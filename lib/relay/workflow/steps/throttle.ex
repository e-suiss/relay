defmodule Relay.Workflow.Steps.Throttle do
  @moduledoc """
  The throttle step (WF-32): counts the run's event against the tenant-wide counter of its rendered `throttle_key` through the run's throttle effect (`Relay.Workflow.Throttle.hit/3`). An allowed event goes on; an event over the limit ends the run as skipped with `throttle.limited`, and the step's `throttled` result is true for later conditions.
  """

  @behaviour Relay.Workflow.Step

  # WF-32
  @impl Relay.Workflow.Step
  def run(step, context, _now) do
    case context.effects.throttle.(step) do
      {:ok, %{outcome: :allowed} = hit} ->
        {:continue, %{"outcome" => "allowed", "count" => hit.count, "throttled" => false}}

      {:ok, %{outcome: :limited, rule_id: rule_id}} ->
        rule_id = rule_id || "throttle.limited"
        result = %{"outcome" => "skipped", "rule_id" => rule_id, "throttled" => true}
        {:stop, rule_id, result}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
