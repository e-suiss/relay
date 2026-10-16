defmodule Relay.Webhooks.Store do
  @moduledoc """
  Data access for inbound provider receipts. A receipt is committed before the provider gets its `2xx`; a repeated provider event is counted, not processed again. Every function runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Repo

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  # WH-49
  # OP-68 (7)
  @doc "Records a provider receipt; the same provider event in the same environment is a duplicate."
  @spec receipt_record(map()) :: {:recorded | :duplicate, Relay.Id.t() | nil}
  def receipt_record(r) do
    [row] =
      Repo.call!("relay_fn.webhook_receipt_record", [
        r.id,
        r.provider,
        Map.get(r, :provider_account_id),
        r.provider_event_id,
        r.body_digest,
        Map.get(r, :body_ct),
        Map.get(r, :body_key_id)
      ])

    {Repo.code!(row["result"], [:recorded, :duplicate]), row["receipt_id"]}
  end

  @doc "Marks a receipt that produces no ledger event as processed or rejected."
  @spec receipt_mark(Relay.Id.t(), :processed | :rejected, String.t() | nil) ::
          :marked | :already_final | :not_found
  def receipt_mark(receipt_id, state, reason) when state in [:processed, :rejected] do
    [row] =
      Repo.call!("relay_fn.webhook_receipt_mark", [receipt_id, Atom.to_string(state), reason])

    Repo.code!(row["webhook_receipt_mark"], [:marked, :already_final, :not_found])
  end
end
