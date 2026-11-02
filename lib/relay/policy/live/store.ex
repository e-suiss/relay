defmodule Relay.Policy.Live.Store do
  @moduledoc """
  Data access of the running policy lattice: the inputs of one evaluation (the delivery and its notification, the category with its sub-tenant setting, the recipient's preferences and profile, the consent copy, the address and its suppression, the tenant's zone and the sub-tenant's state) and the decision records. Every function except `in_scope/2` runs inside `Relay.Repo.in_scope/3`; the decision is written by `relay_fn.delivery_decide`, which writes the ledger event and, for a skip or an expiry, the `notification.suppressed` outbox event in the same transaction.
  """

  alias Relay.Repo

  @context """
  SELECT d.id, d.channel::text AS channel, d.decision, d.provider_account_id,
    n.id AS notification_id, n.recipient_id, n.subtenant_id, n.message_class::text AS message_class,
    n.security_subtype, n.sender_type, n.expires_at, n.workflow_id, e.priority, e.api_client_id,
    w.key AS workflow_key, v.category AS category_key
  FROM relay.deliveries d
  JOIN relay.notifications n ON n.tenant_id = d.tenant_id AND n.environment = d.environment
    AND n.id = d.notification_id
  LEFT JOIN relay.events e ON e.tenant_id = n.tenant_id AND e.environment = n.environment
    AND e.id = n.event_id
  LEFT JOIN relay.workflows w ON w.tenant_id = n.tenant_id AND w.environment = n.environment
    AND w.id = n.workflow_id
  LEFT JOIN relay.workflow_versions v ON v.tenant_id = n.tenant_id
    AND v.environment = n.environment AND v.id = n.workflow_version_id
  WHERE d.id = $1
  """

  @category """
  SELECT c.key, c.message_class::text AS message_class, c.locked, c.enabled, c.channel_defaults,
    (extract(epoch FROM c.default_expires_in) * 1000)::bigint AS default_expires_ms,
    c.frequency_limit, (extract(epoch FROM c.frequency_window) * 1000)::bigint AS frequency_window_ms,
    c.frequency_fate, c.digest_allowed, s.id AS setting_id, s.enabled AS setting_enabled,
    s.channel_defaults AS setting_channel_defaults,
    (extract(epoch FROM s.default_expires_in) * 1000)::bigint AS setting_default_expires_ms,
    s.frequency_limit AS setting_frequency_limit,
    (extract(epoch FROM s.frequency_window) * 1000)::bigint AS setting_frequency_window_ms,
    s.frequency_fate AS setting_frequency_fate
  FROM relay.categories c
  LEFT JOIN relay.category_subtenant_settings s ON s.tenant_id = c.tenant_id
    AND s.environment = c.environment AND s.category_id = c.id AND s.subtenant_id = $2
  WHERE c.key = $1
  """

  @preferences """
  SELECT p.level, p.value FROM relay.preferences p
  WHERE p.recipient_id = $1 AND (
    (p.level = 'category_channel' AND p.key = $2 AND p.channel::text = $3)
    OR (p.level = 'channel' AND p.key IS NULL AND p.channel::text = $3)
    OR (p.level = 'workflow' AND p.key = $4 AND (p.channel IS NULL OR p.channel::text = $3))
    OR (p.level = 'scope_key' AND p.key = $5 AND (p.channel IS NULL OR p.channel::text = $3)))
  """

  @profile """
  SELECT p.quiet_hours, p.schedule, p.dnd_until, p.quiet_hours_email, p.digest
  FROM relay.preference_profiles p WHERE p.recipient_id = $1
  """

  @recipient "SELECT r.timezone FROM relay.recipients r WHERE r.id = $1"

  @address """
  SELECT a.state, a.address_bidx, a.address_bidx_next FROM relay.recipient_addresses a
  WHERE a.recipient_id = $1 AND a.kind = $2 AND a.state IN ('active', 'disabled')
  ORDER BY (a.state = 'active') DESC LIMIT 1
  """

  @tenant "SELECT t.default_timezone FROM relay.tenants t WHERE t.id = $1"

  @subtenant "SELECT s.state FROM relay.subtenants s WHERE s.id = $1"

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  @doc "The delivery, its notification, event and workflow reference, or `nil`."
  @spec context(Relay.Id.t()) :: map() | nil
  def context(delivery_id), do: one(@context, [delivery_id])

  # PC-57 (1)
  # PC-57 (2)
  @doc "The category of `key` with the setting of `subtenant_id` beside it, or `nil`."
  @spec category(String.t(), Relay.Id.t() | nil) :: map() | nil
  def category(key, subtenant_id), do: one(@category, [key, subtenant_id])

  # PC-12
  # PC-57 (5)
  @doc "The recipient's preference values for a category, channel, workflow and scope key."
  @spec preferences(Relay.Id.t(), String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          [map()]
  def preferences(recipient_id, category_key, channel, workflow_key, scope_key),
    do: all(@preferences, [recipient_id, category_key, channel, workflow_key, scope_key])

  # PC-57 (5)
  @doc "The recipient's preference profile, or `nil`."
  @spec profile(Relay.Id.t()) :: map() | nil
  def profile(recipient_id), do: one(@profile, [recipient_id])

  @doc "The time zone of the recipient's profile, or `nil`."
  @spec recipient_time_zone(Relay.Id.t()) :: String.t() | nil
  def recipient_time_zone(recipient_id) do
    case one(@recipient, [recipient_id]) do
      %{"timezone" => zone} -> zone
      nil -> nil
    end
  end

  # PC-59 (1)
  @doc "The current consent states of a recipient per brand and channel."
  @spec consents(Relay.Id.t()) :: [map()]
  def consents(recipient_id), do: Repo.call!("relay_fn.consent_current", [recipient_id])

  @doc "The recipient's active or disabled address of `kind`, or `nil`."
  @spec address(Relay.Id.t(), String.t()) :: map() | nil
  def address(recipient_id, kind), do: one(@address, [recipient_id, kind])

  # PC-59 (2)
  @doc "The suppressions in force for any of `digests` on `channel`."
  @spec suppressions(String.t(), [binary()]) :: [map()]
  def suppressions(_channel, []), do: []

  def suppressions(channel, digests),
    do: Repo.call!("relay_fn.suppression_match", [channel, digests])

  @doc "The tenant's default time zone."
  @spec tenant_time_zone(Relay.Id.t()) :: String.t() | nil
  def tenant_time_zone(tenant_id) do
    case one(@tenant, [tenant_id]) do
      %{"default_timezone" => zone} -> zone
      nil -> nil
    end
  end

  @doc "The state of a sub-tenant, or `nil`."
  @spec subtenant_state(Relay.Id.t()) :: String.t() | nil
  def subtenant_state(subtenant_id) do
    case one(@subtenant, [subtenant_id]) do
      %{"state" => state} -> state
      nil -> nil
    end
  end

  # PC-58 (2)
  # DS-24
  # DS-27
  @doc "Records a lattice decision on a delivery; see `relay_fn.delivery_decide`."
  @spec decide(
          Relay.Id.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil,
          DateTime.t() | nil,
          map() | nil
        ) :: :recorded | :unchanged | :paused | :already_terminal | :not_found
  def decide(delivery_id, decision, reason, rule_id, deferred_until, detail) do
    [row] =
      Repo.call!("relay_fn.delivery_decide", [
        delivery_id,
        decision,
        reason,
        rule_id,
        deferred_until,
        detail
      ])

    Repo.code!(row["delivery_decide"], [
      :recorded,
      :unchanged,
      :paused,
      :already_terminal,
      :not_found
    ])
  end

  # TN-40
  @doc "Pauses a delivery a kill switch matches."
  @spec pause(Relay.Id.t(), String.t(), Relay.Id.t()) ::
          :paused | :already_paused | :already_terminal | :not_found
  def pause(delivery_id, rule_id, kill_switch_id) do
    [row] = Repo.call!("relay_fn.delivery_pause", [delivery_id, rule_id, kill_switch_id])
    Repo.code!(row["delivery_pause"], [:paused, :already_paused, :already_terminal, :not_found])
  end

  defp one(sql, params) do
    case all(sql, params) do
      [row] -> row
      [] -> nil
    end
  end

  defp all(sql, params) do
    %Postgrex.Result{columns: columns, rows: rows} = Repo.scoped_query!(sql, params)
    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end
end
