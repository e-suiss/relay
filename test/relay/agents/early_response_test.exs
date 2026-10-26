defmodule Relay.Agents.EarlyResponseTest do
  use Relay.SqlCase, async: true

  import RelayTest.WaitpointFixture

  setup do
    s = setup!()
    agent = member!(s, "agent")
    responder = member!(s, "subscriber")
    %{s: s, agent: agent, responder: responder, value_key: content_key!(s, responder)}
  end

  defp early(ctx, key, opts \\ []) do
    offer(Keyword.get(opts, :event_type, "agent.answer"), key,
      waiter_kind: "agent",
      waiter_ref: ctx.agent,
      record_id: Keyword.get_lazy(opts, :record_id, &id/0)
    )
  end

  defp record(id, column),
    do: one("SELECT #{column} FROM relay.mailbox_records WHERE id = $1", [id])

  describe "AG-13 early events are buffered in the waiter's mailbox" do
    test "AG-13: an event for a named waiter without a waitpoint is held in its mailbox", ctx do
      assert [["buffered", nil, record_id]] = early(ctx, "order-1")

      assert record(record_id, "kind") == "early_event"
      assert record(record_id, "delivery_state") == "held"
      assert record(record_id, "correlation_key") == "order-1"

      ["opened", id, _, ^record_id] =
        open(ctx.s, kind: "event", waiter_ref: ctx.agent, correlation_key: "order-1")

      assert record(record_id, "mailbox_id") == waitpoint(id, "waiter_mailbox_id")
    end

    test "AG-13: an early event resolves the event waitpoint that opens for it, once", ctx do
      [["buffered", nil, record_id]] = early(ctx, "order-2")

      ["opened", id, _, ^record_id] =
        open(ctx.s, kind: "event", waiter_ref: ctx.agent, correlation_key: "order-2")

      assert one("SELECT relay_fn.waitpoint_resolve_by_event($1, $2, NULL)", [id, record_id]) ==
               "resolved"

      assert waitpoint(id, "state") == "resolved"
      assert waitpoint(id, "resolved_by_record_id") == record_id
      assert record(record_id, "consumed_by_waitpoint_id") == id
      assert List.last(mailbox_events(waitpoint(id, "waiter_mailbox_id"))) == "waitpoint.resolved"

      ["opened", _, _, nil] =
        open(ctx.s, kind: "event", waiter_ref: ctx.agent, correlation_key: "order-2")
    end

    test "AG-13: a consumed or foreign early record cannot resolve another waitpoint", ctx do
      [["buffered", nil, record_id]] = early(ctx, "order-3")

      ["opened", id, _, ^record_id] =
        open(ctx.s, kind: "event", waiter_ref: ctx.agent, correlation_key: "order-3")

      "resolved" =
        one("SELECT relay_fn.waitpoint_resolve_by_event($1, $2, NULL)", [id, record_id])

      ["opened", other, _, nil] =
        open(ctx.s, kind: "event", waiter_ref: ctx.agent, correlation_key: "order-4")

      assert error_message("SELECT relay_fn.waitpoint_resolve_by_event($1, $2, NULL)", [
               other,
               record_id
             ]) =~ "invalid_argument"
    end

    test "AG-13: only an early event of the same type and key is found at opening", ctx do
      [["buffered", nil, _]] = early(ctx, "order-5", event_type: "agent.other")
      [["buffered", nil, _]] = early(ctx, "order-50")

      assert ["opened", _, _, nil] =
               open(ctx.s, kind: "event", waiter_ref: ctx.agent, correlation_key: "order-5")
    end

    test "AG-13: an early answer to a question is consumed by the response that uses it", ctx do
      [["buffered", nil, record_id]] = early(ctx, "ticket-1")

      ["opened", id, _, ^record_id] =
        open(ctx.s,
          waiter_ref: ctx.agent,
          responder_ids: [ctx.responder],
          correlation_key: "ticket-1"
        )

      assert ["resolved", _] =
               respond(id,
                 responder_recipient_id: ctx.responder,
                 subject_digest: waitpoint(id, "subject_digest"),
                 value_key_id: ctx.value_key,
                 source_record_id: record_id
               )

      assert record(record_id, "consumed_by_waitpoint_id") == id
    end

    test "AG-13: an early answer left in the buffer stays there for a later waitpoint", ctx do
      [["buffered", nil, record_id]] = early(ctx, "ticket-2")

      ["opened", id, _, ^record_id] =
        open(ctx.s,
          waiter_ref: ctx.agent,
          responder_ids: [ctx.responder],
          correlation_key: "ticket-2"
        )

      one("SELECT relay_fn.waitpoint_cancel($1, 'retry', $2, $3, $4, $5, $6)", [
        id,
        digest() | actor()
      ])

      assert ["opened", _, _, ^record_id] =
               open(ctx.s,
                 waiter_ref: ctx.agent,
                 responder_ids: [ctx.responder],
                 correlation_key: "ticket-2"
               )
    end

    test "AG-13: an event without a waiter and without a match is recorded with its rule" do
      assert [["unmatched", nil, nil]] = offer("agent.answer", "nobody-waits")

      assert row(
               "SELECT rule_id, waiter_kind FROM relay.waitpoint_unmatched_events WHERE correlation_key = $1",
               ["nobody-waits"]
             ) == ["waitpoint.no_match", nil]

      assert [["unmatched", nil, nil]] =
               offer("agent.answer", "unknown-agent", waiter_kind: "agent", waiter_ref: id())

      assert one(
               "SELECT count(*) FROM relay.waitpoint_unmatched_events WHERE correlation_key = $1",
               ["unknown-agent"]
             ) == 1
    end
  end
end
