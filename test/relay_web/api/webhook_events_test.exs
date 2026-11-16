defmodule RelayWeb.Api.WebhookEventsTest do
  use Relay.DataCase, async: false

  alias Relay.Repo
  alias Relay.Webhooks
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture
  alias RelayTest.WebhookEngine, as: Fake

  setup do
    previous = Fake.install()
    on_exit(fn -> Application.put_env(:relay, Relay.Webhooks, previous) end)
    tenant = TenantFixture.tenant!()
    %{tenant: tenant, scope: tenant.live, token: F.token(tenant.live)}
  end

  defp get(ctx, path, status \\ 200), do: F.body(F.request(:get, path, ctx.token), status)

  defp post(ctx, path, body, status), do: F.body(F.request(:post, path, ctx.token, body), status)

  defp uuid, do: Relay.Id.to_string(Relay.Id.generate())

  defp outbox(type, extra \\ %{}) do
    payload =
      Map.merge(
        %{
          "notification_id" => uuid(),
          "delivery_id" => uuid(),
          "recipient_id" => uuid(),
          "recipient_kind" => "subscriber",
          "workflow" => %{"key" => "welcome", "version" => 1},
          "channel" => "email"
        },
        extra
      )

    %{
      id: Relay.Id.generate(),
      created_at: Relay.Clock.utc_now(),
      event_type: type,
      stream_key: "notification:" <> uuid(),
      epoch: 1,
      seq: 1,
      payload: payload,
      traceparent: nil
    }
  end

  defp dispatch!(scope, event) do
    {:ok, []} = Repo.in_scope(scope, fn _status -> Webhooks.Live.outbox_jobs(event) end)
    event
  end

  describe "WH-45 (2) the event feed of the development tunnel" do
    test "WH-45, WH-8, WH-11: the feed lists the environment's own events with their thin envelope, whether or not an endpoint subscribes",
         ctx do
      delivered = dispatch!(ctx.scope, outbox("notification.delivered"))
      extra = %{"reason" => "quiet_hours", "rule_id" => "policy.quiet_hours", "free" => "text"}
      suppressed = dispatch!(ctx.scope, outbox("notification.suppressed", extra))

      assert %{"object" => "list", "data" => [newest, oldest]} = get(ctx, "/v1/webhook_events")
      assert newest["id"] == Relay.ExternalId.encode("oev", suppressed.id)
      assert oldest["id"] == Relay.ExternalId.encode("oev", delivered.id)

      assert %{"object" => "webhook_event", "type" => "notification.suppressed"} = newest
      envelope = newest["envelope"]
      assert %{"specversion" => "1.0", "type" => "notification.suppressed"} = envelope
      assert envelope["id"] == newest["id"]
      assert envelope["subject"] == suppressed.stream_key
      assert envelope["environment"] == "live"
      assert envelope["data"]["rule_id"] == "policy.quiet_hours"
      refute Map.has_key?(envelope["data"], "free")
    end

    test "API-56: the feed filters by type and time and pages with cursors", ctx do
      for _n <- 1..3, do: dispatch!(ctx.scope, outbox("notification.delivered"))
      dispatch!(ctx.scope, outbox("notification.suppressed", %{"reason" => "quiet_hours"}))

      typed = get(ctx, "/v1/webhook_events?event_type=notification.delivered")
      assert length(typed["data"]) == 3
      assert Enum.all?(typed["data"], &(&1["type"] == "notification.delivered"))

      later = Relay.Clock.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
      query = URI.encode_query(%{"created_after" => later})
      assert get(ctx, "/v1/webhook_events?" <> query)["data"] == []

      first = get(ctx, "/v1/webhook_events?limit=3")
      assert %{"has_more" => true, "next_cursor" => cursor} = first
      rest = get(ctx, "/v1/webhook_events?limit=3&starting_after=" <> cursor)
      assert %{"has_more" => false, "data" => [last]} = rest
      refute last["id"] in Enum.map(first["data"], & &1["id"])

      refused = get(ctx, "/v1/webhook_events?created_after=soon", 422)
      assert refused["code"] == "validation_failed"
      assert Enum.any?(refused["errors"], &(&1["pointer"] == "/created_after"))
    end

    test "WH-8 (4), TN-16: the feed holds no event of a tenant's own event types and none of another scope",
         ctx do
      dispatch!(ctx.scope, outbox("notification.delivered"))
      key = "shop-" <> TenantFixture.random()
      post(ctx, "/v1/webhook_consumers", %{"key" => key}, 201)
      type = %{"name" => "order.shipped", "schema" => %{"type" => "object"}}
      post(ctx, "/v1/webhook_event_types", type, 201)

      assert {:ok, prepared} =
               Webhooks.prepare_destination_event(ctx.scope, key, "order.shipped", %{"a" => 1})

      {:ok, %{messages: 0}} =
        Repo.in_scope(ctx.scope, fn _status ->
          Webhooks.emit_destination_event(Relay.Id.generate(), prepared, %{})
        end)

      assert [%{"type" => "notification.delivered"}] = get(ctx, "/v1/webhook_events")["data"]

      test_plane = %{ctx | token: F.token(ctx.tenant.test)}
      assert get(test_plane, "/v1/webhook_events")["data"] == []
      stranger = TenantFixture.tenant!()
      assert get(%{ctx | token: F.token(stranger.live)}, "/v1/webhook_events")["data"] == []
    end
  end
end
