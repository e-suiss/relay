defmodule Relay.Policy.WindowTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Policy.Window

  @all_days [1, 2, 3, 4, 5, 6, 7]
  @ist "Europe/Istanbul"
  @ny "America/New_York"
  @berlin "Europe/Berlin"

  defp quiet(from, to, days \\ @all_days),
    do: [{:quiet, {:quiet, [%{days: days, from: from, to: to}]}}]

  defp next(zone, constraints, from, limit \\ nil),
    do: Window.next_allowed(from, limit || DateTime.add(from, 8, :day), zone, constraints)

  defp expect_next(zone, constraints, from, expected),
    do: assert_at(next(zone, constraints, from), expected)

  defp assert_at(result, expected) do
    assert {:ok, at} = result
    assert DateTime.compare(at, expected) == :eq, "#{at} is not #{expected}"
  end

  describe "PC-45 PC-58 (5) quiet hours" do
    test "PC-45: a range crossing midnight ends on the next day (Istanbul, no DST)" do
      constraints = quiet(~T[22:00:00], ~T[07:00:00])

      expect_next(@ist, constraints, ~U[2026-11-02 20:30:00Z], ~U[2026-11-03 04:00:00Z])
      expect_next(@ist, constraints, ~U[2026-11-03 03:59:00Z], ~U[2026-11-03 04:00:00Z])
      expect_next(@ist, constraints, ~U[2026-11-02 18:59:30Z], ~U[2026-11-02 18:59:30Z])
      expect_next(@ist, constraints, ~U[2026-11-02 19:00:00Z], ~U[2026-11-03 04:00:00Z])
    end

    test "PC-45: a range belongs to the weekday it starts on" do
      friday_night = quiet(~T[22:00:00], ~T[08:00:00], [5])

      expect_next(@ist, friday_night, ~U[2026-11-07 04:00:00Z], ~U[2026-11-07 05:00:00Z])
      expect_next(@ist, friday_night, ~U[2026-11-07 20:00:00Z], ~U[2026-11-07 20:00:00Z])
      expect_next(@ist, friday_night, ~U[2026-11-05 20:00:00Z], ~U[2026-11-05 20:00:00Z])
    end

    test "PC-58 (5): chained and overlapping ranges are cleared together" do
      constraints = quiet(~T[22:00:00], ~T[02:00:00]) ++ quiet(~T[01:00:00], ~T[06:00:00])

      expect_next(@ist, constraints, ~U[2026-11-02 20:00:00Z], ~U[2026-11-03 03:00:00Z])
    end

    test "PC-58 (5): a whole-day range on every day leaves no instant within eight days" do
      whole_day = quiet(~T[00:00:00], ~T[00:00:00])

      assert next(@ist, whole_day, ~U[2026-11-02 12:00:00Z]) == :none
    end

    test "PC-46: no allowed instant before the limit is :none" do
      constraints = quiet(~T[22:00:00], ~T[07:00:00])
      from = ~U[2026-11-02 20:30:00Z]

      assert next(@ist, constraints, from, ~U[2026-11-03 04:00:00Z]) == :none
      assert_at(next(@ist, constraints, from, ~U[2026-11-03 04:00:01Z]), ~U[2026-11-03 04:00:00Z])
    end
  end

  describe "WF-47 daylight saving time" do
    test "WF-47: America/New_York spring forward: a range ending inside the gap ends at 03:00 EDT" do
      constraints = quiet(~T[22:00:00], ~T[02:30:00])

      expect_next(@ny, constraints, ~U[2026-03-08 04:00:00Z], ~U[2026-03-08 07:00:00Z])
    end

    test "WF-47: America/New_York spring forward: a range ending after the gap ends at its local time" do
      constraints = quiet(~T[22:00:00], ~T[07:00:00])

      expect_next(@ny, constraints, ~U[2026-03-08 04:00:00Z], ~U[2026-03-08 11:00:00Z])
    end

    test "WF-47: America/New_York fall back: the first 01:30 ends a range, the repeated hour is quiet again" do
      constraints = quiet(~T[22:00:00], ~T[01:30:00])

      expect_next(@ny, constraints, ~U[2026-11-01 03:00:00Z], ~U[2026-11-01 05:30:00Z])
      expect_next(@ny, constraints, ~U[2026-11-01 06:10:00Z], ~U[2026-11-01 06:30:00Z])
    end

    test "WF-47: Europe/Berlin spring forward and fall back keep 07:00 local" do
      constraints = quiet(~T[22:00:00], ~T[07:00:00])

      expect_next(@berlin, constraints, ~U[2026-03-28 22:00:00Z], ~U[2026-03-29 05:00:00Z])
      expect_next(@berlin, constraints, ~U[2026-10-24 21:00:00Z], ~U[2026-10-25 06:00:00Z])
    end

    test "WF-47: Europe/Berlin: a range starting in the spring gap blocks from 03:00 CEST" do
      constraints = quiet(~T[02:30:00], ~T[04:00:00])

      assert Window.blocking(~U[2026-03-29 00:59:00Z], @berlin, constraints) == nil
      assert Window.blocking(~U[2026-03-29 01:00:00Z], @berlin, constraints) == :quiet
      expect_next(@berlin, constraints, ~U[2026-03-29 01:00:00Z], ~U[2026-03-29 02:00:00Z])
    end
  end

  describe "PC-58 (5) schedule, windows and dnd" do
    test "PC-58 (5): an availability schedule defers to the next start" do
      weekdays = [%{days: [1, 2, 3, 4, 5], from: ~T[09:00:00], to: ~T[18:00:00]}]
      schedule = [{:schedule, {:only, weekdays}}]

      expect_next(@ist, schedule, ~U[2026-11-07 07:00:00Z], ~U[2026-11-09 06:00:00Z])
      expect_next(@ist, schedule, ~U[2026-11-09 05:00:00Z], ~U[2026-11-09 06:00:00Z])
      expect_next(@ist, schedule, ~U[2026-11-09 10:00:00Z], ~U[2026-11-09 10:00:00Z])
      assert next(@ist, [{:schedule, {:only, []}}], ~U[2026-11-09 10:00:00Z]) == :none
    end

    test "PC-48: the 10:00–18:00 window in New York" do
      window = [{:pc48, {:only, [%{days: @all_days, from: ~T[10:00:00], to: ~T[18:00:00]}]}}]

      expect_next(@ny, window, ~U[2026-11-02 12:00:00Z], ~U[2026-11-02 15:00:00Z])
      expect_next(@ny, window, ~U[2026-11-02 23:30:00Z], ~U[2026-11-03 15:00:00Z])
    end

    test "WF-41 5: dnd_until defers to the minute after it" do
      dnd = [{:dnd, {:until, ~U[2026-11-02 13:10:30.250Z]}}]

      expect_next(@ist, dnd, ~U[2026-11-02 12:00:00Z], ~U[2026-11-02 13:11:00Z])
      expect_next(@ist, dnd, ~U[2026-11-02 14:00:00Z], ~U[2026-11-02 14:00:00Z])
    end

    test "PC-58 (5): blocking names the first constraint that blocks" do
      constraints = [
        {:first, {:until, ~U[2026-11-02 12:30:00Z]}},
        {:second, {:quiet, [%{days: @all_days, from: ~T[14:00:00], to: ~T[16:00:00]}]}}
      ]

      assert Window.blocking(~U[2026-11-02 12:00:00Z], @ist, constraints) == :first
      assert Window.blocking(~U[2026-11-02 12:40:00Z], @ist, constraints) == :second
      assert Window.blocking(~U[2026-11-02 13:00:00Z], @ist, constraints) == nil
    end

    test "WF-42: allowed_ms stops at the next blocked minute, the limit or the maximum" do
      constraints = quiet(~T[22:00:00], ~T[07:00:00]) ++ quiet(~T[07:05:00], ~T[08:00:00])
      at = ~U[2026-11-03 04:00:00Z]
      far = ~U[2026-11-04 00:00:00Z]
      near = ~U[2026-11-03 04:01:30Z]

      assert Window.allowed_ms(at, far, @ist, constraints, 600_000) == 300_000
      assert Window.allowed_ms(at, far, @ist, constraints, 120_000) == 120_000
      assert Window.allowed_ms(at, near, @ist, constraints, 600_000) == 90_000
      assert Window.allowed_ms(at, far, @ist, constraints, 0) == 0
    end
  end

  defp range do
    gen all days <- uniq_list_of(integer(1..7), min_length: 1, max_length: 7),
            from <- integer(0..(24 * 60 - 1)),
            to <- integer(0..(24 * 60 - 1)) do
      %{days: Enum.sort(days), from: time(from), to: time(to)}
    end
  end

  defp time(minutes), do: Time.new!(div(minutes, 60), rem(minutes, 60), 0)

  defp brute(from, limit, zone, constraints) do
    from
    |> Stream.iterate(&DateTime.add(&1, 60, :second))
    |> Enum.take_while(&(DateTime.compare(&1, limit) == :lt))
    |> Enum.find(:none, &(Window.blocking(&1, zone, constraints) == nil))
  end

  property "PC-46 PC-58 (5): the search finds the first allowed minute a minute-by-minute scan finds" do
    check all zone <- member_of([@ist, @ny, @berlin]),
              offset <- integer(0..(365 * 24 * 60)),
              ranges <- list_of(range(), max_length: 3),
              max_runs: 60 do
      from = DateTime.add(~U[2026-01-01 00:00:00Z], offset, :minute)
      limit = DateTime.add(from, 2, :day)
      constraints = [{:quiet, {:quiet, ranges}}]

      case brute(from, limit, zone, constraints) do
        :none -> assert Window.next_allowed(from, limit, zone, constraints) == :none
        expected -> assert_at(Window.next_allowed(from, limit, zone, constraints), expected)
      end
    end
  end
end
