defmodule Relay.Iys.Store do
  @moduledoc """
  The database access of the İYS context (PC-28, PC-29, PC-30, PC-32): the configuration and brands of a tenant environment, the upload rows of the write path and their settlement, the permission cache and the synchronisation state of each brand, through the `relay_fn.iys_*` functions. Every function but `in_scope/2`, `scopes/1` and `overview/1` runs inside the caller's scoped transaction.
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
  b.authorised_at, u.address_digest_key_id
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

  # PC-32
  @doc "The active brands of the scope with their synchronisation state, by brand code; a brand that never synchronised has `nil` state columns."
  @spec sync_states() :: [map()]
  def sync_states do
    sql = """
    SELECT b.id, b.brand_code, b.name, b.subtenant_id, b.sender_identity_id, b.message_access,
      b.call_access, b.email_access, b.authorised_at, b.created_at, s.cursor_iys, s.cursor_hs,
      s.last_attempt_at, s.last_pull_at, s.last_error_code, s.last_error_at,
      s.full_sync_started_at, s.full_sync_floor_at, s.last_full_sync_at, s.stale_state,
      s.reconciled_at, s.drift_count, s.address_count, s.address_state
    FROM relay.iys_brands b
    LEFT JOIN relay.iys_sync_states s ON s.tenant_id = b.tenant_id
      AND s.environment = b.environment AND s.brand_id = b.id
    WHERE b.state = 'active'
    ORDER BY b.brand_code
    """

    all(sql, [])
  end

  # PC-32
  @doc "Applies consent movements of a brand to the permission cache; `origin` is `pull`, `upload` or `verify`, and a pull names its `feed` (`IYS` or `HS`) and the cursor after the movements. Answers how many movements changed the cache."
  @spec permissions_apply(
          id(),
          String.t(),
          String.t() | nil,
          String.t() | nil,
          [map()],
          DateTime.t()
        ) :: {:applied | :brand_not_found, non_neg_integer()}
  def permissions_apply(brand_id, origin, feed, cursor, movements, %DateTime{} = now) do
    params = [brand_id, origin, feed, cursor, movements, now]
    [row] = Repo.call!("relay_fn.iys_permissions_apply", params)
    {Repo.code!(row["result"], [:applied, :brand_not_found]), row["applied"]}
  end

  # PC-32
  @doc "Marks a cached permission: `refusal_applied` or `refusal_unmatched` for a rejection that came from İYS, `withdrawn` for a permission İYS no longer holds."
  @spec permission_mark(id(), String.t(), DateTime.t()) :: :marked | :not_found
  def permission_mark(id, mark, %DateTime{} = now) do
    [row] = Repo.call!("relay_fn.iys_permission_mark", [id, mark, now])
    Repo.code!(row["iys_permission_mark"], [:marked, :not_found])
  end

  # PC-32
  # PC-33
  # OP-42
  @doc "Records what a synchronisation run observed about a brand; see `relay_fn.iys_sync_record`."
  @spec sync_record(id(), map(), DateTime.t()) :: :recorded | :brand_not_found
  def sync_record(brand_id, observation, %DateTime{} = now) do
    [row] = Repo.call!("relay_fn.iys_sync_record", [brand_id, observation, now])
    Repo.code!(row["iys_sync_record"], [:recorded, :brand_not_found])
  end

  # PC-34
  @doc "Opens a failed upload again for the operator."
  @spec upload_retry(id(), String.t(), binary(), Actor.t(), DateTime.t()) ::
          :retried | :not_found | :not_failed | :not_retryable
  def upload_retry(id, reason, digest, %Actor{} = actor, %DateTime{} = now) do
    params = [id, reason, digest] ++ Actor.params(actor) ++ [now]
    [row] = Repo.call!("relay_fn.iys_upload_retry", params)
    Repo.code!(row["iys_upload_retry"], [:retried, :not_found, :not_failed, :not_retryable])
  end

  # PC-32
  # PC-38
  @doc "The rejections of a brand that came from İYS and were not applied in Relay yet, oldest first, each with the active recipients that have the address."
  @spec pending_refusals(id(), pos_integer()) :: [map()]
  def pending_refusals(brand_id, limit) do
    sql = """
    SELECT p.id, p.consent_type, p.consent_at, p.registered_at, p.transaction_ref,
      ARRAY(SELECT DISTINCT a.recipient_id FROM relay.recipient_addresses a
        JOIN relay.recipients r ON r.tenant_id = a.tenant_id AND r.environment = a.environment
          AND r.id = a.recipient_id AND r.state = 'active'
        WHERE a.tenant_id = p.tenant_id AND a.environment = p.environment
          AND a.kind = CASE p.consent_type WHEN 'EPOSTA' THEN 'email' ELSE 'phone' END
          AND a.state IN ('active', 'disabled')
          AND (a.address_bidx = p.address_digest
            OR a.address_bidx = p.address_digest_alt)) AS recipient_ids
    FROM relay.iys_permissions p
    WHERE p.brand_id = $1 AND p.refusal_state = 'pending'
    ORDER BY p.id
    LIMIT #{limit}
    """

    all(sql, [brand_id])
  end

  # PC-32
  @doc "The current cached permissions of a brand, type and recipient type whose address has one of `digests`."
  @spec current_permissions(id(), String.t(), String.t(), [binary()]) :: [map()]
  def current_permissions(brand_id, consent_type, recipient_type, digests) do
    sql = """
    SELECT p.id, p.consent_status, p.verified_at
    FROM relay.iys_permissions p
    WHERE p.brand_id = $1 AND p.consent_type = $2 AND p.recipient_type = $3
      AND p.superseded_at IS NULL
      AND (p.address_digest = ANY($4::bytea[]) OR p.address_digest_alt = ANY($4::bytea[]))
    """

    all(sql, [brand_id, consent_type, recipient_type, digests])
  end

  # PC-32
  # OP-42
  @doc "The cached permissions of a brand that have to be read again from İYS, oldest first: approvals last verified before `floor` (`nil` for none) and permissions written from an upload before `unpulled_before` that no pull reported. Only permissions whose address an active recipient has are listed, each with that recipient."
  @spec unverified(id(), DateTime.t() | nil, DateTime.t(), pos_integer()) :: [map()]
  def unverified(brand_id, floor, %DateTime{} = unpulled_before, limit) do
    sql = """
    SELECT p.id, p.consent_type, p.recipient_type, p.consent_status, r.recipient_id
    FROM relay.iys_permissions p
    JOIN LATERAL (SELECT a.recipient_id FROM relay.recipient_addresses a
      WHERE a.tenant_id = p.tenant_id AND a.environment = p.environment
        AND a.kind = CASE p.consent_type WHEN 'EPOSTA' THEN 'email' ELSE 'phone' END
        AND a.state = 'active'
        AND (a.address_bidx = p.address_digest OR a.address_bidx = p.address_digest_alt)
      ORDER BY a.recipient_id
      LIMIT 1) r ON true
    WHERE p.brand_id = $1 AND p.superseded_at IS NULL
      AND ((p.consent_status = 'ONAY' AND p.verified_at < $2::timestamptz)
        OR (p.origin = 'upload' AND p.pulled_at IS NULL AND p.created_at < $3))
    ORDER BY p.verified_at, p.id
    LIMIT #{limit}
    """

    all(sql, [brand_id, floor, unpulled_before])
  end

  # OP-42
  # PC-62
  @doc "What the reconciliation counts for a brand: `drift`, the confirmed uploads settled before `settled_before` whose movement the cache does not hold and the cached permissions written from an upload before it that no pull reported; `unverified`, the approvals last verified before `floor`; and `addresses`, the distinct addresses the cache holds."
  @spec reconciliation(id(), DateTime.t() | nil, DateTime.t()) :: map()
  def reconciliation(brand_id, floor, %DateTime{} = settled_before) do
    sql = """
    SELECT
      (SELECT count(*) FROM relay.iys_uploads u
        WHERE u.brand_id = $1 AND u.state = 'confirmed' AND u.settled_at < $3
          AND u.settled_at >= $3 - interval '7 days'
          AND NOT EXISTS (SELECT 1 FROM relay.iys_permissions p
            WHERE p.tenant_id = u.tenant_id AND p.environment = u.environment
              AND p.brand_id = u.brand_id AND p.consent_type = u.consent_type
              AND p.superseded_at IS NULL
              AND (p.address_digest = u.address_digest
                OR p.address_digest_alt = u.address_digest)
              AND (p.consent_status = u.consent_status
                OR p.registered_at > u.registered_at)))
      + (SELECT count(*) FROM relay.iys_permissions p
        WHERE p.brand_id = $1 AND p.superseded_at IS NULL AND p.origin = 'upload'
          AND p.pulled_at IS NULL AND p.created_at < $3) AS drift,
      (SELECT count(*) FROM relay.iys_permissions p
        WHERE p.brand_id = $1 AND p.superseded_at IS NULL AND p.consent_status = 'ONAY'
          AND p.verified_at < $2::timestamptz) AS unverified,
      (SELECT count(DISTINCT p.address_digest) FROM relay.iys_permissions p
        WHERE p.brand_id = $1 AND p.superseded_at IS NULL) AS addresses
    """

    one(sql, [brand_id, floor, settled_before])
  end

  # PC-33
  # PC-27
  # INV-19
  @doc "The rows the İYS gate reads for a marketing delivery, in one statement: the tenant's region, whether it has a configuration, the brand bound to `subtenant_id` (`nil` for the tenant), the brand's synchronisation state and the current permissions of the address digest for `consent_type`."
  @spec gate(id(), id() | nil, String.t(), binary()) :: [map()]
  def gate(tenant_id, subtenant_id, consent_type, digest) do
    sql = """
    SELECT t.region::text AS region, c.id AS config_id, b.id AS brand_id, s.last_pull_at,
      s.full_sync_floor_at, p.consent_status, p.verified_at
    FROM relay.tenants t
    LEFT JOIN relay.iys_configs c ON c.tenant_id = t.id
    LEFT JOIN relay.iys_brands b ON b.tenant_id = c.tenant_id AND b.environment = c.environment
      AND b.state = 'active' AND b.sender_identity_id IS NULL
      AND b.subtenant_id IS NOT DISTINCT FROM $2::uuid
    LEFT JOIN relay.iys_sync_states s ON s.tenant_id = b.tenant_id
      AND s.environment = b.environment AND s.brand_id = b.id
    LEFT JOIN relay.iys_permissions p ON p.tenant_id = b.tenant_id
      AND p.environment = b.environment AND p.brand_id = b.id AND p.consent_type = $3
      AND p.superseded_at IS NULL
      AND (p.address_digest = $4 OR p.address_digest_alt = $4)
    WHERE t.id = $1
    """

    all(sql, [tenant_id, subtenant_id, consent_type, digest])
  end

  # TN-13 (4)
  @doc "Lists the scopes that have an İYS configuration, through the İYS discovery escape hatch; scopes only, no content."
  @spec scopes(pos_integer()) :: [{Relay.Id.t(), String.t()}]
  def scopes(limit) do
    rows = Repo.call_unscoped!(:iys_scope_discovery, "relay_ops.iys_scopes", [limit])
    for row <- rows, do: {row["tenant_id"], row["environment"]}
  end

  # PC-33
  # PC-62
  # OP-42
  @doc "Counts, across every tenant and by count only, the active brands whose copy is past the warning and the stop age at `now`, the brands at the warning and at the limit of the direct access threshold, and the drift the reconciliations found."
  @spec overview(DateTime.t()) :: map()
  def overview(%DateTime{} = now) do
    warning = Relay.Limits.seconds!(["iys", "stale_warning"])
    stop = Relay.Limits.seconds!(["iys", "stale_stop"])
    params = [now, warning, stop]
    [row] = Repo.call_unscoped!(:iys_sync_overview, "relay_ops.iys_sync_overview", params)
    row
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
