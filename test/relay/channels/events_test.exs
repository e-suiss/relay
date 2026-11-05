defmodule Relay.Channels.EventsTest do
  use Relay.DataCase, async: false

  alias Relay.Channels.Live
  alias Relay.Datasets
  alias RelayTest.DeliveryFixture
  alias RelayTest.TenantFixture

  defp forget,
    do:
      Datasets.Cache.invalidate(
        Datasets.Cache,
        {Datasets.installation_scope(), "channel_event_evidence"}
      )

  setup do
    forget()
    {:ok, _report} = Datasets.load_package(TenantFixture.actor())
    on_exit(&forget/0)
    :ok
  end

  defp event(delivery_id, code, fields \\ []) do
    Map.merge(
      %{delivery_id: delivery_id, provider: "fake", channel: "email", event_code: code},
      Map.new(fields)
    )
  end

  describe "DS-10 provider events" do
    test "DS-10, INV-5: a delivered event of the evidence table raises the delivery to delivered" do
      %{scope: scope, delivery_id: id} = DeliveryFixture.sendable!()

      assert {:ok, %{result: :applied, side_effect: "none"}} =
               Live.record_event(scope, event(id, "delivered"))

      assert {:ok, %{"delivery_rank" => 2}} = Relay.Delivery.delivery(scope, id)
      assert {:ok, ledger} = Relay.Delivery.ledger(scope, id)
      assert Enum.any?(ledger, &(&1["event_type"] == "provider.reported"))
    end

    test "DS-10: an event code without an evidence row is rejected" do
      %{scope: scope, delivery_id: id} = DeliveryFixture.sendable!()

      assert Live.record_event(scope, event(id, "opened")) == {:error, :unknown_event}

      assert Live.record_event(scope, event(Relay.Id.generate(), "delivered")) ==
               {:error, :delivery_not_found}
    end

    test "DS-6, CH-7, CH-8: a bounce takes its class from the mapping and an unmapped code is unknown" do
      %{scope: scope, delivery_id: id} = DeliveryFixture.sendable!()
      bounce = event(id, "bounced", raw_code: "hard_bounce", price: %{"amount" => "0"})

      assert {:ok, %{failure_class: "permanent_target", side_effect: "add_suppression"}} =
               Live.record_event(scope, bounce)

      assert {:ok, %{"failure_kind" => "bounced"}} = Relay.Delivery.delivery(scope, id)

      assert {:ok, %{failure_class: "unknown"}} =
               Live.record_event(scope, event(id, "undelivered", raw_code: "X-9"))
    end

    test "INV-13: the delivery of a provider idempotency key is read back from the key" do
      id = Relay.Id.generate()

      assert Live.delivery_of_key("dlv-" <> Relay.Id.to_string(id)) == {:ok, id}
      assert Live.delivery_of_key("dlv-nothing") == :error
      assert Live.delivery_of_key("other") == :error
    end
  end
end
