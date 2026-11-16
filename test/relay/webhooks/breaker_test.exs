defmodule Relay.Webhooks.BreakerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Webhooks.Breaker

  @params %{failure_threshold: 5, open_ms: 30_000, max_open_ms: 900_000, probe_ms: 20_000}

  defp attempt(breaker, now, result) do
    {decision, breaker} = Breaker.admit(breaker, now, @params)
    assert decision in [:allow, :probe]
    Breaker.record(breaker, now, @params, decision, result)
  end

  defp failures(breaker, now, count),
    do: Enum.reduce(1..count, breaker, fn _n, breaker -> attempt(breaker, now, :failure) end)

  defp opened(now), do: failures(Breaker.new(), now, 5)

  defp step(breaker, {now, result}) do
    case Breaker.admit(breaker, now, @params) do
      {{:reject, _wait}, breaker} -> breaker
      {decision, breaker} -> Breaker.record(breaker, now, @params, decision, result)
    end
  end

  defp events do
    list_of(tuple({integer(0..120_000), member_of([:success, :failure])}), max_length: 60)
  end

  describe "WH-35 state machine" do
    test "WH-35: a closed breaker opens after five failures in a row" do
      breaker = failures(Breaker.new(), 1_000, 4)
      assert %Breaker{state: :closed, failures: 4} = breaker
      assert {:allow, ^breaker} = Breaker.admit(breaker, 1_000, @params)

      breaker = attempt(breaker, 1_000, :failure)
      assert %Breaker{state: :open, open_count: 1, open_until: 31_000} = breaker
    end

    test "WH-35: a success in between starts the count again" do
      breaker =
        Breaker.new()
        |> failures(0, 4)
        |> attempt(0, :success)
        |> failures(0, 4)

      assert %Breaker{state: :closed, failures: 4} = breaker
    end

    test "WH-35: an open breaker rejects without an attempt and says how long to wait" do
      breaker = opened(1_000)

      assert {{:reject, 30_000}, ^breaker} = Breaker.admit(breaker, 1_000, @params)
      assert {{:reject, 1}, ^breaker} = Breaker.admit(breaker, 30_999, @params)
    end

    test "WH-35: a half-open breaker lets one probe through" do
      {decision, breaker} = Breaker.admit(opened(1_000), 31_000, @params)

      assert decision == :probe
      assert %Breaker{state: :half_open, probe_until: 51_000} = breaker
      assert {{:reject, 19_000}, ^breaker} = Breaker.admit(breaker, 32_000, @params)
    end

    test "WH-35: a successful probe closes the breaker and resets it" do
      {:probe, breaker} = Breaker.admit(opened(1_000), 31_000, @params)
      breaker = Breaker.record(breaker, 31_500, @params, :probe, :success)

      assert breaker == Breaker.new()
      assert %Breaker{open_until: 61_500} = failures(breaker, 31_500, 5)
    end

    test "WH-35: a failed probe opens the breaker again for twice as long, at most fifteen minutes" do
      durations =
        Enum.map_reduce(1..8, {opened(0), 30_000}, fn _round, {breaker, now} ->
          {:probe, breaker} = Breaker.admit(breaker, now, @params)
          breaker = Breaker.record(breaker, now, @params, :probe, :failure)
          assert breaker.state == :open
          {breaker.open_until - now, {breaker, breaker.open_until}}
        end)

      assert elem(durations, 0) ==
               [60_000, 120_000, 240_000, 480_000, 900_000, 900_000, 900_000, 900_000]

      assert Enum.map(1..7, &Breaker.open_ms(&1, @params)) ==
               [30_000, 60_000, 120_000, 240_000, 480_000, 900_000, 900_000]

      assert Breaker.open_ms(10_000, @params) == 900_000
    end

    test "WH-35: a probe that never reports back stops blocking after the probe time" do
      {:probe, breaker} = Breaker.admit(opened(0), 30_000, @params)

      assert {{:reject, 1}, ^breaker} = Breaker.admit(breaker, 49_999, @params)
      assert {:probe, %Breaker{probe_until: 70_000}} = Breaker.admit(breaker, 50_000, @params)
    end

    test "WH-35: a result that arrives after the breaker moved on changes nothing" do
      open = opened(0)
      assert Breaker.record(open, 10, @params, :allow, :failure) == open
      assert Breaker.record(open, 10, @params, :allow, :success) == open

      {:probe, half_open} = Breaker.admit(open, 30_000, @params)
      assert Breaker.record(half_open, 30_001, @params, :allow, :failure) == half_open
      assert Breaker.record(Breaker.new(), 0, @params, :probe, :failure) == Breaker.new()
    end

    property "WH-35: the breaker is open only after failures, and never longer than the cap" do
      check all events <- events() do
        ordered = Enum.sort_by(events, &elem(&1, 0))

        Enum.reduce(ordered, Breaker.new(), fn {now, _result} = event, breaker ->
          next = step(breaker, event)

          assert next.failures < @params.failure_threshold
          assert next.state != :open or next.open_until - now <= @params.max_open_ms
          assert next.state != :open or next.open_count >= 1
          next
        end)
      end
    end
  end

  describe "WH-35 stored state" do
    test "WH-35: the state survives being stored and read back" do
      {:probe, half_open} = Breaker.admit(opened(0), 30_000, @params)

      for breaker <- [Breaker.new(), failures(Breaker.new(), 0, 3), opened(0), half_open] do
        stored = breaker |> Breaker.dump() |> Jason.encode!() |> Jason.decode!()
        assert Breaker.load(stored) == {:ok, breaker}
      end
    end

    test "WH-35: anything that is not a stored state is refused" do
      valid = Breaker.dump(opened(0))

      refused = [
        nil,
        %{},
        %{valid | "state" => "ajar"},
        %{valid | "failures" => -1},
        %{valid | "open_count" => "1"},
        %{valid | "open_until" => nil},
        %{valid | "state" => "half_open"}
      ]

      for stored <- refused do
        assert Breaker.load(stored) == :error
      end
    end
  end
end
