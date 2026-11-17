defmodule Relay.Iys.Store do
  @moduledoc """
  The database access of the İYS context (PC-28, PC-29, PC-30): the configuration and brands of a tenant environment, the upload rows of the write path and their settlement, through the `relay_fn.iys_*` functions. Every function but `in_scope/2` and `scopes/1` runs inside the caller's scoped transaction.
  """

  alias Relay.Actor
  alias Relay.Repo

  @type id :: Relay.Id.t()
  @type cursor :: %{direction: :after | :before, sort_ts_us: integer(), id: id()} | nil

  @put ~w(created updated version_conflict tenant_inactive sandbox_required secret_not_found
          binding_conflict subtenant_not_found sender_identity_not_found
          sender_identity_mismatch)a
  @enqueued ~w(queued duplicate not_configured brand_not_mapped)a
  @claimed ~w(claimed busy settled overdue not_found)a
  @settled ~w(settled already_settled not_found)a

  @upload """
  u.tenant_id, u.environment, u.id, u.brand_id, u.consent_type, u.consent_status,
  u.recipient_type, u.source, u.origin, u.consent_at, u.recipient_id, u.consent_id,
  u.address_ct, u.address_key_id, u.address_digest, u.state, u.deadline_at, u.attempts,
  u.error_code, u.error_at, u.transaction_ref, u.registered_at, u.trace_ref, u.created_at,
  u.updated_at, u.settled_at, b.brand_code, b.message_access, b.call_access, b.email_access,
  b.authorised_at
  """

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  @doc "Rolls the current scoped transaction back with `reason`."
  @spec rollback(term()) :: no_return()
  def rollback(reason), do: Repo.rollback(reason)

  # PC-29
  @doc "The İYS configuration of the scope, or `nil`."
  @spec config() :: map() | nil
  def config do
    sql = """
    SELECT c.tenant_id, c.environment, c.id, c.mode, c.api, c.iys_code, c.integrator_code,
      c.username, c.credential_ref_id, c.consent_limit, c.used_consent_limit,
      c.consent_limit_exceed, c.quota_state, c.quota_checked_at, c.blocked_code, c.blocked_at,
      c.version, c.created_at, c.updated_at
    FROM relay.iys_configs c
    """

    one(sql, [])
  end

  # PC-29
  @doc "The active brands of the scope, by brand code."
  @spec brands() :: [map()]
  def brands do
    sql = """
    SELECT b.tenant_id, b.environment, b.id, b.brand_code, b.name, b.subtenant_id,
      b.sender_identity_id, b.state, b.message_access, b.call_access, b.email_access,
      b.authorised_at, b.created_at, b.updated_at
    FROM relay.iys_brands b
    WHERE b.state = 'active'
    ORDER BY b.brand_code
    """

    all(sql, [])
  end

  # PC-29
  # E-22
  @doc "Writes the configuration and replaces the brand set; `brands` carry a fresh `id` each, used when the brand is new."
  @spec config_put(id(), map(), [map()], pos_integer() | nil, binary(), Actor.t()) ::
          {atom(), pos_integer() | nil}
  def config_put(id, config, brands, expected_version, digest, %Actor{} = actor) do
    params = [id, config, brands, expected_version, digest] ++ Actor.params(actor)
    [row] = Repo.call!("relay_fn.iys_config_put", params)
    {Repo.code!(row["result"], @put), row["version"]}
  end

  # PC-34
  @doc "Records what was observed about the connection: the quota (`quota_state`, `consent_limit`, `used_consent_limit`, `consent_limit_exceed`) and, when the key is present, the `blocked_code` (`nil` clears it). Answers the quota state before the write, or `nil` without a configuration."
  @spec config_observe(map(), DateTime.t()) :: String.t() | nil
  def config_observe(observation, %DateTime{} = now) do
    [row] = Repo.call!("relay_fn.iys_config_observe", [observation, now])

    case Repo.code!(row["result"], [:observed, :not_found]) do
      :observed -> row["quota_state"]
      :not_found -> nil
    end
  end

  # PC-29
  @doc "Records the integrator's authorisations of the active brands; a brand the list does not name has none."
  @spec brands_observe([map()], DateTime.t()) :: :observed | :not_integrator
  def brands_observe(brands, %DateTime{} = now) do
    [row] = Repo.call!("relay_fn.iys_brands_observe", [brands, now])
    Repo.code!(row["iys_brands_observe"], [:observed, :not_integrator])
  end

  # PC-30
  @doc "Opens the upload of a consent movement; `sealed` is the address ciphertext with its key and `digest` its blind index with its key."
  @spec upload_enqueue(id(), map(), map(), {id(), binary()}, DateTime.t()) ::
          {atom(), id() | nil}
  def upload_enqueue(id, upload, %{ct: ct, key_id: key_id}, {digest_key_id, digest}, now) do
    params = [id, upload, ct, key_id, digest, digest_key_id, now]
    [row] = Repo.call!("relay_fn.iys_upload_enqueue", params)
    {Repo.code!(row["result"], @enqueued), row["upload_id"]}
  end

  # PC-30
  @doc "Claims an upload for one attempt until `claimed_until`."
  @spec upload_claim(id(), DateTime.t(), DateTime.t()) :: atom()
  def upload_claim(id, %DateTime{} = claimed_until, %DateTime{} = now) do
    [row] = Repo.call!("relay_fn.iys_upload_claim", [id, claimed_until, now])
    Repo.code!(row["iys_upload_claim"], @claimed)
  end

  # PC-30
  @doc "Settles an attempt of an upload with `outcome` (`retry`, `uploaded`, `confirmed`, `failed`, `expired` or `skipped`); `consent_row_id` is the identifier of the consent copy row a confirmation or an expiry appends."
  @spec upload_settle(id(), String.t(), map(), id() | nil, DateTime.t()) :: atom()
  def upload_settle(id, outcome, detail, consent_row_id, %DateTime{} = now) do
    params = [id, outcome, detail, consent_row_id, now]
    [row] = Repo.call!("relay_fn.iys_upload_settle", params)
    Repo.code!(row["iys_upload_settle"], @settled)
  end

  # PC-30
  @doc "Reads an upload with the code and authorisations of its brand, or `nil`."
  @spec upload(id()) :: map() | nil
  def upload(id) do
    sql = """
    SELECT #{@upload}
    FROM relay.iys_uploads u
    LEFT JOIN relay.iys_brands b ON b.tenant_id = u.tenant_id AND b.environment = u.environment
      AND b.id = u.brand_id
    WHERE u.id = $1
    """

    one(sql, [id])
  end

  # PC-30
  # API-56
  @doc "A page of uploads, newest first, optionally of one state; at most `limit + 1` rows, each with its `cursor_at`."
  @spec uploads(String.t() | nil, cursor(), pos_integer()) :: [map()]
  def uploads(state, cursor, limit) do
    {condition, order, params} = window(cursor, [state])

    sql = """
    SELECT #{@upload}, u.created_at AS cursor_at
    FROM relay.iys_uploads u
    LEFT JOIN relay.iys_brands b ON b.tenant_id = u.tenant_id AND b.environment = u.environment
      AND b.id = u.brand_id
    WHERE ($1::text IS NULL OR u.state = $1)#{condition}
    ORDER BY u.created_at #{order}, u.id #{order}
    LIMIT #{limit + 1}
    """

    rows = all(sql, params)
    if order == "ASC", do: Enum.reverse(rows), else: rows
  end

  defp window(nil, params), do: {"", "DESC", params}

  defp window(%{direction: :after, sort_ts_us: ts, id: id}, params),
    do: {" AND (u.created_at, u.id) < ($2, $3)", "DESC", params ++ [from_us(ts), id]}

  defp window(%{direction: :before, sort_ts_us: ts, id: id}, params),
    do: {" AND (u.created_at, u.id) > ($2, $3)", "ASC", params ++ [from_us(ts), id]}

  defp from_us(us), do: DateTime.from_unix!(us, :microsecond)

  # PC-30
  @doc "The identifiers of the open uploads whose deadline passed at `now` or that no attempt touched since `idle_since`, oldest first."
  @spec due(DateTime.t(), DateTime.t(), pos_integer()) :: [map()]
  def due(%DateTime{} = now, %DateTime{} = idle_since, limit) do
    sql = """
    SELECT u.tenant_id, u.environment, u.id, u.consent_status,
      (u.state = 'pending' AND u.deadline_at <= $1) AS overdue
    FROM relay.iys_uploads u
    WHERE u.state IN ('pending', 'uploaded')
      AND ((u.state = 'pending' AND u.deadline_at <= $1) OR u.updated_at <= $2)
    ORDER BY u.id
    LIMIT #{limit}
    """

    all(sql, [now, idle_since])
  end

  # WH-15
  # OP-7
  @doc "Appends a tenant event to the outbox on `stream_key`."
  @spec event(String.t(), String.t(), map()) :: :appended
  def event(type, stream_key, data) do
    params = [Relay.Id.generate(), type, stream_key, data, nil]
    [row] = Repo.call!("relay_fn.outbox_append", params)
    Repo.code!(row["result"], [:appended])
  end

  # TN-13 (4)
  @doc "Lists the scopes that have an İYS configuration, through the İYS discovery escape hatch; scopes only, no content."
  @spec scopes(pos_integer()) :: [{Relay.Id.t(), String.t()}]
  def scopes(limit) do
    rows = Repo.call_unscoped!(:iys_scope_discovery, "relay_ops.iys_scopes", [limit])
    for row <- rows, do: {row["tenant_id"], row["environment"]}
  end

  defp one(sql, params) do
    case all(sql, params) do
      [row] -> row
      [] -> nil
    end
  end

  defp all(sql, params) do
    %{rows: rows, columns: columns} = Repo.scoped_query!(sql, params)
    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end
end
