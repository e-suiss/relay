defmodule Relay.Webhooks.RecoveryWorker do
  @moduledoc """
  The job of one batch of a recovery operation on an endpoint (WH-31, WH-33 (2)): a recover, a filtered bulk retry, a replay of kept events or a cancellation of scheduled retries. A request only starts the operation; the selected messages are taken here, a bounded batch for each run, and the run queues the next one in its own transaction while the selection has more (`Relay.Webhooks.Recovery.advance/1`). It runs in the `l2` lane behind the tenant wait table, so a large recovery shares the lane fairly and does not hold back live traffic. Its arguments carry the scope, the endpoint identifier, the operation with its filters and the identifier the previous batch stopped at; never a payload or an address (T-15).
  """

  use Relay.Worker, queue: :l2, max_attempts: 5, timeout: 120_000

  # T-15
  # WH-31
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"operation" => _operation, "endpoint_id" => _id} = args}) do
    with {:ok, scope} <- Relay.Scope.from_job_args(args),
         {:ok, _count} <- Relay.Webhooks.recovery_advance(scope, args) do
      :ok
    end
  end
end
