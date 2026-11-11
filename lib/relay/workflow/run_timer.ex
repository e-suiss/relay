defmodule Relay.Workflow.RunTimer do
  @moduledoc """
  The one timer job of a waiting workflow run (WF-43, WF-59 (5)). It runs on the `l1` queue, scheduled for the run's wake time, and advances the run with `Relay.Workflow.wake/2`: the run goes on from its cursor in one transaction, opens the deliveries of the steps it reaches and, when it waits again, queues its next timer in the same transaction. It never waits itself and carries only identifiers (T-15).
  """

  use Relay.Worker, queue: :l1, priority: 2, max_attempts: 10, timeout: 60_000

  # WF-43
  # T-15
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => run_id} = args}) do
    with {:ok, scope} <- Relay.Scope.from_job_args(args),
         {:ok, id} <- Relay.Id.parse(run_id),
         {:ok, _result} <- Relay.Workflow.wake(scope, id) do
      :ok
    end
  end
end
