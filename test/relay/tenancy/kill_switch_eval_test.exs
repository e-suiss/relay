defmodule Relay.Tenancy.KillSwitchEvalTest do
  use ExUnit.Case, async: true

  alias Relay.Tenancy.KillSwitch
  alias Relay.Tenancy.KillSwitch.Record
  alias Relay.Tenancy.KillSwitch.Snapshot

  @now ~U[2026-10-27 12:00:00.000000Z]
  @t "0192f3a4-5b6c-7d8e-9f01-23456789abcd"
  @n "0192f3a4-5b6c-7d8e-9f01-23456789abcf"
  @installation Relay.Id.generate()

  defp id!(text) do
    {:ok, id} = Relay.Id.parse(text)
    id
  end

  defp tenant, do: id!(@t)

  defp record(attrs) do
    base = %{
      id: Relay.Id.generate(),
      tenant_id: tenant(),
      environment: :live,
      scope_kind: :tenant,
      scope_ref: nil,
      channel: nil,
      target_kind: :all,
      target_ref: nil,
      message_class: nil,
      state: :off,
      canary_percent: nil,
      paused_until: nil,
      expires_at: DateTime.add(@now, 3600),
      status: :active,
      created_at: DateTime.add(@now, -60)
    }

    attrs = Map.new(attrs)

    attrs =
      if attrs[:scope_kind] == :platform,
        do: Map.merge(%{tenant_id: @installation, environment: :live}, attrs),
        else: attrs

    struct!(Record, Map.merge(base, attrs))
  end

  defp snapshot(records), do: Snapshot.new(1, records)

  defp message(attrs \\ []) do
    Map.merge(
      %{
        tenant_id: tenant(),
        environment: :live,
        channel: "sms",
        message_class: "transactional",
        notification_id: id!(@n),
        subtenant_id: nil,
        provider_account_id: nil,
        template_id: nil
      },
      Map.new(attrs)
    )
  end

  defp eval(records, attrs \\ []),
    do: KillSwitch.evaluate(snapshot(records), message(attrs), @now)

  describe "TN-37 most restrictive record wins" do
    test "TN-37: platform off with tenant on stops the message" do
      platform = record(scope_kind: :platform, state: :off)
      tenant_on = record(state: :on)
      assert eval([tenant_on, platform]) == {:pause, platform.id, "killswitch.off"}
    end

    test "TN-37: a future paused_until beats a tenant canary of the tenant and channel" do
      canary = record(state: :canary, canary_percent: 10)

      paused =
        record(state: :paused_until, channel: "sms", paused_until: DateTime.add(@now, 600))

      assert eval([canary, paused]) == {:pause, paused.id, "killswitch.paused_until"}
    end

    test "TN-37: of two canaries the smaller percent sets the threshold" do
      wide = record(state: :canary, canary_percent: 30)
      narrow = record(state: :canary, canary_percent: 10)
      assert eval([wide, narrow]) == {:pause, narrow.id, "killswitch.canary"}
    end

    test "TN-37: the oldest off record is the one reported" do
      older = record(state: :off, created_at: DateTime.add(@now, -120))
      newer = record(state: :off, created_at: DateTime.add(@now, -10))
      assert eval([newer, older]) == {:pause, older.id, "killswitch.off"}
    end

    test "TN-37: the latest paused_until is the one reported" do
      soon = record(state: :paused_until, paused_until: DateTime.add(@now, 60))
      later = record(state: :paused_until, paused_until: DateTime.add(@now, 600))
      endless = record(state: :paused_until, paused_until: nil)
      assert eval([soon, later]) == {:pause, later.id, "killswitch.paused_until"}
      assert eval([soon, endless, later]) == {:pause, endless.id, "killswitch.paused_until"}
    end

    test "TN-37: an expired off record allows the message" do
      assert eval([record(state: :off, expires_at: @now)]) == :allow
      assert eval([record(state: :off, expires_at: DateTime.add(@now, -1))]) == :allow
    end

    test "TN-37: a past paused_until allows the message" do
      assert eval([record(state: :paused_until, paused_until: DateTime.add(@now, -1))]) == :allow
    end

    test "TN-37: a released record allows the message" do
      released = record(state: :off, status: :released)
      assert KillSwitch.evaluate(Snapshot.new(1, [released]), message(), @now) == :allow

      assert KillSwitch.evaluate(
               %Snapshot{generation: 1, index: %{{:tenant, tenant(), :live} => [released]}},
               message(),
               @now
             ) == :allow
    end

    test "TN-37: a tenant record of the other environment allows the message" do
      assert eval([record(state: :off, environment: :test)]) == :allow
    end

    test "TN-37: a platform record also stops a message of the test environment" do
      platform = record(scope_kind: :platform, state: :off)
      assert eval([platform], environment: :test) == {:pause, platform.id, "killswitch.off"}
    end

    test "TN-37: a sub-tenant record does not stop a message without a sub-tenant" do
      stn = Relay.Id.generate()
      sub = record(scope_kind: :subtenant, scope_ref: Relay.Id.to_string(stn), state: :off)
      assert eval([sub]) == :allow
      assert eval([sub], subtenant_id: stn) == {:pause, sub.id, "killswitch.off"}
    end

    test "TN-37: the J4 bucket 15 is paused by canary 15 and allowed by canary 16" do
      at_15 = record(state: :canary, canary_percent: 15)
      at_16 = record(state: :canary, canary_percent: 16)
      assert eval([at_15]) == {:pause, at_15.id, "killswitch.canary"}
      assert eval([at_16]) == :allow
    end

    test "TN-37: an on record, no record and a channel or target mismatch allow the message" do
      assert eval([]) == :allow
      assert eval([record(state: :on)]) == :allow
      assert eval([record(state: :off, channel: "email")]) == :allow

      account = Relay.Id.generate()

      by_account =
        record(
          state: :off,
          target_kind: :provider_account,
          target_ref: Relay.Id.to_string(account)
        )

      assert eval([by_account]) == :allow

      assert eval([by_account], provider_account_id: account) ==
               {:pause, by_account.id, "killswitch.off"}

      template = record(state: :off, target_kind: :template, target_ref: "tpl_x")
      assert eval([template], template_id: "tpl_x") == {:pause, template.id, "killswitch.off"}
    end

    test "TN-37: a message of another tenant is not stopped by a tenant record" do
      assert eval([record(state: :off)], tenant_id: Relay.Id.generate()) == :allow
    end
  end

  describe "TN-42 security class" do
    test "TN-42: a record without a message class does not stop security" do
      assert eval([record(state: :off)], message_class: "security") == :allow

      assert eval([record(scope_kind: :platform, state: :off)], message_class: "security") ==
               :allow
    end

    test "TN-42: a record of class security stops security" do
      security = record(state: :off, message_class: "security")

      assert eval([security], message_class: "security") ==
               {:pause, security.id, "killswitch.off"}

      assert eval([security], message_class: "transactional") == :allow
    end
  end

  describe "TN-38 INV-43 no state" do
    test "INV-43: without any snapshot the message is held, never sent" do
      assert KillSwitch.evaluate(:unknown, message(), @now) == {:hold, "killswitch.state_unknown"}
    end
  end
end
