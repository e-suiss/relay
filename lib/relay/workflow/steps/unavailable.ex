defmodule Relay.Workflow.Steps.Unavailable do
  @moduledoc """
  The step of a type that has no module in `Relay.Workflow.Step.module/1` (WF-8). Every type of the definition contract has one, so a published workflow never reaches it; a run that meets such a step records `skipped` with `workflow_run.step_unavailable` as its outcome and goes on with the next step, so nothing is skipped silently.
  """

  @behaviour Relay.Workflow.Step

  # WF-8
  @impl Relay.Workflow.Step
  def run(_step, _context, _now),
    do: {:continue, %{"outcome" => "skipped", "rule_id" => "workflow_run.step_unavailable"}}
end
