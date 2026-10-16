defmodule Relay.Delivery.LedgerEntryTest do
  use ExUnit.Case, async: true

  alias Relay.Delivery.Ledger

  @base %{
    id: <<1::128>>,
    delivery_id: <<2::128>>,
    actor: :provider_webhook,
    event_type: "attempt.succeeded",
    occurred_at: ~U[2026-10-16 10:00:00Z]
  }

  describe "C-32 ledger entries" do
    test "C-32: an entry carries actor, event, raw code and occurrence time" do
      assert {:ok, entry} =
               Ledger.new(
                 Map.merge(@base, %{raw_code: "250", attempt_no: 1, delivery_rank: :accepted})
               )

      params = Ledger.params(entry)
      assert length(params) == 17
      assert Enum.at(params, 3) == "provider_webhook"
      assert Enum.at(params, 4) == "attempt.succeeded"
      assert Enum.at(params, 5) == "250"
      assert Enum.at(params, 10) == 1
    end

    test "C-32: the event names are the closed set of this stage" do
      assert Ledger.event_types() ==
               ~w(delivery.queued delivery.skipped delivery.deferred delivery.cancelled
                  attempt.started attempt.succeeded attempt.failed attempt.unknown)
    end

    test "C-32: values outside the closed sets are refused" do
      for {field, value} <- [
            actor: :robot,
            event_type: "delivery.opened",
            delivery_rank: :read,
            failure_kind: :lost,
            after_delivered: :maybe,
            occurred_at: "2026-10-16"
          ] do
        assert {:error, %Relay.Error{code: :invalid_ledger_entry, details: %{field: ^field}}} =
                 Ledger.new(Map.put(@base, field, value))
      end
    end

    test "C-32: an entry without its required fields is refused" do
      assert {:error, %Relay.Error{code: :invalid_ledger_entry}} =
               Ledger.new(Map.delete(@base, :delivery_id))
    end

    test "C-32: the axis effect is passed as the database codes" do
      {:ok, entry} =
        Ledger.new(
          Map.merge(@base, %{
            delivery_rank: :delivered,
            failure_kind: :bounced,
            after_delivered: :conflict
          })
        )

      params = Ledger.params(entry)
      assert Enum.at(params, 10) == 2
      assert Enum.at(params, 11) == "bounced"
      assert Enum.at(params, 14) == "conflict"
    end
  end
end
