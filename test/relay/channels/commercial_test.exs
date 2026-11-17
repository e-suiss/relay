defmodule Relay.Channels.CommercialTest do
  use ExUnit.Case, async: true

  alias Relay.Channels.Commercial
  alias Relay.Channels.Netgsm
  alias Relay.Channels.Request
  alias Relay.Channels.Verimor

  @stub Relay.Channels.ProviderHttp

  defp request(provider, fields) do
    base = %{
      scope: nil,
      delivery_id: Relay.Id.generate(),
      attempt_no: 1,
      channel: "sms",
      provider: provider,
      idempotency_key: "dlv-key-1",
      target: %{kind: :address, id: nil, value: Relay.Redacted.wrap("+905551112233")},
      timeout_ms: 5_000,
      content: %{"body" => "Kampanya basladi"},
      credentials: Relay.Redacted.wrap("secret"),
      account: %{"id" => nil, "settings" => %{"usercode" => "u", "username" => "u"}},
      sender: %{"value" => "ACME"},
      message_class: "marketing",
      encoding: "GSM7"
    }

    struct!(Request, Map.merge(base, fields))
  end

  defp capture(reply) do
    test = self()

    Req.Test.stub(@stub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, conn.request_path, Jason.decode!(body)})
      reply.(conn)
    end)
  end

  defp netgsm(fields) do
    capture(fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"code" => "00", "jobid" => "1"}))
    end)

    {:accepted, _detail} = Netgsm.deliver(request("netgsm", fields))
    assert_received {:request, "/sms/rest/v2/send", body}
    body
  end

  defp verimor(fields) do
    capture(&Plug.Conn.send_resp(&1, 200, "20210"))
    {:accepted, _detail} = Verimor.deliver(request("verimor", fields))
    assert_received {:request, _path, body}
    body
  end

  describe "PC-4 commercial declaration" do
    test "PC-4: only the marketing class is commercial" do
      for class <- ~w(security action_required transactional operational social system) do
        assert Commercial.declaration(class, "individual") ==
                 %{commercial: false, iys_recipient_type: nil}
      end

      assert Commercial.declaration(nil, nil) == %{commercial: false, iys_recipient_type: nil}
      assert %{commercial: true} = Commercial.declaration("marketing", "individual")
    end

    test "PC-4: the İYS recipient type comes from the consent copy's recipient type" do
      assert Commercial.declaration("marketing", "individual").iys_recipient_type == "BIREYSEL"
      assert Commercial.declaration("marketing", "merchant").iys_recipient_type == "TACIR"
      assert Commercial.declaration("marketing", nil).iys_recipient_type == "BIREYSEL"
    end

    test "PC-4: the recipient type is read from the active consent of the brand and channel" do
      brand = Relay.Id.generate()

      consents = [
        %{
          "channel" => "sms",
          "brand_subtenant_id" => nil,
          "status" => "active",
          "recipient_type" => "merchant"
        },
        %{
          "channel" => "sms",
          "brand_subtenant_id" => brand,
          "status" => "active",
          "recipient_type" => "individual"
        },
        %{
          "channel" => "voice",
          "brand_subtenant_id" => nil,
          "status" => "revoked",
          "recipient_type" => "merchant"
        }
      ]

      assert Commercial.recipient_type(consents, "sms", nil) == "merchant"
      assert Commercial.recipient_type(consents, "sms", brand) == "individual"
      assert Commercial.recipient_type(consents, "voice", nil) == nil
      assert Commercial.recipient_type(consents, "email", nil) == nil
      assert Commercial.recipient_type([], "sms", nil) == nil
    end

    test "PC-4: a request without a decided declaration is declared from its class" do
      assert Commercial.of(request("netgsm", %{})) ==
               %{commercial: true, iys_recipient_type: "BIREYSEL"}

      assert Commercial.of(request("netgsm", %{message_class: "security"})) ==
               %{commercial: false, iys_recipient_type: nil}

      decided = %{commercial: true, iys_recipient_type: "TACIR"}
      assert Commercial.of(request("netgsm", %{commercial: decided})) == decided
    end
  end

  describe "PC-4 the declaration the adapters send" do
    test "PC-4: Netgsm's İYS filter follows the declaration, never the account default" do
      individual = %{commercial: true, iys_recipient_type: "BIREYSEL"}
      merchant = %{commercial: true, iys_recipient_type: "TACIR"}
      none = %{commercial: false, iys_recipient_type: nil}

      assert netgsm(%{commercial: individual})["iysfilter"] == "11"
      assert netgsm(%{commercial: merchant})["iysfilter"] == "12"
      assert netgsm(%{commercial: none, message_class: "transactional"})["iysfilter"] == "0"
      assert netgsm(%{})["iysfilter"] == "11"
      assert netgsm(%{message_class: "operational"})["iysfilter"] == "0"
    end

    test "PC-4: Verimor's commercial flag and recipient type follow the declaration" do
      merchant = %{commercial: true, iys_recipient_type: "TACIR"}

      assert %{"is_commercial" => true, "iys_recipient_type" => "TACIR"} =
               verimor(%{commercial: merchant})

      assert %{"is_commercial" => true, "iys_recipient_type" => "BIREYSEL"} = verimor(%{})

      body = verimor(%{message_class: "transactional"})
      assert body["is_commercial"] == false
      refute Map.has_key?(body, "iys_recipient_type")
    end

    test "PC-4, CH-56: a voice call is declared like an SMS" do
      voice = %{channel: "voice", sender: %{"value" => "+908501112233"}}
      merchant = %{commercial: true, iys_recipient_type: "TACIR"}

      assert %{"is_commercial" => true, "iys_recipient_type" => "TACIR"} =
               verimor(Map.put(voice, :commercial, merchant))

      body = verimor(Map.put(voice, :message_class, "security"))
      assert body["is_commercial"] == false
      refute Map.has_key?(body, "iys_recipient_type")
    end
  end
end
