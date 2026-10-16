defmodule Relay.Sql.DeliveryTest do
  use Relay.SqlCase, async: true

  alias Relay.Repo

  @accept "SELECT * FROM relay_fn.notification_accept($1, $2, $3, $4, 'transactional', NULL, 'system', NULL, NULL, NULL, false, NULL)"
  @open "SELECT * FROM relay_fn.delivery_open($1, $2, $3, 'address', NULL, $4, 'acme', NULL, $5, $6, $7, $8, $9, NULL)"

  defp open(notification, channel, target_key, opts \\ []) do
    row(@open, [
      id(),
      notification,
      channel,
      target_key,
      opts[:fallback_of],
      opts[:decision] || "send",
      opts[:reason],
      opts[:rule],
      opts[:deferred_until]
    ])
  end

  defp delivery(delivery_id) do
    [row] =
      Repo.query!(
        "SELECT delivery_rank, failure_kind, has_conflict, duplicate_delivered, late_event_count, projection_version, attempt_count, failure_rule_id FROM relay.deliveries WHERE id = $1",
        [delivery_id]
      ).rows

    Enum.zip(
      ~w(rank failure_kind has_conflict duplicate_delivered late_event_count projection_version attempt_count failure_rule_id)a,
      row
    )
    |> Map.new()
  end

  defp events(delivery_id) do
    rows(
      "SELECT event_type, projection_result FROM relay.delivery_events WHERE delivery_id = $1 ORDER BY received_at, id",
      [delivery_id]
    )
  end

  defp attempt_open(delivery_id) do
    row("SELECT * FROM relay_fn.attempt_open($1, $2, NULL, NULL, $3)", [
      id(),
      delivery_id,
      "pik_1"
    ])
  end

  defp attempt_finish(delivery_id, attempt_no, state, rank) do
    row(
      "SELECT * FROM relay_fn.attempt_finish($1, $2, $3, NULL, $4, 'msg_1', $5, NULL, $6, NULL)",
      [delivery_id, attempt_no, state, "200", id(), rank]
    )
  end

  describe "notification_accept" do
    test "API-16: the same dedup_key for the same recipient returns the first notification and counts" do
      %{recipient: recipient, notification: notification} = scenario!()
      dedup = one("SELECT dedup_key FROM relay.notifications WHERE id = $1", [notification])

      assert row(@accept, [id(), recipient, nil, dedup]) == ["duplicate", notification]
      assert row(@accept, [id(), recipient, nil, dedup]) == ["duplicate", notification]

      assert one("SELECT duplicate_count FROM relay.notifications WHERE id = $1", [notification]) ==
               2

      assert one("SELECT count(*) FROM relay.notifications WHERE dedup_key = $1", [dedup]) == 1
    end

    test "C-80: the dedup_key is unique per recipient, not per channel or tenant-wide" do
      %{data_key: _, bidx_key: bidx, recipient: recipient} = scenario!()

      wrap =
        one("SELECT wrapping_key_id FROM relay.subject_keys WHERE recipient_id = $1", [recipient])

      other = recipient!(bidx, wrap)

      first = id()
      second = id()
      assert row(@accept, [first, recipient, nil, "access:pw:1"]) == ["created", first]
      assert row(@accept, [second, other, nil, "access:pw:1"]) == ["created", second]
    end

    test "C-29: unknown recipients and subtenants are reported and dedup_key has no update path" do
      %{recipient: recipient} = scenario!()

      assert row(@accept, [id(), id(), nil, "k1"]) == ["recipient_not_found", nil]
      assert row(@accept, [id(), recipient, id(), "k2"]) == ["subtenant_not_found", nil]

      functions =
        rows(
          "SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'relay_fn' AND p.prosrc ~* 'UPDATE relay\\.notifications[^;]*SET((?!WHERE)[^;])*dedup_key\\s*='"
        )

      assert functions == []
    end
  end

  describe "delivery_open" do
    test "C-30: the same notification, channel and target is opened once and fallback links a new delivery" do
      %{notification: notification} = scenario!()
      target = digest()

      ["opened", sms] = open(notification, "sms", target)
      assert open(notification, "sms", target) == ["exists", sms]

      ["opened", whatsapp] = open(notification, "whatsapp", digest(), fallback_of: sms)

      assert one("SELECT fallback_of FROM relay.deliveries WHERE id = $1", [whatsapp]) == sms
      assert open(notification, "email", digest(), fallback_of: id()) == ["fallback_invalid", nil]
    end

    test "C-82: two devices of one recipient get two push deliveries" do
      %{notification: notification} = scenario!()

      assert ["opened", _] = open(notification, "push", digest())
      assert ["opened", _] = open(notification, "push", digest())

      assert one("SELECT count(*) FROM relay.deliveries WHERE notification_id = $1", [
               notification
             ]) == 2
    end

    test "OP-2: a skipped delivery still opens a row with its reason and opening event" do
      %{notification: notification} = scenario!()

      ["opened", skipped] =
        open(notification, "sms", digest(),
          decision: "skip",
          reason: "quiet_hours",
          rule: "pc.quiet"
        )

      assert %{rank: 0, failure_kind: "skipped", failure_rule_id: "pc.quiet"} = delivery(skipped)
      assert events(skipped) == [["delivery.skipped", "applied"]]
      assert_rebuilds(skipped)

      ["opened", deferred] =
        open(notification, "email", digest(),
          decision: "defer",
          rule: "pc.window",
          deferred_until: DateTime.add(DateTime.utc_now(), 3600)
        )

      assert events(deferred) == [["delivery.deferred", "applied"]]
      assert attempt_open(deferred) == ["delivery_not_sendable", nil]
    end

    test "DS-1: unknown and closed notifications are rejected" do
      %{notification: notification} = scenario!()

      assert open(id(), "sms", digest()) == ["notification_not_found", nil]

      ["cancelled", 0] =
        row("SELECT * FROM relay_fn.notification_cancel($1, 'ops.cancel', $2, $3, $4, $5, $6)", [
          notification,
          digest() | actor()
        ])

      assert open(notification, "sms", digest()) == ["notification_closed", nil]
    end
  end

  describe "attempts" do
    test "C-31: one active attempt at a time, terminal attempts are never overwritten and retry opens a new attempt" do
      %{notification: notification} = scenario!()
      ["opened", d] = open(notification, "sms", digest())

      assert attempt_open(d) == ["opened", 1]
      assert attempt_open(d) == ["attempt_active", 1]
      assert one("SELECT relay_fn.attempt_start($1, 1)", [d]) == "started"
      assert one("SELECT relay_fn.attempt_start($1, 1)", [d]) == "not_pending"
      assert attempt_finish(d, 1, "unknown", nil) == ["applied", "stale_ignored"]
      assert attempt_finish(d, 1, "unknown", nil) == ["duplicate_ignored", nil]
      assert attempt_finish(d, 1, "succeeded", 1) == ["already_terminal", nil]

      assert attempt_open(d) == ["opened", 2]
      assert one("SELECT relay_fn.attempt_start($1, 2)", [d]) == "started"
      assert attempt_finish(d, 2, "succeeded", 1) == ["applied", "applied"]
      assert attempt_open(d) == ["delivery_not_sendable", nil]
      assert one("SELECT relay_fn.attempt_start($1, 9)", [d]) == "not_found"

      assert rows(
               "SELECT attempt_no, state FROM relay.delivery_attempts WHERE delivery_id = $1 ORDER BY attempt_no",
               [d]
             ) ==
               [[1, "unknown"], [2, "succeeded"]]

      assert %{rank: 1, attempt_count: 2} = delivery(d)
      assert_rebuilds(d)
    end

    test "C-3: attempts carry the attempt state, deliveries do not" do
      columns =
        rows(
          "SELECT column_name FROM information_schema.columns WHERE table_schema = 'relay' AND table_name = 'deliveries' AND column_name IN ('state', 'attempt_state')"
        )

      assert columns == []
    end
  end

  describe "ledger" do
    setup do
      %{notification: notification} = scenario!()
      ["opened", d] = open(notification, "sms", digest())
      ["opened", 1] = attempt_open(d)
      "started" = one("SELECT relay_fn.attempt_start($1, 1)", [d])
      %{d: d}
    end

    test "OP-4: the delivery axis only rises and late events are written and counted", %{d: d} do
      assert ledger!(d, attempt_no: 1, event_type: "dlr.delivered", rank: 2) |> hd() == "applied"

      assert ledger!(d, attempt_no: 1, event_type: "dlr.accepted", rank: 1) |> hd() ==
               "stale_ignored"

      assert %{rank: 2, late_event_count: 1} = delivery(d)
      assert length(events(d)) == 4
      assert_rebuilds(d)
    end

    test "DS-4: an older attempt's failure cannot override a newer attempt's failure", %{d: d} do
      ["applied", "stale_ignored"] = attempt_finish(d, 1, "unknown", nil)
      ["opened", 2] = attempt_open(d)

      assert ledger!(d,
               attempt_no: 2,
               event_type: "dlr.failed",
               failure_kind: "failed",
               failure_class: "transient"
             )
             |> hd() == "applied"

      assert ledger!(d,
               attempt_no: 1,
               event_type: "dlr.failed",
               failure_kind: "bounced",
               failure_class: "permanent_target"
             )
             |> hd() == "stale_ignored"

      assert one("SELECT failure_attempt_no FROM relay.deliveries WHERE id = $1", [d]) == 2
      assert_rebuilds(d)
    end

    test "DS-5: delivered evidence from two attempts flags duplicate_delivered", %{d: d} do
      ["applied", "stale_ignored"] = attempt_finish(d, 1, "unknown", nil)
      ["opened", 2] = attempt_open(d)

      assert ledger!(d, attempt_no: 2, rank: 2) |> hd() == "applied"
      assert ledger!(d, attempt_no: 1, rank: 2) |> hd() == "applied"
      assert %{rank: 2, duplicate_delivered: true} = delivery(d)
      assert_rebuilds(d)
    end

    test "DS-5: delivered clears only the same attempt's earlier failure", %{d: d} do
      ledger!(d, attempt_no: 1, failure_kind: "failed", failure_class: "transient")
      assert ledger!(d, attempt_no: 1, rank: 2) |> hd() == "applied"
      assert %{rank: 2, failure_kind: nil} = delivery(d)
      assert_rebuilds(d)
    end

    test "DS-6: a failure after delivered follows after_delivered valid, stale or conflict", %{
      d: d
    } do
      "applied" = ledger!(d, attempt_no: 1, rank: 2) |> hd()

      assert ledger!(d, attempt_no: 1, failure_kind: "failed", after_delivered: "stale") |> hd() ==
               "stale_ignored"

      assert ledger!(d, attempt_no: 1, failure_kind: "failed", after_delivered: "conflict")
             |> hd() == "conflict_flagged"

      assert %{has_conflict: true, failure_kind: nil} = delivery(d)

      assert ledger!(d, attempt_no: 1, failure_kind: "bounced", after_delivered: "valid") |> hd() ==
               "applied"

      assert %{rank: 2, failure_kind: "bounced"} = delivery(d)
      assert_rebuilds(d)
    end

    test "DS-4: future timestamps are rejected for providers and clamped for clients", %{d: d} do
      future = DateTime.add(DateTime.utc_now(), 7200)

      assert ledger!(d, attempt_no: 1, occurred_at: future, actor: "provider_webhook", rank: 1)
             |> hd() == "rejected_future_timestamp"

      assert ledger!(d, attempt_no: 1, occurred_at: future, actor: "client_sdk", rank: 2) |> hd() ==
               "applied"

      assert one(
               "SELECT occurred_at <= received_at FROM relay.delivery_events WHERE delivery_id = $1 AND actor = 'client_sdk'",
               [d]
             )
    end

    test "DS-2: unknown deliveries and attempts are reported", %{d: d} do
      assert ledger!(id(), rank: 1) == ["delivery_not_found", nil, nil]
      assert ledger!(d, attempt_no: 5, rank: 1) |> hd() == "attempt_not_found"
    end

    test "WH-49: a processed provider receipt is never applied twice", %{d: d} do
      receipt = id()

      ["recorded", ^receipt] =
        row(
          "SELECT * FROM relay_fn.webhook_receipt_record($1, 'acme', NULL, 'evt_1', $2, NULL, NULL)",
          [
            receipt,
            digest()
          ]
        )

      assert row(
               "SELECT * FROM relay_fn.webhook_receipt_record($1, 'acme', NULL, 'evt_1', $2, NULL, NULL)",
               [
                 id(),
                 digest()
               ]
             ) == ["duplicate", receipt]

      assert ledger!(d, attempt_no: 1, rank: 1, receipt_id: receipt) |> hd() == "applied"

      assert ledger!(d, attempt_no: 1, rank: 2, receipt_id: receipt) |> hd() ==
               "duplicate_ignored"

      assert one("SELECT relay_fn.webhook_receipt_mark($1, 'rejected', 'bad')", [receipt]) ==
               "already_final"

      assert one("SELECT relay_fn.webhook_receipt_mark($1, 'rejected', 'bad')", [id()]) ==
               "not_found"

      assert error_message("SELECT count(*) FROM relay.webhook_receipts") =~ "permission denied"
    end

    test "C-32: ledger rows carry actor, event, raw code and both timestamps and cannot be updated",
         %{d: d} do
      ledger!(d, attempt_no: 1, rank: 1, raw_code: "DELIVRD", actor: "provider_api")

      assert [["provider_api", "dlr.delivered", "DELIVRD", true]] =
               rows(
                 "SELECT actor, event_type, raw_code, occurred_at IS NOT NULL AND received_at IS NOT NULL FROM relay.delivery_events WHERE delivery_id = $1 AND raw_code IS NOT NULL",
                 [d]
               )

      assert error_message(
               "UPDATE relay.delivery_events SET raw_code = 'x' WHERE delivery_id = $1",
               [d]
             ) =~
               "permission denied"
    end

    test "C-2: the projection rebuilds from the ledger after cancellation", %{d: d} do
      assert one("SELECT relay_fn.delivery_cancel($1, 'ops.stop', $2, $3, $4, $5, $6)", [
               d,
               digest() | actor()
             ]) ==
               "cancelled"

      assert one("SELECT relay_fn.delivery_cancel($1, 'ops.stop', $2, $3, $4, $5, $6)", [
               d,
               digest() | actor()
             ]) ==
               "already_terminal"

      assert one("SELECT relay_fn.delivery_cancel($1, 'ops.stop', $2, $3, $4, $5, $6)", [
               id(),
               digest() | actor()
             ]) ==
               "not_found"

      assert %{failure_kind: "cancelled", failure_rule_id: "ops.stop"} = delivery(d)
      assert_rebuilds(d)
    end
  end

  test "OP-3: the rebuild reports a projection that drifted from its ledger" do
    worker = connect("relay_worker")

    {tenant, d} =
      committed(worker, fn ->
        %{tenant: tenant, notification: notification} = scenario!()
        {tenant, delivery!(notification)}
      end)

    committed(connect(:admin), fn ->
      rows("UPDATE relay.deliveries SET late_event_count = 7 WHERE id = $1", [d])
    end)

    drift =
      rolled_back(worker, fn ->
        ctx(tenant)
        rows("SELECT * FROM relay_fn.delivery_projection_rebuild($1)", [d])
      end)

    assert drift == [["late_event_count", "7", "0"]]
  end

  test "TN-40: notification cancel cancels only pending deliveries" do
    %{notification: notification} = scenario!()
    ["opened", pending] = open(notification, "sms", digest())
    ["opened", accepted] = open(notification, "email", digest())
    ["opened", 1] = attempt_open(accepted)
    ["applied", "applied"] = attempt_finish(accepted, 1, "succeeded", 1)

    assert row(
             "SELECT * FROM relay_fn.notification_cancel($1, 'ops.recall', $2, $3, $4, $5, $6)",
             [
               notification,
               digest() | actor()
             ]
           ) == ["cancelled", 1]

    assert %{failure_kind: "cancelled"} = delivery(pending)
    assert %{failure_kind: nil, rank: 1} = delivery(accepted)

    assert row(
             "SELECT * FROM relay_fn.notification_cancel($1, 'ops.recall', $2, $3, $4, $5, $6)",
             [
               notification,
               digest() | actor()
             ]
           ) == ["already_closed", 0]
  end

  test "T-57: the accept path writes record, ledger, job and outbox in one transaction or not at all" do
    %{recipient: recipient, data_key: data_key} = scenario!()
    key = "accept_" <> Base.encode16(digest())
    fingerprint = digest()

    accept = fn fail? ->
      Repo.transaction(fn ->
        ["created" | _] =
          row("SELECT * FROM relay_fn.idempotency_begin('POST /v1/notifications', $1, $2)", [
            key,
            fingerprint
          ])

        notification = id()
        ["created", ^notification] = row(@accept, [notification, recipient, nil, key])
        ["opened", delivery] = open(notification, "sms", digest())

        Repo.query!(
          "INSERT INTO relay_queue.oban_jobs (worker, queue, args) VALUES ('Relay.Delivery.Send', 'delivery', $1)",
          [%{"delivery_id" => Relay.Id.to_string(delivery)}]
        )

        ["appended", _, _] =
          row(
            "SELECT * FROM relay_fn.outbox_append($1, 'notification.accepted', $2, '{}', NULL)",
            [
              id(),
              "notification:" <> Relay.Id.to_string(notification)
            ]
          )

        "stored" =
          one(
            "SELECT relay_fn.idempotency_complete('POST /v1/notifications', $1, $2, 202::smallint, '{}'::jsonb, $3, $4)",
            [
              key,
              fingerprint,
              digest(),
              data_key
            ]
          )

        if fail?, do: Repo.rollback(:injected), else: notification
      end)
    end

    assert {:error, :injected} = accept.(true)
    assert one("SELECT count(*) FROM relay.notifications WHERE dedup_key = $1", [key]) == 0

    assert one("SELECT count(*) FROM relay.outbox_events WHERE stream_key LIKE 'notification:%'") ==
             0

    assert {:ok, notification} = accept.(false)

    assert one(
             "SELECT count(*) FROM relay.deliveries d JOIN relay.delivery_events e ON e.delivery_id = d.id WHERE d.notification_id = $1",
             [notification]
           ) == 1

    assert one(
             "SELECT count(*) FROM relay_queue.oban_jobs WHERE args->>'delivery_id' IS NOT NULL AND worker = 'Relay.Delivery.Send'"
           ) >= 1

    assert one("SELECT count(*) FROM relay.outbox_events WHERE stream_key = $1", [
             "notification:" <> Relay.Id.to_string(notification)
           ]) == 1
  end
end
