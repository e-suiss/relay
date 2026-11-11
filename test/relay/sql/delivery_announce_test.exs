defmodule Relay.Sql.DeliveryAnnounceTest do
  use Relay.SqlCase, async: false

  @announce "SELECT relay_private.engagement_announce(d, $2, $3, $4) FROM relay.deliveries d WHERE d.id = $1"

  defp outbox(notification) do
    for [type, payload] <-
          rows(
            """
            SELECT o.event_type, o.payload FROM relay.outbox_events o
            WHERE o.payload ->> 'notification_id' = $1 ORDER BY o.created_at, o.seq, o.id
            """,
            [Relay.Id.to_string(notification)]
          ),
        do: {type, payload}
  end

  defp types(notification), do: Enum.map(outbox(notification), &elem(&1, 0))

  defp cancel(delivery) do
    "cancelled" =
      one("SELECT relay_fn.delivery_cancel($1, 'ops.stop', $2, $3, $4, $5, $6)", [
        delivery,
        digest() | actor()
      ])
  end

  defp started(notification, channel) do
    d = delivery!(notification, channel)

    ["opened", 1] =
      row("SELECT * FROM relay_fn.attempt_open($1, $2, NULL, NULL, $3)", [id(), d, "k"])

    "started" = one("SELECT relay_fn.attempt_start($1, 1)", [d])
    d
  end

  describe "E-84 delivery.status_changed" do
    test "E-84, DS-14: every status transition is announced with the previous status" do
      %{notification: n} = scenario!()
      d = started(n, "sms")

      ledger!(d, attempt_no: 1, event_type: "dlr.accepted", rank: 1)
      ledger!(d, attempt_no: 1, event_type: "dlr.accepted", rank: 1)
      ledger!(d, attempt_no: 1, event_type: "dlr.delivered", rank: 2)

      changes =
        for {"delivery.status_changed", p} <- outbox(n),
            do: {p["previous_status"], p["status"], p["channel"]}

      assert changes == [{"queued", "sent", "sms"}, {"sent", "delivered", "sms"}]
    end

    test "X-1: a status change carries the reason, rule and failure the API shows" do
      %{notification: n} = scenario!()
      d = started(n, "sms")

      ledger!(d,
        attempt_no: 1,
        event_type: "dlr.failed",
        failure_kind: "failed",
        failure_class: "permanent_target"
      )

      [{"delivery.status_changed", p} | _] = outbox(n)

      view =
        row(
          "SELECT (relay_private.delivery_reason(d)).* FROM relay.deliveries d WHERE d.id = $1",
          [d]
        )

      assert p["status"] == "failed"
      assert [p["reason"], p["rule_id"]] == view
      assert p["reason"] == "failed"
      failure = %{"kind" => "failed", "class" => "permanent_target", "retryable" => false}
      assert p["failure"] == failure
      assert p["delivery_id"] == Relay.Id.to_string(d)
      assert p["recipient_kind"] == "subscriber"
    end
  end

  describe "E-84 notification outcomes" do
    test "E-84: notification.delivered is announced once, at the first delivered delivery" do
      %{notification: n} = scenario!()
      sms = started(n, "sms")
      email = started(n, "email")

      ledger!(sms, attempt_no: 1, rank: 2)
      ledger!(email, attempt_no: 1, rank: 2)

      assert [{"notification.delivered", p}] =
               Enum.filter(outbox(n), &(elem(&1, 0) == "notification.delivered"))

      assert p["delivery_id"] == Relay.Id.to_string(sms)
      assert p["channel"] == "sms"
      refute "notification.failed" in types(n)
    end

    test "E-84: notification.failed waits until every delivery is terminal and none delivered" do
      %{notification: n} = scenario!()
      sms = started(n, "sms")
      email = started(n, "email")

      ledger!(sms, attempt_no: 1, failure_kind: "failed", failure_class: "permanent_target")
      refute "notification.failed" in types(n)

      cancel(email)
      assert Enum.count(types(n), &(&1 == "notification.failed")) == 1
      refute "notification.delivered" in types(n)
      refute "notification.expired" in types(n)
    end

    test "E-84: a notification whose deliveries were only cancelled announces no outcome" do
      %{notification: n} = scenario!()
      cancel(started(n, "sms"))

      assert "delivery.status_changed" in types(n)

      for outcome <- ~w(notification.delivered notification.failed notification.expired),
          do: refute(outcome in types(n))
    end
  end

  describe "E-84 engagement" do
    test "E-84: seen, read and archived are announced once and a click once per link rel" do
      admin = connect(:admin)

      on(admin, fn ->
        rolled_back(admin, fn ->
          %{notification: n} = scenario!()
          d = delivery!(n, "in_app")
          at = DateTime.utc_now()

          announce = fn kind, rel -> one(@announce, [d, kind, rel, at]) end

          assert announce.("seen", nil)
          refute announce.("seen", nil)
          assert announce.("read", nil)
          assert announce.("clicked", "primary")
          refute announce.("clicked", "primary")
          assert announce.("clicked", "invoice")
          assert announce.("archived", nil)

          assert types(n) == [
                   "notification.seen",
                   "notification.read",
                   "notification.clicked",
                   "notification.clicked",
                   "notification.archived"
                 ]

          rels = for {"notification.clicked", p} <- outbox(n), do: p["link_rel"]
          assert rels == ["primary", "invoice"]

          assert [{"notification.seen", seen} | _] = outbox(n)
          assert seen["channel"] == "in_app"
          assert is_binary(seen["seen_at"])

          assert error_message(@announce, [d, "clicked", nil, at]) == "invalid_argument"
        end)
      end)
    end
  end
end
