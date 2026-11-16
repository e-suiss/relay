defmodule Relay.Repo.Migrations.CreateWebhookTables do
  use Ecto.Migration

  @grants %{
    tenant: [
      {"SELECT, INSERT, UPDATE", "relay_owner"},
      {"SELECT", "relay_app, relay_maint, relay_archive, relay_report"}
    ],
    tenant_append: [
      {"SELECT, INSERT", "relay_owner"},
      {"SELECT", "relay_app, relay_maint, relay_archive, relay_report"}
    ]
  }

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  @kinds "'https', 'kafka', 'nats_jetstream', 'rabbitmq', 'aws_sqs', 'aws_sns', 'aws_eventbridge', 'gcp_pubsub', 'azure_service_bus', 'azure_event_grid', 's3'"
  @failed "'failed_permanent', 'exhausted', 'expired', 'window_exceeded', 'dead_lettered', 'cancelled'"

  # WH-1
  # WH-2
  # WH-5
  # WH-6
  # WH-10
  # WH-12
  # WH-14
  # WH-16
  # WH-19
  # WH-21
  # WH-27
  # WH-30
  # WH-35
  # WH-36
  # WH-37
  # WH-45
  # WH-56
  # INV-12
  # INV-39
  # API-55
  # OP-9
  def up do
    Enum.each(statements(), &execute/1)
  end

  def down, do: :ok

  defp statements do
    List.flatten([
      consumers(),
      event_types(),
      endpoints(),
      endpoint_versions(),
      endpoint_keys(),
      endpoint_health(),
      events(),
      batches(),
      messages(),
      attempts(),
      operations_contacts()
    ])
  end

  defp consumers do
    [
      ~S"""
      CREATE TABLE relay.webhook_consumers (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        key text NOT NULL
          CONSTRAINT webhook_consumers_key_check
            CHECK (char_length(key) BETWEEN 1 AND 256 AND key ~ '^[!-~]+$'),
        name text
          CONSTRAINT webhook_consumers_name_check CHECK (char_length(name) BETWEEN 1 AND 256),
        source text
          CONSTRAINT webhook_consumers_source_check
            CHECK (char_length(source) BETWEEN 1 AND 1024 AND source ~ '^[!-~]+$'),
        subtenant_id uuid,
        state text NOT NULL
          CONSTRAINT webhook_consumers_state_check CHECK (state IN ('active', 'archived')),
        version bigint NOT NULL DEFAULT 1
          CONSTRAINT webhook_consumers_version_check CHECK (version >= 1),
        archived_at timestamptz,
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT webhook_consumers_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT webhook_consumers_key_key UNIQUE (tenant_id, environment, key),
        CONSTRAINT webhook_consumers_archived_check
          CHECK ((state = 'archived') = (archived_at IS NOT NULL)),
        CONSTRAINT webhook_consumers_subtenant_id_fkey
          FOREIGN KEY (tenant_id, environment, subtenant_id)
          REFERENCES relay.subtenants (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      no_delete("webhook_consumers"),
      scoped("webhook_consumers", :tenant)
    ]
  end

  defp event_types do
    [
      ~S"""
      CREATE TABLE relay.webhook_event_types (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        name text NOT NULL
          CONSTRAINT webhook_event_types_name_check
            CHECK (name ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$' AND char_length(name) <= 128),
        description text
          CONSTRAINT webhook_event_types_description_check
            CHECK (char_length(description) BETWEEN 1 AND 500),
        state text NOT NULL
          CONSTRAINT webhook_event_types_state_check CHECK (state IN ('active', 'archived')),
        current_version bigint NOT NULL DEFAULT 1
          CONSTRAINT webhook_event_types_current_version_check CHECK (current_version >= 1),
        version bigint NOT NULL DEFAULT 1
          CONSTRAINT webhook_event_types_version_check CHECK (version >= 1),
        archived_at timestamptz,
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT webhook_event_types_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT webhook_event_types_name_key UNIQUE (tenant_id, environment, name),
        CONSTRAINT webhook_event_types_archived_check
          CHECK ((state = 'archived') = (archived_at IS NOT NULL))
      )
      """,
      no_delete("webhook_event_types"),
      scoped("webhook_event_types", :tenant),
      ~S"""
      CREATE TABLE relay.webhook_event_type_versions (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        event_type_id uuid NOT NULL,
        version bigint NOT NULL
          CONSTRAINT webhook_event_type_versions_version_check CHECK (version >= 1),
        json_schema jsonb NOT NULL
          CONSTRAINT webhook_event_type_versions_json_schema_check
            CHECK (pg_column_size(json_schema) <= 65536),
        schema_digest relay.sha256 NOT NULL,
        identifiers text[] NOT NULL DEFAULT '{}'
          CONSTRAINT webhook_event_type_versions_identifiers_check
            CHECK (cardinality(identifiers) <= 32),
        example jsonb
          CONSTRAINT webhook_event_type_versions_example_check
            CHECK (pg_column_size(example) <= 65536),
        created_by_ref text NOT NULL
          CONSTRAINT webhook_event_type_versions_created_by_ref_check
            CHECK (char_length(created_by_ref) BETWEEN 1 AND 256),
        created_at timestamptz NOT NULL,
        CONSTRAINT webhook_event_type_versions_pkey
          PRIMARY KEY (tenant_id, environment, event_type_id, version),
        CONSTRAINT webhook_event_type_versions_event_type_id_fkey
          FOREIGN KEY (tenant_id, environment, event_type_id)
          REFERENCES relay.webhook_event_types (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      append_only("webhook_event_type_versions"),
      scoped("webhook_event_type_versions", :tenant_append)
    ]
  end

  defp endpoints do
    [
      """
      CREATE TABLE relay.webhook_endpoints (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        use_kind text NOT NULL
          CONSTRAINT webhook_endpoints_use_kind_check
            CHECK (use_kind IN ('relay_events', 'destination')),
        consumer_id uuid,
        kind text NOT NULL
          CONSTRAINT webhook_endpoints_kind_check CHECK (kind IN (#{@kinds})),
        url text
          CONSTRAINT webhook_endpoints_url_check
            CHECK (url ~ '^https://' AND char_length(url) <= 2048),
        destination jsonb NOT NULL DEFAULT '{}'
          CONSTRAINT webhook_endpoints_destination_check
            CHECK (pg_column_size(destination) <= 16384),
        credential_ref_id uuid,
        event_types text[] NOT NULL DEFAULT '{}'
          CONSTRAINT webhook_endpoints_event_types_check CHECK (cardinality(event_types) <= 100),
        signature_scheme text
          CONSTRAINT webhook_endpoints_signature_scheme_check
            CHECK (signature_scheme IN ('v1a', 'v1')),
        description text
          CONSTRAINT webhook_endpoints_description_check
            CHECK (char_length(description) BETWEEN 1 AND 500),
        managed_by text NOT NULL DEFAULT 'tenant'
          CONSTRAINT webhook_endpoints_managed_by_check CHECK (managed_by IN ('tenant', 'product')),
        product text
          CONSTRAINT webhook_endpoints_product_check CHECK (char_length(product) BETWEEN 1 AND 64),
        state text NOT NULL
          CONSTRAINT webhook_endpoints_state_check
            CHECK (state IN ('active', 'paused', 'disabled', 'archived')),
        disabled_reason text
          CONSTRAINT webhook_endpoints_disabled_reason_check
            CHECK (disabled_reason IN ('manual', 'failing', 'gone')),
        disabled_at timestamptz,
        paused_at timestamptz,
        archived_at timestamptz,
        auto_disable boolean NOT NULL DEFAULT true,
        retry_schedule bigint[]
          CONSTRAINT webhook_endpoints_retry_schedule_check
            CHECK (cardinality(retry_schedule) BETWEEN 1 AND 15),
        max_concurrency bigint
          CONSTRAINT webhook_endpoints_max_concurrency_check CHECK (max_concurrency >= 1),
        rate_per_second bigint
          CONSTRAINT webhook_endpoints_rate_per_second_check CHECK (rate_per_second >= 1),
        payload_version text NOT NULL
          CONSTRAINT webhook_endpoints_payload_version_check
            CHECK (payload_version ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'),
        current_version bigint NOT NULL DEFAULT 1
          CONSTRAINT webhook_endpoints_current_version_check CHECK (current_version >= 1),
        version bigint NOT NULL DEFAULT 1
          CONSTRAINT webhook_endpoints_version_check CHECK (version >= 1),
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT webhook_endpoints_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT webhook_endpoints_consumer_check
          CHECK ((use_kind = 'destination') = (consumer_id IS NOT NULL)),
        CONSTRAINT webhook_endpoints_https_check
          CHECK ((kind = 'https') = (url IS NOT NULL)
            AND (kind = 'https') = (signature_scheme IS NOT NULL)),
        CONSTRAINT webhook_endpoints_product_owner_check
          CHECK ((managed_by = 'product') = (product IS NOT NULL)),
        CONSTRAINT webhook_endpoints_disabled_check
          CHECK ((state = 'disabled') = (disabled_at IS NOT NULL)
            AND (state = 'disabled') = (disabled_reason IS NOT NULL)),
        CONSTRAINT webhook_endpoints_paused_check
          CHECK ((state = 'paused') = (paused_at IS NOT NULL)),
        CONSTRAINT webhook_endpoints_archived_check
          CHECK ((state = 'archived') = (archived_at IS NOT NULL)),
        CONSTRAINT webhook_endpoints_consumer_id_fkey
          FOREIGN KEY (tenant_id, environment, consumer_id)
          REFERENCES relay.webhook_consumers (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT webhook_endpoints_credential_ref_id_fkey
          FOREIGN KEY (tenant_id, environment, credential_ref_id)
          REFERENCES relay.secret_refs (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE INDEX webhook_endpoints_consumer_index ON relay.webhook_endpoints
        (tenant_id, environment, consumer_id) WHERE state <> 'archived'
      """,
      no_delete("webhook_endpoints"),
      scoped("webhook_endpoints", :tenant)
    ]
  end

  defp endpoint_versions do
    [
      ~S"""
      CREATE TABLE relay.webhook_endpoint_versions (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        endpoint_id uuid NOT NULL,
        version bigint NOT NULL
          CONSTRAINT webhook_endpoint_versions_version_check CHECK (version >= 1),
        snapshot text[] NOT NULL DEFAULT '{}'
          CONSTRAINT webhook_endpoint_versions_snapshot_check CHECK (cardinality(snapshot) <= 50),
        payload_version text NOT NULL
          CONSTRAINT webhook_endpoint_versions_payload_version_check
            CHECK (payload_version ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'),
        created_by_ref text NOT NULL
          CONSTRAINT webhook_endpoint_versions_created_by_ref_check
            CHECK (char_length(created_by_ref) BETWEEN 1 AND 256),
        created_at timestamptz NOT NULL,
        CONSTRAINT webhook_endpoint_versions_pkey
          PRIMARY KEY (tenant_id, environment, endpoint_id, version),
        CONSTRAINT webhook_endpoint_versions_endpoint_id_fkey
          FOREIGN KEY (tenant_id, environment, endpoint_id)
          REFERENCES relay.webhook_endpoints (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      append_only("webhook_endpoint_versions"),
      scoped("webhook_endpoint_versions", :tenant_append)
    ]
  end

  defp endpoint_keys do
    [
      ~S"""
      CREATE TABLE relay.webhook_endpoint_keys (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        endpoint_id uuid NOT NULL,
        scheme text NOT NULL
          CONSTRAINT webhook_endpoint_keys_scheme_check CHECK (scheme IN ('v1a', 'v1')),
        state text NOT NULL
          CONSTRAINT webhook_endpoint_keys_state_check
            CHECK (state IN ('active', 'previous', 'retired')),
        public_key bytea
          CONSTRAINT webhook_endpoint_keys_public_key_check CHECK (octet_length(public_key) = 32),
        secret_ct bytea
          CONSTRAINT webhook_endpoint_keys_secret_ct_check
            CHECK (octet_length(secret_ct) <= 4096 + 29),
        secret_key_id uuid,
        activated_at timestamptz NOT NULL,
        superseded_at timestamptz,
        expires_at timestamptz,
        retired_at timestamptz,
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT webhook_endpoint_keys_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT webhook_endpoint_keys_public_check
          CHECK ((scheme = 'v1a') = (public_key IS NOT NULL)),
        CONSTRAINT webhook_endpoint_keys_secret_check
          CHECK ((state = 'retired') = (secret_ct IS NULL)
            AND (secret_ct IS NULL OR secret_key_id IS NOT NULL)),
        CONSTRAINT webhook_endpoint_keys_superseded_check
          CHECK ((state = 'active') = (superseded_at IS NULL)),
        CONSTRAINT webhook_endpoint_keys_expires_check
          CHECK (state <> 'previous' OR expires_at IS NOT NULL),
        CONSTRAINT webhook_endpoint_keys_retired_check
          CHECK ((state = 'retired') = (retired_at IS NOT NULL)),
        CONSTRAINT webhook_endpoint_keys_endpoint_id_fkey
          FOREIGN KEY (tenant_id, environment, endpoint_id)
          REFERENCES relay.webhook_endpoints (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT webhook_endpoint_keys_secret_key_id_fkey
          FOREIGN KEY (tenant_id, environment, secret_key_id)
          REFERENCES relay.tenant_keys (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE UNIQUE INDEX webhook_endpoint_keys_active_key ON relay.webhook_endpoint_keys
        (tenant_id, environment, endpoint_id) WHERE state = 'active'
      """,
      """
      CREATE UNIQUE INDEX webhook_endpoint_keys_previous_key ON relay.webhook_endpoint_keys
        (tenant_id, environment, endpoint_id) WHERE state = 'previous'
      """,
      """
      CREATE INDEX webhook_endpoint_keys_endpoint_index ON relay.webhook_endpoint_keys
        (tenant_id, environment, endpoint_id, id)
      """,
      no_delete("webhook_endpoint_keys"),
      scoped("webhook_endpoint_keys", :tenant)
    ]
  end

  defp endpoint_health do
    [
      ~S"""
      CREATE TABLE relay.webhook_endpoint_health (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        endpoint_id uuid NOT NULL,
        breaker_state text NOT NULL DEFAULT 'closed'
          CONSTRAINT webhook_endpoint_health_breaker_state_check
            CHECK (breaker_state IN ('closed', 'open', 'half_open')),
        breaker_opened_at timestamptz,
        breaker_open_seconds bigint
          CONSTRAINT webhook_endpoint_health_breaker_open_seconds_check
            CHECK (breaker_open_seconds >= 1),
        breaker_retry_at timestamptz,
        breaker_trips bigint NOT NULL DEFAULT 0
          CONSTRAINT webhook_endpoint_health_breaker_trips_check CHECK (breaker_trips >= 0),
        consecutive_failures bigint NOT NULL DEFAULT 0
          CONSTRAINT webhook_endpoint_health_consecutive_failures_check
            CHECK (consecutive_failures >= 0),
        failing_since timestamptz,
        failure_count bigint NOT NULL DEFAULT 0
          CONSTRAINT webhook_endpoint_health_failure_count_check CHECK (failure_count >= 0),
        last_failure_at timestamptz,
        last_failure_code text
          CONSTRAINT webhook_endpoint_health_last_failure_code_check
            CHECK (last_failure_code ~ '^[a-z0-9_]{1,64}$'),
        last_response_status bigint
          CONSTRAINT webhook_endpoint_health_last_response_status_check
            CHECK (last_response_status BETWEEN 100 AND 599),
        warned_at timestamptz,
        last_success_at timestamptz,
        last_attempt_at timestamptz,
        version bigint NOT NULL DEFAULT 1
          CONSTRAINT webhook_endpoint_health_version_check CHECK (version >= 1),
        updated_at timestamptz NOT NULL,
        CONSTRAINT webhook_endpoint_health_pkey PRIMARY KEY (tenant_id, environment, endpoint_id),
        CONSTRAINT webhook_endpoint_health_breaker_check
          CHECK ((breaker_state = 'closed') = (breaker_opened_at IS NULL)
            AND (breaker_state = 'closed') = (breaker_retry_at IS NULL)),
        CONSTRAINT webhook_endpoint_health_failing_check
          CHECK ((failure_count = 0) = (failing_since IS NULL)),
        CONSTRAINT webhook_endpoint_health_endpoint_id_fkey
          FOREIGN KEY (tenant_id, environment, endpoint_id)
          REFERENCES relay.webhook_endpoints (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      no_delete("webhook_endpoint_health"),
      scoped("webhook_endpoint_health", :tenant)
    ]
  end

  defp events do
    [
      ~S"""
      CREATE TABLE relay.webhook_events (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        use_kind text NOT NULL
          CONSTRAINT webhook_events_use_kind_check
            CHECK (use_kind IN ('relay_events', 'destination')),
        consumer_id uuid,
        event_type text NOT NULL
          CONSTRAINT webhook_events_event_type_check
            CHECK (event_type ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'
              AND char_length(event_type) <= 128),
        schema_version bigint NOT NULL DEFAULT 1
          CONSTRAINT webhook_events_schema_version_check CHECK (schema_version >= 1),
        origin text NOT NULL
          CONSTRAINT webhook_events_origin_check CHECK (origin IN ('outbox', 'workflow', 'test')),
        source text
          CONSTRAINT webhook_events_source_check CHECK (char_length(source) BETWEEN 1 AND 1024),
        subject text
          CONSTRAINT webhook_events_subject_check CHECK (char_length(subject) BETWEEN 1 AND 512),
        stream_epoch bigint
          CONSTRAINT webhook_events_stream_epoch_check CHECK (stream_epoch >= 1),
        seq bigint CONSTRAINT webhook_events_seq_check CHECK (seq >= 1),
        occurred_at timestamptz NOT NULL,
        traceparent text
          CONSTRAINT webhook_events_traceparent_check
            CHECK (traceparent ~ '^[0-9a-f]{2}-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}$'),
        payload jsonb
          CONSTRAINT webhook_events_payload_check CHECK (pg_column_size(payload) <= 262144),
        payload_ct bytea
          CONSTRAINT webhook_events_payload_ct_check
            CHECK (octet_length(payload_ct) <= 262144 + 29),
        payload_key_id uuid,
        payload_digest relay.sha256 NOT NULL,
        payload_erased_at timestamptz,
        created_at timestamptz NOT NULL,
        CONSTRAINT webhook_events_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT webhook_events_consumer_check
          CHECK (use_kind = 'destination' OR consumer_id IS NULL),
        CONSTRAINT webhook_events_payload_form_check
          CHECK (num_nonnulls(payload, payload_ct) = 1
            OR (payload_erased_at IS NOT NULL AND num_nonnulls(payload, payload_ct) = 0)),
        CONSTRAINT webhook_events_payload_key_check
          CHECK (payload_ct IS NULL OR payload_key_id IS NOT NULL),
        CONSTRAINT webhook_events_consumer_id_fkey
          FOREIGN KEY (tenant_id, environment, consumer_id)
          REFERENCES relay.webhook_consumers (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT webhook_events_payload_key_id_fkey
          FOREIGN KEY (tenant_id, environment, payload_key_id)
          REFERENCES relay.tenant_keys (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE INDEX webhook_events_type_index ON relay.webhook_events
        (tenant_id, environment, event_type, created_at, id)
      """,
      """
      CREATE INDEX webhook_events_created_at_index ON relay.webhook_events
        (tenant_id, environment, created_at, id)
      """,
      no_delete("webhook_events"),
      scoped("webhook_events", :tenant)
    ]
  end

  defp batches do
    [
      ~S"""
      CREATE TABLE relay.webhook_batches (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        endpoint_id uuid NOT NULL,
        state text NOT NULL
          CONSTRAINT webhook_batches_state_check
            CHECK (state IN ('open', 'closed', 'written', 'failed')),
        opened_at timestamptz NOT NULL,
        closes_at timestamptz NOT NULL,
        closed_at timestamptz,
        event_count bigint NOT NULL DEFAULT 0
          CONSTRAINT webhook_batches_event_count_check CHECK (event_count >= 0),
        byte_count bigint NOT NULL DEFAULT 0
          CONSTRAINT webhook_batches_byte_count_check CHECK (byte_count >= 0),
        object_key text
          CONSTRAINT webhook_batches_object_key_check
            CHECK (char_length(object_key) BETWEEN 1 AND 1024),
        object_digest relay.sha256,
        attempt_count bigint NOT NULL DEFAULT 0
          CONSTRAINT webhook_batches_attempt_count_check CHECK (attempt_count >= 0),
        written_at timestamptz,
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT webhook_batches_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT webhook_batches_closed_check CHECK ((state = 'open') = (closed_at IS NULL)),
        CONSTRAINT webhook_batches_written_check
          CHECK ((state = 'written') = (written_at IS NOT NULL)
            AND (state <> 'written' OR (object_key IS NOT NULL AND object_digest IS NOT NULL))),
        CONSTRAINT webhook_batches_endpoint_id_fkey
          FOREIGN KEY (tenant_id, environment, endpoint_id)
          REFERENCES relay.webhook_endpoints (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE UNIQUE INDEX webhook_batches_open_key ON relay.webhook_batches
        (tenant_id, environment, endpoint_id) WHERE state = 'open'
      """,
      """
      CREATE INDEX webhook_batches_due_index ON relay.webhook_batches
        (tenant_id, environment, closes_at) WHERE state IN ('open', 'closed')
      """,
      no_delete("webhook_batches"),
      scoped("webhook_batches", :tenant)
    ]
  end

  defp messages do
    [
      """
      CREATE TABLE relay.webhook_messages (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        endpoint_id uuid NOT NULL,
        event_id uuid NOT NULL,
        endpoint_version bigint NOT NULL,
        event_type text NOT NULL
          CONSTRAINT webhook_messages_event_type_check CHECK (char_length(event_type) <= 128),
        origin text NOT NULL
          CONSTRAINT webhook_messages_origin_check CHECK (origin IN ('event', 'replay', 'test')),
        state text NOT NULL
          CONSTRAINT webhook_messages_state_check
            CHECK (state IN ('pending', 'scheduled', 'in_flight', 'held', 'delivered', #{@failed})),
        hold_reason text
          CONSTRAINT webhook_messages_hold_reason_check
            CHECK (hold_reason IN ('endpoint_paused', 'endpoint_disabled', 'breaker_open')),
        reason text
          CONSTRAINT webhook_messages_reason_check CHECK (reason ~ '^[a-z0-9_]{1,64}$'),
        schedule_no bigint NOT NULL DEFAULT 1
          CONSTRAINT webhook_messages_schedule_no_check CHECK (schedule_no >= 1),
        schedule_started_at timestamptz NOT NULL,
        attempt_count bigint NOT NULL DEFAULT 0
          CONSTRAINT webhook_messages_attempt_count_check CHECK (attempt_count >= 0),
        total_attempt_count bigint NOT NULL DEFAULT 0
          CONSTRAINT webhook_messages_total_attempt_count_check
            CHECK (total_attempt_count >= attempt_count),
        retry_after_count bigint NOT NULL DEFAULT 0
          CONSTRAINT webhook_messages_retry_after_count_check CHECK (retry_after_count >= 0),
        next_attempt_at timestamptz,
        window_ends_at timestamptz,
        expires_at timestamptz,
        locked_until timestamptz,
        lock_token uuid,
        batch_id uuid,
        last_attempt_at timestamptz,
        last_response_status bigint
          CONSTRAINT webhook_messages_last_response_status_check
            CHECK (last_response_status BETWEEN 100 AND 599),
        delivered_at timestamptz,
        terminal_at timestamptz,
        cancelled_by_ref text
          CONSTRAINT webhook_messages_cancelled_by_ref_check
            CHECK (char_length(cancelled_by_ref) BETWEEN 1 AND 256),
        state_version bigint NOT NULL DEFAULT 1
          CONSTRAINT webhook_messages_state_version_check CHECK (state_version >= 1),
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT webhook_messages_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT webhook_messages_endpoint_event_key
          UNIQUE (tenant_id, environment, endpoint_id, event_id),
        CONSTRAINT webhook_messages_held_check CHECK ((state = 'held') = (hold_reason IS NOT NULL)),
        CONSTRAINT webhook_messages_due_check
          CHECK (state NOT IN ('pending', 'scheduled') OR next_attempt_at IS NOT NULL),
        CONSTRAINT webhook_messages_lock_check
          CHECK ((locked_until IS NULL) = (lock_token IS NULL)
            AND (state <> 'in_flight' OR locked_until IS NOT NULL)),
        CONSTRAINT webhook_messages_terminal_check
          CHECK ((state IN ('delivered', #{@failed})) = (terminal_at IS NOT NULL)),
        CONSTRAINT webhook_messages_delivered_check
          CHECK (state <> 'delivered' OR delivered_at IS NOT NULL),
        CONSTRAINT webhook_messages_endpoint_id_fkey
          FOREIGN KEY (tenant_id, environment, endpoint_id)
          REFERENCES relay.webhook_endpoints (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT webhook_messages_event_id_fkey
          FOREIGN KEY (tenant_id, environment, event_id)
          REFERENCES relay.webhook_events (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT webhook_messages_endpoint_version_fkey
          FOREIGN KEY (tenant_id, environment, endpoint_id, endpoint_version)
          REFERENCES relay.webhook_endpoint_versions (tenant_id, environment, endpoint_id, version)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT webhook_messages_batch_id_fkey
          FOREIGN KEY (tenant_id, environment, batch_id)
          REFERENCES relay.webhook_batches (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE INDEX webhook_messages_due_index ON relay.webhook_messages
        (tenant_id, environment, next_attempt_at, id) WHERE state IN ('pending', 'scheduled')
      """,
      """
      CREATE INDEX webhook_messages_endpoint_index ON relay.webhook_messages
        (tenant_id, environment, endpoint_id, id DESC)
      """,
      """
      CREATE INDEX webhook_messages_endpoint_state_index ON relay.webhook_messages
        (tenant_id, environment, endpoint_id, state, id)
      """,
      """
      CREATE INDEX webhook_messages_missed_index ON relay.webhook_messages
        (tenant_id, environment, endpoint_id, created_at, id)
        WHERE state IN (#{@failed}) OR hold_reason = 'endpoint_disabled'
      """,
      """
      CREATE INDEX webhook_messages_event_index ON relay.webhook_messages
        (tenant_id, environment, event_id)
      """,
      """
      CREATE INDEX webhook_messages_batch_index ON relay.webhook_messages
        (tenant_id, environment, batch_id) WHERE batch_id IS NOT NULL
      """,
      no_delete("webhook_messages"),
      scoped("webhook_messages", :tenant)
    ]
  end

  defp attempts do
    [
      ~S"""
      CREATE TABLE relay.webhook_attempts (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        created_at timestamptz NOT NULL,
        message_id uuid NOT NULL,
        endpoint_id uuid NOT NULL,
        attempt_no bigint NOT NULL
          CONSTRAINT webhook_attempts_attempt_no_check CHECK (attempt_no >= 1),
        schedule_no bigint NOT NULL
          CONSTRAINT webhook_attempts_schedule_no_check CHECK (schedule_no >= 1),
        trigger_kind text NOT NULL
          CONSTRAINT webhook_attempts_trigger_kind_check
            CHECK (trigger_kind IN ('schedule', 'manual', 'recovery', 'test')),
        started_at timestamptz NOT NULL,
        finished_at timestamptz,
        duration_ms bigint
          CONSTRAINT webhook_attempts_duration_ms_check CHECK (duration_ms >= 0),
        result text
          CONSTRAINT webhook_attempts_result_check
            CHECK (result IN ('succeeded', 'failed_retryable', 'failed_permanent', 'aborted',
              'deferred')),
        failure_code text
          CONSTRAINT webhook_attempts_failure_code_check CHECK (failure_code ~ '^[a-z0-9_]{1,64}$'),
        response_status bigint
          CONSTRAINT webhook_attempts_response_status_check
            CHECK (response_status BETWEEN 100 AND 599),
        retry_after_seconds bigint
          CONSTRAINT webhook_attempts_retry_after_seconds_check CHECK (retry_after_seconds >= 0),
        webhook_timestamp bigint
          CONSTRAINT webhook_attempts_webhook_timestamp_check CHECK (webhook_timestamp >= 0),
        body_digest relay.sha256 NOT NULL,
        signature text
          CONSTRAINT webhook_attempts_signature_check CHECK (char_length(signature) <= 1024),
        destination_ip inet,
        destination_ref text
          CONSTRAINT webhook_attempts_destination_ref_check
            CHECK (char_length(destination_ref) BETWEEN 1 AND 512),
        response_ct bytea
          CONSTRAINT webhook_attempts_response_ct_check
            CHECK (octet_length(response_ct) <= 8192 + 29),
        response_key_id uuid,
        response_truncated boolean NOT NULL DEFAULT false,
        response_erased_at timestamptz,
        updated_at timestamptz NOT NULL,
        CONSTRAINT webhook_attempts_pkey PRIMARY KEY (tenant_id, environment, id, created_at),
        CONSTRAINT webhook_attempts_finished_check CHECK ((result IS NULL) = (finished_at IS NULL)),
        CONSTRAINT webhook_attempts_response_key_check
          CHECK (response_ct IS NULL OR response_key_id IS NOT NULL),
        CONSTRAINT webhook_attempts_response_erased_check
          CHECK (response_erased_at IS NULL OR response_ct IS NULL),
        CONSTRAINT webhook_attempts_message_id_fkey
          FOREIGN KEY (tenant_id, environment, message_id)
          REFERENCES relay.webhook_messages (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT webhook_attempts_endpoint_id_fkey
          FOREIGN KEY (tenant_id, environment, endpoint_id)
          REFERENCES relay.webhook_endpoints (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT webhook_attempts_response_key_id_fkey
          FOREIGN KEY (tenant_id, environment, response_key_id)
          REFERENCES relay.tenant_keys (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      ) PARTITION BY RANGE (created_at)
      """,
      """
      CREATE INDEX webhook_attempts_message_index ON relay.webhook_attempts
        (tenant_id, environment, message_id, attempt_no)
      """,
      """
      CREATE INDEX webhook_attempts_endpoint_index ON relay.webhook_attempts
        (tenant_id, environment, endpoint_id, created_at DESC)
      """,
      scoped("webhook_attempts", :tenant)
    ]
  end

  defp operations_contacts do
    [
      ~S"""
      CREATE TABLE relay.operations_contacts (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        address_ct bytea
          CONSTRAINT operations_contacts_address_ct_check
            CHECK (octet_length(address_ct) <= 320 + 29),
        address_key_id uuid NOT NULL,
        state text NOT NULL
          CONSTRAINT operations_contacts_state_check CHECK (state IN ('active', 'removed')),
        removed_at timestamptz,
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT operations_contacts_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT operations_contacts_removed_check
          CHECK ((state = 'removed') = (removed_at IS NOT NULL)
            AND (state = 'removed') = (address_ct IS NULL)),
        CONSTRAINT operations_contacts_address_key_id_fkey
          FOREIGN KEY (tenant_id, environment, address_key_id)
          REFERENCES relay.tenant_keys (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE INDEX operations_contacts_active_index ON relay.operations_contacts
        (tenant_id, environment, id) WHERE state = 'active'
      """,
      no_delete("operations_contacts"),
      scoped("operations_contacts", :tenant)
    ]
  end

  defp no_delete(table) do
    [
      """
      CREATE TRIGGER #{table}_no_delete BEFORE DELETE ON relay.#{table}
        FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
      """,
      """
      CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON relay.#{table}
        FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
      """
    ]
  end

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

  defp scoped(table, group) do
    grants =
      for {privileges, roles} <- Map.fetch!(@grants, group),
          do: "GRANT #{privileges} ON relay.#{table} TO #{roles}"

    [
      "ALTER TABLE relay.#{table} ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE relay.#{table} FORCE ROW LEVEL SECURITY",
      "CREATE POLICY #{table}_scope ON relay.#{table} USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})",
      grants
    ]
  end
end
