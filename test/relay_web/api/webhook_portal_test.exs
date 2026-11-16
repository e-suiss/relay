defmodule RelayWeb.Api.WebhookPortalTest do
  use Relay.DataCase, async: false

  alias Relay.Webhooks.EngineStore
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.PortalIsolation, as: Portal
  alias RelayTest.TenantFixture
  alias RelayTest.WebhookEngine, as: Fake

  defmodule Later do
    @moduledoc false
    @behaviour Relay.Clock

    @impl Relay.Clock
    def utc_now, do: DateTime.add(DateTime.utc_now(), 1_200, :second)

    @impl Relay.Clock
    def monotonic_ms, do: System.monotonic_time(:millisecond)
  end

  @endpoints "/v1/portal/webhook_endpoints"
  @messages "/v1/portal/webhook_messages"
  @url "https://hooks.example.com/portal"

  setup do
    previous = Fake.install()
    on_exit(fn -> Application.put_env(:relay, Relay.Webhooks, previous) end)
    tenant = TenantFixture.tenant!()
    %{tenant: tenant, scope: tenant.live, token: F.token(tenant.live)}
  end

  defp consumer!(ctx) do
    key = "shop-" <> TenantFixture.random()
    consumer = F.body(F.request(:post, "/v1/webhook_consumers", ctx.token, %{"key" => key}), 201)
    Map.put(consumer, :token, Portal.token!(ctx.scope, consumer["id"]))
  end

  defp get(token, path, status \\ 200), do: F.body(Portal.request(:get, path, token), status)

  defp post(token, path, body, status),
    do: F.body(Portal.request(:post, path, token, body), status)

  defp patch(token, path, body, status),
    do: F.body(Portal.request(:patch, path, token, body), status)

  defp endpoint!(token, overrides \\ %{}) do
    body = Map.merge(%{"url" => @url, "event_types" => []}, overrides)
    post(token, @endpoints, body, 201)
  end

  defp id!(text, prefix) do
    {:ok, id} = Relay.ExternalId.decode(text, [prefix])
    id
  end

  defp claims(token) do
    [header, payload, _signature] = String.split(token, ".")
    decode = &(&1 |> Base.url_decode64!(padding: false) |> Jason.decode!())
    {decode.(header), decode.(payload)}
  end

  defp audit(scope, action, target) do
    now = DateTime.utc_now()

    {:ok, rows} =
      Relay.Repo.in_scope(scope, fn _status ->
        Relay.Repo.call!(
          "relay_fn.audit_query",
          [DateTime.add(now, -3_600), DateTime.add(now, 3_600), action, nil, 1_000] ++
            [TenantFixture.digest() | Relay.Actor.params(TenantFixture.actor())]
        )
      end)

    for %{"target_id" => ^target} = row <- rows,
        do: Map.take(row, ~w(actor_kind actor_ref on_behalf_of_ref reason))
  end

  defp attempt(ctx, message, opts \\ []),
    do: Relay.Webhooks.attempt(ctx.scope, id!(message["id"], "whm"), opts)

  defp cancelled_message!(ctx, consumer, endpoint) do
    now = Relay.Clock.utc_now()
    data = %{"order_id" => "A-1"}
    digest = :crypto.hash(:sha256, Jason.encode!(data))

    event = %{
      "use_kind" => "destination",
      "consumer_id" => Relay.Id.to_string(id!(consumer["id"], "whc")),
      "event_type" => "order.shipped",
      "schema_version" => 1,
      "origin" => "workflow",
      "source" => "urn:shop:orders",
      "subject" => "order:A-1",
      "occurred_at" => now
    }

    message = %{
      id: Relay.Id.generate(),
      endpoint_id: id!(endpoint["id"], "whe"),
      next_attempt_at: now,
      window_ends_at: DateTime.add(now, 3_600, :second)
    }

    {:ok, 1} =
      Relay.Repo.in_scope(ctx.scope, fn _status ->
        opts = %{origin: "event"}
        id = Relay.Id.generate()
        [_created] = EngineStore.fan_out(id, event, data, digest, [message], opts, now)
        Relay.Webhooks.cancel_messages([message.id], "portal-test")
      end)

    Relay.ExternalId.encode("whm", message.id)
  end

  defp failed_test_message!(ctx, token, endpoint) do
    sent = post(token, "#{@endpoints}/#{endpoint["id"]}/test", nil, 202)
    Fake.answers([Fake.http(500, [], "down for maintenance")])
    assert {:ok, {:attempted, :exhausted}} = attempt(ctx, sent)
    sent
  end

  describe "WH-47 the portal token" do
    test "WH-47: a tenant backend mints a short-lived token for exactly one consumer and environment",
         ctx do
      consumer = consumer!(ctx)
      path = "/v1/webhook_consumers/#{consumer["id"]}/portal_tokens"
      minted = F.body(F.request(:post, path, ctx.token), 201)

      assert %{"object" => "webhook_portal_token", "consumer_id" => id} = minted
      assert id == consumer["id"]
      {:ok, expires_at, 0} = DateTime.from_iso8601(minted["expires_at"])
      assert_in_delta DateTime.diff(expires_at, DateTime.utc_now()), 900, 5

      {header, claims} = claims(minted["token"])
      assert %{"alg" => "ES256", "typ" => "relay-webhook-portal+jwt"} = header
      assert %{"sub" => ^id, "env" => "live"} = claims
      assert claims["exp"] - claims["iat"] == 900
      refute Map.has_key?(claims, "scope")
      refute minted["token"] =~ Relay.Id.to_string(ctx.scope.tenant_id)
      refute Jason.encode!(claims) =~ Relay.ExternalId.encode("ten", ctx.scope.tenant_id)

      assert get(minted["token"], @endpoints)["data"] == []

      reader = F.token(ctx.scope, ["read"])
      assert F.body(F.request(:post, path, reader), 403)["code"] == "auth_insufficient_scope"

      missing = "/v1/webhook_consumers/whc_01j9zq3k4m5n6p7q8r9s0t1v2w/portal_tokens"
      unknown = F.request(:post, missing, ctx.token)
      assert F.body(unknown, 404)["code"] == "webhook_consumer_not_found"

      other = F.request(:post, path, F.token(ctx.tenant.test))
      assert F.body(other, 404)["code"] == "webhook_consumer_not_found"
    end

    test "WH-47: an archived consumer gets no token and its tokens stop at once", ctx do
      consumer = consumer!(ctx)
      path = "/v1/webhook_consumers/#{consumer["id"]}"
      assert get(consumer.token, @endpoints)["data"] == []

      F.body(F.request(:post, path <> "/archive", ctx.token), 200)

      refused = F.body(F.request(:post, path <> "/portal_tokens", ctx.token), 422)
      assert refused["code"] == "webhook_consumer_archived"
      assert get(consumer.token, @endpoints, 401)["code"] == "auth_invalid_token"
    end

    test "WH-47, E-25: only a portal token opens the portal, and a portal token opens nothing else",
         ctx do
      consumer = consumer!(ctx)

      assert get(nil, @endpoints, 401)["code"] == "auth_missing_credentials"
      access = get(ctx.token, @endpoints, 401)["code"]
      assert access in ["auth_invalid_token", "auth_malformed_credentials"]
      assert get(consumer.token <> "x", @endpoints, 401)["code"] == "auth_invalid_token"

      [header, _payload, signature] = String.split(consumer.token, ".")
      {_header, claims} = claims(consumer.token)
      other = consumer!(ctx)
      forged = claims |> Map.put("sub", other["id"]) |> Jason.encode!()
      forged = Enum.join([header, Base.url_encode64(forged, padding: false), signature], ".")
      assert get(forged, @endpoints, 401)["code"] == "auth_invalid_token"

      dpop = F.request(:get, @endpoints, ctx.token)
      assert F.body(dpop, 401)["code"] in ["auth_malformed_credentials", "auth_invalid_token"]

      inbox = Portal.request(:get, "/v1/subscriber/inbox/items", consumer.token)
      assert F.body(inbox, 401)["code"] == "auth_invalid_token"
      {:error, refused} = RelayWeb.Auth.Subscriber.verify(consumer.token)
      assert refused.code == :auth_invalid_token

      server = Portal.request(:get, "/v1/webhook_endpoints", consumer.token)
      assert server.status == 401
    end

    test "WH-47: a portal token is refused after its fifteen minutes", ctx do
      consumer = consumer!(ctx)
      clock = Application.fetch_env!(:relay, :clock)
      on_exit(fn -> Application.put_env(:relay, :clock, clock) end)

      Application.put_env(:relay, :clock, Later)
      expired = Portal.request(:get, @endpoints, consumer.token)
      Application.put_env(:relay, :clock, clock)

      assert F.body(expired, 401)["code"] == "auth_expired_token"
      assert get(consumer.token, @endpoints)["data"] == []
    end
  end

  describe "WH-46 WH-52 endpoints of the portal" do
    test "WH-46, WH-52, WH-45: the portal adds https endpoints to its consumer, at most five",
         ctx do
      consumer = consumer!(ctx)
      body = %{"url" => @url, "event_types" => []}
      created = Portal.request(:post, @endpoints, consumer.token, body)
      endpoint = F.body(created, 201)

      assert %{
               "object" => "webhook_endpoint",
               "environment" => "live",
               "use" => "destination",
               "consumer" => key,
               "consumer_id" => consumer_id,
               "destination" => %{"kind" => "https", "url" => @url},
               "signature_scheme" => "v1a",
               "signing_keys" => [%{"state" => "active", "public_key" => "whpk_" <> _}],
               "secret" => nil,
               "state" => "active"
             } = endpoint

      assert key == consumer["key"] and consumer_id == consumer["id"]

      assert Plug.Conn.get_resp_header(created, "location") ==
               ["/v1/portal/webhook_endpoints/" <> endpoint["id"]]

      assert get(consumer.token, "#{@endpoints}/#{endpoint["id"]}")["id"] == endpoint["id"]
      assert "whsec_" <> _ = endpoint!(consumer.token, %{"signature_scheme" => "v1"})["secret"]

      for extra <- [%{"use" => "relay_events"}, %{"destination" => %{"kind" => "s3"}}] do
        body = Map.merge(%{"url" => @url, "event_types" => []}, extra)
        assert post(consumer.token, @endpoints, body, 422)["code"] == "unknown_field"
      end

      unknown = %{"url" => @url, "event_types" => ["order.never_defined"]}
      assert post(consumer.token, @endpoints, unknown, 422)["code"] == "validation_failed"

      for _ <- 1..3, do: endpoint!(consumer.token)
      full = post(consumer.token, @endpoints, %{"url" => @url, "event_types" => []}, 422)
      assert full["code"] == "webhook_endpoint_limit_reached"
      assert length(get(consumer.token, @endpoints)["data"]) == 5

      server = F.body(F.request(:get, "/v1/webhook_endpoints", ctx.token), 200)
      assert length(server["data"]) == 5
    end

    test "WH-40, WH-54: the portal's address check answers at once and points at url", ctx do
      consumer = consumer!(ctx)

      for url <- ["https://hooks.example.com:8443/x", "https://blocked.example.com/hook"] do
        refused = post(consumer.token, @endpoints, %{"url" => url, "event_types" => []}, 422)
        assert refused["code"] == "webhook_endpoint_url_not_allowed"
        assert [%{"pointer" => "/url", "code" => "not_allowed"}] = refused["errors"]
      end

      endpoint = endpoint!(consumer.token)
      path = "#{@endpoints}/#{endpoint["id"]}"
      moved = patch(consumer.token, path, %{"url" => "https://blocked.example.com/hook"}, 422)
      assert moved["code"] == "webhook_endpoint_url_not_allowed"
      assert [%{"pointer" => "/url"}] = moved["errors"]
      assert get(consumer.token, path)["destination"]["url"] == @url
    end

    test "WH-46, WH-48: adding, changing, disabling, rotating and archiving are audited with the portal actor",
         ctx do
      consumer = consumer!(ctx)
      type = %{"name" => "order.shipped", "schema" => %{"type" => "object"}}
      F.body(F.request(:post, "/v1/webhook_event_types", ctx.token, type), 201)

      endpoint = endpoint!(consumer.token)
      path = "#{@endpoints}/#{endpoint["id"]}"

      change = %{
        "url" => "https://hooks.example.com/moved",
        "event_types" => ["order.shipped"],
        "description" => "orders"
      }

      changed = patch(consumer.token, path, change, 200)
      assert changed["destination"] == %{"kind" => "https", "url" => change["url"]}
      assert changed["event_types"] == ["order.shipped"]
      assert changed["description"] == "orders"

      stale = [{"if-match", ~s("1")}]
      refused = Portal.request(:patch, path, consumer.token, %{"description" => "late"}, stale)
      assert F.body(refused, 412)["code"] == "precondition_failed"

      for field <- ["snapshot", "auto_disable", "max_concurrency", "retry_schedule"] do
        assert patch(consumer.token, path, %{field => nil}, 422)["code"] == "unknown_field"
      end

      assert patch(consumer.token, path, %{"state" => "disabled"}, 200)["state"] == "disabled"
      paused = patch(consumer.token, path, %{"state" => "paused"}, 422)
      assert paused["code"] == "validation_failed"
      assert patch(consumer.token, path, %{"state" => "active"}, 200)["state"] == "active"

      rotated = post(consumer.token, path <> "/rotate_key", nil, 200)
      assert [%{"state" => "active"}, %{"state" => "previous"}] = rotated["signing_keys"]
      assert rotated["previous_key_expires_at"]

      archived = post(consumer.token, path <> "/archive", nil, 200)
      assert %{"state" => "archived", "signing_keys" => []} = archived
      late = patch(consumer.token, path, %{"description" => "late"}, 422)
      assert late["code"] == "webhook_endpoint_archived"
      rotation = post(consumer.token, path <> "/rotate_key", nil, 422)
      assert rotation["code"] == "webhook_endpoint_archived"

      target = Relay.Id.to_string(id!(endpoint["id"], "whe"))

      actor = %{
        "actor_kind" => "api_client",
        "actor_ref" => "webhook_portal:" <> consumer["id"],
        "on_behalf_of_ref" => consumer["id"]
      }

      for action <- ["created", "key_rotated", "archived"] do
        assert [row] = audit(ctx.scope, "webhook_endpoint." <> action, target)
        assert Map.delete(row, "reason") == actor
      end

      updates = audit(ctx.scope, "webhook_endpoint.updated", target)
      assert updates != []
      assert Enum.all?(updates, &(Map.delete(&1, "reason") == actor))
    end

    test "WH-46, WH-14: the portal lists the tenant's active event types with schema and example",
         ctx do
      consumer = consumer!(ctx)

      for name <- ["order.shipped", "order.cancelled"] do
        body = %{
          "name" => name,
          "schema" => %{
            "type" => "object",
            "properties" => %{"order_id" => %{"type" => "string"}}
          },
          "identifiers" => ["order_id"],
          "example" => %{"order_id" => "A-1"}
        }

        F.body(F.request(:post, "/v1/webhook_event_types", ctx.token, body), 201)
      end

      [%{"id" => cancelled}, _shipped] =
        F.body(F.request(:get, "/v1/webhook_event_types", ctx.token), 200)["data"]

      F.body(F.request(:post, "/v1/webhook_event_types/#{cancelled}/archive", ctx.token), 200)

      assert [type] = get(consumer.token, "/v1/portal/webhook_event_types")["data"]

      assert %{
               "name" => "order.shipped",
               "state" => "active",
               "identifiers" => ["order_id"],
               "example" => %{"order_id" => "A-1"},
               "schema" => %{"type" => "object"}
             } = type
    end
  end

  describe "WH-30 WH-31 WH-32 the delivery log of the portal" do
    test "WH-45 (3), WH-30, WH-10: a test event is in the consumer's delivery log with its attempts and the kept answer",
         ctx do
      consumer = consumer!(ctx)
      endpoint = endpoint!(consumer.token)
      sent = failed_test_message!(ctx, consumer.token, endpoint)
      assert %{"origin" => "test", "event_type" => "webhook_endpoint.tested"} = sent

      path = "#{@messages}/#{sent["id"]}"
      message = get(consumer.token, path)
      assert %{"state" => "exhausted", "attempt_count" => 1} = message
      assert message["last_response_status"] == 500
      assert message["endpoint_id"] == endpoint["id"]
      assert message["event_id"] == sent["event_id"]

      assert [listed] = get(consumer.token, @messages)["data"]
      assert listed["id"] == sent["id"]

      filters = [
        {"state=exhausted", 1},
        {"state=delivered", 0},
        {"endpoint_id=" <> endpoint["id"], 1},
        {"event_type=webhook_endpoint.tested", 1},
        {"event_type=order.shipped", 0},
        {"created_after=2099-01-01T00:00:00Z", 0},
        {"created_before=2099-01-01T00:00:00Z", 1}
      ]

      for {filter, count} <- filters do
        assert length(get(consumer.token, @messages <> "?" <> filter)["data"]) == count, filter
      end

      for bad <- ["state=lost", "endpoint_id=whe_x", "created_after=yesterday"] do
        assert get(consumer.token, @messages <> "?" <> bad, 422)["code"] == "validation_failed"
      end

      assert [attempt] = get(consumer.token, path <> "/attempts")["data"]

      assert %{
               "object" => "webhook_attempt",
               "attempt_no" => 1,
               "trigger" => "test",
               "result" => "failed_retryable",
               "failure_code" => "http_5xx",
               "response_status" => 500,
               "destination_ip" => "203.0.114.7"
             } = attempt

      assert attempt["message_id"] == sent["id"] and attempt["endpoint_id"] == endpoint["id"]
      assert attempt["body_digest"] =~ ~r/\A[0-9a-f]{64}\z/
      refute Map.has_key?(attempt, "response_body")

      one = get(consumer.token, "#{path}/attempts/#{attempt["id"]}")

      assert one["response_body"] == %{
               "encoding" => "utf8",
               "content" => "down for maintenance",
               "truncated" => false
             }

      assert Map.delete(one, "response_body") == attempt

      missing = "#{path}/attempts/wha_01j9zq3k4m5n6p7q8r9s0t1v2w"
      assert get(consumer.token, missing, 404)["code"] == "webhook_attempt_not_found"

      unknown = "#{@messages}/whm_01j9zq3k4m5n6p7q8r9s0t1v2w"
      assert get(consumer.token, unknown, 404)["code"] == "webhook_message_not_found"
      attempts = get(consumer.token, unknown <> "/attempts", 404)
      assert attempts["code"] == "webhook_message_not_found"
    end

    test "WH-30 (2), WH-31, WH-37, WH-48: the portal lists the missed events and recovers them, audited",
         ctx do
      consumer = consumer!(ctx)
      endpoint = endpoint!(consumer.token)
      path = "#{@endpoints}/#{endpoint["id"]}"
      tested = failed_test_message!(ctx, consumer.token, endpoint)
      missed = cancelled_message!(ctx, consumer, endpoint)
      delivered = post(consumer.token, path <> "/test", nil, 202)
      assert {:ok, {:attempted, :delivered}} = attempt(ctx, delivered)

      listed = get(consumer.token, path <> "/missed_events")["data"]
      assert Enum.sort(Enum.map(listed, & &1["id"])) == Enum.sort([tested["id"], missed])
      shipped = path <> "/missed_events?event_type=order.shipped"
      assert [only] = get(consumer.token, shipped)["data"]
      assert %{"id" => ^missed, "state" => "cancelled", "origin" => "event"} = only

      late = post(consumer.token, path <> "/recover", %{"since" => "2099-01-01T00:00:00Z"}, 200)
      assert late["selected"] == 0
      assert post(consumer.token, path <> "/recover", %{}, 422)["code"] == "validation_failed"

      assert patch(consumer.token, path, %{"state" => "disabled"}, 200)["state"] == "disabled"
      since = %{"since" => "2026-01-01T00:00:00Z"}
      conflict = post(consumer.token, path <> "/recover", since, 422)
      assert conflict["code"] == "webhook_endpoint_state_conflict"
      assert patch(consumer.token, path, %{"state" => "active"}, 200)["state"] == "active"
      flush()

      recovered = post(consumer.token, path <> "/recover", since, 200)

      assert recovered == %{
               "object" => "webhook_recovery",
               "operation" => "recover",
               "endpoint_id" => endpoint["id"],
               "selected" => 1
             }

      assert_received {:webhook_job, %{worker: Relay.Webhooks.RecoveryWorker, args: args}}
      stored = args |> Jason.encode!() |> Jason.decode!()
      assert :ok = Relay.Webhooks.RecoveryWorker.perform(%Oban.Job{args: stored})

      again = get(consumer.token, "#{@messages}/#{missed}")
      assert %{"state" => "pending", "reason" => nil} = again
      assert again["event_id"] == only["event_id"]
      assert get(consumer.token, "#{@messages}/#{tested["id"]}")["state"] == "exhausted"
      assert get(consumer.token, "#{@messages}/#{delivered["id"]}")["state"] == "delivered"
      assert [%{"id" => left}] = get(consumer.token, path <> "/missed_events")["data"]
      assert left == tested["id"]

      target = Relay.Id.to_string(id!(endpoint["id"], "whe"))
      assert [row, _late] = audit(ctx.scope, "webhook_endpoint.messages_recovered", target)
      assert row["actor_ref"] == "webhook_portal:" <> consumer["id"]
      assert row["on_behalf_of_ref"] == consumer["id"]
    end

    test "WH-32, WH-33 (1), WH-48: the portal resends one message with the same event identifier",
         ctx do
      consumer = consumer!(ctx)
      endpoint = endpoint!(consumer.token)
      path = "#{@endpoints}/#{endpoint["id"]}"
      sent = failed_test_message!(ctx, consumer.token, endpoint)
      flush()

      resent = post(consumer.token, "#{@messages}/#{sent["id"]}/resend", nil, 202)
      assert resent["id"] == sent["id"] and resent["event_id"] == sent["event_id"]
      assert_received {:webhook_job, %{args: %{"manual" => true, "message_id" => queued}}}
      assert queued == Relay.Id.to_string(id!(sent["id"], "whm"))
      assert [row] = audit(ctx.scope, "webhook_message.resent", queued)
      assert row["actor_ref"] == "webhook_portal:" <> consumer["id"]

      assert {:ok, {:attempted, :delivered}} = attempt(ctx, sent, manual: true)

      message = get(consumer.token, "#{@messages}/#{sent["id"]}")
      assert %{"state" => "delivered", "attempt_count" => 2} = message
      attempts = get(consumer.token, "#{@messages}/#{sent["id"]}/attempts")["data"]
      assert Enum.map(attempts, & &1["trigger"]) == ["test", "manual"]
      assert Enum.map(attempts, & &1["attempt_no"]) == [1, 2]

      first = get(consumer.token, "#{@messages}/#{sent["id"]}/attempts?limit=1")
      assert %{"has_more" => true, "data" => [%{"attempt_no" => 1}]} = first
      next = "#{@messages}/#{sent["id"]}/attempts?limit=1&starting_after=#{first["next_cursor"]}"
      assert [%{"attempt_no" => 2}] = get(consumer.token, next)["data"]

      assert post(consumer.token, path <> "/archive", nil, 200)["state"] == "archived"
      refused = post(consumer.token, "#{@messages}/#{sent["id"]}/resend", nil, 422)
      assert refused["code"] == "webhook_endpoint_archived"

      unknown = "#{@messages}/whm_01j9zq3k4m5n6p7q8r9s0t1v2w/resend"
      assert post(consumer.token, unknown, nil, 404)["code"] == "webhook_message_not_found"
    end

    test "WH-39, WH-46: the portal reads the health of its endpoints", ctx do
      consumer = consumer!(ctx)
      endpoint = endpoint!(consumer.token)
      failed_test_message!(ctx, consumer.token, endpoint)

      health = get(consumer.token, "#{@endpoints}/#{endpoint["id"]}/health")
      assert %{"object" => "webhook_endpoint_health", "state" => "active", "failed" => 1} = health
      assert health["endpoint_id"] == endpoint["id"]
      assert health["breaker"]["state"]
    end
  end

  describe "WH-14 WH-53 the event catalog" do
    test "WH-14, WH-53: the catalog lists Relay's event types by name with their versioned schema",
         ctx do
      names = Relay.EventCatalog.names()
      first = F.body(F.request(:get, "/v1/webhook_catalog?limit=2", ctx.token), 200)
      assert %{"object" => "list", "has_more" => true, "previous_cursor" => nil} = first
      assert Enum.map(first["data"], & &1["name"]) == Enum.take(names, 2)

      for event <- first["data"] do
        assert %{"object" => "webhook_catalog_event", "version" => version} = event
        assert event["dataschema"] =~ "/v1/event_schemas/#{event["name"]}/#{version}"
        assert is_map(event["schema"]) and is_binary(event["summary"])
        refute Jason.encode!(event["schema"]) =~ "$ref"
      end

      next = "/v1/webhook_catalog?limit=2&starting_after=" <> first["next_cursor"]
      second = F.body(F.request(:get, next, ctx.token), 200)
      assert Enum.map(second["data"], & &1["name"]) == names |> Enum.drop(2) |> Enum.take(2)

      back = "/v1/webhook_catalog?limit=2&ending_before=" <> second["previous_cursor"]
      assert F.body(F.request(:get, back, ctx.token), 200)["data"] == first["data"]

      reader = F.token(ctx.scope, ["read"])
      all = F.body(F.request(:get, "/v1/webhook_catalog?limit=100", reader), 200)
      assert Enum.map(all["data"], & &1["name"]) == Enum.take(names, 100)
      assert "notification.delivered" in Enum.map(all["data"], & &1["name"])

      publisher = F.token(ctx.scope, ["publish"])
      refused = F.request(:get, "/v1/webhook_catalog", publisher)
      assert F.body(refused, 403)["code"] == "auth_insufficient_scope"
    end
  end

  defp flush do
    receive do
      {:webhook_job, _job} -> flush()
    after
      0 -> :ok
    end
  end
end
