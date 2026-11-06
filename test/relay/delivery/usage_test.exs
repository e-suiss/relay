defmodule Relay.Delivery.UsageTest do
  use Relay.DataCase, async: false

  alias RelayTest.DeliveryFixture

  defp today, do: Relay.Clock.utc_now() |> DateTime.to_date()

  describe "C-88 OP-38 daily usage records" do
    test "INV-49, OP-38: finished attempts of a day are counted per channel, provider and outcome" do
      %{scope: scope, delivery_id: id} = DeliveryFixture.sendable!()
      first = DeliveryFixture.started_attempt!(scope, id)
      DeliveryFixture.finish(scope, id, first, :failed, failure_class: "transient")
      second = DeliveryFixture.started_attempt!(scope, id)
      DeliveryFixture.finish(scope, id, second, :succeeded)

      assert {:ok, rows} = Relay.Delivery.usage_rows(scope, today())

      assert [
               %{"provider" => "mailpit", "outcome" => "accepted", "quantity" => 1} = accepted,
               %{"provider" => "mailpit", "outcome" => "failed", "attempt_count" => 1}
             ] = rows

      assert accepted["is_test"] == false
      assert {:ok, []} = Relay.Delivery.usage_rows(scope, Date.add(today(), -1))
    end

    test "C-88: a day that has not closed is not written" do
      %{scope: scope, delivery_id: id} = DeliveryFixture.sendable!()
      n = DeliveryFixture.started_attempt!(scope, id)
      DeliveryFixture.finish(scope, id, n, :succeeded)

      counts = Relay.Delivery.close_usage_day(today())

      assert counts.day_open >= 1
      assert counts.recorded == 0
      assert counts.conflict == 0
    end
  end
end
