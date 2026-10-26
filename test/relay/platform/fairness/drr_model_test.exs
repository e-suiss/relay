defmodule Relay.Platform.Fairness.DrrModelTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Platform.Fairness.Drr

  @quantum 5_000

  defp tenant(key, weight, waits),
    do: %{key: key, weight: weight, deficit: 0, last_served_round: 0, waits: waits}

  defp waits(count, cost, opts \\ []) do
    for n <- 1..count//1 do
      %{
        id: {Keyword.get(opts, :tag, :w), n},
        cost: cost,
        priority: Keyword.get(opts, :priority, 1),
        scheduled_at: Keyword.get(opts, :at, 0)
      }
    end
  end

  defp rounds(tenants, count, max_jobs, now \\ 0) do
    Enum.reduce(1..count, {[], tenants}, fn round_no, {taken, tenants} ->
      {more, tenants} = Drr.round(tenants, round_no, now, @quantum, max_jobs)
      {taken ++ more, tenants}
    end)
  end

  defp cost_by(taken),
    do:
      Enum.reduce(taken, %{}, fn {key, w}, acc -> Map.update(acc, key, w.cost, &(&1 + w.cost)) end)

  describe "T-21 the DRR model" do
    property "T-21: with unbounded backlogs the dispatched cost follows the weights within one quantum" do
      check all(
              wa <- integer(1..5),
              wb <- integer(1..5),
              cost <- integer(500..@quantum),
              count <- integer(1..8)
            ) do
        backlog = div(count * 6 * @quantum, cost) + 1

        tenants = [
          tenant(:a, wa, waits(backlog, cost, tag: :a)),
          tenant(:b, wb, waits(backlog, cost, tag: :b))
        ]

        {taken, _tenants} = rounds(tenants, count, 1_000_000)
        costs = cost_by(taken)
        assert abs(costs[:a] * wb - costs[:b] * wa) <= @quantum * max(wa, wb)
      end
    end

    test "T-21: weights 1 and 3 give a 1:3 share" do
      tenants = [
        tenant(:a, 1, waits(500, 1_000, tag: :a)),
        tenant(:b, 3, waits(500, 1_000, tag: :b))
      ]

      {taken, _} = rounds(tenants, 10, 1_000_000)
      assert cost_by(taken) == %{a: 50_000, b: 150_000}
    end

    test "T-21: a newcomer is served in the round after it arrives, whatever the other backlog" do
      {_taken, tenants} = Drr.round([tenant(:big, 1, waits(100_000, 1))], 1, 0, @quantum, 100)
      tenants = [tenant(:new, 1, waits(1, 1, tag: :new)) | tenants]
      {taken, _tenants} = Drr.round(tenants, 2, 0, @quantum, 100)
      assert [{:new, _} | _] = taken
    end

    test "T-21: an emptied tenant keeps no deficit" do
      {_taken, [t]} = Drr.round([tenant(:a, 3, waits(2, 10))], 1, 0, @quantum, 100)
      assert t.deficit == 0
      assert t.waits == []
    end

    test "T-21: only future jobs leave the tenant waiting with no deficit" do
      {taken, [t]} = Drr.round([tenant(:a, 1, waits(2, 10, at: 100))], 1, 0, @quantum, 100)
      assert taken == []
      assert t.deficit == 0
      assert length(t.waits) == 2
    end

    test "T-21: a deficit carries over while due jobs remain" do
      {taken, [t]} = Drr.round([tenant(:a, 1, waits(2, 4_000))], 1, 0, @quantum, 100)
      assert length(taken) == 1
      assert t.deficit == 1_000
    end

    test "T-21 (2): the quantum is the largest job unit and the cost limit" do
      assert Drr.quantum() == 5_000
      assert Drr.valid_cost?(5_000)
      refute Drr.valid_cost?(5_001)
      refute Drr.valid_cost?(0)
      assert_raise FunctionClauseError, fn -> Drr.round([], 1, 0, 4_999, 1) end
    end

    test "T-91 (1): the dispatcher's target depth is twice the lane budget per node" do
      assert Drr.target_depth(10, 3) == 60
      assert Drr.queued_cap() == 1_000_000
    end
  end
end
