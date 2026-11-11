defmodule Relay.Channels.Live.Store do
  @moduledoc """
  Data access of the channel step of the delivery job: the delivery with its notification and event, the send mode settings, and the recipient's active address. Every function except `in_scope/2` runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Repo

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  # T-15
  @doc "Queues a job inside the current transaction; rolls the transaction back when it is not queued."
  @spec insert_job!(Ecto.Changeset.t()) :: :ok
  def insert_job!(changeset) do
    case Oban.insert(changeset) do
      {:ok, _job} -> :ok
      {:error, reason} -> Repo.rollback({:job_not_queued, reason})
    end
  end

  # T-15
  @doc "Reads what the channel step needs of a delivery: its channel, target kind and target (the one device of a test send), recipient, requested provider, class, `expires_at`, test flag, the requested send mode and priority of its event, its workflow's category, the notification's subject and, for the push policy, the pinned locale, the template's key and sensitivity, the category key, the sender's `interruption` and the Access client of the event's API client (the sender of a critical Grant question, CH-84), and for the channel overrides the event's sealed request overrides with their key and the pinned version's workflow overrides and steps; `nil` when there is no such delivery."
  @spec delivery(Relay.Id.t()) :: map() | nil
  def delivery(delivery_id) do
    one(
      """
      SELECT d.tenant_id, d.environment, d.id, d.channel::text AS channel, d.target_kind,
        d.target_id, d.recipient_id, d.provider, d.provider_account_id, d.traceparent, d.attempt_count,
        n.message_class::text AS message_class, n.expires_at, n.is_test, e.send_mode::text AS send_mode,
        e.priority, n.subject_type, n.subject_id, p.locale, t.key AS template_key,
        v.sensitivity, c.key AS category_key, wv.definition->>'category' AS category,
        e.interruption, ac.access_client_id AS sender_ref, ep.overrides_ct,
        ep.key_id AS payload_key_id, wv.definition->'overrides' AS workflow_overrides,
        wv.definition->'steps' AS steps
      FROM relay.deliveries d
      JOIN relay.notifications n ON n.tenant_id = d.tenant_id AND n.environment = d.environment
        AND n.id = d.notification_id
      LEFT JOIN relay.events e ON e.tenant_id = n.tenant_id AND e.environment = n.environment
        AND e.id = n.event_id
      LEFT JOIN relay.event_payloads ep ON ep.tenant_id = e.tenant_id
        AND ep.environment = e.environment AND ep.event_id = e.id
        AND ep.created_at = e.payload_created_at
      LEFT JOIN relay.delivery_render_plans p ON p.tenant_id = d.tenant_id
        AND p.environment = d.environment AND p.delivery_id = d.id
      LEFT JOIN relay.template_versions v ON v.tenant_id = p.tenant_id
        AND v.environment = p.environment AND v.id = p.template_version_id
      LEFT JOIN relay.templates t ON t.tenant_id = p.tenant_id AND t.environment = p.environment
        AND t.id = p.template_id
      LEFT JOIN relay.categories c ON c.tenant_id = t.tenant_id AND c.environment = t.environment
        AND c.id = t.category_id
      LEFT JOIN relay.workflow_versions wv ON wv.tenant_id = e.tenant_id
        AND wv.environment = e.environment AND wv.id = e.workflow_version_id
      LEFT JOIN relay.api_clients ac ON ac.tenant_id = e.tenant_id
        AND ac.environment = e.environment AND ac.id = e.api_client_id
      WHERE d.id = $1
      """,
      [delivery_id]
    )
  end

  # T-41
  @doc "Reads the attempt counts of the deliveries among `ids` as a map of delivery identifier to attempt count; an unknown delivery is absent."
  @spec delivery_attempts([Relay.Id.t()]) :: %{Relay.Id.t() => non_neg_integer()}
  def delivery_attempts(ids) do
    rows =
      all(
        "SELECT tenant_id, environment, id, attempt_count FROM relay.deliveries WHERE id = ANY($1::uuid[])",
        [ids]
      )

    Map.new(rows, &{&1["id"], &1["attempt_count"]})
  end

  # DS-48
  @doc "Reads up to `limit` open deliveries of a channel whose latest attempt went to `provider`, accepted at least `min_age_s` seconds ago and neither delivered nor failed, oldest first: each with its acceptance time and the provider account, attempt number, idempotency key and provider message id of the latest attempt."
  @spec open_deliveries(String.t(), String.t(), non_neg_integer(), pos_integer()) :: [map()]
  def open_deliveries(provider, channel, min_age_s, limit) do
    all(
      """
      SELECT d.tenant_id, d.environment, d.id, d.accepted_at, a.provider_account_id,
        a.attempt_no, a.provider_idempotency_key, a.provider_message_id
      FROM relay.deliveries d
      JOIN LATERAL (
        SELECT x.provider, x.provider_account_id, x.attempt_no, x.provider_idempotency_key,
          x.provider_message_id
        FROM relay.delivery_attempts x
        WHERE x.tenant_id = d.tenant_id AND x.environment = d.environment AND x.delivery_id = d.id
        ORDER BY x.attempt_no DESC
        LIMIT 1
      ) a ON a.provider = $1
      WHERE d.channel = $2::relay.channel AND d.delivery_rank = 1 AND d.failure_kind IS NULL
        AND d.accepted_at <= now() - $3::bigint * interval '1 second'
      ORDER BY d.accepted_at, d.id
      LIMIT $4
      """,
      [provider, channel, min_age_s, limit]
    )
  end

  # DS-48
  @doc "Reads the active, verified provider accounts of `provider` on `channel`: identifier, provider, settings and credential reference."
  @spec reconciled_accounts(String.t(), String.t()) :: [map()]
  def reconciled_accounts(provider, channel) do
    all(
      """
      SELECT tenant_id, environment, id, provider, channel::text AS channel, settings,
        credential_ref_id
      FROM relay.provider_accounts
      WHERE provider = $1 AND channel = $2::relay.channel AND state = 'active'
        AND verification_state = 'verified'
      ORDER BY id
      """,
      [provider, channel]
    )
  end

  # DS-48
  # TN-13 (4)
  @doc "Lists the scopes that have a verified provider account of `providers`, through the reconciliation discovery escape hatch; scopes only, no content."
  @spec reconciliation_scopes([String.t()], pos_integer()) :: [{Relay.Id.t(), String.t()}]
  def reconciliation_scopes(providers, limit) do
    function = "relay_ops.reconciliation_scopes"
    rows = Repo.call_unscoped!(:reconciliation_discovery, function, [providers, limit])
    for row <- rows, do: {row["tenant_id"], row["environment"]}
  end

  # T-15
  @doc "Rolls the current scoped transaction back with `reason`."
  @spec rollback(term()) :: no_return()
  def rollback(reason), do: Repo.rollback(reason)

  # API-62
  # OP-51
  @doc "Reads the tenant-level settings among `keys` as a map of key to value."
  @spec settings([String.t()]) :: %{String.t() => term()}
  def settings(keys) do
    rows =
      all(
        "SELECT tenant_id, environment, key, value FROM relay.settings WHERE subtenant_id IS NULL AND key = ANY($1::text[])",
        [keys]
      )

    Map.new(rows, &{&1["key"], &1["value"]})
  end

  # CH-28
  @doc "Reads the active address of `kind` (`email` or `phone`) of a recipient: its identifier, ciphertext and key; `nil` when there is none."
  @spec address(Relay.Id.t(), String.t()) :: map() | nil
  def address(recipient_id, kind) do
    one(
      "SELECT tenant_id, environment, id, address_ct, address_key_id FROM relay.recipient_addresses WHERE recipient_id = $1 AND kind = $2 AND state = 'active'",
      [recipient_id, kind]
    )
  end

  # PC-43
  @doc "The recipients with an active phone address among the address blind indexes `digests`."
  @spec phone_recipients([binary()]) :: [Relay.Id.t()]
  def phone_recipients(digests) do
    sql = """
    SELECT DISTINCT a.recipient_id FROM relay.recipient_addresses a
    WHERE a.kind = 'phone' AND a.state = 'active'
      AND (a.address_bidx = ANY ($1) OR a.address_bidx_next = ANY ($1))
    """

    for row <- all(sql, [digests]), do: row["recipient_id"]
  end

  # PC-43
  @doc "The keys of the active categories of the `marketing` class, in key order."
  @spec marketing_categories() :: [String.t()]
  def marketing_categories do
    sql = """
    SELECT c.key FROM relay.categories c
    WHERE c.message_class = 'marketing' AND c.state = 'active'
    ORDER BY c.key
    """

    for row <- all(sql, []), do: row["key"]
  end

  defp one(sql, params), do: sql |> all(params) |> List.first()

  defp all(sql, params) do
    %Postgrex.Result{columns: columns, rows: rows} = Repo.scoped_query!(sql, params)
    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end
end
