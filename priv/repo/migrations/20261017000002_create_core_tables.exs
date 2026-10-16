defmodule Relay.Repo.Migrations.CreateCoreTables do
  use Ecto.Migration

  @grants %{
    root: [
      {"SELECT, UPDATE", "relay_owner"},
      {"SELECT", "relay_app, relay_maint, relay_archive, relay_report"}
    ],
    tenant: [
      {"SELECT, INSERT, UPDATE", "relay_owner"},
      {"SELECT", "relay_app, relay_maint, relay_archive, relay_report"}
    ],
    tenant_append: [
      {"SELECT, INSERT", "relay_owner"},
      {"SELECT", "relay_app, relay_maint, relay_archive, relay_report"}
    ],
    key: [{"SELECT, INSERT, UPDATE", "relay_owner"}, {"SELECT", "relay_app, relay_maint"}],
    audit: [{"SELECT, INSERT", "relay_owner"}, {"SELECT", "relay_maint, relay_archive"}],
    receipt: [{"SELECT, INSERT, UPDATE", "relay_owner"}, {"SELECT", "relay_maint, relay_archive"}],
    installation: [{"SELECT", "relay_owner, relay_app, relay_maint, relay_archive"}],
    installation_maint: [
      {"SELECT", "relay_owner, relay_app, relay_archive"},
      {"SELECT, INSERT, UPDATE", "relay_maint"}
    ],
    installation_audit: [
      {"SELECT", "relay_owner, relay_app, relay_archive"},
      {"SELECT, INSERT", "relay_maint"}
    ],
    audit_leaves: [{"SELECT", "relay_owner, relay_archive"}, {"SELECT, INSERT", "relay_maint"}]
  }

  @tenant_scope "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"

  # TN-11
  # TN-12
  # TN-13
  # INV-36
  # INV-37
  # OP-1
  # OP-2
  # OP-9
  # OP-13
  # OP-66
  def up do
    Enum.each(statements(), &execute/1)
  end

  defp statements do
    List.flatten([
      installation(),
      tenancy(),
      keys(),
      delivery(),
      intake(),
      audit(),
      datasets(),
      operations()
    ])
  end

  defp installation do
    [
      ~S"""
      CREATE TABLE relay.tenants (
        id uuid NOT NULL,
        kind text NOT NULL CONSTRAINT tenants_kind_check CHECK (kind IN ('installation', 'tenant')),
        access_tenant_id text NOT NULL
          CONSTRAINT tenants_access_tenant_id_check CHECK (char_length(access_tenant_id) <= 128),
        region relay.region NOT NULL,
        sector text NOT NULL DEFAULT 'general'
          CONSTRAINT tenants_sector_check CHECK (sector ~ '^[a-z][a-z0-9_]{1,31}$'),
        default_timezone text NOT NULL
          CONSTRAINT tenants_default_timezone_check CHECK (
            default_timezone ~ '^[A-Za-z]+(/[A-Za-z0-9_+-]+)*$'
            AND default_timezone !~ '^Etc/GMT'
            AND default_timezone !~ '^(UTC|GMT)[+-]'
          ),
        default_locale text NOT NULL
          CONSTRAINT tenants_default_locale_check
            CHECK (default_locale ~ '^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$'),
        status text NOT NULL
          CONSTRAINT tenants_status_check CHECK (status IN ('active', 'suspended', 'closed')),
        status_reason text,
        status_changed_at timestamptz NOT NULL,
        closed_at timestamptz,
        version bigint NOT NULL DEFAULT 1,
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT tenants_pkey PRIMARY KEY (id),
        CONSTRAINT tenants_access_tenant_id_key UNIQUE (access_tenant_id),
        CONSTRAINT tenants_status_reason_check CHECK (status = 'active' OR status_reason IS NOT NULL),
        CONSTRAINT tenants_closed_at_check CHECK ((status = 'closed') = (closed_at IS NOT NULL))
      )
      """,
      "ALTER TABLE relay.tenants ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE relay.tenants FORCE ROW LEVEL SECURITY",
      """
      CREATE POLICY tenants_scope ON relay.tenants
        USING (id = (select current_setting('relay.tenant_id')::uuid))
        WITH CHECK (id = (select current_setting('relay.tenant_id')::uuid))
      """,
      grant("tenants", :root),
      ~S"""
      CREATE TABLE relay.installation (
        singleton boolean NOT NULL CONSTRAINT installation_singleton_check CHECK (singleton),
        region relay.region NOT NULL,
        installation_tenant_id uuid NOT NULL,
        created_at timestamptz NOT NULL,
        CONSTRAINT installation_pkey PRIMARY KEY (singleton),
        CONSTRAINT installation_installation_tenant_id_fkey FOREIGN KEY (installation_tenant_id)
          REFERENCES relay.tenants (id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      grant("installation", :installation),
      ~S"""
      CREATE FUNCTION relay_private.installation_tenant_id() RETURNS uuid
        LANGUAGE sql
        STABLE
        SECURITY DEFINER
        SET search_path = pg_catalog, pg_temp
        SET TimeZone = 'UTC'
      AS $$
        SELECT installation_tenant_id FROM relay.installation WHERE singleton
      $$
      """,
      "REVOKE ALL ON FUNCTION relay_private.installation_tenant_id() FROM PUBLIC",
      """
      GRANT EXECUTE ON FUNCTION relay_private.installation_tenant_id()
        TO relay_owner, relay_app, relay_maint, relay_archive, relay_report
      """
    ]
  end

  defp tenancy do
    [
      ~S"""
      CREATE TABLE relay.subtenants (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        access_organization_id text NOT NULL
          CONSTRAINT subtenants_access_organization_id_check
            CHECK (char_length(access_organization_id) <= 128),
        name text NOT NULL CONSTRAINT subtenants_name_check CHECK (char_length(name) BETWEEN 1 AND 200),
        state text NOT NULL CONSTRAINT subtenants_state_check CHECK (state IN ('active', 'archived')),
        archived_at timestamptz,
        version bigint NOT NULL DEFAULT 1,
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT subtenants_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT subtenants_access_organization_id_key
          UNIQUE (tenant_id, environment, access_organization_id),
        CONSTRAINT subtenants_archived_at_check CHECK ((state = 'archived') = (archived_at IS NOT NULL)),
        CONSTRAINT subtenants_tenant_id_fkey FOREIGN KEY (tenant_id)
          REFERENCES relay.tenants (id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      scoped("subtenants", :tenant),
      ~S"""
      CREATE TABLE relay.settings (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        subtenant_id uuid,
        key text NOT NULL
          CONSTRAINT settings_key_check
            CHECK (key ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$' AND char_length(key) <= 128),
        value jsonb CONSTRAINT settings_value_check CHECK (pg_column_size(value) <= 16384),
        version bigint NOT NULL DEFAULT 1,
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT settings_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT settings_scope_key_key
          UNIQUE NULLS NOT DISTINCT (tenant_id, environment, subtenant_id, key),
        CONSTRAINT settings_subtenant_id_fkey FOREIGN KEY (tenant_id, environment, subtenant_id)
          REFERENCES relay.subtenants (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      scoped("settings", :tenant)
    ]
  end

  defp keys do
    [
      ~S"""
      CREATE TABLE relay.tenant_keys (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        purpose text NOT NULL
          CONSTRAINT tenant_keys_purpose_check CHECK (purpose IN ('data', 'dek_wrap', 'receipt_day')),
        valid_day date,
        kek_ref text NOT NULL CONSTRAINT tenant_keys_kek_ref_check CHECK (char_length(kek_ref) <= 512),
        wrapped_key bytea,
        state text NOT NULL
          CONSTRAINT tenant_keys_state_check CHECK (state IN ('active', 'retired', 'destroyed')),
        destroyed_at timestamptz,
        created_at timestamptz NOT NULL,
        CONSTRAINT tenant_keys_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT tenant_keys_valid_day_check
          CHECK ((purpose = 'receipt_day') = (valid_day IS NOT NULL)),
        CONSTRAINT tenant_keys_wrapped_key_check CHECK ((state = 'destroyed') = (wrapped_key IS NULL))
      )
      """,
      """
      CREATE UNIQUE INDEX tenant_keys_active_purpose_key ON relay.tenant_keys
        (tenant_id, environment, purpose) WHERE state = 'active' AND purpose <> 'receipt_day'
      """,
      """
      CREATE UNIQUE INDEX tenant_keys_receipt_day_key ON relay.tenant_keys
        (tenant_id, environment, valid_day) WHERE purpose = 'receipt_day'
      """,
      scoped("tenant_keys", :key),
      ~S"""
      CREATE TABLE relay.blind_index_keys (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        hsm_ref text NOT NULL,
        state text NOT NULL
          CONSTRAINT blind_index_keys_state_check CHECK (state IN ('active', 'rotating', 'retired')),
        created_at timestamptz NOT NULL,
        retired_at timestamptz,
        CONSTRAINT blind_index_keys_pkey PRIMARY KEY (tenant_id, environment, id)
      )
      """,
      """
      CREATE UNIQUE INDEX blind_index_keys_active_key ON relay.blind_index_keys
        (tenant_id, environment) WHERE state = 'active'
      """,
      scoped("blind_index_keys", :key),
      ~S"""
      CREATE TABLE relay.recipients (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        kind text NOT NULL CONSTRAINT recipients_kind_check CHECK (kind IN ('subscriber', 'agent')),
        external_id_bidx bytea
          CONSTRAINT recipients_external_id_bidx_check CHECK (octet_length(external_id_bidx) = 32),
        external_id_bidx_key_id uuid,
        external_id_bidx_next bytea
          CONSTRAINT recipients_external_id_bidx_next_check
            CHECK (octet_length(external_id_bidx_next) = 32),
        external_id_ct bytea NOT NULL,
        external_id_key_id uuid NOT NULL,
        state text NOT NULL CONSTRAINT recipients_state_check CHECK (state IN ('active', 'deleted')),
        deleted_at timestamptz,
        deleted_reason text
          CONSTRAINT recipients_deleted_reason_check
            CHECK (deleted_reason IN ('erasure', 'retention_end', 'tenant_closed', 'operator')),
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT recipients_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT recipients_external_id_bidx_key UNIQUE (tenant_id, environment, external_id_bidx),
        CONSTRAINT recipients_deleted_at_check CHECK ((state = 'deleted') = (deleted_at IS NOT NULL)),
        CONSTRAINT recipients_external_id_bidx_key_id_fkey
          FOREIGN KEY (tenant_id, environment, external_id_bidx_key_id)
          REFERENCES relay.blind_index_keys (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      scoped("recipients", :tenant),
      ~S"""
      CREATE TABLE relay.subject_keys (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        recipient_id uuid NOT NULL,
        retention_class relay.retention_class NOT NULL
          CONSTRAINT subject_keys_retention_class_check CHECK (retention_class IN ('recipient_profile',
            'notification_content', 'delivery_record', 'commercial_consent', 'commercial_message',
            'preference')),
        wrapped_dek bytea,
        wrapping_key_id uuid NOT NULL,
        state text NOT NULL
          CONSTRAINT subject_keys_state_check CHECK (state IN ('active', 'restricted', 'destroyed')),
        restricted_at timestamptz,
        destroyed_at timestamptz,
        destroy_reason text
          CONSTRAINT subject_keys_destroy_reason_check
            CHECK (destroy_reason IN ('erasure', 'retention_end', 'tenant_closed')),
        created_at timestamptz NOT NULL,
        CONSTRAINT subject_keys_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT subject_keys_recipient_class_key
          UNIQUE (tenant_id, environment, recipient_id, retention_class),
        CONSTRAINT subject_keys_destroyed_check
          CHECK ((state = 'destroyed') = (wrapped_dek IS NULL AND destroyed_at IS NOT NULL)),
        CONSTRAINT subject_keys_recipient_id_fkey FOREIGN KEY (tenant_id, environment, recipient_id)
          REFERENCES relay.recipients (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT subject_keys_wrapping_key_id_fkey
          FOREIGN KEY (tenant_id, environment, wrapping_key_id)
          REFERENCES relay.tenant_keys (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      scoped("subject_keys", :key),
      """
      ALTER TABLE relay.recipients ADD CONSTRAINT recipients_external_id_key_id_fkey
        FOREIGN KEY (tenant_id, environment, external_id_key_id)
        REFERENCES relay.subject_keys (tenant_id, environment, id)
        ON DELETE RESTRICT ON UPDATE RESTRICT DEFERRABLE INITIALLY DEFERRED
      """,
      ~S"""
      CREATE TABLE relay.secret_refs (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        kind text NOT NULL
          CONSTRAINT secret_refs_kind_check
            CHECK (kind IN ('provider_credential', 'channel_identity', 'webhook_signing')),
        ref text CONSTRAINT secret_refs_ref_check CHECK (ref IS NULL OR ref !~ '://[^/]*:[^@/]*@'),
        secret_ct bytea,
        secret_key_id uuid,
        ref_version bigint NOT NULL,
        fingerprint relay.sha256 NOT NULL,
        state text NOT NULL CONSTRAINT secret_refs_state_check CHECK (state IN ('active', 'retired')),
        created_at timestamptz NOT NULL,
        retired_at timestamptz,
        CONSTRAINT secret_refs_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT secret_refs_fingerprint_key UNIQUE (tenant_id, environment, kind, fingerprint),
        CONSTRAINT secret_refs_source_check CHECK ((ref IS NOT NULL) <> (secret_ct IS NOT NULL)),
        CONSTRAINT secret_refs_secret_key_check CHECK ((secret_ct IS NULL) = (secret_key_id IS NULL)),
        CONSTRAINT secret_refs_secret_key_id_fkey FOREIGN KEY (tenant_id, environment, secret_key_id)
          REFERENCES relay.tenant_keys (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      scoped("secret_refs", :key),
      ~S"""
      CREATE TABLE relay.legal_holds (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        scope text NOT NULL CONSTRAINT legal_holds_scope_check CHECK (scope IN ('tenant', 'recipient')),
        recipient_id uuid,
        reason text NOT NULL
          CONSTRAINT legal_holds_reason_check CHECK (char_length(reason) BETWEEN 1 AND 2000),
        state text NOT NULL CONSTRAINT legal_holds_state_check CHECK (state IN ('active', 'released')),
        placed_at timestamptz NOT NULL,
        released_at timestamptz,
        CONSTRAINT legal_holds_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT legal_holds_recipient_check CHECK ((scope = 'recipient') = (recipient_id IS NOT NULL)),
        CONSTRAINT legal_holds_recipient_id_fkey FOREIGN KEY (tenant_id, environment, recipient_id)
          REFERENCES relay.recipients (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE UNIQUE INDEX legal_holds_active_key ON relay.legal_holds
        (tenant_id, environment, scope, recipient_id) NULLS NOT DISTINCT WHERE state = 'active'
      """,
      scoped("legal_holds", :tenant),
      ~S"""
      CREATE TABLE relay.erasure_log (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        recipient_id uuid NOT NULL,
        request_ref text NOT NULL,
        destroyed_classes text[] NOT NULL,
        restricted_classes text[] NOT NULL,
        cancelled_deliveries bigint NOT NULL,
        backup_copies_expire_at timestamptz NOT NULL,
        created_at timestamptz NOT NULL,
        CONSTRAINT erasure_log_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT erasure_log_backup_copies_expire_at_check
          CHECK (backup_copies_expire_at = created_at + interval '35 days'),
        CONSTRAINT erasure_log_recipient_id_fkey FOREIGN KEY (tenant_id, environment, recipient_id)
          REFERENCES relay.recipients (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      scoped("erasure_log", :tenant_append),
      append_only("erasure_log")
    ]
  end

  defp delivery do
    [
      ~S"""
      CREATE TABLE relay.notifications (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        recipient_id uuid NOT NULL,
        subtenant_id uuid,
        dedup_key text NOT NULL
          CONSTRAINT notifications_dedup_key_check CHECK (char_length(dedup_key) BETWEEN 1 AND 512),
        message_class relay.message_class NOT NULL,
        security_subtype text
          CONSTRAINT notifications_security_subtype_check
            CHECK (security_subtype IN ('otp_oob', 'email_verification')),
        sender_type text NOT NULL
          CONSTRAINT notifications_sender_type_check CHECK (sender_type IN ('human', 'system', 'agent')),
        subject_type text
          CONSTRAINT notifications_subject_type_check CHECK (char_length(subject_type) <= 128),
        subject_id text CONSTRAINT notifications_subject_id_check CHECK (char_length(subject_id) <= 128),
        expires_at timestamptz,
        is_test boolean NOT NULL,
        state text NOT NULL
          CONSTRAINT notifications_state_check CHECK (state IN ('active', 'cancelled', 'expired')),
        closed_at timestamptz,
        close_rule_id text,
        duplicate_count bigint NOT NULL DEFAULT 0,
        last_duplicate_at timestamptz,
        traceparent text
          CONSTRAINT notifications_traceparent_check
            CHECK (traceparent ~ '^[0-9a-f]{2}-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}$'),
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT notifications_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT notifications_dedup_key_key UNIQUE (tenant_id, environment, dedup_key, recipient_id),
        CONSTRAINT notifications_id_recipient_id_key UNIQUE (tenant_id, environment, id, recipient_id),
        CONSTRAINT notifications_security_class_check
          CHECK (security_subtype IS NULL OR message_class = 'security'),
        CONSTRAINT notifications_subject_check CHECK ((subject_type IS NULL) = (subject_id IS NULL)),
        CONSTRAINT notifications_security_expiry_check
          CHECK (security_subtype IS NULL OR expires_at IS NOT NULL),
        CONSTRAINT notifications_closed_at_check CHECK ((state = 'active') = (closed_at IS NULL)),
        CONSTRAINT notifications_recipient_id_fkey FOREIGN KEY (tenant_id, environment, recipient_id)
          REFERENCES relay.recipients (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT notifications_subtenant_id_fkey FOREIGN KEY (tenant_id, environment, subtenant_id)
          REFERENCES relay.subtenants (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE INDEX notifications_recipient_created_at_index ON relay.notifications
        (tenant_id, environment, recipient_id, created_at DESC)
      """,
      scoped("notifications", :tenant),
      ~S"""
      CREATE TABLE relay.deliveries (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        notification_id uuid NOT NULL,
        recipient_id uuid NOT NULL,
        channel relay.channel NOT NULL,
        target_kind text NOT NULL
          CONSTRAINT deliveries_target_kind_check
            CHECK (target_kind IN ('address', 'device', 'inbox', 'endpoint', 'agent_mailbox')),
        target_id uuid,
        target_key bytea NOT NULL
          CONSTRAINT deliveries_target_key_check CHECK (octet_length(target_key) = 32),
        provider text,
        provider_account_id uuid,
        fallback_of uuid,
        decision text NOT NULL
          CONSTRAINT deliveries_decision_check CHECK (decision IN ('send', 'skip', 'defer')),
        decision_reason text,
        decision_rule_id text,
        deferred_until timestamptz,
        delivery_rank smallint NOT NULL
          CONSTRAINT deliveries_delivery_rank_check CHECK (delivery_rank IN (0, 1, 2)),
        accepted_at timestamptz,
        delivered_at timestamptz,
        failure_kind text
          CONSTRAINT deliveries_failure_kind_check
            CHECK (failure_kind IN ('skipped', 'failed', 'bounced', 'expired', 'cancelled')),
        failure_class text
          CONSTRAINT deliveries_failure_class_check CHECK (failure_class IN ('transient',
            'permanent_target', 'permanent_content', 'policy', 'quota', 'auth', 'sender_config',
            'unknown')),
        failure_rule_id text,
        failure_reason text,
        failure_attempt_no bigint,
        failure_provider_seq bigint,
        failure_occurred_at timestamptz,
        failure_received_at timestamptz,
        has_conflict boolean NOT NULL DEFAULT false,
        duplicate_delivered boolean NOT NULL DEFAULT false,
        attempt_count bigint NOT NULL DEFAULT 0,
        late_event_count bigint NOT NULL DEFAULT 0,
        projection_version bigint NOT NULL,
        last_event_at timestamptz,
        traceparent text
          CONSTRAINT deliveries_traceparent_check
            CHECK (traceparent ~ '^[0-9a-f]{2}-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}$'),
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT deliveries_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT deliveries_target_key
          UNIQUE (tenant_id, environment, notification_id, channel, target_key),
        CONSTRAINT deliveries_fallback_of_check CHECK (fallback_of <> id),
        CONSTRAINT deliveries_decision_rule_check
          CHECK (decision = 'send' OR decision_rule_id IS NOT NULL),
        CONSTRAINT deliveries_deferred_until_check
          CHECK ((decision = 'defer') = (deferred_until IS NOT NULL)),
        CONSTRAINT deliveries_accepted_at_check CHECK (delivery_rank < 1 OR accepted_at IS NOT NULL),
        CONSTRAINT deliveries_delivered_at_check CHECK (delivery_rank < 2 OR delivered_at IS NOT NULL),
        CONSTRAINT deliveries_notification_id_fkey
          FOREIGN KEY (tenant_id, environment, notification_id, recipient_id)
          REFERENCES relay.notifications (tenant_id, environment, id, recipient_id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT deliveries_fallback_of_fkey FOREIGN KEY (tenant_id, environment, fallback_of)
          REFERENCES relay.deliveries (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE INDEX deliveries_notification_id_index ON relay.deliveries
        (tenant_id, environment, notification_id)
      """,
      """
      CREATE INDEX deliveries_deferred_until_index ON relay.deliveries
        (tenant_id, environment, deferred_until) WHERE decision = 'defer'
      """,
      scoped("deliveries", :tenant),
      ~S"""
      CREATE TABLE relay.delivery_attempts (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        created_at timestamptz NOT NULL,
        delivery_id uuid NOT NULL,
        attempt_no bigint NOT NULL CONSTRAINT delivery_attempts_attempt_no_check CHECK (attempt_no >= 1),
        state text NOT NULL
          CONSTRAINT delivery_attempts_state_check
            CHECK (state IN ('pending', 'in_flight', 'succeeded', 'failed', 'unknown')),
        started_at timestamptz,
        finished_at timestamptz,
        provider text,
        provider_account_id uuid,
        provider_idempotency_key text,
        provider_message_id text
          CONSTRAINT delivery_attempts_provider_message_id_check
            CHECK (char_length(provider_message_id) <= 256),
        failure_class text
          CONSTRAINT delivery_attempts_failure_class_check CHECK (failure_class IN ('transient',
            'permanent_target', 'permanent_content', 'policy', 'quota', 'auth', 'sender_config',
            'unknown')),
        raw_code text CONSTRAINT delivery_attempts_raw_code_check CHECK (char_length(raw_code) <= 128),
        updated_at timestamptz NOT NULL,
        CONSTRAINT delivery_attempts_pkey PRIMARY KEY (tenant_id, environment, id, created_at),
        CONSTRAINT delivery_attempts_started_at_check CHECK (state = 'pending' OR started_at IS NOT NULL),
        CONSTRAINT delivery_attempts_finished_at_check
          CHECK ((state IN ('succeeded', 'failed', 'unknown')) = (finished_at IS NOT NULL)),
        CONSTRAINT delivery_attempts_delivery_id_fkey FOREIGN KEY (tenant_id, environment, delivery_id)
          REFERENCES relay.deliveries (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      ) PARTITION BY RANGE (created_at)
      """,
      """
      CREATE INDEX delivery_attempts_delivery_id_index ON relay.delivery_attempts
        (tenant_id, environment, delivery_id, attempt_no)
      """,
      scoped("delivery_attempts", :tenant),
      ~S"""
      CREATE TABLE relay.webhook_receipts (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        provider text NOT NULL
          CONSTRAINT webhook_receipts_provider_check CHECK (char_length(provider) <= 64),
        provider_account_id uuid,
        provider_event_id text NOT NULL
          CONSTRAINT webhook_receipts_provider_event_id_check
            CHECK (char_length(provider_event_id) BETWEEN 1 AND 512),
        body_digest relay.sha256 NOT NULL,
        body_ct bytea
          CONSTRAINT webhook_receipts_body_ct_check CHECK (octet_length(body_ct) <= 1048576 + 29),
        body_key_id uuid,
        state text NOT NULL
          CONSTRAINT webhook_receipts_state_check CHECK (state IN ('received', 'processed', 'rejected')),
        processed_at timestamptz,
        duplicate_count bigint NOT NULL DEFAULT 0,
        received_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT webhook_receipts_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT webhook_receipts_provider_event_id_key
          UNIQUE (tenant_id, environment, provider, provider_event_id),
        CONSTRAINT webhook_receipts_processed_at_check
          CHECK ((state = 'received') = (processed_at IS NULL)),
        CONSTRAINT webhook_receipts_body_key_id_fkey FOREIGN KEY (tenant_id, environment, body_key_id)
          REFERENCES relay.tenant_keys (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      scoped("webhook_receipts", :receipt),
      ~S"""
      CREATE TABLE relay.delivery_events (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        received_at timestamptz NOT NULL,
        delivery_id uuid NOT NULL,
        attempt_no bigint,
        actor text NOT NULL
          CONSTRAINT delivery_events_actor_check CHECK (actor IN ('relay', 'provider_api',
            'provider_webhook', 'client_sdk', 'user')),
        event_type relay.event_name NOT NULL,
        raw_code text CONSTRAINT delivery_events_raw_code_check CHECK (char_length(raw_code) <= 128),
        provider text,
        provider_seq bigint,
        occurred_at timestamptz NOT NULL,
        receipt_id uuid,
        projection_result text NOT NULL
          CONSTRAINT delivery_events_projection_result_check
            CHECK (projection_result IN ('applied', 'stale_ignored', 'conflict_flagged')),
        detail jsonb CONSTRAINT delivery_events_detail_check CHECK (pg_column_size(detail) <= 8192),
        evidence_version_id uuid,
        traceparent text
          CONSTRAINT delivery_events_traceparent_check
            CHECK (traceparent ~ '^[0-9a-f]{2}-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}$'),
        CONSTRAINT delivery_events_pkey PRIMARY KEY (tenant_id, environment, id, received_at),
        CONSTRAINT delivery_events_occurred_at_check
          CHECK (occurred_at <= received_at + interval '1 hour'),
        CONSTRAINT delivery_events_delivery_id_fkey FOREIGN KEY (tenant_id, environment, delivery_id)
          REFERENCES relay.deliveries (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT delivery_events_receipt_id_fkey FOREIGN KEY (tenant_id, environment, receipt_id)
          REFERENCES relay.webhook_receipts (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      ) PARTITION BY RANGE (received_at)
      """,
      """
      CREATE INDEX delivery_events_delivery_id_index ON relay.delivery_events
        (tenant_id, environment, delivery_id, received_at)
      """,
      scoped("delivery_events", :tenant_append),
      append_only("delivery_events")
    ]
  end

  defp intake do
    [
      ~S"""
      CREATE TABLE relay.idempotency_keys (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        created_at timestamptz NOT NULL,
        endpoint text NOT NULL
          CONSTRAINT idempotency_keys_endpoint_check CHECK (char_length(endpoint) <= 128),
        key relay.idempotency_key NOT NULL,
        request_fingerprint relay.sha256 NOT NULL,
        expires_at timestamptz NOT NULL,
        response_status smallint NOT NULL
          CONSTRAINT idempotency_keys_response_status_check CHECK (response_status BETWEEN 100 AND 599
            AND response_status NOT IN (400, 401, 403, 429)),
        response_headers jsonb NOT NULL
          CONSTRAINT idempotency_keys_response_headers_check
            CHECK (pg_column_size(response_headers) <= 4096),
        response_body_ct bytea NOT NULL
          CONSTRAINT idempotency_keys_response_body_ct_check
            CHECK (octet_length(response_body_ct) <= 1048576 + 29),
        response_body_key_id uuid NOT NULL,
        CONSTRAINT idempotency_keys_pkey PRIMARY KEY (tenant_id, environment, id, created_at),
        CONSTRAINT idempotency_keys_key_key UNIQUE (tenant_id, environment, endpoint, key, created_at),
        CONSTRAINT idempotency_keys_expires_at_check
          CHECK (expires_at = created_at + interval '24 hours'),
        CONSTRAINT idempotency_keys_response_body_key_id_fkey
          FOREIGN KEY (tenant_id, environment, response_body_key_id)
          REFERENCES relay.tenant_keys (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      ) PARTITION BY RANGE (created_at)
      """,
      """
      CREATE INDEX idempotency_keys_lookup_index ON relay.idempotency_keys
        (tenant_id, environment, endpoint, key, created_at DESC)
      """,
      scoped("idempotency_keys", :receipt),
      ~S"""
      CREATE TABLE relay.outbox_events (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        created_at timestamptz NOT NULL,
        event_type relay.event_name NOT NULL,
        stream_key text NOT NULL
          CONSTRAINT outbox_events_stream_key_check
            CHECK (stream_key ~ '^[a-z_]+:[A-Za-z0-9_.:-]{1,200}$'),
        epoch bigint NOT NULL,
        seq bigint NOT NULL,
        payload jsonb NOT NULL
          CONSTRAINT outbox_events_payload_check CHECK (pg_column_size(payload) <= 16384),
        state text NOT NULL
          CONSTRAINT outbox_events_state_check CHECK (state IN ('pending', 'dispatched')),
        dispatched_at timestamptz,
        traceparent text
          CONSTRAINT outbox_events_traceparent_check
            CHECK (traceparent ~ '^[0-9a-f]{2}-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}$'),
        CONSTRAINT outbox_events_pkey PRIMARY KEY (tenant_id, environment, id, created_at),
        CONSTRAINT outbox_events_dispatched_at_check
          CHECK ((state = 'dispatched') = (dispatched_at IS NOT NULL))
      ) PARTITION BY RANGE (created_at)
      """,
      """
      CREATE INDEX outbox_events_pending_index ON relay.outbox_events
        (tenant_id, environment, created_at, id) WHERE state = 'pending'
      """,
      scoped("outbox_events", :tenant),
      ~S"""
      CREATE TABLE relay.stream_heads (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        stream_key text NOT NULL,
        epoch bigint NOT NULL DEFAULT 1,
        last_seq bigint NOT NULL DEFAULT 0,
        updated_at timestamptz NOT NULL,
        CONSTRAINT stream_heads_pkey PRIMARY KEY (tenant_id, environment, stream_key)
      )
      """,
      scoped("stream_heads", :tenant),
      ~S"""
      CREATE TABLE relay.usage_records (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        usage_day date NOT NULL,
        channel relay.channel NOT NULL,
        provider text NOT NULL,
        destination_country text
          CONSTRAINT usage_records_destination_country_check CHECK (destination_country ~ '^[A-Z]{2}$'),
        destination_operator text
          CONSTRAINT usage_records_destination_operator_check
            CHECK (char_length(destination_operator) <= 64),
        whatsapp_category text,
        outcome text NOT NULL
          CONSTRAINT usage_records_outcome_check
            CHECK (outcome IN ('accepted', 'failed', 'late_adjustment')),
        is_test boolean NOT NULL,
        quantity bigint NOT NULL CONSTRAINT usage_records_quantity_check CHECK (quantity >= 0),
        attempt_count bigint NOT NULL
          CONSTRAINT usage_records_attempt_count_check CHECK (attempt_count >= 0),
        sms_segments bigint,
        cost_micros bigint,
        currency text CONSTRAINT usage_records_currency_check CHECK (currency ~ '^[A-Z]{3}$'),
        created_at timestamptz NOT NULL,
        CONSTRAINT usage_records_pkey PRIMARY KEY (tenant_id, environment, id, usage_day),
        CONSTRAINT usage_records_dimensions_key UNIQUE NULLS NOT DISTINCT (tenant_id, environment,
          usage_day, channel, provider, destination_country, destination_operator, whatsapp_category,
          outcome, is_test),
        CONSTRAINT usage_records_whatsapp_category_check
          CHECK (channel = 'whatsapp' OR whatsapp_category IS NULL),
        CONSTRAINT usage_records_sms_segments_check CHECK (channel = 'sms' OR sms_segments IS NULL),
        CONSTRAINT usage_records_cost_check CHECK ((cost_micros IS NULL) = (currency IS NULL))
      ) PARTITION BY RANGE (usage_day)
      """,
      scoped("usage_records", :tenant_append),
      append_only("usage_records")
    ]
  end

  defp audit do
    [
      ~S"""
      CREATE TABLE relay.audit_log (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        created_at timestamptz NOT NULL,
        txid xid8 NOT NULL DEFAULT pg_current_xact_id(),
        action relay.event_name NOT NULL,
        actor_kind relay.actor_kind NOT NULL,
        actor_ref text NOT NULL CONSTRAINT audit_log_actor_ref_check CHECK (char_length(actor_ref) <= 256),
        on_behalf_of_ref text NOT NULL,
        access_record_ref text,
        target_type text,
        target_id text,
        reason text CONSTRAINT audit_log_reason_check CHECK (char_length(reason) <= 2000),
        details_ct bytea,
        details_key_id uuid,
        record_digest relay.sha256 NOT NULL,
        CONSTRAINT audit_log_pkey PRIMARY KEY (tenant_id, environment, id, created_at),
        CONSTRAINT audit_log_details_key_id_fkey FOREIGN KEY (tenant_id, environment, details_key_id)
          REFERENCES relay.tenant_keys (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      ) PARTITION BY RANGE (created_at)
      """,
      "CREATE INDEX audit_log_txid_index ON relay.audit_log (txid)",
      """
      CREATE INDEX audit_log_created_at_index ON relay.audit_log
        (tenant_id, environment, created_at)
      """,
      scoped("audit_log", :audit),
      append_only("audit_log"),
      ~S"""
      CREATE TABLE relay.audit_leaves (
        log_origin text NOT NULL,
        leaf_index bigint NOT NULL,
        audit_tenant_id uuid NOT NULL,
        audit_environment relay.environment NOT NULL,
        audit_id uuid NOT NULL,
        audit_created_at timestamptz NOT NULL,
        leaf_hash relay.sha256 NOT NULL,
        integrated_at timestamptz NOT NULL,
        CONSTRAINT audit_leaves_pkey PRIMARY KEY (log_origin, leaf_index),
        CONSTRAINT audit_leaves_audit_id_key UNIQUE (audit_id)
      )
      """,
      grant("audit_leaves", :audit_leaves),
      append_only("audit_leaves"),
      ~S"""
      CREATE TABLE relay.audit_checkpoints (
        id uuid NOT NULL,
        log_origin text NOT NULL,
        tree_size bigint NOT NULL,
        root_hash relay.sha256 NOT NULL,
        signed_note text NOT NULL,
        key_ref text NOT NULL,
        is_heartbeat boolean NOT NULL,
        created_at timestamptz NOT NULL,
        CONSTRAINT audit_checkpoints_pkey PRIMARY KEY (id),
        CONSTRAINT audit_checkpoints_tree_size_key
          UNIQUE (log_origin, tree_size, is_heartbeat, created_at)
      )
      """,
      grant("audit_checkpoints", :installation_audit),
      append_only("audit_checkpoints"),
      ~S"""
      CREATE TABLE relay.audit_checkpoint_publications (
        checkpoint_id uuid NOT NULL,
        target text NOT NULL
          CONSTRAINT audit_checkpoint_publications_target_check
            CHECK (target IN ('worm_store', 'siem') OR target ~ '^customer:.+$'),
        status text NOT NULL
          CONSTRAINT audit_checkpoint_publications_status_check CHECK (status IN ('published', 'failed')),
        detail text,
        created_at timestamptz NOT NULL,
        CONSTRAINT audit_checkpoint_publications_pkey PRIMARY KEY (checkpoint_id, target, created_at),
        CONSTRAINT audit_checkpoint_publications_checkpoint_id_fkey FOREIGN KEY (checkpoint_id)
          REFERENCES relay.audit_checkpoints (id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      grant("audit_checkpoint_publications", :installation_audit),
      append_only("audit_checkpoint_publications")
    ]
  end

  defp datasets do
    [
      ~S"""
      CREATE TABLE relay.datasets (
        name text NOT NULL CONSTRAINT datasets_name_check CHECK (name ~ '^[a-z][a-z0-9_]{2,63}$'),
        json_schema jsonb NOT NULL,
        json_schema_digest relay.sha256 NOT NULL,
        allowed_scopes text[] NOT NULL
          CONSTRAINT datasets_allowed_scopes_check CHECK (allowed_scopes <@ ARRAY['installation', 'tenant']
            AND cardinality(allowed_scopes) > 0),
        created_at timestamptz NOT NULL,
        CONSTRAINT datasets_pkey PRIMARY KEY (name)
      )
      """,
      grant("datasets", :installation),
      ~S"""
      CREATE TABLE relay.dataset_versions (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        dataset_name text NOT NULL,
        version_no bigint NOT NULL,
        content jsonb NOT NULL
          CONSTRAINT dataset_versions_content_check CHECK (pg_column_size(content) <= 8388608),
        content_digest relay.sha256 NOT NULL,
        source text NOT NULL
          CONSTRAINT dataset_versions_source_check CHECK (source IN ('package', 'operator')),
        source_ref text NOT NULL,
        valid_from timestamptz NOT NULL,
        published_by_ref text NOT NULL,
        created_at timestamptz NOT NULL,
        CONSTRAINT dataset_versions_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT dataset_versions_version_no_key
          UNIQUE (tenant_id, environment, dataset_name, version_no),
        CONSTRAINT dataset_versions_content_digest_key
          UNIQUE (tenant_id, environment, dataset_name, content_digest),
        CONSTRAINT dataset_versions_dataset_name_fkey FOREIGN KEY (dataset_name)
          REFERENCES relay.datasets (name) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      shared("dataset_versions", :tenant_append),
      append_only("dataset_versions"),
      ~S"""
      CREATE TABLE relay.dataset_active (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        dataset_name text NOT NULL,
        version_id uuid NOT NULL,
        activated_at timestamptz NOT NULL,
        activated_by_ref text NOT NULL,
        CONSTRAINT dataset_active_pkey PRIMARY KEY (tenant_id, environment, dataset_name),
        CONSTRAINT dataset_active_version_id_fkey FOREIGN KEY (tenant_id, environment, version_id)
          REFERENCES relay.dataset_versions (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT dataset_active_dataset_name_fkey FOREIGN KEY (dataset_name)
          REFERENCES relay.datasets (name) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      shared("dataset_active", :tenant)
    ]
  end

  defp operations do
    [
      ~S"""
      CREATE TABLE relay.partition_policies (
        table_name text NOT NULL,
        partition_interval text NOT NULL
          CONSTRAINT partition_policies_partition_interval_check
            CHECK (partition_interval IN ('day', 'month')),
        premake_horizon interval NOT NULL,
        alarm_threshold interval NOT NULL,
        hot_retention interval NOT NULL,
        updated_at timestamptz NOT NULL,
        updated_by_ref text NOT NULL,
        CONSTRAINT partition_policies_pkey PRIMARY KEY (table_name)
      )
      """,
      grant("partition_policies", :installation_maint),
      ~S"""
      CREATE TABLE relay.singleton_tasks (
        name text NOT NULL,
        leader_node text,
        lease_until timestamptz,
        fencing_token bigint NOT NULL,
        state jsonb,
        updated_at timestamptz NOT NULL,
        CONSTRAINT singleton_tasks_pkey PRIMARY KEY (name)
      )
      """,
      grant("singleton_tasks", :installation_maint)
    ]
  end

  defp scoped(table, grants) do
    [
      "ALTER TABLE relay.#{table} ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE relay.#{table} FORCE ROW LEVEL SECURITY",
      "CREATE POLICY #{table}_scope ON relay.#{table} USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})",
      grant(table, grants)
    ]
  end

  defp shared(table, grants) do
    [
      "ALTER TABLE relay.#{table} ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE relay.#{table} FORCE ROW LEVEL SECURITY",
      "CREATE POLICY #{table}_scope ON relay.#{table} USING ((#{@tenant_scope}) OR tenant_id = (select relay_private.installation_tenant_id())) WITH CHECK (#{@tenant_scope})",
      grant(table, grants)
    ]
  end

  defp grant(table, group) do
    for {privileges, roles} <- Map.fetch!(@grants, group),
        do: "GRANT #{privileges} ON relay.#{table} TO #{roles}"
  end

  # INV-6
  # INV-49
  defp append_only(table) do
    [
      """
      CREATE TRIGGER #{table}_append_only BEFORE UPDATE OR DELETE ON relay.#{table}
        FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
      """,
      """
      CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON relay.#{table}
        FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
      """
    ]
  end
end
