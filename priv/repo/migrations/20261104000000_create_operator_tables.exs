defmodule Relay.Repo.Migrations.CreateOperatorTables do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  # TN-19
  # TN-20
  # TN-21
  # TN-23
  # TN-10
  # TN-71
  # E-26
  # E-63
  def up do
    Enum.each(statements(), &execute/1)
    Enum.each(~w(role_assignments support_delegations tenant_suspensions), &scoped/1)
  end

  defp scoped(table) do
    execute("ALTER TABLE relay.#{table} ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE relay.#{table} FORCE ROW LEVEL SECURITY")

    execute("""
    CREATE POLICY #{table}_scope ON relay.#{table}
      USING (#{@tenant_scope})
      WITH CHECK (#{@tenant_scope})
    """)

    execute("GRANT SELECT, INSERT, UPDATE ON relay.#{table} TO relay_owner")
    execute("GRANT SELECT ON relay.#{table} TO relay_app, relay_maint, relay_archive")

    execute("""
    CREATE TRIGGER #{table}_no_delete BEFORE DELETE ON relay.#{table}
      FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    execute("""
    CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON relay.#{table}
      FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
    """)
  end

  defp statements do
    [
      ~S"""
      CREATE TABLE relay.operators (
        id uuid NOT NULL,
        access_subject text NOT NULL
          CONSTRAINT operators_access_subject_check
            CHECK (char_length(access_subject) BETWEEN 1 AND 256),
        display_name_ct bytea,
        email_ct bytea,
        field_key_id uuid,
        status text NOT NULL
          CONSTRAINT operators_status_check CHECK (status IN ('active', 'suspended', 'deleted')),
        status_changed_at timestamptz NOT NULL,
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT operators_pkey PRIMARY KEY (id),
        CONSTRAINT operators_access_subject_key UNIQUE (access_subject)
      )
      """,
      "GRANT SELECT ON relay.operators TO relay_owner, relay_app, relay_archive",
      "GRANT SELECT, INSERT, UPDATE ON relay.operators TO relay_maint",
      ~S"""
      CREATE TABLE relay.operator_sessions (
        id uuid NOT NULL,
        operator_id uuid NOT NULL,
        token_digest relay.sha256 NOT NULL,
        csrf_digest relay.sha256 NOT NULL,
        client_kind text NOT NULL
          CONSTRAINT operator_sessions_client_kind_check CHECK (client_kind IN ('panel', 'cli')),
        access_session_ref text
          CONSTRAINT operator_sessions_access_session_ref_check
            CHECK (char_length(access_session_ref) <= 256),
        auth_time timestamptz NOT NULL,
        acr text CONSTRAINT operator_sessions_acr_check CHECK (char_length(acr) <= 128),
        step_up_at timestamptz,
        step_up_record_ref text
          CONSTRAINT operator_sessions_step_up_record_ref_check
            CHECK (char_length(step_up_record_ref) <= 256),
        expires_at timestamptz NOT NULL,
        idle_until timestamptz NOT NULL,
        state text NOT NULL
          CONSTRAINT operator_sessions_state_check CHECK (state IN ('active', 'revoked', 'expired')),
        revoked_reason text
          CONSTRAINT operator_sessions_revoked_reason_check
            CHECK (revoked_reason IN ('logout', 'operator_suspended', 'operator_deleted', 'admin')),
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT operator_sessions_pkey PRIMARY KEY (id),
        CONSTRAINT operator_sessions_token_digest_key UNIQUE (token_digest),
        CONSTRAINT operator_sessions_revoked_check
          CHECK ((state = 'revoked') = (revoked_reason IS NOT NULL)),
        CONSTRAINT operator_sessions_operator_id_fkey FOREIGN KEY (operator_id)
          REFERENCES relay.operators (id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE INDEX operator_sessions_operator_id_index ON relay.operator_sessions (operator_id)
        WHERE state = 'active'
      """,
      "GRANT SELECT, INSERT, UPDATE ON relay.operator_sessions TO relay_maint",
      ~S"""
      CREATE TABLE relay.role_assignments (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        operator_id uuid NOT NULL,
        role text NOT NULL
          CONSTRAINT role_assignments_role_check
            CHECK (role IN ('installation_operator', 'tenant_admin', 'tenant_operator')),
        status text NOT NULL
          CONSTRAINT role_assignments_status_check CHECK (status IN ('active', 'revoked')),
        granted_by_ref text NOT NULL
          CONSTRAINT role_assignments_granted_by_ref_check
            CHECK (char_length(granted_by_ref) <= 256),
        reason text NOT NULL
          CONSTRAINT role_assignments_reason_check CHECK (char_length(reason) BETWEEN 1 AND 2000),
        step_up_record_ref text,
        revoked_at timestamptz,
        revoked_by_ref text,
        revoke_reason text
          CONSTRAINT role_assignments_revoke_reason_check CHECK (char_length(revoke_reason) <= 2000),
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT role_assignments_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT role_assignments_revoked_check
          CHECK ((status = 'revoked') = (revoked_at IS NOT NULL)),
        CONSTRAINT role_assignments_tenant_id_fkey FOREIGN KEY (tenant_id)
          REFERENCES relay.tenants (id) ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT role_assignments_operator_id_fkey FOREIGN KEY (operator_id)
          REFERENCES relay.operators (id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE UNIQUE INDEX role_assignments_active_key ON relay.role_assignments
        (tenant_id, environment, operator_id, role) WHERE status = 'active'
      """,
      """
      CREATE INDEX role_assignments_operator_id_index ON relay.role_assignments (operator_id)
        WHERE status = 'active'
      """,
      ~S"""
      CREATE TABLE relay.support_delegations (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        operator_id uuid NOT NULL,
        access text NOT NULL CONSTRAINT support_delegations_access_check CHECK (access IN ('read')),
        reason text NOT NULL
          CONSTRAINT support_delegations_reason_check CHECK (char_length(reason) BETWEEN 1 AND 2000),
        granted_by_ref text NOT NULL
          CONSTRAINT support_delegations_granted_by_ref_check
            CHECK (char_length(granted_by_ref) <= 256),
        step_up_record_ref text NOT NULL,
        starts_at timestamptz NOT NULL,
        expires_at timestamptz NOT NULL,
        status text NOT NULL
          CONSTRAINT support_delegations_status_check
            CHECK (status IN ('active', 'revoked', 'expired')),
        revoked_at timestamptz,
        revoked_by_ref text,
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT support_delegations_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT support_delegations_window_check
          CHECK (expires_at > starts_at AND expires_at <= starts_at + interval '3 days'),
        CONSTRAINT support_delegations_revoked_check
          CHECK ((status = 'revoked') = (revoked_at IS NOT NULL)),
        CONSTRAINT support_delegations_tenant_id_fkey FOREIGN KEY (tenant_id)
          REFERENCES relay.tenants (id) ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT support_delegations_operator_id_fkey FOREIGN KEY (operator_id)
          REFERENCES relay.operators (id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE INDEX support_delegations_operator_id_index ON relay.support_delegations
        (tenant_id, environment, operator_id) WHERE status = 'active'
      """,
      ~S"""
      CREATE TABLE relay.tenant_suspensions (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        subtenant_id uuid,
        ground text NOT NULL
          CONSTRAINT tenant_suspensions_ground_check
            CHECK (ground IN ('abuse', 'security', 'legal', 'other')),
        reason text NOT NULL
          CONSTRAINT tenant_suspensions_reason_check CHECK (char_length(reason) BETWEEN 1 AND 2000),
        notice_due_at timestamptz NOT NULL,
        effective_at timestamptz NOT NULL,
        appeal_until timestamptz NOT NULL,
        state text NOT NULL
          CONSTRAINT tenant_suspensions_state_check
            CHECK (state IN ('scheduled', 'effective', 'lifted', 'cancelled')),
        created_by_ref text NOT NULL
          CONSTRAINT tenant_suspensions_created_by_ref_check
            CHECK (char_length(created_by_ref) <= 256),
        step_up_record_ref text NOT NULL,
        lifted_at timestamptz,
        lifted_by_ref text,
        lift_reason text
          CONSTRAINT tenant_suspensions_lift_reason_check CHECK (char_length(lift_reason) <= 2000),
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT tenant_suspensions_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT tenant_suspensions_environment_check CHECK (environment = 'live'),
        CONSTRAINT tenant_suspensions_notice_check
          CHECK (ground <> 'other' OR effective_at >= created_at + interval '7 days'),
        CONSTRAINT tenant_suspensions_immediate_check
          CHECK (ground = 'other' OR effective_at = created_at),
        CONSTRAINT tenant_suspensions_notice_due_check
          CHECK (notice_due_at = CASE WHEN ground = 'other' THEN created_at
            ELSE effective_at + interval '24 hours' END),
        CONSTRAINT tenant_suspensions_appeal_check
          CHECK (appeal_until = effective_at + interval '14 days'),
        CONSTRAINT tenant_suspensions_lifted_check
          CHECK ((state IN ('lifted', 'cancelled')) = (lifted_at IS NOT NULL)),
        CONSTRAINT tenant_suspensions_tenant_id_fkey FOREIGN KEY (tenant_id)
          REFERENCES relay.tenants (id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE UNIQUE INDEX tenant_suspensions_open_key ON relay.tenant_suspensions
        (tenant_id, environment, subtenant_id) NULLS NOT DISTINCT
        WHERE state IN ('scheduled', 'effective')
      """,
      """
      CREATE INDEX tenant_suspensions_due_index ON relay.tenant_suspensions (effective_at)
        WHERE state = 'scheduled'
      """,
      """
      ALTER TABLE relay.subtenants ADD CONSTRAINT subtenants_state_suspended_check
        CHECK (state IN ('active', 'suspended', 'archived')) NOT VALID
      """
    ]
  end
end
