defmodule Relay.Delivery.AttemptTest do
  use Relay.DataCase, async: false

  alias RelayTest.DeliveryFixture
  alias RelayTest.TenantFixture

  setup do
    TenantFixture.as_role("relay_worker")
    DeliveryFixture.sendable!()
  end

  describe "C-31 attempts" do
    test "C-31: a terminal attempt is never overwritten", %{scope: scope, delivery_id: id} do
      attempt = DeliveryFixture.started_attempt!(scope, id)

      assert {:applied, _} =
               DeliveryFixture.finish(scope, id, attempt, :failed, failure_class: "transient")

      assert {:already_terminal, _} =
               DeliveryFixture.finish(scope, id, attempt, :succeeded, delivery_rank: 1)
    end

    test "C-31: a retry is a new attempt with the next number", %{scope: scope, delivery_id: id} do
      first = DeliveryFixture.started_attempt!(scope, id)

      {:applied, _} =
        DeliveryFixture.finish(scope, id, first, :failed, failure_class: "transient")

      second = DeliveryFixture.started_attempt!(scope, id)
      assert second == first + 1
      assert {:ok, %{"attempt_count" => ^second}} = Relay.Delivery.delivery(scope, id)
    end

    test "C-31: only one attempt is active at a time", %{scope: scope, delivery_id: id} do
      active = DeliveryFixture.started_attempt!(scope, id)

      assert {:ok, {:attempt_active, ^active}} =
               Relay.Delivery.open_attempt(scope, %{id: Relay.Id.generate(), delivery_id: id})
    end

    test "C-31: an attempt starts once", %{scope: scope, delivery_id: id} do
      attempt = DeliveryFixture.started_attempt!(scope, id)
      assert {:ok, :not_pending} = Relay.Delivery.start_attempt(scope, id, attempt)
      assert {:ok, :not_found} = Relay.Delivery.start_attempt(scope, Relay.Id.generate(), 1)
    end

    test "C-31: a provider acceptance moves the delivery to accepted", %{
      scope: scope,
      delivery_id: id
    } do
      attempt = DeliveryFixture.started_attempt!(scope, id)

      assert {:applied, _} =
               DeliveryFixture.finish(scope, id, attempt, :succeeded, delivery_rank: 1)

      assert {:ok, %{"delivery_rank" => 1}} = Relay.Delivery.delivery(scope, id)
    end
  end
end
