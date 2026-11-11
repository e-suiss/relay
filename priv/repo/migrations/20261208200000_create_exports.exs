defmodule Relay.Repo.Migrations.CreateExports do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  # DS-37
  # OP-39
  # L-57
  # TN-12
  # TN-13
  # TN-18
  def up do
    execute(~S"""
    CREATE TABLE relay.exports (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      id uuid NOT NULL,
      kind text NOT NULL
        CONSTRAINT exports_kind_check
          CHECK (kind IN ('deliveries', 'delivery_events', 'usage_records')),
      format text NOT NULL CONSTRAINT exports_format_check CHECK (format = 'csv'),
      period_start date NOT NULL,
      period_end date NOT NULL,
      state text NOT NULL
        CONSTRAINT exports_state_check CHECK (state IN ('pending', 'ready', 'failed', 'expired')),
      row_count bigint CONSTRAINT exports_row_count_check CHECK (row_count >= 0),
      byte_size bigint CONSTRAINT exports_byte_size_check CHECK (byte_size >= 0),
      content_sha256 relay.sha256,
      content bytea CONSTRAINT exports_content_check CHECK (octet_length(content) <= 67108864),
      failure text CONSTRAINT exports_failure_check CHECK (failure IN ('too_large', 'unavailable')),
      requested_by text NOT NULL
        CONSTRAINT exports_requested_by_check CHECK (char_length(requested_by) <= 256),
      expires_at timestamptz,
      completed_at timestamptz,
      created_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      CONSTRAINT exports_pkey PRIMARY KEY (tenant_id, environment, id),
      CONSTRAINT exports_period_check
        CHECK (period_end > period_start AND period_end - period_start <= 92),
      CONSTRAINT exports_content_state_check CHECK ((state = 'ready') = (content IS NOT NULL)),
      CONSTRAINT exports_ready_check CHECK (state NOT IN ('ready', 'expired')
        OR (row_count IS NOT NULL AND byte_size IS NOT NULL AND content_sha256 IS NOT NULL
          AND expires_at IS NOT NULL AND completed_at IS NOT NULL)),
      CONSTRAINT exports_failed_check CHECK ((state = 'failed') = (failure IS NOT NULL))
    )
    """)

    execute("""
    CREATE INDEX exports_created_at_index ON relay.exports (tenant_id, environment, created_at, id)
    """)

    execute("""
    CREATE INDEX exports_expires_at_index ON relay.exports (tenant_id, environment, expires_at)
      WHERE state = 'ready'
    """)

    execute("""
    CREATE TRIGGER exports_no_delete BEFORE DELETE ON relay.exports
      FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    execute("ALTER TABLE relay.exports ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE relay.exports FORCE ROW LEVEL SECURITY")

    execute(
      "CREATE POLICY exports_scope ON relay.exports USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})"
    )

    execute("GRANT SELECT, INSERT, UPDATE ON relay.exports TO relay_owner")
    execute("GRANT SELECT ON relay.exports TO relay_app, relay_maint, relay_archive")
  end

  def down, do: :ok
end
