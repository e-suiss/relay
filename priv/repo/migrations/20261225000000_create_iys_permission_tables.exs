defmodule Relay.Repo.Migrations.CreateIysPermissionTables do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  @tables ~w(iys_permissions iys_sync_states)

  # PC-32
  # PC-33
  # PC-62
  # OP-42
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
      CREATE TABLE relay.iys_permissions (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        brand_id uuid NOT NULL,
        consent_type text NOT NULL
          CONSTRAINT iys_permissions_consent_type_check
            CHECK (consent_type IN ('MESAJ', 'ARAMA', 'EPOSTA')),
        address_digest bytea NOT NULL
          CONSTRAINT iys_permissions_address_digest_check
            CHECK (octet_length(address_digest) = 32),
        address_digest_key_id uuid NOT NULL,
        address_digest_alt bytea
          CONSTRAINT iys_permissions_address_digest_alt_check
            CHECK (octet_length(address_digest_alt) = 32),
        address_digest_alt_key_id uuid,
        recipient_type text NOT NULL
          CONSTRAINT iys_permissions_recipient_type_check
            CHECK (recipient_type IN ('BIREYSEL', 'TACIR')),
        consent_status text NOT NULL
          CONSTRAINT iys_permissions_consent_status_check
            CHECK (consent_status IN ('ONAY', 'RET')),
        source text NOT NULL
          CONSTRAINT iys_permissions_source_check CHECK (source ~ '^[A-Z][A-Z0-9_]{1,31}$'),
        consent_at timestamptz,
        registered_at timestamptz,
        transaction_ref text
          CONSTRAINT iys_permissions_transaction_ref_check
            CHECK (char_length(transaction_ref) BETWEEN 1 AND 128),
        origin text NOT NULL
          CONSTRAINT iys_permissions_origin_check CHECK (origin IN ('pull', 'upload', 'verify')),
        refusal_state text
          CONSTRAINT iys_permissions_refusal_state_check
            CHECK (refusal_state IN ('pending', 'applied', 'unmatched')),
        verified_at timestamptz NOT NULL,
        pulled_at timestamptz,
        superseded_at timestamptz,
        created_at timestamptz NOT NULL,
        CONSTRAINT iys_permissions_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT iys_permissions_refusal_check
          CHECK (refusal_state IS NULL OR consent_status = 'RET'),
        CONSTRAINT iys_permissions_alt_check
          CHECK ((address_digest_alt IS NULL) = (address_digest_alt_key_id IS NULL)),
        CONSTRAINT iys_permissions_brand_id_fkey FOREIGN KEY (tenant_id, environment, brand_id)
          REFERENCES relay.iys_brands (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT iys_permissions_address_digest_key_id_fkey
          FOREIGN KEY (tenant_id, environment, address_digest_key_id)
          REFERENCES relay.blind_index_keys (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT iys_permissions_address_digest_alt_key_id_fkey
          FOREIGN KEY (tenant_id, environment, address_digest_alt_key_id)
          REFERENCES relay.blind_index_keys (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE UNIQUE INDEX iys_permissions_current_key ON relay.iys_permissions
        (tenant_id, environment, brand_id, consent_type, address_digest, recipient_type)
        WHERE superseded_at IS NULL
      """,
      """
      CREATE INDEX iys_permissions_refusal_index ON relay.iys_permissions
        (tenant_id, environment, brand_id, id) WHERE refusal_state = 'pending'
      """,
      """
      CREATE INDEX iys_permissions_alt_index ON relay.iys_permissions
        (tenant_id, environment, brand_id, consent_type, address_digest_alt)
        WHERE superseded_at IS NULL AND address_digest_alt IS NOT NULL
      """,
      """
      CREATE INDEX iys_permissions_verified_index ON relay.iys_permissions
        (tenant_id, environment, brand_id, verified_at) WHERE superseded_at IS NULL
      """,
      """
      CREATE INDEX iys_permissions_unpulled_index ON relay.iys_permissions
        (tenant_id, environment, brand_id, created_at)
        WHERE superseded_at IS NULL AND origin = 'upload' AND pulled_at IS NULL
      """,
      ~S"""
      CREATE TABLE relay.iys_sync_states (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        brand_id uuid NOT NULL,
        cursor_iys text
          CONSTRAINT iys_sync_states_cursor_iys_check
            CHECK (char_length(cursor_iys) BETWEEN 1 AND 256),
        cursor_hs text
          CONSTRAINT iys_sync_states_cursor_hs_check
            CHECK (char_length(cursor_hs) BETWEEN 1 AND 256),
        last_attempt_at timestamptz,
        last_pull_at timestamptz,
        last_error_code text
          CONSTRAINT iys_sync_states_last_error_code_check
            CHECK (char_length(last_error_code) BETWEEN 1 AND 64),
        last_error_at timestamptz,
        full_sync_started_at timestamptz,
        full_sync_floor_at timestamptz,
        last_full_sync_at timestamptz,
        stale_state text NOT NULL
          CONSTRAINT iys_sync_states_stale_state_check
            CHECK (stale_state IN ('fresh', 'warning', 'stopped')),
        reconciled_at timestamptz,
        drift_count bigint NOT NULL
          CONSTRAINT iys_sync_states_drift_count_check CHECK (drift_count >= 0),
        address_count bigint NOT NULL
          CONSTRAINT iys_sync_states_address_count_check CHECK (address_count >= 0),
        address_state text NOT NULL
          CONSTRAINT iys_sync_states_address_state_check
            CHECK (address_state IN ('ok', 'warning', 'reached')),
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT iys_sync_states_pkey PRIMARY KEY (tenant_id, environment, brand_id),
        CONSTRAINT iys_sync_states_error_check
          CHECK ((last_error_code IS NULL) = (last_error_at IS NULL)),
        CONSTRAINT iys_sync_states_brand_id_fkey FOREIGN KEY (tenant_id, environment, brand_id)
          REFERENCES relay.iys_brands (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """
    ]
  end
end
