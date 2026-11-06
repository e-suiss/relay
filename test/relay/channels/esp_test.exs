defmodule Relay.Channels.EspTest do
  use ExUnit.Case, async: true

  alias Relay.ChannelDeclarations
  alias Relay.Channels.Email.Esp
  alias Relay.Channels.Mailgun
  alias Relay.Channels.Postmark
  alias Relay.Channels.Request
  alias Relay.Channels.Sendgrid
  alias Relay.Channels.Ses

  @link "https://access.example/verify?t=abc123"
  @streams %{
    "transactional" => %{
      "from" => "security@sender.example",
      "domain" => "sender.example",
      "selector" => "tx2026",
      "return_path_domain" => "bounce.sender.example",
      "ip_pool" => "tx-pool",
      "queue" => "tx"
    },
    "marketing" => %{
      "from" => "news@news.sender.example",
      "domain" => "news.sender.example",
      "selector" => "mk2026",
      "return_path_domain" => "bounce.news.sender.example",
      "ip_pool" => "mk-pool",
      "queue" => "mk"
    }
  }

  defp request(provider, credentials, settings \\ %{}) do
    %Request{
      scope: Relay.Scope.new!(Relay.Id.generate(), :live),
      delivery_id: Relay.Id.generate(),
      attempt_no: 1,
      channel: "email",
      provider: provider,
      idempotency_key: "key-1",
      target: %{kind: :address, id: nil, value: Relay.Redacted.wrap("reader@example.com")},
      timeout_ms: 5_000,
      content: %{
        "subject" => "Confirm your address",
        "text" => "Confirm: " <> @link,
        "html" => ~s(<p><a href="#{@link}">Confirm</a></p>)
      },
      credentials: credentials && Relay.Redacted.wrap(credentials),
      account: %{
        "id" => Relay.Id.generate(),
        "settings" => Map.merge(%{"streams" => @streams}, settings)
      },
      message_class: "security"
    }
  end

  defp stub(fun), do: Req.Test.stub(Esp, fun)

  defp body(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    body
  end

  defp header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [value | _rest] -> value
      [] -> nil
    end
  end

  defp declarations do
    {:ok, content} = ChannelDeclarations.compose()
    ChannelDeclarations.new(content, nil)
  end

  defp class(provider, result) do
    {:ok, outcome} = Relay.Channels.normalize(declarations(), provider, "email", result)
    outcome.failure_class
  end

  describe "CH-3 CH-34 Postmark" do
    test "CH-3, CH-43, CH-76: a message goes out untracked with its correlation metadata" do
      request = request("postmark", %{"server_token" => "pm-token"})
      parent = self()

      stub(fn conn ->
        token = header(conn, "x-postmark-server-token")
        send(parent, {:sent, conn.request_path, token, body(conn)})
        Req.Test.json(conn, %{"ErrorCode" => 0, "MessageID" => "pm-1", "Message" => "OK"})
      end)

      assert {:accepted, %{provider_message_id: "pm-1"}} = Postmark.deliver(request)
      assert_received {:sent, "/email", "pm-token", json}
      sent = Jason.decode!(json)

      assert sent["TrackOpens"] == false
      assert sent["TrackLinks"] == "None"
      assert sent["MessageStream"] == "outbound"
      assert sent["TextBody"] == "Confirm: " <> @link
      assert sent["Metadata"]["relay_delivery_id"] == Relay.Id.to_string(request.delivery_id)
      names = Enum.map(sent["Headers"], & &1["Name"])
      assert "Feedback-ID" in names
      assert "Message-ID" in names
    end

    test "CH-7: an inactive recipient is a permanent target failure" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(422)
        |> Req.Test.json(%{"ErrorCode" => 406, "Message" => "inactive"})
      end)

      result = Postmark.deliver(request("postmark", %{"server_token" => "pm-token"}))
      assert {:rejected, %{code: "postmark:406", status: 422}} = result
      assert class("postmark", result) == "permanent_target"
    end

    test "T-28: an uncertain send is resolved by its metadata" do
      request = request("postmark", %{"server_token" => "pm-token"})
      id = Relay.Id.to_string(request.delivery_id)

      stub(fn conn ->
        assert conn.method == "GET"
        assert URI.decode_query(conn.query_string)["metadata_relay_delivery_id"] == id
        Req.Test.json(conn, %{"TotalCount" => 1, "Messages" => [%{"MessageID" => "pm-9"}]})
      end)

      assert {:accepted, %{provider_message_id: "pm-9"}} = Postmark.query(request)

      stub(fn conn -> Req.Test.json(conn, %{"TotalCount" => 0, "Messages" => []}) end)
      assert Postmark.query(request) == :not_received
    end

    test "TN-26: a request without a credential is refused before any call" do
      assert {:rejected, %{code: "credential_invalid"}} =
               Postmark.deliver(request("postmark", nil))
    end
  end

  describe "CH-3 CH-34 SendGrid" do
    test "CH-3, CH-43: a message goes out with tracking off and its custom argument" do
      request = request("sendgrid", %{"api_key" => "SG.key"})
      parent = self()

      stub(fn conn ->
        send(parent, {:sent, conn.host, header(conn, "authorization"), body(conn)})

        conn
        |> Plug.Conn.put_resp_header("x-message-id", "sg-1")
        |> Plug.Conn.send_resp(202, "")
      end)

      assert {:accepted, %{provider_message_id: "sg-1"}} = Sendgrid.deliver(request)
      assert_received {:sent, "api.sendgrid.com", "Bearer SG.key", json}
      sent = Jason.decode!(json)

      assert sent["tracking_settings"]["click_tracking"]["enable"] == false
      assert sent["tracking_settings"]["open_tracking"]["enable"] == false
      assert sent["ip_pool_name"] == "tx-pool"
      [personalization] = sent["personalizations"]

      assert personalization["custom_args"]["relay_delivery_id"] ==
               Relay.Id.to_string(request.delivery_id)

      assert Map.has_key?(sent["headers"], "Feedback-ID")
    end

    test "CH-9: a 429 carries the provider's Retry-After" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "30")
        |> Plug.Conn.send_resp(429, "{}")
      end)

      result = Sendgrid.deliver(request("sendgrid", %{"api_key" => "SG.key"}))
      assert {:rejected, %{code: "http_429", retry_after_ms: 30_000}} = result
      assert class("sendgrid", result) == "transient"
    end

    test "CH-3: the EU region goes to SendGrid's EU host" do
      parent = self()

      stub(fn conn ->
        send(parent, {:host, conn.host})
        Plug.Conn.send_resp(conn, 202, "")
      end)

      settings = %{"sendgrid" => %{"region" => "eu"}}
      request = request("sendgrid", %{"api_key" => "SG.key"}, settings)
      assert {:accepted, _info} = Sendgrid.deliver(request)
      assert_received {:host, "api.eu.sendgrid.com"}
    end
  end

  describe "CH-3 CH-34 Mailgun" do
    test "CH-3, CH-43: a message goes out as form fields with tracking off" do
      request = request("mailgun", %{"api_key" => "mg-key"})
      parent = self()

      stub(fn conn ->
        send(parent, {:sent, conn.request_path, header(conn, "authorization"), body(conn)})
        Req.Test.json(conn, %{"id" => "<mg-1@sender.example>", "message" => "Queued"})
      end)

      assert {:accepted, %{provider_message_id: "<mg-1@sender.example>"}} =
               Mailgun.deliver(request)

      assert_received {:sent, "/v3/sender.example/messages", auth, form}
      assert auth == "Basic " <> Base.encode64("api:mg-key")
      fields = URI.decode_query(form)

      assert fields["o:tracking"] == "no"
      assert fields["o:tracking-clicks"] == "no"
      assert fields["v:relay_delivery_id"] == Relay.Id.to_string(request.delivery_id)
      assert fields["text"] == "Confirm: " <> @link
      assert String.starts_with?(fields["h:Feedback-ID"], "security:security:")
    end

    test "CH-7: an unknown domain is a sender configuration failure" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 404, ~s({"message":"Domain not found"})) end)
      result = Mailgun.deliver(request("mailgun", %{"api_key" => "mg-key"}))
      assert {:rejected, %{code: "http_404"}} = result
      assert class("mailgun", result) == "sender_config"
    end
  end

  describe "CH-3 CH-34 SES" do
    @ses %{"ses" => %{"region" => "eu-central-1", "configuration_set" => "relay"}}

    test "CH-3: a raw message goes out signed with SigV4 and tagged with its delivery" do
      credentials = %{"access_key_id" => "AKIDEXAMPLE", "secret_access_key" => "secret"}
      request = request("ses", credentials, @ses)
      parent = self()

      stub(fn conn ->
        send(parent, {:sent, conn.host, header(conn, "authorization"), body(conn)})
        Req.Test.json(conn, %{"MessageId" => "ses-1"})
      end)

      assert {:accepted, %{provider_message_id: "ses-1"}} = Ses.deliver(request)
      assert_received {:sent, "email.eu-central-1.amazonaws.com", authorization, json}
      assert authorization =~ ~r{\AAWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/\d+/eu-central-1/ses/}
      sent = Jason.decode!(json)

      assert sent["ConfigurationSetName"] == "relay"
      assert [%{"Name" => "relay_delivery_id"}] = sent["EmailTags"]
      mime = Base.decode64!(sent["Content"]["Raw"]["Data"])
      assert mime =~ "Feedback-ID: security:security:"
      refute mime =~ "DKIM-Signature"
    end

    test "CH-7: an SES error type is its raw code" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-amzn-errortype", "MessageRejected:http://internal")
        |> Plug.Conn.send_resp(400, ~s({"message":"Email address is not verified."}))
      end)

      credentials = %{"access_key_id" => "AKIDEXAMPLE", "secret_access_key" => "secret"}
      result = Ses.deliver(request("ses", credentials, @ses))
      assert {:rejected, %{code: "ses:MessageRejected", status: 400}} = result
      assert class("ses", result) == "permanent_content"
    end

    test "CH-47: the event queue is read and a message deleted through SQS" do
      settings = %{
        "queue_url" => "https://sqs.eu-central-1.amazonaws.com/123456789012/relay-events",
        "topic_arn" => "arn:aws:sns:eu-central-1:123456789012:relay"
      }

      credentials = Relay.Redacted.wrap(%{"access_key_id" => "AKID", "secret_access_key" => "s"})
      parent = self()

      stub(fn conn ->
        send(parent, {:sqs, header(conn, "x-amz-target"), Jason.decode!(body(conn))})

        Req.Test.json(conn, %{
          "Messages" => [%{"MessageId" => "q1", "ReceiptHandle" => "r1", "Body" => "{}"}]
        })
      end)

      assert {:ok, [%{"ReceiptHandle" => "r1"}]} =
               Ses.receive_messages(settings, credentials, wait_s: 0)

      assert_received {:sqs, "AmazonSQS.ReceiveMessage", %{"QueueUrl" => queue}}
      assert queue == settings["queue_url"]

      assert :ok = Ses.delete_message(settings, credentials, "r1")
      assert_received {:sqs, "AmazonSQS.DeleteMessage", %{"ReceiptHandle" => "r1"}}
    end
  end

  describe "T-28 transport failures" do
    test "T-28: a refused connection is not sent and a timeout is uncertain" do
      request = request("sendgrid", %{"api_key" => "SG.key"})

      stub(&Req.Test.transport_error(&1, :econnrefused))
      assert {:not_sent, "econnrefused"} = Sendgrid.deliver(request)

      stub(&Req.Test.transport_error(&1, :timeout))
      assert {:uncertain, "transport_error"} = Sendgrid.deliver(request)
    end
  end
end
