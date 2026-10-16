defmodule Relay.Platform.OutboxStore do
  @moduledoc """
  Data access for the transactional outbox and stream sequences. Rows are claimed by state with `FOR UPDATE SKIP LOCKED`, never by `id > last_id` (OP-5). Scope discovery is the only cross-tenant read and returns scopes, never content.
  """

  alias Relay.Repo

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  @type event :: %{
          id: Relay.Id.t(),
          created_at: DateTime.t(),
          event_type: String.t(),
          stream_key: String.t(),
          epoch: non_neg_integer(),
          seq: non_neg_integer(),
          payload: map(),
          traceparent: String.t() | nil
        }

  # OP-5
  # TN-13 (4)
  # T-86
  @doc "Lists the scopes that have pending outbox rows, oldest first, through the outbox escape hatch."
  @spec pending_scopes(pos_integer()) :: [{Relay.Id.t(), String.t(), DateTime.t()}]
  def pending_scopes(limit) when is_integer(limit) and limit > 0 do
    for row <-
          Repo.call_unscoped!(:outbox_scope_discovery, "relay_ops.outbox_pending_scopes", [limit]),
        do: {row["tenant_id"], row["environment"], row["oldest_created_at"]}
  end

  # OP-5
  @doc "Claims pending outbox rows of the established scope in commit-visible order, skipping rows another dispatcher holds."
  @spec claim(pos_integer()) :: [event()]
  def claim(limit) when is_integer(limit) and limit > 0 do
    for row <- Repo.call!("relay_fn.outbox_claim", [limit]) do
      %{
        id: row["id"],
        created_at: row["created_at"],
        event_type: row["event_type"],
        stream_key: row["stream_key"],
        epoch: row["epoch"],
        seq: row["seq"],
        payload: row["payload"],
        traceparent: row["traceparent"]
      }
    end
  end

  @doc "Marks claimed rows dispatched in the same transaction that wrote their delivery jobs."
  @spec mark_dispatched([Relay.Id.t()]) :: [
          {Relay.Id.t(), :dispatched | :already_dispatched | :not_found}
        ]
  def mark_dispatched([]), do: []

  def mark_dispatched(ids) when is_list(ids) do
    for row <- Repo.call!("relay_fn.outbox_mark_dispatched", [ids]),
        do: {row["id"], Repo.code!(row["result"], [:dispatched, :already_dispatched, :not_found])}
  end

  # C-71
  # OP-5
  @doc "Takes the next sequence number of a stream; the row lock is held to commit, so sequence order is commit order."
  @spec stream_next_seq(String.t()) :: {non_neg_integer(), non_neg_integer()}
  def stream_next_seq(stream_key) when is_binary(stream_key) do
    [row] = Repo.call!("relay_fn.stream_next_seq", [stream_key])
    {row["epoch"], row["seq"]}
  end
end
