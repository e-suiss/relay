defmodule Relay.Workflow.Steps.Unavailable do
  @moduledoc """
  The step type the runner does not execute yet: `webhook` (WF-8, WF-11), which needs the outbound event delivery engine and its tenant endpoints. The publication gate accepts its shape; at run time it records `skipped` with `workflow_run.step_unavailable` as its outcome and the run goes on with the next step, so nothing is skipped silently. The type's module replaces this one in `Relay.Workflow.Step.module/1` when it is built.
  """

  @behaviour Relay.Workflow.Step

  # WF-8
  @impl Relay.Workflow.Step
  def run(_step, _context, _now),
    do: {:continue, %{"outcome" => "skipped", "rule_id" => "workflow_run.step_unavailable"}}
end
