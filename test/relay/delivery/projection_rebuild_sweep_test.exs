defmodule Relay.Delivery.ProjectionRebuildSweepTest do
  use ExUnit.Case, async: true

  alias Relay.Delivery.ProjectionRebuild

  @now ~U[2026-10-23 12:00:00Z]

  defp scope(n, environment),
    do: %{tenant_id: Relay.Id.build(n, <<n::80>>), environment: environment}

  describe "OP-3 weekly sweep schedule" do
    test "OP-3: a sweep starts at once, runs on, and waits a week after it finished" do
      assert ProjectionRebuild.wait_ms(%{}, @now) == 0
      assert ProjectionRebuild.wait_ms(%{"sweep" => %{}}, @now) == 0

      finished = DateTime.add(@now, -2, :day) |> DateTime.to_iso8601()

      assert ProjectionRebuild.wait_ms(%{"finished_at" => finished}, @now) ==
               5 * 24 * 60 * 60_000

      long_ago = DateTime.add(@now, -8, :day) |> DateTime.to_iso8601()
      assert ProjectionRebuild.wait_ms(%{"finished_at" => long_ago}, @now) == 0
    end

    test "OP-3: the sweep walks tenant environments in order and resumes after a missing one" do
      scopes = [scope(1, "live"), scope(1, "test"), scope(3, "live")]
      [a, b, c] = scopes

      assert ProjectionRebuild.current(scopes, nil) == a
      assert ProjectionRebuild.next(scopes, a) == b
      assert ProjectionRebuild.next(scopes, b) == c
      assert ProjectionRebuild.next(scopes, c) == nil

      saved = %{
        "tenant_id" => Relay.Id.to_string(scope(2, "live").tenant_id),
        "environment" => "live"
      }

      assert ProjectionRebuild.current(scopes, saved) == c

      saved = %{"tenant_id" => Relay.Id.to_string(b.tenant_id), "environment" => "test"}
      assert ProjectionRebuild.current(scopes, saved) == b
    end
  end
end
