defmodule Relay.Repo.Migrations.CreatePreferenceTables do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  @tables ~w(categories category_subtenant_settings preferences preference_changes
             preference_profiles consents suppressions)
  @append_only ~w(preference_changes consents)

  # PC-57 (1)
  # PC-57 (2)
  # PC-57 (5)
  # PC-59 (1)
  # PC-59 (2)
  # PC-1
  # PC-6
  # PC-16
  # PC-20
  # OP-20
  # TN-12
  # TN-13
  # INV-6
  def up do
    Enum.each(statements(), &execute/1)
    Enum.each(@tables, &scoped/1)
    Enum.each(@append_only, &append_only/1)
  end

  defp scoped(table) do
    execute("ALTER TABLE relay.#{table} ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE relay.#{table} FORCE ROW LEVEL SECURITY")

    execute(
      "CREATE POLICY #{table}_scope ON relay.#{table} USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})"
    )

    privileges = if table in @append_only, do: "SELECT, INSERT", else: "SELECT, INSERT, UPDATE"
    execute("GRANT #{privileges} ON relay.#{table} TO relay_owner")

    execute(
      "GRANT SELECT ON relay.#{table} TO relay_app, relay_maint, relay_archive, relay_report"
    )
  end

  defp append_only(table) do
    execute("""
    CREATE TRIGGER #{table}_no_mutation BEFORE UPDATE OR DELETE ON relay.#{table}
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
      CREATE TABLE relay.categories (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        key text NOT NULL CONSTRAINT categories_key_check CHECK (key ~ '^[a-z][a-z0-9_]{0,63}$'),
        name text NOT NULL CONSTRAINT categories_name_check CHECK (char_length(name) BETWEEN 1 AND 200),
        message_class relay.message_class NOT NULL,
        locked boolean NOT NULL,
        enabled boolean NOT NULL,
        channel_defaults jsonb NOT NULL
          CONSTRAINT categories_channel_defaults_check
            CHECK (jsonb_typeof(channel_defaults) = 'object' AND pg_column_size(channel_defaults) <= 4096),
        default_expires_in interval
          CONSTRAINT categories_default_expires_in_check
            CHECK (default_expires_in BETWEEN interval '1 minute' AND interval '30 days'),
        frequency_limit bigint
          CONSTRAINT categories_frequency_limit_check CHECK (frequency_limit BETWEEN 1 AND 10000),
        frequency_window interval
          CONSTRAINT categories_frequency_window_check
            CHECK (frequency_window BETWEEN interval '1 hour' AND interval '7 days'),
        frequency_fate text
          CONSTRAINT categories_frequency_fate_check
            CHECK (frequency_fate IN ('drop', 'defer', 'digest', 'inbox_only')),
        digest_allowed boolean NOT NULL,
        builtin boolean NOT NULL,
        state text NOT NULL CONSTRAINT categories_state_check CHECK (state IN ('active', 'archived')),
        archived_at timestamptz,
        version bigint NOT NULL CONSTRAINT categories_version_check CHECK (version >= 1),
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT categories_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT categories_key_key UNIQUE (tenant_id, environment, key),
        CONSTRAINT categories_security_locked_check
          CHECK (message_class <> 'security' OR locked),
        CONSTRAINT categories_lockable_check
          CHECK (NOT locked OR message_class IN ('security', 'transactional', 'operational',
            'action_required')),
        CONSTRAINT categories_security_expires_check
          CHECK (message_class <> 'security' OR default_expires_in IS NULL),
        CONSTRAINT categories_digest_allowed_check
          CHECK (NOT digest_allowed OR message_class = 'operational'),
        CONSTRAINT categories_frequency_check
          CHECK ((frequency_limit IS NULL) = (frequency_window IS NULL)
            AND (frequency_limit IS NULL) = (frequency_fate IS NULL)),
        CONSTRAINT categories_frequency_class_check
          CHECK (frequency_limit IS NULL OR message_class IN ('marketing', 'social', 'operational')),
        CONSTRAINT categories_archived_check CHECK ((state = 'archived') = (archived_at IS NOT NULL))
      )
      """,
      ~S"""
      CREATE FUNCTION relay_private.categories_guard() RETURNS trigger
        LANGUAGE plpgsql
        SET search_path = pg_catalog, pg_temp
        SET TimeZone = 'UTC'
      AS $fn$
      BEGIN
        IF NEW.tenant_id = OLD.tenant_id AND NEW.environment = OLD.environment
          AND NEW.id = OLD.id AND NEW.key = OLD.key AND NEW.message_class = OLD.message_class
          AND NEW.builtin = OLD.builtin AND NEW.created_at = OLD.created_at
          AND (OLD.state = 'active' OR NEW.state = 'archived') THEN
          RETURN NEW;
        END IF;
        RAISE EXCEPTION 'invariant_violation'
          USING DETAIL = format('%s on %I.%I is not allowed', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME),
                HINT = 'PC-1';
      END
      $fn$
      """,
      "REVOKE ALL ON FUNCTION relay_private.categories_guard() FROM PUBLIC",
      """
      CREATE TRIGGER categories_guard BEFORE UPDATE ON relay.categories
        FOR EACH ROW EXECUTE FUNCTION relay_private.categories_guard()
      """,
      """
      CREATE TRIGGER categories_no_delete BEFORE DELETE ON relay.categories
        FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
      """,
      ~S"""
      CREATE TABLE relay.category_subtenant_settings (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        category_id uuid NOT NULL,
        subtenant_id uuid NOT NULL,
        enabled boolean,
        channel_defaults jsonb
          CONSTRAINT category_subtenant_settings_channel_defaults_check
            CHECK (jsonb_typeof(channel_defaults) = 'object' AND pg_column_size(channel_defaults) <= 4096),
        default_expires_in interval
          CONSTRAINT category_subtenant_settings_default_expires_in_check
            CHECK (default_expires_in BETWEEN interval '1 minute' AND interval '30 days'),
        frequency_limit bigint
          CONSTRAINT category_subtenant_settings_frequency_limit_check
            CHECK (frequency_limit BETWEEN 1 AND 10000),
        frequency_window interval
          CONSTRAINT category_subtenant_settings_frequency_window_check
            CHECK (frequency_window BETWEEN interval '1 hour' AND interval '7 days'),
        frequency_fate text
          CONSTRAINT category_subtenant_settings_frequency_fate_check
            CHECK (frequency_fate IN ('drop', 'defer', 'digest', 'inbox_only')),
        version bigint NOT NULL
          CONSTRAINT category_subtenant_settings_version_check CHECK (version >= 1),
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT category_subtenant_settings_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT category_subtenant_settings_category_subtenant_key
          UNIQUE (tenant_id, environment, category_id, subtenant_id),
        CONSTRAINT category_subtenant_settings_frequency_check
          CHECK ((frequency_limit IS NULL) = (frequency_window IS NULL)
            AND (frequency_limit IS NULL) = (frequency_fate IS NULL)),
        CONSTRAINT category_subtenant_settings_category_id_fkey
          FOREIGN KEY (tenant_id, environment, category_id)
          REFERENCES relay.categories (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT category_subtenant_settings_subtenant_id_fkey
          FOREIGN KEY (tenant_id, environment, subtenant_id)
          REFERENCES relay.subtenants (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE TRIGGER category_subtenant_settings_no_delete BEFORE DELETE
        ON relay.category_subtenant_settings
        FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
      """,
      ~S"""
      CREATE TABLE relay.preferences (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        recipient_id uuid NOT NULL,
        level text NOT NULL
          CONSTRAINT preferences_level_check
            CHECK (level IN ('category_channel', 'channel', 'workflow', 'scope_key')),
        key text CONSTRAINT preferences_key_check CHECK (char_length(key) BETWEEN 1 AND 256),
        channel relay.channel,
        value text NOT NULL
          CONSTRAINT preferences_value_check CHECK (value IN ('opt_in', 'opt_out', 'unset')),
        updated_by text NOT NULL
          CONSTRAINT preferences_updated_by_check
            CHECK (updated_by IN ('subscriber', 'tenant', 'access', 'unsubscribe')),
        version bigint NOT NULL CONSTRAINT preferences_version_check CHECK (version >= 1),
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT preferences_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT preferences_shape_check
          CHECK ((level = 'category_channel' AND key IS NOT NULL AND channel IS NOT NULL)
            OR (level = 'channel' AND key IS NULL AND channel IS NOT NULL)
            OR (level IN ('workflow', 'scope_key') AND key IS NOT NULL)),
        CONSTRAINT preferences_recipient_id_fkey FOREIGN KEY (tenant_id, environment, recipient_id)
          REFERENCES relay.recipients (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE UNIQUE INDEX preferences_cell_key ON relay.preferences
        (tenant_id, environment, recipient_id, level, key, channel) NULLS NOT DISTINCT
      """,
      """
      CREATE TRIGGER preferences_no_delete BEFORE DELETE ON relay.preferences
        FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
      """,
      ~S"""
      CREATE TABLE relay.preference_changes (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        preference_id uuid NOT NULL,
        recipient_id uuid NOT NULL,
        old_value text
          CONSTRAINT preference_changes_old_value_check
            CHECK (old_value IN ('opt_in', 'opt_out', 'unset')),
        new_value text NOT NULL
          CONSTRAINT preference_changes_new_value_check
            CHECK (new_value IN ('opt_in', 'opt_out', 'unset')),
        writer text NOT NULL
          CONSTRAINT preference_changes_writer_check
            CHECK (writer IN ('subscriber', 'tenant', 'access', 'unsubscribe')),
        actor_ref text
          CONSTRAINT preference_changes_actor_ref_check CHECK (char_length(actor_ref) <= 256),
        created_at timestamptz NOT NULL,
        CONSTRAINT preference_changes_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT preference_changes_preference_id_fkey
          FOREIGN KEY (tenant_id, environment, preference_id)
          REFERENCES relay.preferences (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT preference_changes_recipient_id_fkey
          FOREIGN KEY (tenant_id, environment, recipient_id)
          REFERENCES relay.recipients (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE INDEX preference_changes_recipient_index ON relay.preference_changes
        (tenant_id, environment, recipient_id, created_at)
      """,
      """
      CREATE INDEX preference_changes_preference_index ON relay.preference_changes
        (tenant_id, environment, preference_id)
      """,
      ~S"""
      CREATE TABLE relay.preference_profiles (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        recipient_id uuid NOT NULL,
        quiet_hours jsonb NOT NULL
          CONSTRAINT preference_profiles_quiet_hours_check
            CHECK (jsonb_typeof(quiet_hours) = 'array' AND pg_column_size(quiet_hours) <= 8192),
        schedule jsonb NOT NULL
          CONSTRAINT preference_profiles_schedule_check
            CHECK (jsonb_typeof(schedule) = 'array' AND pg_column_size(schedule) <= 8192),
        dnd_until timestamptz,
        quiet_hours_email boolean NOT NULL,
        digest jsonb NOT NULL
          CONSTRAINT preference_profiles_digest_check
            CHECK (jsonb_typeof(digest) = 'object' AND pg_column_size(digest) <= 16384),
        updated_by text NOT NULL
          CONSTRAINT preference_profiles_updated_by_check
            CHECK (updated_by IN ('subscriber', 'access')),
        version bigint NOT NULL CONSTRAINT preference_profiles_version_check CHECK (version >= 1),
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT preference_profiles_pkey PRIMARY KEY (tenant_id, environment, recipient_id),
        CONSTRAINT preference_profiles_recipient_id_fkey
          FOREIGN KEY (tenant_id, environment, recipient_id)
          REFERENCES relay.recipients (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE TRIGGER preference_profiles_no_delete BEFORE DELETE ON relay.preference_profiles
        FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
      """,
      ~S"""
      CREATE TABLE relay.consents (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        recipient_id uuid NOT NULL,
        brand_subtenant_id uuid,
        channel relay.channel NOT NULL,
        status text NOT NULL
          CONSTRAINT consents_status_check
            CHECK (status IN ('none', 'pending', 'active', 'revoked', 'expired')),
        consent_kind text
          CONSTRAINT consents_consent_kind_check
            CHECK (consent_kind IN ('explicit_opt_in', 'soft_opt_in', 'legitimate_interest', 'none')),
        recipient_type text
          CONSTRAINT consents_recipient_type_check CHECK (recipient_type IN ('individual', 'merchant')),
        source text NOT NULL
          CONSTRAINT consents_source_check CHECK (source ~ '^[a-z][a-z0-9_]{0,63}$'),
        source_sequence bigint NOT NULL
          CONSTRAINT consents_source_sequence_check CHECK (source_sequence >= 0),
        occurred_at timestamptz NOT NULL,
        text_version_digest relay.sha256,
        evidence_ct bytea,
        evidence_key_id uuid,
        iys_transaction_ref text
          CONSTRAINT consents_iys_transaction_ref_check
            CHECK (char_length(iys_transaction_ref) BETWEEN 1 AND 128),
        writer text NOT NULL CONSTRAINT consents_writer_check CHECK (writer IN ('access', 'relay')),
        source_event_ref text
          CONSTRAINT consents_source_event_ref_check
            CHECK (char_length(source_event_ref) BETWEEN 1 AND 256),
        created_at timestamptz NOT NULL,
        CONSTRAINT consents_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT consents_evidence_check CHECK ((evidence_ct IS NULL) = (evidence_key_id IS NULL)),
        CONSTRAINT consents_active_evidence_check
          CHECK (status <> 'active' OR (text_version_digest IS NOT NULL AND evidence_ct IS NOT NULL
            AND consent_kind IS NOT NULL AND recipient_type IS NOT NULL)),
        CONSTRAINT consents_recipient_id_fkey FOREIGN KEY (tenant_id, environment, recipient_id)
          REFERENCES relay.recipients (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT consents_brand_subtenant_id_fkey
          FOREIGN KEY (tenant_id, environment, brand_subtenant_id)
          REFERENCES relay.subtenants (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT consents_evidence_key_id_fkey FOREIGN KEY (tenant_id, environment, evidence_key_id)
          REFERENCES relay.subject_keys (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE UNIQUE INDEX consents_sequence_key ON relay.consents
        (tenant_id, environment, recipient_id, brand_subtenant_id, channel, source, source_sequence)
        NULLS NOT DISTINCT
      """,
      ~S"""
      CREATE TABLE relay.suppressions (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        channel relay.channel NOT NULL,
        target_digest bytea NOT NULL
          CONSTRAINT suppressions_target_digest_check CHECK (octet_length(target_digest) = 32),
        target_digest_key_id uuid NOT NULL,
        target_digest_next bytea
          CONSTRAINT suppressions_target_digest_next_check
            CHECK (octet_length(target_digest_next) = 32),
        reason text NOT NULL
          CONSTRAINT suppressions_reason_check
            CHECK (reason IN ('hard_bounce', 'complaint', 'invalid', 'soft_bounce', 'manual')),
        expires_at timestamptz,
        created_by_ref text NOT NULL
          CONSTRAINT suppressions_created_by_ref_check
            CHECK (char_length(created_by_ref) BETWEEN 1 AND 256),
        lifted_at timestamptz,
        lifted_by_ref text
          CONSTRAINT suppressions_lifted_by_ref_check CHECK (char_length(lifted_by_ref) BETWEEN 1 AND 256),
        lift_reason text
          CONSTRAINT suppressions_lift_reason_check CHECK (char_length(lift_reason) BETWEEN 1 AND 2000),
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT suppressions_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT suppressions_expiry_check
          CHECK ((reason = 'soft_bounce' AND expires_at IS NOT NULL)
            OR (reason = 'manual') OR expires_at IS NULL),
        CONSTRAINT suppressions_lifted_check
          CHECK ((lifted_at IS NULL) = (lifted_by_ref IS NULL)
            AND (lifted_at IS NULL) = (lift_reason IS NULL)),
        CONSTRAINT suppressions_target_digest_key_id_fkey
          FOREIGN KEY (tenant_id, environment, target_digest_key_id)
          REFERENCES relay.blind_index_keys (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE INDEX suppressions_target_digest_index ON relay.suppressions
        (tenant_id, environment, channel, target_digest) WHERE lifted_at IS NULL
      """,
      """
      CREATE INDEX suppressions_target_digest_next_index ON relay.suppressions
        (tenant_id, environment, channel, target_digest_next)
        WHERE lifted_at IS NULL AND target_digest_next IS NOT NULL
      """,
      """
      CREATE INDEX suppressions_created_index ON relay.suppressions
        (tenant_id, environment, created_at, id)
      """,
      """
      CREATE TRIGGER suppressions_no_delete BEFORE DELETE ON relay.suppressions
        FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
      """
    ]
  end
end
