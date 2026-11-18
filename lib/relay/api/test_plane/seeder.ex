defmodule Relay.Api.TestPlane.Seeder do
  @moduledoc """
  The job that sets up a tenant's test plane (X-43, X-35): the sample workflow and the seven seed recipients (`Relay.Api.TestPlane.seed/1`). It is queued at tenant creation and by the "reset seeds" action and carries only the scope (T-15). A run that cannot finish is retried; running it again changes only what a manual change moved away from the seeds' definition.
  """

  use Relay.Worker, queue: :l1, priority: 5, max_attempts: 10, timeout: 120_000

  # X-43
  # T-15
  @doc "Queues the setup of the test plane of `scope` inside the caller's scoped transaction."
  @spec enqueue(Relay.Scope.t()) :: :ok | {:error, Relay.Error.t()}
  def enqueue(%Relay.Scope{environment: :test} = scope) do
    attrs = %{
      id: Relay.Id.generate(),
      lane: Relay.Platform.lane(:transactional),
      worker: __MODULE__,
      args: Relay.Scope.to_job_args(scope),
      ref_kind: "test_plane_seeds",
      ref_id: scope.tenant_id,
      priority: 5
    }

    case Relay.Platform.enqueue_job(attrs) do
      {:ok, _queued} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  # X-43
  # X-35
  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    case Relay.Scope.from_job_args(args) do
      {:ok, %Relay.Scope{environment: :test} = scope} -> seeded(Relay.Api.TestPlane.seed(scope))
      _other -> {:cancel, :invalid_args}
    end
  end

  defp seeded(:ok), do: :ok
  defp seeded({:error, reason}), do: {:error, reason}
end
