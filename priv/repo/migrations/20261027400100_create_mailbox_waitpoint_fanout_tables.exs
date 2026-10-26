defmodule Relay.Repo.Migrations.CreateMailboxWaitpointFanoutTables do
  use Ecto.Migration

  @grants %{
    tenant: [
      {"SELECT, INSERT, UPDATE", "relay_owner"},
      {"SELECT", "relay_app, relay_maint, relay_archive, relay_report"}
    ],
    tenant_append: [
      {"SELECT, INSERT", "relay_owner"},
      {"SELECT", "relay_app, relay_maint, relay_archive, relay_report"}
    ],
    virtual_clock: [
      {"SELECT, INSERT, UPDATE", "relay_owner"},
      {"SELECT", "relay_app, relay_maint, relay_report"}
    ]
  }

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  # C-68
  # IN-1
  # MD-15
  # AG-64
  # T-23
  # T-24
  # AG-9
  # AG-11
  # INV-12
  # T-87
  # TN-8
  # X-27
  def up do
    Enum.each(statements(), &execute/1)
  end

  defp statements do
    List.flatten([mailboxes(), waitpoints(), mailbox_records(), fanouts(), virtual_clocks()])
  end

  defp mailboxes do
    [
      ~S"""
      CREATE TABLE relay.mailboxes (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        owner_kind text NOT NULL
          CONSTRAINT mailboxes_owner_kind_check
            CHECK (owner_kind IN ('subscriber', 'agent', 'api_client')),
        owner_ref uuid NOT NULL,
        owner_recipient_id uuid GENERATED ALWAYS AS
          (CASE WHEN owner_kind IN ('subscriber', 'agent') THEN owner_ref END) STORED,
        owner_recipient_kind text GENERATED ALWAYS AS
          (CASE WHEN owner_kind IN ('subscriber', 'agent') THEN owner_kind END) STORED,
        owner_api_client_id uuid GENERATED ALWAYS AS
          (CASE WHEN owner_kind = 'api_client' THEN owner_ref END) STORED,
        stream_key text NOT NULL,
        state text NOT NULL
          CONSTRAINT mailboxes_state_check CHECK (state IN ('active', 'suspended', 'deleted')),
        deleted_at timestamptz,
        deleted_reason text
          CONSTRAINT mailboxes_deleted_reason_check
            CHECK (deleted_reason IN ('erasure', 'retention_end', 'tenant_closed', 'operator')),
        replay_floor_seq bigint NOT NULL DEFAULT 0
          CONSTRAINT mailboxes_replay_floor_seq_check CHECK (replay_floor_seq >= 0),
        open_waitpoints bigint NOT NULL DEFAULT 0
          CONSTRAINT mailboxes_open_waitpoints_check CHECK (open_waitpoints >= 0),
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT mailboxes_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT mailboxes_owner_key UNIQUE (tenant_id, environment, owner_kind, owner_ref),
        CONSTRAINT mailboxes_stream_key_key UNIQUE (tenant_id, environment, stream_key),
        CONSTRAINT mailboxes_id_owner_key UNIQUE (tenant_id, environment, id, owner_kind, owner_ref),
        CONSTRAINT mailboxes_stream_key_check CHECK (stream_key = 'mailbox:' || id::text),
        CONSTRAINT mailboxes_deleted_at_check CHECK ((state = 'deleted') = (deleted_at IS NOT NULL)),
        CONSTRAINT mailboxes_deleted_reason_present_check
          CHECK ((deleted_at IS NULL) = (deleted_reason IS NULL)),
        CONSTRAINT mailboxes_owner_recipient_id_fkey
          FOREIGN KEY (tenant_id, environment, owner_recipient_id, owner_recipient_kind)
          REFERENCES relay.recipients (tenant_id, environment, id, kind)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      scoped("mailboxes", :tenant),
      ~S"""
      CREATE TABLE relay.mailbox_cursors (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        mailbox_id uuid NOT NULL,
        consumer text NOT NULL
          CONSTRAINT mailbox_cursors_consumer_check CHECK (consumer ~ '^[a-z0-9_.:-]{1,64}$'),
        epoch bigint NOT NULL CONSTRAINT mailbox_cursors_epoch_check CHECK (epoch >= 1),
        seq bigint NOT NULL CONSTRAINT mailbox_cursors_seq_check CHECK (seq >= 0),
        updated_at timestamptz NOT NULL,
        CONSTRAINT mailbox_cursors_pkey PRIMARY KEY (tenant_id, environment, mailbox_id, consumer),
        CONSTRAINT mailbox_cursors_mailbox_id_fkey FOREIGN KEY (tenant_id, environment, mailbox_id)
          REFERENCES relay.mailboxes (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      scoped("mailbox_cursors", :tenant)
    ]
  end

  defp waitpoints do
    [
      ~S"""
      CREATE TABLE relay.waitpoints (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        kind text NOT NULL
          CONSTRAINT waitpoints_kind_check CHECK (kind IN ('question', 'review', 'event')),
        waiter_kind text NOT NULL
          CONSTRAINT waitpoints_waiter_kind_check CHECK (waiter_kind IN ('agent', 'api_client')),
        waiter_ref uuid NOT NULL,
        waiter_recipient_id uuid GENERATED ALWAYS AS
          (CASE WHEN waiter_kind = 'agent' THEN waiter_ref END) STORED,
        waiter_recipient_kind text GENERATED ALWAYS AS
          (CASE WHEN waiter_kind = 'agent' THEN 'agent' END) STORED,
        waiter_api_client_id uuid GENERATED ALWAYS AS
          (CASE WHEN waiter_kind = 'api_client' THEN waiter_ref END) STORED,
        waiter_mailbox_id uuid NOT NULL,
        match_event_type relay.event_name NOT NULL,
        correlation_key text NOT NULL
          CONSTRAINT waitpoints_correlation_key_check
            CHECK (correlation_key ~ '^[\x21-\x7e]+$' AND char_length(correlation_key) <= 256),
        condition jsonb
          CONSTRAINT waitpoints_condition_check CHECK (pg_column_size(condition) <= 16384),
        response_schema jsonb
          CONSTRAINT waitpoints_response_schema_size_check
            CHECK (pg_column_size(response_schema) <= 65536),
        subject_digest relay.sha256,
        content_ct bytea,
        claim_text_ct bytea,
        default_response_ct bytea,
        field_key_id uuid,
        fields_erased_at timestamptz,
        escalation_policy_ref text
          CONSTRAINT waitpoints_escalation_policy_ref_check
            CHECK (char_length(escalation_policy_ref) <= 256),
        surface_policy jsonb
          CONSTRAINT waitpoints_surface_policy_check CHECK (pg_column_size(surface_policy) <= 16384),
        deliver_to_topics text[] NOT NULL DEFAULT '{}'
          CONSTRAINT waitpoints_deliver_to_topics_check CHECK (cardinality(deliver_to_topics) <= 10),
        tags text[] NOT NULL DEFAULT '{}'
          CONSTRAINT waitpoints_tags_check CHECK (cardinality(tags) <= 20),
        opened_at timestamptz NOT NULL,
        expires_at timestamptz NOT NULL,
        heartbeat_interval_ms bigint
          CONSTRAINT waitpoints_heartbeat_interval_ms_check
            CHECK (heartbeat_interval_ms BETWEEN 1000 AND 86400000),
        heartbeat_due_at timestamptz,
        next_escalation_at timestamptz,
        state text NOT NULL
          CONSTRAINT waitpoints_state_check
            CHECK (state IN ('open', 'stalled', 'resolved', 'expired', 'cancelled')),
        state_changed_at timestamptz NOT NULL,
        resolved_at timestamptz,
        stalled_at timestamptz,
        expired_at timestamptz,
        cancelled_at timestamptz,
        resolution_response_id uuid,
        resolved_by_record_id uuid,
        resolved_by_event_id uuid,
        cancel_reason text
          CONSTRAINT waitpoints_cancel_reason_check CHECK (char_length(cancel_reason) BETWEEN 1 AND 200),
        cancelled_by_ref text
          CONSTRAINT waitpoints_cancelled_by_ref_check CHECK (char_length(cancelled_by_ref) <= 256),
        version bigint NOT NULL DEFAULT 1,
        traceparent text
          CONSTRAINT waitpoints_traceparent_check
            CHECK (traceparent ~ '^[0-9a-f]{2}-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}$'),
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT waitpoints_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT waitpoints_id_subject_digest_key UNIQUE (tenant_id, environment, id, subject_digest),
        CONSTRAINT waitpoints_id_waiter_key UNIQUE (tenant_id, environment, id, waiter_kind, waiter_ref),
        CONSTRAINT waitpoints_response_schema_check
          CHECK ((kind IN ('question', 'review')) = (response_schema IS NOT NULL)),
        CONSTRAINT waitpoints_subject_digest_check
          CHECK ((kind IN ('question', 'review')) = (subject_digest IS NOT NULL)),
        CONSTRAINT waitpoints_content_check
          CHECK (kind = 'event' OR content_ct IS NOT NULL OR fields_erased_at IS NOT NULL),
        CONSTRAINT waitpoints_field_key_id_check
          CHECK (fields_erased_at IS NOT NULL OR (field_key_id IS NULL)
            = (content_ct IS NULL AND claim_text_ct IS NULL AND default_response_ct IS NULL)),
        CONSTRAINT waitpoints_fields_erased_check
          CHECK (fields_erased_at IS NULL OR (content_ct IS NULL AND claim_text_ct IS NULL
            AND default_response_ct IS NULL AND field_key_id IS NULL)),
        CONSTRAINT waitpoints_expires_at_check
          CHECK (expires_at > opened_at AND expires_at <= opened_at + interval '30 days'),
        CONSTRAINT waitpoints_heartbeat_due_at_check
          CHECK ((heartbeat_interval_ms IS NULL) = (heartbeat_due_at IS NULL)),
        CONSTRAINT waitpoints_resolved_at_check CHECK ((state = 'resolved') = (resolved_at IS NOT NULL)),
        CONSTRAINT waitpoints_expired_at_check CHECK ((state = 'expired') = (expired_at IS NOT NULL)),
        CONSTRAINT waitpoints_cancelled_at_check
          CHECK ((state = 'cancelled') = (cancelled_at IS NOT NULL)),
        CONSTRAINT waitpoints_stalled_at_check CHECK ((state = 'stalled') = (stalled_at IS NOT NULL)),
        CONSTRAINT waitpoints_resolved_before_expiry_check
          CHECK (resolved_at IS NULL OR resolved_at < expires_at),
        CONSTRAINT waitpoints_resolution_check
          CHECK (state <> 'resolved' OR ((kind = 'event') = (resolved_by_record_id IS NOT NULL)
            AND (kind <> 'event') = (resolution_response_id IS NOT NULL))),
        CONSTRAINT waitpoints_cancel_reason_present_check
          CHECK ((state = 'cancelled') = (cancel_reason IS NOT NULL)),
        CONSTRAINT waitpoints_waiter_recipient_id_fkey
          FOREIGN KEY (tenant_id, environment, waiter_recipient_id, waiter_recipient_kind)
          REFERENCES relay.recipients (tenant_id, environment, id, kind)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT waitpoints_waiter_mailbox_id_fkey
          FOREIGN KEY (tenant_id, environment, waiter_mailbox_id, waiter_kind, waiter_ref)
          REFERENCES relay.mailboxes (tenant_id, environment, id, owner_kind, owner_ref)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT waitpoints_field_key_id_fkey FOREIGN KEY (tenant_id, environment, field_key_id)
          REFERENCES relay.tenant_keys (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE UNIQUE INDEX waitpoints_active_key ON relay.waitpoints
        (tenant_id, environment, waiter_kind, waiter_ref, match_event_type, correlation_key)
        WHERE state IN ('open', 'stalled')
      """,
      """
      CREATE INDEX waitpoints_match_index ON relay.waitpoints
        (tenant_id, environment, match_event_type, correlation_key)
        WHERE state IN ('open', 'stalled')
      """,
      """
      CREATE INDEX waitpoints_timer_index ON relay.waitpoints
        (tenant_id, environment, least(expires_at, coalesce(heartbeat_due_at, 'infinity'),
          coalesce(next_escalation_at, 'infinity')))
        WHERE state IN ('open', 'stalled')
      """,
      """
      CREATE INDEX waitpoints_waiter_index ON relay.waitpoints
        (tenant_id, environment, waiter_kind, waiter_ref, state, opened_at DESC)
      """,
      ~S"""
      CREATE FUNCTION relay_private.waitpoints_guard() RETURNS trigger
        LANGUAGE plpgsql
        SET search_path = pg_catalog, pg_temp
        SET TimeZone = 'UTC'
      AS $fn$
      BEGIN
        IF TG_OP <> 'UPDATE' THEN
          RAISE EXCEPTION 'invariant_violation' USING HINT = 'AG-11';
        END IF;
        IF NEW.kind IS DISTINCT FROM OLD.kind OR NEW.waiter_kind IS DISTINCT FROM OLD.waiter_kind
          OR NEW.waiter_ref IS DISTINCT FROM OLD.waiter_ref
          OR NEW.waiter_mailbox_id IS DISTINCT FROM OLD.waiter_mailbox_id
          OR NEW.match_event_type IS DISTINCT FROM OLD.match_event_type
          OR NEW.correlation_key IS DISTINCT FROM OLD.correlation_key
          OR NEW.subject_digest IS DISTINCT FROM OLD.subject_digest
          OR NEW.response_schema IS DISTINCT FROM OLD.response_schema
          OR NEW.opened_at IS DISTINCT FROM OLD.opened_at
          OR NEW.expires_at IS DISTINCT FROM OLD.expires_at
          OR NEW.heartbeat_interval_ms IS DISTINCT FROM OLD.heartbeat_interval_ms
          OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
          RAISE EXCEPTION 'invariant_violation'
            USING DETAIL = 'a waitpoint keeps its identity, match and deadline', HINT = 'AG-11';
        END IF;
        IF OLD.state IN ('resolved', 'expired', 'cancelled') THEN
          IF (to_jsonb(NEW) - ARRAY['content_ct', 'claim_text_ct', 'default_response_ct',
              'field_key_id', 'fields_erased_at', 'updated_at', 'waiter_recipient_id',
              'waiter_recipient_kind', 'waiter_api_client_id'])
            IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['content_ct', 'claim_text_ct',
              'default_response_ct', 'field_key_id', 'fields_erased_at', 'updated_at',
              'waiter_recipient_id', 'waiter_recipient_kind', 'waiter_api_client_id'])
            OR (NEW.content_ct IS NOT NULL AND NEW.content_ct IS DISTINCT FROM OLD.content_ct)
            OR (NEW.claim_text_ct IS NOT NULL AND NEW.claim_text_ct IS DISTINCT FROM OLD.claim_text_ct)
            OR (NEW.default_response_ct IS NOT NULL
              AND NEW.default_response_ct IS DISTINCT FROM OLD.default_response_ct)
            OR (NEW.field_key_id IS NOT NULL AND NEW.field_key_id IS DISTINCT FROM OLD.field_key_id) THEN
            RAISE EXCEPTION 'invariant_violation'
              USING DETAIL = 'a closed waitpoint does not change', HINT = 'AG-11';
          END IF;
          RETURN NEW;
        END IF;
        IF NEW.state IS DISTINCT FROM OLD.state AND NOT (
          (OLD.state = 'open' AND NEW.state IN ('resolved', 'expired', 'cancelled', 'stalled'))
          OR (OLD.state = 'stalled' AND NEW.state IN ('open', 'resolved', 'expired', 'cancelled'))) THEN
          RAISE EXCEPTION 'invariant_violation'
            USING DETAIL = 'waitpoint state transition not allowed', HINT = 'AG-10';
        END IF;
        IF NEW.state = 'resolved' AND NOT (NEW.resolved_at < OLD.expires_at) THEN
          RAISE EXCEPTION 'invariant_violation'
            USING DETAIL = 'an expired waitpoint cannot be resolved', HINT = 'AG-11';
        END IF;
        RETURN NEW;
      END
      $fn$
      """,
      "REVOKE ALL ON FUNCTION relay_private.waitpoints_guard() FROM PUBLIC",
      """
      CREATE TRIGGER waitpoints_guard BEFORE UPDATE ON relay.waitpoints
        FOR EACH ROW EXECUTE FUNCTION relay_private.waitpoints_guard()
      """,
      """
      CREATE TRIGGER waitpoints_no_delete BEFORE DELETE ON relay.waitpoints
        FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
      """,
      """
      CREATE TRIGGER waitpoints_no_truncate BEFORE TRUNCATE ON relay.waitpoints
        FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
      """,
      ~S"""
      CREATE TABLE relay.waitpoint_responders (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        waitpoint_id uuid NOT NULL,
        recipient_id uuid NOT NULL,
        waiter_kind text NOT NULL,
        waiter_ref uuid NOT NULL,
        added_by text NOT NULL
          CONSTRAINT waitpoint_responders_added_by_check CHECK (added_by IN ('creation', 'escalation')),
        created_at timestamptz NOT NULL,
        CONSTRAINT waitpoint_responders_pkey
          PRIMARY KEY (tenant_id, environment, waitpoint_id, recipient_id),
        CONSTRAINT waitpoint_responders_not_waiter_check
          CHECK (waiter_kind <> 'agent' OR recipient_id <> waiter_ref),
        CONSTRAINT waitpoint_responders_waitpoint_id_fkey
          FOREIGN KEY (tenant_id, environment, waitpoint_id, waiter_kind, waiter_ref)
          REFERENCES relay.waitpoints (tenant_id, environment, id, waiter_kind, waiter_ref)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT waitpoint_responders_recipient_id_fkey
          FOREIGN KEY (tenant_id, environment, recipient_id)
          REFERENCES relay.recipients (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      scoped("waitpoint_responders", :tenant_append),
      append_only("waitpoint_responders"),
      ~S"""
      CREATE TABLE relay.waitpoint_responses (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        waitpoint_id uuid NOT NULL,
        waiter_kind text NOT NULL,
        waiter_ref uuid NOT NULL,
        responder_recipient_id uuid NOT NULL,
        responder_actor_ref text NOT NULL
          CONSTRAINT waitpoint_responses_responder_actor_ref_check
            CHECK (char_length(responder_actor_ref) BETWEEN 1 AND 256),
        session_actor_ref text NOT NULL
          CONSTRAINT waitpoint_responses_session_actor_ref_check
            CHECK (char_length(session_actor_ref) BETWEEN 1 AND 256),
        via text NOT NULL CONSTRAINT waitpoint_responses_via_check CHECK (via ~ '^[a-z_]{1,32}$'),
        evidence_level text NOT NULL
          CONSTRAINT waitpoint_responses_evidence_level_check
            CHECK (evidence_level IN ('channel_claim', 'relay_session', 'access_aas_ref')),
        evidence_ref text
          CONSTRAINT waitpoint_responses_evidence_ref_length_check CHECK (char_length(evidence_ref) <= 512),
        subject_digest relay.sha256 NOT NULL,
        value_ct bytea NOT NULL,
        value_key_id uuid NOT NULL,
        value_digest relay.sha256 NOT NULL,
        source_record_id uuid,
        responded_at timestamptz NOT NULL,
        created_at timestamptz NOT NULL,
        CONSTRAINT waitpoint_responses_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT waitpoint_responses_waitpoint_key UNIQUE (tenant_id, environment, waitpoint_id),
        CONSTRAINT waitpoint_responses_not_waiter_check
          CHECK (waiter_kind <> 'agent' OR responder_recipient_id <> waiter_ref),
        CONSTRAINT waitpoint_responses_session_check CHECK (responder_actor_ref = session_actor_ref),
        CONSTRAINT waitpoint_responses_evidence_ref_check
          CHECK ((evidence_level = 'access_aas_ref') = (evidence_ref IS NOT NULL)),
        CONSTRAINT waitpoint_responses_waitpoint_id_fkey
          FOREIGN KEY (tenant_id, environment, waitpoint_id, waiter_kind, waiter_ref)
          REFERENCES relay.waitpoints (tenant_id, environment, id, waiter_kind, waiter_ref)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT waitpoint_responses_responder_recipient_id_fkey
          FOREIGN KEY (tenant_id, environment, waitpoint_id, responder_recipient_id)
          REFERENCES relay.waitpoint_responders (tenant_id, environment, waitpoint_id, recipient_id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT waitpoint_responses_subject_digest_fkey
          FOREIGN KEY (tenant_id, environment, waitpoint_id, subject_digest)
          REFERENCES relay.waitpoints (tenant_id, environment, id, subject_digest)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT waitpoint_responses_value_key_id_fkey
          FOREIGN KEY (tenant_id, environment, value_key_id)
          REFERENCES relay.subject_keys (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      scoped("waitpoint_responses", :tenant_append),
      append_only("waitpoint_responses"),
      ~S"""
      CREATE FUNCTION relay_private.waitpoint_responses_guard() RETURNS trigger
        LANGUAGE plpgsql
        SET search_path = pg_catalog, pg_temp
        SET TimeZone = 'UTC'
      AS $fn$
      BEGIN
        IF NOT EXISTS (SELECT 1 FROM relay.waitpoints w
          WHERE w.tenant_id = NEW.tenant_id AND w.environment = NEW.environment
            AND w.id = NEW.waitpoint_id AND w.state IN ('open', 'stalled')
            AND NEW.responded_at < w.expires_at) THEN
          RAISE EXCEPTION 'invariant_violation'
            USING DETAIL = 'a response needs an open waitpoint before its deadline', HINT = 'AG-11';
        END IF;
        RETURN NEW;
      END
      $fn$
      """,
      "REVOKE ALL ON FUNCTION relay_private.waitpoint_responses_guard() FROM PUBLIC",
      """
      CREATE TRIGGER waitpoint_responses_guard BEFORE INSERT ON relay.waitpoint_responses
        FOR EACH ROW EXECUTE FUNCTION relay_private.waitpoint_responses_guard()
      """,
      """
      ALTER TABLE relay.waitpoints ADD CONSTRAINT waitpoints_resolution_response_id_fkey
        FOREIGN KEY (tenant_id, environment, resolution_response_id)
        REFERENCES relay.waitpoint_responses (tenant_id, environment, id)
        ON DELETE RESTRICT ON UPDATE RESTRICT DEFERRABLE INITIALLY DEFERRED
      """,
      scoped("waitpoints", :tenant),
      ~S"""
      CREATE TABLE relay.waitpoint_counters (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        open_count bigint NOT NULL CONSTRAINT waitpoint_counters_open_count_check CHECK (open_count >= 0),
        updated_at timestamptz NOT NULL,
        CONSTRAINT waitpoint_counters_pkey PRIMARY KEY (tenant_id, environment)
      )
      """,
      scoped("waitpoint_counters", :tenant)
    ]
  end

  defp mailbox_records do
    [
      ~S"""
      CREATE TABLE relay.mailbox_records (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        created_at timestamptz NOT NULL,
        mailbox_id uuid NOT NULL,
        epoch bigint NOT NULL,
        seq bigint NOT NULL,
        kind text NOT NULL
          CONSTRAINT mailbox_records_kind_check
            CHECK (kind IN ('message', 'waitpoint_event', 'early_event')),
        event_type relay.event_name NOT NULL,
        correlation_key text
          CONSTRAINT mailbox_records_correlation_key_check
            CHECK (correlation_key ~ '^[\x21-\x7e]+$' AND char_length(correlation_key) <= 256),
        waitpoint_id uuid,
        source_event_id uuid,
        payload_ct bytea
          CONSTRAINT mailbox_records_payload_ct_check CHECK (octet_length(payload_ct) <= 262144 + 29),
        payload_subject_key_id uuid,
        payload_tenant_key_id uuid,
        payload_digest relay.sha256 NOT NULL,
        delivery_state text NOT NULL
          CONSTRAINT mailbox_records_delivery_state_check
            CHECK (delivery_state IN ('available', 'leased', 'acked', 'dead_lettered', 'held')),
        lease_holder text
          CONSTRAINT mailbox_records_lease_holder_check CHECK (char_length(lease_holder) <= 128),
        lease_until timestamptz,
        delivery_count bigint NOT NULL DEFAULT 0
          CONSTRAINT mailbox_records_delivery_count_check CHECK (delivery_count >= 0),
        acked_at timestamptz,
        dead_lettered_at timestamptz,
        consumed_by_waitpoint_id uuid,
        consumed_at timestamptz,
        payload_erased_at timestamptz,
        traceparent text
          CONSTRAINT mailbox_records_traceparent_check
            CHECK (traceparent ~ '^[0-9a-f]{2}-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}$'),
        updated_at timestamptz NOT NULL,
        CONSTRAINT mailbox_records_pkey PRIMARY KEY (tenant_id, environment, id, created_at),
        CONSTRAINT mailbox_records_seq_key
          UNIQUE (tenant_id, environment, mailbox_id, epoch, seq, created_at),
        CONSTRAINT mailbox_records_position_check CHECK (epoch >= 1 AND seq >= 1),
        CONSTRAINT mailbox_records_correlation_check
          CHECK ((kind = 'early_event') = (correlation_key IS NOT NULL)),
        CONSTRAINT mailbox_records_waitpoint_check
          CHECK ((kind = 'waitpoint_event') = (waitpoint_id IS NOT NULL)),
        CONSTRAINT mailbox_records_held_check CHECK ((kind = 'early_event') = (delivery_state = 'held')),
        CONSTRAINT mailbox_records_payload_key_check
          CHECK (payload_ct IS NULL
            OR ((payload_subject_key_id IS NULL) <> (payload_tenant_key_id IS NULL))),
        CONSTRAINT mailbox_records_lease_check
          CHECK ((delivery_state = 'leased') = (lease_holder IS NOT NULL AND lease_until IS NOT NULL)),
        CONSTRAINT mailbox_records_acked_at_check
          CHECK ((delivery_state = 'acked') = (acked_at IS NOT NULL)),
        CONSTRAINT mailbox_records_dead_lettered_at_check
          CHECK ((delivery_state = 'dead_lettered') = (dead_lettered_at IS NOT NULL)),
        CONSTRAINT mailbox_records_consumed_check
          CHECK ((consumed_by_waitpoint_id IS NULL) = (consumed_at IS NULL)),
        CONSTRAINT mailbox_records_consumed_kind_check CHECK (consumed_at IS NULL OR kind = 'early_event'),
        CONSTRAINT mailbox_records_payload_erased_check
          CHECK (payload_erased_at IS NULL OR payload_ct IS NULL),
        CONSTRAINT mailbox_records_mailbox_id_fkey FOREIGN KEY (tenant_id, environment, mailbox_id)
          REFERENCES relay.mailboxes (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT mailbox_records_waitpoint_id_fkey FOREIGN KEY (tenant_id, environment, waitpoint_id)
          REFERENCES relay.waitpoints (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT mailbox_records_payload_subject_key_id_fkey
          FOREIGN KEY (tenant_id, environment, payload_subject_key_id)
          REFERENCES relay.subject_keys (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT mailbox_records_payload_tenant_key_id_fkey
          FOREIGN KEY (tenant_id, environment, payload_tenant_key_id)
          REFERENCES relay.tenant_keys (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT mailbox_records_consumed_by_waitpoint_id_fkey
          FOREIGN KEY (tenant_id, environment, consumed_by_waitpoint_id)
          REFERENCES relay.waitpoints (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      ) PARTITION BY RANGE (created_at)
      """,
      """
      CREATE INDEX mailbox_records_position_index ON relay.mailbox_records
        (tenant_id, environment, mailbox_id, epoch, seq)
      """,
      """
      CREATE INDEX mailbox_records_lease_index ON relay.mailbox_records
        (tenant_id, environment, mailbox_id, epoch, seq)
        WHERE delivery_state IN ('available', 'leased')
      """,
      """
      CREATE INDEX mailbox_records_early_index ON relay.mailbox_records
        (tenant_id, environment, mailbox_id, event_type, correlation_key, created_at)
        WHERE kind = 'early_event' AND consumed_at IS NULL
      """,
      scoped("mailbox_records", :tenant),
      ~S"""
      CREATE TABLE relay.waitpoint_response_rejections (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        created_at timestamptz NOT NULL,
        waitpoint_id uuid NOT NULL,
        responder_recipient_id uuid,
        responder_actor_ref text NOT NULL
          CONSTRAINT waitpoint_response_rejections_responder_actor_ref_check
            CHECK (char_length(responder_actor_ref) BETWEEN 1 AND 256),
        reason text NOT NULL
          CONSTRAINT waitpoint_response_rejections_reason_check
            CHECK (reason IN ('expired', 'closed', 'not_responder', 'is_waiter', 'digest_mismatch',
              'session_mismatch')),
        rule_id relay.rule_id NOT NULL,
        value_digest relay.sha256,
        responded_at timestamptz NOT NULL,
        CONSTRAINT waitpoint_response_rejections_pkey PRIMARY KEY (tenant_id, environment, id, created_at),
        CONSTRAINT waitpoint_response_rejections_waitpoint_id_fkey
          FOREIGN KEY (tenant_id, environment, waitpoint_id)
          REFERENCES relay.waitpoints (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT waitpoint_response_rejections_responder_recipient_id_fkey
          FOREIGN KEY (tenant_id, environment, responder_recipient_id)
          REFERENCES relay.recipients (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      ) PARTITION BY RANGE (created_at)
      """,
      scoped("waitpoint_response_rejections", :tenant_append),
      append_only("waitpoint_response_rejections"),
      ~S"""
      CREATE TABLE relay.waitpoint_unmatched_events (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        created_at timestamptz NOT NULL,
        source_event_id uuid,
        event_type relay.event_name NOT NULL,
        correlation_key text NOT NULL
          CONSTRAINT waitpoint_unmatched_events_correlation_key_check
            CHECK (correlation_key ~ '^[\x21-\x7e]+$' AND char_length(correlation_key) <= 256),
        waiter_kind text
          CONSTRAINT waitpoint_unmatched_events_waiter_kind_check
            CHECK (waiter_kind IN ('agent', 'api_client')),
        waiter_ref uuid,
        waitpoint_id uuid,
        rule_id relay.rule_id NOT NULL
          CONSTRAINT waitpoint_unmatched_events_rule_id_check
            CHECK (rule_id IN ('waitpoint.no_match', 'waitpoint.condition_false', 'waitpoint.closed')),
        payload_digest relay.sha256,
        CONSTRAINT waitpoint_unmatched_events_pkey PRIMARY KEY (tenant_id, environment, id, created_at),
        CONSTRAINT waitpoint_unmatched_events_waiter_check
          CHECK ((waiter_kind IS NULL) = (waiter_ref IS NULL)),
        CONSTRAINT waitpoint_unmatched_events_waitpoint_id_fkey
          FOREIGN KEY (tenant_id, environment, waitpoint_id)
          REFERENCES relay.waitpoints (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      ) PARTITION BY RANGE (created_at)
      """,
      scoped("waitpoint_unmatched_events", :tenant_append),
      append_only("waitpoint_unmatched_events")
    ]
  end

  defp fanouts do
    [
      ~S"""
      CREATE TABLE relay.fanouts (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        source_kind text NOT NULL
          CONSTRAINT fanouts_source_kind_check CHECK (source_kind ~ '^[a-z_]{1,32}$'),
        source_id uuid NOT NULL,
        lane relay.lane NOT NULL CONSTRAINT fanouts_lane_check CHECK (lane <> 'l0'),
        mode text NOT NULL CONSTRAINT fanouts_mode_check CHECK (mode IN ('normal', 'bulk', 'campaign')),
        slice_size bigint NOT NULL,
        sub_batch_size bigint NOT NULL,
        state text NOT NULL
          CONSTRAINT fanouts_state_check
            CHECK (state IN ('pending', 'running', 'paused', 'completed', 'partial', 'cancelled')),
        total_slices bigint NOT NULL CONSTRAINT fanouts_total_slices_check CHECK (total_slices >= 0),
        slices_completed bigint NOT NULL DEFAULT 0,
        slices_failed bigint NOT NULL DEFAULT 0,
        slices_cancelled bigint NOT NULL DEFAULT 0,
        processed_count bigint NOT NULL DEFAULT 0
          CONSTRAINT fanouts_processed_count_check CHECK (processed_count >= 0),
        failed_count bigint NOT NULL DEFAULT 0
          CONSTRAINT fanouts_failed_count_check CHECK (failed_count >= 0),
        pause_rule_id relay.rule_id,
        close_rule_id relay.rule_id,
        closed_at timestamptz,
        version bigint NOT NULL DEFAULT 1,
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT fanouts_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT fanouts_source_key UNIQUE (tenant_id, environment, source_kind, source_id),
        CONSTRAINT fanouts_size_check
          CHECK (sub_batch_size BETWEEN 1 AND slice_size AND slice_size <= 100000),
        CONSTRAINT fanouts_slices_check
          CHECK (slices_completed >= 0 AND slices_failed >= 0 AND slices_cancelled >= 0
            AND slices_completed + slices_failed + slices_cancelled <= total_slices),
        CONSTRAINT fanouts_pause_rule_id_check CHECK ((state = 'paused') = (pause_rule_id IS NOT NULL)),
        CONSTRAINT fanouts_closed_at_check
          CHECK ((state IN ('completed', 'partial', 'cancelled')) = (closed_at IS NOT NULL))
      )
      """,
      scoped("fanouts", :tenant),
      ~S"""
      CREATE TABLE relay.fanout_slices (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        fanout_id uuid NOT NULL,
        slice_no bigint NOT NULL CONSTRAINT fanout_slices_slice_no_check CHECK (slice_no >= 0),
        range_from uuid,
        range_to uuid,
        state text NOT NULL
          CONSTRAINT fanout_slices_state_check
            CHECK (state IN ('pending', 'running', 'completed', 'failed', 'cancelled')),
        checkpoint_after uuid,
        processed_count bigint NOT NULL DEFAULT 0
          CONSTRAINT fanout_slices_processed_count_check CHECK (processed_count >= 0),
        failed_count bigint NOT NULL DEFAULT 0
          CONSTRAINT fanout_slices_failed_count_check CHECK (failed_count >= 0),
        attempts bigint NOT NULL DEFAULT 0 CONSTRAINT fanout_slices_attempts_check CHECK (attempts >= 0),
        started_at timestamptz,
        finished_at timestamptz,
        updated_at timestamptz NOT NULL,
        CONSTRAINT fanout_slices_pkey PRIMARY KEY (tenant_id, environment, fanout_id, slice_no),
        CONSTRAINT fanout_slices_range_check
          CHECK (range_from IS NULL OR range_to IS NULL OR range_from < range_to),
        CONSTRAINT fanout_slices_finished_at_check
          CHECK ((state IN ('completed', 'failed', 'cancelled')) = (finished_at IS NOT NULL)),
        CONSTRAINT fanout_slices_fanout_id_fkey FOREIGN KEY (tenant_id, environment, fanout_id)
          REFERENCES relay.fanouts (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      scoped("fanout_slices", :tenant)
    ]
  end

  defp virtual_clocks do
    [
      ~S"""
      CREATE TABLE relay.virtual_clocks (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL
          CONSTRAINT virtual_clocks_environment_check CHECK (environment = 'test'),
        offset_ms bigint NOT NULL
          CONSTRAINT virtual_clocks_offset_ms_check CHECK (offset_ms BETWEEN 0 AND 315360000000),
        version bigint NOT NULL DEFAULT 1,
        updated_at timestamptz NOT NULL,
        updated_by_ref text NOT NULL
          CONSTRAINT virtual_clocks_updated_by_ref_check CHECK (char_length(updated_by_ref) <= 256),
        CONSTRAINT virtual_clocks_pkey PRIMARY KEY (tenant_id, environment)
      )
      """,
      scoped("virtual_clocks", :virtual_clock)
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
