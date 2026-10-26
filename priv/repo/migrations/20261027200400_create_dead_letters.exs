defmodule Relay.Repo.Migrations.CreateDeadLetters do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  # T-29
  # INV-3
  # OP-12
  # OP-13
  # OP-66
  # TN-12
  # TN-13
  def up do
    execute(~S"""
    CREATE TABLE relay.dead_letters (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      id uuid NOT NULL,
      created_at timestamptz NOT NULL,
      delivery_id uuid NOT NULL,
      notification_id uuid NOT NULL,
      recipient_id uuid NOT NULL,
      channel relay.channel NOT NULL,
      provider text,
      provider_account_id uuid,
      message_class relay.message_class NOT NULL,
      dlq_class relay.dlq_class NOT NULL,
      failure_class relay.failure_class NOT NULL,
      invalidates_target boolean NOT NULL,
      raw_code text CONSTRAINT dead_letters_raw_code_check CHECK (char_length(raw_code) <= 128),
      attempt_count bigint NOT NULL CONSTRAINT dead_letters_attempt_count_check CHECK (attempt_count >= 1),
      first_attempt_at timestamptz NOT NULL,
      last_attempt_at timestamptz NOT NULL,
      target_key relay.sha256 NOT NULL,
      expires_at timestamptz,
      entry_rule_id relay.rule_id NOT NULL,
      channel_parameters_version_id uuid,
      replay_depth smallint NOT NULL
        CONSTRAINT dead_letters_replay_depth_check CHECK (replay_depth IN (0, 1)),
      replay_of_id uuid,
      replay_of_created_at timestamptz,
      state text NOT NULL
        CONSTRAINT dead_letters_state_check CHECK (state IN ('open', 'replaying', 'replayed', 'closed')),
      close_reason text
        CONSTRAINT dead_letters_close_reason_check
          CHECK (close_reason IN ('expired', 'not_replayable', 'operator', 'replay_failed')),
      replay_requested_at timestamptz,
      replay_actor_kind relay.actor_kind,
      replay_actor_ref text
        CONSTRAINT dead_letters_replay_actor_ref_check CHECK (char_length(replay_actor_ref) <= 256),
      replay_approval_ref text
        CONSTRAINT dead_letters_replay_approval_ref_check
          CHECK (char_length(replay_approval_ref) BETWEEN 1 AND 256),
      replay_cause_fixed_ref text
        CONSTRAINT dead_letters_replay_cause_fixed_ref_check
          CHECK (char_length(replay_cause_fixed_ref) BETWEEN 1 AND 256),
      replay_attempt_no bigint,
      replay_idempotency_key text
        CONSTRAINT dead_letters_replay_idempotency_key_check
          CHECK (replay_idempotency_key ~ '^rpl_[0-9a-f]{32}$'),
      state_changed_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      CONSTRAINT dead_letters_pkey PRIMARY KEY (tenant_id, environment, id, created_at),
      CONSTRAINT dead_letters_invalidates_target_check
        CHECK (NOT invalidates_target OR failure_class = 'permanent_target'),
      CONSTRAINT dead_letters_attempt_times_check CHECK (first_attempt_at <= last_attempt_at),
      CONSTRAINT dead_letters_replay_of_id_check CHECK ((replay_depth = 1) = (replay_of_id IS NOT NULL)),
      CONSTRAINT dead_letters_replay_of_created_at_check
        CHECK ((replay_of_id IS NULL) = (replay_of_created_at IS NULL)),
      CONSTRAINT dead_letters_close_check CHECK ((state = 'closed') = (close_reason IS NOT NULL)),
      CONSTRAINT dead_letters_replay_requested_at_check
        CHECK ((state IN ('replaying', 'replayed')) = (replay_requested_at IS NOT NULL)),
      CONSTRAINT dead_letters_approval_check
        CHECK (dlq_class <> 'quality_alarm' OR state NOT IN ('replaying', 'replayed')
          OR replay_approval_ref IS NOT NULL),
      CONSTRAINT dead_letters_cause_fixed_check
        CHECK (dlq_class <> 'permanent' OR state NOT IN ('replaying', 'replayed')
          OR replay_cause_fixed_ref IS NOT NULL),
      CONSTRAINT dead_letters_never_replayed_check
        CHECK (NOT (invalidates_target AND state IN ('replaying', 'replayed'))),
      CONSTRAINT dead_letters_replay_depth_limit_check
        CHECK (replay_depth = 0 OR state NOT IN ('replaying', 'replayed')),
      CONSTRAINT dead_letters_delivery_id_fkey FOREIGN KEY (tenant_id, environment, delivery_id)
        REFERENCES relay.deliveries (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
      CONSTRAINT dead_letters_notification_id_fkey
        FOREIGN KEY (tenant_id, environment, notification_id, recipient_id)
        REFERENCES relay.notifications (tenant_id, environment, id, recipient_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT
    ) PARTITION BY RANGE (created_at)
    """)

    execute("""
    CREATE INDEX dead_letters_delivery_id_index ON relay.dead_letters
      (tenant_id, environment, delivery_id)
    """)

    execute("""
    CREATE INDEX dead_letters_open_class_index ON relay.dead_letters
      (tenant_id, environment, dlq_class, created_at) WHERE state = 'open'
    """)

    execute("""
    CREATE INDEX dead_letters_open_exhausted_index ON relay.dead_letters (provider, created_at)
      WHERE state = 'open' AND dlq_class = 'exhausted'
    """)

    execute("ALTER TABLE relay.dead_letters ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE relay.dead_letters FORCE ROW LEVEL SECURITY")

    execute(
      "CREATE POLICY dead_letters_scope ON relay.dead_letters USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})"
    )

    execute("GRANT SELECT, INSERT, UPDATE ON relay.dead_letters TO relay_owner")

    execute(
      "GRANT SELECT ON relay.dead_letters TO relay_app, relay_maint, relay_archive, relay_report"
    )

    execute("""
    INSERT INTO relay.partition_policies (table_name, partition_interval, premake_horizon,
      alarm_threshold, hot_retention, updated_at, updated_by_ref)
    VALUES ('dead_letters', 'month', interval '2 months', interval '3 days', interval '13 months',
      now(), 'migration')
    """)

    execute("""
    SELECT relay_private.partition_create('dead_letters', m, m + interval '1 month')
    FROM generate_series(date_trunc('month', now(), 'UTC'),
      now() + interval '2 months', interval '1 month') AS m
    """)
  end
end
