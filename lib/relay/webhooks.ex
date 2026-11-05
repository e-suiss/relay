defmodule Relay.Webhooks do
  @moduledoc """
  The outbound delivery engine, endpoints and the webhook portal. Other contexts use only the functions of this module.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  alias Relay.Webhooks.Store

  # WH-49
  @doc "Records an inbound provider receipt in its own scoped transaction; commit it before answering the provider."
  @spec record_receipt(Relay.Scope.t(), map()) ::
          {:ok, {:recorded | :duplicate, Relay.Id.t() | nil}} | {:error, term()}
  def record_receipt(scope, receipt),
    do: Store.in_scope(scope, fn _status -> Store.receipt_record(receipt) end)

  # WH-49
  @doc "Records an inbound provider receipt inside the caller's scoped transaction, so the job that processes it is queued in the same transaction."
  @spec receipt_record(map()) :: {:recorded | :duplicate, Relay.Id.t() | nil}
  defdelegate receipt_record(receipt), to: Store

  # WH-49
  @doc "Reads a receipt inside the caller's scoped transaction: its provider, state and sealed body, or `nil`."
  @spec receipt(Relay.Id.t()) :: map() | nil
  defdelegate receipt(receipt_id), to: Store

  # WH-49
  @doc "Marks a receipt inside the caller's scoped transaction."
  @spec receipt_mark(Relay.Id.t(), :processed | :rejected, String.t() | nil) ::
          :marked | :already_final | :not_found
  defdelegate receipt_mark(receipt_id, state, reason), to: Store

  @doc "Marks a receipt that produces no ledger event."
  @spec mark_receipt(Relay.Scope.t(), Relay.Id.t(), :processed | :rejected, String.t() | nil) ::
          {:ok, atom()} | {:error, term()}
  def mark_receipt(scope, receipt_id, state, reason),
    do: Store.in_scope(scope, fn _status -> Store.receipt_mark(receipt_id, state, reason) end)
end
