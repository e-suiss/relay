defmodule Relay.Webhooks.AuditStreamTest do
  use Relay.DataCase, async: false

  alias Relay.Repo
  alias Relay.Webhooks
  alias Relay.Webhooks.EngineStore
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture
  alias RelayTest.WebhookEngine, as: Fake

  @url "https://siem.example.com/relay"
  @type_name "audit_record.appended"
  @fields ~w(action actor_kind audit_record_id target_id target_type)
  @rows """
  SELECT id, created_at, event_type, stream_key, epoch, seq, payload, traceparent
  FROM relay.outbox_events WHERE event_type = $1 ORDER BY seq
  """

  setup do
    previous = Fake.install()
    on_exit(fn -> Application.put_env(:relay, Relay.Webhooks, previous) end)
    tenant = TenantFixture.tenant!()
    %{tenant: tenant, scope: tenant.live, token: F.token(tenant.live)}
  end

  defp post(ctx, path, body, status), do: F.body(F.request(:post, path, ctx.token, body), status)

  defp patch(ctx, path, body, status),
    do: F.body(F.request(:patch, path, ctx.token, body), status)

  defp get(ctx, path), do: F.body(F.request(:get, path, ctx.token), 200)

  defp endpoint!(ctx, event_types) do
    body = %{
      "use" => "relay_events",
      "destination" => %{"kind" => "https", "url" => @url},
      "event_types" => event_types
    }

    created = post(ctx, "/v1/webhook_endpoints", body, 201)
    {:ok, id} = Relay.ExternalId.decode(created["id"], ["whe"])
    Map.put(created, :uuid, id)
  end

  defp subscribed!(ctx, event_types \\ []) do
    endpoint = endpoint!(ctx, event_types)
    digest = TenantFixture.digest()
    actor = TenantFixture.actor()

    assert {:ok, {:updated, %{"event_types" => types}}} =
             Webhooks.endpoint_subscribe_explicit(
               ctx.scope,
               endpoint.uuid,
               @type_name,
               digest,
               actor
             )

    assert @type_name in types
    endpoint
  end

  defp read(ctx, fun) do
    {:ok, value} = Repo.in_scope(ctx.scope, fn _status -> fun.() end)
    value
  end

  defp announced(ctx) do
    read(ctx, fn ->
      for [id, created_at, type, stream_key, epoch, seq, payload, traceparent] <-
            Repo.scoped_query!(@rows, [@type_name]).rows do
        %{
          id: id,
          created_at: created_at,
          event_type: type,
          stream_key: stream_key,
          epoch: epoch,
          seq: seq,
          payload: payload,
          traceparent: traceparent
        }
      end
    end)
  end

  defp dispatch!(ctx, event) do
    {:ok, []} = Repo.in_scope(ctx.scope, fn _status -> Webhooks.Live.outbox_jobs(event) end)
    event
  end

  defp message(ctx, endpoint, event),
    do: read(ctx, fn -> EngineStore.message_of(endpoint.uuid, event.id) end)

  defp stored_event(ctx, event), do: read(ctx, fn -> EngineStore.event(event.id) end)

  defp jobs(acc \\ []) do
    receive do
      {:webhook_job, job} -> jobs([job | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "WH-67 the audit records of a tenant as events" do
    test "WH-67, WH-16: an endpoint that chose * does not receive audit_record.appended and an endpoint that names it does",
         ctx do
      all = endpoint!(ctx, ["*"])
      named = subscribed!(ctx)
      events = announced(ctx)
      assert length(events) >= 3

      for event <- events do
        dispatch!(ctx, event)
        assert message(ctx, all, event) == nil
        assert %{"state" => "pending", "event_type" => @type_name} = message(ctx, named, event)
      end
    end

    test "WH-67, WH-11: the delivered event carries the record, the action, the actor kind and the target, and no free text",
         ctx do
      named = subscribed!(ctx)
      [created | _rest] = events = announced(ctx)
      Enum.each(events, &dispatch!(ctx, &1))
      endpoint_event = Enum.find(events, &(&1.payload["action"] == "webhook_endpoint.created"))
      assert endpoint_event.payload["target_type"] == "webhook_endpoint"
      assert Map.keys(created.payload) -- @fields == []

      message = message(ctx, named, endpoint_event)
      Fake.answers([Fake.http(200, [], "stored")])
      assert {:ok, {:attempted, :delivered}} = Webhooks.attempt(ctx.scope, message["id"])
      assert_received {:webhook_delivery, _config, prepared, _opts}

      assert %{"type" => @type_name, "data" => data} = Jason.decode!(prepared.body)
      assert Map.keys(data) -- @fields == []
      assert "aud_" <> _ = data["audit_record_id"]
      assert data["action"] == "webhook_endpoint.created"
      assert data["actor_kind"] == "api_client"
      assert data["target_type"] == "webhook_endpoint"
      assert data["target_id"] == Relay.Id.to_string(named.uuid)
      assert RelayTest.OutboxEvents.data(ctx.scope, @type_name) != []
    end

    test "WH-67, WH-20: the subject is the target of the record and seq counts the records of that target",
         ctx do
      named = subscribed!(ctx)
      stream = "audit_target:webhook_endpoint:" <> Relay.Id.to_string(named.uuid)
      events = Enum.filter(announced(ctx), &(&1.stream_key == stream))

      assert [%{seq: 1, payload: %{"action" => "webhook_endpoint.created"}}, %{seq: 2} = last] =
               Enum.sort_by(events, & &1.seq)

      assert last.payload["action"] == "webhook_endpoint.updated"
      dispatch!(ctx, last)
      assert %{"subject" => ^stream, "seq" => 2} = stored_event(ctx, last)
      assert message(ctx, named, last) != nil
    end

    test "WH-67, WH-52: an endpoint at the limit of event types is not subscribed", ctx do
      endpoint = endpoint!(ctx, [])
      names = for n <- 1..100, do: "thing.happened_#{n}"
      digest = TenantFixture.digest()
      actor = TenantFixture.actor()

      full = %{"event_types" => names}
      update = fn -> Webhooks.endpoint_update(endpoint.uuid, nil, full, digest, actor) end
      assert {:updated, _version} = read(ctx, update)

      assert {:ok, {:limit_reached, %{"event_types" => ^names}}} =
               Webhooks.endpoint_subscribe_explicit(
                 ctx.scope,
                 endpoint.uuid,
                 @type_name,
                 digest,
                 actor
               )
    end

    test "WH-67: with no endpoint that names the type nothing is recorded and nothing is queued",
         ctx do
      all = endpoint!(ctx, ["*"])
      _ = jobs()

      for event <- announced(ctx) do
        dispatch!(ctx, event)
        assert stored_event(ctx, event) == nil
        assert message(ctx, all, event) == nil
      end

      assert jobs() == []
    end

    test "WH-67: delivering an audit event appends no audit record", ctx do
      named = subscribed!(ctx)
      events = announced(ctx)
      Enum.each(events, &dispatch!(ctx, &1))
      Fake.answers(for _event <- events, do: Fake.http(200, [], "stored"))

      for event <- events do
        message = message(ctx, named, event)
        assert {:ok, {:attempted, :delivered}} = Webhooks.attempt(ctx.scope, message["id"])
      end

      assert length(announced(ctx)) == length(events)
    end

    test "WH-67, WH-45: the event feed of the development tunnel never lists an audit event",
         ctx do
      _named = subscribed!(ctx)
      events = announced(ctx)
      Enum.each(events, &dispatch!(ctx, &1))
      assert stored_event(ctx, hd(events)) != nil

      assert get(ctx, "/v1/webhook_events")["data"] == []
      assert get(ctx, "/v1/webhook_events?event_type=" <> @type_name)["data"] == []
    end
  end

  describe "WH-67 TN-50 choosing the type" do
    test "WH-67, TN-50: an API client cannot add the type, which needs an operator session; it keeps and removes it",
         ctx do
      body = %{
        "use" => "relay_events",
        "destination" => %{"kind" => "https", "url" => @url},
        "event_types" => [@type_name]
      }

      assert post(ctx, "/v1/webhook_endpoints", body, 403)["code"] ==
               "auth_operator_session_required"

      plain = endpoint!(ctx, ["notification.delivered"])
      path = "/v1/webhook_endpoints/" <> plain["id"]
      both = %{"event_types" => ["notification.delivered", @type_name]}
      assert patch(ctx, path, both, 403)["code"] == "auth_operator_session_required"

      named = subscribed!(ctx, ["notification.delivered"])
      path = "/v1/webhook_endpoints/" <> named["id"]
      assert patch(ctx, path, both, 200)["event_types"] == both["event_types"]

      removed = %{"event_types" => ["notification.delivered"]}
      assert patch(ctx, path, removed, 200)["event_types"] == ["notification.delivered"]
      assert patch(ctx, path, both, 403)["code"] == "auth_operator_session_required"
    end

    test "WH-67: the catalog marks the type explicit-only and no other type" do
      assert Relay.EventCatalog.explicit_only() ==
               [@type_name, "mailbox.record_flagged", "mailbox.request_received"]
      assert Relay.EventCatalog.explicit_only?(@type_name)
      refute Relay.EventCatalog.explicit_only?("notification.delivered")
      assert @type_name in Relay.EventCatalog.names()
    end

    test "WH-67: an endpoint of use destination and an unknown endpoint are not subscribed",
         ctx do
      key = "shop-" <> TenantFixture.random()
      post(ctx, "/v1/webhook_consumers", %{"key" => key}, 201)

      body = %{
        "use" => "destination",
        "consumer" => key,
        "destination" => %{"kind" => "https", "url" => @url},
        "event_types" => []
      }

      created = post(ctx, "/v1/webhook_endpoints", body, 201)
      {:ok, id} = Relay.ExternalId.decode(created["id"], ["whe"])
      digest = TenantFixture.digest()
      actor = TenantFixture.actor()
      subscribe = &Webhooks.endpoint_subscribe_explicit(ctx.scope, &1, @type_name, digest, actor)

      assert {:ok, {:not_relay_events, %{"event_types" => []}}} = subscribe.(id)
      assert {:ok, {:not_found, nil}} = subscribe.(Relay.Id.generate())
    end
  end
end
