defmodule Relay.Platform.LeadershipTest do
  use ExUnit.Case, async: true

  alias Relay.Platform.Leadership

  describe "T-12 leadership decisions" do
    test "T-12: acquiring makes a fresh leader, renewing under the same token keeps the state" do
      assert Leadership.interpret("acquired", 3, nil) == {:lead, 3, true}
      assert Leadership.interpret("renewed", 3, 3) == {:lead, 3, false}
      assert Leadership.interpret("renewed", 4, 3) == {:lead, 4, true}
      assert Leadership.interpret("held_by_other", 4, 3) == :follow
    end

    test "T-12: five minutes without an observed leader raise the alarm" do
      assert Leadership.leaderless_ms() == 300_000
      refute Leadership.leaderless?(0, 300_000)
      assert Leadership.leaderless?(0, 300_001)
    end

    test "T-12: the lease is renewed at least three times per lease period" do
      assert Leadership.next_tick_ms(500, 30_000) == 500
      assert Leadership.next_tick_ms(3_600_000, 30_000) == 10_000
    end

    test "T-12: runners start only on worker nodes and only when enabled" do
      assert Leadership.children([:api, :socket]) == []
      assert Leadership.children([:worker]) == []
    end
  end
end

defmodule Relay.Platform.LeadershipDatabaseTest do
  use Relay.MaintenanceCase, async: false

  alias Relay.Platform.Leadership.Store

  defp task_name, do: "test_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  test "T-12: one leader at a time; the follower takes over with a higher fencing token" do
    committed(fn ->
      name = task_name()
      assert {:ok, "acquired", t1} = Store.acquire(name, "a", 1_000)
      assert {:ok, "held_by_other", _} = Store.acquire(name, "b", 1_000)
      assert {:ok, "renewed", ^t1} = Store.acquire(name, "a", 1_000)
      assert {:ok, "saved"} = Store.save(name, t1, %{"cursor" => 1})

      Process.sleep(1_200)
      assert {:ok, "acquired", t2} = Store.acquire(name, "b", 1_000)
      assert t2 > t1
      assert {:ok, "not_leader"} = Store.save(name, t1, %{"cursor" => 2})
      assert {:ok, %{"cursor" => 1}} = Store.load_state(name)
      assert {:ok, "saved"} = Store.save(name, t2, %{"cursor" => 3})
    end)
  end
end

defmodule Relay.Platform.LeadershipRunnerTest do
  use Relay.DataCase, async: false

  alias Relay.Platform.Leadership.Runner
  alias Relay.Platform.Leadership.Store

  defmodule Counter do
    @moduledoc false
    @behaviour Relay.Platform.Leadership

    @impl true
    def run(%{state: state, fencing_token: token, node: node}) do
      send(:leadership_runner_test, {:ran, node, token})
      {:ok, %{"count" => ((state || %{})["count"] || 0) + 1}, 1}
    end
  end

  test "T-12: the leader runs the task and saves its state; another node only follows" do
    Process.register(self(), :leadership_runner_test)
    name = "test_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    opts = [name: name, module: Counter, ttl_ms: 60_000, retry_ms: 60_000]

    a = start_supervised!({Runner, [node: "a"] ++ opts}, id: :a)
    assert Runner.tick(a) == :leader
    assert_receive {:ran, "a", token}

    b = start_supervised!({Runner, [node: "b"] ++ opts}, id: :b)
    assert Runner.tick(b) == :follower
    refute_received {:ran, "b", _}

    assert Runner.tick(a) == :leader
    assert_receive {:ran, "a", ^token}
    assert {:ok, %{"count" => count}} = Store.load_state(name)
    assert count >= 2
  end
end
