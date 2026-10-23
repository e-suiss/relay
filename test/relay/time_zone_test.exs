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

    property "C-57: every accepted canonical zone of the bundled tzdata release is its own name" do
      check all zone <-
                  member_of(
                    Enum.filter(Tzdata.canonical_zone_list(), &Relay.TimeZone.accepted?/1)
                  ) do
        assert Relay.TimeZone.new(zone) == {:ok, zone}
      end
    end

    test "TN-2: offsets, unknown names and non-strings are refused" do
      for zone <- ["+03:00", "UTC+3", "GMT+0300", "Europe/Nowhere", "europe/istanbul", "", nil, 3] do
        assert {:error, %Relay.Error{code: :invalid_time_zone}} = Relay.TimeZone.new(zone)
      end
    end
  end

  describe "TN-65 (6) offset zones and links" do
    test "TN-65: the Etc/GMT offset zones, rule zones and the placeholder zone are refused" do
      offsets = Enum.filter(Tzdata.canonical_zone_list(), &String.starts_with?(&1, "Etc/GMT"))
      assert "Etc/GMT+3" in offsets and "Etc/GMT-14" in offsets

      for zone <- offsets ++ ["Etc/GMT0", "GMT", "Etc/Greenwich", "Factory", "EST5EDT"] do
        assert {:error, %Relay.Error{code: :invalid_time_zone}} = Relay.TimeZone.new(zone)
      end
    end

    test "TN-65: a link name becomes the name of the zone it links to" do
      assert Relay.TimeZone.new("Turkey") == {:ok, "Europe/Istanbul"}
      assert Relay.TimeZone.new("Asia/Istanbul") == {:ok, "Europe/Istanbul"}
      assert Relay.TimeZone.new("Europe/Kiev") == {:ok, "Europe/Kyiv"}
      assert Relay.TimeZone.new("US/Eastern") == {:ok, "America/New_York"}
      assert Relay.TimeZone.new("UTC") == {:ok, "Etc/UTC"}
    end

    property "TN-65: every link resolves to its accepted target or is refused with it" do
      check all {link, target} <- member_of(Map.to_list(Tzdata.links())) do
        if Relay.TimeZone.accepted?(target),
          do: assert(Relay.TimeZone.new(link) == {:ok, target}),
          else: assert({:error, _} = Relay.TimeZone.new(link))
      end
    end
  end
end
