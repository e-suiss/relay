defmodule Relay.Workflow.Steps.Webhook do
  @moduledoc """
  The webhook step (WF-8, WF-11): delivers the run's event, as the tenant event type the step names in `event_type`, to the event destination the step names in `endpoint`, through the run's `webhook` effect and so through the shared delivery engine (signing, retries, terminal states, the delivery log and its recovery). The destination is a registered one; the step never computes an address from event data (WH-43 (2)).

  The step does not wait for the delivery. It records `emitted` with the event's identifier, and a later condition reads the delivery result at the time it is evaluated: `delivered` once every message of the event is delivered, `failed` once one ended in another terminal state. The consumer's answer never enters the run (WF-11). An event that cannot be emitted (an unknown or archived destination or event type, data that does not fit the type's schema) records `skipped` with `workflow_run.step_unavailable` and its reason, and the run goes on.
  """

  @behaviour Relay.Workflow.Step

  @unavailable "workflow_run.step_unavailable"

  # WF-8
  # WF-11
  @impl Relay.Workflow.Step
  def run(step, context, _now) do
    case context.effects.webhook.(step) do
      {:ok, %{event_id: event_id}} ->
        {:continue, %{"outcome" => "emitted", "webhook_event_id" => event_id}}

      {:refused, reason} ->
        {:continue,
         %{"outcome" => "skipped", "rule_id" => @unavailable, "reason" => Atom.to_string(reason)}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
