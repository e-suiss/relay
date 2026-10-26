defmodule Relay.Agents.WaitpointMatchTest do
  use Relay.SqlCase, async: true

  import RelayTest.WaitpointFixture

  setup do
    s = setup!()
    responder = member!(s, "subscriber")
    %{s: s, agent: member!(s, "agent"), other: member!(s, "agent"), responder: responder}
  end

  defp event_waitpoint(ctx, waiter, key, event_type \\ "order.paid") do
    ["opened", id, _, nil] =
      open(ctx.s,
        kind: "event",
        waiter_ref: waiter,
        match_event_type: event_type,
        correlation_key: key
      )

    id
  end

  describe "AG-14 exact first-stage matching" do
    test "AG-14: an event matches only the exact event type and correlation key", ctx do
      id = event_waitpoint(ctx, ctx.agent, "order-1")

      for {type, key} <- [
            {"order.paid", "order-"},
            {"order.paid", "order-10"},
            {"order.paid", "ORDER-1"},
            {"order.paid", "order-%"},
            {"order.paid", "order-."},
            {"order.pai", "order-1"},
            {"order.paid.v2", "order-1"}
          ] do
        assert [["unmatched", nil, nil]] = offer(type, key)
      end

      assert [["matched", ^id, nil]] = offer("order.paid", "order-1")
    end

    test "AG-14: without a named waiter every waiter's waitpoint matches", ctx do
      first = event_waitpoint(ctx, ctx.agent, "order-2")
      second = event_waitpoint(ctx, ctx.other, "order-2")

      assert offer("order.paid", "order-2") |> Enum.map(&Enum.at(&1, 1)) |> Enum.sort() ==
               Enum.sort([first, second])
    end

    test "AG-14: a named waiter limits the match to its own waitpoint", ctx do
      first = event_waitpoint(ctx, ctx.agent, "order-3")
      _second = event_waitpoint(ctx, ctx.other, "order-3")

      assert [["matched", ^first, nil]] =
               offer("order.paid", "order-3", waiter_kind: "agent", waiter_ref: ctx.agent)
    end

    test "AG-14: a closed waitpoint no longer matches", ctx do
      id = event_waitpoint(ctx, ctx.agent, "order-4")
      "resolved" = one("SELECT relay_fn.waitpoint_resolve_by_event($1, $2, NULL)", [id, id()])

      assert [["unmatched", nil, nil]] = offer("order.paid", "order-4")
    end

    test "AG-14: a matched event resolves an event waitpoint with a notice record", ctx do
      id = event_waitpoint(ctx, ctx.agent, "order-5")
      event = id()
      record = id()
      [["matched", ^id, nil]] = offer("order.paid", "order-5", event_id: event)

      assert one("SELECT relay_fn.waitpoint_resolve_by_event($1, $2, $3)", [id, record, event]) ==
               "resolved"

      assert waitpoint(id, "resolved_by_event_id") == event
      assert waitpoint(id, "resolved_by_record_id") == record

      assert one("SELECT event_type FROM relay.mailbox_records WHERE id = $1", [record]) ==
               "waitpoint.resolved"

      assert one("SELECT relay_fn.waitpoint_resolve_by_event($1, $2, $3)", [id, id(), event]) ==
               "already_terminal"
    end

    test "AG-14: a question that matches is returned for its answer, not resolved", ctx do
      ["opened", id, _, nil] =
        open(ctx.s, waiter_ref: ctx.agent, responder_ids: [ctx.responder], correlation_key: "q-1")

      assert [["matched", ^id, nil]] = offer("agent.answer", "q-1")
      assert waitpoint(id, "state") == "open"

      assert error_message("SELECT relay_fn.waitpoint_resolve_by_event($1, $2, NULL)", [id, id()]) =~
               "invalid_argument"
    end

    test "AG-14: an event waitpoint takes no responders and is not answered", ctx do
      assert error_message(
               "SELECT * FROM relay_fn.waitpoint_open($1, 'event', 'agent', $2, NULL, 'order.paid', 'k', NULL, NULL, $3, NULL, NULL, NULL, NULL, NULL, $4, NULL, NULL, NULL, NULL, NULL, 10, 10, NULL)",
               [id(), ctx.agent, [ctx.responder], business_now(60_000)]
             ) =~ "invalid_argument"

      id = event_waitpoint(ctx, ctx.agent, "order-6")

      assert error_message(
               "SELECT * FROM relay_fn.waitpoint_respond($1, $2, $3, 'a', 'a', 'push', 'relay_session', NULL, $4, 'v', NULL, $4, NULL)",
               [id, id(), ctx.responder, digest()]
             ) =~ "invalid_argument"
    end
  end

  describe "C-73 E-45 matching stays in its tenant and environment" do
    test "C-73: an event of another environment or another tenant never matches", ctx do
      id = event_waitpoint(ctx, ctx.agent, "order-c73")

      "active" = ctx(ctx.s.tenant, "live")
      assert [["unmatched", nil, nil]] = offer("order.paid", "order-c73")

      assert [["unmatched", nil, nil]] =
               offer("order.paid", "order-c73", waiter_kind: "agent", waiter_ref: ctx.agent)

      other = tenant!()
      "active" = ctx(other, "test")
      assert [["unmatched", nil, nil]] = offer("order.paid", "order-c73")

      "active" = ctx(ctx.s.tenant, "test")
      assert waitpoint(id, "state") == "open"
      assert [["matched", ^id, nil]] = offer("order.paid", "order-c73")
    end

    test "E-45: an answer from any channel is matched and the waiter gets the resolved event",
         ctx do
      value_key = content_key!(ctx.s, ctx.responder)

      for via <- ["email", "sms"] do
        ["opened", id, _, nil] =
          open(ctx.s, waiter_ref: ctx.agent, responder_ids: [ctx.responder])

        assert ["resolved", _] =
                 respond(id,
                   via: via,
                   responder_recipient_id: ctx.responder,
                   subject_digest: waitpoint(id, "subject_digest"),
                   value_key_id: value_key
                 )

        assert waitpoint(id, "state") == "resolved"

        assert List.last(mailbox_events(waitpoint(id, "waiter_mailbox_id"))) ==
                 "waitpoint.resolved"
      end
    end
  end
end
