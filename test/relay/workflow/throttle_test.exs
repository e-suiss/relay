defmodule Relay.Workflow.ThrottleTest do
  use Relay.DataCase, async: true

  alias Relay.Workflow.ContentDedup
  alias Relay.Workflow.Throttle.Window
  alias RelayTest.TenantFixture

  @step %{"key" => "billing:{{recipient.id}}", "limit" => 2, "window" => "PT1H"}
  @calendar %{"key" => "daily", "limit" => 1, "calendar" => "day"}

  defp hit(scope, step, key, ref, extra \\ %{}) do
    attrs = Map.merge(%{key: key, ref: ref}, extra)
    Relay.Workflow.throttle_now(scope, step, attrs)
  end

  defp scope, do: TenantFixture.tenant!().live

  describe "WF-32 WF-37 throttle step fields" do
    test "WF-32: the step fields are checked and exactly one window is given" do
      assert {:ok, %{limit: 2, window: {:window, 3_600_000}}} = Window.config(@step)
      assert {:ok, %{window: {:calendar, :day}}} = Window.config(@calendar)

      until = %{"key" => "k", "limit" => 1, "until" => "/data/ends_at"}
      assert {:ok, %{window: {:until, "/data/ends_at"}}} = Window.config(until)

      both = Map.put(@step, "calendar", "week")
      assert {:error, [%{pointer: "/window"}]} = Window.config(both)

      assert {:error, [%{pointer: "/limit", code: "out_of_range"}]} =
               Window.config(%{@step | "limit" => 10_001})

      assert {:error, [%{pointer: "/key"}]} = Window.config(%{@step | "key" => ""})
    end

    test "WF-37: a throttle window is at most 31 days" do
      assert {:error, [%{pointer: "/window", code: "out_of_range"}]} =
               Window.config(%{@step | "window" => "P32D"})

      now = ~U[2026-11-02 10:00:00Z]
      {:ok, until} = Window.config(%{"key" => "k", "limit" => 1, "until" => "/x"})
      far = DateTime.add(now, 32, :day)

      assert {:error, :out_of_range} = Window.bounds(until, now, nil, far)
      assert :passed = Window.bounds(until, now, nil, DateTime.add(now, -1, :second))
      assert {:until, ^far} = Window.bounds(until, DateTime.add(now, 2, :day), nil, far)
    end

    test "WF-32: a calendar window is the recipient's local day or ISO week" do
      {:ok, day} = Window.config(@calendar)
      {:ok, week} = Window.config(%{@calendar | "calendar" => "week"})
      now = ~U[2026-11-04 22:30:00Z]

      assert {:span, ~U[2026-11-04 21:00:00Z], ~U[2026-11-05 21:00:00Z]} =
               Window.bounds(day, now, "Europe/Istanbul")

      assert {:span, ~U[2026-11-01 21:00:00Z], ~U[2026-11-08 21:00:00Z]} =
               Window.bounds(week, now, "Europe/Istanbul")

      assert {:error, :time_zone_required} = Window.bounds(day, now, nil)
    end
  end

  describe "WF-32 WF-33 counters" do
    test "WF-32: over the limit an event is limited with the throttle rule and a retry answers the same" do
      scope = scope()

      assert {:ok, %{outcome: :allowed, rule_id: nil, count: 1}} = hit(scope, @step, "u1", "n1")
      assert {:ok, %{outcome: :allowed, count: 2}} = hit(scope, @step, "u1", "n2")
      assert {:ok, %{outcome: :limited, rule_id: "throttle.limited"}} =
               hit(scope, @step, "u1", "n3")

      assert {:ok, %{outcome: :limited, repeated: true}} = hit(scope, @step, "u1", "n3")
      assert {:ok, %{outcome: :allowed, count: 1}} = hit(scope, @step, "u2", "n3")
    end

    test "WF-32: workflows that use the same key throttle together, and only within their tenant" do
      scope = scope()
      other = %{@step | "limit" => 3}

      assert {:ok, %{outcome: :allowed}} = hit(scope, @step, "shared", "wf-a:1")
      assert {:ok, %{outcome: :allowed}} = hit(scope, @step, "shared", "wf-a:2")
      assert {:ok, %{outcome: :allowed, count: 3}} = hit(scope, other, "shared", "wf-b:1")
      assert {:ok, %{outcome: :limited}} = hit(scope, other, "shared", "wf-b:2")
      assert {:ok, %{outcome: :allowed, count: 1}} = hit(scope(), @step, "shared", "wf-a:1")
    end

    test "WF-32: an until already past allows the event without counting it" do
      scope = scope()
      step = %{"key" => "k", "limit" => 1, "until" => "/data/ends_at"}
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      assert {:ok, %{outcome: :allowed, count: nil}} = hit(scope, step, "k", "n1", %{until: past})
      assert {:ok, %{outcome: :allowed, count: nil}} = hit(scope, step, "k", "n2")
    end

    test "WF-32, API-69: an active key is reset and counts again from zero" do
      scope = scope()
      actor = TenantFixture.actor()

      reset = fn key ->
        {:ok, result} =
          Relay.Repo.in_scope(scope, fn _status ->
            Relay.Workflow.reset_throttle(scope, key, actor)
          end)

        result
      end

      {:ok, _} = hit(scope, @step, "reset-me", "n1")
      {:ok, _} = hit(scope, @step, "reset-me", "n2")
      assert {:ok, %{outcome: :limited}} = hit(scope, @step, "reset-me", "n3")

      assert {:ok, {:reset, _counter}} = reset.("reset-me")
      assert {:ok, %{outcome: :allowed, count: 1}} = hit(scope, @step, "reset-me", "n4")
      assert {:ok, {:not_active, nil}} = reset.("none")
    end
  end

  describe "WF-35 WF-36 content deduplication window" do
    test "WF-35: content deduplication is off by default and PT5M for operational" do
      assert ContentDedup.window_ms("operational", nil) == 300_000
      assert ContentDedup.window_ms("social", nil) == nil
      assert ContentDedup.window_ms("transactional", nil) == nil
      assert ContentDedup.window_ms("social", %{"window" => "PT10M"}) == 600_000
      assert ContentDedup.window_ms("operational", %{"window" => "PT2M"}) == 120_000
      assert ContentDedup.window_ms("social", %{"window" => "PT30S"}) == nil
      assert ContentDedup.window_ms("operational", %{"window" => "P2D"}) == 300_000
      assert ContentDedup.rule_id() == "content_dedup.same_content"
    end

    test "WF-36, E-11: the security class is never deduplicated by content" do
      assert ContentDedup.window_ms("security", nil) == nil
      assert ContentDedup.window_ms("security", %{"window" => "PT10M"}) == nil
    end

    test "WF-35: the content_dedup field of a definition is checked" do
      assert ContentDedup.errors(nil, "/definition/content_dedup") == []
      assert ContentDedup.errors(%{"window" => "PT1M"}, "/c") == []
      assert [%{pointer: "/c/window"}] = ContentDedup.errors(%{"window" => "PT25H"}, "/c")
      assert [%{pointer: "/c"}] = ContentDedup.errors(%{"window" => "PT1M", "x" => 1}, "/c")
    end
  end
end
