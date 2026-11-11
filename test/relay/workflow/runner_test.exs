defmodule Relay.Workflow.RunnerTest do
  use ExUnit.Case, async: true

  alias Relay.Workflow.Definition
  alias Relay.Workflow.Runner

  @now ~U[2026-11-11 10:00:00Z]

  defp context(steps, overrides \\ %{}) do
    Map.merge(
      %{
        data: %{"order" => "A-1", "at" => "2026-11-12T08:00:00Z"},
        recipient: %{},
        time_zone: "Europe/Istanbul",
        event_time: @now,
        run_started_at: @now,
        message_class: "transactional",
        outcomes: fn _results -> %{} end,
        projection: fn _ids -> %{} end,
        routes: routes(steps),
        facts: fn _step -> %{} end,
        effects: %{
          digest: fn _step -> {:ok, %{role: :anchor, window_id: Relay.Id.generate()}} end,
          throttle: fn _step -> {:ok, %{outcome: :allowed, count: 1, rule_id: nil}} end
        }
      },
      overrides
    )
  end

  defp routes(steps) do
    for %{step: %{"type" => "channel"} = step} <- Definition.entries(%{"steps" => steps}),
        into: %{} do
      case step do
        %{"route" => tree} -> {step["key"], %{"tree" => tree}}
        %{"channel" => channel} -> {step["key"], %{"tree" => channel}}
      end
    end
  end

  defp opener do
    fn step, channel, pointer ->
      {:ok, ["dlv-" <> step["key"] <> pointer], [{step["key"], channel}]}
    end
  end

  defp mail(key),
    do: %{"type" => "channel", "key" => key, "channel" => "email", "template" => "w"}

  defp run(steps, overrides \\ %{}, now \\ @now),
    do:
      Runner.advance(%{"steps" => steps}, Runner.new(), context(steps, overrides), now, opener())

  describe "WF-59 (5) run engine" do
    test "WF-59: channel steps open their deliveries in order and the run completes" do
      assert {:ok, %{status: "completed", outcome: "completed", state: state, extras: opened}} =
               run([mail("a"), mail("b")])

      assert opened == [{"a", "email"}, {"b", "email"}]
      assert state["results"]["a"]["deliveries"] == ["dlv-a"]
      assert state["routes"]["a"]["status"] == "settled"
      assert state["cursor"] == []
    end

    test "WF-43: a delay waits as a cursor past the step and the run goes on when it wakes" do
      steps = [mail("a"), %{"type" => "delay", "key" => "wait", "duration" => "PT1H"}, mail("b")]

      assert {:ok, %{status: "waiting", wake_at: at, state: state, extras: [{"a", "email"}]}} =
               run(steps)

      assert at == ~U[2026-11-11 11:00:00Z]
      assert state["results"]["wait"]["outcome"] == "waited"

      assert {:ok, %{status: "waiting", extras: []}} =
               Runner.advance(%{"steps" => steps}, state, context(steps), @now, opener())

      assert {:ok, %{status: "completed", extras: [{"b", "email"}]}} =
               Runner.advance(%{"steps" => steps}, state, context(steps), at, opener())
    end

    test "WF-41: a delay until a time of the event data waits for that time and a missing one stops" do
      until = %{"type" => "delay", "key" => "wait", "until" => "/at"}

      assert {:ok, %{status: "waiting", wake_at: ~U[2026-11-12 08:00:00Z]}} =
               run([until, mail("b")])

      missing = %{until | "until" => "/nope"}

      assert {:ok, %{outcome: "stopped", rule_id: "workflow_run.delay_until_missing"}} =
               run([missing, mail("b")])

      far = %{data: %{"at" => "2027-06-01T00:00:00Z"}}

      assert {:ok, %{outcome: "stopped", rule_id: "workflow_run.delay_out_of_range"}} =
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

      assert {:ok, %{status: "completed", state: state, extras: opened}} =
               run([check, mail("after")])

      assert opened == [{"a1", "email"}, {"after", "email"}]
      assert state["results"]["check"]["branch"] == 1

      no_match = %{check | "branches" => [hd(check["branches"])]}
      assert {:ok, %{extras: [{"other", "email"}, _after]}} = run([no_match, mail("after")])

      bare = Map.delete(no_match, "else")
      assert {:ok, %{state: state, extras: [{"after", "email"}]}} = run([bare, mail("after")])
      assert state["results"]["check"]["outcome"] == "no_match"
    end

    test "WF-60: a condition reads earlier step results from the delivery projection" do
      check = %{
        "type" => "condition",
        "key" => "check",
        "branches" => [
          %{
            "when" => %{"eq" => [%{"var" => "steps.a.seen"}, false]},
            "steps" => [mail("again")]
          }
        ]
      }

      seen = %{outcomes: fn _results -> %{"a" => %{"seen" => true}} end}
      assert {:ok, %{extras: [{"a", "email"}]}} = run([mail("a"), check], seen)

      unseen = %{outcomes: fn _results -> %{"a" => %{"seen" => false}} end}

      assert {:ok, %{extras: [{"a", "email"}, {"again", "email"}]}} =
               run([mail("a"), check], unseen)
    end

    test "WF-45: a time window waits for its next opening in the recipient's zone" do
      office = %{
        "type" => "time_window",
        "key" => "office",
        "windows" => [%{"days" => ~w(mon tue wed thu fri), "start" => "09:00", "end" => "18:00"}]
      }

      assert {:ok, %{status: "completed", extras: [{"b", "email"}]}} = run([office, mail("b")])

      assert {:ok, %{status: "waiting", wake_at: ~U[2026-11-16 06:00:00Z]}} =
               run([office, mail("b")], %{}, ~U[2026-11-13 16:00:00Z])
    end

    test "WF-8: a step type that is not executable yet is recorded with its rule and the run goes on" do
      wait = %{
        "type" => "wait_for_event",
        "key" => "reply",
        "event_type" => "ticket.replied",
        "correlation_key" => "k",
        "timeout" => "P1D"
      }

      assert {:ok, %{status: "completed", state: state, extras: [{"b", "email"}]}} =
               run([wait, mail("b")])

      assert %{"outcome" => "skipped", "rule_id" => "workflow_run.step_unavailable"} =
               state["results"]["reply"]
    end

    test "WF-32: a throttled event ends the run skipped with throttle.limited" do
      throttle = %{
        "type" => "throttle",
        "key" => "t",
        "throttle_key" => "k",
        "limit" => 1,
        "window" => "PT1H"
      }

      assert {:ok, %{status: "completed", extras: [{"b", "email"}]}} = run([throttle, mail("b")])

      limited = %{
        effects: %{
          digest: fn _step -> {:error, :unused} end,
          throttle: fn _step -> {:ok, %{outcome: :limited, rule_id: "throttle.limited"}} end
        }
      }

      assert {:ok, %{outcome: "stopped", rule_id: "throttle.limited", state: state, extras: []}} =
               run([throttle, mail("b")], limited)

      assert state["results"]["t"]["throttled"] == true
    end

    test "WF-27: a digest anchor parks the run, a folded item ends it and a lone first event goes on" do
      digest = %{
        "type" => "digest",
        "key" => "batch",
        "digest_key" => "{{data.order}}",
        "mode" => "fixed",
        "max_wait" => "PT1H"
      }

      reminder = Map.put(mail("b"), "digest_template", "w-digest")
      steps = [digest, reminder]

      assert {:ok, %{status: "running", state: parked, extras: []}} = run(steps)
      assert parked["parked"] == "batch"

      resumed = Runner.unpark(parked, "digest", %{"total_activities" => 3})

      assert {:ok, %{status: "completed", state: state, extras: [{"b", "email"}]}} =
               Runner.advance(%{"steps" => steps}, resumed, context(steps), @now, opener())

      assert state["results"]["b"]["digest"] == true
      assert state["results"]["batch"]["render"] == %{"total_activities" => 3}

      folded = fn role ->
        %{
          effects: %{
            digest: fn _ -> {:ok, %{role: role, window_id: Relay.Id.generate()}} end,
            throttle: nil
          }
        }
      end

      assert {:ok, %{status: "completed", outcome: "completed", extras: []}} =
               run(steps, folded.(:folded))

      assert {:ok, %{status: "completed", extras: [{"b", "email"}]}} =
               run(steps, folded.(:sent_alone))
    end

    test "WF-13 WF-15: a fallback route opens its next leaf when the first one fails" do
      tree = %{"single" => ["sms", "email"]}
      step = %{"type" => "channel", "key" => "r", "route" => tree, "template" => "w"}

      assert {:ok, %{status: "running", state: state, extras: [{"r", "sms"}]}} = run([step])
      assert state["routes"]["r"]["leaves"]["/single/0"]["deliveries"] == ["dlv-r/single/0"]

      failed = %{projection: fn _ids -> %{"dlv-r/single/0" => %{"status" => "failed"}} end}
      ctx = context([step], failed)

      assert {:ok, %{status: "completed", state: state, extras: [{"r", "email"}]}} =
               Runner.advance(%{"steps" => [step]}, state, ctx, @now, opener())

      assert state["results"]["r"]["deliveries"] |> Enum.sort() ==
               ["dlv-r/single/0", "dlv-r/single/1"]
    end

    test "WF-14: a route that does not resolve is recorded with its rule" do
      step = %{"type" => "channel", "key" => "r", "route" => "missing", "template" => "w"}
      skip = %{routes: %{"r" => %{"skip" => "route.not_found"}}}

      assert {:ok, %{status: "completed", state: state, extras: []}} = run([step], skip)
      assert state["results"]["r"]["rule_id"] == "route.not_found"
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
