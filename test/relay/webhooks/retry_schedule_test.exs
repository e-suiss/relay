defmodule Relay.Webhooks.RetryScheduleTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Webhooks.RetrySchedule

  @second 1_000
  @minute 60 * @second
  @hour 60 * @minute
  @jitter_bp 2_000
  @bounds %{
    min_attempts: 1,
    max_attempts: 15,
    min_total_ms: @minute,
    max_total_ms: 168 * @hour,
    min_wait_ms: 5 * @second,
    max_wait_ms: 24 * @hour
  }
  @now ~U[2026-11-16 08:00:00.000Z]
  @options [jitter_bp: @jitter_bp, max_deferrals: 3]

  defp id(seed) do
    random = binary_part(:crypto.hash(:sha256, Integer.to_string(seed)), 0, 10)
    Relay.Id.build(1_793_000_000_000, random)
  end

  defp fail(waits, progress, id, options \\ []),
    do: RetrySchedule.after_failure(waits, progress, id, @now, @options ++ options)

  defp tries(waits, progress, id, retry_after, count) do
    options = if retry_after, do: [retry_after_ms: retry_after], else: []

    case fail(waits, progress, id, options) do
      {:retry, _at, progress, _source} -> tries(waits, progress, id, retry_after, count + 1)
      {:exhausted, progress} -> {count + 1, progress}
    end
  end

  defp mixed(waits, answers, id) do
    Enum.reduce_while(answers, {0, %{attempts: 0, deferrals: 0}}, fn answer, {tries, progress} ->
      case fail(waits, progress, id, retry_after_ms: answer) do
        {:retry, _at, progress, _source} -> {:cont, {tries + 1, progress}}
        {:exhausted, progress} -> {:halt, {tries + 1, progress}}
      end
    end)
  end

  defp schedule, do: list_of(integer(5_000..86_400_000), min_length: 1, max_length: 15)

  defp answers, do: list_of(one_of([constant(nil), integer(0..200_000_000)]), length: 20)

  describe "WH-22 schedule" do
    test "WH-22: the standard schedule has ten attempts over about 76 hours" do
      waits = RetrySchedule.standard()

      expected = [
        0,
        5 * @second,
        5 * @minute,
        30 * @minute,
        2 * @hour,
        5 * @hour,
        10 * @hour,
        14 * @hour,
        20 * @hour,
        24 * @hour
      ]

      assert waits == expected
      assert RetrySchedule.attempts(waits) == 10
      assert RetrySchedule.total_window_ms(waits) == 75 * @hour + 35 * @minute + 5 * @second
      assert RetrySchedule.longest_window_ms(waits, @jitter_bp) == 326_526_000
      assert RetrySchedule.validate(waits, @bounds) == {:ok, waits}
    end

    property "WH-22: every wait carries jitter of at most twenty percent in either direction" do
      waits = RetrySchedule.standard()

      check all seed <- integer(), attempt <- integer(1..10) do
        nominal = Enum.at(waits, attempt - 1)
        assert {:ok, wait} = RetrySchedule.wait_ms(waits, attempt, id(seed), @jitter_bp)
        assert wait >= nominal - div(nominal, 5)
        assert wait <= nominal + div(nominal, 5)
      end
    end

    test "WH-22: the jitter derives from the message id and the attempt, not from a random source" do
      waits = RetrySchedule.standard()
      wait = &RetrySchedule.wait_ms(waits, &2, id(&1), @jitter_bp)

      for seed <- 1..20, attempt <- 1..10 do
        first = wait.(seed, attempt)
        assert {:ok, _wait} = first
        assert wait.(seed, attempt) == first
      end

      assert wait.(1, 1) == {:ok, 0}
      assert 1..200 |> Enum.map(&wait.(&1, 6)) |> Enum.uniq() |> length() > 150
      assert 2..10 |> Enum.map(&wait.(1, &1)) |> Enum.uniq() |> length() == 9
      assert RetrySchedule.wait_ms(waits, 6, id(1), 0) == {:ok, 5 * @hour}
    end

    test "WH-22: the time of the next attempt follows from the attempts already made" do
      waits = RetrySchedule.standard()

      assert RetrySchedule.next_attempt_at(waits, 0, id(1), @now, @jitter_bp) == {:ok, @now}

      assert {:ok, second} = RetrySchedule.next_attempt_at(waits, 1, id(1), @now, @jitter_bp)
      assert DateTime.diff(second, @now, :millisecond) in 4_000..6_000

      assert {:ok, last} = RetrySchedule.next_attempt_at(waits, 9, id(1), @now, @jitter_bp)
      assert DateTime.diff(last, @now, :millisecond) in (19 * @hour + 12 * @minute)..(29 * @hour)
    end

    test "WH-22: a schedule ends: there is no attempt after the last one" do
      waits = RetrySchedule.standard()

      assert RetrySchedule.wait_ms(waits, 11, id(1), @jitter_bp) == :exhausted
      assert RetrySchedule.next_attempt_at(waits, 10, id(1), @now, @jitter_bp) == :exhausted

      assert tries(waits, %{attempts: 0, deferrals: 0}, id(1), nil, 0) ==
               {10, %{attempts: 10, deferrals: 0}}
    end

    test "WH-22: a tenant schedule must lie inside the bounds" do
      for waits <- [[@minute], [0, @minute], [0, 5 * @second, 55 * @second], [24 * @hour]] do
        assert RetrySchedule.validate(waits, @bounds) == {:ok, waits}
      end

      week = List.duplicate(24 * @hour, 7)
      assert RetrySchedule.validate(week, @bounds) == {:ok, week}

      refused = [
        {[], :invalid_schedule},
        {:infinity, :invalid_schedule},
        {[0, :infinity], :invalid_schedule},
        {[0, 1.5 * @minute], :invalid_schedule},
        {[0, -@minute], :invalid_schedule},
        {List.duplicate(@minute, 16), :attempts_out_of_bounds},
        {[0, 4_999, @minute], :wait_out_of_bounds},
        {[0, 24 * @hour + 1], :wait_out_of_bounds},
        {[24 * @hour + 1], :wait_out_of_bounds},
        {[0], :window_out_of_bounds},
        {[0, 5 * @second], :window_out_of_bounds},
        {[1 | week], :window_out_of_bounds}
      ]

      for {waits, violation} <- refused do
        assert RetrySchedule.validate(waits, @bounds) == {:error, violation}
      end
    end

    property "WH-22: a schedule inside the bounds is tried exactly as often as it has attempts" do
      check all waits <- schedule(), seed <- integer() do
        assert {count, %{attempts: attempts}} =
                 tries(waits, %{attempts: 0, deferrals: 0}, id(seed), nil, 0)

        assert count == length(waits)
        assert attempts == length(waits)
      end
    end
  end

  describe "WH-25 Retry-After" do
    test "WH-25: a Retry-After longer than the schedule is applied and does not count as an attempt" do
      waits = RetrySchedule.standard()
      progress = %{attempts: 1, deferrals: 0}

      assert {:retry, at, %{attempts: 1, deferrals: 1}, :retry_after} =
               fail(waits, progress, id(1), retry_after_ms: 10 * @minute)

      assert DateTime.diff(at, @now, :millisecond) == 10 * @minute
    end

    test "WH-25: the schedule is applied when it is the longer one, and the attempt counts" do
      waits = RetrySchedule.standard()
      progress = %{attempts: 1, deferrals: 0}

      assert {:retry, at, %{attempts: 2, deferrals: 0}, :schedule} =
               fail(waits, progress, id(1), retry_after_ms: 30 * @second)

      assert DateTime.diff(at, @now, :millisecond) in (4 * @minute)..(6 * @minute)
      assert fail(waits, progress, id(1)) == fail(waits, progress, id(1), retry_after_ms: 1)
    end

    test "WH-25: a message is deferred at most three times, then the schedule runs as usual" do
      waits = RetrySchedule.standard()
      day = [retry_after_ms: 48 * @hour]

      progress =
        Enum.reduce(1..3, %{attempts: 0, deferrals: 0}, fn round, progress ->
          assert {:retry, at, %{attempts: 0, deferrals: ^round} = next, :retry_after} =
                   fail(waits, progress, id(1), day)

          assert DateTime.diff(at, @now, :millisecond) == 48 * @hour
          next
        end)

      assert {:retry, at, %{attempts: 1, deferrals: 3}, :schedule} =
               fail(waits, progress, id(1), day)

      assert DateTime.diff(at, @now, :millisecond) in 4_000..6_000

      assert tries(waits, %{attempts: 0, deferrals: 0}, id(1), 48 * @hour, 0) ==
               {13, %{attempts: 10, deferrals: 3}}
    end

    test "WH-25: a deferral is still granted after the last attempt of the schedule" do
      waits = RetrySchedule.standard()

      assert {:retry, _at, %{attempts: 9, deferrals: 1}, :retry_after} =
               fail(waits, %{attempts: 9, deferrals: 0}, id(1), retry_after_ms: @second)

      assert fail(waits, %{attempts: 9, deferrals: 3}, id(1), retry_after_ms: @second) ==
               {:exhausted, %{attempts: 10, deferrals: 3}}
    end

    test "WH-25: the caller may cap what a consumer asks for" do
      waits = RetrySchedule.standard()
      options = [retry_after_ms: 400 * @hour, max_retry_after_ms: 24 * @hour]

      assert {:retry, at, %{attempts: 0, deferrals: 1}, :retry_after} =
               fail(waits, %{attempts: 0, deferrals: 0}, id(1), options)

      assert DateTime.diff(at, @now, :millisecond) == 24 * @hour
    end

    property "WH-25: with any mix of answers a message is tried at most attempts plus three times" do
      waits = RetrySchedule.standard()

      check all answers <- answers(), seed <- integer() do
        {tries, final} = mixed(waits, answers, id(seed))

        assert tries <= 13
        assert final.attempts <= 10
        assert final.deferrals <= 3
      end
    end
  end
end
