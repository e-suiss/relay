defmodule Relay.Workflow.PublishGate do
  @moduledoc """
  The publication gate job (WF-6): it reads a pending workflow version, runs the gate checks of `Relay.Workflow.Definition.gate/1` and publishes the version as the next immutable version number, or rejects it with its field errors. Its arguments carry identifiers only (T-15).
  """

  use Relay.Worker, queue: :maintenance, max_attempts: 10, timeout: 60_000

  alias Relay.Scope

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"version_id" => version_id} = args}) do
    with {:ok, scope} <- Scope.from_job_args(args),
         {:ok, id} <- Relay.Id.parse(version_id),
         {:ok, _result} <- Relay.Workflow.run_gate(scope, id) do
      :ok
    end
  end

  @doc "The gate job of a pending version."
  @spec job(Scope.t(), Relay.Id.t()) :: Ecto.Changeset.t()
  def job(%Scope{} = scope, version_id) do
    scope
    |> Scope.to_job_args()
    |> Map.put("version_id", Relay.Id.to_string(version_id))
    |> new()
  end
end
