defmodule Relay.Iys.ConsentTest do
  use ExUnit.Case, async: true

  alias Relay.Iys.Consent

  @now ~U[2026-11-17 09:00:00Z]

  defp consent(changes \\ %{}) do
    Map.merge(
      %{
        recipient: "+905321112233",
        type: "MESAJ",
        status: "ONAY",
        recipient_type: "BIREYSEL",
        source: "HS_WEB",
        consent_at: ~U[2026-11-17 08:00:00Z]
      },
      changes
    )
  end

  describe "PC-27 channels and types" do
    test "PC-27: only sms, voice and email have an İYS type" do
      assert Consent.type("sms") == {:ok, "MESAJ"}
      assert Consent.type("voice") == {:ok, "ARAMA"}
      assert Consent.type("email") == {:ok, "EPOSTA"}

      for channel <- ~w(push web_push whatsapp in_app slack webhook) do
        assert Consent.type(channel) == :out_of_scope
      end

      assert Consent.channel("ARAMA") == "voice"
      assert Consent.recipient_type("merchant") == "TACIR"
      assert Consent.recipient_type(nil) == "BIREYSEL"
    end
  end

  describe "PC-34 sources" do
    test "PC-34: a consent source maps to the İYS source set; an unknown one is not guessed" do
      assert Consent.source("preference_center") == {:ok, "HS_WEB"}
      assert Consent.source("mobile") == {:ok, "HS_MOBIL"}
      assert Consent.source("sms_keyword") == {:ok, "HS_MESAJ"}
      assert Consent.source("one_click") == {:ok, "HS_EPOSTA"}
      assert Consent.source("call_center") == {:ok, "HS_CAGRI_MERKEZI"}
      assert Consent.source("tenant_decision") == {:ok, "HS_KARAR"}
      assert Consent.source("hs_islak_imza") == {:ok, "HS_ISLAK_IMZA"}
      assert Consent.source("access") == :error
      assert Consent.source("iys_web") == :error
      assert Consent.source(nil) == :error
    end
  end

  describe "PC-34 local validation" do
    test "PC-34: a valid movement passes and its body carries the date in Turkey time" do
      assert Consent.validate(consent(), @now) == :ok

      assert Consent.body(consent()) == %{
               "recipient" => "+905321112233",
               "type" => "MESAJ",
               "source" => "HS_WEB",
               "status" => "ONAY",
               "consentDate" => "2026-11-17 11:00:00",
               "recipientType" => "BIREYSEL"
             }
    end

    test "PC-34: a phone number that is not E.164, too long or written +900 is refused" do
      refused = ["05321112233", "+9005321112233", "+90 532 111 22 33", "+1234567890123456"]

      for recipient <- refused do
        assert Consent.validate(consent(%{recipient: recipient}), @now) ==
                 {:error, :invalid_phone}
      end

      assert Consent.validate(consent(%{type: "ARAMA"}), @now) == :ok
    end

    test "PC-34: an e-mail address is lower case, without a space and of 6 to 265 characters" do
      email = %{type: "EPOSTA", recipient: "ayse@example.com"}
      assert Consent.validate(consent(email), @now) == :ok
      assert Consent.recipient("EPOSTA", " Ayse@Example.COM ") == "ayse@example.com"

      for recipient <- ["Ayse@example.com", "a@b.c", "ayse @example.com", "ayşe@example.com"] do
        assert Consent.validate(consent(%{email | recipient: recipient}), @now) ==
                 {:error, :invalid_email}
      end

      long = String.duplicate("a", 260) <> "@b.com"

      assert Consent.validate(consent(%{email | recipient: long}), @now) ==
               {:error, :invalid_email}
    end

    test "PC-34: a date in the future or before 1 May 2015 is refused" do
      future = consent(%{consent_at: ~U[2026-11-17 09:00:01Z]})
      early = consent(%{consent_at: ~U[2015-04-30 20:59:59Z]})
      legacy = consent(%{source: "HS_2015", consent_at: ~U[2015-04-30 21:00:00Z]})

      assert Consent.validate(future, @now) == {:error, :date_in_future}
      assert Consent.validate(early, @now) == {:error, :date_too_early}
      assert Consent.validate(legacy, @now) == :ok
      assert Consent.validate(%{legacy | consent_at: @now}, @now) == {:error, :date_too_early}
    end

    test "PC-34: a value outside the İYS sets and an approving provider decision are refused" do
      assert Consent.validate(consent(%{type: "PUSH"}), @now) == {:error, :invalid_type}
      assert Consent.validate(consent(%{status: "BEKLIYOR"}), @now) == {:error, :invalid_status}
      assert Consent.validate(consent(%{source: "UNMAPPED"}), @now) == {:error, :invalid_source}
      assert Consent.validate(consent(%{source: "IYS_WEB"}), @now) == {:error, :invalid_source}

      assert Consent.validate(consent(%{recipient_type: "KURUM"}), @now) ==
               {:error, :invalid_recipient_type}

      assert Consent.validate(consent(%{source: "HS_KARAR"}), @now) ==
               {:error, :source_requires_rejection}

      assert Consent.validate(consent(%{source: "HS_KARAR", status: "RET"}), @now) == :ok
    end

    test "PC-34: a batch holds 1 to the published maximum and no recipient twice" do
      one = consent()
      other = consent(%{recipient: "+905321112234"})

      assert Consent.validate_batch([one, other], @now, 1000) == :ok
      assert Consent.validate_batch([], @now, 1000) == {:error, :empty, nil}
      assert Consent.validate_batch([one, other], @now, 1) == {:error, :too_many, nil}

      assert Consent.validate_batch([one, other, %{one | status: "RET"}], @now, 1000) ==
               {:error, :repeated_recipient, 2}

      assert Consent.validate_batch([one, %{other | type: "X"}], @now, 1000) ==
               {:error, :invalid_type, 1}
    end
  end
end
