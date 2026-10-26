defmodule Relay.Agents.WaitpointTimerTest do
  use Relay.SqlCase, async: true

  import RelayTest.WaitpointFixture

  setup do
    s = setup!()
    agent = member!(s, "agent")
    responder = member!(s, "subscriber")
    %{s: s, agent: agent, responder: responder, value_key: content_key!(s, responder)}
  end

  defp question(ctx, opts \\ []) do
    ["opened", id, _, nil] =
      open(ctx.s, Keyword.merge([waiter_ref: ctx.agent, responder_ids: [ctx.responder]], opts))

    id
  end

  defp fire(id), do: row("SELECT * FROM relay_fn.waitpoint_timer_fire($1)", [id])

  defp due, do: "SELECT waitpoint_id FROM relay_fn.waitpoint_due(10)" |> rows() |> List.flatten()

  defp answer(ctx, id),
    do:
      respond(id,
        responder_recipient_id: ctx.responder,
        subject_digest: waitpoint(id, "subject_digest"),
        value_key_id: ctx.value_key
      )

  describe "AG-15 T-24 one timer for deadline and heartbeat" do
    test "AG-15: an early wake-up finds nothing due and names the nearest timer", ctx do
      id = question(ctx, heartbeat_interval_ms: 60_000)
      heartbeat = waitpoint(id, "heartbeat_due_at")

      assert ["not_due", ^heartbeat] = fire(id)
      assert waitpoint(id, "state") == "open"

      plain = question(ctx)
      expires = waitpoint(plain, "expires_at")
      assert ["not_due", ^expires] = fire(plain)
      assert ["not_found", nil] = fire(id())
    end

    test "AG-10: a missed heartbeat stalls the waitpoint once and a heartbeat reopens it", ctx do
      id = question(ctx, heartbeat_interval_ms: 1_000)
      expires = waitpoint(id, "expires_at")
      advance!(1_500)

      assert ["stalled", ^expires] = fire(id)
      assert waitpoint(id, "state") == "stalled"
      assert ["not_due", ^expires] = fire(id)
      assert List.last(mailbox_events(waitpoint(id, "waiter_mailbox_id"))) == "waitpoint.stalled"

      assert ["reopened", %DateTime{}] =
               row("SELECT * FROM relay_fn.waitpoint_heartbeat($1, 'agent', $2)", [id, ctx.agent])

      assert waitpoint(id, "state") == "open"
    end

    test "AG-9: the deadline expires the waitpoint with its default response", ctx do
      id = question(ctx, default_response_ct: "fallback")
      mailbox = waitpoint(id, "waiter_mailbox_id")
      before = one("SELECT open_count FROM relay.waitpoint_counters")
      advance!(3_600_001)

      assert ["expired", nil] = fire(id)
      assert waitpoint(id, "state") == "expired"
      assert ["already_terminal", nil] = fire(id)
      assert one("SELECT open_count FROM relay.waitpoint_counters") == before - 1

      assert row(
               "SELECT payload_ct, payload_tenant_key_id FROM relay.mailbox_records WHERE mailbox_id = $1 AND event_type = 'waitpoint.expired'",
               [mailbox]
             ) == ["fallback", ctx.s.data_key]

      assert ["rejected_closed", nil] = answer(ctx, id)
    end

    test "AG-11: an answer after the deadline is rejected and expires the waitpoint", ctx do
      id = question(ctx)
      advance!(3_600_001)

      assert ["rejected_expired", nil] = answer(ctx, id)
      assert waitpoint(id, "state") == "expired"

      assert ["already_terminal", nil] =
               row("SELECT * FROM relay_fn.waitpoint_heartbeat($1, 'agent', $2)", [id, ctx.agent])
    end

    test "T-24: the due list follows business time", ctx do
      beating = question(ctx, heartbeat_interval_ms: 1_000)
      plain = question(ctx)
      assert due() == []

      advance!(1_500)
      assert due() == [beating]
      ["stalled", _] = fire(beating)
      assert due() == []

      advance!(3_600_000)
      assert Enum.sort(due()) == Enum.sort([beating, plain])
    end
  end
end
