defmodule Relay.Inbox.MailboxTest do
  use Relay.SqlCase, async: true

  import RelayTest.WaitpointFixture

  setup do
    scenario()
  end

  defp scenario do
    s = setup!()
    owner = member!(s, "subscriber")
    %{s: s, owner: owner, mailbox: mailbox!("subscriber", owner)}
  end

  defp read(mailbox, epoch, since, limit),
    do:
      rows("SELECT seq, kind, delivery_state FROM relay_fn.mailbox_read_since($1, $2, $3, $4)", [
        mailbox,
        epoch,
        since,
        limit
      ])

  defp check(mailbox, epoch, since),
    do: row("SELECT * FROM relay_fn.mailbox_cursor_check($1, $2, $3)", [mailbox, epoch, since])

  defp lease(mailbox, holder, opts \\ []) do
    "SELECT id, delivery_count FROM relay_fn.mailbox_lease($1, $2, $3, $4, $5)"
    |> rows([
      mailbox,
      holder,
      Keyword.get(opts, :max, 10),
      Keyword.get(opts, :lease_ms, 60_000),
      Keyword.get(opts, :max_deliveries, 5)
    ])
  end

  defp ack(mailbox, ids, holder),
    do: rows("SELECT * FROM relay_fn.mailbox_ack($1, $2, $3)", [mailbox, ids, holder])

  defp record(id, column),
    do: one("SELECT #{column} FROM relay.mailbox_records WHERE id = $1", [id])

  describe "C-68 AG-64 IN-1 one mailbox per owner" do
    test "AG-64: the mailbox opens lazily once and every owner kind has its own", ctx do
      assert ["exists", mailbox, stream] =
               row("SELECT * FROM relay_fn.mailbox_ensure($1, 'subscriber', $2)", [
                 id(),
                 ctx.owner
               ])

      assert mailbox == ctx.mailbox
      assert stream == "mailbox:" <> Ecto.UUID.load!(mailbox)

      client = id()

      assert ["created", api_mailbox, _] =
               row("SELECT * FROM relay_fn.mailbox_ensure($1, 'api_client', $2)", [id(), client])

      assert api_mailbox != mailbox
    end

    test "IN-1: a subscriber or agent owner must exist with that kind", ctx do
      ensure = "SELECT result FROM relay_fn.mailbox_ensure($1, $2, $3)"
      assert one(ensure, [id(), "agent", ctx.owner]) == "owner_not_found"
      assert one(ensure, [id(), "subscriber", id()]) == "owner_not_found"
      assert error_message(ensure, [id(), "robot", id()]) =~ "invalid_argument"
    end
  end

  describe "C-68 C-71 OP-5 records take the stream sequence" do
    test "C-71: records take consecutive positions with their outbox event", ctx do
      assert ["appended", 1, 1] = append(ctx.mailbox)
      assert ["appended", 1, 2] = append(ctx.mailbox)
      assert ["appended", 1, 3] = append(ctx.mailbox, kind: "early_event", correlation_key: "k")

      assert rows(
               "SELECT seq, event_type FROM relay.outbox_events WHERE stream_key = $1 ORDER BY seq",
               ["mailbox:" <> Ecto.UUID.load!(ctx.mailbox)]
             ) == [
               [1, "mailbox.record_appended"],
               [2, "mailbox.record_appended"],
               [3, "mailbox.record_appended"]
             ]

      assert read(ctx.mailbox, 1, 0, 10) == [
               [1, "message", "available"],
               [2, "message", "available"],
               [3, "early_event", "held"]
             ]
    end

    test "C-68: an unknown, suspended or deleted mailbox takes no record", ctx do
      assert ["mailbox_not_found", nil, nil] = append(id())

      set_state = "SELECT relay_fn.mailbox_set_state($1, $2, $3)"
      assert one(set_state, [ctx.mailbox, "suspended", nil]) == "changed"
      assert ["mailbox_inactive", nil, nil] = append(ctx.mailbox)
      assert one(set_state, [ctx.mailbox, "active", nil]) == "changed"
      assert ["appended", _, _] = append(ctx.mailbox)

      assert error_message(set_state, [ctx.mailbox, "deleted", nil]) =~ "invalid_argument"
      assert one(set_state, [ctx.mailbox, "deleted", "operator"]) == "changed"
      assert one(set_state, [ctx.mailbox, "active", nil]) == "unchanged"
      assert ["mailbox_inactive", nil, nil] = append(ctx.mailbox)
    end

    test "C-68: a payload names exactly one key", ctx do
      assert sql_error(
               "SELECT * FROM relay_fn.mailbox_append($1, $2, 'message', 'inbox.message', NULL, NULL, NULL, 'ct', NULL, NULL, $3, NULL)",
               [id(), ctx.mailbox, digest()]
             ).postgres.constraint == "mailbox_records_payload_key_check"

      assert ["appended", _, _] =
               append(ctx.mailbox, payload_ct: "ct", payload_key_id: ctx.s.data_key)
    end
  end

  describe "IN-22 IN-29 INV-35 since reads and resync" do
    test "IN-22: a reader gets the records after its position in order", ctx do
      for _ <- 1..5, do: append(ctx.mailbox)

      assert Enum.map(read(ctx.mailbox, 1, 2, 10), &hd/1) == [3, 4, 5]
      assert Enum.map(read(ctx.mailbox, 1, 2, 2), &hd/1) == [3, 4]
      assert read(ctx.mailbox, 1, 5, 10) == []
      assert read(ctx.mailbox, 2, 0, 10) == []
    end

    test "IN-29: one read returns at most the replay cap and the one record after it", ctx do
      append(ctx.mailbox)
      assert [_] = read(ctx.mailbox, 1, 0, 501)

      for limit <- [0, 502, nil] do
        assert error_message(
                 "SELECT * FROM relay_fn.mailbox_read_since($1, 1, 0, $2)",
                 [ctx.mailbox, limit]
               ) =~ "invalid_argument"
      end
    end

    test "IN-22: a position outside the stream or of an old epoch needs a resync", ctx do
      for _ <- 1..3, do: append(ctx.mailbox)

      assert ["ok", 1, 3, 0] = check(ctx.mailbox, 1, 0)
      assert ["ok", 1, 3, 0] = check(ctx.mailbox, 1, 3)
      assert ["resync_required", 1, 3, 0] = check(ctx.mailbox, 1, 4)
      assert ["resync_required", 1, 3, 0] = check(ctx.mailbox, 1, -1)
      assert ["resync_required", 1, 3, 0] = check(ctx.mailbox, 2, 0)
      assert ["not_found", nil, nil, nil] = check(id(), 1, 0)
    end

    test "IN-22: an epoch bump is audited and restarts the stream" do
      as_owner(&scenario/0, fn ctx ->
        append(ctx.mailbox)

        assert ["bumped", 2] =
                 row(
                   "SELECT * FROM relay_fn.mailbox_epoch_bump($1, 'restore', $2, $3, $4, $5, $6)",
                   [ctx.mailbox, digest() | actor()]
                 )

        assert ["resync_required", 2, head, 0] = check(ctx.mailbox, 1, 1)
        assert ["appended", 2, seq] = append(ctx.mailbox)
        assert seq > head
        assert [[^seq, "message", "available"]] = read(ctx.mailbox, 2, head, 10)

        assert one(
                 "SELECT count(*) FROM relay.audit_log WHERE action = 'mailbox.epoch_bumped' AND target_id = $1",
                 [Ecto.UUID.load!(ctx.mailbox)]
               ) == 1
      end)
    end

    test "IN-22: a reader cursor only moves forward within its epoch", ctx do
      advance = "SELECT relay_fn.mailbox_cursor_advance($1, $2, $3, $4)"
      assert one(advance, [ctx.mailbox, "web", 1, 2]) == "advanced"
      assert one(advance, [ctx.mailbox, "web", 1, 2]) == "stale"
      assert one(advance, [ctx.mailbox, "web", 1, 1]) == "stale"
      assert one(advance, [ctx.mailbox, "web", 1, 3]) == "advanced"
      assert one(advance, [ctx.mailbox, "web", 2, 9]) == "epoch_mismatch"
      assert one(advance, [id(), "web", 1, 1]) == "not_found"
    end
  end

  describe "AG-21 AG-22 leases and acknowledgements" do
    test "AG-21: a leased record goes to one holder and only that holder acknowledges it", ctx do
      append(ctx.mailbox)
      append(ctx.mailbox)

      assert [[first, 1], [second, 1]] = lease(ctx.mailbox, "worker-a")
      assert lease(ctx.mailbox, "worker-b") == []

      assert ack(ctx.mailbox, [first], "worker-b") == [[first, "lease_lost"]]
      assert ack(ctx.mailbox, [first, first], "worker-a") == [[first, "acked"]]
      assert ack(ctx.mailbox, [first], "worker-a") == [[first, "already_acked"]]
      assert record(first, "delivery_state") == "acked"
      assert record(second, "delivery_state") == "leased"

      unknown = id()
      assert ack(ctx.mailbox, [unknown], "worker-a") == [[unknown, "not_found"]]
    end

    test "AG-21: held early records are never leased", ctx do
      append(ctx.mailbox, kind: "early_event", correlation_key: "order-1")
      assert lease(ctx.mailbox, "worker-a") == []
    end

    test "AG-22: an expired lease is delivered again and dead-lettered past the limit" do
      as_owner(&scenario/0, fn ctx ->
        append(ctx.mailbox)

        expire =
          "UPDATE relay.mailbox_records SET lease_until = now() - interval '1 second' WHERE mailbox_id = $1"

        assert [[id, 1]] = lease(ctx.mailbox, "worker-a", max_deliveries: 2)
        rows(expire, [ctx.mailbox])
        assert [[^id, 2]] = lease(ctx.mailbox, "worker-b", max_deliveries: 2)
        assert ack(ctx.mailbox, [id], "worker-a") == [[id, "lease_lost"]]
        rows(expire, [ctx.mailbox])
        assert lease(ctx.mailbox, "worker-c", max_deliveries: 2) == []
        assert record(id, "delivery_state") == "dead_lettered"

        assert one(
                 "SELECT count(*) FROM relay.outbox_events WHERE stream_key = $1 AND event_type = 'mailbox.record_dead_lettered'",
                 ["mailbox:" <> Ecto.UUID.load!(ctx.mailbox)]
               ) == 1
      end)
    end

    test "AG-22: lease arguments are bounded", ctx do
      for {max, lease_ms, deliveries} <- [
            {0, 60_000, 5},
            {101, 60_000, 5},
            {1, 999, 5},
            {1, 60_000, 0}
          ] do
        assert error_message(
                 "SELECT * FROM relay_fn.mailbox_lease($1, 'w', $2, $3, $4)",
                 [ctx.mailbox, max, lease_ms, deliveries]
               ) =~ "invalid_argument"
      end
    end
  end
end
