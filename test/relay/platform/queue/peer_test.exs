defmodule Relay.Platform.Queue.PeerTest do
  use Relay.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Relay.Platform.Queue.PeerStore
  alias Relay.QueueRepo
  alias RelayTest.TenantFixture

  setup do
    owner = Sandbox.start_owner!(QueueRepo, shared: false)
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    TenantFixture.as_role(QueueRepo, "relay_queue")
    %{name: "Oban.Test." <> TenantFixture.random()}
  end

  defp at(seconds),
    do: ~N[2026-10-16 12:00:00.000000] |> NaiveDateTime.add(seconds, :second)

  describe "T-12 queue leadership through the queue role" do
    test "T-12: one node leads; another cannot take an unexpired lease", %{name: name} do
      assert {:ok, true} = PeerStore.elect(name, "node-a", at(0), at(30))
      assert {:ok, false} = PeerStore.elect(name, "node-b", at(10), at(40))
      assert PeerStore.leader(name) == "node-a"
    end

    test "T-12: the leader renews its own lease", %{name: name} do
      assert {:ok, true} = PeerStore.elect(name, "node-a", at(0), at(30))
      assert {:ok, true} = PeerStore.elect(name, "node-a", at(15), at(45))
    end

    test "T-12: an expired lease passes to another node", %{name: name} do
      assert {:ok, true} = PeerStore.elect(name, "node-a", at(0), at(30))
      assert {:ok, true} = PeerStore.elect(name, "node-b", at(31), at(61))
      assert PeerStore.leader(name) == "node-b"
    end

    test "T-12: a resigning leader frees the lease at once", %{name: name} do
      assert {:ok, true} = PeerStore.elect(name, "node-a", at(0), at(30))
      assert :ok = PeerStore.resign(name, "node-a")
      assert PeerStore.leader(name) == nil
      assert {:ok, true} = PeerStore.elect(name, "node-b", at(1), at(31))
    end
  end
end
