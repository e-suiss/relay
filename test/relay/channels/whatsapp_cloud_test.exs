defmodule Relay.Channels.WhatsappCloudTest do
  use ExUnit.Case, async: true

  alias Relay.ChannelDeclarations
  alias Relay.Channels.Request
  alias Relay.Channels.Whatsapp.Message
  alias Relay.Channels.WhatsappCloud

  defp request(fields \\ []) do
    struct!(
      Request,
      Keyword.merge(
        [
          scope: Relay.Scope.new!(Relay.Id.generate(), :live),
          delivery_id: Relay.Id.generate(),
          attempt_no: 1,
          channel: "whatsapp",
          provider: "whatsapp_cloud",
          idempotency_key: "dlv-1",
          target: %{kind: :address, id: nil, value: Relay.Redacted.wrap("+905551112233")},
          timeout_ms: 5_000,
          content: %{
            "template_name" => "order_shipped_v3",
            "language" => "tr",
            "parameters" => [%{"name" => "1", "value" => "A-17"}]
          },
          credentials: Relay.Redacted.wrap("system-user-token"),
          account: %{"id" => Relay.Id.generate(), "settings" => %{"phone_number_id" => "1065"}}
        ],
        fields
      )
    )
  end

  defp stub(fun), do: Req.Test.stub(WhatsappCloud, fun)

  defp reply(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp normalize(result) do
    {:ok, content} = ChannelDeclarations.compose()
    declarations = ChannelDeclarations.new(content, nil)
    Relay.Channels.normalize(declarations, "whatsapp_cloud", "whatsapp", result)
  end

  describe "CH-3 CH-60 Cloud API adapter" do
    test "CH-60, CH-57: a template message goes to the number's messages endpoint with the correlation" do
      test = self()
      request = request()

      stub(fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        authorization = Plug.Conn.get_req_header(conn, "authorization")
        send(test, {:sent, conn.request_path, authorization, raw})

        reply(conn, 200, %{
          "messaging_product" => "whatsapp",
          "messages" => [%{"id" => "wamid.HBgL", "message_status" => "accepted"}]
        })
      end)

      assert {:accepted, %{provider_message_id: "wamid.HBgL"} = info} =
               WhatsappCloud.deliver(request)

      assert info.detail == %{"message_status" => "accepted"}
      assert_received {:sent, "/v24.0/1065/messages", ["Bearer system-user-token"], raw}

      body = Jason.decode!(raw)
      assert body["type"] == "template"
      assert body["to"] == "+905551112233"
      correlation = Message.correlation(request.delivery_id, 1)
      assert body["biz_opaque_callback_data"] == correlation
    end

    test "CH-59, CH-7: a Graph API error is reported by its code and classified by the mapping" do
      stub(fn conn ->
        reply(conn, 400, %{
          "error" => %{
            "message" => "(#131026) Message undeliverable",
            "type" => "OAuthException",
            "code" => 131_026,
            "error_data" => %{"details" => "Message undeliverable"},
            "fbtrace_id" => "A1"
          }
        })
      end)

      assert {:rejected, %{code: "131026", status: 400} = raw} = WhatsappCloud.deliver(request())
      assert raw.detail["details"] == "Message undeliverable"
      assert {:ok, outcome} = normalize({:rejected, raw})
      assert outcome.failure_class == "permanent_target"
    end

    test "CH-9: a throttled answer without a code carries its Retry-After" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "30")
        |> Plug.Conn.send_resp(429, "slow down")
      end)

      assert {:rejected, %{code: "http_429", retry_after_ms: 30_000}} =
               WhatsappCloud.deliver(request())
    end

    test "CH-2, TN-26: a missing credential, number or content is reported without a call" do
      assert {:rejected, %{code: "credentials_missing"}} =
               WhatsappCloud.deliver(request(credentials: nil))

      assert {:rejected, %{code: "sender_missing"}} =
               WhatsappCloud.deliver(request(account: %{"settings" => %{}}))

      assert {:rejected, %{code: "content_invalid"}} =
               WhatsappCloud.deliver(request(content: %{"unexpected" => true}))
    end

    test "T-28: no answer is an uncertain outcome that is never sent again blindly" do
      stub(&Req.Test.transport_error(&1, :timeout))

      assert {:uncertain, _reason} = WhatsappCloud.deliver(request())
      assert {:ok, %{state: :unknown}} = normalize({:uncertain, "timeout"})
    end

    test "DS-11: every vector response decodes to its own code" do
      {:ok, content} = ChannelDeclarations.compose()
      declarations = ChannelDeclarations.new(content, nil)
      {:ok, declaration} = ChannelDeclarations.declaration(declarations, "whatsapp_cloud")

      for %{"response" => response, "raw" => %{"code" => code}} <- declaration["vectors"] do
        assert WhatsappCloud.decode(response).code == code
      end

      assert Relay.Channels.Registry.check(declarations, WhatsappCloud) == :ok
    end
  end
end
