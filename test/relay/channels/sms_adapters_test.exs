defmodule Relay.Channels.SmsAdaptersTest do
  use ExUnit.Case, async: true

  alias Relay.ChannelDeclarations
  alias Relay.Channels.Infobip
  alias Relay.Channels.Netgsm
  alias Relay.Channels.Registry
  alias Relay.Channels.Request
  alias Relay.Channels.Twilio
  alias Relay.Channels.Verimor

  @stub Relay.Channels.ProviderHttp

  defp declarations do
    {:ok, content} = ChannelDeclarations.compose()
    ChannelDeclarations.new(content, nil)
  end

  defp request(provider, settings, fields \\ %{}) do
    base = %{
      scope: nil,
      delivery_id: Relay.Id.generate(),
      attempt_no: 1,
      channel: "sms",
      provider: provider,
      idempotency_key: "dlv-key-1",
      target: %{kind: :address, id: nil, value: Relay.Redacted.wrap("+905551112233")},
      timeout_ms: 5_000,
      content: %{"body" => "Kod 1234"},
      credentials: Relay.Redacted.wrap("secret"),
      account: %{"id" => nil, "settings" => settings},
      sender: %{"value" => "ACME"},
      message_class: "transactional",
      encoding: "GSM7"
    }

    struct!(Request, Map.merge(base, fields))
  end

  defp capture(reply) do
    test = self()

    Req.Test.stub(@stub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      auth = Plug.Conn.get_req_header(conn, "authorization")
      send(test, {:request, conn.method, conn.request_path, conn.query_string, body, auth})
      reply.(conn)
    end)
  end

  defp text(conn, status, body), do: Plug.Conn.send_resp(conn, status, body)

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  describe "CH-2 CH-71 registration" do
    test "CH-71, CH-2: the Turkish adapters are registered and pass the activation gate" do
      declarations = declarations()

      for adapter <- [Netgsm, Verimor] do
        assert adapter in Registry.adapters()
        assert Registry.check(declarations, adapter) == :ok
      end
    end

    test "CH-6, CH-71: the international adapters are complete but for the clause notification date and stay unregistered" do
      declarations = declarations()

      for adapter <- [Twilio, Infobip] do
        refute adapter in Registry.adapters()

        assert ChannelDeclarations.gate(declarations, adapter.provider()) ==
                 {:error, [:data_residency]}

        assert {:error, :unknown_provider} = Registry.adapter(adapter.provider())
      end
    end
  end

  describe "CH-3 CH-48 CH-53 Netgsm" do
    test "CH-48: a GSM7 send names no Turkish set and an accepted send returns the job id" do
      capture(&json(&1, 200, %{"code" => "00", "jobid" => "171"}))

      assert {:accepted, %{provider_message_id: "171"}} =
               Netgsm.deliver(request("netgsm", %{"usercode" => "8501112233"}))

      assert_received {:request, "POST", "/sms/rest/v2/send", _query, body, [auth]}
      body = Jason.decode!(body)
      assert %{"msgheader" => "ACME", "iysfilter" => "0"} = body
      assert [%{"msg" => "Kod 1234", "no" => "905551112233"}] = body["messages"]
      refute Map.has_key?(body, "encoding")
      assert auth == "Basic " <> Base.encode64("8501112233:secret")
    end

    test "CH-48: a GSM7_TR send names the Turkish set" do
      capture(&json(&1, 200, %{"code" => "00", "jobid" => "172"}))
      Netgsm.deliver(request("netgsm", %{"usercode" => "u"}, %{encoding: "GSM7_TR"}))
      assert_received {:request, "POST", "/sms/rest/v2/send", _query, body, _auth}
      assert %{"encoding" => "TR"} = Jason.decode!(body)
    end

    test "CH-53: the OTP product goes to the OTP service" do
      capture(&json(&1, 200, %{"code" => "0", "jobId" => "9"}))

      assert {:accepted, %{provider_message_id: "9"}} =
               Netgsm.deliver(request("netgsm", %{"usercode" => "u"}, %{product: "otp"}))

      assert_received {:request, "POST", "/sms/rest/v2/otp", _query, body, _auth}
      assert %{"msgheader" => "ACME", "no" => "905551112233"} = Jason.decode!(body)
    end

    test "CH-7: a failure code in the body is the provider code of the mapping" do
      capture(&json(&1, 406, %{"code" => "40"}))

      assert {:rejected, %{code: "send:40", status: 406}} =
               Netgsm.deliver(request("netgsm", %{"usercode" => "u"}))

      capture(&json(&1, 406, %{"code" => "60"}))

      assert {:rejected, %{code: "otp:60"}} =
               Netgsm.deliver(request("netgsm", %{"usercode" => "u"}, %{product: "otp"}))
    end

    test "T-28: no connection is not sent and no answer is uncertain" do
      Req.Test.stub(@stub, &Req.Test.transport_error(&1, :econnrefused))
      assert {:not_sent, "econnrefused"} = Netgsm.deliver(request("netgsm", %{}))

      Req.Test.stub(@stub, &Req.Test.transport_error(&1, :timeout))
      assert {:uncertain, "timeout"} = Netgsm.deliver(request("netgsm", %{}))
    end

    test "CH-10: a report row is delivered, pending or a failure code" do
      assert %{result: {:delivered, _}} = Netgsm.report(%{"jobid" => 1, "status" => 1})
      assert %{result: :pending} = Netgsm.report(%{"jobid" => 1, "status" => 0})
      assert %{result: {:rejected, %{code: "dlr:16"}}} = Netgsm.report(%{"status" => 16})
    end
  end

  describe "CH-3 CH-48 CH-56 Verimor" do
    test "CH-48, INV-13: the send names its data coding and carries the idempotency key" do
      capture(&text(&1, 200, "20210"))

      fields = %{encoding: "UCS2", ttl_s: 3600}
      request = request("verimor", %{"username" => "908501112233"}, fields)
      assert {:accepted, %{provider_message_id: "20210"}} = Verimor.deliver(request)

      assert_received {:request, "POST", "/v2/send.json", _query, body, _auth}
      body = Jason.decode!(body)

      assert %{"datacoding" => "2", "custom_id" => "dlv-key-1", "valid_for" => "01:00"} = body
      assert [%{"id" => "dlv-key-1", "dest" => "905551112233"}] = body["messages"]
    end

    test "CH-7: an error name answers with its provider code" do
      capture(&text(&1, 400, "INVALID_SOURCE_ADDRESS"))

      assert {:rejected, %{code: "send:INVALID_SOURCE_ADDRESS"}} =
               Verimor.deliver(request("verimor", %{}))
    end

    test "T-28: an uncertain send is looked up by its custom id" do
      capture(&json(&1, 200, [%{"message_id" => 77, "status" => "DELIVERED"}]))

      assert {:accepted, %{provider_message_id: "77"}} = Verimor.query(request("verimor", %{}))
      assert_received {:request, "GET", "/v2/status", query, _body, _auth}
      assert URI.decode_query(query)["custom_id"] == "dlv-key-1"

      capture(&text(&1, 404, ""))
      assert Verimor.query(request("verimor", %{})) == :not_received
    end

    test "CH-56: a voice call reads the text with the sender number as caller id" do
      capture(&text(&1, 200, "5501"))

      request =
        request("verimor", %{}, %{
          channel: "voice",
          content: %{"body" => "Kodunuz 1 2 3 4", "language" => "tr-TR"},
          sender: %{"value" => "908501112233"}
        })

      assert {:accepted, %{provider_message_id: "5501"}} = Verimor.deliver(request)
      assert_received {:request, "POST", "/ivr_campaigns.json", query, body, _auth}
      assert URI.decode_query(query)["key"] == "secret"
      body = Jason.decode!(body)
      assert %{"cli" => "908501112233", "call_type" => "ivr"} = body
      assert [%{"phone" => "905551112233", "phrase" => "Kodunuz 1 2 3 4"}] = body["phone_list"]
    end

    test "CH-3, T-40: a report is read only with the URL token" do
      key = Relay.Redacted.wrap("token-1")
      body = Jason.encode!([%{"message_id" => 5, "status" => "NOT_ALLOWED_BY_IYS"}])

      assert {:ok, [%{result: {:rejected, %{code: "dlr:NOT_ALLOWED_BY_IYS"}}}]} =
               Verimor.reports(body, [], key: key, token: "token-1")

      assert {:error, :bad_signature} = Verimor.reports(body, [], key: key, token: "token-2")
      assert {:error, :missing_header} = Verimor.reports(body, [], key: key)

      answered = URI.encode_query(%{"status" => "Cevaplandı", "ivr_campaign_id" => "5"})
      missed = URI.encode_query(%{"status" => "Cevapsız", "ivr_campaign_id" => "6"})

      assert {:ok, [%{result: {:delivered, _}, channel: "voice"}]} =
               Verimor.reports(answered, [], key: key, token: "token-1")

      assert {:ok, [%{result: {:rejected, %{code: "call:Cevapsız"}}}]} =
               Verimor.reports(missed, [], key: key, token: "token-1")
    end
  end

  describe "CH-3 T-40 Twilio" do
    test "CH-48: a message is sent without smart encoding, a failure answers with its code" do
      capture(&json(&1, 201, %{"sid" => "SM1", "status" => "queued"}))
      request = request("twilio", %{"account_sid" => "AC1"}, %{ttl_s: 600})

      assert {:accepted, %{provider_message_id: "SM1"}} = Twilio.deliver(request)
      assert_received {:request, "POST", "/2010-04-01/Accounts/AC1/Messages.json", _q, body, _a}
      form = URI.decode_query(body)
      assert %{"SmartEncoded" => "false", "From" => "ACME", "ValidityPeriod" => "600"} = form

      capture(&json(&1, 400, %{"code" => 21_211, "status" => 400, "message" => "m"}))
      assert {:rejected, %{code: "21211", status: 400}} = Twilio.deliver(request)
    end

    test "CH-56: a call reads the escaped text in the content's language" do
      capture(&json(&1, 201, %{"sid" => "CA1"}))

      request =
        request("twilio", %{"account_sid" => "AC1"}, %{
          channel: "voice",
          content: %{"body" => "Kod <1>", "language" => "tr-TR"}
        })

      assert {:accepted, %{provider_message_id: "CA1"}} = Twilio.deliver(request)
      assert_received {:request, "POST", "/2010-04-01/Accounts/AC1/Calls.json", _q, body, _a}
      assert URI.decode_query(body)["Twiml"] =~ ~s(<Say language="tr-TR">Kod &lt;1&gt;</Say>)
    end

    test "T-40, TN-35: a status callback is read only with a valid signature over URL and form" do
      url = "https://relay.example/hooks/twilio"
      body = "ErrorCode=30003&MessageSid=SM1&MessageStatus=undelivered"
      signed = url <> "ErrorCode30003MessageSidSM1MessageStatusundelivered"
      signature = Base.encode64(:crypto.mac(:hmac, :sha, "token", signed))
      key = Relay.Redacted.wrap("token")

      assert {:ok, [report]} =
               Twilio.reports(body, [{"x-twilio-signature", signature}], key: key, url: url)

      assert %{provider_message_id: "SM1", result: {:rejected, %{code: "30003"}}} = report

      assert {:ok, outcome} =
               Relay.Channels.normalize_report(declarations(), "twilio", "sms", report)

      assert %{failure_class: "transient", event_code: "undelivered"} = outcome

      headers = [{"x-twilio-signature", signature}]

      assert {:error, :bad_signature} = Twilio.reports(body, headers, key: key, url: url <> "/")
    end

    test "INV-13, DS-10: the callback carries the idempotency key back to the report" do
      capture(&json(&1, 201, %{"sid" => "SM3"}))
      settings = %{"account_sid" => "AC1", "status_callback_url" => "https://relay.example/t?a=1"}
      Twilio.deliver(request("twilio", settings))
      assert_received {:request, "POST", _path, _query, body, _auth}
      callback = URI.decode_query(body)["StatusCallback"]
      assert URI.decode_query(URI.parse(callback).query) == %{"a" => "1", "key" => "dlv-key-1"}

      form = "MessageSid=SM3&MessageStatus=sent"
      signed = callback <> "MessageSidSM3MessageStatussent"
      signature = Base.encode64(:crypto.mac(:hmac, :sha, "token", signed))
      key = Relay.Redacted.wrap("token")

      assert {:ok, [%{correlation: "dlv-key-1"} = report]} =
               Twilio.reports(form, [{"x-twilio-signature", signature}], key: key, url: callback)

      scope = Relay.Scope.new!(Relay.Id.generate(), :live)
      assert Relay.Channels.Live.record_report(scope, "twilio", report) == {:ok, :pending}

      unknown = %{report | result: {:delivered, %{}}, correlation: nil}

      assert Relay.Channels.Live.record_report(scope, "twilio", unknown) ==
               {:error, :delivery_not_found}
    end

    test "CH-10: a delivered report is the delivered event and a pending one has no outcome" do
      delivered = Twilio.report(%{"MessageSid" => "SM2", "MessageStatus" => "delivered"})

      assert {:ok, %{event_code: "delivered", provider_message_id: "SM2"}} =
               Relay.Channels.normalize_report(declarations(), "twilio", "sms", delivered)

      pending = Twilio.report(%{"MessageSid" => "SM2", "MessageStatus" => "sent"})

      assert {:ok, nil} =
               Relay.Channels.normalize_report(declarations(), "twilio", "sms", pending)
    end
  end

  describe "CH-3 CH-48 Infobip" do
    test "CH-48, INV-13: the send names its language and carries the idempotency key" do
      reply = %{
        "messages" => [%{"messageId" => "dlv-key-1", "status" => %{"groupName" => "PENDING"}}]
      }

      capture(&json(&1, 200, reply))
      settings = %{"base_url" => "x1y2.api.infobip.com"}
      request = request("infobip", settings, %{encoding: "GSM7_TR"})

      assert {:accepted, %{provider_message_id: "dlv-key-1"}} = Infobip.deliver(request)
      assert_received {:request, "POST", "/sms/3/messages", _query, body, ["App secret"]}
      [message] = Jason.decode!(body)["messages"]
      assert message["content"]["language"] == %{"languageCode" => "TR", "singleShift" => true}
      assert [%{"messageId" => "dlv-key-1", "to" => "905551112233"}] = message["destinations"]
    end

    test "CH-3: a host outside Infobip's API domain is refused before any call" do
      request = request("infobip", %{"base_url" => "evil.example.com"})
      assert {:rejected, %{code: "config:base_url"}} = Infobip.deliver(request)
      refute_received {:request, _, _, _, _, _}
    end

    test "T-28: an uncertain send without a log row was not received" do
      capture(&json(&1, 200, %{"results" => []}))
      request = request("infobip", %{"base_url" => "x1y2.api.infobip.com"})
      assert Infobip.query(request) == :not_received
      assert_received {:request, "GET", "/sms/3/logs", query, _body, _auth}
      assert URI.decode_query(query)["messageId"] == "dlv-key-1"
    end

    test "T-40: a delivery report is read only with its HMAC over the raw body" do
      key = Relay.Redacted.wrap("hmac-key")

      body =
        Jason.encode!(%{
          "results" => [
            %{"messageId" => "m1", "status" => %{"groupName" => "DELIVERED", "name" => "D"}}
          ]
        })

      hex = Base.encode16(:crypto.mac(:hmac, :sha256, "hmac-key", body), case: :lower)

      assert {:ok, [%{result: {:delivered, _}, provider_message_id: "m1"}]} =
               Infobip.reports(body, [{"x-hub-signature", hex}], key: key)

      assert {:error, :bad_signature} =
               Infobip.reports(body <> " ", [{"x-hub-signature", hex}], key: key)
    end
  end
end
