defmodule Relay.Webhooks.AttemptWorker do
  @moduledoc """
  The job of one delivery attempt of a message (WH-22, WH-32 (4), WH-38). It runs in the `l2` lane, behind the tenant wait table, so tenants share the lane fairly and no tenant has a queue of its own. Its arguments carry the scope and the message identifier only (T-15); `manual` marks a resend. The attempt itself is `Relay.Webhooks.Engine.attempt/3`: a message another attempt holds makes the job come back a little later, and everything else ends the job, because the next attempt of a message is always a new job.
  """

  use Relay.Worker, queue: :l2, max_attempts: 5, timeout: 90_000

  # T-15
  # WH-32 (4)
  @impl Oban.Worker
  def perform(%Oban.Job{id: job_id, args: %{"message_id" => message_id} = args}) do
    with {:ok, scope} <- Relay.Scope.from_job_args(args),
         {:ok, id} <- Relay.Id.parse(message_id) do
      opts = [manual: args["manual"] == true, holder: "oban:#{job_id}"]

      case Relay.Webhooks.Engine.attempt(scope, id, opts) do
        {:ok, {:retry_in, seconds}} -> {:snooze, seconds}
        {:ok, _done} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
