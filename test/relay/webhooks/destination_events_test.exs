defmodule Relay.Webhooks.DestinationEventsTest do
  use Relay.DataCase, async: false

  alias Relay.Repo
  alias Relay.Webhooks
  alias Relay.Webhooks.EngineStore
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture
  alias RelayTest.WebhookEngine, as: Fake

  setup do
    previous = Fake.install()
    on_exit(fn -> Application.put_env(:relay, Relay.Webhooks, previous) end)
    tenant = TenantFixture.tenant!()
    %{scope: tenant.live, token: F.token(tenant.live)}
  end

  defp post(ctx, path, body, status), do: F.body(F.request(:post, path, ctx.token, body), status)

  defp consumer!(ctx) do
    key = "shop-" <> TenantFixture.random()
    post(ctx, "/v1/webhook_consumers", %{"key" => key}, 201)
  end

  defp event_type!(ctx) do
    body = %{
      "name" => "order.shipped",
      "schema" => %{
        "type" => "object",
        "required" => ["order"],
        "properties" => %{"order" => %{"type" => "string"}}
      },
      "identifiers" => ["order"]
    }

    post(ctx, "/v1/webhook_event_types", body, 201)
  end

  defp endpoint!(ctx, consumer) do
    body = %{
      "use" => "destination",
      "consumer" => consumer["key"],
      "destination" => %{"kind" => "https", "url" => "https://hooks.example.com/shop"},
      "event_types" => ["*"]
    }

    created = post(ctx, "/v1/webhook_endpoints", body, 201)
    {:ok, id} = Relay.ExternalId.decode(created["id"], ["whe"])
    Map.put(created, :uuid, id)
  end

  defp prepare(ctx, consumer, data),
    do: Webhooks.prepare_destination_event(ctx.scope, consumer["key"], "order.shipped", data)

  defp emit!(ctx, event_id, prepared) do
    {:ok, result} =
      Repo.in_scope(ctx.scope, fn _status ->
        Webhooks.emit_destination_event(event_id, prepared, %{})
      end)

    result
  end

  defp message(ctx, endpoint, event_id) do
    {:ok, message} =
      Repo.in_scope(ctx.scope, fn _status -> EngineStore.message_of(endpoint.uuid, event_id) end)

    message
  end

  defp jobs(acc \\ []) do
    receive do
      {:webhook_job, job} -> jobs([job | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "WH-13 tenant events" do
    test "WH-13 (1): the data of an event follows the schema of its tenant event type", ctx do
      consumer = consumer!(ctx)
      type = event_type!(ctx)

      assert {:ok, %{schema_version: 1, reason: nil}} = prepare(ctx, consumer, %{"order" => "A"})
      assert {:refused, :payload_invalid} = prepare(ctx, consumer, %{"order" => 7})
      assert {:refused, :payload_invalid} = prepare(ctx, consumer, "A-1")
      assert {:refused, :consumer_not_found} = prepare(ctx, %{"key" => "nobody"}, %{})

      post(ctx, "/v1/webhook_event_types/#{type["id"]}/archive", nil, 200)
      assert {:refused, :event_type_archived} = prepare(ctx, consumer, %{"order" => "A"})

      post(ctx, "/v1/webhook_consumers/#{consumer["id"]}/archive", nil, 200)
      assert {:refused, :consumer_archived} = prepare(ctx, consumer, %{"order" => "A"})
    end

    test "WH-2, INV-12: emitting an event again creates no second message", ctx do
      consumer = consumer!(ctx)
      event_type!(ctx)
      endpoint = endpoint!(ctx, consumer)
      {:ok, prepared} = prepare(ctx, consumer, %{"order" => "A-1"})
      event_id = Relay.Id.generate()

      assert %{messages: 1} = emit!(ctx, event_id, prepared)
      assert [%{worker: Webhooks.AttemptWorker}] = jobs()
      first = message(ctx, endpoint, event_id)

      assert %{messages: 0} = emit!(ctx, event_id, prepared)
      assert jobs() == []
      assert message(ctx, endpoint, event_id)["id"] == first["id"]

      read = fn _status -> Webhooks.destination_event_states([event_id]) end
      assert Repo.in_scope(ctx.scope, read) == {:ok, %{event_id => ["pending"]}}
    end

    test "WH-29, WH-52: an event over the hard limit is recorded and its messages are dead-lettered",
         ctx do
      consumer = consumer!(ctx)
      event_type!(ctx)
      endpoint = endpoint!(ctx, consumer)
      large = %{"order" => String.duplicate("x", 300_000)}

      assert {:ok, %{reason: "payload_too_large"} = prepared} = prepare(ctx, consumer, large)
      event_id = Relay.Id.generate()
      assert %{messages: 1} = emit!(ctx, event_id, prepared)

      assert %{"state" => "dead_lettered", "reason" => "payload_too_large"} =
               message(ctx, endpoint, event_id)

      assert jobs() == []
    end
  end
end
