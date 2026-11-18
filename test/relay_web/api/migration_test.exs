defmodule RelayWeb.Api.MigrationTest do
  use Relay.DataCase, async: false

  alias Relay.Repo
  alias Relay.Webhooks.EngineStore
  alias RelayTest.Api
  alias RelayTest.FakeAccess
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @grant "urn:ietf:params:oauth:grant-type:token-exchange"
  @subject_type "urn:ietf:params:oauth:token-type:access_token"

  setup do
    tenant = TenantFixture.tenant!()
    scope = tenant.live
    token = F.token(scope)
    F.workflow!(scope, token, "order-shipped")
    %{tenant: tenant, scope: scope, token: token}
  end

  defp put_mode(scope, mode) do
    attrs = %{category: nil, channel: nil, mode: mode}
    {:ok, _row} = Relay.Operators.Admin.set_send_mode(scope, attrs, TenantFixture.actor(), nil)
    :ok
  end

  defp send!(ctx, external_id, extra \\ %{}) do
    body =
      Map.merge(
        %{
          "workflow" => "order-shipped",
          "to" => [%{"id" => external_id, "email" => "ayse@example.com"}],
          "data" => %{"order" => "A-1"}
        },
        extra
      )

    accepted = F.body(F.request(:post, "/v1/events", ctx.token, body), 202)
    [%{"notification_id" => notification}] = accepted["notifications"]
    path = "/v1/notifications/#{notification}/deliveries"
    [delivery] = F.body(F.request(:get, path, ctx.token), 200)["data"]
    delivery
  end

  defp deliver!(ctx, delivery) do
    {:ok, delivery_id} = Relay.ExternalId.decode(delivery["id"], ["dlv"])
    id = Relay.Id.to_string(delivery_id)
    args = Map.put(Relay.Scope.to_job_args(ctx.scope), "delivery_id", id)
    Relay.Delivery.Send.perform(%Oban.Job{args: args})
    _result = Relay.Channels.Live.deliver(ctx.scope, delivery_id, args)
    :ok
  end

  defp audit(scope, action) do
    now = DateTime.utc_now()
    actor = TenantFixture.actor()

    {:ok, rows} =
      Repo.in_scope(scope, fn _status ->
        Repo.call!(
          "relay_fn.audit_query",
          [DateTime.add(now, -3_600), DateTime.add(now, 3_600), action, nil, 1_000] ++
            [TenantFixture.digest() | Relay.Actor.params(actor)]
        )
      end)

    rows
  end

  defp observation(correlation_id, outcomes) do
    %{
      "correlation_id" => correlation_id,
      "template" => "order-shipped",
      "locale" => "tr",
      "channels" => [%{"channel" => "email", "outcomes" => outcomes}]
    }
  end

  defp outcome(external_id, decision \\ "sent", consent \\ "allowed") do
    %{
      "external_id" => external_id,
      "decision" => decision,
      "consent" => consent,
      "timing" => "none"
    }
  end

  defp expires(days), do: DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), days * 86_400))

  describe "OP-94 shadow comparison" do
    test "OP-94: a matching report of a shadow send is compared and covered, and İYS is never called",
         ctx do
      start_supervised!({RelayTest.IysFake, []})
      :ok = put_mode(ctx.scope, "shadow")
      external_id = "user-" <> TenantFixture.random()

      delivery = send!(ctx, external_id, %{"correlation_id" => "req-1"})
      :ok = deliver!(ctx, delivery)

      body = observation("req-1", [outcome(external_id)])
      answer = F.body(F.request(:post, "/v1/shadow/observations", ctx.token, body), 202)

      assert %{"object" => "shadow_observation", "recorded" => 1, "unknown_recipients" => 0} =
               answer

      assert answer["compared"] == 1

      coverage = F.body(F.request(:get, "/v1/shadow/coverage", ctx.token), 200)
      assert coverage["window_days"] == 14
      refute coverage["exit_criteria_met"]

      assert [%{"template" => "order-shipped", "channel" => "email", "observed" => 1} = row] =
               coverage["rows"]

      assert row["decision_differences"] == 0
      assert RelayTest.IysFake.calls() == []
    end

    test "OP-79: a decision difference is unexplained until an intentional difference covers it",
         ctx do
      :ok = put_mode(ctx.scope, "shadow")
      external_id = "user-" <> TenantFixture.random()
      _delivery = send!(ctx, external_id, %{"correlation_id" => "req-2"})

      body = observation("req-2", [outcome(external_id, "skipped", "refused"), outcome("nobody")])
      answer = F.body(F.request(:post, "/v1/shadow/observations", ctx.token, body), 202)
      assert %{"recorded" => 1, "unknown_recipients" => 1} = answer

      coverage = F.body(F.request(:get, "/v1/shadow/coverage", ctx.token), 200)
      assert coverage["unexplained_decision_differences"] == 1

      difference = %{
        "layer" => "decision",
        "template" => "order-shipped",
        "owner" => "migration-team",
        "reason" => "the old system refuses this consent kind",
        "expires_at" => expires(7)
      }

      created = F.body(F.request(:post, "/v1/shadow/differences", ctx.token, difference), 201)
      assert %{"object" => "shadow_difference", "state" => "active", "renewals" => 0} = created
      assert [_record] = audit(ctx.scope, "shadow_difference.created")

      coverage = F.body(F.request(:get, "/v1/shadow/coverage", ctx.token), 200)
      assert coverage["unexplained_decision_differences"] == 0
      assert coverage["active_intentional_differences"] == 1
      assert [%{"explained" => 1}] = coverage["rows"]
    end

    test "OP-79: an intentional difference expires within 30 days and its renewal is audited",
         ctx do
      difference = %{
        "layer" => "content",
        "owner" => "migration-team",
        "reason" => "one-time codes differ",
        "expires_at" => expires(31)
      }

      refused = F.request(:post, "/v1/shadow/differences", ctx.token, difference)
      assert F.body(refused, 422)["code"] == "validation_failed"

      created =
        F.body(
          F.request(:post, "/v1/shadow/differences", ctx.token, %{
            difference
            | "expires_at" => expires(5)
          }),
          201
        )

      renew = %{"expires_at" => expires(29), "reason" => "still needed"}
      path = "/v1/shadow/differences/#{created["id"]}/renew"
      renewed = F.body(F.request(:post, path, ctx.token, renew), 200)
      assert renewed["renewals"] == 1
      assert [_record] = audit(ctx.scope, "shadow_difference.renewed")

      list = F.body(F.request(:get, "/v1/shadow/differences", ctx.token), 200)
      assert [%{"id" => id}] = list["data"]
      assert id == created["id"]

      missing = "/v1/shadow/differences/sdf_01j9zq3k4m5n6p7q8r9s0t1v2w/renew"
      gone = F.request(:post, missing, ctx.token, renew)
      assert F.body(gone, 404)["code"] == "shadow_difference_not_found"
    end

    test "OP-52 (1): an event of a shadow send goes only to the endpoints marked shadow", ctx do
      live = endpoint!(ctx)
      shadow = endpoint!(ctx)
      path = "/v1/webhook_endpoints/#{shadow["id"]}/shadow"
      marked = F.body(F.request(:post, path, ctx.token, %{"shadow" => true}), 200)
      assert marked["shadow"] == true
      assert [_record | _rest] = audit(ctx.scope, "webhook_endpoint.updated")

      {:ok, ids} =
        Repo.in_scope(ctx.scope, fn _status ->
          shadow_ids = EngineStore.subscribers("notification.delivered", true, true)
          live_ids = EngineStore.subscribers("notification.delivered", true)
          {Enum.map(shadow_ids, & &1["id"]), Enum.map(live_ids, & &1["id"])}
        end)

      assert ids == {[uuid(shadow["id"])], [uuid(live["id"])]}
    end
  end

  defp endpoint!(ctx) do
    body = %{
      "use" => "relay_events",
      "destination" => %{"kind" => "https", "url" => "https://hooks.example.com/relay"},
      "event_types" => ["notification.delivered"]
    }

    F.body(F.request(:post, "/v1/webhook_endpoints", ctx.token, body), 201)
  end

  defp uuid(id) do
    {:ok, uuid} = Relay.ExternalId.decode(id, ["whe"])
    uuid
  end

  describe "OP-95 staged rollout" do
    test "OP-95: pinned lists and categories route recipients, legacy ones skipped with the rule",
         ctx do
      body = %{
        "generation" => 0,
        "relay_list" => ["user-relay"],
        "legacy_list" => ["user-legacy"],
        "enabled_categories" => [],
        "basis_points" => %{}
      }

      rollout = F.body(F.request(:put, "/v1/rollout", ctx.token, body), 200)
      assert %{"object" => "rollout", "generation" => 1, "emergency_stop" => false} = rollout
      assert [_digest] = rollout["relay_list"]
      assert [_record] = audit(ctx.scope, "rollout.updated")

      assert %{"status" => "skipped", "reason" => "routed_to_legacy"} = send!(ctx, "user-legacy")
      assert %{"status" => "skipped", "reason" => "routed_to_legacy"} = send!(ctx, "user-other")
      assert %{"status" => "queued"} = send!(ctx, "user-relay")
    end

    test "OP-53: the ramp rule and the generation are checked on every replacement", ctx do
      base = %{
        "generation" => 0,
        "relay_list" => [],
        "legacy_list" => [],
        "enabled_categories" => ["orders"]
      }

      too_far = Map.put(base, "basis_points", %{"orders" => 500})
      refused = F.body(F.request(:put, "/v1/rollout", ctx.token, too_far), 422)
      assert [%{"pointer" => "/basis_points/orders"}] = refused["errors"]

      first = Map.put(base, "basis_points", %{"orders" => 100})
      assert %{"generation" => 1} = F.body(F.request(:put, "/v1/rollout", ctx.token, first), 200)

      stale = F.request(:put, "/v1/rollout", ctx.token, first)
      assert F.body(stale, 409)["code"] == "resource_conflict"

      soon = %{first | "generation" => 1, "basis_points" => %{"orders" => 200}}
      assert F.body(F.request(:put, "/v1/rollout", ctx.token, soon), 422)["errors"] != []

      back = %{first | "generation" => 1, "basis_points" => %{"orders" => 0}}
      assert %{"generation" => 2} = F.body(F.request(:put, "/v1/rollout", ctx.token, back), 200)
    end

    test "OP-53: the emergency stop is one call that routes everything away and opens an incident",
         ctx do
      reason = %{"reason" => "duplicates seen"}
      stopped = F.body(F.request(:post, "/v1/rollout/emergency_stop", ctx.token, reason), 200)
      assert %{"emergency_stop" => true, "stop_reason" => "duplicates seen"} = stopped
      assert [_record] = audit(ctx.scope, "rollout.emergency_stopped")
      assert [_record] = audit(ctx.scope, "incident.opened")

      assert %{"status" => "skipped", "reason" => "routed_to_legacy"} = send!(ctx, "user-1")

      path = "/v1/rollout/emergency_stop/release"
      released = F.body(F.request(:post, path, ctx.token, %{"reason" => "fixed"}), 200)
      assert released["emergency_stop"] == false
      assert %{"status" => "queued"} = send!(ctx, "user-2")

      again = F.request(:post, path, ctx.token, %{"reason" => "fixed"})
      assert F.body(again, 409)["code"] == "resource_conflict"
    end
  end

  describe "OP-54 dual-send prevention" do
    test "OP-54: a key the existing system claimed is skipped by Relay, and Relay's key is a duplicate",
         ctx do
      claim = %{"key" => "order-77", "ttl_seconds" => 3_600}
      claimed = F.body(F.request(:post, "/v1/dedup/claims", ctx.token, claim), 200)
      assert %{"result" => "claimed", "claimed_by" => "legacy"} = claimed

      again = F.body(F.request(:post, "/v1/dedup/claims", ctx.token, claim), 200)
      assert %{"result" => "duplicate", "claimed_by" => "legacy"} = again

      skipped = send!(ctx, "user-1", %{"dedup_key" => "order-77"})
      assert %{"status" => "skipped", "reason" => "dedup_claimed"} = skipped

      _sent = send!(ctx, "user-2", %{"dedup_key" => "order-78"})
      later = %{claim | "key" => "order-78"}
      relay = F.body(F.request(:post, "/v1/dedup/claims", ctx.token, later), 200)
      assert %{"result" => "duplicate", "claimed_by" => "relay", "expires_at" => nil} = relay
    end

    test "OP-95: the SDK's displayed digests count duplicates per subscriber", ctx do
      :ok = FakeAccess.install!()
      subscriber = subscriber!(ctx.tenant, FakeAccess.client!(ctx.scope, ["read"]))
      digest = Base.encode16(:crypto.hash(:sha256, "ntf_1"), case: :lower)
      other = Base.encode16(:crypto.hash(:sha256, "ntf_2"), case: :lower)
      at = DateTime.to_iso8601(DateTime.utc_now())

      body = %{
        "notifications" => [
          %{"digest" => digest, "displayed_at" => at},
          %{"digest" => other, "displayed_at" => at},
          %{"digest" => digest, "displayed_at" => at}
        ]
      }

      path = "/v1/subscriber/displayed_notifications"
      answer = F.body(F.request(:post, path, subscriber.token, body), 202)

      assert %{"object" => "displayed_notifications", "accepted" => 3, "duplicates" => 1} =
               answer
    end
  end

  defp subscriber!(tenant, app) do
    sub = "pairwise-" <> FakeAccess.random()
    token = FakeAccess.user_token(tenant.attrs.access_tenant_id, app, sub)

    form = %{
      "grant_type" => @grant,
      "subject_token" => token,
      "subject_token_type" => @subject_type,
      "scope" => "devices:write"
    }

    headers = FakeAccess.exchange_headers(token)

    conn =
      :post
      |> Api.conn("/v1/subscriber/token", URI.encode_query(form), headers)
      |> Api.call(RelayWeb.Router)

    %{token: F.body(conn, 200)["access_token"]}
  end
end
