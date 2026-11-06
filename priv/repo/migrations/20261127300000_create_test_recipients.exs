defmodule Relay.Repo.Migrations.CreateTestRecipients do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  # API-61
  # TN-12
  # TN-13
  # OP-9
  def up do
    execute(~S"""
    CREATE TABLE relay.test_recipients (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      id uuid NOT NULL,
      recipient_id uuid NOT NULL,
      device_id uuid,
      state text NOT NULL
        CONSTRAINT test_recipients_state_check CHECK (state IN ('pending', 'verified', 'removed')),
      verify_by timestamptz NOT NULL,
      verified_at timestamptz,
      removed_at timestamptz,
      created_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      CONSTRAINT test_recipients_pkey PRIMARY KEY (tenant_id, environment, id),
      CONSTRAINT test_recipients_verified_check
        CHECK (state <> 'verified' OR verified_at IS NOT NULL),
      CONSTRAINT test_recipients_removed_check
        CHECK ((state = 'removed') = (removed_at IS NOT NULL)),
      CONSTRAINT test_recipients_recipient_id_fkey
        FOREIGN KEY (tenant_id, environment, recipient_id)
        REFERENCES relay.recipients (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
      CONSTRAINT test_recipients_device_id_fkey FOREIGN KEY (tenant_id, environment, device_id)
        REFERENCES relay.devices (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
    )
    """)

    execute("""
    CREATE UNIQUE INDEX test_recipients_listed_key ON relay.test_recipients
      (tenant_id, environment, recipient_id,
        COALESCE(device_id, '00000000-0000-0000-0000-000000000000'::uuid))
      WHERE state <> 'removed'
    """)

    execute("""
    CREATE INDEX test_recipients_recipient_index ON relay.test_recipients
      (tenant_id, environment, recipient_id)
    """)

    execute("""
    CREATE INDEX test_recipients_device_index ON relay.test_recipients
      (tenant_id, environment, device_id) WHERE device_id IS NOT NULL
    """)

    execute(~S"""
    CREATE TABLE relay.test_send_counters (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      usage_day date NOT NULL,
      used bigint NOT NULL CONSTRAINT test_send_counters_used_check CHECK (used >= 0),
      updated_at timestamptz NOT NULL,
      CONSTRAINT test_send_counters_pkey PRIMARY KEY (tenant_id, environment, usage_day)
    )
    """)

    for table <- ~w(test_recipients test_send_counters) do
      execute("""
      CREATE TRIGGER #{table}_no_delete BEFORE DELETE ON relay.#{table}
        FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
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
  end

  def down, do: :ok
end
