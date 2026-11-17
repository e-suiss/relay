defmodule Relay.Repo.Migrations.CreateIysTables do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  @tables ~w(iys_configs iys_brands iys_uploads)

  # PC-28
  # PC-29
  # PC-30
  # PC-34
  # E-22
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
      CREATE TABLE relay.iys_configs (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        mode text NOT NULL
          CONSTRAINT iys_configs_mode_check CHECK (mode IN ('own', 'integrator')),
        api text NOT NULL
          CONSTRAINT iys_configs_api_check CHECK (api IN ('production', 'sandbox')),
        iys_code bigint NOT NULL CONSTRAINT iys_configs_iys_code_check CHECK (iys_code > 0),
        integrator_code bigint
          CONSTRAINT iys_configs_integrator_code_check CHECK (integrator_code > 0),
        username text NOT NULL
          CONSTRAINT iys_configs_username_check CHECK (char_length(username) BETWEEN 1 AND 256),
        credential_ref_id uuid NOT NULL,
        consent_limit bigint
          CONSTRAINT iys_configs_consent_limit_check CHECK (consent_limit >= 0),
        used_consent_limit bigint
          CONSTRAINT iys_configs_used_consent_limit_check CHECK (used_consent_limit >= 0),
        consent_limit_exceed boolean,
        quota_state text NOT NULL
          CONSTRAINT iys_configs_quota_state_check
            CHECK (quota_state IN ('unknown', 'ok', 'warning', 'full')),
        quota_checked_at timestamptz,
        blocked_code text
          CONSTRAINT iys_configs_blocked_code_check
            CHECK (char_length(blocked_code) BETWEEN 1 AND 64),
        blocked_at timestamptz,
        version bigint NOT NULL CONSTRAINT iys_configs_version_check CHECK (version >= 1),
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT iys_configs_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT iys_configs_scope_key UNIQUE (tenant_id, environment),
        CONSTRAINT iys_configs_integrator_check
          CHECK ((mode = 'integrator') = (integrator_code IS NOT NULL)),
        CONSTRAINT iys_configs_blocked_check
          CHECK ((blocked_code IS NULL) = (blocked_at IS NULL)),
        CONSTRAINT iys_configs_credential_ref_id_fkey
          FOREIGN KEY (tenant_id, environment, credential_ref_id)
          REFERENCES relay.secret_refs (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      ~S"""
      CREATE TABLE relay.iys_brands (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        brand_code bigint NOT NULL
          CONSTRAINT iys_brands_brand_code_check CHECK (brand_code > 0),
        name text CONSTRAINT iys_brands_name_check CHECK (char_length(name) BETWEEN 1 AND 256),
        subtenant_id uuid,
        sender_identity_id uuid,
        state text NOT NULL
          CONSTRAINT iys_brands_state_check CHECK (state IN ('active', 'archived')),
        message_access text NOT NULL
          CONSTRAINT iys_brands_message_access_check
            CHECK (message_access IN ('unknown', 'none', 'read', 'write')),
        call_access text NOT NULL
          CONSTRAINT iys_brands_call_access_check
            CHECK (call_access IN ('unknown', 'none', 'read', 'write')),
        email_access text NOT NULL
          CONSTRAINT iys_brands_email_access_check
            CHECK (email_access IN ('unknown', 'none', 'read', 'write')),
        authorised_at timestamptz,
        archived_at timestamptz,
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT iys_brands_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT iys_brands_brand_code_key UNIQUE (tenant_id, environment, brand_code),
        CONSTRAINT iys_brands_archived_check
          CHECK ((state = 'archived') = (archived_at IS NOT NULL)),
        CONSTRAINT iys_brands_subtenant_id_fkey
          FOREIGN KEY (tenant_id, environment, subtenant_id)
          REFERENCES relay.subtenants (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT iys_brands_sender_identity_id_fkey
          FOREIGN KEY (tenant_id, environment, sender_identity_id)
          REFERENCES relay.sender_identities (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE UNIQUE INDEX iys_brands_binding_key ON relay.iys_brands
        (tenant_id, environment, subtenant_id) NULLS NOT DISTINCT
        WHERE state = 'active' AND sender_identity_id IS NULL
      """,
      """
      CREATE UNIQUE INDEX iys_brands_sender_identity_key ON relay.iys_brands
        (tenant_id, environment, sender_identity_id)
        WHERE state = 'active' AND sender_identity_id IS NOT NULL
      """,
      ~S"""
      CREATE TABLE relay.iys_uploads (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        brand_id uuid,
        consent_type text NOT NULL
          CONSTRAINT iys_uploads_consent_type_check
            CHECK (consent_type IN ('MESAJ', 'ARAMA', 'EPOSTA')),
        consent_status text NOT NULL
          CONSTRAINT iys_uploads_consent_status_check CHECK (consent_status IN ('ONAY', 'RET')),
        recipient_type text NOT NULL
          CONSTRAINT iys_uploads_recipient_type_check
            CHECK (recipient_type IN ('BIREYSEL', 'TACIR')),
        source text NOT NULL
          CONSTRAINT iys_uploads_source_check CHECK (source ~ '^[A-Z][A-Z0-9_]{1,31}$'),
        origin text NOT NULL
          CONSTRAINT iys_uploads_origin_check CHECK (origin IN ('access', 'refusal')),
        consent_at timestamptz NOT NULL,
        recipient_id uuid,
        consent_id uuid,
        address_ct bytea,
        address_key_id uuid,
        address_digest bytea NOT NULL
          CONSTRAINT iys_uploads_address_digest_check CHECK (octet_length(address_digest) = 32),
        address_digest_key_id uuid NOT NULL,
        state text NOT NULL
          CONSTRAINT iys_uploads_state_check
            CHECK (state IN ('pending', 'uploaded', 'confirmed', 'failed', 'expired', 'skipped')),
        deadline_at timestamptz,
        attempts bigint NOT NULL CONSTRAINT iys_uploads_attempts_check CHECK (attempts >= 0),
        claimed_until timestamptz,
        error_code text
          CONSTRAINT iys_uploads_error_code_check CHECK (char_length(error_code) BETWEEN 1 AND 64),
        error_at timestamptz,
        transaction_ref text
          CONSTRAINT iys_uploads_transaction_ref_check
            CHECK (char_length(transaction_ref) BETWEEN 1 AND 128),
        registered_at timestamptz,
        trace_ref text
          CONSTRAINT iys_uploads_trace_ref_check CHECK (char_length(trace_ref) BETWEEN 1 AND 64),
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        settled_at timestamptz,
        CONSTRAINT iys_uploads_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT iys_uploads_address_check
          CHECK ((address_ct IS NULL) = (address_key_id IS NULL)),
        CONSTRAINT iys_uploads_deadline_check
          CHECK (consent_status = 'RET' OR deadline_at IS NOT NULL),
        CONSTRAINT iys_uploads_settled_check
          CHECK ((state IN ('confirmed', 'failed', 'expired', 'skipped'))
            = (settled_at IS NOT NULL)),
        CONSTRAINT iys_uploads_error_check CHECK ((error_code IS NULL) = (error_at IS NULL)),
        CONSTRAINT iys_uploads_brand_id_fkey FOREIGN KEY (tenant_id, environment, brand_id)
          REFERENCES relay.iys_brands (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT iys_uploads_recipient_id_fkey
          FOREIGN KEY (tenant_id, environment, recipient_id)
          REFERENCES relay.recipients (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT iys_uploads_consent_id_fkey FOREIGN KEY (tenant_id, environment, consent_id)
          REFERENCES relay.consents (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT iys_uploads_address_key_id_fkey
          FOREIGN KEY (tenant_id, environment, address_key_id)
          REFERENCES relay.tenant_keys (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT iys_uploads_address_digest_key_id_fkey
          FOREIGN KEY (tenant_id, environment, address_digest_key_id)
          REFERENCES relay.blind_index_keys (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE INDEX iys_uploads_key_index ON relay.iys_uploads
        (tenant_id, environment, brand_id, consent_type, address_digest, id)
      """,
      """
      CREATE INDEX iys_uploads_open_index ON relay.iys_uploads
        (tenant_id, environment, deadline_at) WHERE state IN ('pending', 'uploaded')
      """,
      """
      CREATE INDEX iys_uploads_state_index ON relay.iys_uploads
        (tenant_id, environment, state, id)
      """
    ]
  end
end
