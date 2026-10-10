defmodule Relay.TimeZoneTest do
  use ExUnit.Case, async: true

  import Relay.Golden

  @instants [
    ~U[2026-03-29 00:30:00Z],
    ~U[2026-03-29 01:30:00Z],
    ~U[2026-10-25 00:30:00Z],
    ~U[2026-11-01 06:30:00Z]
  ]
  @zones ["Europe/Istanbul", "Europe/Berlin", "America/New_York", "Asia/Tehran"]

  describe "TP-43 WF-47 pinned time zone data" do
    test "TP-43: the bundled tzdata release and its conversions match the golden file" do
      lines =
        for instant <- @instants, zone <- @zones do
          {:ok, local} = DateTime.shift_zone(instant, zone)

          "#{DateTime.to_iso8601(instant)} #{zone} #{DateTime.to_iso8601(local)} #{local.zone_abbr}\n"
        end

      assert_golden("tzdata.txt", ["tzdata #{Tzdata.tzdata_version()}\n" | lines])
    end
  end
end
