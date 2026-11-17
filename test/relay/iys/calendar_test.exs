defmodule Relay.Iys.CalendarTest do
  use ExUnit.Case, async: true

  alias Relay.Iys.Calendar

  @package Path.expand("../../../priv/datasets/business_calendar/v1.json", __DIR__)

  defp packaged do
    {:ok, calendar} = @package |> File.read!() |> Jason.decode!() |> Calendar.parse("TR")
    calendar
  end

  defp tr(day, time) do
    {:ok, at} = DateTime.new(day, time, "Europe/Istanbul")
    DateTime.shift_zone!(at, "Etc/UTC")
  end

  defp local(%DateTime{} = at) do
    shifted = DateTime.shift_zone!(at, "Europe/Istanbul")
    {DateTime.to_date(shifted), DateTime.to_time(shifted)}
  end

  describe "PC-31 business days" do
    test "PC-31: the packaged calendar covers Turkey from 2026 to 2028 and names its sources" do
      content = @package |> File.read!() |> Jason.decode!()
      calendar = packaged()

      assert calendar.coverage_start == ~D[2026-01-01]
      assert calendar.coverage_end == ~D[2028-12-31]
      assert content["source_ref"] =~ "2429"
      assert content["source_ref"] =~ "diyanet.gov.tr"

      for year <- 2026..2028, {month, day} <- [{1, 1}, {4, 23}, {5, 1}, {5, 19}, {7, 15}] do
        assert MapSet.member?(calendar.holidays, Date.new!(year, month, day))
      end

      for year <- 2026..2028, {month, day} <- [{8, 30}, {10, 29}] do
        assert MapSet.member?(calendar.holidays, Date.new!(year, month, day))
      end

      for day <- [~D[2026-03-20], ~D[2026-05-30], ~D[2027-03-11], ~D[2027-05-16]] do
        assert MapSet.member?(calendar.holidays, day)
      end

      for day <- [~D[2028-02-26], ~D[2028-05-08]] do
        assert MapSet.member?(calendar.holidays, day)
      end
    end

    test "PC-31: a weekend and a full-day holiday are not business days; a half day is" do
      calendar = packaged()

      refute Calendar.business_day?(calendar, ~D[2026-11-21])
      refute Calendar.business_day?(calendar, ~D[2026-11-22])
      refute Calendar.business_day?(calendar, ~D[2026-10-29])
      assert Calendar.business_day?(calendar, ~D[2026-10-28])
      assert Calendar.business_day?(calendar, ~D[2026-03-19])
      assert Calendar.business_day?(calendar, ~D[2026-11-23])
    end

    test "PC-31: three business days are not 72 hours across a weekend" do
      calendar = packaged()
      consent_at = tr(~D[2026-11-19], ~T[10:00:00])

      assert {deadline, :covered} = Calendar.deadline(calendar, consent_at)
      assert local(deadline) == {~D[2026-11-24], ~T[10:00:00]}
      assert DateTime.diff(deadline, consent_at, :hour) == 120
    end

    test "PC-31: holidays are skipped and the eve of a holiday counts" do
      calendar = packaged()

      assert {deadline, :covered} = Calendar.deadline(calendar, tr(~D[2026-05-25], ~T[09:30:00]))
      assert local(deadline) == {~D[2026-06-02], ~T[09:30:00]}

      assert {deadline, :covered} = Calendar.deadline(calendar, tr(~D[2026-10-27], ~T[16:00:00]))
      assert local(deadline) == {~D[2026-11-02], ~T[16:00:00]}
    end

    test "PC-31: a consent given on a day off counts from the next business day" do
      calendar = packaged()

      assert {deadline, :covered} = Calendar.deadline(calendar, tr(~D[2026-11-21], ~T[23:15:00]))
      assert local(deadline) == {~D[2026-11-25], ~T[23:15:00]}
    end

    test "PC-31: beyond the coverage only weekends are left out and the result says so" do
      calendar = packaged()

      assert {deadline, :beyond_coverage} =
               Calendar.deadline(calendar, tr(~D[2028-12-28], ~T[12:00:00]))

      assert local(deadline) == {~D[2029-01-02], ~T[12:00:00]}

      assert {~D[2029-01-04], :beyond_coverage} =
               Calendar.add_business_days(calendar, ~D[2029-01-01], 3)
    end

    test "PC-31: the coverage warning starts sixty days before the end" do
      calendar = packaged()

      assert Calendar.coverage(calendar, ~D[2028-10-31]) == :ok
      assert Calendar.coverage(calendar, ~D[2028-11-01]) == {:ending, 60}
      assert Calendar.coverage(calendar, ~D[2028-12-31]) == {:ending, 0}
      assert Calendar.coverage(calendar, ~D[2029-01-01]) == :ended
    end

    test "PC-31: a calendar without the country or with a broken date is refused" do
      assert Calendar.parse(%{"countries" => %{}}, "TR") == {:error, :country_missing}
      assert Calendar.parse(%{}, "TR") == {:error, :invalid_calendar}

      broken = %{
        "countries" => %{
          "TR" => %{
            "coverage_start" => "2026-01-01",
            "coverage_end" => "2026-12-31",
            "holidays" => ["2026-13-01"],
            "half_days" => []
          }
        }
      }

      assert Calendar.parse(broken, "TR") == {:error, :invalid_calendar}
    end
  end

  describe "PC-30 İYS dates" do
    test "PC-30: a consent date is written and read in Turkey time" do
      at = ~U[2026-11-17 21:30:05Z]

      assert Calendar.format(at) == "2026-11-18 00:30:05"
      assert Calendar.parse_time("2026-11-18 00:30:05") == at
      assert Calendar.parse_time("2026-11-18T00:30:05Z") == nil
      assert Calendar.parse_time(nil) == nil
    end
  end
end
