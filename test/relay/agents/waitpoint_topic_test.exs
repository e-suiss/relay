defmodule Relay.Agents.WaitpointTopicTest do
  use Relay.SqlCase, async: true

  import RelayTest.WaitpointFixture

  @topic "SELECT result FROM relay_fn.topic_create($1, $2, $3, $4, $5, $6, $7, $8)"
  @subscribe """
  INSERT INTO relay.topic_subscriptions (tenant_id, environment, id, topic_id, recipient_id,
    state, removed_reason, removed_at, created_at, updated_at)
  SELECT t.tenant_id, t.environment, $1, t.id, $2, 'active', NULL, NULL, now(), now()
  FROM relay.topics t WHERE t.key = $3
  """
  @events """
  SELECT r.event_type FROM relay.mailbox_records r
  JOIN relay.mailboxes m ON m.id = r.mailbox_id
  WHERE m.owner_ref = $1 ORDER BY r.epoch, r.seq
  """

  defp topic!(key, parent \\ nil) do
    "created" = one(@topic, [id(), key, parent, digest() | actor()])
  end

  defp subscribe!(recipient, key), do: rows(@subscribe, [id(), recipient, key])

  defp events(owner), do: @events |> rows([owner]) |> List.flatten()

  defp scenario do
    s = setup!()
    topic!("reports")
    topic!("reports.daily", "reports")
    topic!("other")

    ctx = %{
      s: s,
      waiter: member!(s, "agent"),
      reader: member!(s, "agent"),
      parent_reader: member!(s, "agent"),
      stranger: member!(s, "agent"),
      human: member!(s, "subscriber")
    }

    subscribe!(ctx.waiter, "reports.daily")
    subscribe!(ctx.reader, "reports.daily")
    subscribe!(ctx.reader, "reports")
    subscribe!(ctx.parent_reader, "reports")
    subscribe!(ctx.human, "reports.daily")
    subscribe!(ctx.stranger, "other")
    ctx
  end

  defp as_admin(fun) do
    admin = connect(:admin)

    try do
      rolled_back(admin, fn -> fun.(scenario()) end)
    after
      GenServer.stop(admin)
    end
  end

  defp waitpoint!(ctx, opts) do
    defaults = [kind: "event", waiter_ref: ctx.waiter, deliver_to_topics: ["reports.daily"]]
    ["opened", id, _, nil] = open(ctx.s, Keyword.merge(defaults, opts))
    id
  end

  defp cancel!(id) do
    "cancelled" =
      one("SELECT relay_fn.waitpoint_cancel($1, 'done', $2, $3, $4, $5, $6)", [
        id,
        digest() | actor()
      ])
  end

  describe "AG-7 topic subscription, the multi-reader form" do
    test "AG-7: the result of a waitpoint reaches every agent subscribed to its topics once" do
      as_admin(fn ctx ->
        id = waitpoint!(ctx, [])
        assert events(ctx.reader) == []

        cancel!(id)
        assert events(ctx.reader) == ["waitpoint.cancelled"]
        assert events(ctx.parent_reader) == ["waitpoint.cancelled"]
        assert events(ctx.waiter) == ["waitpoint.created", "waitpoint.cancelled"]
        assert events(ctx.stranger) == []
        assert events(ctx.human) == []
      end)
    end

    test "AG-7: a waitpoint without topics is read by its waiter alone" do
      as_admin(fn ctx ->
        cancel!(waitpoint!(ctx, deliver_to_topics: []))
        assert events(ctx.waiter) == ["waitpoint.created", "waitpoint.cancelled"]
        assert events(ctx.reader) == []
      end)
    end

    test "AG-10: only the result goes to the topic, a stalled waitpoint stays with its waiter" do
      as_admin(fn ctx ->
        id = waitpoint!(ctx, heartbeat_interval_ms: 1_000)
        advance!(1_500)
        assert ["stalled", _next] = row("SELECT * FROM relay_fn.waitpoint_timer_fire($1)", [id])
        assert events(ctx.reader) == []
        assert List.last(events(ctx.waiter)) == "waitpoint.stalled"
      end)
    end
  end
end
