defmodule Relay.Channels.MessagingAdaptersTest do
  use ExUnit.Case, async: true

  alias Relay.ChannelDeclarations
  alias Relay.Channels.Discord
  alias Relay.Channels.Request
  alias Relay.Channels.Slack
  alias Relay.Channels.Teams
  alias Relay.Channels.Telegram

  @teams_url "https://smba.trafficmanager.net/emea/"
  @teams_target ~s({"service_url":"#{@teams_url}","conversation_id":"a:1x"})
  @teams_identity ~s({"app_id":"app-1","app_password":"secret","tenant_id":"tenant-1"})

  defp request(provider, target, opts \\ []) do
    rendered = Jason.encode!(%{"channel" => provider, "output" => %{"text" => "Build failed"}})

    %Request{
      scope: Relay.Scope.new!(Relay.Id.generate(), :live),
      delivery_id: Relay.Id.generate(),
      attempt_no: 1,
      channel: provider,
      provider: provider,
      idempotency_key: Keyword.get(opts, :key, "dlv-key-1"),
      target: %{kind: :address, id: nil, value: Relay.Redacted.wrap(target)},
      timeout_ms: 1000,
      content: Keyword.get(opts, :content, rendered),
      credentials: Keyword.get(opts, :credentials, Relay.Redacted.wrap("token-1")),
      update: Keyword.get(opts, :update)
    }
  end

  defp stub(test_pid, responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)

    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:call, conn.method, conn.request_path, conn.req_headers, body})
      reply = Agent.get_and_update(agent, fn [next | rest] -> {next, rest} end)
      respond(conn, reply)
    end
  end

  defp respond(conn, {:transport, reason}), do: Req.Test.transport_error(conn, reason)

  defp respond(conn, {status, body, headers}) do
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_resp_header(c, k, v) end)
    conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
  end

  defp respond(conn, {status, body}), do: respond(conn, {status, body, []})

  defp normalized(provider, result) do
    {:ok, content} = ChannelDeclarations.compose()
    declarations = ChannelDeclarations.new(content, nil)
    {:ok, outcome} = Relay.Channels.normalize(declarations, provider, provider, result)
    outcome
  end

  describe "CH-62 Slack" do
    test "CH-62: chat.postMessage under the bot token returns the conversation and timestamp" do
      plug = stub(self(), [{200, %{"ok" => true, "channel" => "D1", "ts" => "1700.1"}}])

      assert {:accepted, %{provider_message_id: "D1:1700.1"}} =
               Slack.deliver(request("slack", "U1"), plug: plug)

      assert_received {:call, "POST", "/api/chat.postMessage", headers, body}
      assert {"authorization", "Bearer token-1"} in headers
      assert %{"channel" => "U1", "text" => "Build failed"} = Jason.decode!(body)
      refute Map.has_key?(Jason.decode!(body), "blocks")
    end

    test "CH-62, INV-29: a link renders as a URL button, never as an action that approves" do
      fields = %{"text" => "Approve?", "action_url" => "https://access.example/a/1"}
      message = Slack.message(fields)
      [_section, %{"elements" => [button]}] = message["blocks"]
      assert button["url"] == "https://access.example/a/1"
      refute Map.has_key?(button, "value")
      assert Slack.message(%{"text" => "x", "action_url" => "http://plain"}) == %{"text" => "x"}
    end

    test "CH-23: a message of the same subject updates, and a gone message is posted again" do
      plug =
        stub(self(), [
          {200, %{"ok" => false, "error" => "message_not_found"}},
          {200, %{"ok" => true, "channel" => "C1", "ts" => "2.2"}}
        ])

      assert {:accepted, %{provider_message_id: "C1:2.2"}} =
               Slack.deliver(request("slack", "C1", update: "C1:1.1"), plug: plug)

      assert_received {:call, "POST", "/api/chat.update", _headers, body}
      assert %{"channel" => "C1", "ts" => "1.1"} = Jason.decode!(body)
      assert_received {:call, "POST", "/api/chat.postMessage", _headers, _body}
    end

    test "CH-7, CH-9: a Slack error is the raw code and 429 carries Retry-After" do
      plug = stub(self(), [{200, %{"ok" => false, "error" => "channel_not_found"}}])

      assert {:rejected, %{code: "channel_not_found"} = raw} =
               Slack.deliver(request("slack", "C9"), plug: plug)

      assert %{failure_class: "permanent_target"} = normalized("slack", {:rejected, raw})

      limited = {429, %{"ok" => false, "error" => "ratelimited"}, [{"retry-after", "30"}]}
      plug = stub(self(), [limited])

      assert {:rejected, %{code: "ratelimited", retry_after_ms: 30_000}} =
               Slack.deliver(request("slack", "C9"), plug: plug)
    end

    test "T-28: no connection is not sent and a lost answer is uncertain" do
      plug = stub(self(), [{:transport, :econnrefused}])
      assert {:not_sent, "econnrefused"} = Slack.deliver(request("slack", "C1"), plug: plug)

      plug = stub(self(), [{:transport, :timeout}])
      assert {:uncertain, "timeout"} = Slack.deliver(request("slack", "C1"), plug: plug)
    end

    test "TN-26: a request without a credential is an auth failure" do
      result = Slack.deliver(request("slack", "C1", credentials: nil), [])
      assert {:rejected, %{code: "credential_missing"}} = result
      assert %{failure_class: "auth"} = normalized("slack", result)
    end
  end

  describe "CH-62 Telegram" do
    test "CH-62: sendMessage returns the chat and message" do
      sent = %{"ok" => true, "result" => %{"message_id" => 7, "chat" => %{"id" => 42}}}
      plug = stub(self(), [{200, sent}])

      assert {:accepted, %{provider_message_id: "42:7"}} =
               Telegram.deliver(request("telegram", "42"), plug: plug)

      assert_received {:call, "POST", "/bottoken-1/sendMessage", _headers, body}
      assert %{"chat_id" => "42", "text" => "Build failed"} = Jason.decode!(body)
    end

    test "CH-62: a blocked bot is a permanent target failure" do
      body = %{
        "ok" => false,
        "error_code" => 403,
        "description" => "Forbidden: bot was blocked by the user"
      }

      plug = stub(self(), [{403, body}])
      result = Telegram.deliver(request("telegram", "42"), plug: plug)
      assert {:rejected, %{code: "403_bot_blocked"}} = result
      assert %{failure_class: "permanent_target"} = normalized("telegram", result)
    end

    test "CH-8: an unknown description is unmapped and classified unknown" do
      body = %{"ok" => false, "error_code" => 400, "description" => "Bad Request: something new"}
      plug = stub(self(), [{400, body}])
      result = Telegram.deliver(request("telegram", "42"), plug: plug)
      assert {:rejected, %{code: "http_400"}} = result
      assert %{failure_class: "unknown", unknown_code?: true} = normalized("telegram", result)
    end

    test "CH-23: an unchanged edit is the same message" do
      body = %{
        "ok" => false,
        "error_code" => 400,
        "description" => "Bad Request: message is not modified"
      }

      plug = stub(self(), [{400, body}])

      assert {:accepted, %{provider_message_id: "42:7"}} =
               Telegram.deliver(request("telegram", "42", update: "42:7"), plug: plug)

      assert_received {:call, "POST", "/bottoken-1/editMessageText", _headers, _body}
    end

    test "CH-9: 429 carries the retry_after of the answer" do
      body = %{
        "ok" => false,
        "error_code" => 429,
        "description" => "Too Many Requests: retry after 5",
        "parameters" => %{"retry_after" => 5}
      }

      plug = stub(self(), [{429, body}])

      assert {:rejected, %{code: "429_too_many_requests", retry_after_ms: 5000}} =
               Telegram.deliver(request("telegram", "42"), plug: plug)
    end
  end

  describe "CH-62 Discord" do
    test "INV-13: the message carries a nonce of the idempotency key and is enforced" do
      plug = stub(self(), [{200, %{"id" => "m1", "channel_id" => "c1"}}])

      assert {:accepted, %{provider_message_id: "c1:m1"}} =
               Discord.deliver(request("discord", "c1"), plug: plug)

      assert_received {:call, "POST", "/api/v10/channels/c1/messages", headers, body}
      assert {"authorization", "Bot token-1"} in headers
      decoded = Jason.decode!(body)
      assert decoded["nonce"] == Discord.nonce("dlv-key-1")
      assert byte_size(decoded["nonce"]) == 25
      assert decoded["enforce_nonce"] == true
      assert decoded["allowed_mentions"] == %{"parse" => []}
    end

    test "CH-62: a user target opens the direct message channel first" do
      dm = {200, %{"id" => "dm1", "type" => 1}}
      plug = stub(self(), [dm, {200, %{"id" => "m2", "channel_id" => "dm1"}}])

      assert {:accepted, %{provider_message_id: "dm1:m2"}} =
               Discord.deliver(request("discord", "user:u1"), plug: plug)

      assert_received {:call, "POST", "/api/v10/users/@me/channels", _headers, body}
      assert Jason.decode!(body) == %{"recipient_id" => "u1"}
      assert_received {:call, "POST", "/api/v10/channels/dm1/messages", _headers, _body}
    end

    test "CH-7: a Discord JSON error code is the raw code" do
      plug = stub(self(), [{403, %{"code" => 50_007, "message" => "Cannot send messages"}}])
      result = Discord.deliver(request("discord", "c1"), plug: plug)
      assert {:rejected, %{code: "50007"}} = result
      assert %{failure_class: "permanent_target"} = normalized("discord", result)
    end

    test "CH-23: an edit of an unknown message posts again" do
      gone = {404, %{"code" => 10_008, "message" => "Unknown Message"}}
      plug = stub(self(), [gone, {200, %{"id" => "m3", "channel_id" => "c1"}}])

      assert {:accepted, %{provider_message_id: "c1:m3"}} =
               Discord.deliver(request("discord", "c1", update: "c1:m1"), plug: plug)

      assert_received {:call, "PATCH", "/api/v10/channels/c1/messages/m1", _headers, _body}
    end
  end

  describe "CH-62 Teams" do
    test "CH-62, TN-26: a token for the call, then the activity to the stored reference" do
      plug =
        stub(self(), [
          {200, %{"access_token" => "bf-token", "expires_in" => 3599}},
          {201, %{"id" => "act-1"}}
        ])

      req = request("teams", @teams_target, credentials: Relay.Redacted.wrap(@teams_identity))
      assert {:accepted, %{provider_message_id: "act-1"}} = Teams.deliver(req, plug: plug)

      assert_received {:call, "POST", "/tenant-1/oauth2/v2.0/token", _headers, form}
      assert URI.decode_query(form)["scope"] == "https://api.botframework.com/.default"
      assert_received {:call, "POST", "/emea/v3/conversations/a%3A1x/activities", headers, body}
      assert {"authorization", "Bearer bf-token"} in headers
      assert %{"type" => "message", "text" => "Build failed"} = Jason.decode!(body)
    end

    test "CH-62: only a Bot Framework service URL is called" do
      target = ~s({"service_url":"https://evil.example/","conversation_id":"a:1"})
      req = request("teams", target, credentials: Relay.Redacted.wrap(@teams_identity))
      assert {:rejected, %{code: "target_invalid"}} = Teams.deliver(req, [])
      plain = ~s({"service_url":"http://smba.trafficmanager.net","conversation_id":"a"})
      assert :error = Teams.reference(plain)
      assert {:ok, _} = Teams.reference(@teams_target)
    end

    test "CH-7: a failed token request sent nothing and is classified by its error" do
      plug = stub(self(), [{401, %{"error" => "invalid_client"}}])
      req = request("teams", @teams_target, credentials: Relay.Redacted.wrap(@teams_identity))
      result = Teams.deliver(req, plug: plug)
      assert {:rejected, %{code: "token_invalid_client"}} = result
      assert %{failure_class: "auth"} = normalized("teams", result)
    end

    test "CH-62, INV-29: a link is an Adaptive Card with Action.OpenUrl only" do
      fields = %{"text" => "Approve?", "action_url" => "https://access.example/1"}
      activity = Teams.activity(fields)
      [%{"content" => card}] = activity["attachments"]
      assert [%{"type" => "Action.OpenUrl"}] = card["actions"]
    end

    test "CH-7: a Bot Framework error code is the raw code" do
      plug =
        stub(self(), [
          {200, %{"access_token" => "bf-token"}},
          {403, %{"error" => %{"code" => "ConversationBlockedByUser", "message" => "blocked"}}}
        ])

      req = request("teams", @teams_target, credentials: Relay.Redacted.wrap(@teams_identity))
      result = Teams.deliver(req, plug: plug)
      assert {:rejected, %{code: "ConversationBlockedByUser"}} = result
      assert %{failure_class: "permanent_target"} = normalized("teams", result)
    end
  end

  describe "CH-62 declarations" do
    test "CH-62: messaging channels declare no delivery or read receipts and update in place" do
      {:ok, content} = ChannelDeclarations.compose()
      declarations = ChannelDeclarations.new(content, nil)

      for provider <- ~w(slack teams telegram discord) do
        {:ok, declaration} = ChannelDeclarations.declaration(declarations, provider)
        flags = declaration["capabilities"][provider]
        assert flags["delivery_receipts"] == false
        assert flags["read_receipts"] == false
        assert flags["update"] == true
        assert declaration["paid_channels"] == []
        assert declaration["adapter_version"] =~ ~r/^\d+\.\d+\.\d+$/
        assert :ok = ChannelDeclarations.gate(declarations, provider)
      end

      {:ok, telegram} = ChannelDeclarations.declaration(declarations, "telegram")
      assert telegram["inbound_verification"]["authenticity"] == "unverifiable"
      assert telegram["capabilities"]["telegram"]["business_initiated"] == false
      {:ok, teams} = ChannelDeclarations.declaration(declarations, "teams")
      assert [%{"api" => "Office 365 Connectors and incoming webhooks"}] = teams["deprecations"]
    end
  end
end
