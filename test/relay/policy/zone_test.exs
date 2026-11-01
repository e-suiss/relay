defmodule Relay.Policy.ZoneTest do
  use ExUnit.Case, async: true

  alias Relay.Policy.Zone

  describe "WF-45 PC-58 (4) time zone chain" do
    test "WF-45: the profile's zone comes first, then the device's, then the country's, then the tenant's" do
      assert Zone.resolve("America/New_York", "Europe/Berlin", ["Europe/Istanbul"], "UTC") ==
               {:ok, {"America/New_York", :profile}}

      assert Zone.resolve(nil, "Europe/Berlin", ["Europe/Istanbul"], "UTC") ==
               {:ok, {"Europe/Berlin", :device}}

      assert Zone.resolve(nil, nil, ["Europe/Istanbul"], "UTC") ==
               {:ok, {"Europe/Istanbul", :country}}

      assert Zone.resolve(nil, nil, nil, "Europe/Istanbul") ==
               {:ok, {"Europe/Istanbul", :tenant_default}}
    end

    test "PC-58 (4): the profile country counts only when it has a single zone" do
      us = ["America/New_York", "America/Chicago", "America/Los_Angeles"]

      assert Zone.resolve(nil, nil, us, "Europe/Istanbul") ==
               {:ok, {"Europe/Istanbul", :tenant_default}}

      assert Zone.resolve(nil, nil, [], "Europe/Istanbul") ==
               {:ok, {"Europe/Istanbul", :tenant_default}}

      assert Zone.resolve(nil, nil, ["Asia/Istanbul", "Europe/Istanbul"], "UTC") ==
               {:ok, {"Europe/Istanbul", :country}}
    end

    test "WF-45: a candidate that is not an accepted IANA zone is passed over" do
      assert Zone.resolve("Mars/Olympus", "+03:00", ["Etc/GMT-3"], "Turkey") ==
               {:ok, {"Europe/Istanbul", :tenant_default}}

      assert Zone.resolve(nil, nil, nil, "Mars/Olympus") == :error
      assert Zone.resolve(nil, nil, nil, nil) == :error
    end
  end

  describe "WF-47 local time" do
    test "WF-47: the wall clock and the offset follow tzdata across a transition" do
      assert Zone.local(~U[2026-03-29 00:59:00Z], "Europe/Berlin") == ~N[2026-03-29 01:59:00]
      assert Zone.local(~U[2026-03-29 01:00:00Z], "Europe/Berlin") == ~N[2026-03-29 03:00:00]
      assert Zone.offset(~U[2026-03-29 00:59:00Z], "Europe/Berlin") == 3_600
      assert Zone.offset(~U[2026-03-29 01:00:00Z], "Europe/Berlin") == 7_200
      assert Zone.offset(~U[2026-07-01 00:00:00Z], "Europe/Istanbul") == 10_800
      assert Zone.offset(~U[2026-01-01 00:00:00Z], "Europe/Istanbul") == 10_800
    end
  end
end
