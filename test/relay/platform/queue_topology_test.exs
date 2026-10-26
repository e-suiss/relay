defmodule Relay.Platform.QueueTopologyTest do
  use ExUnit.Case, async: true

  alias Relay.Platform.Lane
  alias Relay.Platform.Queue

  @golden "queue_topology.txt"

  describe "T-90 T-32 TN-51 queue topology" do
    test "T-90: the queues and their per-node budgets are the golden list" do
      lines = for {queue, budget} <- Lane.queues(), do: "#{queue} #{budget}\n"
      Relay.Golden.assert_golden(@golden, lines)
    end

    test "T-90: a worker node's Oban queues are built from the lane module, not read from configuration" do
      base = Application.fetch_env!(:relay, Oban)
      refute Keyword.has_key?(base, :queues)
      refute File.read!("config/config.exs") =~ ~r/^\s*queues:/m
      assert Queue.options(base, [:worker])[:queues] == Lane.queues()
      assert Queue.options(base, [:api, :socket])[:queues] == []
    end

    test "T-32 (1): every lane has its own queue and budget, and the replay and maintenance queues are separate" do
      queues = Keyword.keys(Lane.queues())
      assert Enum.map(Lane.all(), &Lane.queue/1) == [:l0, :l1, :l2, :l3]
      assert Enum.all?(Lane.all(), &(Lane.queue(&1) in queues))
      assert Lane.budget(:l0) >= Lane.budget(:l2)

      assert Enum.all?(Lane.queues(), fn {_queue, budget} -> is_integer(budget) and budget > 0 end)
    end

    test "TN-51: no queue is named after a tenant; lane queues follow the lane and channel pattern" do
      for {queue, _budget} <- Lane.queues() do
        name = Atom.to_string(queue)
        assert name =~ ~r/^(l[0-3](_[a-z_]+)?|dlq_replay|maintenance)$/, name
        refute name =~ ~r/[0-9a-f]{8}-|ten_|tenant/, name
      end
    end

    test "T-90: a channel queue name maps back to its lane; other names do not" do
      assert Lane.lane_of_queue("l0") == :l0
      assert Lane.lane_of_queue("l0_sms") == :l0
      assert Lane.lane_of_queue(:l3_web_push) == :l3
      assert Lane.lane_of_queue("l2_fax") == nil
      assert Lane.lane_of_queue("l4") == nil
      assert Lane.lane_of_queue("dlq_replay") == nil
      assert Lane.lane_queues(:l2) == ["l2"]
    end
  end
end
