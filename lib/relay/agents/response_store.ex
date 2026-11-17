defmodule Relay.Agents.ResponseStore do
  @moduledoc """
  Data access for response collection: the response tokens of a waitpoint through the `relay_fn.waitpoint_response_token_*` functions and the responder's subject data key, inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Repo

  @mint [:minted, :not_found, :not_open, :profile_refused, :not_responder]
  @consume [:consumed, :replayed, :already_consumed, :rotated, :expired, :not_found]
  @process [:settled, :already_settled, :not_processing, :not_found]

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  # AG-31
  @doc "Records a new response token of a responder of a waitpoint and rotates the responder's earlier unused tokens; returns the result and the moment the token expires."
  @spec token_mint(Relay.Id.t(), Relay.Id.t(), Relay.Id.t(), pos_integer()) ::
          {atom(), DateTime.t() | nil}
  def token_mint(id, waitpoint_id, recipient_id, ttl_ms) do
    [row] =
      Repo.call!("relay_fn.waitpoint_response_token_mint", [
        id,
        waitpoint_id,
        recipient_id,
        ttl_ms
      ])

    {Repo.code!(row["result"], @mint), row["expires_at"]}
  end

  # AG-31
  # AG-35
  @doc "Reads a response token, or `nil`."
  @spec token(Relay.Id.t()) :: map() | nil
  def token(id) do
    sql = """
    SELECT t.waitpoint_id, t.recipient_id, t.state, t.expires_at, t.value_digest, t.outcome,
      t.consumed_at, t.settled_at
    FROM relay.waitpoint_response_tokens t WHERE t.id = $1
    """

    %Postgrex.Result{columns: columns, rows: rows} = Repo.scoped_query!(sql, [id])

    case rows do
      [row] -> token_row(id, Map.new(Enum.zip(columns, row)))
      [] -> nil
    end
  end

  defp token_row(id, row) do
    %{
      id: id,
      waitpoint_id: row["waitpoint_id"],
      recipient_id: row["recipient_id"],
      state: row["state"],
      expires_at: row["expires_at"],
      value_digest: row["value_digest"],
      outcome: row["outcome"],
      consumed_at: row["consumed_at"],
      settled_at: row["settled_at"]
    }
  end

  # AG-31
  # INV-33
  @doc "Consumes a response token with the sealed response it carries; a token is consumed once, and the same response sent again is `:replayed`."
  @spec token_consume(Relay.Id.t(), String.t(), binary(), Relay.Id.t(), <<_::256>>) ::
          {atom(), Relay.Id.t() | nil, Relay.Id.t() | nil}
  def token_consume(id, via, value_ct, value_key_id, value_digest) do
    [row] =
      Repo.call!("relay_fn.waitpoint_response_token_consume", [
        id,
        via,
        value_ct,
        value_key_id,
        value_digest
      ])

    {Repo.code!(row["result"], @consume), row["waitpoint_id"], row["recipient_id"]}
  end

  # AG-35
  # AG-28
  @doc "Offers the response a consumed token carries to its waitpoint and settles the token with the outcome."
  @spec token_process(Relay.Id.t(), Relay.Id.t()) :: {atom(), String.t() | nil}
  def token_process(id, response_id) do
    [row] = Repo.call!("relay_fn.waitpoint_response_token_process", [id, response_id])
    {Repo.code!(row["result"], @process), row["outcome"]}
  end

  # OP-18
  @doc "Registers a subject data key of a recipient and retention class, or returns the active one."
  @spec subject_key_create(Relay.Id.t(), Relay.Id.t(), String.t(), binary(), Relay.Id.t()) ::
          {:created | :exists | :recipient_not_found | :recipient_deleted, Relay.Id.t() | nil}
  def subject_key_create(id, recipient_id, retention_class, wrapped_dek, wrapping_key_id) do
    [row] =
      Repo.call!("relay_fn.subject_key_create", [
        id,
        recipient_id,
        retention_class,
        wrapped_dek,
        wrapping_key_id
      ])

    {Repo.code!(row["result"], [:created, :exists, :recipient_not_found, :recipient_deleted]),
     row["subject_key_id"]}
  end
end
