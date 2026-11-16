defmodule Relay.Webhooks.ReleaseWorker do
  @moduledoc """
  The job that releases held messages of an endpoint (WH-31, WH-33 (2), WH-35 (2)): after a resume, when the circuit breaker's open time ends and when the breaker closes. One run releases a bounded batch spread over time by the endpoint's rate and queues the next run while messages remain (`Relay.Webhooks.Fanout.release/3`). Its arguments carry identifiers only (T-15).
  """

  use Relay.Worker, queue: :l2, max_attempts: 5, timeout: 60_000

  @batch 100

  # T-15
  # WH-31
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"endpoint_id" => endpoint_id, "hold_reason" => reason} = args}) do
    with {:ok, scope} <- Relay.Scope.from_job_args(args),
         {:ok, id} <- Relay.Id.parse(endpoint_id),
         {:ok, _count} <- Relay.Webhooks.release_held(scope, id, reason, @batch) do
      :ok
    end
  end
end
