defmodule Relay.TimeZoneTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

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

  describe "TN-2 C-57 IANA time zone identifiers" do
    test "TN-2: IANA zone identifiers are accepted" do
      for zone <- ["Europe/Istanbul", "America/New_York", "Asia/Tehran", "Etc/UTC"] do
        assert Relay.TimeZone.new(zone) == {:ok, zone}
      end
    end

    property "C-57: every zone of the bundled tzdata release is accepted" do
      check all zone <- member_of(Tzdata.zone_list()) do
        assert Relay.TimeZone.new(zone) == {:ok, zone}
      end
    end

    test "TN-2: offsets, unknown names and non-strings are refused" do
      for zone <- ["+03:00", "UTC+3", "GMT+0300", "Europe/Nowhere", "europe/istanbul", "", nil, 3] do
        assert {:error, %Relay.Error{code: :invalid_time_zone}} = Relay.TimeZone.new(zone)
      end
    end
  end
end
