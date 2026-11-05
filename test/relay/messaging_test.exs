defmodule Relay.MessagingTest do
  use Relay.DataCase, async: false

  alias Relay.Messaging
  alias Relay.Messaging.Install
  alias Relay.Repo
  alias RelayTest.TenantFixture

  @outbox "SELECT payload FROM relay.outbox_events WHERE event_type = $1 ORDER BY created_at, id"
  @receipts "SELECT id, duplicate_count, state FROM relay.webhook_receipts WHERE provider = $1"
  @account "SELECT provider, credential_ref_id, verification_state, settings FROM relay.provider_accounts WHERE id = $1"
  @base "https://relay.example.com"

  setup do
    tenant = TenantFixture.tenant!()
    %{scope: tenant.live}
  end

  defp sql!(scope, sql, params) do
    {:ok, rows} = Repo.in_scope(scope, fn _status -> Repo.scoped_query!(sql, params).rows end)
    rows
  end

  defp events(scope, type), do: for([payload] <- sql!(scope, @outbox, [type]), do: payload)

  defp secret_ref!(scope, kind, value) do
    var = "RELAY_TEST_MESSAGING_" <> String.upcase(TenantFixture.random())
    System.put_env(var, value)
    on_exit(fn -> System.delete_env(var) end)
    id = Relay.Id.generate()

    attrs = %{
      id: id,
      kind: kind,
      ref: "${#{var}}",
      ref_version: 1,
      record_digest: TenantFixture.digest()
    }

    {:ok, :created} = Relay.Secrets.register(scope, attrs, TenantFixture.actor())
    id
  end

  defp identity!(scope, channel, kind, app_ref, secret) do
    secret_id = secret_ref!(scope, :channel_identity, Jason.encode!(secret))
    id = Relay.Id.generate()
    attrs = %{id: id, channel: channel, kind: kind, app_ref: app_ref, secret_ref_id: secret_id}

    {:ok, {:created, _version}} =
      Relay.Channels.put_channel_identity(
        scope,
        attrs,
        TenantFixture.digest(),
        TenantFixture.actor()
      )

    id
  end

  defp account!(scope, channel) do
    id = Relay.Id.generate()

    attrs = %{
      id: id,
      channel: channel,
      provider: channel,
      ownership: "shared",
      role: "primary",
      priority: 0,
      processing_countries: ["US"],
      transfer_basis: "adequacy"
    }

    {:ok, {:created, 1}} =
      Relay.Channels.put_account(scope, attrs, TenantFixture.digest(), TenantFixture.actor())

    id
  end

  defp put!(scope, recipient, channel, account, value) do
    {:ok, plan} = Messaging.prepare_target(scope, recipient, channel, account, value)
    {:ok, result} = Repo.in_scope(scope, fn _status -> Messaging.put_target(plan) end)
    result
  end

  defp stub(responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)
    test = self()

    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:call, conn.request_path, body})
      {status, reply} = Agent.get_and_update(agent, fn [next | rest] -> {next, rest} end)
      conn |> Plug.Conn.put_status(status) |> Req.Test.json(reply)
    end
  end

  describe "CH-62 C-22 conversations" do
    test "CH-62, C-22: a conversation is sealed, read back, replaced and disabled with its event",
         %{scope: scope} do
      recipient = TenantFixture.recipient!(scope, nil)
      account = account!(scope, "slack")

      assert {:created, first} = put!(scope, recipient, "slack", account, "U1")

      assert {:ok, %{id: ^first, account_id: ^account, value: value}} =
               Messaging.target(scope, recipient, "slack")

      assert Relay.Redacted.expose(value) == "U1"
      [[ct]] = sql!(scope, "SELECT target_ct FROM relay.messaging_targets WHERE id = $1", [first])
      refute ct =~ "U1"

      assert {:replaced, second} = put!(scope, recipient, "slack", account, "U2")
      assert second != first

      assert {:ok, {:disabled, ^second}} =
               Messaging.disable_target(scope, recipient, "slack", "channel.address_disabled")

      assert :none = Messaging.target(scope, recipient, "slack")

      assert [%{"channel" => "slack", "rule_id" => "channel.address_disabled"}] =
               events(scope, "messaging_target.disabled")
    end

    test "CH-62: a Teams reference needs a Bot Framework host and an account of the channel",
         %{scope: scope} do
      reference = %{
        "service_url" => "https://smba.trafficmanager.net/emea/",
        "conversation_id" => "a:1x"
      }

      assert Messaging.valid_target?("teams", reference)
      refute Messaging.valid_target?("teams", %{reference | "service_url" => "https://x.example"})
      refute Messaging.valid_target?("slack", "has space")
      assert Messaging.valid_target?("discord", "user:123")

      recipient = TenantFixture.recipient!(scope, nil)
      slack = account!(scope, "slack")
      assert {:account_not_found, nil} = put!(scope, recipient, "teams", slack, reference)
    end
  end

  describe "CH-23 collapse by subject" do
    test "CH-23: the subject key is stable, per tenant and per class" do
      tenant = Relay.Id.generate()
      key = Messaging.topic_key(tenant, "order", "o-1", "transactional")
      assert byte_size(key) == 32
      assert key == Messaging.topic_key(tenant, "order", "o-1", "transactional")
      refute key == Messaging.topic_key(tenant, "order", "o-2", "transactional")
      refute key == Messaging.topic_key(tenant, "order", "o-1", "marketing")
      refute key == Messaging.topic_key(Relay.Id.generate(), "order", "o-1", "transactional")
    end

    test "CH-23: without a key or a reference nothing is remembered", %{scope: scope} do
      assert {:ok, :skipped} = Messaging.remember(scope, Relay.Id.generate(), nil, "C1:1", nil)
    end
  end

  describe "CH-62 TN-26 installations" do
    test "CH-62, TN-26: a Slack installation unseals its state, stores the bot token and verifies the workspace",
         %{scope: scope} do
      identity =
        identity!(scope, "slack", "slack_app", "client-1", %{
          "client_secret" => "cs",
          "signing_secret" => "ss"
        })

      {:ok, actor} = Relay.Actor.new(:api_client, "cli-1", "cli-1")
      redirect = @base <> "/v1/messaging_installations/callback"
      attrs = %{channel: "slack", identity_id: identity, redirect_uri: redirect}

      assert {:ok, %{state: "pending", authorize_url: url}} =
               Messaging.start_install(scope, attrs, @base, actor)

      %URI{host: "slack.com", query: query} = URI.parse(url)
      params = URI.decode_query(query)
      assert params["client_id"] == "client-1"

      access = %{
        "ok" => true,
        "access_token" => "xoxb-1",
        "bot_user_id" => "UB",
        "scope" => "chat:write",
        "team" => %{"id" => "T1"}
      }

      plug = stub([{200, access}])

      assert {:ok, %{state: "installed", provider_account_id: account}} =
               Messaging.complete_install(params["state"], "code-1", plug: plug)

      assert_received {:call, "/api/oauth.v2.access", form}
      assert URI.decode_query(form)["client_secret"] == "cs"

      [["slack", credential, "verified", settings]] = sql!(scope, @account, [account])
      assert settings["workspace_id"] == "T1"
      assert {:ok, token} = Relay.Secrets.fetch(scope, credential)
      assert Relay.Redacted.expose(token) == "xoxb-1"
      assert [%{"workspace_id" => "T1"}] = events(scope, "messaging_installation.completed")

      assert {:error, %Relay.Error{code: :messaging_install_state_invalid}} =
               Messaging.complete_install("not-a-state", "code-1", plug: plug)
    end

    test "CH-62: a sealed state expires after ten minutes" do
      attrs = %{
        tenant_id: Relay.Id.generate(),
        environment: "live",
        channel: "slack",
        identity_id: Relay.Id.generate(),
        redirect_uri: @base,
        actor_ref: "cli-1"
      }

      {:ok, state} = Install.seal(attrs, 1_000)
      assert {:ok, %{channel: "slack"}} = Install.unseal(state, 1_000 + 599)
      assert {:error, :invalid} = Install.unseal(state, 1_000 + 601)
    end
  end

  describe "CH-62 WH-49 inbound" do
    test "CH-62, WH-49: a Telegram update is received once, processed into an event and never approves",
         %{scope: scope} do
      identity = identity!(scope, "telegram", "telegram_bot", "bot", %{"bot_token" => "1:a"})
      secret = Relay.Redacted.wrap(Jason.encode!(%{"bot_token" => "1:a"}))
      token = Relay.Redacted.expose(Install.telegram_secret(%{secret: secret}))

      update = %{
        "update_id" => 5,
        "callback_query" => %{
          "from" => %{"id" => 42},
          "data" => "approve",
          "message" => %{"message_id" => 9, "chat" => %{"id" => 42}}
        }
      }

      request = %{
        channel: "telegram",
        tenant_id: scope.tenant_id,
        environment: :live,
        identity_id: identity,
        raw: Jason.encode!(update),
        headers: [{"x-telegram-bot-api-secret-token", token}],
        content_type: "application/json",
        authorization: nil
      }

      assert {:ok, 200, %{}} = Messaging.accept(request)
      assert {:ok, 200, %{}} = Messaging.accept(request)
      [[receipt, 1, "received"]] = sql!(scope, @receipts, ["telegram"])

      bad = %{request | headers: [{"x-telegram-bot-api-secret-token", "wrong"}]}
      assert {:error, :unauthorized} = Messaging.accept(bad)

      assert :ok = Messaging.process(scope, receipt, identity)
      [[^receipt, 1, "processed"]] = sql!(scope, @receipts, ["telegram"])

      assert [event] = events(scope, "messaging_interaction.received")
      assert %{"channel" => "telegram", "kind" => "action", "action" => "approve"} = event
      refute Map.has_key?(event, "approved")
      assert :ok = Messaging.process(scope, receipt, identity)
      assert [_one] = events(scope, "messaging_interaction.received")
    end

    test "CH-62: an unknown channel identity is not found", %{scope: scope} do
      request = %{
        channel: "slack",
        tenant_id: scope.tenant_id,
        environment: :live,
        identity_id: Relay.Id.generate(),
        raw: "{}",
        headers: [],
        content_type: "application/json",
        authorization: nil
      }

      assert {:error, :not_found} = Messaging.accept(request)
    end
  end

  describe "CH-4 adapter versions" do
    test "CH-4: every adapter lists its version and no warning without a deprecation",
         %{scope: scope} do
      assert {:ok, adapters} = Messaging.adapters(scope)
      providers = Enum.map(adapters, & &1.provider)
      for p <- ~w(slack teams telegram discord), do: assert(p in providers)

      for adapter <- adapters do
        assert adapter.adapter_version =~ ~r/^\d+\.\d+\.\d+$/
        assert adapter.warning == (adapter.deprecations != [] and adapter.in_use)
      end
    end
  end
end
