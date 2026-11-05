defmodule Relay.Channels.LiveTest do
  use Relay.DataCase, async: false

  alias Relay.Datasets
  alias RelayTest.DeliveryFixture
  alias RelayTest.TenantFixture

  @datasets ["channel_event_evidence", "channel_parameters"]

  defp forget do
    for name <- @datasets,
        do: :ok = Datasets.Cache.invalidate(Datasets.Cache, {Datasets.installation_scope(), name})
  end

  setup do
    forget()
    {:ok, _report} = Datasets.load_package(TenantFixture.actor())
    on_exit(&forget/0)
    :ok
  end

  describe "CH-14 INV-43 channel step" do
    test "CH-14, INV-43: a delivery without a verified route is held and comes back later" do
      %{scope: scope, delivery_id: id} = DeliveryFixture.sendable!()

      assert Relay.Channels.Live.deliver(scope, id, %{}) == {:snooze, 300}

      assert {:ok, ledger} = Relay.Delivery.ledger(scope, id)
      assert Enum.any?(ledger, &(&1["event_type"] == "delivery.held"))
      assert {:ok, %{"attempt_count" => 0}} = Relay.Delivery.delivery(scope, id)
    end

    test "CH-71, OP-65: the bundled declarations are the active channel_event_evidence version" do
      assert {:ok, declarations} = Datasets.channel_declarations()
      assert "fake" in Relay.ChannelDeclarations.providers(declarations)
      assert is_binary(declarations.version_id)
    end
  end
end
