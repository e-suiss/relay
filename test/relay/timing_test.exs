defmodule Relay.TimingTest do
  use ExUnit.Case, async: true

  alias Relay.Timing

  describe "WF-58 jitter control" do
    test "WF-58: without a setting the spreads are their ceilings and jittered" do
      assert Timing.default() == %{
               release_spread_ms: 900_000,
               scheduled_spread_ms: 60_000,
               precision: :jittered
             }

      assert Timing.from_stored(nil) == Timing.default()
      assert Timing.from_stored(%{"release_spread_ms" => 1}) == Timing.default()
    end

    test "WF-58: a tenant may only shrink the spreads" do
      shrunk = %{
        "release_spread_ms" => 60_000,
        "scheduled_spread_ms" => 0,
        "precision" => "jittered"
      }

      assert {:ok, ^shrunk} = Timing.cast(shrunk)

      assert {:error, ["release_spread_ms"]} =
               Timing.cast(%{shrunk | "release_spread_ms" => 900_001})

      assert {:error, ["scheduled_spread_ms", "precision"]} =
               Timing.cast(%{shrunk | "scheduled_spread_ms" => 60_001, "precision" => "exact"})

      assert Timing.from_stored(shrunk) == %{
               release_spread_ms: 60_000,
               scheduled_spread_ms: 0,
               precision: :jittered
             }

      assert Timing.to_stored(Timing.from_stored(shrunk)) == shrunk
    end

    test "WF-42 WF-58: strict on the tenant or on the send zeroes both spreads" do
      control = Timing.default()
      assert Timing.spread(control, :release, nil) == 900_000
      assert Timing.spread(control, :scheduled, :jittered) == 60_000
      assert Timing.spread(control, :release, :strict) == 0
      assert Timing.spread(%{control | precision: :strict}, :scheduled, nil) == 0
      assert Timing.precision("strict") == :strict
      assert Timing.precision(nil) == :jittered
    end

    test "WF-42: a scheduled delivery's offset is deterministic and within its spread" do
      tenant = Relay.Id.generate()
      delivery = Relay.Id.generate()
      at = "2026-11-20T09:00:00Z"
      offset = Relay.Jitter.scheduled(tenant, :live, delivery, at, 60_000)

      assert offset in 0..59_999
      assert Relay.Jitter.scheduled(tenant, :live, delivery, at, 60_000) == offset
      assert Relay.Jitter.scheduled(tenant, :live, delivery, at, 0) == 0
    end
  end
end
