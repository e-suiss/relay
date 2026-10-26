defmodule Relay.Agents.WaitpointTimer do
  @moduledoc """
  The one timer job of a waitpoint (T-24, AG-15, WF-43). It runs on the `l1` queue at priority 3, scheduled for the nearest of the waitpoint's deadline, heartbeat and escalation time; it evaluates them with `relay_fn.waitpoint_timer_fire`, reschedules itself in the same transaction when the waitpoint stays open, and ends. It never waits, so it finishes well within a second; it carries only identifiers (T-15).
  """

  use Relay.Worker, queue: :l1, priority: 3, max_attempts: 10, timeout: 1_000

  # T-24
  # WF-43
  # AG-4
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"waitpoint_id" => waitpoint_id} = args}) do
    with {:ok, scope} <- Relay.Scope.from_job_args(args),
         {:ok, id} <- Relay.Id.parse(waitpoint_id),
         {:ok, _result} <- Relay.Agents.Waitpoint.fire(scope, id) do
      :ok
    end
  end
end
