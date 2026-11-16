defmodule Relay.Workflow.RRuleTest do
  use ExUnit.Case, async: true

  alias Relay.Workflow.RRule

  @vectors "test/vectors/rrule/v1.json" |> File.read!() |> Jason.decode!()

  defp rule!(text) do
    {:ok, rule} = RRule.parse(text)
    rule
  end

  defp utc(text) do
    {:ok, at, 0} = DateTime.from_iso8601(text)
    at
  end

  defp details(text) do
    {:error, errors} = RRule.parse(text)
    Enum.map(errors, & &1.detail)
  end

  defp shape(occurrences) do
    for o <- occurrences,
        do: %{"local" => NaiveDateTime.to_iso8601(o.local), "at" => DateTime.to_iso8601(o.at)}
  end

  describe "WF-61 subset" do
    test "WF-61: the supported parts parse into their canonical text" do
      for {text, canonical} <- [
            {"FREQ=DAILY", "FREQ=DAILY"},
            {"RRULE:freq=weekly;byday=we,mo;interval=2", "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE"},
            {"FREQ=MONTHLY;BYDAY=-1FR;BYHOUR=18;BYMINUTE=30;COUNT=12",
             "FREQ=MONTHLY;BYDAY=-1FR;BYHOUR=18;BYMINUTE=30;COUNT=12"},
            {"FREQ=MONTHLY;BYDAY=+2TU", "FREQ=MONTHLY;BYDAY=2TU"},
            {"FREQ=MONTHLY;BYMONTHDAY=-1;INTERVAL=1", "FREQ=MONTHLY;BYMONTHDAY=-1"},
            {"UNTIL=20271231T000000Z;FREQ=DAILY", "FREQ=DAILY;UNTIL=20271231T000000Z"},
            {"FREQ=DAILY;INTERVAL=99;COUNT=1000", "FREQ=DAILY;INTERVAL=99;COUNT=1000"}
          ] do
        assert RRule.to_string(rule!(text)) == canonical, text
      end
    end

    test "WF-61: every unsupported part is a field error that names the part" do
      for {text, part} <- [
            {"FREQ=HOURLY", "FREQ=HOURLY"},
            {"FREQ=YEARLY", "FREQ=YEARLY"},
            {"FREQ=MINUTELY", "FREQ=MINUTELY"},
            {"FREQ=SECONDLY", "FREQ=SECONDLY"},
            {"FREQ=MONTHLY;BYDAY=MO;BYSETPOS=1", "BYSETPOS"},
            {"FREQ=WEEKLY;BYWEEKNO=2", "BYWEEKNO"},
            {"FREQ=DAILY;BYYEARDAY=100", "BYYEARDAY"},
            {"FREQ=DAILY;BYSECOND=5", "BYSECOND"},
            {"FREQ=DAILY;BYHOUR=9,17", "BYHOUR"},
            {"FREQ=DAILY;BYMINUTE=0,30", "BYMINUTE"},
            {"FREQ=DAILY;EXDATE=20261111T090000Z", "EXDATE"},
            {"FREQ=DAILY;RDATE=20261111T090000Z", "RDATE"},
            {"FREQ=WEEKLY;WKST=SU", "WKST"},
            {"FREQ=DAILY;BYDAY=MO", "BYDAY"},
            {"FREQ=MONTHLY;BYDAY=MO", "BYDAY"},
            {"FREQ=MONTHLY;BYDAY=5MO", "BYDAY ordinal 5"},
            {"FREQ=MONTHLY;BYMONTHDAY=29", "BYMONTHDAY=29"},
            {"FREQ=MONTHLY;BYMONTHDAY=1,15", "BYMONTHDAY"},
            {"FREQ=WEEKLY;BYMONTHDAY=1", "BYMONTHDAY"}
          ] do
        assert Enum.any?(details(text), &String.contains?(&1, part)), "#{text}: #{part}"

        {:error, errors} = RRule.parse(text)
        assert Enum.all?(errors, &(&1.pointer == "/rrule")), text
      end
    end

    test "WF-61: malformed values, a missing FREQ and forbidden combinations are refused" do
      for text <- [
            "",
            "FREQ",
            "FREQ=DAILY;FREQ=WEEKLY",
            "INTERVAL=2",
            "FREQ=DAILY;INTERVAL=0",
            "FREQ=DAILY;INTERVAL=100",
            "FREQ=DAILY;COUNT=0",
            "FREQ=DAILY;COUNT=1001",
            "FREQ=DAILY;BYHOUR=24",
            "FREQ=DAILY;BYMINUTE=60",
            "FREQ=DAILY;UNTIL=20271231",
            "FREQ=DAILY;COUNT=2;UNTIL=20271231T000000Z",
            "FREQ=MONTHLY;BYDAY=1MO;BYMONTHDAY=1",
            "FREQ=WEEKLY;BYDAY=MO,MO",
            "FREQ=WEEKLY;BYDAY=1MO",
            String.duplicate("A", 513)
          ] do
        assert {:error, [_ | _]} = RRule.parse(text), text
      end

      assert {:error, _errors} = RRule.parse(nil)
    end

    test "WF-61: UNTIL lies at most five years ahead" do
      now = utc("2026-11-11T00:00:00Z")
      assert :ok = RRule.check_horizon(rule!("FREQ=DAILY;UNTIL=20311111T000000Z"), now, 5)
      assert :ok = RRule.check_horizon(rule!("FREQ=DAILY"), now, 5)

      assert {:error, [%{pointer: "/rrule", code: "not_allowed"}]} =
               RRule.check_horizon(rule!("FREQ=DAILY;UNTIL=20311111T000001Z"), now, 5)
    end
  end

  describe "WF-61 WF-47 golden vectors" do
    test "WF-47: the expansions across DST transitions in Europe/Berlin and America/New_York match the vectors" do
      assert @vectors["version"] == "relay.rrule.v1"
      assert length(@vectors["expansions"]) >= 10

      for v <- @vectors["expansions"] do
        dtstart = NaiveDateTime.from_iso8601!(v["dtstart"])
        found = RRule.occurrences(rule!(v["rrule"]), dtstart, v["zone"], v["limit"])
        assert shape(found) == v["expected"], v["id"]
      end
    end

    test "WF-61: the next occurrence after an instant matches the vectors" do
      for v <- @vectors["next"] do
        dtstart = NaiveDateTime.from_iso8601!(v["dtstart"])

        found =
          case RRule.next(rule!(v["rrule"]), dtstart, v["zone"], utc(v["after"])) do
            {:ok, occurrence} -> hd(shape([occurrence]))
            :none -> nil
          end

        assert found == v["expected"], v["id"]
      end
    end

    test "WF-61: COUNT numbers the occurrences from the first one" do
      rule = rule!("FREQ=WEEKLY;BYDAY=MO,FR;COUNT=5")
      dtstart = ~N[2026-11-11 09:00:00]
      all = RRule.occurrences(rule, dtstart, "Europe/Berlin", 10)

      assert Enum.map(all, & &1.ordinal) == [1, 2, 3, 4, 5]

      later = RRule.between(rule, dtstart, "Europe/Berlin", Enum.at(all, 1).at, nil, 10)
      assert Enum.map(later, & &1.ordinal) == [3, 4, 5]
      assert RRule.next(rule, dtstart, "Europe/Berlin", List.last(all).at) == :none
    end

    test "WF-61: an open rule far from its start skips ahead to the same occurrences" do
      rule = rule!("FREQ=DAILY;BYHOUR=7;BYMINUTE=45")
      dtstart = ~N[2022-01-01 07:45:00]
      from = utc("2026-11-11T12:00:00Z")

      assert [first, second] = RRule.between(rule, dtstart, "Europe/Berlin", from, nil, 2)
      assert DateTime.to_iso8601(first.at) == "2026-11-12T06:45:00Z"
      assert DateTime.to_iso8601(second.at) == "2026-11-13T06:45:00Z"
      assert first.ordinal == nil

      upto = utc("2026-11-12T23:00:00Z")
      assert [^first] = RRule.between(rule, dtstart, "Europe/Berlin", from, upto, 10)
    end
  end

  describe "WF-58 WF-42 recurrence jitter" do
    test "WF-58, L-43: occurrences due at the same minute spread over PT60S, the same way every time" do
      tenant = Relay.Id.generate()
      at = "2026-11-12T06:00:00Z"

      offsets =
        for _ <- 1..200,
            do: Relay.Jitter.recurrence(tenant, :live, Relay.Id.generate(), at, 60_000)

      assert Enum.all?(offsets, &(&1 >= 0 and &1 < 60_000))
      assert length(Enum.uniq(offsets)) > 150

      rule = Relay.Id.generate()

      assert Relay.Jitter.recurrence(tenant, :live, rule, at, 60_000) ==
               Relay.Jitter.recurrence(tenant, :live, rule, at, 60_000)

      assert Relay.Jitter.recurrence(tenant, :live, rule, at, 0) == 0
    end
  end
end
