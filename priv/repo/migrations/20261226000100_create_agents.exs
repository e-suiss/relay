defmodule Relay.Repo.Migrations.CreateAgents do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  @tables ~w(agents)

  # C-21
  # E-28
  # E-29
  # AG-5
  # TN-12
  # TN-13
  # OP-9
  def up do
    Enum.each(statements(), &execute/1)
    Enum.each(@tables, &scoped/1)
  end

  def down, do: :ok

  defp scoped(table) do
    execute("""
    CREATE TRIGGER #{table}_no_delete BEFORE DELETE ON relay.#{table}
      FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    execute("""
    CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON relay.#{table}
      FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    execute("ALTER TABLE relay.#{table} ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE relay.#{table} FORCE ROW LEVEL SECURITY")

    execute(
      "CREATE POLICY #{table}_scope ON relay.#{table} USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})"
    )

    execute("GRANT SELECT, INSERT, UPDATE ON relay.#{table} TO relay_owner")

    execute(
      "GRANT SELECT ON relay.#{table} TO relay_app, relay_maint, relay_archive, relay_report"
    )
  end

  defp statements do
    [
      ~S"""
      CREATE TABLE relay.agents (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        recipient_kind text NOT NULL DEFAULT 'agent'
          CONSTRAINT agents_recipient_kind_check CHECK (recipient_kind = 'agent'),
        name text NOT NULL
          CONSTRAINT agents_name_check CHECK (char_length(name) BETWEEN 1 AND 200),
        owner_ref text NOT NULL
          CONSTRAINT agents_owner_ref_check CHECK (owner_ref ~ '^[\x20-\x7E]{1,256}$'),
        webhook_endpoint_id uuid,
        a2a_push_endpoint_id uuid,
        realtime boolean NOT NULL,
        state text NOT NULL
          CONSTRAINT agents_state_check CHECK (state IN ('active', 'suspended', 'deleted')),
        suspended_at timestamptz,
        deleted_at timestamptz,
        access_event_ref text
          CONSTRAINT agents_access_event_ref_check CHECK (char_length(access_event_ref) <= 512),
        version bigint NOT NULL CONSTRAINT agents_version_check CHECK (version >= 1),
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT agents_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT agents_suspended_at_check
          CHECK ((state = 'suspended') = (suspended_at IS NOT NULL)),
        CONSTRAINT agents_deleted_at_check CHECK ((state = 'deleted') = (deleted_at IS NOT NULL)),
        CONSTRAINT agents_id_fkey FOREIGN KEY (tenant_id, environment, id, recipient_kind)
          REFERENCES relay.recipients (tenant_id, environment, id, kind)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT agents_webhook_endpoint_id_fkey
          FOREIGN KEY (tenant_id, environment, webhook_endpoint_id)
          REFERENCES relay.webhook_endpoints (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT agents_a2a_push_endpoint_id_fkey
          FOREIGN KEY (tenant_id, environment, a2a_push_endpoint_id)
          REFERENCES relay.webhook_endpoints (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE INDEX agents_created_index ON relay.agents (tenant_id, environment, created_at, id)
      """,
      """
      CREATE INDEX agents_webhook_endpoint_index ON relay.agents
        (tenant_id, environment, webhook_endpoint_id) WHERE webhook_endpoint_id IS NOT NULL
      """,
      """
      CREATE INDEX agents_a2a_push_endpoint_index ON relay.agents
        (tenant_id, environment, a2a_push_endpoint_id) WHERE a2a_push_endpoint_id IS NOT NULL
      """
    ]
  end
end
