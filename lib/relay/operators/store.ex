defmodule Relay.Operators.Store do
  @moduledoc """
  Data access of the operator surface. Operators and their sessions are installation tables written through the `relay_ops` functions of the `:operator_access` escape hatch; role assignments, support delegations, suspensions, send modes, the API version pin and the audit log are tenant records written through `relay_fn` functions inside `in_scope/2`.
  """

  alias Relay.Actor
  alias Relay.Repo

  @type digest :: <<_::256>>
  @type work_filter :: %{
          optional(:subtenant_id) => Relay.Id.t() | nil,
          optional(:recipient_id) => Relay.Id.t() | nil
        }

  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  @doc "Rolls back the current scoped transaction, which then returns `{:error, value}`."
  @spec rollback(term()) :: no_return()
  def rollback(value), do: Repo.rollback(value)

  @doc "Returns the installation tenant's identifier."
  @spec installation_tenant_id() :: Relay.Id.t()
  def installation_tenant_id do
    {:ok, %{rows: [[id]]}} =
      Repo.unscoped_query(
        :installation_lookup,
        "SELECT installation_tenant_id FROM relay.installation WHERE singleton",
        []
      )

    id
  end

  # TN-19
  # TN-20
  @doc "Signs an operator in: creates the operator on first sign-in and opens a session."
  @spec sign_in(map()) ::
          {:signed_in | :created | :operator_suspended | :operator_deleted, Relay.Id.t() | nil,
           Relay.Id.t() | nil, DateTime.t() | nil}
  def sign_in(attrs) do
    [row] =
      Repo.call_unscoped!(:operator_access, "relay_ops.operator_sign_in", [
        attrs.operator_id,
        attrs.access_subject,
        nil,
        nil,
        nil,
        attrs.session_id,
        attrs.token_digest,
        attrs.csrf_digest,
        attrs.client_kind,
        attrs.access_session_ref,
        attrs.auth_time,
        attrs.acr
      ])

    {Repo.code!(row["result"], [:signed_in, :created, :operator_suspended, :operator_deleted]),
     row["operator_id"], row["session_id"], row["expires_at"]}
  end

  @doc "Creates an operator known from Access before its first sign-in, or returns the existing one."
  @spec ensure(Relay.Id.t(), String.t()) :: {:created | :exists, Relay.Id.t(), String.t()}
  def ensure(id, subject) do
    [row] = Repo.call_unscoped!(:operator_access, "relay_ops.operator_ensure", [id, subject])
    {Repo.code!(row["result"], [:created, :exists]), row["operator_id"], row["status"]}
  end

  @doc "Resolves a session by the digest of its cookie value; extends its idle time."
  @spec resolve(digest()) :: map() | nil
  def resolve(digest) do
    case Repo.call_unscoped!(:operator_access, "relay_ops.operator_session_resolve", [digest]) do
      [row] -> row
      [] -> nil
    end
  end

  # TN-21
  @doc "Records a completed step-up on a session."
  @spec step_up(Relay.Id.t(), DateTime.t(), String.t() | nil, String.t()) ::
          :recorded | :session_inactive
  def step_up(session_id, auth_time, acr, ref) do
    [row] =
      Repo.call_unscoped!(:operator_access, "relay_ops.operator_session_step_up", [
        session_id,
        auth_time,
        acr,
        ref
      ])

    Repo.code!(row["operator_session_step_up"], [:recorded, :session_inactive])
  end

  @doc "Revokes a session."
  @spec revoke(Relay.Id.t(), String.t()) :: :revoked | :already_ended | :not_found
  def revoke(session_id, reason) do
    [row] =
      Repo.call_unscoped!(:operator_access, "relay_ops.operator_session_revoke", [
        session_id,
        reason
      ])

    Repo.code!(row["operator_session_revoke"], [:revoked, :already_ended, :not_found])
  end

  # TN-20
  @doc "Reflects an Access user lifecycle change; suspension and deletion revoke every active session."
  @spec set_status(String.t(), String.t(), String.t() | nil, digest(), Actor.t()) ::
          {:changed | :unchanged | :not_found, non_neg_integer()}
  def set_status(subject, status, event_ref, digest, %Actor{} = actor) do
    [row] =
      Repo.call_unscoped!(
        :operator_access,
        "relay_ops.operator_set_status",
        [subject, status, event_ref, digest] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], [:changed, :unchanged, :not_found]), row["revoked_sessions"]}
  end

  # TN-23
  @doc "Lists the active role grants of an active operator across tenants."
  @spec roles(Relay.Id.t()) :: [map()]
  def roles(operator_id),
    do: Repo.call_unscoped!(:operator_access, "relay_ops.operator_roles", [operator_id])

  @doc "Reads an operator and whether any installation operator assignment was ever made."
  @spec operator(Relay.Id.t()) :: map() | nil
  def operator(operator_id) do
    case Repo.call_unscoped!(:operator_access, "relay_ops.operator_get", [operator_id]) do
      [row] -> row
      [] -> nil
    end
  end

  # TN-23
  @doc "Returns the active support delegation of an operator in a tenant scope, or nil."
  @spec delegation_active(Relay.Id.t(), Relay.Scope.t()) :: map() | nil
  def delegation_active(operator_id, %Relay.Scope{} = scope) do
    case Repo.call_unscoped!(:operator_access, "relay_ops.support_delegation_active", [
           operator_id,
           scope.tenant_id,
           Relay.Environment.dump(scope.environment)
         ]) do
      [row | _] -> row
      [] -> nil
    end
  end

  # X-4
  @doc "Reads installation-level facts and counters of tenants, never record content."
  @spec overview(String.t() | nil, Relay.Id.t() | nil, pos_integer()) :: [map()]
  def overview(status, after_id, limit),
    do:
      Repo.call_unscoped!(:cross_tenant_overview, "relay_ops.tenant_overview", [
        status,
        after_id,
        limit
      ])

  # TN-71
  @doc "Lists scheduled suspensions that are due."
  @spec suspensions_due(pos_integer()) :: [map()]
  def suspensions_due(limit),
    do:
      Repo.call_unscoped!(:suspension_due_discovery, "relay_ops.tenant_suspensions_due", [limit])

  # TN-21
  # TN-23
  @doc "Assigns a role in the established scope."
  @spec role_assign(map(), digest(), Actor.t()) ::
          {:assigned
           | :exists
           | :operator_not_found
           | :operator_inactive
           | :role_not_allowed, Relay.Id.t() | nil}
  def role_assign(attrs, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.role_assign",
        [
          attrs.id,
          attrs.operator_id,
          Atom.to_string(attrs.role),
          attrs.reason,
          attrs.step_up_ref,
          digest
        ] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], [
       :assigned,
       :exists,
       :operator_not_found,
       :operator_inactive,
       :role_not_allowed
     ]), row["role_assignment_id"]}
  end

  @doc "Revokes a role assignment in the established scope."
  @spec role_revoke(Relay.Id.t(), String.t(), String.t() | nil, digest(), Actor.t()) ::
          :revoked | :already_revoked | :not_found | :last_admin
  def role_revoke(id, reason, step_up_ref, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.role_revoke",
        [id, reason, step_up_ref, digest] ++ Actor.params(actor)
      )

    Repo.code!(row["role_revoke"], [:revoked, :already_revoked, :not_found, :last_admin])
  end

  @doc "Lists the role assignments of the established scope after `after_id`."
  @spec role_list(Relay.Id.t() | nil, pos_integer()) :: [map()]
  def role_list(after_id, limit) do
    rows(
      """
      SELECT tenant_id, environment, id, operator_id, role, status, granted_by_ref, revoked_at,
        revoked_by_ref, created_at
      FROM relay.role_assignments
      WHERE ($1::uuid IS NULL OR id > $1::uuid)
      ORDER BY id LIMIT $2
      """,
      [after_id, limit]
    )
  end

  @doc "Reads one role assignment of the established scope."
  @spec role_get(Relay.Id.t()) :: map() | nil
  def role_get(id) do
    """
    SELECT tenant_id, environment, id, operator_id, role, status, granted_by_ref, revoked_at,
      revoked_by_ref, created_at
    FROM relay.role_assignments WHERE id = $1
    """
    |> rows([id])
    |> List.first()
  end

  @doc "Returns true if the established scope has any installation operator assignment, active or not."
  @spec installation_assigned?() :: boolean()
  def installation_assigned? do
    [%{"assigned" => assigned}] =
      rows(
        "SELECT EXISTS (SELECT 1 FROM relay.role_assignments WHERE role = 'installation_operator') AS assigned",
        []
      )

    assigned
  end

  # TN-23
  @doc "Grants a support delegation in the established scope."
  @spec delegation_grant(map(), digest(), Actor.t()) ::
          {:granted | :operator_not_found | :not_installation_operator | :duration_invalid,
           Relay.Id.t() | nil}
  def delegation_grant(attrs, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.support_delegation_grant",
        [attrs.id, attrs.operator_id, attrs.reason, attrs.expires_at, attrs.step_up_ref, digest] ++
          Actor.params(actor)
      )

    {Repo.code!(row["result"], [
       :granted,
       :operator_not_found,
       :not_installation_operator,
       :duration_invalid
     ]), row["delegation_id"]}
  end

  @doc "Revokes a support delegation in the established scope."
  @spec delegation_revoke(Relay.Id.t(), String.t(), digest(), Actor.t()) ::
          :revoked | :already_ended | :not_found
  def delegation_revoke(id, reason, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.support_delegation_revoke",
        [id, reason, digest] ++ Actor.params(actor)
      )

    Repo.code!(row["support_delegation_revoke"], [:revoked, :already_ended, :not_found])
  end

  @doc "Lists the support delegations of the established scope, optionally of one operator."
  @spec delegation_list(Relay.Id.t() | nil, Relay.Id.t() | nil, pos_integer()) :: [map()]
  def delegation_list(operator_id, after_id, limit) do
    rows(
      """
      SELECT tenant_id, environment, id, operator_id, access, reason, granted_by_ref, starts_at,
        CASE WHEN status = 'active' AND expires_at <= now() THEN 'expired' ELSE status END AS status,
        expires_at, revoked_at
      FROM relay.support_delegations
      WHERE ($1::uuid IS NULL OR operator_id = $1::uuid) AND ($2::uuid IS NULL OR id > $2::uuid)
      ORDER BY id LIMIT $3
      """,
      [operator_id, after_id, limit]
    )
  end

  @doc "Reads one support delegation of the established scope."
  @spec delegation_get(Relay.Id.t()) :: map() | nil
  def delegation_get(id) do
    """
    SELECT tenant_id, environment, id, operator_id, access, reason, granted_by_ref, starts_at,
      CASE WHEN status = 'active' AND expires_at <= now() THEN 'expired' ELSE status END AS status,
      expires_at, revoked_at
    FROM relay.support_delegations WHERE id = $1
    """
    |> rows([id])
    |> List.first()
  end

  # TN-10
  # TN-71
  @doc "Records a suspension of the tenant of the established `live` scope, or of one of its subtenants."
  @spec suspension_record(map(), digest(), Actor.t()) ::
          {:scheduled
           | :effective
           | :already_suspended
           | :subtenant_not_found
           | :notice_too_short
           | :effective_not_allowed, Relay.Id.t() | nil}
  def suspension_record(attrs, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.tenant_suspension_record",
        [
          attrs.id,
          attrs.subtenant_id,
          attrs.ground,
          attrs.reason,
          attrs.effective_at,
          attrs.step_up_ref,
          digest
        ] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], [
       :scheduled,
       :effective,
       :already_suspended,
       :subtenant_not_found,
       :notice_too_short,
       :effective_not_allowed
     ]), row["suspension_id"]}
  end

  @doc "Puts a due scheduled suspension into effect."
  @spec suspension_activate(Relay.Id.t()) :: :effective | :not_due | :not_scheduled
  def suspension_activate(id) do
    [row] = Repo.call!("relay_fn.tenant_suspension_activate", [id])
    Repo.code!(row["tenant_suspension_activate"], [:effective, :not_due, :not_scheduled])
  end

  @doc "Lifts an effective suspension or cancels a scheduled one."
  @spec suspension_lift(Relay.Id.t(), String.t(), String.t(), digest(), Actor.t()) ::
          :lifted | :cancelled | :not_found | :already_ended
  def suspension_lift(id, reason, step_up_ref, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.tenant_suspension_lift",
        [id, reason, step_up_ref, digest] ++ Actor.params(actor)
      )

    Repo.code!(row["tenant_suspension_lift"], [:lifted, :cancelled, :not_found, :already_ended])
  end

  @doc "Lists the suspensions of the established `live` scope, newest first."
  @spec suspensions() :: [map()]
  def suspensions do
    rows(
      """
      SELECT tenant_id, environment, id, subtenant_id, ground, reason, effective_at,
        notice_due_at, appeal_until, state, created_by_ref, created_at, lifted_at
      FROM relay.tenant_suspensions ORDER BY created_at DESC, id DESC LIMIT 20
      """,
      []
    )
  end

  @doc "Reads one suspension of the established scope."
  @spec suspension_get(Relay.Id.t()) :: map() | nil
  def suspension_get(id) do
    """
    SELECT tenant_id, environment, id, subtenant_id, ground, reason, effective_at,
      notice_due_at, appeal_until, state, created_by_ref, created_at, lifted_at
    FROM relay.tenant_suspensions WHERE id = $1
    """
    |> rows([id])
    |> List.first()
  end

  @doc "Reads the open suspension (scheduled or effective) of the tenant or of one subtenant."
  @spec suspension_open(Relay.Id.t() | nil) :: map() | nil
  def suspension_open(subtenant_id) do
    """
    SELECT tenant_id, environment, id, subtenant_id, ground, reason, effective_at,
      notice_due_at, appeal_until, state, created_by_ref, created_at, lifted_at
    FROM relay.tenant_suspensions
    WHERE subtenant_id IS NOT DISTINCT FROM $1::uuid AND state IN ('scheduled', 'effective')
    """
    |> rows([subtenant_id])
    |> List.first()
  end

  # TN-10
  # TN-40
  # TN-73
  @doc "Reads up to `limit` pending deliveries of the established scope that are neither terminal nor paused; `filter` narrows them to the notifications of a subtenant (`:subtenant_id`) or of a recipient (`:recipient_id`)."
  @spec pending_deliveries(work_filter(), pos_integer()) :: [Relay.Id.t()]
  def pending_deliveries(filter, limit) do
    """
    SELECT d.tenant_id, d.environment, d.id
    FROM relay.deliveries d
    JOIN relay.notifications n ON n.tenant_id = d.tenant_id AND n.environment = d.environment
      AND n.id = d.notification_id
    WHERE d.delivery_rank = 0 AND d.failure_kind IS NULL AND d.paused_at IS NULL
      AND ($1::uuid IS NULL OR n.subtenant_id = $1::uuid)
      AND ($2::uuid IS NULL OR n.recipient_id = $2::uuid)
    ORDER BY d.created_at, d.id
    LIMIT $3
    """
    |> rows([filter[:subtenant_id], filter[:recipient_id], limit])
    |> Enum.map(& &1["id"])
  end

  # TN-10
  # TN-40
  # TN-73
  @doc "Reads up to `limit` deliveries of the established scope paused with `rule_id`, with their notification, message class and whether their subtenant or recipient is still suspended; `filter` narrows them as in `pending_deliveries/2`."
  @spec paused_deliveries(String.t(), work_filter(), pos_integer()) :: [map()]
  def paused_deliveries(rule_id, filter, limit) do
    rows(
      """
      SELECT d.tenant_id, d.environment, d.id, d.notification_id,
        n.message_class::text AS message_class,
        EXISTS (SELECT 1 FROM relay.subtenants s
          WHERE s.tenant_id = n.tenant_id AND s.environment = n.environment
            AND s.id = n.subtenant_id AND s.state = 'suspended') AS subtenant_suspended,
        EXISTS (SELECT 1 FROM relay.recipients r
          WHERE r.tenant_id = n.tenant_id AND r.environment = n.environment
            AND r.id = n.recipient_id AND r.suspended_at IS NOT NULL) AS recipient_suspended
      FROM relay.deliveries d
      JOIN relay.notifications n ON n.tenant_id = d.tenant_id AND n.environment = d.environment
        AND n.id = d.notification_id
      WHERE d.delivery_rank = 0 AND d.failure_kind IS NULL AND d.paused_at IS NOT NULL
        AND d.pause_kill_switch_id IS NULL AND d.pause_rule_id::text = $1
        AND ($2::uuid IS NULL OR n.subtenant_id = $2::uuid)
        AND ($3::uuid IS NULL OR n.recipient_id = $3::uuid)
      ORDER BY d.created_at, d.id
      LIMIT $4
      """,
      [rule_id, filter[:subtenant_id], filter[:recipient_id], limit]
    )
  end

  # TN-73
  @doc "Suspends a subscriber of the established scope and writes its `subscriber.suspended` audit record; returns the result and the subscriber's version."
  @spec subscriber_suspend(Relay.Id.t(), String.t() | nil, digest(), Actor.t()) ::
          {:suspended | :already_suspended | :not_found, pos_integer() | nil}
  def subscriber_suspend(recipient_id, reason, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.recipient_suspend",
        [recipient_id, reason, digest] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], [:suspended, :already_suspended, :not_found]), row["version"]}
  end

  # TN-73
  @doc "Lifts the suspension of a subscriber of the established scope and writes its `subscriber.resumed` audit record; returns the result and the subscriber's version."
  @spec subscriber_resume(Relay.Id.t(), String.t() | nil, digest(), Actor.t()) ::
          {:resumed | :not_suspended | :not_found, pos_integer() | nil}
  def subscriber_resume(recipient_id, reason, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.recipient_resume",
        [recipient_id, reason, digest] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], [:resumed, :not_suspended, :not_found]), row["version"]}
  end

  # TN-73
  @doc "Reads the state and `suspended_at` of a subscriber of the established scope, or `nil` when there is no such subscriber."
  @spec subscriber_suspension(Relay.Id.t()) :: map() | nil
  def subscriber_suspension(recipient_id) do
    """
    SELECT r.tenant_id, r.environment, r.state, r.suspended_at
    FROM relay.recipients r
    WHERE r.id = $1 AND r.kind = 'subscriber' AND r.state <> 'deleted'
    """
    |> rows([recipient_id])
    |> List.first()
  end

  # TN-73
  # S-69
  @doc "Lists, after `after_id`, up to `limit` tenants an Access user event may reach a subscriber of: every tenant that is not closed, by identifier only, through the `:access_event_intake` escape hatch."
  @spec subscriber_tenants(Relay.Id.t() | nil, pos_integer()) :: [Relay.Id.t()]
  def subscriber_tenants(after_id, limit) do
    :access_event_intake
    |> Repo.call_unscoped!("relay_ops.subscriber_tenants", [after_id, limit])
    |> Enum.map(& &1["tenant_id"])
  end

  # TN-10
  # TN-40
  @doc "Marks a delivery `PAUSED` with `rule_id` and no kill switch."
  @spec delivery_pause(Relay.Id.t(), String.t()) ::
          :paused | :already_paused | :already_terminal | :not_found
  def delivery_pause(delivery_id, rule_id) do
    [row] = Repo.call!("relay_fn.delivery_pause", [delivery_id, rule_id, nil])
    Repo.code!(row["delivery_pause"], [:paused, :already_paused, :already_terminal, :not_found])
  end

  # TN-40
  @doc "Lifts the pause of a delivery the policy lattice decided to send."
  @spec delivery_resume(Relay.Id.t(), String.t(), String.t()) ::
          :resumed | :not_paused | :already_terminal | :not_found
  def delivery_resume(delivery_id, decision_ref, rule_id) do
    [row] = Repo.call!("relay_fn.delivery_resume", [delivery_id, decision_ref, rule_id])
    Repo.code!(row["delivery_resume"], [:resumed, :not_paused, :already_terminal, :not_found])
  end

  # TN-40
  @doc "Cancels a paused delivery the policy lattice decided to skip."
  @spec delivery_cancel(Relay.Id.t(), String.t(), digest(), Actor.t()) ::
          :cancelled | :already_terminal | :not_found
  def delivery_cancel(delivery_id, rule_id, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.delivery_cancel",
        [delivery_id, rule_id, digest] ++ Actor.params(actor)
      )

    Repo.code!(row["delivery_cancel"], [:cancelled, :already_terminal, :not_found])
  end

  # T-15
  @doc "True when a delivery job of `delivery_id` still waits or runs in the queue."
  @spec delivery_job?(Relay.Id.t()) :: boolean()
  def delivery_job?(delivery_id) do
    [%{"queued" => queued}] =
      rows(
        """
        SELECT EXISTS (SELECT 1 FROM relay_queue.oban_jobs j
          WHERE j.state IN ('available', 'scheduled', 'executing', 'retryable')
            AND j.args->>'delivery_id' = $1) AS queued
        """,
        [Relay.Id.to_string(delivery_id)]
      )

    queued
  end

  # OP-51
  @doc "Sets or clears one send mode level of the established scope."
  @spec send_mode_set(map(), digest(), Actor.t()) ::
          {:set | :cleared | :unchanged | :invalid_level, String.t() | nil, boolean()}
  def send_mode_set(attrs, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.send_mode_set",
        [attrs.category, attrs.channel, attrs.mode, attrs.step_up_ref, digest] ++
          Actor.params(actor)
      )

    {Repo.code!(row["result"], [:set, :cleared, :unchanged, :invalid_level]), row["previous"],
     row["relaxed"]}
  end

  @doc "Reads the send mode settings of the established scope."
  @spec send_modes() :: [map()]
  def send_modes do
    rows(
      """
      SELECT tenant_id, environment, key, value #>> '{}' AS mode, updated_at
      FROM relay.settings
      WHERE subtenant_id IS NULL AND (key = 'send_mode' OR key LIKE 'send\\_mode.%')
        AND value IS NOT NULL
      ORDER BY key
      """,
      []
    )
  end

  # TN-50
  @doc "Reads the audit log of the established scope; the read itself is audited (`audit_log.read`)."
  @spec audit_query(map(), digest(), Actor.t()) :: [map()]
  def audit_query(query, digest, %Actor{} = actor) do
    Repo.call!(
      "relay_fn.audit_query",
      [query.from, query.to, query.action, query.after_id, query.limit, digest] ++
        Actor.params(actor)
    )
  end

  # TN-47
  @doc "Appends one audit record in the established scope and returns its identifier."
  @spec audit(map(), digest(), Actor.t()) :: Relay.Id.t()
  def audit(record, digest, %Actor{} = actor) do
    [kind, ref, on_behalf_of, access_record] = Actor.params(actor)
    id = Relay.Id.generate()

    [_row] =
      Repo.call!("relay_fn.audit_append", [
        id,
        record.action,
        kind,
        ref,
        on_behalf_of,
        access_record,
        record.target_type,
        record.target_id,
        Map.get(record, :reason),
        nil,
        nil,
        digest
      ])

    id
  end

  @doc "Returns true if a subscriber exists in the established scope."
  @spec subscriber?(Relay.Id.t()) :: boolean()
  def subscriber?(id) do
    rows("SELECT tenant_id, environment, id FROM relay.recipients WHERE id = $1", [id]) != []
  end

  # API-52
  @doc "Reads the established tenant's API version pin."
  @spec api_version() :: map()
  def api_version do
    [row] =
      rows(
        "SELECT id AS tenant_id, api_version::text AS api_version, api_version_pinned_at FROM relay.tenants",
        []
      )

    row
  end

  # API-52
  @doc "Moves the established tenant's API version pin by hand."
  @spec api_version_set(String.t(), digest(), Actor.t()) ::
          :pinned | :already_pinned | :changed | :unchanged | :unsupported
  def api_version_set(version, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.tenant_api_version_pin",
        [Date.from_iso8601!(version), false, digest] ++ Actor.params(actor)
      )

    Repo.code!(row["tenant_api_version_pin"], [
      :pinned,
      :already_pinned,
      :changed,
      :unchanged,
      :unsupported
    ])
  end

  # API-51
  # TN-52
  @doc "Reads the quota policies of the established scope, removed ones included, by period."
  @spec quota_policies() :: [map()]
  def quota_policies do
    rows(
      """
      SELECT tenant_id, environment, period, limit_total, class_caps, security_reserve_bp, state,
        version, updated_at
      FROM relay.quota_policies
      ORDER BY period
      """,
      []
    )
  end

  # API-51
  @doc "Reads the quota usage of the current period of the established scope."
  @spec quota_usage(String.t()) :: map()
  def quota_usage(period) do
    [row] = Repo.call!("relay_fn.quota_usage", [period])
    row
  end

  # API-51
  # TN-52
  # TN-22
  @doc "Sets, changes or removes (`limit_total: nil`) the quota policy of a period; audited as `quota_policy.changed`."
  @spec quota_policy_set(map(), digest(), Actor.t()) ::
          {:created | :updated | :removed | :unchanged | :version_conflict | :invalid_caps,
           pos_integer() | nil}
  def quota_policy_set(attrs, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.quota_policy_set",
        [
          attrs.period,
          attrs.limit_total,
          attrs.class_caps,
          attrs.security_reserve_bp,
          nil,
          digest
        ] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], [
       :created,
       :updated,
       :removed,
       :unchanged,
       :version_conflict,
       :invalid_caps
     ]), row["version"]}
  end

  defp rows(sql, params) do
    result = Repo.scoped_query!(sql, params)
    Enum.map(result.rows, &(result.columns |> Enum.zip(&1) |> Map.new()))
  end
end
