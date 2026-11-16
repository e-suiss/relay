defmodule Relay.Webhooks.DestinationsEngineTest do
  use Relay.DataCase, async: false

  import RelayTest.WebhookDestinations

  alias Relay.Webhooks.EngineStore
  alias RelayTest.DestinationFixture, as: Net
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.ScriptedSocket
  alias RelayTest.TenantFixture

  @url "https://hooks.example.com/relay"
  @token_url "https://login.example.com/oauth/token"
  @token ~s({"access_token":"tok-1","token_type":"Bearer","expires_in":3600})
  @secret "destination-secret-0123456789"
  @accepted ~s({"FailedEntryCount":0,"Entries":[{"EventId":"11710aed"}]})
  @nats_info %{"server_id" => "NTEST", "tls_required" => true, "headers" => true}
  @topic "arn:aws:sns:eu-central-1:123456789012:orders"
  @bus "arn:aws:events:eu-central-1:123456789012:event-bus/orders"
  @namespace "shop.servicebus.windows.net"
  @grid "https://orders.westeurope-1.eventgrid.azure.net/api/events"

  setup do
    previous = install()
    on_exit(fn -> Application.put_env(:relay, Relay.Webhooks, previous) end)
    tenant = TenantFixture.tenant!()
    %{tenant: tenant, scope: tenant.live, token: F.token(tenant.live)}
  end

  defp secret!(ctx, value \\ @secret) do
    credential = credential!(ctx.scope, value)
    on_exit(fn -> System.delete_env(credential.var) end)
    credential.id
  end

  defp allow_ports(ports) do
    config = Application.get_env(:relay, Relay.Webhooks, [])
    Application.put_env(:relay, Relay.Webhooks, Keyword.put(config, :extra_ports, ports))
  end

  defp oauth2(ctx) do
    endpoint!(ctx, %{
      "kind" => "https",
      "url" => @url,
      "auth" => "oauth2_client_credentials",
      "token_url" => @token_url,
      "client_id" => "relay-client",
      "scopes" => ["hooks.write", "hooks.read"],
      "credential_ref_id" => secret!(ctx)
    })
  end

  defp hosts(requests), do: Enum.map(requests, fn {connection, _request} -> connection.host end)

  defp nats_server do
    state = %{inbox: nil}
    ScriptedSocket.serve("nats.example.com", &nats/2, state)
  end

  defp nats(:open, state), do: {["INFO ", Jason.encode!(@nats_info), "\r\n"], state}
  defp nats(:upgrade, state), do: {"", state}
  defp nats({:data, data}, state), do: nats_commands(data, [], state)

  defp nats_commands("", answers, state), do: {answers, state}

  defp nats_commands(data, answers, state) do
    [line, rest] = :binary.split(data, "\r\n")
    {answer, rest, state} = nats_command(String.split(line, " ", parts: 2), rest, state)
    nats_commands(rest, [answers, answer], state)
  end

  defp nats_command(["CONNECT", json], rest, state) do
    send(self(), {:nats, :connect, Jason.decode!(json)})
    {"", rest, state}
  end

  defp nats_command(["SUB", arguments], rest, state) do
    [inbox, "1"] = String.split(arguments, " ")
    {"", rest, %{state | inbox: inbox}}
  end

  defp nats_command(["PING"], rest, state), do: {"PONG\r\n", rest, state}
  defp nats_command(["PONG"], rest, state), do: {"", rest, state}

  defp nats_command(["HPUB", arguments], rest, state) do
    [subject, _reply, header_size, total_size] = String.split(arguments, " ")
    header_size = String.to_integer(header_size)
    payload_size = String.to_integer(total_size) - header_size
    <<_block::binary-size(^header_size), rest::binary>> = rest
    <<payload::binary-size(^payload_size), "\r\n", rest::binary>> = rest
    send(self(), {:nats, :publish, subject, payload})
    ack = ~s({"stream":"EVENTS","seq":42})
    size = Integer.to_string(byte_size(ack))
    {["MSG ", state.inbox, " 1 ", size, "\r\n", ack, "\r\n"], rest, state}
  end

  describe "WH-17 WH-19 HTTPS endpoint authentication" do
    test "WH-17, WH-19, WH-43: an OAuth2 endpoint gets its token through the egress boundary once, keeps it in a bounded cache and sends it as a bearer",
         ctx do
      endpoint = oauth2(ctx)
      Net.answer("login.example.com", Net.response(200, @token))
      {_event, first} = message!(ctx, endpoint)
      {_other, second} = message!(ctx, endpoint)
      _ = jobs()

      assert {:attempted, :delivered} = attempt(ctx, first)
      assert [{%{host: "login.example.com", port: 443}, fetch}, {_hook, delivery}] = sent()
      assert %{method: "POST", path: "/oauth/token"} = fetch
      assert fetch.body == "grant_type=client_credentials&scope=hooks.write+hooks.read"
      basic = "Basic " <> Base.encode64("relay-client:" <> @secret)
      assert Net.header(fetch, "authorization") == basic
      assert Net.header(delivery, "authorization") == "Bearer tok-1"
      assert is_binary(Net.header(delivery, "webhook-signature"))

      assert {:attempted, :delivered} = attempt(ctx, second)
      assert [{%{host: "hooks.example.com"}, again}] = sent()
      assert Net.header(again, "authorization") == "Bearer tok-1"

      logged = attempts(ctx, first) ++ attempts(ctx, second)
      refute inspect(logged) =~ "tok-1"
      refute inspect(logged) =~ @secret
      stored = read(ctx, fn -> EngineStore.endpoint(endpoint.uuid) end)
      refute inspect(stored) =~ @secret
    end

    test "WH-19: a token the endpoint refuses is dropped, so the next attempt fetches a new one",
         ctx do
      endpoint = oauth2(ctx)
      Net.answer("login.example.com", Net.response(200, @token))
      Net.answer("hooks.example.com", Net.response(401, "expired"))
      {_event, message} = message!(ctx, endpoint)
      _ = jobs()

      assert {:attempted, :scheduled} = attempt(ctx, message)
      assert hosts(sent()) == ["login.example.com", "hooks.example.com"]

      Net.answer("hooks.example.com", Net.response(200))
      assert {:attempted, :delivered} = attempt(ctx, message, clock: at(60))
      assert hosts(sent()) == ["login.example.com", "hooks.example.com"]
    end

    test "WH-19, WH-43: a token endpoint that fails or resolves to a blocked address makes no delivery and names no secret",
         ctx do
      endpoint = oauth2(ctx)
      Net.answer("login.example.com", Net.response(500, "down"))
      {_event, message} = message!(ctx, endpoint)
      {_other, blocked} = message!(ctx, endpoint)
      _ = jobs()

      assert {:attempted, :scheduled} = attempt(ctx, message)
      assert hosts(sent()) == ["login.example.com"]
      assert [%{"failure_code" => "credentials_unavailable"} = row] = attempts(ctx, message)
      refute inspect(row) =~ @secret

      Net.resolve("login.example.com", {:ok, [{169, 254, 169, 254}]})
      assert {:attempted, :dead_lettered} = attempt(ctx, blocked)
      assert sent() == []
      assert [%{"failure_code" => "address_blocked"}] = attempts(ctx, blocked)
    end

    test "WH-17, WH-19: a mutual TLS endpoint presents its certificate with the private key its credential holds",
         ctx do
      %{cert: der, key: key} = :public_key.pkix_test_root_cert(~c"relay webhook client", [])
      certificate = :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
      type = elem(key, 0)
      private = :public_key.pem_encode([:public_key.pem_entry_encode(type, key)])

      endpoint =
        endpoint!(ctx, %{
          "kind" => "https",
          "url" => @url,
          "auth" => "mtls",
          "client_certificate" => certificate,
          "credential_ref_id" => secret!(ctx, private)
        })

      {_event, message} = message!(ctx, endpoint)
      assert {:attempted, :delivered} = attempt(ctx, message)
      assert [{%{host: "hooks.example.com"} = connection, request}] = sent()
      assert %{certificate: [^der], key: presented} = connection.client_certificate
      assert Relay.Redacted.redacted?(presented)
      refute inspect(connection) =~ "PRIVATE KEY"
      assert Net.header(request, "authorization") == nil

      stored = read(ctx, fn -> EngineStore.endpoint(endpoint.uuid) end)
      refute inspect(stored) =~ "PRIVATE KEY"
      refute inspect(attempts(ctx, message)) =~ "PRIVATE KEY"
    end

    test "WH-19: a destination names only a registered destination credential", ctx do
      destination = %{
        "kind" => "https",
        "url" => @url,
        "auth" => "oauth2_client_credentials",
        "token_url" => @token_url,
        "client_id" => "relay-client"
      }

      body = fn id ->
        %{
          "use" => "relay_events",
          "destination" => Map.put(destination, "credential_ref_id", id),
          "event_types" => []
        }
      end

      unknown = Relay.ExternalId.encode("sec", Relay.Id.generate())
      refused = F.body(F.request(:post, "/v1/webhook_endpoints", ctx.token, body.(unknown)), 422)
      assert refused["code"] == "webhook_credential_not_found"

      var = "RELAY_TEST_WEBHOOK_OTHER_" <> String.upcase(TenantFixture.random())
      System.put_env(var, "a-provider-secret")
      on_exit(fn -> System.delete_env(var) end)

      {:ok, other} =
        Relay.Secrets.register_ref(
          ctx.scope,
          :provider_credential,
          "${" <> var <> "}",
          1,
          TenantFixture.digest(),
          TenantFixture.actor()
        )

      foreign = Relay.ExternalId.encode("sec", other.id)
      refused = F.body(F.request(:post, "/v1/webhook_endpoints", ctx.token, body.(foreign)), 422)
      assert refused["code"] == "webhook_credential_not_found"
      assert Relay.Webhooks.Live.credential(ctx.scope, other.id) == nil

      plain = Map.put(destination, "client_secret", "in-the-clear")
      body = %{"use" => "relay_events", "destination" => plain, "event_types" => []}
      F.body(F.request(:post, "/v1/webhook_endpoints", ctx.token, body), 422)
    end
  end

  describe "WH-17 WH-18 cloud destinations through the engine" do
    test "WH-17, WH-18, WH-19: every cloud kind is written with its credential resolved from the reference and logged without it",
         ctx do
      key = :public_key.generate_key({:rsa, 2048, 65_537})
      pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

      account =
        Jason.encode!(%{
          "type" => "service_account",
          "client_email" => "relay@shop-prod-1.iam.gserviceaccount.com",
          "private_key_id" => "key-1",
          "private_key" => pem
        })

      access = Base.encode64(:crypto.hash(:sha256, "service bus test key"))

      fields = [
        "Endpoint=sb://shop.servicebus.windows.net/",
        "SharedAccessKeyName=relay-send",
        "SharedAccessKey=" <> access
      ]

      connection = Enum.join(fields, ";")

      aws = %{"region" => "eu-central-1", "access_key_id" => "AKIDEXAMPLE0000000"}
      queue = "https://sqs.eu-central-1.amazonaws.com/123456789012/orders"
      sqs = Map.merge(aws, %{"kind" => "aws_sqs", "queue_url" => queue})
      sns = Map.merge(aws, %{"kind" => "aws_sns", "topic_arn" => @topic})
      bus = Map.merge(aws, %{"kind" => "aws_eventbridge", "event_bus_arn" => @bus})
      pubsub = %{"kind" => "gcp_pubsub", "project_id" => "shop-prod-1", "topic" => "orders"}
      queues = %{"kind" => "azure_service_bus", "namespace" => @namespace, "entity" => "orders"}
      grid = %{"kind" => "azure_event_grid", "endpoint" => @grid}
      Net.answer("events.eu-central-1.amazonaws.com", Net.response(200, @accepted))
      Net.answer("oauth2.googleapis.com", Net.response(200, @token))
      Net.answer("pubsub.googleapis.com", Net.response(200, ~s({"messageIds":["1"]})))

      kinds = [
        {sqs, @secret, "sqs.eu-central-1.amazonaws.com"},
        {sns, @secret, "sns.eu-central-1.amazonaws.com"},
        {bus, @secret, "events.eu-central-1.amazonaws.com"},
        {pubsub, account, "pubsub.googleapis.com"},
        {queues, connection, @namespace},
        {grid, @secret, "orders.westeurope-1.eventgrid.azure.net"}
      ]

      for {destination, secret, host} <- kinds do
        kind = destination["kind"]
        credential = secret!(ctx, secret)
        endpoint = endpoint!(ctx, Map.put(destination, "credential_ref_id", credential))
        {event, message} = message!(ctx, endpoint)
        _ = jobs()

        assert {:attempted, :delivered} = attempt(ctx, message), kind
        requests = sent()
        assert host in hosts(requests), kind
        assert Enum.all?(requests, fn {dialed, _request} -> dialed.port == 443 end)
        assert [%{"result" => "succeeded", "ip" => "203.0.114.10"} = row] = attempts(ctx, message)
        refute inspect(row) =~ "PRIVATE KEY"
        refute inspect(row) =~ access
        refute inspect(row) =~ @secret
        assert %{"state" => "delivered"} = message(ctx, endpoint, event)
        stored = read(ctx, fn -> EngineStore.endpoint(endpoint.uuid) end)
        refute inspect(stored) =~ "PRIVATE KEY"
        refute inspect(stored) =~ @secret
      end
    end

    test "WH-18, WH-19: a cloud destination whose credential no longer resolves is tried again without a call",
         ctx do
      credential = credential!(ctx.scope, @secret)

      endpoint =
        endpoint!(ctx, %{
          "kind" => "aws_sqs",
          "queue_url" => "https://sqs.eu-central-1.amazonaws.com/123456789012/orders",
          "region" => "eu-central-1",
          "access_key_id" => "AKIDEXAMPLE0000000",
          "credential_ref_id" => credential.id
        })

      {_event, message} = message!(ctx, endpoint)
      System.delete_env(credential.var)

      assert {:attempted, :scheduled} = attempt(ctx, message)
      assert sent() == []
      assert [%{"failure_code" => "credentials_unavailable"}] = attempts(ctx, message)
    end

    test "WH-41, WH-43: a cloud address in a blocked range is never called", ctx do
      endpoint =
        endpoint!(ctx, %{
          "kind" => "azure_event_grid",
          "endpoint" => @grid,
          "credential_ref_id" => secret!(ctx)
        })

      {_event, message} = message!(ctx, endpoint)
      Net.resolve("orders.westeurope-1.eventgrid.azure.net", {:ok, [{10, 0, 0, 7}]})

      assert {:attempted, :dead_lettered} = attempt(ctx, message)
      assert sent() == []
      assert [%{"failure_code" => "address_blocked", "ip" => "10.0.0.7"}] = attempts(ctx, message)
    end
  end

  describe "WH-40 WH-41 WH-43 broker connections through the engine" do
    setup ctx do
      password = secret!(ctx)

      brokers = %{
        "kafka" => %{
          "kind" => "kafka",
          "brokers" => ["b1.example.com:9093"],
          "topic" => "orders",
          "sasl_mechanism" => "plain",
          "username" => "relay",
          "credential_ref_id" => password
        },
        "nats_jetstream" => %{
          "kind" => "nats_jetstream",
          "servers" => ["nats.example.com:4222"],
          "subject" => "orders.shipped",
          "username" => "relay",
          "credential_ref_id" => password
        },
        "rabbitmq" => %{
          "kind" => "rabbitmq",
          "host" => "mq.example.com:5671",
          "exchange" => "events",
          "routing_key" => "orders",
          "username" => "relay",
          "credential_ref_id" => password
        }
      }

      hosts = %{
        "kafka" => {"b1.example.com", 9093},
        "nats_jetstream" => {"nats.example.com", 4222},
        "rabbitmq" => {"mq.example.com", 5671}
      }

      %{brokers: brokers, hosts: hosts}
    end

    test "WH-40 (2), WH-43: a broker port the installation does not allow is never connected",
         ctx do
      for {kind, destination} <- ctx.brokers do
        endpoint = endpoint!(ctx, destination)
        {event, message} = message!(ctx, endpoint)

        assert {:attempted, :dead_lettered} = attempt(ctx, message), kind
        refute_received {:dialed, _connection}
        assert [%{"failure_code" => "destination_invalid"}] = attempts(ctx, message)
        assert %{"reason" => "destination_invalid"} = message(ctx, endpoint, event)
      end
    end

    test "WH-41, WH-43, WH-54: a broker address in a blocked range or of a metadata service is never connected, also on an allowed port",
         ctx do
      allow_ports([9093, 4222, 5671])

      for {kind, destination} <- ctx.brokers do
        {host, _port} = ctx.hosts[kind]
        endpoint = endpoint!(ctx, destination)
        {_event, private} = message!(ctx, endpoint)
        {_other, metadata} = message!(ctx, endpoint)

        Net.resolve(host, {:ok, [{10, 0, 0, 5}]})
        assert {:attempted, :dead_lettered} = attempt(ctx, private), kind
        assert [%{"failure_code" => "address_blocked"} = row] = attempts(ctx, private)
        assert row["ip"] == "10.0.0.5"

        Net.resolve(host, {:ok, [{203, 0, 114, 10}, {169, 254, 169, 254}]})
        assert {:attempted, :dead_lettered} = attempt(ctx, metadata), kind
        assert [%{"failure_code" => "address_blocked"}] = attempts(ctx, metadata)
        refute_received {:dialed, _connection}
      end
    end

    test "WH-41 (1), WH-18: on an allowed port the broker is dialed at the validated address under its own name, and a refused connection is tried again",
         ctx do
      allow_ports([9093, 4222, 5671])

      for {kind, destination} <- ctx.brokers do
        {host, port} = ctx.hosts[kind]
        endpoint = endpoint!(ctx, destination)
        {_event, message} = message!(ctx, endpoint)

        assert {:attempted, :scheduled} = attempt(ctx, message), kind
        assert_received {:dialed, %{host: ^host, port: ^port, address: {203, 0, 114, 10}}}
        assert [%{"failure_code" => "connection_failed"} = row] = attempts(ctx, message)
        assert row["ip"] == "203.0.114.10"
        refute inspect(row) =~ @secret
      end
    end

    test "WH-17, WH-18, WH-19: a JetStream endpoint is delivered through the engine with the password its credential holds",
         ctx do
      allow_ports([4222])
      nats_server()
      endpoint = endpoint!(ctx, ctx.brokers["nats_jetstream"])
      {event, message} = message!(ctx, endpoint)
      _ = jobs()

      assert {:attempted, :delivered} = attempt(ctx, message)
      assert_received {:dialed, %{host: "nats.example.com", port: 4222}}
      assert_received {:nats, :connect, %{"user" => "relay", "pass" => @secret}}
      assert_received {:nats, :publish, "orders.shipped", _payload}
      assert %{"state" => "delivered"} = message(ctx, endpoint, event)
      assert [%{"result" => "succeeded"} = row] = attempts(ctx, message)
      refute inspect(row) =~ @secret
      refute inspect(jobs()) =~ @secret
    end
  end
end
