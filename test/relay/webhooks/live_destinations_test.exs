defmodule Relay.Webhooks.LiveDestinationsTest do
  use ExUnit.Case, async: false

  import RelayTest.WebhookDestinations,
    only: [credential!: 2, endpoint!: 2, message!: 2, message: 3, attempt: 2, attempts: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Relay.Redacted
  alias Relay.Webhooks
  alias Relay.Webhooks.Batch
  alias Relay.Webhooks.Destination.Kafka
  alias Relay.Webhooks.Destination.Kafka.Protocol
  alias Relay.Webhooks.Destination.NatsJetstream
  alias Relay.Webhooks.Destination.Rabbitmq
  alias Relay.Webhooks.Destination.S3
  alias RelayTest.DestinationFixture, as: Net
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.LiveDestinations, as: Live
  alias RelayTest.TenantFixture

  @moduletag :live_destinations
  @moduletag timeout: 180_000

  @kafka "kafka.live.relay.test"
  @nats "nats.live.relay.test"
  @nats_token "nats-token.live.relay.test"
  @rabbitmq "rabbitmq.live.relay.test"
  @minio "minio.live.relay.test"
  @structured "application/cloudevents+json; charset=utf-8"

  defp prepared(fields \\ %{}),
    do: Net.prepared(Map.merge(%{id: "evt_" <> Live.unique()}, fields))

  defp wrapped(secret \\ Live.secret()), do: Redacted.wrap(secret)

  defp kafka(extra) do
    base = %{
      brokers: [@kafka <> ":9093"],
      topic: "relay-live",
      sasl_mechanism: "scram_sha_256",
      username: "relay",
      credential: wrapped()
    }

    Map.merge(base, extra)
  end

  defp nats(extra) do
    base = %{
      servers: [@nats <> ":4222"],
      subject: "relay.live." <> Live.unique(),
      username: "relay",
      credential: wrapped()
    }

    Map.merge(base, extra)
  end

  defp rabbitmq(extra) do
    base = %{
      host: @rabbitmq <> ":5671",
      exchange: "relay.live",
      routing_key: "relay.live." <> Live.unique(),
      username: "relay",
      credential: wrapped()
    }

    Map.merge(base, extra)
  end

  defp store(extra) do
    base = %{
      endpoint: "https://" <> @minio <> ":9000",
      bucket: Live.bucket(),
      region: "us-east-1",
      prefix: "events",
      access_key_id: Live.access_key_id(),
      credential: wrapped()
    }

    Map.merge(base, extra)
  end

  defp record(records, id) do
    assert [record] = Enum.filter(records, &String.contains?(&1.headers, "ce_id:" <> id))
    record
  end

  defp queued(messages, id) do
    assert [message] = Enum.filter(messages, &(&1["properties"]["message_id"] == id))
    message
  end

  defp delivered!(ctx, destination, host) do
    endpoint = endpoint!(ctx, Map.put(destination, "credential_ref_id", ctx.credential))
    {event, message} = message!(ctx, endpoint)

    assert {:attempted, :delivered} = attempt(ctx, message)
    assert %{"state" => "delivered"} = message(ctx, endpoint, event)
    assert [%{"result" => "succeeded", "attempt_no" => 1} = row] = attempts(ctx, message)
    assert row["ip"] == Live.address(host)
    refute inspect(row) =~ Live.secret()
    {event, Relay.ExternalId.encode("oev", event.id)}
  end

  describe "WH-58 a Kafka broker over TLS" do
    test "WH-58, WH-18, WH-20 (3): a SCRAM-SHA-256 record is read back with its headers, in the partition the Java client chooses for its key" do
      keys = for n <- 1..6, do: "order/" <> Live.unique() <> "-" <> Integer.to_string(n)
      messages = Enum.map(keys, &prepared(%{subject: &1}))
      address = Live.address(@kafka)

      for message <- messages do
        assert {:ok, receipt} = Kafka.deliver(kafka(%{}), message, Live.options())
        assert %{kind: :write, address: ^address} = receipt
      end

      marker = "java-" <> Live.unique()
      :ok = Live.kafka_produce(keys, marker)
      records = Live.kafka_records()

      for {key, message} <- Enum.zip(keys, messages) do
        ours = record(records, message.id)
        assert [java] = Enum.filter(records, &(&1.key == key and &1.value == marker))
        assert ours.key == key
        assert ours.value == message.data
        assert ours.partition == java.partition
        assert ours.partition == Protocol.partition(key, 3)
        assert ours.headers =~ "ce_specversion:1.0"
        assert ours.headers =~ "ce_type:order.shipped"
        assert ours.headers =~ "ce_subject:" <> key
        assert ours.headers =~ "ce_source:https://shop.example/orders"
        assert ours.headers =~ "content-type:application/json"
      end
    end

    test "WH-58, WH-17, WH-8 (3): SCRAM-SHA-512 and PLAIN authenticate, and a structured record without a key is the whole event" do
      scram = prepared(%{subject: nil})
      plain = prepared()
      config = kafka(%{sasl_mechanism: "scram_sha_512", cloudevents_mode: "structured"})

      assert {:ok, %{kind: :write}} = Kafka.deliver(config, scram, Live.options())

      config = kafka(%{sasl_mechanism: "plain", username: "relayplain"})
      assert {:ok, %{kind: :write}} = Kafka.deliver(config, plain, Live.options())

      records = Live.kafka_records()
      structured = record(records, scram.id)
      assert structured.key == "null"
      assert structured.value == scram.body
      assert structured.headers =~ "content-type:" <> @structured
      assert %{"id" => id, "specversion" => "1.0"} = Jason.decode!(structured.value)
      assert id == scram.id

      binary = record(records, plain.id)
      assert binary.key == "order/o-1"
      assert binary.value == plain.data
    end

    test "WH-58, WH-17, WH-18: a wrong password is a credentials failure and an unknown topic is refused" do
      config = kafka(%{credential: wrapped("not-the-password")})
      assert {:error, failure} = Kafka.deliver(config, prepared(), Live.options())
      assert %{class: :credentials} = failure
      refute inspect(failure) =~ "not-the-password"

      config = kafka(%{sasl_mechanism: "scram_sha_512", credential: wrapped("not-the-password")})
      assert {:error, %{class: :credentials}} = Kafka.deliver(config, prepared(), Live.options())

      config = kafka(%{topic: "relay-live-absent"})
      assert {:error, failure} = Kafka.deliver(config, prepared(), Live.options())
      assert %{reason: "kafka_error_3"} = failure
    end
  end

  describe "WH-58 a NATS JetStream server over TLS" do
    test "WH-58, WH-17, WH-18: a message of a user with a password is read back with its headers and is not stored twice" do
      message = prepared()
      config = nats(%{})
      address = Live.address(@nats)

      assert {:ok, receipt} = NatsJetstream.deliver(config, message, Live.options())
      assert %{kind: :write, address: ^address} = receipt

      stored = Live.nats_message(@nats, config.subject, Live.nats_user())
      assert stored.subject == config.subject
      assert stored.data == message.data
      assert stored.headers =~ "Nats-Msg-Id: " <> message.id <> "\r\n"
      assert stored.headers =~ "ce-id: " <> message.id <> "\r\n"
      assert stored.headers =~ "ce-specversion: 1.0\r\n"
      assert stored.headers =~ "ce-type: order.shipped\r\n"
      assert stored.headers =~ "ce-subject: order/o-1\r\n"
      assert stored.headers =~ "ce-datacontenttype: application/json\r\n"

      assert {:ok, %{kind: :write}} = NatsJetstream.deliver(config, message, Live.options())
      again = Live.nats_message(@nats, config.subject, Live.nats_user())
      assert again.seq == stored.seq
    end

    test "WH-58, WH-17, WH-8 (3): an NKey user signs the server's nonce and publishes a structured event" do
      message = prepared()
      config = nats(%{cloudevents_mode: "structured", credential: wrapped(Live.nkey_seed())})
      config = Map.delete(config, :username)

      assert {:ok, %{kind: :write}} = NatsJetstream.deliver(config, message, Live.options())

      stored = Live.nats_message(@nats, config.subject, Live.nats_user())
      assert stored.data == message.body
      assert stored.headers =~ "Nats-Msg-Id: " <> message.id <> "\r\n"
      assert stored.headers =~ "content-type: " <> @structured <> "\r\n"
    end

    test "WH-58, WH-17: a token authenticates against a server that asks for one" do
      message = prepared()

      config = %{
        servers: [@nats_token <> ":4222"],
        subject: "relay.live." <> Live.unique(),
        credential: wrapped(Live.token())
      }

      address = Live.address(@nats_token)
      assert {:ok, receipt} = NatsJetstream.deliver(config, message, Live.options())
      assert %{kind: :write, address: ^address} = receipt

      stored = Live.nats_message(@nats_token, config.subject, Live.nats_token())
      assert stored.data == message.data
      assert stored.headers =~ "ce-id: " <> message.id <> "\r\n"
    end

    test "WH-58, WH-17, WH-18: a wrong password is a credentials failure and a subject no stream listens on is unavailable" do
      config = nats(%{credential: wrapped("not-the-password")})
      assert {:error, failure} = NatsJetstream.deliver(config, prepared(), Live.options())
      assert %{class: :credentials, reason: "authorization_violation"} = failure
      refute inspect(failure) =~ "not-the-password"

      config = nats(%{subject: "relay.absent." <> Live.unique()})
      assert {:error, failure} = NatsJetstream.deliver(config, prepared(), Live.options())
      assert %{class: :unavailable, reason: "no_responders"} = failure
    end
  end

  describe "WH-58 a RabbitMQ broker over TLS" do
    test "WH-58, WH-17, WH-18: a confirmed message is read back persistent with its properties and headers, in both modes" do
      binary = prepared()
      structured = prepared()
      first = rabbitmq(%{})
      second = rabbitmq(%{cloudevents_mode: "structured"})
      address = Live.address(@rabbitmq)

      assert {:ok, receipt} = Rabbitmq.deliver(first, binary, Live.options())
      assert %{kind: :write, address: ^address} = receipt
      assert {:ok, %{kind: :write}} = Rabbitmq.deliver(second, structured, Live.options())

      messages = Live.rabbitmq_messages()
      stored = queued(messages, binary.id)
      assert stored["payload"] == binary.data
      assert stored["exchange"] == "relay.live"
      assert stored["routing_key"] == first.routing_key
      assert %{"content_type" => "application/json", "delivery_mode" => 2} = stored["properties"]
      headers = stored["properties"]["headers"]
      assert headers["cloudEvents:id"] == binary.id
      assert headers["cloudEvents:specversion"] == "1.0"
      assert headers["cloudEvents:type"] == "order.shipped"
      assert headers["cloudEvents:subject"] == "order/o-1"

      stored = queued(messages, structured.id)
      assert stored["payload"] == structured.body
      assert stored["routing_key"] == second.routing_key
      assert %{"content_type" => @structured, "delivery_mode" => 2} = stored["properties"]
    end

    test "WH-58, WH-18: a body larger than the negotiated frame is split and arrives whole" do
      message = prepared(%{data: %{"blob" => String.duplicate("relay ", 60_000)}})
      assert byte_size(message.data) > 262_144

      assert {:ok, %{kind: :write}} = Rabbitmq.deliver(rabbitmq(%{}), message, Live.options())

      stored = queued(Live.rabbitmq_messages(), message.id)
      assert stored["payload_bytes"] == byte_size(message.data)
      assert stored["payload"] == message.data
    end

    test "WH-58, WH-17, WH-18: an unroutable message and a missing exchange are rejected, a wrong password is a credentials failure" do
      _earlier = Live.rabbitmq_messages()
      config = rabbitmq(%{exchange: "relay.live.unbound"})
      assert {:error, failure} = Rabbitmq.deliver(config, prepared(), Live.options())
      assert %{class: :rejected, reason: "unroutable"} = failure

      config = rabbitmq(%{exchange: "relay.live.absent"})
      assert {:error, failure} = Rabbitmq.deliver(config, prepared(), Live.options())
      assert %{class: :rejected, reason: "amqp_404"} = failure

      config = rabbitmq(%{credential: wrapped("not-the-password")})
      assert {:error, failure} = Rabbitmq.deliver(config, prepared(), Live.options())
      assert %{class: :credentials} = failure
      refute inspect(failure) =~ "not-the-password"

      assert Live.rabbitmq_messages() == []
    end
  end

  describe "WH-58 an S3 compatible store over TLS" do
    test "WH-58, WH-17, WH-21: a batch is written in path style and read back as the same JSON lines" do
      bodies = [prepared().body, prepared().body]
      id = "whb_" <> Live.unique()
      {:ok, batch} = Batch.prepared(id, bodies, 1)
      address = Live.address(@minio)

      assert {:ok, receipt} = S3.deliver(store(%{}), batch, Live.options())
      assert %{kind: :write, status: 200, address: ^address} = receipt

      object = Live.object("events/" <> id <> ".jsonl")
      assert object.status == 200
      assert object.content_type == "application/x-ndjson"
      assert object.body == Enum.join(bodies, "\n") <> "\n"

      assert {:ok, %{status: 200}} = S3.deliver(store(%{}), batch, Live.options())
      assert Live.object("events/" <> id <> ".jsonl").body == object.body
    end

    test "WH-58, WH-17: a prefix with characters the signature encodes is signed as the store expects" do
      id = "whb_" <> Live.unique()
      {:ok, batch} = Batch.prepared(id, [prepared().body], 1)
      config = store(%{prefix: "live/it's(1)!*/nested"})

      assert {:ok, %{status: 200}} = S3.deliver(config, batch, Live.options())
    end

    test "WH-58, WH-17, WH-18: a wrong secret access key is a credentials failure and a missing bucket is refused" do
      {:ok, batch} = Batch.prepared("whb_" <> Live.unique(), [prepared().body], 1)

      config = store(%{credential: wrapped("not-the-secret-key")})
      assert {:error, failure} = S3.deliver(config, batch, Live.options())
      assert %{class: :credentials, reason: "http_403"} = failure
      refute inspect(failure) =~ "not-the-secret-key"

      config = store(%{bucket: "relay-live-absent"})
      assert {:error, failure} = S3.deliver(config, batch, Live.options())
      assert %{class: :rejected, reason: "http_404"} = failure
    end
  end

  describe "WH-58 the engine's attempt" do
    setup do
      owner = Sandbox.start_owner!(Relay.Repo, shared: true)
      on_exit(fn -> Sandbox.stop_owner(owner) end)
      previous = Live.install()
      on_exit(fn -> Application.put_env(:relay, Relay.Webhooks, previous) end)
      tenant = TenantFixture.tenant!()
      ctx = %{tenant: tenant, scope: tenant.live, token: F.token(tenant.live)}
      credential = credential!(ctx.scope, Live.secret())
      on_exit(fn -> System.delete_env(credential.var) end)
      Map.put(ctx, :credential, credential.id)
    end

    test "WH-58, WH-17, WH-19: a Kafka endpoint is delivered with the password its credential holds",
         ctx do
      destination = %{
        "kind" => "kafka",
        "brokers" => [@kafka <> ":9093"],
        "topic" => "relay-live",
        "sasl_mechanism" => "scram_sha_256",
        "username" => "relay"
      }

      {event, id} = delivered!(ctx, destination, @kafka)

      stored = record(Live.kafka_records(), id)
      assert stored.headers =~ "ce_type:notification.delivered"
      assert stored.headers =~ "content-type:application/json"
      data = Jason.decode!(stored.value)
      assert data["notification_id"] == event.payload["notification_id"]

      assert stored.key == "null" or stored.headers =~ "ce_subject:" <> stored.key
    end

    test "WH-58, WH-17, WH-19: a JetStream endpoint is delivered", ctx do
      subject = "relay.live." <> Live.unique()

      destination = %{
        "kind" => "nats_jetstream",
        "servers" => [@nats <> ":4222"],
        "subject" => subject,
        "username" => "relay"
      }

      {event, id} = delivered!(ctx, destination, @nats)

      stored = Live.nats_message(@nats, subject, Live.nats_user())
      assert stored.headers =~ "Nats-Msg-Id: " <> id <> "\r\n"
      assert stored.headers =~ "ce-type: notification.delivered\r\n"
      data = Jason.decode!(stored.data)
      assert data["notification_id"] == event.payload["notification_id"]
    end

    test "WH-58, WH-17, WH-19: a RabbitMQ endpoint is delivered", ctx do
      routing_key = "relay.live." <> Live.unique()

      destination = %{
        "kind" => "rabbitmq",
        "host" => @rabbitmq <> ":5671",
        "exchange" => "relay.live",
        "routing_key" => routing_key,
        "username" => "relay"
      }

      {event, id} = delivered!(ctx, destination, @rabbitmq)

      stored = queued(Live.rabbitmq_messages(), id)
      assert stored["routing_key"] == routing_key
      assert stored["properties"]["headers"]["cloudEvents:type"] == "notification.delivered"
      data = Jason.decode!(stored["payload"])
      assert data["notification_id"] == event.payload["notification_id"]
    end

    test "WH-58, WH-21, WH-45 (3): the test event of an object store endpoint is written as an object of one line",
         ctx do
      prefix = "engine-" <> Live.unique()

      endpoint =
        endpoint!(ctx, %{
          "kind" => "s3",
          "endpoint" => "https://" <> @minio <> ":9000",
          "bucket" => Live.bucket(),
          "region" => "us-east-1",
          "prefix" => prefix,
          "access_key_id" => Live.access_key_id(),
          "credential_ref_id" => ctx.credential
        })

      path = "/v1/webhook_endpoints/#{endpoint["id"]}/test"
      created = F.body(F.request(:post, path, ctx.token, %{}), 202)
      {:ok, id} = Relay.ExternalId.decode(created["id"], ["whm"])

      assert {:ok, {:attempted, :delivered}} = Webhooks.attempt(ctx.scope, id)

      object = Live.object(prefix <> "/" <> created["event_id"] <> ".jsonl")
      assert object.status == 200
      assert [line] = String.split(object.body, "\n", trim: true)
      assert %{"type" => "webhook_endpoint.tested", "specversion" => "1.0"} = Jason.decode!(line)
    end
  end
end
