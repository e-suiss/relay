defmodule Relay.Agents.WaitpointLimitTest do
  use Relay.SqlCase, async: true

  import RelayTest.WaitpointFixture

  alias Relay.Agents.Waitpoint

  setup do
    s = setup!()
    agent = member!(s, "agent")
    responder = member!(s, "subscriber")
    %{s: s, agent: agent, responder: responder, value_key: content_key!(s, responder)}
  end

  defp event(ctx, waiter_kind, waiter, opts \\ []) do
    open(
      ctx.s,
      Keyword.merge(
        [
          kind: "event",
          waiter_kind: waiter_kind,
          waiter_ref: waiter,
          match_event_type: "order.paid"
        ],
        opts
      )
    )
  end

  defp counter, do: one("SELECT open_count FROM relay.waitpoint_counters")

  defp mailbox_open(id),
    do:
      one(
        "SELECT m.open_waitpoints FROM relay.mailboxes m JOIN relay.waitpoints w ON w.waiter_mailbox_id = m.id WHERE w.id = $1",
        [id]
      )

  describe "TN-54 T-91 open waitpoint limits" do
    test "T-91: the default limits are 10,000 per tenant and 1,000 per waiter" do
      assert Waitpoint.default_caps() == %{tenant: 10_000, waiter: 1_000}
    end

    test "TN-54: the waiter limit counts every event type and key of one waiter", ctx do
      ["opened", _, _, nil] = event(ctx, "agent", ctx.agent, waiter_open_cap: 2)

      ["opened", _, _, nil] =
        event(ctx, "agent", ctx.agent, match_event_type: "order.shipped", waiter_open_cap: 2)

      assert ["limit_exceeded", nil, nil, nil] =
               event(ctx, "agent", ctx.agent, match_event_type: "order.lost", waiter_open_cap: 2)

      assert ["opened", _, _, nil] = event(ctx, "api_client", id(), waiter_open_cap: 2)
    end

    test "TN-54: an API client waiter has the same limits", ctx do
      client = id()
      ["opened", id, _, nil] = event(ctx, "api_client", client, waiter_open_cap: 1)

      assert ["limit_exceeded", nil, nil, nil] =
               event(ctx, "api_client", client, waiter_open_cap: 1)

      assert mailbox_open(id) == 1
    end

    test "TN-54: every terminal transition frees its place", ctx do
      ["opened", resolved, _, nil] = event(ctx, "agent", ctx.agent)

      ["opened", answered, _, nil] =
        open(ctx.s, waiter_ref: ctx.agent, responder_ids: [ctx.responder])

      ["opened", cancelled, _, nil] = event(ctx, "agent", ctx.agent)
      assert counter() == 3
      assert mailbox_open(resolved) == 3

      "resolved" =
        one("SELECT relay_fn.waitpoint_resolve_by_event($1, $2, NULL)", [resolved, id()])

      ["resolved", _] =
        respond(answered,
          responder_recipient_id: ctx.responder,
          subject_digest: waitpoint(answered, "subject_digest"),
          value_key_id: ctx.value_key
        )

      "cancelled" =
        one("SELECT relay_fn.waitpoint_cancel($1, 'done', $2, $3, $4, $5, $6)", [
          cancelled,
          digest() | actor()
        ])

      assert counter() == 0
      assert mailbox_open(resolved) == 0

      ["opened", expiring, _, nil] = event(ctx, "agent", ctx.agent)
      advance!(3_600_001)
      ["expired", nil] = row("SELECT * FROM relay_fn.waitpoint_timer_fire($1)", [expiring])
      assert counter() == 0
    end

    test "TN-54: the tenant limit counts each environment on its own", ctx do
      ["opened", _, _, nil] = event(ctx, "api_client", id(), tenant_open_cap: 1)

      assert ["limit_exceeded", nil, nil, nil] =
               event(ctx, "api_client", id(), tenant_open_cap: 1)

      "active" = ctx(ctx.s.tenant, "live")
      assert ["opened", _, _, nil] = event(ctx, "api_client", id(), tenant_open_cap: 1)
    end
  end
end
