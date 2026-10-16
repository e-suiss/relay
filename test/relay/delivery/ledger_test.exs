defmodule Relay.Delivery.LedgerTest do
  use Relay.DataCase, async: false

  alias Relay.Repo
  alias RelayTest.DeliveryFixture
  alias RelayTest.TenantFixture

  setup do
    TenantFixture.as_role("relay_worker")
    DeliveryFixture.sendable!()
  end

  defp entry(delivery_id, attrs) do
    {:ok, entry} =
      Relay.Delivery.ledger_entry(
        Map.merge(
          %{
            id: Relay.Id.generate(),
            delivery_id: delivery_id,
            actor: :provider_webhook,
            provider: "mailpit",
            occurred_at: Relay.Clock.utc_now()
          },
          Map.new(attrs)
        )
      )

    entry
  end

  defp append(scope, entry) do
    {:ok, result} = Relay.Delivery.append_ledger(scope, entry)
    result
  end

  describe "C-32 OP-3 OP-4 the append-only ledger" do
    test "C-32: an event records actor, event, raw code and both times", %{
      scope: scope,
      delivery_id: id
    } do
      attempt = DeliveryFixture.started_attempt!(scope, id)

      {:applied, :accepted, _} =
        append(
          scope,
          entry(id,
            attempt_no: attempt,
            event_type: "attempt.succeeded",
            raw_code: "250",
            delivery_rank: :accepted
          )
        )

      {:ok, events} = Relay.Delivery.ledger(scope, id)
      event = Enum.find(events, &(&1["event_type"] == "attempt.succeeded"))

      assert event["actor"] == "provider_webhook"
      assert event["raw_code"] == "250"
      assert %DateTime{} = event["occurred_at"]
      assert %DateTime{} = event["received_at"]
    end

    test "OP-4: a late event is written but never moves the delivery back", %{
      scope: scope,
      delivery_id: id
    } do
      attempt = DeliveryFixture.started_attempt!(scope, id)

      {:applied, :delivered, _} =
        append(
          scope,
          entry(id,
            attempt_no: attempt,
            event_type: "attempt.succeeded",
            delivery_rank: :delivered
          )
        )

      assert {:stale_ignored, :delivered, _} =
               append(
                 scope,
                 entry(id,
                   attempt_no: attempt,
                   event_type: "attempt.succeeded",
                   delivery_rank: :accepted
                 )
               )

      {:ok, delivery} = Relay.Delivery.delivery(scope, id)
      assert delivery["delivery_rank"] == 2
      assert delivery["late_event_count"] >= 1
    end

    test "DS-4: a provider event from the far future is rejected", %{
      scope: scope,
      delivery_id: id
    } do
      future = DateTime.add(Relay.Clock.utc_now(), 2 * 3600, :second)

      assert {:rejected_future_timestamp, _, _} =
               append(scope, entry(id, event_type: "attempt.failed", occurred_at: future))
    end

    test "C-32: ledger rows cannot be updated or deleted", %{scope: scope, delivery_id: id} do
      for sql <- [
            "UPDATE relay.delivery_events SET raw_code = 'x' WHERE delivery_id = $1",
            "DELETE FROM relay.delivery_events WHERE delivery_id = $1"
          ] do
        assert {:error, %Postgrex.Error{}} =
                 Repo.in_scope(scope, fn _ ->
                   case Repo.query(sql, [id]) do
                     {:ok, result} -> result
                     {:error, error} -> Repo.rollback(error)
                   end
                 end)
      end
    end

    test "C-2: the projection rebuilds from the ledger without differences", %{
      scope: scope,
      delivery_id: id
    } do
      attempt = DeliveryFixture.started_attempt!(scope, id)
      {:applied, _} = DeliveryFixture.finish(scope, id, attempt, :succeeded, delivery_rank: 1)

      _ =
        append(
          scope,
          entry(id,
            attempt_no: attempt,
            event_type: "attempt.succeeded",
            delivery_rank: :delivered
          )
        )

      assert {:ok, []} = Relay.Delivery.rebuild_projection(scope, id)
    end

    test "TN-15: another tenant's delivery is not found", %{delivery_id: id} do
      other = TenantFixture.tenant!()

      assert {:delivery_not_found, _, _} =
               append(
                 other.live,
                 entry(id, event_type: "delivery.cancelled", failure_kind: :cancelled)
               )
    end
  end
end
