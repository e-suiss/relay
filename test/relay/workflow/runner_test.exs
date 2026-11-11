defmodule Relay.Workflow.RunnerTest do
  use ExUnit.Case, async: true

  alias Relay.Workflow.Runner

  @now ~U[2026-11-11 10:00:00Z]

  defp context(overrides \\ %{}) do
    Map.merge(
      %{
        data: %{"order" => "A-1", "at" => "2026-11-12T08:00:00Z"},
        recipient: %{},
        time_zone: "Europe/Istanbul",
        event_time: @now,
        run_started_at: @now,
        message_class: "transactional",
        outcomes: fn _results -> %{} end
      },
      overrides
    )
  end

  defp opener do
    fn step, channel -> {:ok, ["dlv-" <> step["key"]], [{step["key"], channel}]} end
  end

  defp mail(key),
    do: %{"type" => "channel", "key" => key, "channel" => "email", "template" => "w"}

  defp run(steps, ctx \\ context(), now \\ @now),
    do: Runner.advance(%{"steps" => steps}, Runner.new(), ctx, now, opener())

  describe "WF-59 (5) run engine" do
    test "WF-59: channel steps open their deliveries in order and the run completes" do
      assert {:ok, {:completed, "completed", nil, state, opened}} = run([mail("a"), mail("b")])
      assert opened == [{"a", "email"}, {"b", "email"}]
      assert state["results"]["a"]["deliveries"] == ["dlv-a"]
      assert state["cursor"] == []
    end

    test "WF-43: a delay waits as a cursor past the step and the run goes on when it wakes" do
      steps = [mail("a"), %{"type" => "delay", "key" => "wait", "duration" => "PT1H"}, mail("b")]

      assert {:ok, {:waiting, at, state, [{"a", "email"}]}} = run(steps)
      assert at == ~U[2026-11-11 11:00:00Z]
      assert state["results"]["wait"]["outcome"] == "waited"

      assert {:ok, {:completed, "completed", nil, _state, [{"b", "email"}]}} =
               Runner.advance(%{"steps" => steps}, state, context(), at, opener())
    end

    test "WF-41: a delay until a time of the event data waits for that time and a missing one stops" do
      until = %{"type" => "delay", "key" => "wait", "until" => "/at"}
      assert {:ok, {:waiting, ~U[2026-11-12 08:00:00Z], _state, []}} = run([until, mail("b")])

      missing = %{until | "until" => "/nope"}

      assert {:ok, {:completed, "stopped", "workflow_run.delay_until_missing", _state, []}} =
               run([missing, mail("b")])

      far = context(%{data: %{"at" => "2027-06-01T00:00:00Z"}})

      assert {:ok, {:completed, "stopped", "workflow_run.delay_out_of_range", _, []}} =
               run([until, mail("b")], far)
    end

    test "WF-10: a condition enters its first matching branch and the flow joins after it" do
      check = %{
        "type" => "condition",
        "key" => "check",
        "branches" => [
          %{"when" => %{"eq" => [%{"var" => "data.order"}, "B-2"]}, "steps" => [mail("b2")]},
          %{"when" => %{"eq" => [%{"var" => "data.order"}, "A-1"]}, "steps" => [mail("a1")]}
        ],
        "else" => [mail("other")]
      }

      assert {:ok, {:completed, _, _, state, opened}} = run([check, mail("after")])
      assert opened == [{"a1", "email"}, {"after", "email"}]
      assert state["results"]["check"]["branch"] == 1

      no_match = %{check | "branches" => [hd(check["branches"])]}

      assert {:ok, {:completed, _, _, _, [{"other", "email"}, _after]}} =
               run([no_match, mail("after")])

      bare = Map.delete(no_match, "else")
      assert {:ok, {:completed, _, _, state, [{"after", "email"}]}} = run([bare, mail("after")])
      assert state["results"]["check"]["outcome"] == "no_match"
    end

    test "WF-60: a condition reads earlier step results from the delivery projection" do
      seen = fn _results -> %{"a" => %{"seen" => true}} end

      check = %{
        "type" => "condition",
        "key" => "check",
        "branches" => [
          %{"when" => %{"eq" => [%{"var" => "steps.a.seen"}, false]}, "steps" => [mail("again")]}
        ]
      }

      assert {:ok, {:completed, _, _, _, [{"a", "email"}]}} =
               run([mail("a"), check], context(%{outcomes: seen}))

      unseen = fn _results -> %{"a" => %{"seen" => false}} end

      assert {:ok, {:completed, _, _, _, [{"a", "email"}, {"again", "email"}]}} =
               run([mail("a"), check], context(%{outcomes: unseen}))
    end

    test "WF-45: a time window waits for its next opening in the recipient's zone" do
      office = %{
        "type" => "time_window",
        "key" => "office",
        "windows" => [%{"days" => ~w(mon tue wed thu fri), "start" => "09:00", "end" => "18:00"}]
      }

      assert {:ok, {:completed, _, _, _, [{"b", "email"}]}} = run([office, mail("b")])

      evening = ~U[2026-11-13 16:00:00Z]

      assert {:ok, {:waiting, ~U[2026-11-16 06:00:00Z], _state, []}} =
               run([office, mail("b")], context(), evening)
    end

    test "WF-8: a step type that is not executable yet is recorded with its rule and the run goes on" do
      throttle = %{
        "type" => "throttle",
        "key" => "t",
        "throttle_key" => "k",
        "limit" => 1,
        "window" => "PT1H"
      }

      assert {:ok, {:completed, _, _, state, [{"b", "email"}]}} = run([throttle, mail("b")])

      assert %{"outcome" => "skipped", "rule_id" => "workflow_run.step_unavailable"} =
               state["results"]["t"]
    end

    test "WF-13: the route seam opens a plain channel leaf and records any other route" do
      leaf = %{
        "type" => "channel",
        "key" => "r",
        "route" => %{"single" => ["sms"]},
        "template" => "w"
      }

      tree = %{leaf | "key" => "t", "route" => %{"single" => ["sms", "email"]}}

      assert {:ok, {:completed, _, _, state, [{"r", "sms"}]}} = run([leaf, tree])
      assert state["results"]["t"]["rule_id"] == "workflow_run.route_unavailable"
    end

    test "WF-22: the condition view of a step counts human clicks and the projection" do
      results = %{"a" => %{"deliveries" => ["x", "y"]}, "s" => %{"outcome" => "skipped"}}

      deliveries = %{
        "x" => %{"status" => "delivered", "seen" => true, "read" => false, "clicked" => false},
        "y" => %{"status" => "failed", "seen" => false, "read" => false, "clicked" => true}
      }

      view = Runner.outcomes(results, deliveries)

      assert %{"delivered" => true, "failed" => true, "seen" => true, "clicked" => true} =
               view["a"]

      assert %{"skipped" => true, "delivered" => false} = view["s"]
    end
  end
end
