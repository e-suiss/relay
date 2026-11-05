defmodule Relay.Channels.SmsTest do
  use ExUnit.Case, async: true

  alias Relay.ChannelDeclarations
  alias Relay.Channels.Sms
  alias Relay.Channels.SmsSender

  defp declarations do
    {:ok, content} = ChannelDeclarations.compose()
    ChannelDeclarations.new(content, nil)
  end

  defp declaration(provider) do
    {:ok, declaration} = ChannelDeclarations.declaration(declarations(), provider)
    declaration
  end

  defp catalog(sms), do: %{"sms" => sms}

  describe "CH-48 CH-75 explicit encoding" do
    test "CH-75: every provider starts with an unverified Turkish single shift" do
      for provider <- ChannelDeclarations.providers(declarations()) do
        declaration = declaration(provider)

        if "sms" in declaration["channels"] do
          assert declaration["sms"]["turkish_single_shift"] == "unverified", provider
          refute Sms.turkish_shift_verified?(declaration), provider
        end
      end
    end

    test "CH-48: Turkish text goes as UCS2 to an unverified provider and GSM7 text stays GSM7" do
      verimor = declaration("verimor")

      assert {:ok, %{encoding: "UCS2", segments: 1}} =
               Sms.encoding(verimor, "Şifreniz 1234", "TR")
      assert {:ok, %{encoding: "GSM7", segments: 1}} = Sms.encoding(verimor, "Code 1234", "TR")
    end

    test "CH-75: GSM7_TR is used only with device evidence of a verified single shift" do
      claimed =
        catalog(%{
          "encodings" => ["GSM7", "GSM7_TR", "UCS2"],
          "turkish_single_shift" => "verified",
          "turkish_single_shift_evidence" => nil
        })

      proven = put_in(claimed, ["sms", "turkish_single_shift_evidence"], "handset 2026-11-05")

      assert {:ok, %{encoding: "UCS2"}} = Sms.encoding(claimed, "ağ", nil)
      assert {:ok, %{encoding: "GSM7_TR"}} = Sms.encoding(proven, "ağ", nil)
    end

    test "CH-48: a provider that cannot name an encoding carrying the text refuses the send" do
      netgsm = declaration("netgsm")

      assert {:error, "channel.sms_encoding_unsupported"} = Sms.encoding(netgsm, "ağ", "TR")
      assert {:ok, %{encoding: "GSM7"}} = Sms.encoding(netgsm, "Kod 1234", "TR")
    end

    test "CH-75: the provider × country reserve enters the segment count, 0 when undeclared" do
      sms = %{
        "encodings" => ["GSM7"],
        "turkish_single_shift" => "unverified",
        "segment_reserve" => [%{"country" => "TR", "septets" => 5, "source" => "test"}]
      }

      text = String.duplicate("a", 158)

      assert Sms.reserved(catalog(sms), "TR") == 5
      assert Sms.reserved(catalog(sms), "DE") == 0
      assert {:ok, %{segments: 2, reserved: 5}} = Sms.encoding(catalog(sms), text, "TR")
      assert {:ok, %{segments: 1, reserved: 0}} = Sms.encoding(catalog(sms), text, "DE")
    end
  end

  describe "CH-51 TR route" do
    test "CH-51: a +90 number goes only through a BTK-authorized provider" do
      assert Sms.route(declaration("netgsm"), "+905551112233", "Kod 1234") == :ok
      assert Sms.route(declaration("verimor"), "+905551112233", "Kod 1234") == :ok

      assert Sms.route(declaration("twilio"), "+905551112233", "Kod 1234") ==
               {:error, "channel.tr_route_unauthorized"}

      assert Sms.route(declaration("twilio"), "+4915112345678", "Kod 1234") == :ok
    end

    test "CH-51: a foreign route with a link in the text is refused with its own rule" do
      assert Sms.route(declaration("infobip"), "+905551112233", "Bak: https://x.example/a") ==
               {:error, "channel.foreign_route_url"}

      assert Sms.route(declaration("infobip"), "+905551112233", "www.example.com") ==
               {:error, "channel.foreign_route_url"}

      assert Sms.link?("ornek.com.tr/kampanya")
      refute Sms.link?("Kodunuz 1234. Kimseyle paylasmayin.")
    end

    test "CH-51: the route keeps only BTK-authorized accounts for a +90 number" do
      accounts = [%{"provider" => "twilio"}, %{"provider" => "netgsm"}]

      assert [%{"provider" => "netgsm"}] =
               Relay.Channels.tr_route(accounts, "+905551112233", declarations())

      assert Relay.Channels.tr_route(accounts, "+4915112345678", declarations()) == accounts
    end
  end

  describe "CH-53 OTP traffic and product" do
    test "CH-53: security uses only security accounts and every other class only standard ones" do
      accounts = [
        %{"id" => 1, "traffic" => "security"},
        %{"id" => 2, "traffic" => "standard"},
        %{"id" => 3}
      ]

      assert [%{"id" => 1}] = Sms.traffic(accounts, "security")
      assert [%{"id" => 2}, %{"id" => 3}] = Sms.traffic(accounts, "marketing")
      assert [%{"id" => 2}, %{"id" => 3}] = Sms.traffic(accounts, "transactional")
    end

    test "CH-53: security maps to the provider's OTP product when it has one" do
      assert Sms.product(declaration("netgsm"), "security") == "otp"
      assert Sms.product(declaration("netgsm"), "transactional") == "standard"
      assert Sms.product(declaration("verimor"), "security") == "standard"
    end
  end

  describe "CH-50 preflight" do
    test "CH-50, CH-48, CH-53: a send carries its sender, encoding and product or stops" do
      sender = %{
        "value" => "ACME",
        "country" => "TR",
        "sms_type" => "alphanumeric",
        "registration" => %{"iys_brand_code" => "123456"}
      }

      content = %{"body" => "Kod 1234"}
      number = "+905551112233"
      netgsm = declaration("netgsm")

      assert {:ok, %{encoding: "GSM7", product: "otp", sender: ^sender}} =
               Sms.preflight(netgsm, sender, "security", number, content)

      unregistered = Map.put(sender, "registration", %{})

      assert {:skip, "channel.sender_iys_missing"} =
               Sms.preflight(netgsm, unregistered, "security", number, content)

      assert {:skip, "channel.tr_route_unauthorized"} =
               Sms.preflight(declaration("twilio"), sender, "security", number, content)
    end

    test "CH-50: a stored row becomes the identity the rules read" do
      identity =
        SmsSender.identity(%{
          "value" => "ACME",
          "country" => "TR",
          "sms_type" => "alphanumeric",
          "registration" => %{"iys_brand_code" => "1", "other" => "x"}
        })

      assert identity["sender_type"] == "alphanumeric"
      assert identity["approval_state"] == "approved"
      refute Map.has_key?(identity, "other")
    end
  end
end
