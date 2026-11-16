defmodule Relay.InboxOperationsTest do
  use Relay.DataCase, async: false

  alias Relay.Repo
  alias RelayTest.Api
  alias RelayTest.FakeAccess
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @grant "urn:ietf:params:oauth:grant-type:token-exchange"
  @subject_type "urn:ietf:params:oauth:token-type:access_token"

  setup do
    :ok = FakeAccess.install!()
    tenant = TenantFixture.tenant!()
    scope = tenant.live
    token = F.token(scope)
    F.workflow!(scope, token, "order-shipped", channels: ["in_app"])
    app = FakeAccess.client!(scope, ["read"])
    subscriber = subscriber!(tenant, app)
    %{tenant: tenant, scope: scope, token: token, app: app, subscriber: subscriber}
  end

  defp subscriber!(tenant, app) do
    sub = "pairwise-" <> FakeAccess.random()
    token = FakeAccess.user_token(tenant.attrs.access_tenant_id, app, sub)

    form = %{
      "grant_type" => @grant,
      "subject_token" => token,
      "subject_token_type" => @subject_type
    }

    headers = FakeAccess.exchange_headers(token)

    conn =
      :post
      |> Api.conn("/v1/subscriber/token", URI.encode_query(form), headers)
      |> Api.call(RelayWeb.Router)

    body = F.body(conn, 200)
    {:ok, id} = Relay.ExternalId.decode(body["subscriber_id"], ["sub"])
    %{token: body["access_token"], id: id, sub: sub}
  end

  defp sql!(scope, sql, params) do
    {:ok, rows} = Repo.in_scope(scope, fn _status -> Repo.scoped_query!(sql, params).rows end)
    rows
  end

  defp send!(ctx, order) do
    body = %{
      "workflow" => "order-shipped",
      "to" => [ctx.subscriber.sub],
      "data" => %{"order" => order}
    }

    accepted = F.body(F.request(:post, "/v1/events", ctx.token, body), 202)
    [%{"notification_id" => notification}] = accepted["notifications"]
    path = "/v1/notifications/#{notification}/deliveries"
    [delivery] = F.body(F.request(:get, path, ctx.token), 200)["data"]
    {:ok, delivery_id} = Relay.ExternalId.decode(delivery["id"], ["dlv"])
    deliver!(ctx, delivery_id)
    delivery_id
  end

  defp deliver!(ctx, delivery_id) do
    id = Relay.Id.to_string(delivery_id)
    args = Map.put(Relay.Scope.to_job_args(ctx.scope), "delivery_id", id)
    Relay.Delivery.Send.perform(%Oban.Job{args: args})
    :ok = Relay.Channels.Live.deliver(ctx.scope, delivery_id, args)
  end

  defp mine(ctx, method, path, body \\ nil),
    do: F.request(method, "/v1/subscriber/inbox" <> path, ctx.subscriber.token, body)

  defp items(ctx, query \\ ""), do: F.body(mine(ctx, :get, "/items" <> query), 200)

  defp announce!(ctx, extra \\ %{}) do
    content = %{"title" => "Bakım", "body" => "Yarın bakım var."}
    body = Map.merge(%{"audience" => "tenant", "content" => content}, extra)
    F.body(F.request(:post, "/v1/inbox/announcements", ctx.token, body), 201)
  end

  defp states(ctx),
    do: sql!(ctx.scope, "SELECT count(*)::integer FROM relay.inbox_announcement_states", [])

  describe "IN-50 X-17 mark all read" do
    test "IN-50, X-17: every unread item is read in one write with one bulk publication and nothing is archived",
         ctx do
      send!(ctx, "A-1")
      send!(ctx, "A-2")
      assert %{"unread" => 2, "unseen" => 2, "total" => 2} = items(ctx)["counters"]

      body = F.body(mine(ctx, :post, "/read_all", %{}), 200)
      assert %{"object" => "inbox_read_all_result", "scope" => "all", "updated" => 2} = body
      assert %{"unread" => 0, "unseen" => 0, "total" => 2} = body["counters"]

      listed = items(ctx)["data"]
      assert length(listed) == 2
      assert Enum.all?(listed, &(&1["read"] and &1["seen"] and not &1["archived"]))
      assert Enum.all?(listed, &(&1["state_version"] == 2))

      events =
        sql!(
          ctx.scope,
          """
          SELECT o.event_type FROM relay.outbox_events o
          JOIN relay.mailboxes m ON m.stream_key = o.stream_key
          WHERE m.owner_ref = $1 AND o.event_type LIKE 'inbox.%' ORDER BY o.seq
          """,
          [ctx.subscriber.id]
        )

      assert Enum.count(events, &(&1 == ["inbox.items_bulk_updated"])) == 1
      assert List.last(events) == ["inbox.counters_changed"]
      assert F.body(mine(ctx, :post, "/read_all", %{}), 200)["updated"] == 0
    end

    test "IN-14, X-17: mark all read of another category leaves the items unread", ctx do
      send!(ctx, "A-1")
      body = F.body(mine(ctx, :post, "/read_all", %{"category" => "elsewhere"}), 200)
      assert %{"scope" => "category", "category" => "elsewhere", "updated" => 0} = body
      assert body["counters"]["unread"] == 1
    end

    test "IN-50, IN-3: the read mark reads earlier announcements without a row per recipient",
         ctx do
      announce!(ctx)
      assert %{"unread" => 1, "total" => 1} = items(ctx)["counters"]

      F.body(mine(ctx, :post, "/read_all", %{}), 200)

      assert [%{"kind" => "announcement", "read" => true}] = items(ctx)["data"]
      assert [[0]] = states(ctx)

      announce!(ctx)
      assert items(ctx)["counters"]["unread"] == 1
    end
  end

  describe "IN-14 asynchronous bulk actions" do
    test "IN-14: a bulk archive runs in chunks as a job and reports its progress", ctx do
      send!(ctx, "A-1")
      send!(ctx, "A-2")

      started = F.body(mine(ctx, :post, "/bulk", %{"action" => "archive"}), 202)
      assert %{"object" => "inbox_bulk_operation", "state" => "running"} = started

      for [id] <- F.jobs("Relay.Inbox.BulkJob", ctx.scope, "operation_id") do
        args = Map.put(Relay.Scope.to_job_args(ctx.scope), "operation_id", id)
        assert :ok = Relay.Inbox.BulkJob.perform(%Oban.Job{args: args})
      end

      done = F.body(mine(ctx, :get, "/bulk/#{started["id"]}"), 200)
      assert %{"state" => "completed", "matched" => 2, "updated" => 2} = done

      assert items(ctx)["data"] == []
      assert length(items(ctx, "?status=archived")["data"]) == 2
      assert items(ctx)["counters"]["total"] == 0
    end

    test "IN-14: an unknown action and another subscriber's operation are refused", ctx do
      conn = mine(ctx, :post, "/bulk", %{"action" => "delete"})
      assert F.body(conn, 422)["code"] == "validation_failed"

      missing = Relay.ExternalId.encode("ibk", Relay.Id.generate())

      conn = mine(ctx, :get, "/bulk/#{missing}")
      assert F.body(conn, 404)["code"] == "inbox_bulk_operation_not_found"
    end
  end

  describe "IN-3 C-70 announcements" do
    test "IN-3, C-70, API-35: one record merges into the list, the counters and the delta", ctx do
      send!(ctx, "A-1")
      first = items(ctx)
      announcement = announce!(ctx, %{"category" => "maintenance"})
      assert %{"object" => "inbox_announcement", "state" => "active"} = announcement

      listed = items(ctx)
      assert [%{"kind" => "announcement", "id" => id}, %{"kind" => "personal"}] = listed["data"]
      assert id == announcement["id"]
      assert %{"total" => 2, "unread" => 2} = listed["counters"]
      assert listed["counters"]["version"] > first["counters"]["version"]

      changes = F.body(mine(ctx, :get, "/changes?since=#{first["cursor"]}"), 200)
      assert [%{"type" => "created", "item_id" => ^id}] = changes["changes"]

      assert [[0]] = states(ctx)
      assert F.body(mine(ctx, :get, "/items/#{id}"), 200)["title"] == "Bakım"
    end

    test "IN-3, IN-12: a recipient's intent on an announcement writes its own state only", ctx do
      %{"id" => id} = announce!(ctx)
      path = "/items/#{id}/intents"

      read = F.body(mine(ctx, :post, path, %{"op" => "read"}), 200)
      assert %{"result" => "applied", "item_id" => ^id} = read
      assert %{"read" => true, "state_version" => 2} = read["state"]
      assert read["counters"]["unread"] == 0

      conn = mine(ctx, :post, path, %{"op" => "snooze"})
      assert F.body(conn, 422)["code"] == "validation_failed"

      F.body(mine(ctx, :post, path, %{"op" => "hide"}), 200)
      assert items(ctx)["data"] == []
      assert [[1]] = states(ctx)
    end

    test "IN-16, IN-3: a retracted announcement leaves every list and counter", ctx do
      %{"id" => id} = announce!(ctx)
      before = items(ctx)

      path = "/v1/inbox/announcements/#{id}"
      retracted = F.body(F.request(:post, path <> "/retract", ctx.token, %{}), 200)
      assert retracted["state"] == "retracted"

      after_retract = items(ctx)
      assert after_retract["data"] == []
      assert after_retract["counters"]["total"] == 0

      changes = F.body(mine(ctx, :get, "/changes?since=#{before["cursor"]}"), 200)
      assert [%{"type" => "removed", "item_id" => ^id}] = changes["changes"]
      assert F.body(F.request(:get, path, ctx.token), 200)["state"] == "retracted"
    end

    test "IN-49, IN-3: content over the inbox limits and an unknown topic are refused", ctx do
      long = %{"audience" => "tenant", "content" => %{"title" => String.duplicate("a", 600)}}
      conn = F.request(:post, "/v1/inbox/announcements", ctx.token, long)
      assert F.body(conn, 422)["code"] == "validation_failed"

      topic = %{"audience" => "topic", "topic" => "nope", "content" => %{"title" => "x"}}
      conn = F.request(:post, "/v1/inbox/announcements", ctx.token, topic)
      assert F.body(conn, 422)["code"] == "validation_failed"
    end
  end

  describe "IN-18 IN-21 reconciliation" do
    test "IN-21: a client report reconciles the counters at once", ctx do
      send!(ctx, "A-1")
      body = F.body(mine(ctx, :post, "/counters/inconsistency"), 200)
      assert %{"object" => "inbox_reconciliation", "result" => "consistent"} = body
      assert body["counters"]["total"] == 1
    end

    test "IN-18, OP-42: the nightly pass checks the recipients changed in the last day", ctx do
      send!(ctx, "A-1")
      since = DateTime.add(Relay.Clock.utc_now(), -86_400, :second)

      assert {:ok, %{checked: 1, repaired: 0, last: last}} =
               Relay.Inbox.reconcile_changed(ctx.scope, since, nil, 200)

      assert last == ctx.subscriber.id
    end
  end

  describe "IN-44 OP-22 retention" do
    test "IN-44, OP-22: items beyond the visible window leave the list and the counters", ctx do
      change = %{
        key: "inbox.retention",
        value: %{"visible_items" => 1},
        expected_version: nil,
        record_digest: TenantFixture.digest()
      }

      assert {:ok, _} = Relay.Tenancy.put_setting(ctx.scope, change, TenantFixture.actor())

      send!(ctx, "A-1")
      send!(ctx, "A-2")

      listed = items(ctx)
      assert [_newest] = listed["data"]
      assert listed["counters"]["total"] == 1

      assert [["retention"]] =
               sql!(
                 ctx.scope,
                 "SELECT hidden_reason FROM relay.inbox_items WHERE hidden_at IS NOT NULL",
                 []
               )

      raised = %{change | value: %{"visible_items" => 1001}}

      assert {:error, %Relay.Error{code: :invalid_setting}} =
               Relay.Tenancy.put_setting(ctx.scope, raised, TenantFixture.actor())

      assert {:ok, 0} = Relay.Inbox.retire_due(ctx.scope, 100)
      assert Relay.Inbox.retention_defaults()["visible_items"] == 1000
    end
  end

  describe "DS-7 WF-27 IN-35 evidence and signals" do
    test "DS-7, DS-12: an inbox read is the engagement evidence of the in-app delivery", ctx do
      delivery_id = send!(ctx, "A-1")
      [item] = items(ctx)["data"]
      F.body(mine(ctx, :post, "/items/#{item["id"]}/intents", %{"op" => "click"}), 200)

      ledger =
        sql!(
          ctx.scope,
          """
          SELECT event_type, actor, detail->'engagement'->>'source' FROM relay.delivery_events
          WHERE delivery_id = $1 AND event_type LIKE 'engagement.%' ORDER BY received_at, id
          """,
          [delivery_id]
        )

      assert ["engagement.clicked", "user", "inbox_action"] in ledger
      assert ["engagement.read", "user", "inbox_action"] in ledger

      assert [["inbox_action", "inbox_action"]] =
               sql!(
                 ctx.scope,
                 "SELECT read_source, clicked_source FROM relay.deliveries WHERE id = $1",
                 [delivery_id]
               )
    end

    test "IN-35: a new in-app item queues a sync signal to the devices", ctx do
      send!(ctx, "A-1")
      signals = F.jobs("Relay.Devices.SignalJob", ctx.scope, "kind")
      assert ["sync"] in signals
    end
  end

  describe "IN-52 snapshot limits" do
    test "IN-52: the snapshot endpoints answer 429 with Retry-After past the recipient rate",
         ctx do
      limit = Relay.Limits.fetch!(["inbox", "snapshot_per_recipient_per_minute"])
      for _ <- 1..limit, do: F.body(mine(ctx, :get, "/counters"), 200)

      conn = mine(ctx, :get, "/counters")
      assert F.body(conn, 429)["code"] == "rate_limited"
      assert [_seconds] = Plug.Conn.get_resp_header(conn, "retry-after")
    end
  end
end
