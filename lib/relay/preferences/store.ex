defmodule Relay.Preferences.Store do
  @moduledoc """
  Data access of categories, sub-tenant category settings, preferences, preference profiles, the consent copy and suppressions. Writes call the `relay_fn.category_*`, `relay_fn.preference_*`, `relay_fn.consent_record` and `relay_fn.suppression_*` functions; reads select the rows of the established scope. Every function except `in_scope/2` runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Actor
  alias Relay.Repo

  @type digest :: <<_::256>>

  @category_columns """
  c.id, c.key, c.name, c.message_class::text AS message_class, c.locked, c.enabled,
  c.channel_defaults, c.default_expires_in, c.frequency_limit, c.frequency_window,
  c.frequency_fate, c.digest_allowed, c.builtin, c.state, c.archived_at, c.version,
  c.created_at, c.updated_at
  """

  @setting_columns """
  x.id, x.enabled, x.channel_defaults, x.default_expires_in, x.frequency_limit,
  x.frequency_window, x.frequency_fate, x.version, x.created_at, x.updated_at
  """

  @suppression_columns """
  s.id, s.channel::text AS channel, s.reason, s.expires_at, s.created_at, s.lifted_at,
  s.lifted_by_ref, s.lift_reason, s.updated_at
  """

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  # PC-57 (1)
  @doc "Creates a category."
  @spec category_create(map(), digest(), Actor.t()) ::
          {atom(), Relay.Id.t() | nil, pos_integer() | nil}
  def category_create(attrs, digest, %Actor{} = actor) do
    params =
      Enum.concat([
        [attrs.id, attrs.key, attrs.name, attrs.message_class, attrs.locked, attrs.enabled],
        [attrs.channel_defaults | settings(attrs)],
        [attrs.digest_allowed, digest],
        Actor.params(actor)
      ])

    [row] = Repo.call!("relay_fn.category_create", params)

    {Repo.code!(row["result"], [
       :created,
       :key_conflict,
       :tenant_inactive,
       :lock_not_allowed,
       :default_forbidden,
       :invalid_settings
     ]), row["category_id"], row["version"]}
  end

  # PC-57 (1)
  # PC-11
  @doc "Writes every field of a category under its version."
  @spec category_update(String.t(), map(), pos_integer() | nil, digest(), Actor.t()) ::
          {atom(), pos_integer() | nil}
  def category_update(key, attrs, expected_version, digest, %Actor{} = actor) do
    params =
      Enum.concat([
        [key, attrs.name, attrs.locked, attrs.enabled, attrs.channel_defaults],
        settings(attrs),
        [attrs.digest_allowed, expected_version, digest],
        Actor.params(actor)
      ])

    [row] = Repo.call!("relay_fn.category_update", params)

    {Repo.code!(row["result"], [
       :updated,
       :unchanged,
       :not_found,
       :archived,
       :version_conflict,
       :lock_not_allowed,
       :default_forbidden,
       :invalid_settings
     ]), row["version"]}
  end

  # PC-57 (1)
  @doc "Archives a category."
  @spec category_archive(String.t(), digest(), Actor.t()) :: {atom(), pos_integer() | nil}
  def category_archive(key, digest, %Actor{} = actor) do
    [row] = Repo.call!("relay_fn.category_archive", [key, digest] ++ Actor.params(actor))

    {Repo.code!(row["result"], [:archived, :already_archived, :builtin, :not_found]),
     row["version"]}
  end

  # PC-57 (2)
  @doc "Replaces the overrides of a category for one sub-tenant."
  @spec subtenant_put(Relay.Id.t(), String.t(), Relay.Id.t(), map(), digest(), Actor.t()) ::
          {atom(), pos_integer() | nil}
  def subtenant_put(id, key, subtenant_id, attrs, digest, %Actor{} = actor) do
    params =
      Enum.concat([
        [id, key, subtenant_id, attrs.enabled, attrs.channel_defaults],
        settings(attrs),
        [digest],
        Actor.params(actor)
      ])

    [row] = Repo.call!("relay_fn.category_subtenant_put", params)

    {Repo.code!(row["result"], [
       :created,
       :updated,
       :unchanged,
       :not_found,
       :archived,
       :subtenant_not_found,
       :default_forbidden,
       :invalid_settings,
       :lock_not_allowed
     ]), row["version"]}
  end

  defp settings(attrs) do
    frequency = Map.get(attrs, :frequency) || %{}
    [Map.get(attrs, :default_expires_in), frequency[:limit], frequency[:window], frequency[:fate]]
  end

  @doc "Reads a category by key, or `nil`."
  @spec category(String.t()) :: map() | nil
  def category(key) do
    one("SELECT #{@category_columns} FROM relay.categories c WHERE c.key = $1", [key])
  end

  # API-56
  @doc "Lists categories newest first, after or before a cursor position."
  @spec categories(map() | nil, pos_integer()) :: [map()]
  def categories(cursor, limit) do
    page("relay.categories c", @category_columns, "c", "TRUE", [], cursor, limit)
  end

  @doc "Whether a sub-tenant exists in the established scope."
  @spec subtenant?(Relay.Id.t()) :: boolean()
  def subtenant?(subtenant_id) do
    one("SELECT 1 AS found FROM relay.subtenants s WHERE s.id = $1", [subtenant_id]) != nil
  end

  @doc "Reads the overrides of a category for one sub-tenant, or `nil`."
  @spec subtenant_setting(Relay.Id.t(), Relay.Id.t()) :: map() | nil
  def subtenant_setting(category_id, subtenant_id) do
    one(
      """
      SELECT #{@setting_columns} FROM relay.category_subtenant_settings x
      WHERE x.category_id = $1 AND x.subtenant_id = $2
      """,
      [category_id, subtenant_id]
    )
  end

  # PC-57 (5)
  # PC-15
  # PC-6
  @doc "Writes one preference switch."
  @spec preference_set(map(), String.t(), String.t() | nil) ::
          {atom(), Relay.Id.t() | nil, pos_integer() | nil}
  def preference_set(write, writer, actor_ref) do
    [row] =
      Repo.call!("relay_fn.preference_set", [
        Relay.Id.generate(),
        write.recipient_id,
        write.level,
        write.key,
        write.channel,
        write.value,
        writer,
        actor_ref
      ])

    {Repo.code!(row["result"], [
       :set,
       :unchanged,
       :direction_forbidden,
       :recipient_not_found,
       :category_not_found,
       :last_channel
     ]), row["preference_id"], row["version"]}
  end

  # PC-57 (5)
  @doc "Writes the whole preference profile of a recipient."
  @spec profile_put(Relay.Id.t(), map(), String.t()) :: {atom(), pos_integer() | nil}
  def profile_put(recipient_id, profile, writer) do
    [row] =
      Repo.call!("relay_fn.preference_profile_put", [
        recipient_id,
        profile["quiet_hours"],
        profile["schedule"],
        profile["dnd_until"],
        profile["quiet_hours_email"],
        profile["digest"],
        writer,
        nil
      ])

    {Repo.code!(row["result"], [
       :created,
       :updated,
       :unchanged,
       :version_conflict,
       :writer_forbidden,
       :invalid_profile,
       :digest_not_allowed,
       :recipient_not_found
     ]), row["version"]}
  end

  @doc "Whether a recipient is an active subscriber of the established scope."
  @spec subscriber?(Relay.Id.t()) :: boolean()
  def subscriber?(recipient_id) do
    one(
      """
      SELECT 1 AS found FROM relay.recipients r
      WHERE r.id = $1 AND r.kind = 'subscriber' AND r.state = 'active'
      """,
      [recipient_id]
    ) != nil
  end

  # PC-12
  @doc "The category × channel cells of a recipient."
  @spec cells(Relay.Id.t()) :: [map()]
  def cells(recipient_id), do: Repo.call!("relay_fn.preference_cells", [recipient_id])

  # PC-57 (5)
  @doc "The channel, workflow and scope key switches of a recipient."
  @spec switches(Relay.Id.t()) :: [map()]
  def switches(recipient_id) do
    maps(
      Repo.scoped_query!(
        """
        SELECT p.level, p.key, p.channel::text AS channel, p.value FROM relay.preferences p
        WHERE p.recipient_id = $1 AND p.level IN ('channel', 'workflow', 'scope_key')
        ORDER BY p.level, p.key NULLS FIRST, p.channel NULLS FIRST
        """,
        [recipient_id]
      )
    )
  end

  @doc "The preference profile of a recipient, or `nil`."
  @spec profile(Relay.Id.t()) :: map() | nil
  def profile(recipient_id) do
    one(
      """
      SELECT p.quiet_hours, p.schedule, p.dnd_until, p.quiet_hours_email, p.digest, p.version
      FROM relay.preference_profiles p WHERE p.recipient_id = $1
      """,
      [recipient_id]
    )
  end

  # PC-59 (1)
  # E-80
  @doc "Records a consent copy row; an older or repeated source sequence changes nothing."
  @spec consent_record(map()) :: {atom(), Relay.Id.t() | nil}
  def consent_record(c) do
    [row] =
      Repo.call!("relay_fn.consent_record", [
        Relay.Id.generate(),
        c.recipient_id,
        c.brand_subtenant_id,
        c.channel,
        c.status,
        c.consent_kind,
        c.recipient_type,
        c.source,
        c.sequence,
        c.occurred_at,
        c.text_version_digest,
        c.evidence_ct,
        c.evidence_key_id,
        c.iys_transaction_ref,
        "access",
        c.source_event_ref
      ])

    {Repo.code!(row["result"], [
       :recorded,
       :duplicate,
       :stale,
       :evidence_required,
       :recipient_not_found,
       :subtenant_not_found,
       :evidence_key_invalid
     ]), row["consent_id"]}
  end

  # PC-21
  @doc "The current consent of a recipient per brand and channel."
  @spec consents(Relay.Id.t()) :: [map()]
  def consents(recipient_id), do: Repo.call!("relay_fn.consent_current", [recipient_id])

  # PC-59 (1)
  @doc "The identifier of a recipient's active `commercial_consent` subject key, or `nil`."
  @spec consent_key(Relay.Id.t()) :: Relay.Id.t() | nil
  def consent_key(recipient_id) do
    sql = """
    SELECT k.id FROM relay.subject_keys k
    WHERE k.recipient_id = $1 AND k.retention_class = 'commercial_consent' AND k.state = 'active'
    """

    case one(sql, [recipient_id]) do
      %{"id" => id} -> id
      nil -> nil
    end
  end

  # OP-18
  @doc "Registers the `commercial_consent` subject key of a recipient."
  @spec consent_key_create(Relay.Id.t(), Relay.Id.t(), binary(), Relay.Id.t()) ::
          {atom(), Relay.Id.t() | nil}
  def consent_key_create(id, recipient_id, wrapped_dek, wrapping_key_id) do
    [row] =
      Repo.call!("relay_fn.subject_key_create", [
        id,
        recipient_id,
        "commercial_consent",
        wrapped_dek,
        wrapping_key_id
      ])

    {Repo.code!(row["result"], [:created, :exists, :recipient_not_found, :recipient_deleted]),
     row["subject_key_id"]}
  end

  # PC-59 (2)
  @doc "Adds a suppression; an equal active one is returned instead."
  @spec suppression_add(map(), digest(), Actor.t()) :: {atom(), Relay.Id.t() | nil}
  def suppression_add(s, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.suppression_add",
        [
          Relay.Id.generate(),
          s.channel,
          s.target_digest,
          s.target_digest_key_id,
          s.target_digest_next,
          s.reason,
          s.expires_at,
          digest
        ] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], [:added, :exists, :invalid_expiry, :key_not_found]),
     row["suppression_id"]}
  end

  # PC-59 (2)
  @doc "Lifts a suppression; `lift` carries `:lifter` (`tenant` or `operator`), `:step_up_ref` and `:reason`."
  @spec suppression_lift(Relay.Id.t(), map(), digest(), Actor.t()) :: atom()
  def suppression_lift(id, lift, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.suppression_lift",
        [id, lift.lifter, lift.step_up_ref, lift.reason, digest] ++ Actor.params(actor)
      )

    Repo.code!(row["result"], [
      :lifted,
      :already_lifted,
      :not_found,
      :lift_forbidden,
      :step_up_required
    ])
  end

  @doc "Reads a suppression, or `nil`."
  @spec suppression(Relay.Id.t()) :: map() | nil
  def suppression(id) do
    one("SELECT #{@suppression_columns} FROM relay.suppressions s WHERE s.id = $1", [id])
  end

  # API-56
  @doc "Lists suppressions newest first with optional `channel`, `reason` and `state` filters."
  @spec suppressions(map(), map() | nil, pos_integer()) :: [map()]
  def suppressions(filters, cursor, limit) do
    {conditions, params} =
      Enum.reduce([:channel, :reason, :state], {[], []}, fn name, {conditions, params} ->
        case Map.get(filters, name) do
          nil -> {conditions, params}
          value -> {[filter(name, length(params) + 1) | conditions], params ++ [value]}
        end
      end)

    where = if conditions == [], do: "TRUE", else: Enum.join(Enum.reverse(conditions), " AND ")
    page("relay.suppressions s", @suppression_columns, "s", where, params, cursor, limit)
  end

  defp filter(:channel, n), do: "s.channel::text = $#{n}"
  defp filter(:reason, n), do: "s.reason = $#{n}"

  defp filter(:state, n) do
    """
    (CASE WHEN s.lifted_at IS NOT NULL THEN 'lifted'
      WHEN s.expires_at IS NOT NULL AND s.expires_at <= now() THEN 'expired'
      ELSE 'active' END) = $#{n}
    """
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

    rows = maps(Repo.scoped_query!(sql, params))
    if order == "ASC", do: Enum.reverse(rows), else: rows
  end

  defp from_us(us), do: DateTime.from_unix!(us, :microsecond)

  defp one(sql, params) do
    case maps(Repo.scoped_query!(sql, params)) do
      [row] -> row
      [] -> nil
    end
  end

  defp maps(%Postgrex.Result{columns: columns, rows: rows}),
    do: Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
end
