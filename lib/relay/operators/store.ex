defmodule Relay.Operators.Store do
  @moduledoc """
  Data access of the operator surface. Operators and their sessions are installation tables written through the `relay_ops` functions of the `:operator_access` escape hatch; role assignments, support delegations, suspensions, send modes, the API version pin and the audit log are tenant records written through `relay_fn` functions inside `in_scope/2`.
  """

  alias Relay.Actor
  alias Relay.Repo

  @type digest :: <<_::256>>

  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

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

  defp rows(sql, params) do
    result = Repo.scoped_query!(sql, params)
    Enum.map(result.rows, &(result.columns |> Enum.zip(&1) |> Map.new()))
  end
end
