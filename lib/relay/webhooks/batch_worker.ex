defmodule Relay.Webhooks.BatchWorker do
  @moduledoc """
  The job that writes one object store batch (WH-21). It is queued with the batch for the time the batch's age closes it, at once when the batch closes early, and by the sweep when a write crashed. It runs in the `l2` lane, behind the tenant wait table, and its arguments carry the scope and the batch identifier only (T-15). The write itself is `Relay.Webhooks.Batcher.write/3`: a batch that is not due yet or that another write holds makes the job come back later, and everything else ends the job, because the members that are tried again join another batch.
  """

  use Relay.Worker, queue: :l2, max_attempts: 5, timeout: 900_000

  # T-15
  # WH-21
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"batch_id" => batch_id} = args}) do
    with {:ok, scope} <- Relay.Scope.from_job_args(args),
         {:ok, id} <- Relay.Id.parse(batch_id) do
      case Relay.Webhooks.Batcher.write(scope, id) do
        {:ok, {:retry_in, seconds}} -> {:snooze, seconds}
        {:ok, _done} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
