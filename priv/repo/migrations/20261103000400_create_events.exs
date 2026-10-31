defmodule Relay.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  # C-28
  # API-19
  # API-20
  # API-28
  # API-57
  # API-58
  # INV-60
  # MD-16
  # OP-13
  # OP-66
  # TN-12
  # TN-13
  def up do
    execute(~S"""
    CREATE TABLE relay.events (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      id uuid NOT NULL,
      workflow_id uuid NOT NULL,
      workflow_version_id uuid NOT NULL,
      api_client_id uuid,
      subtenant_id uuid,
      source text NOT NULL CONSTRAINT events_source_check CHECK (source IN ('api', 'cloudevents')),
      ce_key_digest relay.sha256,
      dedup_key text CONSTRAINT events_dedup_key_check CHECK (char_length(dedup_key) BETWEEN 1 AND 512),
      cancellation_key relay.cancellation_key,
      sender_type text NOT NULL
        CONSTRAINT events_sender_type_check CHECK (sender_type IN ('human', 'system', 'agent')),
      priority text NOT NULL
        CONSTRAINT events_priority_check CHECK (priority IN ('low', 'normal', 'high')),
      security_subtype text
        CONSTRAINT events_security_subtype_check
          CHECK (security_subtype IN ('otp_oob', 'email_verification')),
      on_expire text CONSTRAINT events_on_expire_check CHECK (on_expire IN ('drop', 'inbox_only')),
      send_at timestamptz,
      expires_at timestamptz,
      retention_none boolean NOT NULL,
      send_mode relay.send_mode,
      is_test boolean NOT NULL,
      recipient_count bigint NOT NULL
        CONSTRAINT events_recipient_count_check CHECK (recipient_count BETWEEN 0 AND 100),
      state text NOT NULL CONSTRAINT events_state_check CHECK (state IN ('accepted', 'cancelled')),
      cancelled_at timestamptz,
      cancellation_id uuid,
      payload_created_at timestamptz NOT NULL,
      traceparent text
        CONSTRAINT events_traceparent_check
          CHECK (traceparent ~ '^[0-9a-f]{2}-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}$'),
      created_at timestamptz NOT NULL,
      CONSTRAINT events_pkey PRIMARY KEY (tenant_id, environment, id),
      CONSTRAINT events_ce_key_digest_check
        CHECK ((source = 'cloudevents') = (ce_key_digest IS NOT NULL)),
      CONSTRAINT events_send_at_check
        CHECK (send_at IS NULL OR send_at <= created_at + interval '90 days'),
      CONSTRAINT events_send_mode_check CHECK (send_mode IS NULL OR environment = 'test'),
      CONSTRAINT events_cancelled_at_check CHECK ((state = 'cancelled') = (cancelled_at IS NOT NULL)),
      CONSTRAINT events_payload_created_at_check CHECK (payload_created_at = created_at),
      CONSTRAINT events_workflow_id_fkey FOREIGN KEY (tenant_id, environment, workflow_id)
        REFERENCES relay.workflows (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
      CONSTRAINT events_workflow_version_id_fkey
        FOREIGN KEY (tenant_id, environment, workflow_version_id)
        REFERENCES relay.workflow_versions (tenant_id, environment, id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
      CONSTRAINT events_api_client_id_fkey FOREIGN KEY (tenant_id, environment, api_client_id)
        REFERENCES relay.api_clients (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
      CONSTRAINT events_subtenant_id_fkey FOREIGN KEY (tenant_id, environment, subtenant_id)
        REFERENCES relay.subtenants (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
    )
    """)

    execute("""
    CREATE INDEX events_created_at_index ON relay.events (tenant_id, environment, created_at)
    """)

    execute("""
    CREATE INDEX events_cancellation_key_index ON relay.events
      (tenant_id, environment, cancellation_key)
      WHERE cancellation_key IS NOT NULL AND state = 'accepted'
    """)

    execute("""
    CREATE INDEX events_dedup_key_index ON relay.events (tenant_id, environment, dedup_key)
    """)

    execute(~S"""
    CREATE TABLE relay.event_payloads (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      event_id uuid NOT NULL,
      created_at timestamptz NOT NULL,
      data_ct bytea,
      metadata_ct bytea,
      actor_ct bytea,
      ce_attributes_ct bytea,
      key_id uuid NOT NULL,
      plain_size bigint NOT NULL
        CONSTRAINT event_payloads_plain_size_check CHECK (plain_size BETWEEN 0 AND 262144),
      erased_at timestamptz,
      erase_reason text
        CONSTRAINT event_payloads_erase_reason_check
          CHECK (erase_reason IN ('security_subtype', 'retention_none', 'subject_erasure',
            'tenant_closed')),
      CONSTRAINT event_payloads_pkey PRIMARY KEY (tenant_id, environment, event_id, created_at),
      CONSTRAINT event_payloads_erased_check CHECK ((erased_at IS NULL) = (erase_reason IS NULL)),
      CONSTRAINT event_payloads_event_id_fkey FOREIGN KEY (tenant_id, environment, event_id)
        REFERENCES relay.events (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
      CONSTRAINT event_payloads_key_id_fkey FOREIGN KEY (tenant_id, environment, key_id)
        REFERENCES relay.tenant_keys (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
    ) PARTITION BY RANGE (created_at)
    """)

    scoped("event_payloads", "relay_app, relay_maint, relay_archive")

    execute(~S"""
    CREATE TABLE relay.event_type_mappings (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      id uuid NOT NULL,
      type text NOT NULL CONSTRAINT event_type_mappings_type_check CHECK (char_length(type) BETWEEN 1 AND 256),
      source text
        CONSTRAINT event_type_mappings_source_check CHECK (char_length(source) BETWEEN 1 AND 1024),
      workflow_id uuid NOT NULL,
      to_pointer text NOT NULL
        CONSTRAINT event_type_mappings_to_pointer_check CHECK (char_length(to_pointer) <= 256),
      tenant_pointer text
        CONSTRAINT event_type_mappings_tenant_pointer_check CHECK (char_length(tenant_pointer) <= 256),
      data_fields text[] NOT NULL
        CONSTRAINT event_type_mappings_data_fields_check
          CHECK (cardinality(data_fields) BETWEEN 1 AND 100),
      state text NOT NULL
        CONSTRAINT event_type_mappings_state_check CHECK (state IN ('active', 'archived')),
      version bigint NOT NULL CONSTRAINT event_type_mappings_version_check CHECK (version >= 1),
      created_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      CONSTRAINT event_type_mappings_pkey PRIMARY KEY (tenant_id, environment, id),
      CONSTRAINT event_type_mappings_workflow_id_fkey FOREIGN KEY (tenant_id, environment, workflow_id)
        REFERENCES relay.workflows (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
    )
    """)

    execute("""
    CREATE UNIQUE INDEX event_type_mappings_active_key ON relay.event_type_mappings
      (tenant_id, environment, type, source) NULLS NOT DISTINCT WHERE state = 'active'
    """)

    scoped("event_type_mappings", "relay_app, relay_maint, relay_archive, relay_report")

    execute(~S"""
    CREATE TABLE relay.cancellations (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      id uuid NOT NULL,
      kind text NOT NULL
        CONSTRAINT cancellations_kind_check CHECK (kind IN ('event', 'notification', 'key')),
      event_id uuid,
      notification_id uuid,
      cancellation_key relay.cancellation_key,
      recipient_ids uuid[]
        CONSTRAINT cancellations_recipient_ids_check CHECK (cardinality(recipient_ids) BETWEEN 1 AND 100),
      channels relay.channel[]
        CONSTRAINT cancellations_channels_check CHECK (cardinality(channels) BETWEEN 1 AND 12),
      reason text CONSTRAINT cancellations_reason_check CHECK (char_length(reason) <= 500),
      cancelled_count bigint NOT NULL
        CONSTRAINT cancellations_cancelled_count_check CHECK (cancelled_count >= 0),
      already_sent_count bigint NOT NULL
        CONSTRAINT cancellations_already_sent_count_check CHECK (already_sent_count >= 0),
      not_found_count bigint NOT NULL
        CONSTRAINT cancellations_not_found_count_check CHECK (not_found_count >= 0),
      has_more boolean NOT NULL,
      created_by_ref text NOT NULL
        CONSTRAINT cancellations_created_by_ref_check
          CHECK (char_length(created_by_ref) BETWEEN 1 AND 256),
      created_at timestamptz NOT NULL,
      CONSTRAINT cancellations_pkey PRIMARY KEY (tenant_id, environment, id),
      CONSTRAINT cancellations_key_check CHECK ((kind = 'key') = (cancellation_key IS NOT NULL)),
      CONSTRAINT cancellations_event_check CHECK ((kind = 'event') = (event_id IS NOT NULL)),
      CONSTRAINT cancellations_notification_check
        CHECK ((kind = 'notification') = (notification_id IS NOT NULL)),
      CONSTRAINT cancellations_event_id_fkey FOREIGN KEY (tenant_id, environment, event_id)
        REFERENCES relay.events (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
      CONSTRAINT cancellations_notification_id_fkey
        FOREIGN KEY (tenant_id, environment, notification_id)
        REFERENCES relay.notifications (tenant_id, environment, id)
        ON DELETE RESTRICT ON UPDATE RESTRICT
    )
    """)

    execute("""
    CREATE INDEX cancellations_key_index ON relay.cancellations
      (tenant_id, environment, cancellation_key, created_at) WHERE kind = 'key'
    """)

    execute("""
    CREATE INDEX cancellations_event_id_index ON relay.cancellations
      (tenant_id, environment, event_id) WHERE kind = 'event'
    """)

    execute("""
    CREATE TRIGGER cancellations_append_only BEFORE UPDATE OR DELETE ON relay.cancellations
      FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    execute("""
    CREATE TRIGGER cancellations_no_truncate BEFORE TRUNCATE ON relay.cancellations
      FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    execute("""
    ALTER TABLE relay.events ADD CONSTRAINT events_cancellation_id_fkey
      FOREIGN KEY (tenant_id, environment, cancellation_id)
      REFERENCES relay.cancellations (tenant_id, environment, id)
      ON DELETE RESTRICT ON UPDATE RESTRICT
    """)

    scoped("events", "relay_app, relay_maint, relay_archive, relay_report")

    execute("ALTER TABLE relay.cancellations ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE relay.cancellations FORCE ROW LEVEL SECURITY")

    execute(
      "CREATE POLICY cancellations_scope ON relay.cancellations USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})"
    )

    execute("GRANT SELECT, INSERT ON relay.cancellations TO relay_owner")
    execute("GRANT SELECT ON relay.cancellations TO relay_app, relay_maint, relay_archive")

    execute("""
    INSERT INTO relay.partition_policies (table_name, partition_interval, premake_horizon,
      alarm_threshold, hot_retention, updated_at, updated_by_ref)
    VALUES ('event_payloads', 'month', interval '2 months', interval '3 days', interval '13 months',
      now(), 'migration')
    """)

    execute("""
    SELECT relay_private.partition_create('event_payloads', m, m + interval '1 month')
    FROM generate_series(date_trunc('month', now(), 'UTC'),
      now() + interval '2 months', interval '1 month') AS m
    """)
  end

  defp scoped(table, readers) do
    execute("ALTER TABLE relay.#{table} ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE relay.#{table} FORCE ROW LEVEL SECURITY")

    execute(
      "CREATE POLICY #{table}_scope ON relay.#{table} USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})"
    )

    execute("GRANT SELECT, INSERT, UPDATE ON relay.#{table} TO relay_owner")
    execute("GRANT SELECT ON relay.#{table} TO #{readers}")
  end
end
