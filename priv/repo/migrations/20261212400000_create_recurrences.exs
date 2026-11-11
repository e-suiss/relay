defmodule Relay.Repo.Migrations.CreateRecurrences do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  # WF-48
  # WF-49
  # WF-61
  # WF-43
  # WF-47
  # C-8
  # C-52
  # TN-12
  # TN-13
  def up do
    execute(~S"""
    CREATE TABLE relay.recurrences (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      id uuid NOT NULL,
      workflow_id uuid NOT NULL,
      workflow_key relay.workflow_key NOT NULL,
      target_kind text NOT NULL
        CONSTRAINT recurrences_target_kind_check CHECK (target_kind IN ('subscriber', 'topic')),
      recipient_id uuid,
      topic_key text CONSTRAINT recurrences_topic_key_check
        CHECK (char_length(topic_key) BETWEEN 1 AND 128),
      rrule text NOT NULL CONSTRAINT recurrences_rrule_check
        CHECK (char_length(rrule) BETWEEN 6 AND 512),
      dtstart text NOT NULL CONSTRAINT recurrences_dtstart_check
        CHECK (dtstart ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$'),
      timezone text CONSTRAINT recurrences_timezone_check
        CHECK (char_length(timezone) BETWEEN 1 AND 64),
      data_ct bytea CONSTRAINT recurrences_data_ct_check CHECK (octet_length(data_ct) <= 300000),
      data_key_id uuid,
      state text NOT NULL CONSTRAINT recurrences_state_check
        CHECK (state IN ('active', 'completed', 'cancelled')),
      next_at timestamptz,
      next_ordinal bigint CONSTRAINT recurrences_next_ordinal_check CHECK (next_ordinal >= 1),
      next_zone text CONSTRAINT recurrences_next_zone_check
        CHECK (char_length(next_zone) BETWEEN 1 AND 64),
      fire_at timestamptz,
      occurrence_count bigint NOT NULL
        CONSTRAINT recurrences_occurrence_count_check CHECK (occurrence_count >= 0),
      last_occurrence_at timestamptz,
      cancel_reason text CONSTRAINT recurrences_cancel_reason_check
        CHECK (cancel_reason IN ('request', 'subject_erasure')),
      cancelled_at timestamptz,
      completed_at timestamptz,
      created_by text NOT NULL
        CONSTRAINT recurrences_created_by_check CHECK (char_length(created_by) <= 256),
      version bigint NOT NULL CONSTRAINT recurrences_version_check CHECK (version >= 1),
      created_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      CONSTRAINT recurrences_pkey PRIMARY KEY (tenant_id, environment, id),
      CONSTRAINT recurrences_workflow_id_fkey FOREIGN KEY (tenant_id, environment, workflow_id)
        REFERENCES relay.workflows (tenant_id, environment, id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
      CONSTRAINT recurrences_recipient_id_fkey FOREIGN KEY (tenant_id, environment, recipient_id)
        REFERENCES relay.recipients (tenant_id, environment, id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
      CONSTRAINT recurrences_data_key_id_fkey FOREIGN KEY (tenant_id, environment, data_key_id)
        REFERENCES relay.tenant_keys (tenant_id, environment, id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
      CONSTRAINT recurrences_target_check CHECK (
        ((target_kind = 'subscriber') = (recipient_id IS NOT NULL))
        AND ((target_kind = 'topic') = (topic_key IS NOT NULL))
        AND (target_kind = 'topic' OR (timezone IS NULL AND data_key_id IS NULL))),
      CONSTRAINT recurrences_active_check CHECK ((state = 'active')
        = (next_at IS NOT NULL AND fire_at IS NOT NULL AND next_zone IS NOT NULL)),
      CONSTRAINT recurrences_cancelled_check CHECK ((state = 'cancelled')
        = (cancelled_at IS NOT NULL AND cancel_reason IS NOT NULL)),
      CONSTRAINT recurrences_completed_check
        CHECK ((state = 'completed') = (completed_at IS NOT NULL))
    )
    """)

    execute("""
    CREATE INDEX recurrences_fire_at_index ON relay.recurrences (tenant_id, environment, fire_at)
      WHERE state = 'active'
    """)

    execute("""
    CREATE INDEX recurrences_created_at_index
      ON relay.recurrences (tenant_id, environment, created_at, id)
    """)

    execute("""
    CREATE INDEX recurrences_recipient_id_index
      ON relay.recurrences (tenant_id, environment, recipient_id)
      WHERE recipient_id IS NOT NULL
    """)

    execute("""
    CREATE INDEX recurrences_workflow_id_index
      ON relay.recurrences (tenant_id, environment, workflow_id)
    """)

    execute(~S"""
    CREATE TABLE relay.recurrence_occurrences (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      id uuid NOT NULL,
      recurrence_id uuid NOT NULL,
      occurrence_at timestamptz NOT NULL,
      ordinal bigint CONSTRAINT recurrence_occurrences_ordinal_check CHECK (ordinal >= 1),
      outcome text NOT NULL CONSTRAINT recurrence_occurrences_outcome_check
        CHECK (outcome IN ('sent', 'missed', 'skipped', 'failed')),
      rule_id text CONSTRAINT recurrence_occurrences_rule_id_check
        CHECK (char_length(rule_id) BETWEEN 1 AND 128),
      error_code text CONSTRAINT recurrence_occurrences_error_code_check
        CHECK (char_length(error_code) BETWEEN 1 AND 64),
      event_id uuid,
      recorded_at timestamptz NOT NULL,
      created_at timestamptz NOT NULL,
      CONSTRAINT recurrence_occurrences_pkey PRIMARY KEY (tenant_id, environment, id),
      CONSTRAINT recurrence_occurrences_occurrence_key
        UNIQUE (tenant_id, environment, recurrence_id, occurrence_at),
      CONSTRAINT recurrence_occurrences_recurrence_id_fkey
        FOREIGN KEY (tenant_id, environment, recurrence_id)
        REFERENCES relay.recurrences (tenant_id, environment, id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
      CONSTRAINT recurrence_occurrences_event_id_fkey
        FOREIGN KEY (tenant_id, environment, event_id)
        REFERENCES relay.events (tenant_id, environment, id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
      CONSTRAINT recurrence_occurrences_sent_check CHECK ((outcome = 'sent') = (event_id IS NOT NULL)),
      CONSTRAINT recurrence_occurrences_rule_check
        CHECK (outcome NOT IN ('missed', 'skipped') OR rule_id IS NOT NULL),
      CONSTRAINT recurrence_occurrences_failed_check
        CHECK ((outcome = 'failed') = (error_code IS NOT NULL))
    )
    """)

    execute("""
    CREATE INDEX recurrence_occurrences_event_id_index
      ON relay.recurrence_occurrences (tenant_id, environment, event_id)
      WHERE event_id IS NOT NULL
    """)

    for table <- ["recurrences", "recurrence_occurrences"] do
      execute("""
      CREATE TRIGGER #{table}_no_delete BEFORE DELETE ON relay.#{table}
        FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
      """)

      execute("ALTER TABLE relay.#{table} ENABLE ROW LEVEL SECURITY")
      execute("ALTER TABLE relay.#{table} FORCE ROW LEVEL SECURITY")

      execute(
        "CREATE POLICY #{table}_scope ON relay.#{table} USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})"
      )

      execute("GRANT SELECT ON relay.#{table} TO relay_app, relay_maint, relay_archive")
    end

    execute("GRANT SELECT, INSERT, UPDATE ON relay.recurrences TO relay_owner")
    execute("GRANT SELECT, INSERT ON relay.recurrence_occurrences TO relay_owner")
  end

  def down, do: :ok
end
