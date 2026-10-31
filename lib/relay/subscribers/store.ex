defmodule Relay.Subscribers.Store do
  @moduledoc """
  Data access of subscribers: the lookup by blind index, the single write path `relay_fn.recipient_upsert`, the profile reads with their address states, and deletion requests. Every function except `in_scope/2` runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Actor
  alias Relay.Repo

  @row """
  SELECT r.id, r.kind, r.state, r.version, r.inbox_only, r.external_id_ct, r.name_ct,
    r.locale, r.timezone, r.legal_type, r.created_at, r.updated_at,
    (SELECT a.address_ct FROM relay.recipient_addresses a
      WHERE a.tenant_id = r.tenant_id AND a.environment = r.environment
        AND a.recipient_id = r.id AND a.kind = 'email' AND a.state = 'active') AS email_ct,
    (SELECT a.state FROM relay.recipient_addresses a
      WHERE a.tenant_id = r.tenant_id AND a.environment = r.environment
        AND a.recipient_id = r.id AND a.kind = 'email' AND a.state IN ('active', 'disabled')
      ORDER BY (a.state = 'active') DESC LIMIT 1) AS email_state,
    (SELECT a.state FROM relay.recipient_addresses a
      WHERE a.tenant_id = r.tenant_id AND a.environment = r.environment
        AND a.recipient_id = r.id AND a.kind = 'phone' AND a.state IN ('active', 'disabled')
      ORDER BY (a.state = 'active') DESC LIMIT 1) AS phone_state
  FROM relay.recipients r
  """

  @type digest :: <<_::256>>

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  @doc "Queues a job inside the current transaction; rolls the transaction back when it is not queued."
  @spec insert_job!(Ecto.Changeset.t()) :: :ok
  def insert_job!(changeset) do
    case Oban.insert(changeset) do
      {:ok, _job} -> :ok
      {:error, reason} -> Repo.rollback({:job_not_queued, reason})
    end
  end

  # C-19
  # TN-33
  @doc "Finds the recipient whose external identifier has this blind index, or `nil`."
  @spec lookup(binary()) :: map() | nil
  def lookup(bidx) do
    one(
      """
      SELECT r.id, r.kind, r.state, r.version FROM relay.recipients r
      WHERE r.external_id_bidx = $1 OR r.external_id_bidx_next = $1
      """,
      [bidx]
    )
  end

  @doc "Finds the subscribers whose external identifiers have these blind indexes."
  @spec lookup_many([binary()]) :: [Relay.Id.t()]
  def lookup_many(bidxs) do
    for row <-
          maps(
            Repo.scoped_query!(
              """
              SELECT r.id FROM relay.recipients r
              WHERE r.kind = 'subscriber'
                AND (r.external_id_bidx = ANY ($1) OR r.external_id_bidx_next = ANY ($1))
              """,
              [bidxs]
            )
          ),
        do: row["id"]
  end

  # API-21
  # API-66
  # C-20
  @doc "Writes a subscriber through `relay_fn.recipient_upsert`; see `Relay.Subscribers.prepare/3` for the plan."
  @spec upsert(map(), pos_integer() | nil) :: {atom(), Relay.Id.t() | nil, pos_integer() | nil}
  def upsert(plan, expected_version) do
    [row] =
      Repo.call!("relay_fn.recipient_upsert", [
        plan.id,
        Atom.to_string(plan.mode),
        plan.bidx,
        plan.bidx_key_id,
        plan.external_id_ct,
        plan.profile_dek_id,
        plan.wrapped_dek,
        plan.wrapping_key_id,
        plan.fields,
        plan.name_ct,
        plan.attributes_ct,
        plan.locale,
        plan.timezone,
        plan.legal_type,
        plan.email_address_id,
        plan.email_ct,
        plan.email_bidx,
        plan.phone_address_id,
        plan.phone_ct,
        plan.phone_bidx,
        plan.address_bidx_key_id,
        expected_version
      ])

    {Repo.code!(row["result"], [
       :created,
       :updated,
       :unchanged,
       :exists,
       :recipient_not_found,
       :deletion_pending,
       :is_agent,
       :version_conflict,
       :tenant_inactive
     ]), row["recipient_id"], row["version"]}
  end

  @doc "Reads a recipient with its address states, or `nil`."
  @spec row(Relay.Id.t()) :: map() | nil
  def row(id), do: one(@row <> " WHERE r.id = $1", [id])

  # API-56
  @doc "Lists subscribers newest first after or before a cursor position; at most `limit + 1` rows."
  @spec list(map() | nil, pos_integer()) :: [map()]
  def list(cursor, limit) do
    {condition, order, params} =
      case cursor do
        nil -> {"", "DESC", []}
        %{direction: :after} = c -> {" AND (r.created_at, r.id) < ($1, $2)", "DESC", at(c)}
        %{direction: :before} = c -> {" AND (r.created_at, r.id) > ($1, $2)", "ASC", at(c)}
      end

    sql =
      @row <>
        " WHERE r.kind = 'subscriber' AND r.state <> 'deleted'#{condition}" <>
        " ORDER BY r.created_at #{order}, r.id #{order} LIMIT #{limit + 1}"

    rows = maps(Repo.scoped_query!(sql, params))
    if order == "ASC", do: Enum.reverse(rows), else: rows
  end

  defp at(%{sort_ts_us: ts, id: id}), do: [DateTime.from_unix!(ts, :microsecond), id]

  # API-66
  @doc "Records a deletion request for a subscriber and marks it `deletion_requested`."
  @spec deletion_request(Relay.Id.t(), Relay.Id.t(), digest(), Actor.t()) ::
          {:requested | :already_requested | :not_found | :held, Relay.Id.t() | nil}
  def deletion_request(request_id, recipient_id, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.recipient_deletion_request",
        [request_id, recipient_id, digest] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], [:requested, :already_requested, :not_found, :held]),
     row["request_id"]}
  end

  # API-66
  @doc "Completes a deletion request with the erasure that carried it out; without one it is held."
  @spec deletion_complete(Relay.Id.t(), Relay.Id.t() | nil) :: :completed | :held | :not_pending
  def deletion_complete(request_id, erasure_id) do
    [row] = Repo.call!("relay_fn.recipient_deletion_complete", [request_id, erasure_id])
    Repo.code!(row["recipient_deletion_complete"], [:completed, :held, :not_pending])
  end

  @doc "Reads a deletion request, or `nil`."
  @spec deletion(Relay.Id.t()) :: map() | nil
  def deletion(id) do
    one(
      """
      SELECT q.id, q.recipient_id, q.status, q.created_at, q.completed_at
      FROM relay.recipient_deletion_requests q WHERE q.id = $1
      """,
      [id]
    )
  end

  @doc "The latest erasure log entry of a recipient, or `nil`."
  @spec erasure_id(Relay.Id.t()) :: Relay.Id.t() | nil
  def erasure_id(recipient_id) do
    case one(
           """
           SELECT e.id FROM relay.erasure_log e WHERE e.recipient_id = $1
           ORDER BY e.created_at DESC, e.id DESC LIMIT 1
           """,
           [recipient_id]
         ) do
      %{"id" => id} -> id
      nil -> nil
    end
  end

  defp one(sql, params) do
    case maps(Repo.scoped_query!(sql, params)) do
      [row] -> row
      [] -> nil
    end
  end

  defp maps(%Postgrex.Result{columns: columns, rows: rows}),
    do: Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
end
