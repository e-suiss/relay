defmodule Relay.Iys.UploadWorker do
  @moduledoc """
  The job of one İYS upload (PC-30): one attempt of `Relay.Iys.run_upload/2`. It is queued with its upload row in one transaction, refusals ahead of approvals, and its arguments carry the scope and the upload identifier only (T-15). An upload that has to wait, for an earlier movement of the same recipient, a limit or an unavailable İYS, makes the job come back; the sweep queues it again if it is lost.
  """

  use Relay.Worker, queue: :l1, max_attempts: 20, timeout: 120_000

  # T-15
  # PC-30
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"upload_id" => upload_id} = args}) do
    with {:ok, scope} <- Relay.Scope.from_job_args(args),
         {:ok, id} <- Relay.Id.parse(upload_id) do
      case Relay.Iys.run_upload(scope, id) do
        :done -> :ok
        {:snooze, seconds} -> {:snooze, seconds}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, _invalid} -> {:cancel, :invalid_args}
    end
  end
end
