defmodule Relay.Agents.Ceiling.ApplyWorker do
  @moduledoc """
  The job that applies the owner's decision on the notifications held at an agent's ceiling (AG-49): it resumes, cancels or expires their paused deliveries batch by batch (`Relay.Agents.Ceiling.apply_decision/2`). It is queued in the transaction that records the decision; its arguments carry the scope and the decision's identifier only (T-15). A run that stops half way is continued by the next attempt, which applies only what is left.
  """

  use Relay.Worker, queue: :maintenance, max_attempts: 20, timeout: 600_000

  # T-15
  @doc "The job changeset that applies the decision `decision_id` of `scope`."
  @spec job(Relay.Scope.t(), Relay.Id.t()) :: Ecto.Changeset.t()
  def job(%Relay.Scope{} = scope, decision_id) do
    scope
    |> Relay.Scope.to_job_args()
    |> Map.put("decision_id", Relay.Id.to_string(decision_id))
    |> new()
  end

  # AG-49
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"decision_id" => text} = args}) do
    with {:ok, scope} <- Relay.Scope.from_job_args(args),
         {:ok, decision_id} <- Relay.Id.parse(text),
         {:ok, _totals} <- Relay.Agents.Ceiling.apply_decision(scope, decision_id) do
      :ok
    end
  end
end
