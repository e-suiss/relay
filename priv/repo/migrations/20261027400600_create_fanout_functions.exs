defmodule Relay.Repo.Migrations.CreateFanoutFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"

  @functions [
    {"relay_private.fanout_emit(relay.fanouts)", "relay_migrator", ~w(relay_owner)},
    {"relay_fn.fanout_create(uuid, text, uuid, text, text, bigint, bigint, uuid[])",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.fanout_slice_begin(uuid, bigint)", "relay_owner", ~w(relay_app)},
    {"relay_fn.fanout_slice_checkpoint(uuid, bigint, uuid, bigint, bigint)", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.fanout_slice_finish(uuid, bigint, text)", "relay_owner", ~w(relay_app)},
    {"relay_fn.fanout_pause(uuid, text)", "relay_owner", ~w(relay_app)},
    {"relay_fn.fanout_resume(uuid)", "relay_owner", ~w(relay_app)},
    {"relay_fn.fanout_cancel(uuid, text, bytea, #{@actor})", "relay_owner", ~w(relay_app)},
    {"relay_fn.fanout_get(uuid)", "relay_owner", ~w(relay_app relay_report)}
  ]

  # T-23
  # TN-54
  # WF-44
  # MD-7
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
      CREATE FUNCTION relay_private.fanout_emit(p_fanout relay.fanouts) RETURNS void
      LANGUAGE plpgsql VOLATILE
      SET search_path = pg_catalog, pg_temp
      AS $fn$
      BEGIN
        PERFORM relay_fn.outbox_append(uuidv7(), 'fanout.' || p_fanout.state,
          'fanout:' || p_fanout.id::text,
          jsonb_build_object('fanout_id', p_fanout.id, 'source_kind', p_fanout.source_kind,
            'source_id', p_fanout.source_id, 'state', p_fanout.state,
            'total_slices', p_fanout.total_slices, 'slices_completed', p_fanout.slices_completed,
            'slices_failed', p_fanout.slices_failed, 'slices_cancelled', p_fanout.slices_cancelled,
            'processed_count', p_fanout.processed_count, 'failed_count', p_fanout.failed_count,
            'close_rule_id', p_fanout.close_rule_id),
          NULL);
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.fanout_create(p_id uuid, p_source_kind text, p_source_id uuid,
        p_lane text, p_mode text, p_slice_size bigint, p_sub_batch_size bigint, p_bounds uuid[])
        RETURNS TABLE (result text, fanout_id uuid, total_slices bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.fanouts;
        v_n bigint := COALESCE(cardinality(p_bounds), 0) - 1;
        v_id uuid;
      BEGIN
        IF p_source_kind IS NULL OR p_source_id IS NULL OR p_lane IS NULL OR p_mode IS NULL
          OR p_slice_size IS NULL OR p_sub_batch_size IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'T-23';
        END IF;
        SELECT * INTO v_row FROM relay.fanouts f
          WHERE f.tenant_id = v_tenant AND f.environment = v_env
            AND ((f.source_kind = p_source_kind AND f.source_id = p_source_id) OR f.id = p_id);
        IF FOUND THEN
          RETURN QUERY SELECT 'exists'::text, v_row.id, v_row.total_slices;
          RETURN;
        END IF;
        IF relay_private.tenant_status() <> 'active' THEN
          RETURN QUERY SELECT 'tenant_inactive'::text, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        IF v_n < 1 OR v_n > 100000
          OR EXISTS (SELECT 1 FROM unnest(p_bounds) WITH ORDINALITY AS b(bound, n)
            WHERE b.bound IS NULL AND b.n NOT IN (1, v_n + 1))
          OR EXISTS (SELECT 1 FROM (SELECT b.bound, lead(b.bound) OVER (ORDER BY b.n) AS next_bound
              FROM unnest(p_bounds) WITH ORDINALITY AS b(bound, n)) s
            WHERE s.bound IS NOT NULL AND s.next_bound IS NOT NULL AND s.bound >= s.next_bound) THEN
          RETURN QUERY SELECT 'invalid_bounds'::text, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        INSERT INTO relay.fanouts AS f (tenant_id, environment, id, source_kind, source_id, lane,
          mode, slice_size, sub_batch_size, state, total_slices, slices_completed, slices_failed,
          slices_cancelled, processed_count, failed_count, version, created_at, updated_at)
        VALUES (v_tenant, v_env, p_id, p_source_kind, p_source_id, p_lane, p_mode, p_slice_size,
          p_sub_batch_size, 'pending', v_n, 0, 0, 0, 0, 0, 1, now(), now())
        ON CONFLICT (tenant_id, environment, source_kind, source_id) DO NOTHING
        RETURNING f.id INTO v_id;
        IF v_id IS NULL THEN
          SELECT * INTO v_row FROM relay.fanouts f
            WHERE f.tenant_id = v_tenant AND f.environment = v_env AND f.source_kind = p_source_kind
              AND f.source_id = p_source_id;
          RETURN QUERY SELECT 'exists'::text, v_row.id, v_row.total_slices;
          RETURN;
        END IF;
        INSERT INTO relay.fanout_slices (tenant_id, environment, fanout_id, slice_no, range_from,
          range_to, state, checkpoint_after, processed_count, failed_count, attempts, updated_at)
        SELECT v_tenant, v_env, p_id, s.n - 1, p_bounds[s.n], p_bounds[s.n + 1], 'pending', NULL, 0,
          0, 0, now()
        FROM generate_series(1, v_n) AS s(n);
        RETURN QUERY SELECT 'created'::text, p_id, v_n;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.fanout_slice_begin(p_fanout_id uuid, p_slice_no bigint)
        RETURNS TABLE (result text, checkpoint_after uuid, range_to uuid)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_slice relay.fanout_slices;
        v_state text;
      BEGIN
        SELECT * INTO v_slice FROM relay.fanout_slices s
          WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.fanout_id = p_fanout_id
            AND s.slice_no = p_slice_no
          FOR NO KEY UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::uuid;
          RETURN;
        END IF;
        IF v_slice.state IN ('completed', 'failed', 'cancelled') THEN
          RETURN QUERY SELECT 'already_terminal'::text, v_slice.checkpoint_after, v_slice.range_to;
          RETURN;
        END IF;
        SELECT f.state INTO v_state FROM relay.fanouts f
          WHERE f.tenant_id = v_tenant AND f.environment = v_env AND f.id = p_fanout_id;
        IF v_state = 'cancelled' THEN
          RETURN QUERY SELECT 'cancelled'::text, v_slice.checkpoint_after, v_slice.range_to;
          RETURN;
        END IF;
        IF v_state = 'paused' THEN
          RETURN QUERY SELECT 'paused'::text, v_slice.checkpoint_after, v_slice.range_to;
          RETURN;
        END IF;
        UPDATE relay.fanout_slices s SET state = 'running', attempts = s.attempts + 1,
            started_at = COALESCE(s.started_at, now()), updated_at = now()
          WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.fanout_id = p_fanout_id
            AND s.slice_no = p_slice_no;
        IF v_state = 'pending' THEN
          UPDATE relay.fanouts f SET state = 'running', version = f.version + 1, updated_at = now()
            WHERE f.tenant_id = v_tenant AND f.environment = v_env AND f.id = p_fanout_id
              AND f.state = 'pending';
        END IF;
        RETURN QUERY SELECT CASE WHEN v_slice.state = 'running' THEN 'resumed' ELSE 'begun' END,
          v_slice.checkpoint_after, v_slice.range_to;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.fanout_slice_checkpoint(p_fanout_id uuid, p_slice_no bigint,
        p_after uuid, p_processed_delta bigint, p_failed_delta bigint)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_slice relay.fanout_slices;
        v_state text;
      BEGIN
        IF COALESCE(p_processed_delta, 0) < 0 OR COALESCE(p_failed_delta, 0) < 0 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'T-23';
        END IF;
        SELECT * INTO v_slice FROM relay.fanout_slices s
          WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.fanout_id = p_fanout_id
            AND s.slice_no = p_slice_no
          FOR NO KEY UPDATE;
        IF NOT FOUND OR v_slice.state <> 'running' THEN
          RETURN 'not_running';
        END IF;
        IF p_after IS NOT NULL THEN
          IF (v_slice.checkpoint_after IS NOT NULL AND p_after <= v_slice.checkpoint_after)
            OR (v_slice.range_from IS NOT NULL AND p_after < v_slice.range_from)
            OR (v_slice.range_to IS NOT NULL AND p_after >= v_slice.range_to) THEN
            RAISE EXCEPTION 'invalid_argument' USING HINT = 'T-23';
          END IF;
          UPDATE relay.fanout_slices s SET checkpoint_after = p_after,
              processed_count = s.processed_count + COALESCE(p_processed_delta, 0),
              failed_count = s.failed_count + COALESCE(p_failed_delta, 0), updated_at = now()
            WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.fanout_id = p_fanout_id
              AND s.slice_no = p_slice_no;
        END IF;
        SELECT f.state INTO v_state FROM relay.fanouts f
          WHERE f.tenant_id = v_tenant AND f.environment = v_env AND f.id = p_fanout_id;
        IF v_state = 'cancelled' THEN
          RETURN 'cancelled';
        END IF;
        IF v_state = 'paused' THEN
          RETURN 'paused';
        END IF;
        RETURN 'continue';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.fanout_slice_finish(p_fanout_id uuid, p_slice_no bigint,
        p_state text)
        RETURNS TABLE (result text, fanout_state text)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_slice relay.fanout_slices;
        v_row relay.fanouts;
        v_was text;
      BEGIN
        IF p_state IS NULL OR p_state NOT IN ('completed', 'failed', 'cancelled') THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'T-23';
        END IF;
        SELECT * INTO v_slice FROM relay.fanout_slices s
          WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.fanout_id = p_fanout_id
            AND s.slice_no = p_slice_no
          FOR NO KEY UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::text;
          RETURN;
        END IF;
        SELECT * INTO v_row FROM relay.fanouts f
          WHERE f.tenant_id = v_tenant AND f.environment = v_env AND f.id = p_fanout_id
          FOR NO KEY UPDATE;
        IF v_slice.state IN ('completed', 'failed', 'cancelled') THEN
          RETURN QUERY SELECT 'already_terminal'::text, v_row.state;
          RETURN;
        END IF;
        UPDATE relay.fanout_slices s SET state = p_state, finished_at = now(), updated_at = now()
          WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.fanout_id = p_fanout_id
            AND s.slice_no = p_slice_no;
        v_was := v_row.state;
        UPDATE relay.fanouts f SET
            slices_completed = f.slices_completed + CASE WHEN p_state = 'completed' THEN 1 ELSE 0 END,
            slices_failed = f.slices_failed + CASE WHEN p_state = 'failed' THEN 1 ELSE 0 END,
            slices_cancelled = f.slices_cancelled + CASE WHEN p_state = 'cancelled' THEN 1 ELSE 0 END,
            processed_count = f.processed_count + v_slice.processed_count,
            failed_count = f.failed_count + v_slice.failed_count,
            version = f.version + 1, updated_at = now()
          WHERE f.tenant_id = v_tenant AND f.environment = v_env AND f.id = p_fanout_id
          RETURNING * INTO v_row;
        IF v_row.slices_completed + v_row.slices_failed + v_row.slices_cancelled = v_row.total_slices THEN
          IF v_was = 'cancelled' THEN
            PERFORM relay_private.fanout_emit(v_row);
          ELSE
            UPDATE relay.fanouts f SET
                state = CASE WHEN f.slices_failed = 0 AND f.slices_cancelled = 0 THEN 'completed'
                  ELSE 'partial' END,
                pause_rule_id = NULL, closed_at = now(), version = f.version + 1, updated_at = now()
              WHERE f.tenant_id = v_tenant AND f.environment = v_env AND f.id = p_fanout_id
              RETURNING * INTO v_row;
            PERFORM relay_private.fanout_emit(v_row);
          END IF;
        END IF;
        RETURN QUERY SELECT 'finished'::text, v_row.state;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.fanout_pause(p_fanout_id uuid, p_rule_id text) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_state text;
      BEGIN
        IF p_rule_id IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'T-34';
        END IF;
        SELECT f.state INTO v_state FROM relay.fanouts f
          WHERE f.tenant_id = v_tenant AND f.environment = v_env AND f.id = p_fanout_id
          FOR NO KEY UPDATE;
        IF v_state = 'paused' THEN
          RETURN 'already_paused';
        END IF;
        IF v_state IS NULL OR v_state NOT IN ('pending', 'running') THEN
          RETURN 'not_running';
        END IF;
        UPDATE relay.fanouts f SET state = 'paused', pause_rule_id = p_rule_id,
            version = f.version + 1, updated_at = now()
          WHERE f.tenant_id = v_tenant AND f.environment = v_env AND f.id = p_fanout_id;
        RETURN 'paused';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.fanout_resume(p_fanout_id uuid) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_state text;
      BEGIN
        SELECT f.state INTO v_state FROM relay.fanouts f
          WHERE f.tenant_id = v_tenant AND f.environment = v_env AND f.id = p_fanout_id
          FOR NO KEY UPDATE;
        IF v_state IS DISTINCT FROM 'paused' THEN
          RETURN 'not_paused';
        END IF;
        UPDATE relay.fanouts f SET
            state = CASE WHEN EXISTS (SELECT 1 FROM relay.fanout_slices s
              WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.fanout_id = p_fanout_id
                AND s.state <> 'pending') THEN 'running' ELSE 'pending' END,
            pause_rule_id = NULL, version = f.version + 1, updated_at = now()
          WHERE f.tenant_id = v_tenant AND f.environment = v_env AND f.id = p_fanout_id;
        RETURN 'resumed';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.fanout_cancel(p_fanout_id uuid, p_rule_id text,
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text)
        RETURNS TABLE (result text, cancelled_slices bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.fanouts;
        v_count bigint;
      BEGIN
        IF p_rule_id IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'T-23';
        END IF;
        SELECT * INTO v_row FROM relay.fanouts f
          WHERE f.tenant_id = v_tenant AND f.environment = v_env AND f.id = p_fanout_id
          FOR NO KEY UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, 0::bigint;
          RETURN;
        END IF;
        IF v_row.state IN ('completed', 'partial', 'cancelled') THEN
          RETURN QUERY SELECT 'already_closed'::text, 0::bigint;
          RETURN;
        END IF;
        WITH cancelled AS (
          UPDATE relay.fanout_slices s SET state = 'cancelled', finished_at = now(), updated_at = now()
            WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.fanout_id = p_fanout_id
              AND s.state = 'pending'
            RETURNING 1
        )
        SELECT count(*) INTO v_count FROM cancelled;
        UPDATE relay.fanouts f SET state = 'cancelled', pause_rule_id = NULL,
            close_rule_id = p_rule_id, closed_at = now(),
            slices_cancelled = f.slices_cancelled + v_count, version = f.version + 1,
            updated_at = now()
          WHERE f.tenant_id = v_tenant AND f.environment = v_env AND f.id = p_fanout_id
          RETURNING * INTO v_row;
        PERFORM relay_fn.drr_cancel('fanout_slice', p_fanout_id, p_rule_id);
        IF v_row.slices_completed + v_row.slices_failed + v_row.slices_cancelled = v_row.total_slices THEN
          PERFORM relay_private.fanout_emit(v_row);
        END IF;
        PERFORM relay_private.audit_write(v_tenant, v_env, 'fanout.cancelled', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'fanout', p_fanout_id::text,
          p_rule_id, p_record_digest);
        RETURN QUERY SELECT 'cancelled'::text, v_count;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.fanout_get(p_fanout_id uuid)
        RETURNS SETOF relay.fanouts
      LANGUAGE sql STABLE SECURITY INVOKER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT * FROM relay.fanouts f
        WHERE f.tenant_id = relay_private.ctx_tenant_id()
          AND f.environment = relay_private.ctx_environment() AND f.id = p_fanout_id
      $fn$
      """
    ]
  end
end
