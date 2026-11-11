defmodule Relay.Workflow.Steps.Unavailable do
  @moduledoc """
  The step types the runner does not execute yet: `digest`, `throttle`, `wait_for_event` and `webhook` (WF-8). The publication gate accepts their shapes; at run time each records `skipped` with `workflow_run.step_unavailable` as its outcome and the run goes on with the next step, so nothing is skipped silently. Each type's module replaces this one in `Relay.Workflow.Step.module/1` when it is built.
  """

  @behaviour Relay.Workflow.Step

  # WF-8
  @impl Relay.Workflow.Step
  def run(_step, _context, _now),
    do: {:continue, %{"outcome" => "skipped", "rule_id" => "workflow_run.step_unavailable"}}
end
