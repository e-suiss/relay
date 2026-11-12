defmodule Relay.InboxTest do
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

  defp send!(ctx, extra \\ %{}) do
    base = %{
      "workflow" => "order-shipped",
      "to" => [ctx.subscriber.sub],
      "data" => %{"order" => "A-1"}
    }

    accepted = F.body(F.request(:post, "/v1/events", ctx.token, Map.merge(base, extra)), 202)
    [%{"notification_id" => notification}] = accepted["notifications"]
    path = "/v1/notifications/#{notification}/deliveries"
    [delivery] = F.body(F.request(:get, path, ctx.token), 200)["data"]
    {:ok, delivery_id} = Relay.ExternalId.decode(delivery["id"], ["dlv"])
    %{notification: notification, delivery_id: delivery_id}
  end

  defp deliver!(ctx, sent) do
    id = Relay.Id.to_string(sent.delivery_id)
    args = Map.put(Relay.Scope.to_job_args(ctx.scope), "delivery_id", id)
    Relay.Delivery.Send.perform(%Oban.Job{args: args})
    Relay.Channels.Live.deliver(ctx.scope, sent.delivery_id, args)
  end

  defp mine(ctx, method, path, body \\ nil),
    do: F.request(method, "/v1/subscriber/inbox" <> path, ctx.subscriber.token, body)

  defp items!(ctx) do
    {:ok, snapshot} = Relay.Inbox.snapshot(ctx.scope, ctx.subscriber.id)
    snapshot
  end

  defp intent!(ctx, item, op, extra \\ %{}) do
    path = "/items/#{item["id"]}/intents"
    mine(ctx, :post, path, Map.merge(%{"op" => op}, extra))
  end

  describe "IN-2 IN-5 the in-app write path" do
    test "IN-2, IN-5: an in-app delivery writes one item, and its commit is the delivered evidence",
         ctx do
      sent = send!(ctx)
      assert :ok = deliver!(ctx, sent)
      assert :ok = deliver!(ctx, sent)

      snapshot = items!(ctx)
      assert [item] = snapshot.items
      assert %{"title" => "Sipariş", "body" => "Siparişiniz kargoda."} = item
      assert item["state_version"] == 1
      assert %{"seen" => false, "read" => false, "archived" => false, "hidden" => false} = item
      assert %{unseen: 1, unread: 1, total: 1, version: 1} = snapshot.counters

      assert [[2]] =
               sql!(ctx.scope, "SELECT delivery_rank FROM relay.deliveries WHERE id = $1", [
                 sent.delivery_id
               ])

      assert [["created"]] =
               sql!(
                 ctx.scope,
                 "SELECT outcome FROM relay.inbox_item_deliveries WHERE delivery_id = $1",
                 [sent.delivery_id]
               )
    end

    test "IN-25, IN-22: the item, its counters and its sequenced stream event commit together",
         ctx do
      deliver!(ctx, send!(ctx))

      events =
        sql!(
          ctx.scope,
          """
          SELECT o.event_type, o.seq FROM relay.outbox_events o
          JOIN relay.mailboxes m ON m.stream_key = o.stream_key
          WHERE m.owner_ref = $1 ORDER BY o.seq
          """,
          [ctx.subscriber.id]
        )

      assert [["inbox.item_created", seq]] = events
      assert %{cursor: %{seq: ^seq}} = items!(ctx)
    end

    test "IN-49: content over the published limits fails the delivery without retry", ctx do
      long = String.duplicate("a", 600)
      cells = %{"in_app" => %{"title" => long, "body" => "Siparişiniz kargoda."}}
      F.publish_template!(ctx.scope, "order-shipped", F.template_definition(cells))
      sent = send!(ctx)
      assert :ok = deliver!(ctx, sent)

      assert [["failed", "inbox_item_too_large"]] =
               sql!(
                 ctx.scope,
                 "SELECT failure_kind::text, failure_reason FROM relay.deliveries WHERE id = $1",
                 [sent.delivery_id]
               )

      assert items!(ctx).items == []
    end

    test "IN-49: the limits are published in the contract" do
      limits = Relay.Limits.fetch!(["inbox"])
      assert limits["title_max_bytes"] == 512
      assert limits["body_max_bytes"] == 8192
      assert limits["actions_max"] == 3
      assert limits["item_max_bytes"] == 16_384
      assert limits["realtime_item_max_bytes"] == 8192
    end

    test "IN-46: retention none with an in-app step is refused at acceptance", ctx do
      body = %{
        "workflow" => "order-shipped",
        "to" => [ctx.subscriber.sub],
        "data" => %{"order" => "A-1"},
        "retention" => "none"
      }

      assert F.body(F.request(:post, "/v1/events", ctx.token, body), 422)["code"] ==
               "validation_failed"
    end
  end

  describe "IN-9 IN-12 states and intents" do
    setup ctx do
      deliver!(ctx, send!(ctx))
      [item] = items!(ctx).items
      %{item: item}
    end

    test "IN-9, IN-10: read also marks seen, and seen and read count apart", ctx do
      body = F.body(intent!(ctx, ctx.item, "seen", %{"client_seq" => 1}), 200)

      assert %{"result" => "applied", "client_seq" => 1} = body
      assert %{"seen" => true, "read" => false, "state_version" => 2} = body["state"]
      assert %{"unseen" => 0, "unread" => 1, "total" => 1} = body["counters"]

      body = F.body(intent!(ctx, ctx.item, "read"), 200)
      assert %{"seen" => true, "read" => true, "state_version" => 3} = body["state"]
      assert %{"unseen" => 0, "unread" => 0, "version" => 3} = body["counters"]
    end

    test "IN-12: monotone intents are idempotent and reverse ones need the current version",
         ctx do
      F.body(intent!(ctx, ctx.item, "read"), 200)
      assert F.body(intent!(ctx, ctx.item, "read"), 200)["result"] == "unchanged"

      conflict = F.body(intent!(ctx, ctx.item, "unread", %{"base_state_version" => 1}), 409)
      assert conflict["code"] == "inbox_item_conflict"
      assert %{"read" => true, "state_version" => 2} = conflict["current"]

      body = F.body(intent!(ctx, ctx.item, "unread", %{"base_state_version" => 2}), 200)
      assert %{"read" => false, "state_version" => 3} = body["state"]
      assert body["counters"]["unread"] == 1
    end

    test "IN-9, IN-11: archive and unarchive move the item between tabs", ctx do
      F.body(intent!(ctx, ctx.item, "archive"), 200)
      assert F.body(mine(ctx, :get, "/items"), 200)["data"] == []

      archived = F.body(mine(ctx, :get, "/items?status=archived"), 200)["data"]
      assert [%{"archived" => true}] = archived
      assert F.body(mine(ctx, :get, "/counters"), 200)["total"] == 0

      F.body(intent!(ctx, ctx.item, "unarchive", %{"base_state_version" => 2}), 200)
      assert [%{"archived" => false}] = F.body(mine(ctx, :get, "/items"), 200)["data"]
    end

    test "IN-9, IN-44: hide is terminal for the user and the row stays", ctx do
      F.body(intent!(ctx, ctx.item, "hide"), 200)

      assert F.body(mine(ctx, :get, "/items/#{ctx.item["id"]}"), 404)["code"] ==
               "inbox_item_not_found"

      assert F.body(intent!(ctx, ctx.item, "read"), 200)["result"] == "unchanged"
      assert [[1]] = sql!(ctx.scope, "SELECT count(*)::integer FROM relay.inbox_items", [])
    end

    test "IN-9, IN-17: a snooze leaves the list and queues the item's timer", ctx do
      until = DateTime.add(Relay.Clock.utc_now(), 3600, :second)
      snooze = %{"snooze_until" => DateTime.to_iso8601(until)}
      F.body(intent!(ctx, ctx.item, "snooze", snooze), 200)

      assert F.body(mine(ctx, :get, "/items"), 200)["data"] == []
      assert [_snoozed] = F.body(mine(ctx, :get, "/items?status=snoozed"), 200)["data"]
      assert F.jobs("Relay.Inbox.Timer", ctx.scope, "item_id") != []
    end
  end

  describe "IN-29 IN-30 the client surface" do
    setup ctx do
      deliver!(ctx, send!(ctx))
      :ok
    end

    test "IN-29, IN-30: the first page is the cold sync with counters and the stream cursor",
         ctx do
      body = F.body(mine(ctx, :get, "/items"), 200)

      assert [%{"object" => "inbox_item", "title" => "Sipariş"} = item] = body["data"]
      assert %{"unseen" => 1, "unread" => 1, "total" => 1} = body["counters"]
      assert is_binary(body["cursor"])
      assert body["has_more"] == false

      assert F.body(mine(ctx, :get, "/items/#{item["id"]}"), 200)["id"] == item["id"]
    end

    test "IN-29, IN-22: the delta returns changes after the cursor and asks for a resync on another epoch",
         ctx do
      first = F.body(mine(ctx, :get, "/items"), 200)
      [item] = first["data"]
      F.body(intent!(ctx, item, "read"), 200)

      changes = F.body(mine(ctx, :get, "/changes?since=#{first["cursor"]}"), 200)
      assert [%{"type" => "updated", "state_version" => 2}] = changes["changes"]
      assert changes["truncated"] == false
      assert changes["resync_required"] == false

      again = F.body(mine(ctx, :get, "/changes?since=#{changes["cursor"]}"), 200)
      assert again["changes"] == []

      stale = Relay.Inbox.encode_cursor(%{epoch: 99, seq: 0})
      resync = F.body(mine(ctx, :get, "/changes?since=#{stale}"), 200)
      assert %{"resync_required" => true, "resync_reason" => "epoch_changed"} = resync
    end

    test "IN-26, IN-27: realtime messages carry the counters and the item", ctx do
      {:ok, page} = Relay.Inbox.delta(ctx.scope, ctx.subscriber.id, %{epoch: 1, seq: 0})
      messages = Relay.Inbox.realtime_messages(page)

      assert [{_cursor, created}, {_tail, counters}] = messages
      assert %{"t" => "inbox.item_created", "v" => 1, "counters" => %{"total" => 1}} = created
      assert created["d"]["item"]["title"] == "Sipariş"
      assert counters["t"] == "inbox.counters_changed"

      {:ok, head} = Relay.Inbox.cursor(ctx.scope, ctx.subscriber.id)
      start = Relay.Inbox.encode_cursor(%{epoch: 1, seq: 0})
      {:ok, source} = Relay.Inbox.changes(ctx.scope, ctx.subscriber.id, start, 100)
      assert [%{t: "inbox.item_created"}, %{t: "inbox.counters_changed"}] = source.changes
      assert source.cursor == head
      assert {:ok, topic} = Relay.Inbox.signal_topic(ctx.scope, ctx.subscriber.id)
      assert is_binary(topic)
    end

    test "IN-43: a server token is refused on the client surface", ctx do
      assert F.request(:get, "/v1/subscriber/inbox/counters", ctx.token).status == 401
    end
  end

  describe "IN-16 retraction" do
    test "IN-16, API-59: cancelling a delivered notification retracts its item", ctx do
      sent = send!(ctx)
      deliver!(ctx, sent)
      assert [_item] = items!(ctx).items

      path = "/v1/notifications/#{sent.notification}/cancel"
      F.body(F.request(:post, path, ctx.token, %{}), 200)

      snapshot = items!(ctx)
      assert snapshot.items == []
      assert %{total: 0, unseen: 0, version: 2} = snapshot.counters

      assert [["retracted"]] = sql!(ctx.scope, "SELECT hidden_reason FROM relay.inbox_items", [])
    end
  end
end
