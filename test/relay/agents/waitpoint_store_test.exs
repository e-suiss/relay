defmodule Relay.Agents.WaitpointStoreTest do
  use Relay.SqlCase, async: true

  import RelayTest.WaitpointFixture

  setup do
    scenario()
  end

  defp scenario do
    s = setup!()
    agent = member!(s, "agent")
    responder = member!(s, "subscriber")
    %{s: s, agent: agent, responder: responder, value_key: content_key!(s, responder)}
  end

  defp as_owner(fun) do
    admin = connect(:admin)

    try do
      rolled_back(admin, fn ->
        ctx = scenario()
        rows("SET LOCAL ROLE relay_owner")
        fun.(ctx)
      end)
    after
      GenServer.stop(admin)
    end
  end

  defp question(ctx, opts \\ []) do
    open(ctx.s, Keyword.merge([waiter_ref: ctx.agent, responder_ids: [ctx.responder]], opts))
  end

  describe "AG-9 deadline" do
    test "AG-9: a waitpoint without a deadline, with a past one or one beyond 30 days is refused",
         ctx do
      assert ["expires_invalid", nil, nil, nil] = question(ctx, expires_at: nil)
      assert ["expires_invalid", nil, nil, nil] = question(ctx, expires_at: {:in, -1_000})

      assert ["expires_invalid", nil, nil, nil] =
               question(ctx, expires_at: {:in, 30 * 86_400_000 + 60_000})

      assert ["opened", _, _, nil] = question(ctx, expires_at: {:in, 30 * 86_400_000 - 60_000})
    end

    test "AG-9: a retry with the same identifier keeps the stored deadline", ctx do
      id = id()
      ["opened", ^id, stored, nil] = question(ctx, id: id, expires_at: {:in, 3_600_000})

      assert ["exists", ^id, ^stored, nil] =
               question(ctx, id: id, expires_at: {:in, 7_200_000}, correlation_key: "other")

      assert waitpoint(id, "expires_at") == stored
    end

    test "AG-9: the deadline is written once and never changes" do
      as_owner(fn ctx ->
        ["opened", id, _, nil] = question(ctx)

        assert error_message(
                 "UPDATE relay.waitpoints SET expires_at = expires_at + interval '1 day' WHERE id = $1",
                 [id]
               ) =~ "invariant_violation"
      end)
    end

    test "AG-9: a second-stage condition is refused until the condition language exists", ctx do
      assert ["condition_unsupported", nil, nil, nil] = question(ctx, condition: %{"a" => 1})
    end
  end

  describe "AG-10 C-72 lifecycle" do
    test "C-72: a question is resolved once and the second answer is rejected as closed", ctx do
      ["opened", id, _, nil] = question(ctx)
      digest = waitpoint(id, "subject_digest")

      opts = [
        responder_recipient_id: ctx.responder,
        subject_digest: digest,
        value_key_id: ctx.value_key
      ]

      assert ["resolved", response] = respond(id, opts)
      assert waitpoint(id, "state") == "resolved"
      assert waitpoint(id, "resolution_response_id") == response
      assert ["rejected_closed", nil] = respond(id, opts)

      assert one(
               "SELECT reason FROM relay.waitpoint_response_rejections WHERE waitpoint_id = $1",
               [id]
             ) == "closed"
    end

    test "AG-10: a stalled waitpoint still accepts its answer" do
      as_owner(fn ctx ->
        ["opened", id, _, nil] = question(ctx, heartbeat_interval_ms: 1_000)

        rows(
          "UPDATE relay.waitpoints SET state = 'stalled', stalled_at = now() WHERE id = $1",
          [id]
        )

        assert waitpoint(id, "state") == "stalled"

        assert ["resolved", _] =
                 respond(id,
                   responder_recipient_id: ctx.responder,
                   subject_digest: waitpoint(id, "subject_digest"),
                   value_key_id: ctx.value_key
                 )
      end)
    end

    test "AG-10: the heartbeat renews an open waitpoint and reopens a stalled one", ctx do
      ["opened", id, _, nil] = question(ctx, heartbeat_interval_ms: 60_000)

      assert ["renewed", %DateTime{}] =
               row("SELECT * FROM relay_fn.waitpoint_heartbeat($1, 'agent', $2)", [id, ctx.agent])

      assert ["not_waiter", nil] =
               row("SELECT * FROM relay_fn.waitpoint_heartbeat($1, 'agent', $2)", [id, id()])

      ["opened", other, _, nil] = question(ctx)

      assert ["no_heartbeat", nil] =
               row("SELECT * FROM relay_fn.waitpoint_heartbeat($1, 'agent', $2)", [
                 other,
                 ctx.agent
               ])
    end

    test "C-72: a waitpoint is listed while open and cancelled once", ctx do
      ["opened", id, _, nil] = question(ctx, tags: ["billing"])

      listed =
        rows(
          "SELECT id FROM relay_fn.waitpoint_list(ARRAY['open', 'stalled'], 'agent', $1, ARRAY['billing'], NULL, 10)",
          [ctx.agent]
        )

      assert [[^id]] = listed

      cancel = "SELECT relay_fn.waitpoint_cancel($1, 'not needed', $2, $3, $4, $5, $6)"
      assert one(cancel, [id, digest() | actor()]) == "cancelled"
      assert one(cancel, [id, digest() | actor()]) == "already_terminal"
      assert waitpoint(id, "cancel_reason") == "not needed"

      assert rows(
               "SELECT id FROM relay_fn.waitpoint_list(ARRAY['open'], 'agent', $1, NULL, NULL, 10)",
               [ctx.agent]
             ) == []
    end

    test "C-72: every transition writes a waitpoint event to the waiter's mailbox and the outbox",
         ctx do
      ["opened", id, _, nil] = question(ctx)
      mailbox = waitpoint(id, "waiter_mailbox_id")

      one("SELECT relay_fn.waitpoint_cancel($1, 'done', $2, $3, $4, $5, $6)", [
        id,
        digest() | actor()
      ])

      assert mailbox_events(mailbox) == ["waitpoint.created", "waitpoint.cancelled"]

      assert rows(
               "SELECT event_type FROM relay.outbox_events WHERE stream_key = $1 ORDER BY seq",
               ["waitpoint:" <> Ecto.UUID.load!(id)]
             ) == [["waitpoint.created"], ["waitpoint.cancelled"]]
    end
  end

  describe "INV-12 T-87 uniqueness" do
    test "INV-12: a waiter has one active waitpoint per event type and correlation key", ctx do
      ["opened", _, _, nil] = question(ctx, correlation_key: "order-1")
      assert ["active_exists", nil, nil, nil] = question(ctx, correlation_key: "order-1")

      other = member!(ctx.s, "agent")

      assert ["opened", _, _, nil] =
               open(ctx.s,
                 waiter_ref: other,
                 responder_ids: [ctx.responder],
                 correlation_key: "order-1"
               )
    end

    test "T-87: the database refuses a second active waitpoint even without the function" do
      as_owner(fn ctx ->
        ["opened", id, _, nil] = question(ctx, correlation_key: "order-2")

        error =
          sql_error(
            """
            INSERT INTO relay.waitpoints (tenant_id, environment, id, kind, waiter_kind, waiter_ref,
              waiter_mailbox_id, match_event_type, correlation_key, opened_at, expires_at, state,
              state_changed_at, created_at, updated_at)
            SELECT tenant_id, environment, $2, 'event', waiter_kind, waiter_ref, waiter_mailbox_id,
              match_event_type, correlation_key, now(), now() + interval '1 hour', 'open', now(),
              now(), now()
            FROM relay.waitpoints WHERE id = $1
            """,
            [id, id()]
          )

        assert error.postgres.code == :unique_violation
        assert error.postgres.constraint == "waitpoints_active_key"
      end)
    end
  end

  describe "AG-64 TN-54 waiter mailbox and limits" do
    test "AG-64: an API client waiter gets its mailbox lazily and the same stream", ctx do
      client = id()

      assert ["opened", id, _, nil] =
               open(ctx.s,
                 kind: "event",
                 waiter_kind: "api_client",
                 waiter_ref: client,
                 match_event_type: "order.paid"
               )

      mailbox = waitpoint(id, "waiter_mailbox_id")

      assert row("SELECT owner_kind, owner_ref, stream_key FROM relay.mailboxes WHERE id = $1", [
               mailbox
             ]) == ["api_client", client, "mailbox:" <> Ecto.UUID.load!(mailbox)]

      assert mailbox_events(mailbox) == ["waitpoint.created"]
    end

    test "AG-64: an agent waiter must exist", ctx do
      assert ["waiter_not_found", nil, nil, nil] =
               open(ctx.s, waiter_ref: id(), responder_ids: [ctx.responder])

      assert ["waiter_not_found", nil, nil, nil] =
               open(ctx.s, waiter_ref: ctx.responder, responder_ids: [ctx.agent])
    end

    test "TN-54: the open waitpoint limits per tenant and per waiter hold", ctx do
      ["opened", _, _, nil] = question(ctx, waiter_open_cap: 2)
      ["opened", _, _, nil] = question(ctx, waiter_open_cap: 2)
      assert ["limit_exceeded", nil, nil, nil] = question(ctx, waiter_open_cap: 2)
      assert ["limit_exceeded", nil, nil, nil] = question(ctx, tenant_open_cap: 2)
      assert one("SELECT open_count FROM relay.waitpoint_counters") == 2
    end

    test "TN-54: closing a waitpoint frees its place", ctx do
      ["opened", id, _, nil] = question(ctx, waiter_open_cap: 1)
      assert ["limit_exceeded", nil, nil, nil] = question(ctx, waiter_open_cap: 1)

      one("SELECT relay_fn.waitpoint_cancel($1, 'done', $2, $3, $4, $5, $6)", [
        id,
        digest() | actor()
      ])

      assert ["opened", _, _, nil] = question(ctx, waiter_open_cap: 1)
    end
  end
end
