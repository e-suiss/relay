defmodule Relay.Repo.Migrations.CreateImports do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  # OP-96
  # OP-55
  # OP-97
  # TN-12
  # TN-13
  def up do
    execute(~S"""
    CREATE TABLE relay.imports (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      id uuid NOT NULL,
      kind text NOT NULL
        CONSTRAINT imports_kind_check
          CHECK (kind IN ('suppressions', 'consents', 'subscribers', 'devices', 'templates',
            'scheduled')),
      batch text NOT NULL
        CONSTRAINT imports_batch_check CHECK (batch ~ '^[A-Za-z0-9._-]{1,64}$'),
      state text NOT NULL
        CONSTRAINT imports_state_check CHECK (state IN ('pending', 'completed', 'failed')),
      line_count bigint NOT NULL CONSTRAINT imports_line_count_check CHECK (line_count >= 0),
      byte_size bigint NOT NULL CONSTRAINT imports_byte_size_check CHECK (byte_size >= 0),
      content_sha256 relay.sha256 NOT NULL,
      content_ct bytea
        CONSTRAINT imports_content_ct_check CHECK (octet_length(content_ct) <= 40000000),
      content_key_id uuid,
      report jsonb
        CONSTRAINT imports_report_check
          CHECK (jsonb_typeof(report) = 'object' AND pg_column_size(report) <= 16777216),
      failure text
        CONSTRAINT imports_failure_check CHECK (failure IN ('unavailable', 'content_unreadable')),
      requested_by text NOT NULL
        CONSTRAINT imports_requested_by_check CHECK (char_length(requested_by) <= 256),
      completed_at timestamptz,
      created_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      CONSTRAINT imports_pkey PRIMARY KEY (tenant_id, environment, id),
      CONSTRAINT imports_content_key_check CHECK ((content_ct IS NULL) = (content_key_id IS NULL)),
      CONSTRAINT imports_pending_check
        CHECK ((state = 'pending') = (completed_at IS NULL)
          AND (state <> 'pending' OR content_ct IS NOT NULL)),
      CONSTRAINT imports_completed_check CHECK ((state = 'completed') = (report IS NOT NULL)),
      CONSTRAINT imports_failed_check CHECK ((state = 'failed') = (failure IS NOT NULL)),
      CONSTRAINT imports_content_key_id_fkey FOREIGN KEY (tenant_id, environment, content_key_id)
        REFERENCES relay.tenant_keys (tenant_id, environment, id)
        ON DELETE RESTRICT ON UPDATE RESTRICT
    )
    """)

    execute("""
    CREATE INDEX imports_created_at_index ON relay.imports (tenant_id, environment, created_at, id)
    """)

    execute("""
    CREATE INDEX imports_batch_index ON relay.imports (tenant_id, environment, batch, kind, state)
    """)

    execute("""
    CREATE INDEX imports_content_key_id_index ON relay.imports
      (tenant_id, environment, content_key_id) WHERE content_key_id IS NOT NULL
    """)

    execute("""
    CREATE TRIGGER imports_no_delete BEFORE DELETE ON relay.imports
      FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    execute("ALTER TABLE relay.imports ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE relay.imports FORCE ROW LEVEL SECURITY")

    execute(
      "CREATE POLICY imports_scope ON relay.imports USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})"
    )

    execute("GRANT SELECT, INSERT, UPDATE ON relay.imports TO relay_owner")
    execute("GRANT SELECT ON relay.imports TO relay_app, relay_maint, relay_archive")

    execute(~S"""
    CREATE TABLE relay.import_records (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      id uuid NOT NULL,
      import_id uuid NOT NULL,
      line bigint NOT NULL CONSTRAINT import_records_line_check CHECK (line >= 1),
      entity_kind text NOT NULL
        CONSTRAINT import_records_entity_kind_check
          CHECK (entity_kind IN ('suppression', 'consent', 'subscriber', 'device', 'event')),
      entity_key text NOT NULL
        CONSTRAINT import_records_entity_key_check
          CHECK (entity_key ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
      recipient_id uuid,
      provider_ref_ct bytea
        CONSTRAINT import_records_provider_ref_ct_check CHECK (octet_length(provider_ref_ct) <= 2048),
      source_last_seen_at timestamptz,
      migrated_at timestamptz NOT NULL,
      created_at timestamptz NOT NULL,
      CONSTRAINT import_records_pkey PRIMARY KEY (tenant_id, environment, id),
      CONSTRAINT import_records_line_key
        UNIQUE (tenant_id, environment, import_id, line, entity_kind),
      CONSTRAINT import_records_provider_ref_check
        CHECK (provider_ref_ct IS NULL OR recipient_id IS NOT NULL),
      CONSTRAINT import_records_last_seen_check
        CHECK (entity_kind = 'device' OR source_last_seen_at IS NULL),
      CONSTRAINT import_records_import_id_fkey FOREIGN KEY (tenant_id, environment, import_id)
        REFERENCES relay.imports (tenant_id, environment, id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
      CONSTRAINT import_records_recipient_id_fkey FOREIGN KEY (tenant_id, environment, recipient_id)
        REFERENCES relay.recipients (tenant_id, environment, id)
        ON DELETE RESTRICT ON UPDATE RESTRICT
    )
    """)

    execute("""
    CREATE INDEX import_records_entity_index ON relay.import_records
      (tenant_id, environment, entity_kind, entity_key)
    """)

    execute("""
    CREATE INDEX import_records_recipient_id_index ON relay.import_records
      (tenant_id, environment, recipient_id) WHERE recipient_id IS NOT NULL
    """)

    execute("""
    CREATE TRIGGER import_records_no_delete BEFORE DELETE ON relay.import_records
      FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    execute("ALTER TABLE relay.import_records ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE relay.import_records FORCE ROW LEVEL SECURITY")

    execute(
      "CREATE POLICY import_records_scope ON relay.import_records USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})"
    )

    execute("GRANT SELECT, INSERT, UPDATE ON relay.import_records TO relay_owner")
    execute("GRANT SELECT ON relay.import_records TO relay_app, relay_maint, relay_archive")
  end

  def down, do: :ok
end
