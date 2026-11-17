defmodule Relay.Repo.Migrations.CreateAgentCeilingTables do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  @tables ~w(agent_ceiling_events agent_ceiling_decisions agent_ceiling_holds agent_run_states)

  # AG-48
  # AG-49
  # AG-50
  # INV-3
  # INV-34
  # OP-9
  def up do
    Enum.each(statements(), &execute/1)
    Enum.each(@tables, fn table -> Enum.each(scoped(table), &execute/1) end)
  end

  def down, do: :ok

  defp statements do
    [
      ~S"""
      CREATE TABLE relay.agent_ceiling_events (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        agent_ref uuid NOT NULL,
        rule_id text NOT NULL
          CONSTRAINT agent_ceiling_events_rule_id_check
            CHECK (rule_id IN ('agent_ceiling.exceeded', 'agent_ceiling.counter_unreadable')),
        held_count bigint NOT NULL
          CONSTRAINT agent_ceiling_events_held_count_check CHECK (held_count >= 0),
        state text NOT NULL
          CONSTRAINT agent_ceiling_events_state_check CHECK (state IN ('open', 'decided')),
        decided_at timestamptz,
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT agent_ceiling_events_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT agent_ceiling_events_decided_check
          CHECK ((state = 'decided') = (decided_at IS NOT NULL))
      )
      """,
      """
      CREATE UNIQUE INDEX agent_ceiling_events_open_key ON relay.agent_ceiling_events
        (tenant_id, environment, agent_ref) WHERE state = 'open'
      """,
      ~S"""
      CREATE TABLE relay.agent_ceiling_decisions (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        agent_ref uuid NOT NULL,
        ceiling_event_id uuid NOT NULL,
        decision text NOT NULL
          CONSTRAINT agent_ceiling_decisions_decision_check
            CHECK (decision IN ('send_all', 'cancel', 'stop')),
        decision_ref text NOT NULL
          CONSTRAINT agent_ceiling_decisions_decision_ref_check
            CHECK (decision_ref ~ '^[\x20-\x7e]{1,256}$'),
        note text
          CONSTRAINT agent_ceiling_decisions_note_check CHECK (char_length(note) <= 1000),
        applied_count bigint NOT NULL
          CONSTRAINT agent_ceiling_decisions_applied_count_check CHECK (applied_count >= 0),
        decided_by_ref text NOT NULL
          CONSTRAINT agent_ceiling_decisions_decided_by_ref_check
            CHECK (char_length(decided_by_ref) BETWEEN 1 AND 256),
        step_up_ref text
          CONSTRAINT agent_ceiling_decisions_step_up_ref_check
            CHECK (char_length(step_up_ref) BETWEEN 1 AND 512),
        decided_at timestamptz NOT NULL,
        created_at timestamptz NOT NULL,
        CONSTRAINT agent_ceiling_decisions_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT agent_ceiling_decisions_ceiling_event_id_key
          UNIQUE (tenant_id, environment, ceiling_event_id),
        CONSTRAINT agent_ceiling_decisions_release_check
          CHECK (decision <> 'send_all' OR step_up_ref IS NOT NULL),
        CONSTRAINT agent_ceiling_decisions_ceiling_event_id_fkey
          FOREIGN KEY (tenant_id, environment, ceiling_event_id)
          REFERENCES relay.agent_ceiling_events (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE INDEX agent_ceiling_decisions_agent_index ON relay.agent_ceiling_decisions
        (tenant_id, environment, agent_ref, decided_at DESC)
      """,
      ~S"""
      CREATE TABLE relay.agent_ceiling_holds (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        notification_id uuid NOT NULL,
        agent_ref uuid NOT NULL,
        state text NOT NULL
          CONSTRAINT agent_ceiling_holds_state_check
            CHECK (state IN ('passed', 'held', 'released', 'cancelled', 'expired')),
        rule_id text
          CONSTRAINT agent_ceiling_holds_rule_id_check
            CHECK (rule_id IN ('agent_ceiling.exceeded', 'agent_ceiling.counter_unreadable')),
        ceiling_event_id uuid,
        decision_id uuid,
        expires_at timestamptz,
        held_at timestamptz,
        decided_at timestamptz,
        applied_at timestamptz,
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT agent_ceiling_holds_pkey PRIMARY KEY (tenant_id, environment, notification_id),
        CONSTRAINT agent_ceiling_holds_held_check
          CHECK ((state = 'passed') = (held_at IS NULL)
            AND (state = 'passed') = (rule_id IS NULL)
            AND (state = 'passed') = (ceiling_event_id IS NULL)),
        CONSTRAINT agent_ceiling_holds_decided_check
          CHECK ((state IN ('released', 'cancelled', 'expired')) = (decision_id IS NOT NULL)
            AND (decision_id IS NULL) = (decided_at IS NULL)),
        CONSTRAINT agent_ceiling_holds_applied_check
          CHECK (applied_at IS NULL OR decision_id IS NOT NULL),
        CONSTRAINT agent_ceiling_holds_notification_id_fkey
          FOREIGN KEY (tenant_id, environment, notification_id)
          REFERENCES relay.notifications (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT agent_ceiling_holds_ceiling_event_id_fkey
          FOREIGN KEY (tenant_id, environment, ceiling_event_id)
          REFERENCES relay.agent_ceiling_events (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT agent_ceiling_holds_decision_id_fkey
          FOREIGN KEY (tenant_id, environment, decision_id)
          REFERENCES relay.agent_ceiling_decisions (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE INDEX agent_ceiling_holds_held_index ON relay.agent_ceiling_holds
        (tenant_id, environment, agent_ref, held_at DESC, notification_id DESC)
        WHERE held_at IS NOT NULL
      """,
      """
      CREATE INDEX agent_ceiling_holds_pending_index ON relay.agent_ceiling_holds
        (tenant_id, environment, decision_id, notification_id)
        WHERE decision_id IS NOT NULL AND applied_at IS NULL
      """,
      """
      CREATE INDEX agent_ceiling_holds_ceiling_event_id_index ON relay.agent_ceiling_holds
        (tenant_id, environment, ceiling_event_id)
      """,
      ~S"""
      CREATE TABLE relay.agent_run_states (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        agent_ref uuid NOT NULL,
        state text NOT NULL
          CONSTRAINT agent_run_states_state_check CHECK (state IN ('active', 'stopped')),
        decision_ref text NOT NULL
          CONSTRAINT agent_run_states_decision_ref_check
            CHECK (decision_ref ~ '^[\x20-\x7e]{1,256}$'),
        changed_at timestamptz NOT NULL,
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT agent_run_states_pkey PRIMARY KEY (tenant_id, environment, agent_ref)
      )
      """
    ]
  end

  defp scoped(table) do
    [
      """
      CREATE TRIGGER #{table}_no_delete BEFORE DELETE ON relay.#{table}
        FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
      """,
      """
      CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON relay.#{table}
        FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
      """,
      "ALTER TABLE relay.#{table} ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE relay.#{table} FORCE ROW LEVEL SECURITY",
      "CREATE POLICY #{table}_scope ON relay.#{table} USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})",
      "GRANT SELECT, INSERT, UPDATE ON relay.#{table} TO relay_owner",
      "GRANT SELECT ON relay.#{table} TO relay_app, relay_maint, relay_archive, relay_report"
    ]
  end
end
