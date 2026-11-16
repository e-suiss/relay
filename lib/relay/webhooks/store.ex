defmodule Relay.Webhooks.Store do
  @moduledoc """
  Data access of the webhook engine: inbound provider receipts, and the consumers, tenant event types, endpoints, endpoint versions, signing keys and operations contacts of outbound delivery. A receipt is committed before the provider gets its `2xx`; a repeated provider event is counted, not processed again. Rows are written only through the `relay_fn.webhook_*` and `relay_fn.operations_contacts_replace` functions and are never deleted. Every function runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Actor
  alias Relay.Repo

  @type id :: Relay.Id.t()
  @type cursor :: map() | nil

  @consumer_created ~w(created key_conflict subtenant_not_found tenant_inactive)a
  @consumer_updated ~w(updated unchanged not_found archived version_conflict)a
  @consumer_archived ~w(archived already_archived in_use not_found)a
  @type_created ~w(created name_conflict tenant_inactive)a
  @version_added ~w(added unchanged not_found archived)a
  @archived ~w(archived already_archived not_found)a
  @endpoint_created ~w(created tenant_limit_reached consumer_limit_reached consumer_not_found
                       consumer_archived credential_not_found event_type_not_found
                       tenant_inactive)a
  @endpoint_updated ~w(updated unchanged not_found archived managed version_conflict
                       credential_not_found event_type_not_found invalid_state)a
  @endpoint_archived ~w(archived already_archived managed not_found)a
  @rotated ~w(rotated not_found archived managed not_signed)a
  @replaced ~w(replaced tenant_inactive)a

  @consumers "relay.webhook_consumers c"
  @consumer_columns "c.id, c.key, c.name, c.source, c.subtenant_id, c.state, c.version, c.archived_at, c.created_at, c.updated_at"
  @event_types "relay.webhook_event_types t JOIN relay.webhook_event_type_versions v ON v.tenant_id = t.tenant_id AND v.environment = t.environment AND v.event_type_id = t.id AND v.version = t.current_version"
  @event_type_columns "t.id, t.name, t.description, t.state, t.current_version, t.archived_at, t.created_at, t.updated_at, v.json_schema, v.identifiers, v.example"
  @type_versions "relay.webhook_event_type_versions v JOIN relay.webhook_event_types t ON t.tenant_id = v.tenant_id AND t.environment = v.environment AND t.id = v.event_type_id"
  @type_version_columns "v.event_type_id, v.version, v.json_schema, v.identifiers, v.example, v.created_at, t.name"
  @endpoints "relay.webhook_endpoints e JOIN relay.webhook_endpoint_versions ev ON ev.tenant_id = e.tenant_id AND ev.environment = e.environment AND ev.endpoint_id = e.id AND ev.version = e.current_version LEFT JOIN relay.webhook_consumers c ON c.tenant_id = e.tenant_id AND c.environment = e.environment AND c.id = e.consumer_id"
  @endpoint_columns "e.id, e.environment::text AS environment, e.use_kind, e.consumer_id, c.key AS consumer_key, e.kind, e.url, e.destination, e.credential_ref_id, e.event_types, e.signature_scheme, e.description, e.managed_by, e.product, e.state, e.disabled_reason, e.disabled_at, e.paused_at, e.archived_at, e.auto_disable, e.retry_schedule, e.max_concurrency, e.rate_per_second, e.payload_version, e.current_version, e.version, e.created_at, e.updated_at, ev.snapshot"
  @endpoint_versions "relay.webhook_endpoint_versions ev"
  @endpoint_version_columns "ev.endpoint_id, ev.version, ev.snapshot, ev.payload_version, ev.created_at"
  @key_columns "k.id, k.endpoint_id, k.scheme, k.state, k.public_key, k.activated_at, k.expires_at"

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

  # WH-49
  @doc "Reads a receipt: its provider, state, duplicate count, provider account and sealed body, or `nil`."
  @spec receipt(Relay.Id.t()) :: map() | nil
  def receipt(receipt_id) do
    case Repo.call!("relay_fn.webhook_receipt_read", [receipt_id]) do
      [row] -> row
      [] -> nil
    end
  end

  @doc "Marks a receipt that produces no ledger event as processed or rejected."
  @spec receipt_mark(Relay.Id.t(), :processed | :rejected, String.t() | nil) ::
          :marked | :already_final | :not_found
  def receipt_mark(receipt_id, state, reason) when state in [:processed, :rejected] do
    [row] =
      Repo.call!("relay_fn.webhook_receipt_mark", [receipt_id, Atom.to_string(state), reason])

    Repo.code!(row["webhook_receipt_mark"], [:marked, :already_final, :not_found])
  end

  # WH-2
  @doc "Creates a consumer; returns the result, the consumer's identifier and its version."
  @spec consumer_create(map(), binary(), Actor.t()) :: {atom(), id() | nil, pos_integer() | nil}
  def consumer_create(attrs, digest, %Actor{} = actor) do
    params =
      [
        Relay.Id.generate(),
        attrs.key,
        Map.get(attrs, :name),
        Map.get(attrs, :source),
        Map.get(attrs, :subtenant_id),
        digest
      ] ++ Actor.params(actor)

    [row] = Repo.call!("relay_fn.webhook_consumer_create", params)
    {Repo.code!(row["result"], @consumer_created), row["consumer_id"], row["version"]}
  end

  # WH-2
  @doc "Changes the name or the event source of a consumer; `changes` holds only the fields to change, by their column name."
  @spec consumer_update(id(), pos_integer() | nil, map(), binary(), Actor.t()) ::
          {atom(), pos_integer() | nil}
  def consumer_update(id, expected_version, changes, digest, %Actor{} = actor) do
    params = [id, expected_version, changes, digest] ++ Actor.params(actor)
    [row] = Repo.call!("relay_fn.webhook_consumer_update", params)
    {Repo.code!(row["result"], @consumer_updated), row["version"]}
  end

  # WH-2
  @doc "Archives a consumer that has no endpoint left that is not archived."
  @spec consumer_archive(id(), binary(), Actor.t()) :: {atom(), pos_integer() | nil}
  def consumer_archive(id, digest, %Actor{} = actor) do
    [row] = Repo.call!("relay_fn.webhook_consumer_archive", [id, digest] ++ Actor.params(actor))
    {Repo.code!(row["result"], @consumer_archived), row["version"]}
  end

  # WH-2
  @doc "Reads a consumer, or `nil`."
  @spec consumer(id()) :: map() | nil
  def consumer(id),
    do: one("SELECT #{@consumer_columns} FROM #{@consumers} WHERE c.id = $1", [id])

  # WH-2
  # API-56
  @doc "A page of consumers, newest first, optionally of one state; at most `limit + 1` rows."
  @spec consumers(String.t() | nil, cursor(), pos_integer()) :: [map()]
  def consumers(state, cursor, limit) do
    where = "($1::text IS NULL OR c.state = $1)"
    page(@consumers, @consumer_columns, "c", where, [state], cursor, limit)
  end

  # WH-14
  @doc "Creates a tenant event type with the first version of its schema; returns the result and the type's identifier."
  @spec event_type_create(map(), binary(), Actor.t()) :: {atom(), id() | nil}
  def event_type_create(attrs, digest, %Actor{} = actor) do
    params =
      [
        Relay.Id.generate(),
        attrs.name,
        Map.get(attrs, :description),
        attrs.schema,
        attrs.schema_digest,
        attrs.identifiers,
        Map.get(attrs, :example),
        digest
      ] ++ Actor.params(actor)

    [row] = Repo.call!("relay_fn.webhook_event_type_create", params)
    {Repo.code!(row["result"], @type_created), row["event_type_id"]}
  end

  # WH-14
  @doc "Opens the next schema version of a tenant event type; the current schema again changes nothing."
  @spec event_type_version_add(id(), map(), binary(), Actor.t()) :: {atom(), pos_integer() | nil}
  def event_type_version_add(id, attrs, digest, %Actor{} = actor) do
    example = Map.get(attrs, :example)
    version = [id, attrs.schema, attrs.schema_digest, attrs.identifiers, example, digest]
    params = version ++ Actor.params(actor)
    [row] = Repo.call!("relay_fn.webhook_event_type_version_add", params)
    {Repo.code!(row["result"], @version_added), row["version"]}
  end

  # WH-14
  @doc "Archives a tenant event type."
  @spec event_type_archive(id(), binary(), Actor.t()) :: {atom(), pos_integer() | nil}
  def event_type_archive(id, digest, %Actor{} = actor) do
    [row] = Repo.call!("relay_fn.webhook_event_type_archive", [id, digest] ++ Actor.params(actor))
    {Repo.code!(row["result"], @archived), row["version"]}
  end

  # WH-14
  @doc "Reads a tenant event type with its current schema version, or `nil`."
  @spec event_type(id()) :: map() | nil
  def event_type(id),
    do: one("SELECT #{@event_type_columns} FROM #{@event_types} WHERE t.id = $1", [id])

  # WH-14
  # API-56
  @doc "A page of tenant event types, newest first, optionally of one state."
  @spec event_types(String.t() | nil, cursor(), pos_integer()) :: [map()]
  def event_types(state, cursor, limit) do
    where = "($1::text IS NULL OR t.state = $1)"
    page(@event_types, @event_type_columns, "t", where, [state], cursor, limit)
  end

  # WH-14
  @doc "Reads one schema version of a tenant event type, or `nil`."
  @spec event_type_version(id(), pos_integer()) :: map() | nil
  def event_type_version(id, version) do
    sql =
      "SELECT #{@type_version_columns} FROM #{@type_versions} WHERE v.event_type_id = $1 AND v.version = $2"

    one(sql, [id, version])
  end

  # WH-14
  # API-56
  @doc "A page of the schema versions of a tenant event type, newest first."
  @spec event_type_versions(id(), cursor(), pos_integer()) :: [map()]
  def event_type_versions(id, cursor, limit) do
    where = "v.event_type_id = $1"
    numbered(@type_versions, @type_version_columns, "v", where, [id], cursor, limit)
  end

  # WH-2
  # WH-5
  # WH-16
  # WH-45
  @doc "Creates an endpoint with its first version, its health row and, for an `https` endpoint, its signing key `key`; returns the result and the endpoint's identifier."
  @spec endpoint_create(map(), map() | nil, map(), binary(), Actor.t()) :: {atom(), id() | nil}
  def endpoint_create(attrs, key, limits, digest, %Actor{} = actor) do
    key = key || %{}

    params =
      [
        Relay.Id.generate(),
        attrs.use,
        Map.get(attrs, :consumer),
        attrs.kind,
        Map.get(attrs, :url),
        attrs.destination,
        Map.get(attrs, :credential_ref_id),
        attrs.event_types,
        Map.get(attrs, :signature_scheme),
        attrs.snapshot,
        Map.get(attrs, :description),
        attrs.settings,
        attrs.payload_version,
        Map.get(key, :id),
        Map.get(key, :public_key),
        Map.get(key, :secret_ct),
        Map.get(key, :secret_key_id),
        limits.per_tenant,
        limits.per_consumer,
        digest
      ] ++ Actor.params(actor)

    [row] = Repo.call!("relay_fn.webhook_endpoint_create", params)
    {Repo.code!(row["result"], @endpoint_created), row["endpoint_id"]}
  end

  # WH-12
  # WH-48
  @doc "Changes an endpoint; `changes` holds only the fields to change, by their column name. A changed snapshot opens a new endpoint version."
  @spec endpoint_update(id(), pos_integer() | nil, map(), binary(), Actor.t()) ::
          {atom(), pos_integer() | nil}
  def endpoint_update(id, expected_version, changes, digest, %Actor{} = actor) do
    params = [id, expected_version, changes, digest] ++ Actor.params(actor)
    [row] = Repo.call!("relay_fn.webhook_endpoint_update", params)
    {Repo.code!(row["result"], @endpoint_updated), row["version"]}
  end

  # WH-48
  @doc "Archives an endpoint and retires its signing keys."
  @spec endpoint_archive(id(), binary(), Actor.t()) :: {atom(), pos_integer() | nil}
  def endpoint_archive(id, digest, %Actor{} = actor) do
    [row] = Repo.call!("relay_fn.webhook_endpoint_archive", [id, digest] ++ Actor.params(actor))
    {Repo.code!(row["result"], @endpoint_archived), row["version"]}
  end

  # WH-6
  # WH-48
  @doc "Makes `key` the active signing key of an endpoint; the key it replaces keeps signing for `overlap_s` seconds. Returns the result, the previous key's identifier and when it stops."
  @spec endpoint_key_rotate(id(), map(), non_neg_integer(), binary(), Actor.t()) ::
          {atom(), id() | nil, DateTime.t() | nil}
  def endpoint_key_rotate(id, key, overlap_s, digest, %Actor{} = actor) do
    params =
      [
        id,
        key.id,
        key.scheme,
        Map.get(key, :public_key),
        key.secret_ct,
        key.secret_key_id,
        overlap_s,
        digest
      ] ++ Actor.params(actor)

    [row] = Repo.call!("relay_fn.webhook_endpoint_key_rotate", params)
    {Repo.code!(row["result"], @rotated), row["previous_key_id"], row["previous_expires_at"]}
  end

  # WH-6
  @doc "Retires the previous keys of the scope whose overlap ended; returns how many."
  @spec keys_expire() :: non_neg_integer()
  def keys_expire do
    [row] = Repo.call!("relay_fn.webhook_endpoint_keys_expire", [])
    row["webhook_endpoint_keys_expire"]
  end

  # WH-2
  @doc "Reads an endpoint with its consumer's key and the snapshot of its current version, or `nil`."
  @spec endpoint(id()) :: map() | nil
  def endpoint(id),
    do: one("SELECT #{@endpoint_columns} FROM #{@endpoints} WHERE e.id = $1", [id])

  # WH-2
  # API-56
  @doc "A page of endpoints, newest first, filtered by `:use`, `:state` and `:consumer_id` when given."
  @spec endpoints(map(), cursor(), pos_integer()) :: [map()]
  def endpoints(filters, cursor, limit) do
    where =
      "($1::text IS NULL OR e.use_kind = $1) AND ($2::text IS NULL OR e.state = $2) AND ($3::uuid IS NULL OR e.consumer_id = $3)"

    params = [filters[:use], filters[:state], filters[:consumer_id]]
    page(@endpoints, @endpoint_columns, "e", where, params, cursor, limit)
  end

  # WH-12
  @doc "Reads one version of an endpoint, or `nil`."
  @spec endpoint_version(id(), pos_integer()) :: map() | nil
  def endpoint_version(id, version) do
    sql =
      "SELECT #{@endpoint_version_columns} FROM #{@endpoint_versions} WHERE ev.endpoint_id = $1 AND ev.version = $2"

    one(sql, [id, version])
  end

  # WH-12
  # API-56
  @doc "A page of the versions of an endpoint, newest first."
  @spec endpoint_versions(id(), cursor(), pos_integer()) :: [map()]
  def endpoint_versions(id, cursor, limit) do
    where = "ev.endpoint_id = $1"
    numbered(@endpoint_versions, @endpoint_version_columns, "ev", where, [id], cursor, limit)
  end

  # WH-5
  # WH-6
  @doc "The keys of endpoints that sign now, the active key before a previous key whose overlap has not ended at `now`, without their secrets."
  @spec keys([id()], DateTime.t()) :: [map()]
  def keys(endpoint_ids, %DateTime{} = now) do
    all(
      """
      SELECT #{@key_columns} FROM relay.webhook_endpoint_keys k
      WHERE k.endpoint_id = ANY ($1)
        AND (k.state = 'active' OR (k.state = 'previous' AND k.expires_at > $2))
      ORDER BY k.endpoint_id, k.id DESC
      """,
      [endpoint_ids, now]
    )
  end

  # WH-5
  # WH-6
  @doc "The signing keys of one endpoint with their sealed secrets, the active key first."
  @spec signing_keys(id(), DateTime.t()) :: [map()]
  def signing_keys(endpoint_id, %DateTime{} = now) do
    all(
      """
      SELECT #{@key_columns}, k.secret_ct, k.secret_key_id FROM relay.webhook_endpoint_keys k
      WHERE k.endpoint_id = $1
        AND (k.state = 'active' OR (k.state = 'previous' AND k.expires_at > $2))
      ORDER BY k.id DESC
      """,
      [endpoint_id, now]
    )
  end

  # WH-56
  @doc "Replaces the operations contacts of the scope with sealed addresses; returns the result."
  @spec contacts_replace([binary()], id() | nil, pos_integer(), binary(), Actor.t()) :: atom()
  def contacts_replace(address_cts, key_id, max, digest, %Actor{} = actor) do
    ids = Enum.map(address_cts, fn _ct -> Relay.Id.generate() end)
    params = [ids, address_cts, key_id, max, digest] ++ Actor.params(actor)
    [row] = Repo.call!("relay_fn.operations_contacts_replace", params)
    Repo.code!(row["result"], @replaced)
  end

  # WH-56
  @doc "The active operations contacts of the scope, oldest first, with their sealed addresses."
  @spec contacts() :: [map()]
  def contacts do
    all(
      """
      SELECT c.id, c.address_ct, c.address_key_id, c.created_at FROM relay.operations_contacts c
      WHERE c.state = 'active' ORDER BY c.id
      """,
      []
    )
  end

  defp page(from, columns, alias_, where, params, cursor, limit) do
    {condition, order, params} =
      case cursor do
        nil ->
          {"", "DESC", params}

        %{direction: :after, sort_ts_us: ts, id: id} ->
          n = length(params)

          {" AND (#{alias_}.created_at, #{alias_}.id) < ($#{n + 1}, $#{n + 2})", "DESC",
           params ++ [from_us(ts), id]}

        %{direction: :before, sort_ts_us: ts, id: id} ->
          n = length(params)

          {" AND (#{alias_}.created_at, #{alias_}.id) > ($#{n + 1}, $#{n + 2})", "ASC",
           params ++ [from_us(ts), id]}
      end

    sql = """
    SELECT #{columns}, #{alias_}.created_at AS cursor_at FROM #{from}
    WHERE #{where}#{condition}
    ORDER BY #{alias_}.created_at #{order}, #{alias_}.id #{order}
    LIMIT #{limit + 1}
    """

    rows = all(sql, params)
    if order == "ASC", do: Enum.reverse(rows), else: rows
  end

  defp numbered(from, columns, alias_, where, params, cursor, limit) do
    n = length(params)

    {condition, order, params} =
      case cursor do
        nil ->
          {"", "DESC", params}

        %{direction: :after, sort_ts_us: version} ->
          {" AND #{alias_}.version < $#{n + 1}", "DESC", params ++ [version]}

        %{direction: :before, sort_ts_us: version} ->
          {" AND #{alias_}.version > $#{n + 1}", "ASC", params ++ [version]}
      end

    sql = """
    SELECT #{columns} FROM #{from}
    WHERE #{where}#{condition}
    ORDER BY #{alias_}.version #{order}
    LIMIT #{limit + 1}
    """

    rows = all(sql, params)
    if order == "ASC", do: Enum.reverse(rows), else: rows
  end

  defp from_us(us), do: DateTime.from_unix!(us, :microsecond)

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
