defmodule Relay.Repo.Migrations.CreateFairnessAndLoadShedTables do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  # T-21
  # T-91 (2)
  # TN-51
  # TN-54
  # OP-74
  # OP-12
  # T-34 (4)
  # INV-24
  # INV-6
  def up do
    Enum.each(List.flatten(statements()), &execute/1)
  end

  defp statements do
    [
      ~S"""
      CREATE TABLE relay_queue.drr_waits (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        lane relay.lane NOT NULL CONSTRAINT drr_waits_lane_check CHECK (lane IN ('l2', 'l3')),
        queue text NOT NULL
          CONSTRAINT drr_waits_queue_check
            CHECK (queue ~ '^l[0-3](_[a-z_]+)?$' AND left(queue, 2) = lane),
        worker text NOT NULL
          CONSTRAINT drr_waits_worker_check CHECK (worker ~ '^[A-Z][A-Za-z0-9_.]{1,127}$'),
        args jsonb NOT NULL CONSTRAINT drr_waits_args_check CHECK (pg_column_size(args) <= 1024),
        priority smallint NOT NULL CONSTRAINT drr_waits_priority_check CHECK (priority BETWEEN 0 AND 9),
        cost bigint NOT NULL CONSTRAINT drr_waits_cost_check CHECK (cost BETWEEN 1 AND 100000),
        scheduled_at timestamptz NOT NULL,
        ref_kind text NOT NULL CONSTRAINT drr_waits_ref_kind_check CHECK (ref_kind ~ '^[a-z_]{1,32}$'),
        ref_id uuid NOT NULL,
        state text NOT NULL
          CONSTRAINT drr_waits_state_check CHECK (state IN ('waiting', 'dispatched', 'cancelled')),
        cancel_rule_id relay.rule_id,
        state_changed_at timestamptz,
        prunable_at timestamptz,
        created_at timestamptz NOT NULL,
        CONSTRAINT drr_waits_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT drr_waits_cancel_rule_id_check
          CHECK ((state = 'cancelled') = (cancel_rule_id IS NOT NULL)),
        CONSTRAINT drr_waits_state_changed_at_check
          CHECK ((state = 'waiting') = (state_changed_at IS NULL)),
        CONSTRAINT drr_waits_prunable_at_check
          CHECK ((state = 'waiting') = (prunable_at IS NULL))
      )
      """,
      """
      CREATE INDEX drr_waits_dispatch_index ON relay_queue.drr_waits
        (lane, tenant_id, environment, priority, scheduled_at, id) WHERE state = 'waiting'
      """,
      """
      CREATE INDEX drr_waits_ref_index ON relay_queue.drr_waits
        (tenant_id, environment, ref_kind, ref_id) WHERE state = 'waiting'
      """,
      """
      CREATE INDEX drr_waits_prunable_at_index ON relay_queue.drr_waits (prunable_at)
        WHERE prunable_at IS NOT NULL
      """,
      ephemeral("drr_waits", "prunable_at < now() - interval '1 hour'"),
      ~S"""
      CREATE TABLE relay_queue.drr_tenants (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        lane relay.lane NOT NULL CONSTRAINT drr_tenants_lane_check CHECK (lane IN ('l2', 'l3')),
        weight bigint NOT NULL CONSTRAINT drr_tenants_weight_check CHECK (weight BETWEEN 1 AND 100),
        deficit bigint NOT NULL CONSTRAINT drr_tenants_deficit_check CHECK (deficit >= 0),
        pending_count bigint NOT NULL
          CONSTRAINT drr_tenants_pending_count_check CHECK (pending_count >= 0),
        pending_cost bigint NOT NULL
          CONSTRAINT drr_tenants_pending_cost_check CHECK (pending_cost >= 0),
        active boolean NOT NULL,
        last_served_round bigint NOT NULL,
        expires_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT drr_tenants_pkey PRIMARY KEY (tenant_id, environment, lane),
        CONSTRAINT drr_tenants_active_check CHECK (active = (pending_count > 0))
      )
      """,
      """
      CREATE INDEX drr_tenants_round_index ON relay_queue.drr_tenants
        (lane, last_served_round, tenant_id, environment) WHERE active
      """,
      """
      CREATE INDEX drr_tenants_expires_at_index ON relay_queue.drr_tenants (expires_at)
        WHERE NOT active
      """,
      ephemeral("drr_tenants", "expires_at < now() - interval '1 hour' AND NOT active"),
      ~S"""
      CREATE TABLE relay.load_shed_events (
        id uuid NOT NULL,
        lane relay.lane NOT NULL,
        phase text NOT NULL
          CONSTRAINT load_shed_events_phase_check CHECK (phase IN ('engaged', 'released')),
        rule_id relay.rule_id NOT NULL,
        sample_ms bigint NOT NULL CONSTRAINT load_shed_events_sample_ms_check CHECK (sample_ms >= 0),
        target_ms bigint NOT NULL CONSTRAINT load_shed_events_target_ms_check CHECK (target_ms >= 0),
        interval_ms bigint NOT NULL
          CONSTRAINT load_shed_events_interval_ms_check CHECK (interval_ms >= 0),
        fencing_token bigint NOT NULL,
        created_at timestamptz NOT NULL,
        CONSTRAINT load_shed_events_pkey PRIMARY KEY (id),
        CONSTRAINT load_shed_events_l0_check CHECK (lane <> 'l0' OR rule_id = 'load_shed.l0_alarm')
      )
      """,
      "CREATE INDEX load_shed_events_lane_index ON relay.load_shed_events (lane, created_at, id)",
      "GRANT SELECT ON relay.load_shed_events TO relay_app, relay_archive, relay_report",
      "GRANT SELECT, INSERT ON relay.load_shed_events TO relay_maint",
      """
      CREATE TRIGGER load_shed_events_append_only BEFORE UPDATE OR DELETE ON relay.load_shed_events
        FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
      """,
      """
      CREATE TRIGGER load_shed_events_no_truncate BEFORE TRUNCATE ON relay.load_shed_events
        FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
      """
    ]
  end

  # OP-74
  defp ephemeral(table, prune) do
    [
      "ALTER TABLE relay_queue.#{table} ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE relay_queue.#{table} FORCE ROW LEVEL SECURITY",
      "CREATE POLICY #{table}_scope ON relay_queue.#{table} USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})",
      "CREATE POLICY #{table}_prune_read ON relay_queue.#{table} FOR SELECT TO relay_queue USING (#{prune})",
      "CREATE POLICY #{table}_prune ON relay_queue.#{table} FOR DELETE TO relay_queue USING (#{prune})",
      "GRANT SELECT, INSERT, UPDATE ON relay_queue.#{table} TO relay_owner",
      "GRANT SELECT, DELETE ON relay_queue.#{table} TO relay_queue",
      "GRANT SELECT, UPDATE ON relay_queue.#{table} TO relay_maint"
    ]
  end
end
