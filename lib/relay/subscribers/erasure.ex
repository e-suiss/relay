defmodule Relay.Subscribers.Erasure do
  @moduledoc """
  The job that carries out a subscriber deletion request (API-66): it erases the subject by crypto-shredding (`Relay.Keys.Erasure.erase_subject/4`, request reference `sdr_…`), which cancels its pending and scheduled deliveries and deletes its inbox, and then completes the request with the erasure log entry, or holds it under a legal hold. Rows are never deleted. Its arguments carry identifiers only (T-15).
  """

  use Relay.Worker, queue: :maintenance, max_attempts: 20, timeout: 120_000

  alias Relay.Scope

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"request_id" => request, "recipient_id" => recipient} = args}) do
    with {:ok, scope} <- Scope.from_job_args(args),
         {:ok, request_id} <- Relay.Id.parse(request),
         {:ok, recipient_id} <- Relay.Id.parse(recipient),
         {:ok, _result} <- Relay.Subscribers.erase(scope, request_id, recipient_id) do
      :ok
    end
  end

  @doc "The erasure job of a deletion request."
  @spec job(Scope.t(), Relay.Id.t(), Relay.Id.t()) :: Ecto.Changeset.t()
  def job(%Scope{} = scope, request_id, recipient_id) do
    scope
    |> Scope.to_job_args()
    |> Map.merge(%{
      "request_id" => Relay.Id.to_string(request_id),
      "recipient_id" => Relay.Id.to_string(recipient_id)
    })
    |> new()
  end
end
