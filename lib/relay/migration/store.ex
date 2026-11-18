defmodule Relay.Migration.Store do
  @moduledoc """
  Data access of the migration modes (OP-52 … OP-54, OP-94, OP-95): the shadow day keys, comparisons and intentional differences, the staged rollout configuration, the dedup claims and the shadow flag of webhook endpoints. Writes go through `relay_fn` functions; every function except `in_scope/2` runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Actor
  alias Relay.Repo

  @decision_fields ~w(recipients decision consent timing dedup_key schedule)
  @difference_columns "tenant_id, environment, id, layer, field, template_key, channel::text AS channel, owner, reason, expires_at, renewals, created_at, updated_at"
  @comparison_columns "tenant_id, environment, id, correlation_id, channel::text AS channel, recipient_id, key_id, template_key, locale, legacy_ct, relay_ct, delivery_ct, state, created_at"
  @rollout_columns "tenant_id, environment, emergency_stop, configured, stopped_at, stop_reason, relay_list, legacy_list, enabled_categories, basis_points, steps, generation, updated_at"

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  # OP-94
  @doc "The shadow day key of a day, `nil` when there is none."
  @spec shadow_key(Date.t()) :: map() | nil
  def shadow_key(%Date{} = day) do
    """
    SELECT tenant_id, environment, id, key_day, wrapped_dek, wrapping_key_id, state
    FROM relay.shadow_keys WHERE key_day = $1
    """
    |> all([day])
    |> List.first()
  end

  # OP-94
  @doc "The shadow day key with this identifier, `nil` when there is none."
  @spec shadow_key_by_id(Relay.Id.t()) :: map() | nil
  def shadow_key_by_id(key_id) do
    """
    SELECT tenant_id, environment, id, key_day, wrapped_dek, wrapping_key_id, state
    FROM relay.shadow_keys WHERE id = $1
    """
    |> all([key_id])
    |> List.first()
  end

  # OP-94
  @doc "Registers the shadow day key of a day, or returns the one that exists."
  @spec shadow_key_create(Relay.Id.t(), Date.t(), binary(), Relay.Id.t()) ::
          {:created | :exists, Relay.Id.t()}
  def shadow_key_create(id, day, wrapped, wrapping_key_id) do
    [row] = Repo.call!("relay_fn.shadow_key_create", [id, day, wrapped, wrapping_key_id])
    {Repo.code!(row["result"], [:created, :exists]), row["shadow_key_id"]}
  end

  # OP-52 (5)
  # OP-94
  @doc "Destroys a past shadow day key, audited."
  @spec shadow_key_destroy(Relay.Id.t(), <<_::256>>, Actor.t()) ::
          :destroyed | :already_destroyed | :not_allowed | :not_found
  def shadow_key_destroy(key_id, digest, %Actor{} = actor) do
    [row] = Repo.call!("relay_fn.shadow_key_destroy", [key_id, digest | Actor.params(actor)])

    Repo.code!(row["shadow_key_destroy"], [
      :destroyed,
      :already_destroyed,
      :not_allowed,
      :not_found
    ])
  end

  # OP-94
  @doc "The comparison of a request, channel and recipient, `nil` when there is none."
  @spec comparison(String.t(), String.t(), Relay.Id.t()) :: map() | nil
  def comparison(correlation_id, channel, recipient_id) do
    """
    SELECT #{@comparison_columns} FROM relay.shadow_comparisons
    WHERE correlation_id = $1 AND channel = $2 AND recipient_id = $3
    """
    |> all([correlation_id, channel, recipient_id])
    |> List.first()
  end

  # OP-94
  @doc "The comparisons of a request."
  @spec comparisons(String.t()) :: [map()]
  def comparisons(correlation_id) do
    all(
      "SELECT #{@comparison_columns} FROM relay.shadow_comparisons WHERE correlation_id = $1",
      [correlation_id]
    )
  end

  # OP-94
  @doc "The comparisons still waiting for Relay's decision, oldest first, at most `limit`."
  @spec pending_comparisons(pos_integer()) :: [map()]
  def pending_comparisons(limit) do
    """
    SELECT #{@comparison_columns} FROM relay.shadow_comparisons
    WHERE state = 'pending' AND legacy_ct IS NOT NULL AND relay_ct IS NULL
      AND created_at >= now() - interval '1 hour'
    ORDER BY created_at LIMIT $1
    """
    |> all([limit])
  end

  # OP-94
  @doc "Records one side of a comparison sealed under `key_id`."
  @spec shadow_side_record(map()) :: {:recorded | :unchanged | :key_mismatch, Relay.Id.t()}
  def shadow_side_record(attrs) do
    [row] =
      Repo.call!("relay_fn.shadow_side_record", [
        attrs.id,
        attrs.correlation_id,
        attrs.channel,
        attrs.recipient_id,
        attrs.key_id,
        Atom.to_string(attrs.side),
        attrs.template_key,
        attrs.locale,
        attrs.ct
      ])

    {Repo.code!(row["result"], [:recorded, :unchanged, :key_mismatch]), row["comparison_id"]}
  end

  # OP-52 (4)
  # OP-94
  @doc "Sets the outcome of a comparison."
  @spec shadow_compare_set(Relay.Id.t(), map()) :: :set | :not_found
  def shadow_compare_set(id, outcome) do
    [row] =
      Repo.call!("relay_fn.shadow_compare_set", [
        id,
        Atom.to_string(outcome.state),
        outcome.decision_match,
        outcome.content_match,
        outcome.routing_match,
        outcome.differing,
        outcome.unpermitted
      ])

    Repo.code!(row["shadow_compare_set"], [:set, :not_found])
  end

  # OP-94
  @doc "Relay's deliveries of the events with a correlation identifier: per delivery its channel, recipient, decision, rule, deferral, the event's dedup key and send time, and the pinned template and locale."
  @spec relay_decisions(String.t()) :: [map()]
  def relay_decisions(correlation_id) do
    """
    SELECT d.tenant_id, d.environment, d.id, d.channel::text AS channel, d.recipient_id,
      d.decision, d.decision_rule_id, d.deferred_until, e.dedup_key, e.send_at,
      t.key AS template_key, p.locale
    FROM relay.events e
    JOIN relay.notifications n ON n.tenant_id = e.tenant_id AND n.environment = e.environment
      AND n.event_id = e.id
    JOIN relay.deliveries d ON d.tenant_id = n.tenant_id AND d.environment = n.environment
      AND d.notification_id = n.id
    LEFT JOIN relay.delivery_render_plans p ON p.tenant_id = d.tenant_id
      AND p.environment = d.environment AND p.delivery_id = d.id
    LEFT JOIN relay.templates t ON t.tenant_id = p.tenant_id AND t.environment = p.environment
      AND t.id = p.template_id
    WHERE e.correlation_id = $1
    ORDER BY d.created_at, d.id
    """
    |> all([correlation_id])
  end

  # OP-94
  @doc "The correlation identifier of a delivery's event, its recipient and channel, and the pinned template and locale; `nil` without a correlation identifier."
  @spec delivery_request(Relay.Id.t()) :: map() | nil
  def delivery_request(delivery_id) do
    """
    SELECT d.tenant_id, d.environment, e.correlation_id, d.channel::text AS channel,
      d.recipient_id, t.key AS template_key, p.locale
    FROM relay.deliveries d
    JOIN relay.notifications n ON n.tenant_id = d.tenant_id AND n.environment = d.environment
      AND n.id = d.notification_id
    JOIN relay.events e ON e.tenant_id = n.tenant_id AND e.environment = n.environment
      AND e.id = n.event_id
    LEFT JOIN relay.delivery_render_plans p ON p.tenant_id = d.tenant_id
      AND p.environment = d.environment AND p.delivery_id = d.id
    LEFT JOIN relay.templates t ON t.tenant_id = p.tenant_id AND t.environment = p.environment
      AND t.id = p.template_id
    WHERE d.id = $1 AND e.correlation_id IS NOT NULL
    """
    |> all([delivery_id])
    |> List.first()
  end

  # OP-79
  # OP-94
  @doc "The coverage rows of the last `window_days` days: per template, locale and channel the counts of compared requests and of their differences, a difference explained when an active intentional difference covers it; and the first comparison ever made."
  @spec coverage(pos_integer(), pos_integer()) :: %{rows: [map()], first_at: DateTime.t() | nil}
  def coverage(window_days, grace_s) do
    rows =
      """
      WITH active AS (
        SELECT layer, field, template_key, channel FROM relay.shadow_differences
        WHERE expires_at > now()
      ),
      compared AS (
        SELECT c.template_key, c.locale, c.channel,
          CASE WHEN c.state = 'pending' THEN ARRAY['recipients']::text[]
            ELSE c.differing END AS differing
        FROM relay.shadow_comparisons c
        WHERE c.created_at >= now() - $1::bigint * interval '1 day'
          AND (c.state <> 'pending' OR c.created_at < now() - $2::bigint * interval '1 second')
      ),
      judged AS (
        SELECT r.*,
          r.differing && $3::text[] AS decision_differs,
          EXISTS (SELECT 1 FROM unnest(r.differing) f
            WHERE f = ANY ($3::text[]) AND NOT EXISTS (SELECT 1 FROM active a
              WHERE a.layer = 'decision' AND (a.field IS NULL OR a.field = f)
                AND (a.template_key IS NULL OR a.template_key = r.template_key)
                AND (a.channel IS NULL OR a.channel = r.channel))) AS unexplained,
          EXISTS (SELECT 1 FROM unnest(r.differing) f
            WHERE f = 'content' AND NOT EXISTS (SELECT 1 FROM active a
              WHERE a.layer = 'content' AND (a.template_key IS NULL OR a.template_key = r.template_key)
                AND (a.channel IS NULL OR a.channel = r.channel))) AS content_differs,
          EXISTS (SELECT 1 FROM unnest(r.differing) f
            WHERE f IN ('provider', 'sender') AND NOT EXISTS (SELECT 1 FROM active a
              WHERE a.layer = 'routing' AND (a.field IS NULL OR a.field = f)
                AND (a.template_key IS NULL OR a.template_key = r.template_key)
                AND (a.channel IS NULL OR a.channel = r.channel))) AS routing_differs
        FROM compared r
      )
      SELECT COALESCE(template_key, '') AS template, COALESCE(locale, '') AS locale,
        channel::text AS channel, count(*) AS observed,
        count(*) FILTER (WHERE decision_differs) AS decision_differences,
        count(*) FILTER (WHERE decision_differs AND NOT unexplained) AS explained,
        count(*) FILTER (WHERE unexplained) AS unexplained,
        count(*) FILTER (WHERE content_differs) AS content_differences,
        count(*) FILTER (WHERE routing_differs) AS routing_differences
      FROM judged
      GROUP BY 1, 2, 3
      ORDER BY 1, 2, 3
      """
      |> all([window_days, grace_s, @decision_fields])

    [first] = all("SELECT min(created_at) AS first_at FROM relay.shadow_comparisons", [])
    %{rows: rows, first_at: first["first_at"]}
  end

  # OP-52 (3)
  # OP-79
  @doc "The number of active intentional differences."
  @spec active_differences() :: non_neg_integer()
  def active_differences do
    [row] =
      all(
        "SELECT count(*) AS active FROM relay.shadow_differences WHERE expires_at > now()",
        []
      )

    row["active"]
  end

  # OP-79
  @doc "Intentional differences after a cursor identifier, newest first, at most `limit`."
  @spec differences(Relay.Id.t() | nil, pos_integer()) :: [map()]
  def differences(after_id, limit) do
    """
    SELECT #{@difference_columns}, expires_at > now() AS active
    FROM relay.shadow_differences
    WHERE ($1::uuid IS NULL OR id < $1)
    ORDER BY id DESC LIMIT $2
    """
    |> all([after_id, limit])
  end

  # OP-79
  @doc "One intentional difference, `nil` when there is none."
  @spec difference(Relay.Id.t()) :: map() | nil
  def difference(id) do
    """
    SELECT #{@difference_columns}, expires_at > now() AS active
    FROM relay.shadow_differences WHERE id = $1
    """
    |> all([id])
    |> List.first()
  end

  # OP-52 (3)
  # OP-79
  @doc "Records an intentional difference, audited."
  @spec difference_create(map(), <<_::256>>, Actor.t()) :: :created | :exists | :invalid_expiry
  def difference_create(attrs, digest, %Actor{} = actor) do
    params =
      [
        attrs.id,
        attrs.layer,
        attrs.field,
        attrs.template_key,
        attrs.channel,
        attrs.owner,
        attrs.reason,
        attrs.expires_at,
        digest
      ] ++ Actor.params(actor)

    [row] = Repo.call!("relay_fn.shadow_difference_create", params)
    Repo.code!(row["shadow_difference_create"], [:created, :exists, :invalid_expiry])
  end

  # OP-79
  @doc "Moves the expiry of an intentional difference, audited."
  @spec difference_renew(Relay.Id.t(), DateTime.t(), String.t(), <<_::256>>, Actor.t()) ::
          :renewed | :not_found | :invalid_expiry
  def difference_renew(id, expires_at, reason, digest, %Actor{} = actor) do
    params = [id, expires_at, reason, digest | Actor.params(actor)]
    [row] = Repo.call!("relay_fn.shadow_difference_renew", params)
    Repo.code!(row["shadow_difference_renew"], [:renewed, :not_found, :invalid_expiry])
  end

  # OP-95
  @doc "The rollout configuration of the established scope, `nil` when none is set."
  @spec rollout() :: map() | nil
  def rollout do
    "SELECT #{@rollout_columns} FROM relay.rollout_configs"
    |> all([])
    |> List.first()
  end

  # OP-53
  # OP-95
  @doc "Replaces the rollout configuration when its generation is still `expected`, audited."
  @spec rollout_put(map(), non_neg_integer(), <<_::256>>, Actor.t()) ::
          {:updated | :version_conflict, non_neg_integer()}
  def rollout_put(config, expected, digest, %Actor{} = actor) do
    params =
      [
        config.relay_list,
        config.legacy_list,
        config.enabled_categories,
        config.basis_points,
        config.steps,
        expected,
        digest
      ] ++ Actor.params(actor)

    [row] = Repo.call!("relay_fn.rollout_put", params)
    {Repo.code!(row["result"], [:updated, :version_conflict]), row["generation"]}
  end

  # OP-53
  # OP-95
  @doc "Stops the rollout and opens the incident record, both audited."
  @spec rollout_stop(String.t(), <<_::256>>, <<_::256>>, Actor.t()) ::
          {:stopped | :already_stopped, non_neg_integer()}
  def rollout_stop(reason, incident, digest, %Actor{} = actor) do
    params = [reason, incident, digest | Actor.params(actor)]
    [row] = Repo.call!("relay_fn.rollout_emergency_stop", params)
    {Repo.code!(row["result"], [:stopped, :already_stopped]), row["generation"]}
  end

  # OP-53
  @doc "Releases the emergency stop, audited."
  @spec rollout_release(String.t(), <<_::256>>, Actor.t()) ::
          {:released | :not_stopped, non_neg_integer()}
  def rollout_release(reason, digest, %Actor{} = actor) do
    params = [reason, digest | Actor.params(actor)]
    [row] = Repo.call!("relay_fn.rollout_emergency_release", params)
    {Repo.code!(row["result"], [:released, :not_stopped]), row["generation"]}
  end

  # OP-54
  # OP-95
  @doc "Claims a dedup key for the system being replaced, unless an unexpired claim or a Relay notification holds it."
  @spec dedup_claim(String.t(), pos_integer()) ::
          {:claimed | :duplicate, String.t(), DateTime.t() | nil}
  def dedup_claim(key, ttl_s) do
    [row] = Repo.call!("relay_fn.dedup_claim", [key, ttl_s])
    {Repo.code!(row["result"], [:claimed, :duplicate]), row["claimed_by"], row["expires_at"]}
  end

  # OP-54
  @doc "True while the system being replaced holds an unexpired claim on a dedup key; it locks the key until the caller's transaction ends."
  @spec dedup_claim_held?(String.t()) :: boolean()
  def dedup_claim_held?(key) do
    [row] = Repo.call!("relay_fn.dedup_claim_held", [key])
    row["dedup_claim_held"] == true
  end

  # OP-52 (1)
  # OP-94
  @doc "Marks a webhook endpoint as the shadow endpoint or as a live one, audited."
  @spec webhook_shadow_set(Relay.Id.t(), boolean(), <<_::256>>, Actor.t()) ::
          :set | :unchanged | :not_found | :archived
  def webhook_shadow_set(endpoint_id, shadow, digest, %Actor{} = actor) do
    params = [endpoint_id, shadow, digest | Actor.params(actor)]
    [row] = Repo.call!("relay_fn.webhook_endpoint_shadow_set", params)

    Repo.code!(row["webhook_endpoint_shadow_set"], [:set, :unchanged, :not_found, :archived])
  end

  defp all(sql, params) do
    %Postgrex.Result{columns: columns, rows: rows} = Repo.scoped_query!(sql, params)
    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end
end
