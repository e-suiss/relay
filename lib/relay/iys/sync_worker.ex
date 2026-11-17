defmodule Relay.Iys.SyncWorker do
  @moduledoc """
  The job that runs the İYS read path of one scope (PC-32, OP-42): the pull of consent movements, the verifications, the rejections that came from İYS and the reconciliation (`Relay.Iys.sync/2`). The synchronisation sweep queues one per configured scope; its arguments carry the scope only (T-15). A brand whose pull did not finish is tried again by the next job, so a failed pull does not fail the job.
  """

  use Relay.Worker, queue: :maintenance, max_attempts: 3, timeout: 600_000

  # T-15
  @doc "The job changeset of the synchronisation of `scope`."
  @spec job(Relay.Scope.t()) :: Ecto.Changeset.t()
  def job(%Relay.Scope{} = scope), do: scope |> Relay.Scope.to_job_args() |> new()

  # PC-32
  # OP-42
  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    with {:ok, scope} <- Relay.Scope.from_job_args(args),
         {:ok, _reports} <- Relay.Iys.sync(scope, Relay.Clock.utc_now()) do
      :ok
    end
  end
end
