defmodule Relay.Workflow.Steps.Channel do
  @moduledoc """
  The channel step (WF-8, WF-13): hands the step to the run's route evaluation (`{:route, result}`), which sends through the tree the notification's plan holds for it (its `channel`, its `route` or the category's default route, WF-14). A step with A/B variants (WF-50) is recorded as `skipped` with `workflow_run.step_unavailable` until variants are built, and the run goes on.
  """

  @behaviour Relay.Workflow.Step

  @unavailable "workflow_run.step_unavailable"

  # WF-13
  # WF-50
  @impl Relay.Workflow.Step
  def run(%{"variants" => [_ | _]}, _context, _now),
    do: {:continue, %{"outcome" => "skipped", "rule_id" => @unavailable}}

  def run(_step, _context, _now), do: {:route, %{"outcome" => "routed"}}
end
