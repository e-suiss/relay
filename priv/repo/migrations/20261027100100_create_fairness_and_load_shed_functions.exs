defmodule Relay.Repo.Migrations.CreateFairnessAndLoadShedFunctions do
  use Ecto.Migration

  @functions [
    {"relay_private.drr_weight(jsonb)", "relay_migrator", ~w(relay_owner relay_maint)},
    {"relay_fn.drr_enqueue(uuid, text, text, text, jsonb, smallint, bigint, timestamp with time zone, text, uuid, bigint)",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.drr_cancel(text, uuid, text)", "relay_owner", ~w(relay_app)},
    {"relay_ops.drr_take(text, bigint, bigint, integer)", "relay_maint", ~w(relay_worker)},
    {"relay_ops.drr_weights_refresh(text, bigint)", "relay_maint", ~w(relay_worker)},
    {"relay_ops.load_shed_record(uuid, text, text, text, bigint, bigint, bigint, bigint)",
     "relay_maint", ~w(relay_worker)},
    {"relay_ops.load_shed_state()", "relay_maint", ~w(relay_app)}
  ]

  # T-21
  # T-91 (2)
  # TN-54
  # T-34
  # T-34 (4)
  # INV-24
  # OP-8
  def up do
    Enum.each(statements(), &execute/1)

    for {signature, owner, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      if owner == "relay_owner", do: execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
    end
  end

  def down do
    for {signature, _owner, _grantees} <- Enum.reverse(@functions),
        do: execute("DROP FUNCTION #{signature}")
  end

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_private.drr_weight(p_value jsonb) RETURNS bigint
      LANGUAGE sql IMMUTABLE
      SET search_path = pg_catalog, pg_temp
      AS $fn$
        SELECT CASE
          WHEN jsonb_typeof(p_value) = 'number' AND (p_value #>> '{}')::numeric BETWEEN 1 AND 100
            AND (p_value #>> '{}')::numeric = trunc((p_value #>> '{}')::numeric)
          THEN (p_value #>> '{}')::numeric::bigint
          ELSE 1
        END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.drr_enqueue(p_id uuid, p_lane text, p_queue text, p_worker text,
        p_args jsonb, p_priority smallint, p_cost bigint, p_scheduled_at timestamptz,
        p_ref_kind text, p_ref_id uuid, p_queued_cap bigint)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_pending bigint;
        v_id uuid;
      BEGIN
        IF p_lane IS NULL OR p_lane NOT IN ('l0', 'l1', 'l2', 'l3') THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'T-31';
        END IF;
        IF p_lane IN ('l0', 'l1') THEN
          RETURN 'lane_not_fair';
        END IF;
        IF relay_private.tenant_status() <> 'active' THEN
          RETURN 'tenant_inactive';
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        IF p_queue IS NULL OR p_queue !~ '^l[0-3](_[a-z_]+)?$' OR left(p_queue, 2) <> p_lane
          OR p_worker IS NULL OR p_worker !~ '^[A-Z][A-Za-z0-9_.]{1,127}$'
          OR p_args IS NULL OR jsonb_typeof(p_args) <> 'object' OR pg_column_size(p_args) > 1024
          OR p_priority IS NULL OR p_priority NOT BETWEEN 0 AND 9
          OR p_cost IS NULL OR p_cost NOT BETWEEN 1 AND 5000
          OR p_scheduled_at IS NULL OR p_ref_kind IS NULL OR p_ref_kind !~ '^[a-z_]{1,32}$'
          OR p_ref_id IS NULL OR p_queued_cap IS NULL OR p_queued_cap < 1 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'T-21';
        END IF;
        INSERT INTO relay_queue.drr_tenants AS t (tenant_id, environment, lane, weight, deficit,
          pending_count, pending_cost, active, last_served_round, expires_at, updated_at)
        VALUES (v_tenant, v_env, p_lane,
          COALESCE((SELECT relay_private.drr_weight(s.value) FROM relay.settings s
            WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.subtenant_id IS NULL
              AND s.key = 'fairness.weight.' || p_lane), 1),
          0, 0, 0, false, 0, now() + interval '7 days', now())
        ON CONFLICT (tenant_id, environment, lane) DO UPDATE SET updated_at = now()
        RETURNING t.pending_count INTO v_pending;
        IF EXISTS (SELECT 1 FROM relay_queue.drr_waits w
          WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_id) THEN
          RETURN 'exists';
        END IF;
        IF v_pending + 1 > p_queued_cap THEN
          RETURN 'queued_cap_exceeded';
        END IF;
        INSERT INTO relay_queue.drr_waits AS w (tenant_id, environment, id, lane, queue, worker,
          args, priority, cost, scheduled_at, ref_kind, ref_id, state, cancel_rule_id,
          state_changed_at, prunable_at, created_at)
        VALUES (v_tenant, v_env, p_id, p_lane, p_queue, p_worker, p_args, p_priority, p_cost,
          p_scheduled_at, p_ref_kind, p_ref_id, 'waiting', NULL, NULL, NULL, now())
        ON CONFLICT (tenant_id, environment, id) DO NOTHING
        RETURNING w.id INTO v_id;
        IF v_id IS NULL THEN
          RETURN 'exists';
        END IF;
        UPDATE relay_queue.drr_tenants t SET pending_count = t.pending_count + 1,
            pending_cost = t.pending_cost + p_cost, active = true,
            expires_at = now() + interval '7 days', updated_at = now()
          WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.lane = p_lane;
        RETURN 'enqueued';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.drr_cancel(p_ref_kind text, p_ref_id uuid, p_rule_id text)
        RETURNS TABLE (result text, cancelled bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_count bigint;
      BEGIN
        IF p_ref_kind IS NULL OR p_ref_id IS NULL OR p_rule_id IS NULL
          OR p_rule_id !~ '^[a-z][a-z0-9_]*([.:][A-Za-z0-9_-]+)*$'
          OR char_length(p_rule_id) > 128 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'T-21';
        END IF;
        PERFORM 1 FROM relay_queue.drr_tenants t
          WHERE t.tenant_id = v_tenant AND t.environment = v_env
            AND t.lane IN (SELECT w.lane FROM relay_queue.drr_waits w
              WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.ref_kind = p_ref_kind
                AND w.ref_id = p_ref_id AND w.state = 'waiting')
          ORDER BY t.lane
          FOR UPDATE;
        WITH c AS (
          UPDATE relay_queue.drr_waits w SET state = 'cancelled', cancel_rule_id = p_rule_id,
              state_changed_at = now(), prunable_at = now() + interval '1 day'
            WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.ref_kind = p_ref_kind
              AND w.ref_id = p_ref_id AND w.state = 'waiting'
            RETURNING w.lane, w.cost
        ), s AS (
          SELECT c.lane, count(*) AS n, sum(c.cost) AS total FROM c GROUP BY c.lane
        ), u AS (
          UPDATE relay_queue.drr_tenants t SET pending_count = t.pending_count - s.n,
              pending_cost = t.pending_cost - s.total, active = t.pending_count - s.n > 0,
              deficit = CASE WHEN t.pending_count - s.n > 0 THEN t.deficit ELSE 0 END,
              expires_at = now() + interval '7 days', updated_at = now()
            FROM s
            WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.lane = s.lane
            RETURNING s.n
        )
        SELECT COALESCE(sum(u.n), 0)::bigint INTO v_count FROM u;
        IF v_count = 0 THEN
          RETURN QUERY SELECT 'none'::text, 0::bigint;
        ELSE
          RETURN QUERY SELECT 'cancelled'::text, v_count;
        END IF;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.drr_take(p_lane text, p_fencing_token bigint, p_quantum bigint,
        p_max_jobs integer)
        RETURNS TABLE (result text, tenant_id uuid, environment text, id uuid, queue text,
          worker text, args jsonb, priority smallint, scheduled_at timestamptz)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_task relay.singleton_tasks;
        v_round bigint;
        v_tenant relay_queue.drr_tenants;
        v_wait record;
        v_deficit bigint;
        v_taken integer := 0;
        v_count bigint;
        v_cost bigint;
        v_left bigint;
      BEGIN
        IF p_lane IS NULL OR p_lane NOT IN ('l2', 'l3') OR p_fencing_token IS NULL
          OR p_quantum IS NULL OR p_quantum < 5000 OR p_max_jobs IS NULL OR p_max_jobs < 1 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'T-21';
        END IF;
        SELECT * INTO v_task FROM relay.singleton_tasks t WHERE t.name = 'drr_dispatcher' FOR UPDATE;
        IF NOT FOUND OR v_task.fencing_token <> p_fencing_token OR v_task.lease_until IS NULL
          OR v_task.lease_until <= now() THEN
          RETURN QUERY SELECT 'not_leader'::text, NULL::uuid, NULL::text, NULL::uuid, NULL::text,
            NULL::text, NULL::jsonb, NULL::smallint, NULL::timestamptz;
          RETURN;
        END IF;
        v_round := COALESCE((v_task.state -> p_lane ->> 'round')::bigint, 0) + 1;
        UPDATE relay.singleton_tasks t
          SET state = COALESCE(t.state, '{}'::jsonb)
              || jsonb_build_object(p_lane, jsonb_build_object('round', v_round)),
            updated_at = now()
          WHERE t.name = 'drr_dispatcher';
        FOR v_tenant IN
          SELECT * FROM relay_queue.drr_tenants t
          WHERE t.lane = p_lane AND t.active
          ORDER BY t.last_served_round, t.tenant_id, t.environment
          FOR UPDATE
        LOOP
          EXIT WHEN v_taken >= p_max_jobs;
          v_deficit := v_tenant.deficit + v_tenant.weight * p_quantum;
          v_count := 0;
          v_cost := 0;
          FOR v_wait IN
            SELECT w.id, w.queue, w.worker, w.args, w.priority, w.scheduled_at, w.cost
            FROM relay_queue.drr_waits w
            WHERE w.lane = p_lane AND w.tenant_id = v_tenant.tenant_id
              AND w.environment = v_tenant.environment AND w.state = 'waiting'
              AND w.scheduled_at <= now()
            ORDER BY w.priority, w.scheduled_at, w.id
            FOR UPDATE
          LOOP
            EXIT WHEN v_wait.cost > v_deficit OR v_taken >= p_max_jobs;
            UPDATE relay_queue.drr_waits w SET state = 'dispatched', state_changed_at = now(),
                prunable_at = now() + interval '1 day'
              WHERE w.tenant_id = v_tenant.tenant_id AND w.environment = v_tenant.environment
                AND w.id = v_wait.id;
            v_deficit := v_deficit - v_wait.cost;
            v_count := v_count + 1;
            v_cost := v_cost + v_wait.cost;
            v_taken := v_taken + 1;
            RETURN QUERY SELECT 'dispatched'::text, v_tenant.tenant_id, v_tenant.environment::text,
              v_wait.id, v_wait.queue, v_wait.worker, v_wait.args, v_wait.priority,
              v_wait.scheduled_at;
          END LOOP;
          v_left := v_tenant.pending_count - v_count;
          IF v_left = 0 OR NOT EXISTS (SELECT 1 FROM relay_queue.drr_waits w
            WHERE w.lane = p_lane AND w.tenant_id = v_tenant.tenant_id
              AND w.environment = v_tenant.environment AND w.state = 'waiting'
              AND w.scheduled_at <= now()) THEN
            v_deficit := 0;
          END IF;
          UPDATE relay_queue.drr_tenants t SET deficit = v_deficit, pending_count = v_left,
              pending_cost = t.pending_cost - v_cost, active = v_left > 0,
              last_served_round = v_round, expires_at = now() + interval '7 days',
              updated_at = now()
            WHERE t.tenant_id = v_tenant.tenant_id AND t.environment = v_tenant.environment
              AND t.lane = p_lane;
        END LOOP;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.drr_weights_refresh(p_lane text, p_fencing_token bigint)
        RETURNS TABLE (result text, updated bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_task relay.singleton_tasks;
        v_count bigint;
      BEGIN
        IF p_lane IS NULL OR p_lane NOT IN ('l2', 'l3') OR p_fencing_token IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'T-21';
        END IF;
        SELECT * INTO v_task FROM relay.singleton_tasks t WHERE t.name = 'drr_dispatcher' FOR UPDATE;
        IF NOT FOUND OR v_task.fencing_token <> p_fencing_token OR v_task.lease_until IS NULL
          OR v_task.lease_until <= now() THEN
          RETURN QUERY SELECT 'not_leader'::text, 0::bigint;
          RETURN;
        END IF;
        WITH n AS (
          SELECT t.tenant_id, t.environment,
            COALESCE((SELECT relay_private.drr_weight(s.value) FROM relay.settings s
              WHERE s.tenant_id = t.tenant_id AND s.environment = t.environment
                AND s.subtenant_id IS NULL AND s.key = 'fairness.weight.' || p_lane), 1) AS weight
          FROM relay_queue.drr_tenants t
          WHERE t.lane = p_lane
        ), u AS (
          UPDATE relay_queue.drr_tenants t SET weight = n.weight, updated_at = now()
            FROM n
            WHERE t.tenant_id = n.tenant_id AND t.environment = n.environment
              AND t.lane = p_lane AND t.weight <> n.weight
            RETURNING 1
        )
        SELECT count(*)::bigint INTO v_count FROM u;
        RETURN QUERY SELECT 'refreshed'::text, v_count;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.load_shed_record(p_id uuid, p_lane text, p_phase text,
        p_rule_id text, p_sample_ms bigint, p_target_ms bigint, p_interval_ms bigint,
        p_fencing_token bigint)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_task relay.singleton_tasks;
        v_last text;
      BEGIN
        IF p_lane IS NULL OR p_lane NOT IN ('l0', 'l1', 'l2', 'l3')
          OR p_phase IS NULL OR p_phase NOT IN ('engaged', 'released')
          OR p_rule_id IS NULL OR p_rule_id !~ '^[a-z][a-z0-9_]*([.:][A-Za-z0-9_-]+)*$'
          OR char_length(p_rule_id) > 128 OR (p_lane = 'l0' AND p_rule_id <> 'load_shed.l0_alarm')
          OR p_sample_ms IS NULL OR p_sample_ms < 0 OR p_target_ms IS NULL OR p_target_ms < 0
          OR p_interval_ms IS NULL OR p_interval_ms < 0 OR p_fencing_token IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'T-34';
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        SELECT * INTO v_task FROM relay.singleton_tasks t
          WHERE t.name = 'load_shed_controller' FOR UPDATE;
        IF NOT FOUND OR v_task.fencing_token <> p_fencing_token OR v_task.lease_until IS NULL
          OR v_task.lease_until <= now() THEN
          RETURN 'not_leader';
        END IF;
        SELECT e.phase INTO v_last FROM relay.load_shed_events e
          WHERE e.lane = p_lane ORDER BY e.created_at DESC, e.id DESC LIMIT 1;
        IF COALESCE(v_last, 'released') = p_phase THEN
          RETURN 'unchanged';
        END IF;
        INSERT INTO relay.load_shed_events (id, lane, phase, rule_id, sample_ms, target_ms,
          interval_ms, fencing_token, created_at)
        VALUES (p_id, p_lane, p_phase, p_rule_id, p_sample_ms, p_target_ms, p_interval_ms,
          p_fencing_token, now());
        RETURN 'recorded';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.load_shed_state()
        RETURNS TABLE (lane text, phase text, rule_id text, since timestamptz)
      LANGUAGE sql STABLE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT DISTINCT ON (e.lane) e.lane::text, e.phase, e.rule_id::text, e.created_at
        FROM relay.load_shed_events e
        ORDER BY e.lane, e.created_at DESC, e.id DESC
      $fn$
      """
    ]
  end
end
