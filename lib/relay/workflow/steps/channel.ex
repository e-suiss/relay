defmodule Relay.Workflow.Steps.Channel do
  @moduledoc """
  The channel step (WF-8, WF-13): opens the step's deliveries on the channel its `channel` or `route` resolves to through `Relay.Workflow.Route.plan/1`. A route the seam cannot resolve yet, and a step with A/B variants (WF-50), are recorded as `skipped` with their rule and the run goes on.
  """

  @behaviour Relay.Workflow.Step

  @unavailable "workflow_run.step_unavailable"

  # WF-13
  # WF-50
  @impl Relay.Workflow.Step
  def run(%{"variants" => [_ | _]}, _context, _now),
    do: {:continue, %{"outcome" => "skipped", "rule_id" => @unavailable}}

  def run(step, _context, _now) do
    case Relay.Workflow.Route.plan(step) do
      {:channel, channel} ->
        {:open, channel, %{"outcome" => "opened", "channel" => channel}}

      {:unavailable, rule_id} ->
        {:continue, %{"outcome" => "skipped", "rule_id" => rule_id}}
    end
  end
end
