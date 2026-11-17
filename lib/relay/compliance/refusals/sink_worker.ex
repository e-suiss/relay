defmodule Relay.Compliance.Refusals.SinkWorker do
  @moduledoc """
  The job that hands an applied refusal notice to the refusal sink (PC-38). It is queued by the transaction that applied the notice and runs outside it, so the registry is never written inside a transaction; a sink error is retried. Its arguments carry identifiers only (T-15).
  """

  use Relay.Worker, queue: :l1, max_attempts: 20, timeout: 60_000

  alias Relay.Compliance.Refusals

  # PC-38
  # T-15
  @doc "The job of an applied refusal."
  @spec job(Relay.Scope.t(), Relay.Id.t()) :: Ecto.Changeset.t()
  def job(%Relay.Scope{} = scope, <<_::128>> = refusal_id) do
    scope
    |> Relay.Scope.to_job_args()
    |> Map.put("refusal_id", Relay.Id.to_string(refusal_id))
    |> new()
  end

  # PC-38
  # T-15
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"refusal_id" => refusal_id} = args}) do
    case {Relay.Scope.from_job_args(args), Relay.Id.parse(refusal_id)} do
      {{:ok, scope}, {:ok, id}} -> Refusals.forward(scope, id)
      _invalid -> {:cancel, :invalid_args}
    end
  end
end
