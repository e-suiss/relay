defmodule Relay.Iys.RefreshWorker do
  @moduledoc """
  The job that reads what İYS says about one scope's connection (PC-29, PC-34): the integrator's authorisations and the consent quota (`Relay.Iys.refresh/2`). The sweep queues one per configured scope at every refresh interval; its arguments carry the scope only (T-15).
  """

  use Relay.Worker, queue: :maintenance, max_attempts: 3, timeout: 300_000

  # T-15
  @doc "The job changeset of the refresh of `scope`."
  @spec job(Relay.Scope.t()) :: Ecto.Changeset.t()
  def job(%Relay.Scope{} = scope), do: scope |> Relay.Scope.to_job_args() |> new()

  # PC-29
  # PC-34
  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    with {:ok, scope} <- Relay.Scope.from_job_args(args),
         {:ok, _read} <- Relay.Iys.refresh(scope, Relay.Clock.utc_now()) do
      :ok
    end
  end
end
