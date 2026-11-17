defmodule Relay.Policy.ComplianceGateTest do
  use ExUnit.Case, async: true

  alias Relay.Policy.Engine
  alias Relay.Policy.Fixture

  @hour 3_600_000
  @us_zones ~w(America/New_York America/Chicago America/Denver America/Phoenix
               America/Los_Angeles America/Anchorage Pacific/Honolulu)

  defp evaluate(changes), do: changes |> Fixture.snapshot() |> Engine.evaluate()

  defp marketing(channel, changes) do
    base = [
      channel: channel,
      notification: [message_class: :marketing],
      preferences: [category_channel: :opt_in],
      consent: %{state: :active, ref: "c1"}
    ]

    evaluate(base ++ changes)
  end

  defp synced(age_ms), do: DateTime.to_unix(Fixture.now(), :millisecond) - age_ms

  defp merchant, do: Fixture.compliance(recipient_type: :merchant)

  defp us_window do
    Fixture.compliance(
      required: :explicit_opt_in,
      accepted: [:explicit_opt_in],
      default: :locked_off,
      legal_windows: [
        %{row: "us.marketing.sms_voice", from: ~T[08:00:00], to: ~T[21:00:00], zones: @us_zones}
      ]
    )
  end

  defp assert_at(%DateTime{} = actual, %DateTime{} = expected),
    do: assert(DateTime.compare(actual, expected) == :eq, "#{actual} is not #{expected}")

  describe "PC-40 gate 1d: the compliance table" do
    test "PC-40, PC-42: a row that asks for consent passes only an ACTIVE consent of a kind it accepts" do
      soft =
        Fixture.compliance(
          required: :soft_opt_in,
          accepted: [:soft_opt_in, :explicit_opt_in],
          default: :locked_off,
          detail: %{compliance_row: "eu.marketing.individual", compliance_country: "DE"}
        )

      for kind <- [:soft_opt_in, :explicit_opt_in] do
        consent = %{state: :active, ref: "c1", kind: kind}
        assert {:send, _} = marketing(:email, compliance: soft, consent: consent)
      end

      weak = %{state: :active, ref: "c2", kind: :legitimate_interest}

      assert {:skip, :consent_missing, "consent.insufficient", detail} =
               marketing(:email, compliance: soft, consent: weak)

      assert detail.consent_kind == :legitimate_interest
      assert detail.consent_ref == "c2"

      assert {:skip, :consent_missing, "consent.missing", _} =
               marketing(:email, compliance: soft, consent: %{state: :none, ref: nil})
    end

    test "PC-24, PC-42: a merchant needs no prior consent" do
      for channel <- [:email, :sms, :voice] do
        assert {:send, _} =
                 marketing(channel, compliance: merchant(), consent: %{state: :none, ref: nil})
      end
    end

    test "PC-40: a class other than marketing is held to its row as well" do
      strict = Fixture.compliance(required: :explicit_opt_in, accepted: [:explicit_opt_in])

      for class <- [:transactional, :security] do
        changes = [channel: :sms, notification: [message_class: class], compliance: strict]

        assert {:skip, :consent_missing, "consent.missing", _} = evaluate(changes)

        assert {:skip, :consent_revoked, "consent.revoked", _} =
                 evaluate(changes ++ [consent: %{state: :revoked, ref: "c4"}])

        assert {:send, _} = evaluate(changes ++ [consent: %{state: :active, ref: "c5"}])
      end
    end

    test "PC-58: the decision detail names the row that decided" do
      assert {:skip, :consent_missing, "consent.missing", detail} =
               marketing(:email, consent: %{state: :none, ref: nil})

      assert %{compliance_row: "tr.marketing.individual", compliance_country: "TR"} = detail
    end

    test "INV-43: a compliance input that could not be read decides nothing" do
      assert {:error, {:input_unavailable, :compliance}} =
               marketing(:email, compliance: :unreadable)

      assert {:error, {:input_unavailable, :compliance}} = evaluate(compliance: :unreadable)
    end

    test "INV-17, PC-54: no tenant default opens a cell the table locks; the recipient's own value does" do
      locked = Fixture.compliance(default: :locked_off)

      changes = [
        channel: :in_app,
        notification: [message_class: :marketing],
        category: [channel_defaults: %{in_app: :on}],
        compliance: locked
      ]

      assert {:skip, :preference_off, "preference.category_default", _} = evaluate(changes)
      assert {:send, _} = evaluate(changes ++ [preferences: [category_channel: :opt_in]])
      assert {:send, _} = evaluate(Keyword.put(changes, :compliance, Fixture.compliance()))
    end
  end

  describe "PC-27 PC-33 gate 1d: İYS" do
    test "PC-27, INV-19: a tenant in scope without İYS information sends no marketing on e-mail, SMS and voice" do
      for channel <- [:email, :sms, :voice] do
        assert {:skip, :iys_not_configured, "iys.not_configured", detail} =
                 marketing(channel, iys: :not_configured)

        assert detail.recipient_type == :individual
      end

      assert {:skip, :iys_not_configured, "iys.not_configured", _} =
               marketing(:email, iys: :not_configured, compliance: merchant())
    end

    test "PC-27: push, in-app and WhatsApp and the informational classes are outside İYS" do
      for channel <- [:push, :in_app, :whatsapp] do
        assert {:send, _} = marketing(channel, iys: :not_configured)
      end

      for class <- [:transactional, :operational], channel <- [:email, :sms] do
        assert {:send, _} =
                 evaluate(
                   channel: channel,
                   notification: [message_class: class],
                   preferences: [category_channel: :opt_in],
                   iys: :not_configured
                 )
      end
    end

    test "PC-27: a tenant outside the scope of İYS is not held to it" do
      assert {:send, _} = marketing(:email, iys: :out_of_scope)
    end

    test "PC-33, PC-21: an individual recipient needs an approval in the İYS copy" do
      assert {:send, _} = marketing(:sms, iys: {:cached, :approved, synced(@hour)})

      assert {:skip, :consent_missing, "iys.approval_missing", _} =
               marketing(:sms, iys: {:cached, :none, synced(@hour)})
    end

    test "PC-24: a merchant needs no approval and is stopped only by a rejection" do
      assert {:send, _} =
               marketing(:email, compliance: merchant(), iys: {:cached, :none, synced(@hour)})

      for compliance <- [merchant(), Fixture.compliance()] do
        assert {:skip, :consent_revoked, "iys.rejected", _} =
                 marketing(:email,
                   compliance: compliance,
                   iys: {:cached, :rejected, synced(@hour)}
                 )
      end
    end

    test "PC-33, INV-43: a stale or never synchronised İYS copy stops marketing" do
      assert {:send, _} = marketing(:email, iys: {:cached, :approved, synced(23 * @hour)})

      assert {:skip, :iys_stale, "iys.stale", detail} =
               marketing(:email, iys: {:cached, :approved, synced(24 * @hour)})

      assert_at(detail.iys_synced_at, DateTime.add(Fixture.now(), -24, :hour))

      assert {:skip, :iys_stale, "iys.stale", %{iys_synced_at: nil}} =
               marketing(:email, iys: {:cached, :approved, nil})

      old = {:cached, :none, synced(30 * @hour)}

      assert {:skip, :iys_stale, "iys.stale", _} =
               marketing(:voice, compliance: merchant(), iys: old)
    end

    test "INV-43: an İYS input that could not be read decides nothing" do
      assert {:error, {:input_unavailable, :iys}} = marketing(:email, iys: :unreadable)
    end

    test "PC-27: the table's consent is asked before İYS" do
      assert {:skip, :consent_missing, "consent.missing", _} =
               marketing(:email, consent: %{state: :none, ref: nil}, iys: :not_configured)
    end
  end

  describe "PC-47 WF-46 the legal send window" do
    test "PC-47, C-63: the legal window defers on every channel and is not the quiet hours" do
      for channel <- [:sms, :voice, :email] do
        assert {:defer, :legal_window, "legal_window.deferred", until, detail} =
                 marketing(channel,
                   compliance: us_window(),
                   profile: [time_zone: "America/New_York", quiet_hours: []]
                 )

        assert_at(until, ~U[2026-11-02 13:00:00Z])
        assert detail.legal_window == ["us.marketing.sms_voice"]
        assert detail.timezone_inferred == false
        assert detail.timezone_source == :profile
      end

      assert {:send, _} =
               marketing(:sms,
                 now: ~U[2026-11-02 13:00:00Z],
                 compliance: us_window(),
                 profile: [time_zone: "America/New_York"]
               )
    end

    test "WF-46, PC-47: with an inferred zone the narrowest window across the country's zones applies" do
      for device <- [nil, "America/Chicago"] do
        changes = [
          compliance: us_window(),
          profile: [time_zone: nil],
          device_time_zone: device,
          notification: [expires_at: ~U[2026-11-05 00:00:00Z]]
        ]

        assert {:defer, :legal_window, "legal_window.deferred", until, detail} =
                 marketing(:sms, changes)

        assert_at(until, ~U[2026-11-02 18:00:00Z])
        assert detail.timezone_inferred == true

        assert {:send, info} = marketing(:sms, [now: ~U[2026-11-02 18:30:00Z]] ++ changes)
        assert info.timezone_source in [:tenant_default, :device]

        assert {:defer, :legal_window, _, late, _} =
                 marketing(:sms, [now: ~U[2026-11-03 02:30:00Z]] ++ changes)

        assert_at(late, ~U[2026-11-03 18:00:00Z])
      end
    end

    test "PC-47: without a legal window row only the other shapers apply" do
      assert {:send, _} =
               marketing(:sms, profile: [time_zone: "America/New_York", quiet_hours: []])
    end

    test "PC-47: a delivery that no window lets through before it expires is expired" do
      assert {:expire, "expiry.no_window", %{deferred_by: "legal_window.deferred"}} =
               marketing(:sms,
                 compliance: us_window(),
                 profile: [time_zone: "America/New_York"],
                 notification: [
                   message_class: :marketing,
                   expires_at: ~U[2026-11-02 12:30:00Z]
                 ]
               )
    end
  end
end
