defmodule Relay.Webhooks.EventStreamTest do
  use Relay.DataCase, async: false

  alias Relay.Repo
  alias Relay.Webhooks
  alias Relay.Webhooks.EngineStore
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture
  alias RelayTest.WebhookEngine, as: Fake

  @semantic ~w(delivery.status_changed notification.delivered notification.failed
               notification.seen notification.read notification.clicked
               notification.suppressed)

  setup do
    previous = Fake.install()
    on_exit(fn -> Application.put_env(:relay, Relay.Webhooks, previous) end)
    installed = Application.get_env(:relay, Relay.Webhooks)
    kinds = Map.put(Keyword.fetch!(installed, :destinations), "kafka", Fake.Destination)
    Application.put_env(:relay, Relay.Webhooks, Keyword.put(installed, :destinations, kinds))
    tenant = TenantFixture.tenant!()
    %{scope: tenant.live, token: F.token(tenant.live)}
  end

  defp stream!(ctx, types) do
    body = %{
      "use" => "relay_events",
      "destination" => %{
        "kind" => "kafka",
        "brokers" => ["broker.example.com:9092"],
        "topic" => "relay-events"
      },
      "event_types" => types
    }

    created = F.body(F.request(:post, "/v1/webhook_endpoints", ctx.token, body), 201)
    {:ok, id} = Relay.ExternalId.decode(created["id"], ["whe"])
    Map.put(created, :uuid, id)
  end

  defp uuid, do: Relay.Id.to_string(Relay.Id.generate())

  defp outbox(type, seq) do
    %{
      id: Relay.Id.generate(),
      created_at: Relay.Clock.utc_now(),
      event_type: type,
      stream_key: "notification:" <> uuid(),
      epoch: 1,
      seq: seq,
      payload: %{
        "notification_id" => uuid(),
        "delivery_id" => uuid(),
        "recipient_id" => uuid(),
        "recipient_kind" => "subscriber",
        "workflow" => %{"key" => "welcome", "version" => 1},
        "channel" => "email",
        "status" => "delivered",
        "previous_status" => "sent",
        "reason" => "quiet_hours",
        "rule_id" => "policy.quiet_hours"
      },
      traceparent: nil
    }
  end

  defp dispatch!(ctx, event) do
    {:ok, []} = Repo.in_scope(ctx.scope, fn _status -> Webhooks.Live.outbox_jobs(event) end)
    event
  end

  defp message(ctx, endpoint, event) do
    {:ok, message} =
      Repo.in_scope(ctx.scope, fn _status -> EngineStore.message_of(endpoint.uuid, event.id) end)

    message
  end

  describe "E-65 DS-37 the semantic event stream" do
    test "E-65, DS-37, WH-17: delivery transitions, engagements and skips flow to a queue destination that chose every type",
         ctx do
      stream = stream!(ctx, ["*"])
      written = {:ok, %{kind: :write, duration_ms: 2, address: "203.0.114.9"}}

      for {type, seq} <- Enum.with_index(@semantic, 1) do
        assert Relay.EventCatalog.delivered?(type)
        event = dispatch!(ctx, outbox(type, seq))
        message = message(ctx, stream, event)
        assert %{"state" => "pending", "event_type" => ^type} = message

        Fake.answers([written])
        assert {:ok, {:attempted, :delivered}} = Webhooks.attempt(ctx.scope, message["id"])
        assert_received {:webhook_delivery, _config, prepared, _opts}

        assert prepared.id == Relay.ExternalId.encode("oev", event.id)
        assert prepared.type == type
        assert prepared.partition_key == event.stream_key
        assert {"seq", Integer.to_string(seq)} in prepared.attributes
        assert %{"id" => id, "type" => ^type} = Jason.decode!(prepared.body)
        assert id == prepared.id
      end
    end

    test "E-65, WH-16: a destination that chose some types receives only those", ctx do
      stream = stream!(ctx, ["notification.suppressed"])
      skipped = dispatch!(ctx, outbox("notification.suppressed", 1))
      seen = dispatch!(ctx, outbox("notification.seen", 2))

      assert %{"state" => "pending"} = message(ctx, stream, skipped)
      assert message(ctx, stream, seen) == nil
    end
  end
end
