defmodule Relay.Platform.LanePriorityTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Platform.Lane

  describe "T-36 the in-lane priority map" do
    test "T-36: every row of the map" do
      rows = [
        {{:delivery, 1, :high}, 0},
        {{:delivery, 1, :normal}, 1},
        {{:delivery, 1, :low}, 1},
        {{:delivery, 2, :normal}, 2},
        {{:delivery, 3, :high}, 2},
        {{:scheduled, 1, :normal}, 3},
        {{:waitpoint_timer, 1, :normal}, 3},
        {{:digest, 1, :normal}, 4},
        {{:first_slice, 1, :normal}, 5},
        {{:next_slice, 1, :normal}, 6},
        {{:first_slice, 2, :normal}, 7},
        {{:next_slice, 3, :normal}, 7},
        {{:delivery, 4, :normal}, 8},
        {{:delivery, 9, :high}, 8},
        {{:dlq_replay, 1, :normal}, 0},
        {{:maintenance, 1, :normal}, 0}
      ]

      for {{kind, attempt, requested}, expected} <- rows,
          do: assert(Lane.priority(kind, attempt, requested) == expected, inspect(kind))
    end

    property "T-36: a retry never shares the first attempt's priority" do
      check all(
              attempt <- integer(2..50),
              requested <- member_of([:high, :normal, :low])
            ) do
        assert Lane.priority(:delivery, attempt, requested) >
                 Lane.priority(:delivery, 1, requested)
      end
    end

    test "T-36: priority 9 is never used" do
      kinds =
        ~w(delivery scheduled waitpoint_timer digest first_slice next_slice dlq_replay maintenance)a

      for kind <- kinds,
          attempt <- 1..6,
          requested <- [:high, :normal, :low],
          do: assert(Lane.priority(kind, attempt, requested) in 0..8)
    end

    test "T-36: dead-letter replays and maintenance run in their own queues" do
      queues = Keyword.keys(Lane.queues())
      assert :dlq_replay in queues
      assert :maintenance in queues
    end
  end
end
