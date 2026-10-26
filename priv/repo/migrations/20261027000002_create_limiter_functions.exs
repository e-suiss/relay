defmodule Relay.Repo.Migrations.CreateLimiterFunctions do
  use Ecto.Migration

  @owner ~w(relay_owner)

  @functions [
    {"relay_private.rl_fdiv(bigint, bigint)", "relay_migrator", @owner},
    {"relay_private.rl_cdiv(bigint, bigint)", "relay_migrator", @owner},
    {"relay_private.rl_cur(bigint, bigint, bigint)", "relay_migrator", @owner},
    {"relay_private.rl_prev(bigint, bigint, bigint, bigint)", "relay_migrator", @owner},
    {"relay_private.rl_estimate(bigint, bigint, bigint, bigint, bigint, bigint)",
     "relay_migrator", @owner},
    {"relay_private.rl_expires(bigint, bigint)", "relay_migrator", @owner},
    {"relay_private.rl_log_trim(bigint[], bigint, bigint)", "relay_migrator", @owner},
    {"relay_private.rl_ring_shift(bigint[], bigint, bigint)", "relay_migrator", @owner},
    {"relay_private.rl_gcra_at(bigint, text, bigint, bigint, bigint, bigint, bigint, bigint, bigint)",
     "relay_migrator", @owner},
    {"relay_private.rl_window_at(bigint, text, text, bigint, bigint, bigint, bigint)",
     "relay_migrator", @owner},
    {"relay_private.rl_counter_at(bigint, text, bigint, text, bigint)", "relay_migrator", @owner},
    {"relay_private.rl_ring_at(bigint, text, bigint, integer, integer)", "relay_migrator",
     @owner},
    {"relay_fn.rl_gcra(text, bigint, bigint, bigint, bigint, bigint, bigint, bigint)",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.rl_window(text, text, bigint, bigint, bigint, bigint)", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.rl_counter(text, bigint, text, bigint)", "relay_owner", ~w(relay_app)},
    {"relay_fn.rl_ring(text, bigint, integer, integer)", "relay_owner", ~w(relay_app)},
    {"relay_fn.cc_acquire(text, bigint, text, bigint)", "relay_owner", ~w(relay_app)},
    {"relay_fn.cc_release(text, text)", "relay_owner", ~w(relay_app)}
  ]

  # T-11
  # T-19
  # T-20 (1)
  # T-22
  # T-27
  # TN-43
  # INV-44
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
    helpers() ++ limiters() ++ wrappers() ++ concurrency()
  end

  defp helpers do
    [
      ~S"""
      CREATE FUNCTION relay_private.rl_fdiv(p_a bigint, p_b bigint) RETURNS bigint
      LANGUAGE sql IMMUTABLE
      SET search_path = pg_catalog, pg_temp
      AS $fn$
        SELECT CASE WHEN p_a >= 0 THEN p_a / p_b ELSE -((-p_a + p_b - 1) / p_b) END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.rl_cdiv(p_a bigint, p_b bigint) RETURNS bigint
      LANGUAGE sql IMMUTABLE
      SET search_path = pg_catalog, pg_temp
      AS $fn$
        SELECT CASE WHEN p_a > 0 THEN (p_a + p_b - 1) / p_b ELSE -((-p_a) / p_b) END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.rl_cur(p_stored_w bigint, p_cur bigint, p_w bigint)
        RETURNS bigint
      LANGUAGE sql IMMUTABLE
      SET search_path = pg_catalog, pg_temp
      AS $fn$
        SELECT CASE WHEN p_stored_w >= p_w THEN p_cur ELSE 0 END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.rl_prev(p_stored_w bigint, p_cur bigint, p_prev bigint,
        p_w bigint) RETURNS bigint
      LANGUAGE sql IMMUTABLE
      SET search_path = pg_catalog, pg_temp
      AS $fn$
        SELECT CASE
          WHEN p_stored_w >= p_w THEN p_prev
          WHEN p_stored_w = p_w - 1 THEN p_cur
          ELSE 0
        END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.rl_estimate(p_stored_w bigint, p_cur bigint, p_prev bigint,
        p_w bigint, p_pos bigint, p_period bigint) RETURNS bigint
      LANGUAGE sql IMMUTABLE
      SET search_path = pg_catalog, pg_temp
      AS $fn$
        SELECT CASE
          WHEN p_stored_w IS NULL THEN 0
          WHEN p_stored_w > p_w THEN p_prev + p_cur
          WHEN p_stored_w = p_w
            THEN relay_private.rl_cdiv(p_prev * (p_period - p_pos), p_period) + p_cur
          WHEN p_stored_w = p_w - 1
            THEN relay_private.rl_cdiv(p_cur * (p_period - p_pos), p_period)
          ELSE 0
        END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.rl_expires(p_now_us bigint, p_ttl_ms bigint) RETURNS timestamptz
      LANGUAGE sql IMMUTABLE
      SET search_path = pg_catalog, pg_temp
      AS $fn$
        SELECT 'epoch'::timestamptz + make_interval(secs => (p_now_us + p_ttl_ms * 1000) / 1000000.0)
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.rl_log_trim(p_log bigint[], p_now_us bigint, p_window_us bigint)
        RETURNS bigint[]
      LANGUAGE sql IMMUTABLE
      SET search_path = pg_catalog, pg_temp
      AS $fn$
        SELECT COALESCE(array_agg(x ORDER BY x), ARRAY[]::bigint[])
        FROM unnest(p_log) AS x WHERE x > p_now_us - p_window_us
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.rl_ring_shift(p_buckets bigint[], p_start bigint, p_minute bigint)
        RETURNS bigint[]
      LANGUAGE sql IMMUTABLE
      SET search_path = pg_catalog, pg_temp
      AS $fn$
        SELECT array_agg(
          CASE WHEN i + d BETWEEN 1 AND 120 THEN COALESCE(p_buckets[(i + d)::integer], 0) ELSE 0 END
          ORDER BY i)
        FROM generate_series(1, 120) AS i,
          LATERAL (SELECT GREATEST(p_minute, p_start + 119) - 119 - p_start AS d) AS s
      $fn$
      """
    ]
  end

  defp limiters do
    [gcra_at(), window_at(), counter_at(), ring_at()]
  end

  defp gcra_at do
    ~S"""
    CREATE FUNCTION relay_private.rl_gcra_at(p_now_us bigint, p_limit_key text, p_emission_us bigint,
      p_burst bigint, p_cost bigint, p_cap bigint, p_limit bigint, p_period_us bigint,
      p_offset_us bigint)
      RETURNS TABLE (result text, retry_after_us bigint, tat_us bigint, now_us bigint)
    LANGUAGE plpgsql VOLATILE
    SET search_path = pg_catalog, pg_temp
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_t uuid := relay_private.ctx_tenant_id();
      v_e relay.environment := relay_private.ctx_environment();
      v_w bigint;
      v_pos bigint;
      v_new bigint;
      v_algorithm text;
      v_tat bigint;
      v_win bigint;
      v_cur bigint;
      v_prev bigint;
      v_tat1 bigint;
      v_est bigint;
    BEGIN
      IF p_now_us IS NULL OR p_limit_key IS NULL OR p_emission_us IS NULL OR p_emission_us < 1
        OR p_burst IS NULL OR p_burst < 1 OR p_cost IS NULL OR p_cost < 1 OR p_cap IS NULL
        OR p_cap < -1 OR p_limit IS NULL OR p_limit < 1 OR p_period_us IS NULL OR p_period_us < 1
        OR p_offset_us IS NULL OR p_offset_us < 0 THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'T-19';
      END IF;
      v_w := relay_private.rl_fdiv(p_now_us + p_offset_us, p_period_us);
      v_pos := p_now_us + p_offset_us - v_w * p_period_us;

      WITH up AS (
        INSERT INTO relay_queue.limiter_states AS s (tenant_id, environment, limit_key, algorithm,
          tat_us, win_index, cur_count, prev_count, expires_at, updated_at)
        SELECT v_t, v_e, p_limit_key, 'gcra', p_now_us + p_cost * p_emission_us, v_w, p_cost, 0,
          relay_private.rl_expires(p_now_us, GREATEST(relay_private.rl_cdiv(p_cost * p_emission_us, 1000),
            CASE WHEN p_cap >= 0 THEN 2 * relay_private.rl_cdiv(p_period_us, 1000) ELSE 0 END) + 1000),
          clock_timestamp()
        WHERE p_cost <= p_burst AND (p_cap < 0 OR p_cost <= p_cap)
        ON CONFLICT (tenant_id, environment, limit_key) DO UPDATE SET
          tat_us = GREATEST(s.tat_us, p_now_us) + p_cost * p_emission_us,
          win_index = GREATEST(s.win_index, v_w),
          cur_count = relay_private.rl_cur(s.win_index, s.cur_count, v_w) + p_cost,
          prev_count = relay_private.rl_prev(s.win_index, s.cur_count, s.prev_count, v_w),
          expires_at = relay_private.rl_expires(p_now_us, GREATEST(
            relay_private.rl_cdiv(GREATEST(s.tat_us, p_now_us) + p_cost * p_emission_us - p_now_us, 1000),
            CASE WHEN p_cap >= 0 THEN 2 * relay_private.rl_cdiv(p_period_us, 1000) ELSE 0 END) + 1000),
          updated_at = clock_timestamp()
        WHERE s.algorithm = 'gcra'
          AND GREATEST(s.tat_us, p_now_us) + p_cost * p_emission_us - p_now_us <= p_burst * p_emission_us
          AND (p_cap < 0 OR relay_private.rl_estimate(s.win_index, s.cur_count, s.prev_count, v_w,
            v_pos, p_period_us) + p_cost <= p_cap)
        RETURNING s.tat_us
      ), old AS (
        SELECT o.algorithm, o.tat_us, o.win_index, o.cur_count, o.prev_count
        FROM relay_queue.limiter_states o
        WHERE o.tenant_id = v_t AND o.environment = v_e AND o.limit_key = p_limit_key
      )
      SELECT (SELECT u.tat_us FROM up u), o.algorithm, o.tat_us, o.win_index, o.cur_count,
        o.prev_count
      INTO v_new, v_algorithm, v_tat, v_win, v_cur, v_prev
      FROM (SELECT 1) AS one LEFT JOIN old o ON true;

      IF v_new IS NOT NULL THEN
        RETURN QUERY SELECT 'allowed'::text, 0::bigint, v_new, p_now_us;
        RETURN;
      END IF;
      IF v_algorithm IS NOT NULL AND v_algorithm <> 'gcra' THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'T-19';
      END IF;
      v_tat := COALESCE(v_tat, p_now_us);
      IF p_cost > p_burst THEN
        RETURN QUERY SELECT 'cost_exceeds_burst'::text, 0::bigint, v_tat, p_now_us;
        RETURN;
      END IF;
      v_tat1 := GREATEST(v_tat, p_now_us) + p_cost * p_emission_us;
      IF v_tat1 - p_now_us > p_burst * p_emission_us THEN
        RETURN QUERY SELECT 'limited'::text, v_tat1 - p_now_us - p_burst * p_emission_us, v_tat,
          p_now_us;
        RETURN;
      END IF;
      IF p_cap >= 0 THEN
        v_est := relay_private.rl_estimate(v_win, v_cur, v_prev, v_w, v_pos, p_period_us);
        IF v_est + p_cost > p_cap THEN
          RETURN QUERY SELECT 'ceiling'::text, GREATEST(p_emission_us,
            relay_private.rl_cdiv((v_est + p_cost - p_cap) * p_period_us, p_limit)), v_tat, p_now_us;
          RETURN;
        END IF;
      END IF;
      RETURN QUERY SELECT 'limited'::text, 1::bigint, v_tat, p_now_us;
    END
    $fn$
    """
  end

  defp window_at do
    ~S"""
    CREATE FUNCTION relay_private.rl_window_at(p_now_us bigint, p_limit_key text, p_algorithm text,
      p_limit bigint, p_window_ms bigint, p_offset_ms bigint, p_cost bigint)
      RETURNS TABLE (result text, count_after bigint, retry_after_ms bigint)
    LANGUAGE plpgsql VOLATILE
    SET search_path = pg_catalog, pg_temp
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_t uuid := relay_private.ctx_tenant_id();
      v_e relay.environment := relay_private.ctx_environment();
      v_window bigint;
      v_offset bigint;
      v_w bigint;
      v_pos bigint;
      v_eff bigint;
      v_new bigint;
      v_algorithm text;
      v_win bigint;
      v_cur bigint;
      v_prev bigint;
      v_log bigint[];
      v_count bigint;
      v_est bigint;
      v_end bigint;
    BEGIN
      IF p_now_us IS NULL OR p_limit_key IS NULL
        OR p_algorithm IS NULL OR p_algorithm NOT IN ('fixed_window', 'sliding_counter', 'sliding_log')
        OR p_limit IS NULL OR p_limit < 1 OR p_window_ms IS NULL OR p_window_ms < 1
        OR p_offset_ms IS NULL OR p_offset_ms < 0 OR p_cost IS NULL OR p_cost < 1
        OR (p_algorithm = 'sliding_log' AND p_limit > 1000) THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'T-19';
      END IF;
      v_window := p_window_ms * 1000;
      v_offset := p_offset_ms * 1000;
      v_w := relay_private.rl_fdiv(p_now_us + v_offset, v_window);
      v_pos := p_now_us + v_offset - v_w * v_window;
      v_eff := (9 * p_limit) / 10;

      IF p_algorithm = 'fixed_window' THEN
        WITH up AS (
          INSERT INTO relay_queue.limiter_states AS s (tenant_id, environment, limit_key, algorithm,
            win_index, cur_count, prev_count, expires_at, updated_at)
          SELECT v_t, v_e, p_limit_key, 'fixed_window', v_w, p_cost, 0,
            relay_private.rl_expires(p_now_us,
              relay_private.rl_cdiv((v_w + 1) * v_window - v_offset - p_now_us, 1000) + 1000),
            clock_timestamp()
          WHERE p_cost <= p_limit
          ON CONFLICT (tenant_id, environment, limit_key) DO UPDATE SET
            win_index = GREATEST(s.win_index, v_w),
            cur_count = relay_private.rl_cur(s.win_index, s.cur_count, v_w) + p_cost,
            prev_count = 0,
            expires_at = relay_private.rl_expires(p_now_us, relay_private.rl_cdiv(
              (GREATEST(s.win_index, v_w) + 1) * v_window - v_offset - p_now_us, 1000) + 1000),
            updated_at = clock_timestamp()
          WHERE s.algorithm = 'fixed_window'
            AND relay_private.rl_cur(s.win_index, s.cur_count, v_w) + p_cost <= p_limit
          RETURNING s.cur_count
        ), old AS (
          SELECT o.algorithm, o.win_index, o.cur_count FROM relay_queue.limiter_states o
          WHERE o.tenant_id = v_t AND o.environment = v_e AND o.limit_key = p_limit_key
        )
        SELECT (SELECT u.cur_count FROM up u), o.algorithm, o.win_index, o.cur_count
        INTO v_new, v_algorithm, v_win, v_cur
        FROM (SELECT 1) AS one LEFT JOIN old o ON true;

        IF v_new IS NOT NULL THEN
          RETURN QUERY SELECT 'allowed'::text, v_new, 0::bigint;
          RETURN;
        END IF;
        IF v_algorithm IS NOT NULL AND v_algorithm <> p_algorithm THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'T-19';
        END IF;
        v_end := (GREATEST(COALESCE(v_win, v_w), v_w) + 1) * v_window - v_offset;
        RETURN QUERY SELECT 'limited'::text, COALESCE(relay_private.rl_cur(v_win, v_cur, v_w), 0),
          relay_private.rl_cdiv(v_end - p_now_us, 1000);
        RETURN;
      END IF;

      IF p_algorithm = 'sliding_counter' THEN
        WITH up AS (
          INSERT INTO relay_queue.limiter_states AS s (tenant_id, environment, limit_key, algorithm,
            win_index, cur_count, prev_count, expires_at, updated_at)
          SELECT v_t, v_e, p_limit_key, 'sliding_counter', v_w, p_cost, 0,
            relay_private.rl_expires(p_now_us, 2 * p_window_ms + 1000), clock_timestamp()
          WHERE p_cost <= v_eff
          ON CONFLICT (tenant_id, environment, limit_key) DO UPDATE SET
            win_index = GREATEST(s.win_index, v_w),
            cur_count = relay_private.rl_cur(s.win_index, s.cur_count, v_w) + p_cost,
            prev_count = relay_private.rl_prev(s.win_index, s.cur_count, s.prev_count, v_w),
            expires_at = relay_private.rl_expires(p_now_us, 2 * p_window_ms + 1000),
            updated_at = clock_timestamp()
          WHERE s.algorithm = 'sliding_counter'
            AND relay_private.rl_estimate(s.win_index, s.cur_count, s.prev_count, v_w, v_pos, v_window)
              + p_cost <= v_eff
          RETURNING relay_private.rl_estimate(s.win_index, s.cur_count, s.prev_count, v_w, v_pos,
            v_window) AS estimate
        ), old AS (
          SELECT o.algorithm, o.win_index, o.cur_count, o.prev_count FROM relay_queue.limiter_states o
          WHERE o.tenant_id = v_t AND o.environment = v_e AND o.limit_key = p_limit_key
        )
        SELECT (SELECT u.estimate FROM up u), o.algorithm, o.win_index, o.cur_count, o.prev_count
        INTO v_new, v_algorithm, v_win, v_cur, v_prev
        FROM (SELECT 1) AS one LEFT JOIN old o ON true;

        IF v_new IS NOT NULL THEN
          RETURN QUERY SELECT 'allowed'::text, v_new, 0::bigint;
          RETURN;
        END IF;
        IF v_algorithm IS NOT NULL AND v_algorithm <> p_algorithm THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'T-19';
        END IF;
        v_est := relay_private.rl_estimate(v_win, v_cur, v_prev, v_w, v_pos, v_window);
        v_prev := COALESCE(relay_private.rl_prev(v_win, v_cur, v_prev, v_w), 0);
        v_cur := COALESCE(relay_private.rl_cur(v_win, v_cur, v_w), 0);
        v_w := GREATEST(COALESCE(v_win, v_w), v_w);
        IF v_cur + p_cost > v_eff THEN
          v_end := (v_w + 1) * v_window - v_offset;
        ELSIF v_prev <= 0 OR v_est + p_cost <= v_eff THEN
          v_end := p_now_us + 1;
        ELSE
          v_end := v_w * v_window - v_offset + v_window
            - relay_private.rl_fdiv((v_eff - v_cur - p_cost) * v_window, v_prev);
        END IF;
        RETURN QUERY SELECT 'limited'::text, v_est, relay_private.rl_cdiv(v_end - p_now_us, 1000);
        RETURN;
      END IF;

      WITH up AS (
        INSERT INTO relay_queue.limiter_states AS s (tenant_id, environment, limit_key, algorithm,
          log_us, expires_at, updated_at)
        SELECT v_t, v_e, p_limit_key, 'sliding_log', array_fill(p_now_us, ARRAY[p_cost]::integer[]),
          relay_private.rl_expires(p_now_us, p_window_ms + 1000), clock_timestamp()
        WHERE p_cost <= p_limit
        ON CONFLICT (tenant_id, environment, limit_key) DO UPDATE SET
          log_us = ARRAY(SELECT x FROM unnest(relay_private.rl_log_trim(s.log_us, p_now_us, v_window)
            || array_fill(p_now_us, ARRAY[p_cost]::integer[])) AS x ORDER BY x),
          expires_at = relay_private.rl_expires(p_now_us, p_window_ms + 1000),
          updated_at = clock_timestamp()
        WHERE s.algorithm = 'sliding_log'
          AND cardinality(relay_private.rl_log_trim(s.log_us, p_now_us, v_window)) + p_cost <= p_limit
        RETURNING cardinality(s.log_us)::bigint AS n
      ), old AS (
        SELECT o.algorithm, o.log_us FROM relay_queue.limiter_states o
        WHERE o.tenant_id = v_t AND o.environment = v_e AND o.limit_key = p_limit_key
      )
      SELECT (SELECT u.n FROM up u), o.algorithm, o.log_us
      INTO v_new, v_algorithm, v_log
      FROM (SELECT 1) AS one LEFT JOIN old o ON true;

      IF v_new IS NOT NULL THEN
        RETURN QUERY SELECT 'allowed'::text, v_new, 0::bigint;
        RETURN;
      END IF;
      IF v_algorithm IS NOT NULL AND v_algorithm <> p_algorithm THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'T-19';
      END IF;
      v_log := relay_private.rl_log_trim(COALESCE(v_log, ARRAY[]::bigint[]), p_now_us, v_window);
      v_count := cardinality(v_log);
      IF p_cost > p_limit THEN
        RETURN QUERY SELECT 'limited'::text, v_count, relay_private.rl_cdiv(v_window, 1000);
        RETURN;
      END IF;
      RETURN QUERY SELECT 'limited'::text, v_count, GREATEST(1, COALESCE(relay_private.rl_cdiv(
        v_log[(v_count + p_cost - p_limit)::integer] + v_window - p_now_us, 1000), 1));
    END
    $fn$
    """
  end

  defp counter_at do
    ~S"""
    CREATE FUNCTION relay_private.rl_counter_at(p_now_us bigint, p_limit_key text, p_window_ms bigint,
      p_op text, p_by bigint)
      RETURNS TABLE (estimate bigint)
    LANGUAGE plpgsql VOLATILE
    SET search_path = pg_catalog, pg_temp
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_t uuid := relay_private.ctx_tenant_id();
      v_e relay.environment := relay_private.ctx_environment();
      v_window bigint;
      v_w bigint;
      v_pos bigint;
      v_algorithm text;
      v_win bigint;
      v_cur bigint;
      v_prev bigint;
      v_est bigint;
    BEGIN
      IF p_now_us IS NULL OR p_limit_key IS NULL OR p_window_ms IS NULL OR p_window_ms < 1
        OR p_op IS NULL OR p_op NOT IN ('incr', 'read') OR p_by IS NULL OR p_by < 0 THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'T-27';
      END IF;
      v_window := p_window_ms * 1000;
      v_w := relay_private.rl_fdiv(p_now_us, v_window);
      v_pos := p_now_us - v_w * v_window;

      IF p_op = 'read' THEN
        SELECT o.algorithm, o.win_index, o.cur_count, o.prev_count
        INTO v_algorithm, v_win, v_cur, v_prev
        FROM relay_queue.limiter_states o
        WHERE o.tenant_id = v_t AND o.environment = v_e AND o.limit_key = p_limit_key;
        IF v_algorithm IS NOT NULL AND v_algorithm <> 'sliding_counter' THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'T-27';
        END IF;
        RETURN QUERY SELECT COALESCE(relay_private.rl_estimate(v_win, v_cur, v_prev, v_w, v_pos,
          v_window), 0);
        RETURN;
      END IF;

      INSERT INTO relay_queue.limiter_states AS s (tenant_id, environment, limit_key, algorithm,
        win_index, cur_count, prev_count, expires_at, updated_at)
      VALUES (v_t, v_e, p_limit_key, 'sliding_counter', v_w, p_by, 0,
        relay_private.rl_expires(p_now_us, 2 * p_window_ms + 1000), clock_timestamp())
      ON CONFLICT (tenant_id, environment, limit_key) DO UPDATE SET
        win_index = GREATEST(s.win_index, v_w),
        cur_count = relay_private.rl_cur(s.win_index, s.cur_count, v_w) + p_by,
        prev_count = relay_private.rl_prev(s.win_index, s.cur_count, s.prev_count, v_w),
        expires_at = relay_private.rl_expires(p_now_us, 2 * p_window_ms + 1000),
        updated_at = clock_timestamp()
      WHERE s.algorithm = 'sliding_counter'
      RETURNING relay_private.rl_estimate(s.win_index, s.cur_count, s.prev_count, v_w, v_pos,
        v_window)
      INTO v_est;
      IF v_est IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'T-27';
      END IF;
      RETURN QUERY SELECT v_est;
    END
    $fn$
    """
  end

  defp ring_at do
    ~S"""
    CREATE FUNCTION relay_private.rl_ring_at(p_now_us bigint, p_limit_key text, p_cost bigint,
      p_current_minutes integer, p_baseline_minutes integer)
      RETURNS TABLE (current_sum bigint, baseline_sum bigint)
    LANGUAGE plpgsql VOLATILE
    SET search_path = pg_catalog, pg_temp
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_t uuid := relay_private.ctx_tenant_id();
      v_e relay.environment := relay_private.ctx_environment();
      v_minute bigint;
      v_buckets bigint[];
    BEGIN
      IF p_now_us IS NULL OR p_limit_key IS NULL OR p_cost IS NULL OR p_cost < 0
        OR p_current_minutes IS NULL OR p_current_minutes < 1 OR p_baseline_minutes IS NULL
        OR p_baseline_minutes < 0 OR p_current_minutes + p_baseline_minutes > 120 THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-43';
      END IF;
      v_minute := relay_private.rl_fdiv(p_now_us, 60000000);

      INSERT INTO relay_queue.limiter_states AS s (tenant_id, environment, limit_key, algorithm,
        win_index, buckets, expires_at, updated_at)
      VALUES (v_t, v_e, p_limit_key, 'bucket_ring', v_minute - 119,
        array_fill(0::bigint, ARRAY[119]) || p_cost,
        relay_private.rl_expires(p_now_us, 7200000), clock_timestamp())
      ON CONFLICT (tenant_id, environment, limit_key) DO UPDATE SET
        buckets = (SELECT b[1:119] || (b[120] + p_cost)
          FROM (SELECT relay_private.rl_ring_shift(s.buckets, s.win_index, v_minute) AS b) AS r),
        win_index = GREATEST(s.win_index, v_minute - 119),
        expires_at = relay_private.rl_expires(p_now_us, 7200000),
        updated_at = clock_timestamp()
      WHERE s.algorithm = 'bucket_ring'
      RETURNING s.buckets INTO v_buckets;
      IF v_buckets IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-43';
      END IF;
      RETURN QUERY SELECT
        (SELECT COALESCE(sum(x), 0)::bigint FROM unnest(v_buckets[121 - p_current_minutes:120]) AS x),
        (SELECT COALESCE(sum(x), 0)::bigint
          FROM unnest(v_buckets[121 - p_current_minutes - p_baseline_minutes:120 - p_current_minutes]) AS x);
    END
    $fn$
    """
  end

  defp wrappers do
    [
      ~S"""
      CREATE FUNCTION relay_fn.rl_gcra(p_limit_key text, p_emission_us bigint, p_burst bigint,
        p_cost bigint, p_cap bigint, p_limit bigint, p_period_us bigint, p_offset_us bigint)
        RETURNS TABLE (result text, retry_after_us bigint, tat_us bigint, now_us bigint)
      LANGUAGE sql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT * FROM relay_private.rl_gcra_at(
          (extract(epoch FROM clock_timestamp()) * 1000000)::bigint, p_limit_key, p_emission_us,
          p_burst, p_cost, p_cap, p_limit, p_period_us, p_offset_us)
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.rl_window(p_limit_key text, p_algorithm text, p_limit bigint,
        p_window_ms bigint, p_offset_ms bigint, p_cost bigint)
        RETURNS TABLE (result text, count_after bigint, retry_after_ms bigint)
      LANGUAGE sql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT * FROM relay_private.rl_window_at(
          (extract(epoch FROM clock_timestamp()) * 1000000)::bigint, p_limit_key, p_algorithm,
          p_limit, p_window_ms, p_offset_ms, p_cost)
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.rl_counter(p_limit_key text, p_window_ms bigint, p_op text,
        p_by bigint)
        RETURNS TABLE (estimate bigint)
      LANGUAGE sql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT * FROM relay_private.rl_counter_at(
          (extract(epoch FROM clock_timestamp()) * 1000000)::bigint, p_limit_key, p_window_ms,
          p_op, p_by)
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.rl_ring(p_limit_key text, p_cost bigint, p_current_minutes integer,
        p_baseline_minutes integer)
        RETURNS TABLE (current_sum bigint, baseline_sum bigint)
      LANGUAGE sql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT * FROM relay_private.rl_ring_at(
          (extract(epoch FROM clock_timestamp()) * 1000000)::bigint, p_limit_key, p_cost,
          p_current_minutes, p_baseline_minutes)
      $fn$
      """
    ]
  end

  defp concurrency do
    [
      ~S"""
      CREATE FUNCTION relay_fn.cc_acquire(p_counter_key text, p_limit bigint, p_holder text,
        p_lease_ms bigint)
        RETURNS TABLE (result text, in_use bigint, wait_ms bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_t uuid := relay_private.ctx_tenant_id();
        v_e relay.environment := relay_private.ctx_environment();
        v_now timestamptz := clock_timestamp();
        v_until timestamptz;
        v_slot bigint;
        v_result text;
        v_in_use bigint;
        v_wait bigint;
      BEGIN
        IF p_counter_key IS NULL OR p_limit IS NULL OR p_limit < 1 OR p_holder IS NULL
          OR char_length(p_holder) NOT BETWEEN 1 AND 128 OR p_lease_ms IS NULL OR p_lease_ms < 1 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'T-22';
        END IF;
        v_until := v_now + make_interval(secs => p_lease_ms / 1000.0);

        UPDATE relay_queue.concurrency_slots s
        SET lease_until = v_until, expires_at = v_until + interval '1 day', updated_at = v_now
        WHERE (s.tenant_id, s.environment, s.counter_key, s.slot_no) = (
          SELECT h.tenant_id, h.environment, h.counter_key, h.slot_no
          FROM relay_queue.concurrency_slots h
          WHERE h.tenant_id = v_t AND h.environment = v_e AND h.counter_key = p_counter_key
            AND h.holder = p_holder AND h.slot_no <= p_limit
          ORDER BY h.slot_no LIMIT 1)
        RETURNING s.slot_no INTO v_slot;

        IF v_slot IS NOT NULL THEN
          v_result := 'renewed';
        ELSE
          IF NOT EXISTS (
            SELECT 1 FROM relay_queue.concurrency_slots x
            WHERE x.tenant_id = v_t AND x.environment = v_e AND x.counter_key = p_counter_key
              AND x.slot_no = p_limit) THEN
            INSERT INTO relay_queue.concurrency_slots (tenant_id, environment, counter_key, slot_no,
              holder, lease_until, expires_at, updated_at)
            SELECT v_t, v_e, p_counter_key, g, NULL, NULL, v_now + interval '1 day', v_now
            FROM generate_series(1::bigint, p_limit) AS g
            ON CONFLICT (tenant_id, environment, counter_key, slot_no) DO NOTHING;
          END IF;

          SELECT f.slot_no INTO v_slot FROM relay_queue.concurrency_slots f
          WHERE f.tenant_id = v_t AND f.environment = v_e AND f.counter_key = p_counter_key
            AND f.slot_no <= p_limit AND (f.holder IS NULL OR f.lease_until < v_now)
          ORDER BY f.slot_no LIMIT 1 FOR UPDATE SKIP LOCKED;

          IF v_slot IS NOT NULL THEN
            UPDATE relay_queue.concurrency_slots s
            SET holder = p_holder, lease_until = v_until, expires_at = v_until + interval '1 day',
              updated_at = v_now
            WHERE s.tenant_id = v_t AND s.environment = v_e AND s.counter_key = p_counter_key
              AND s.slot_no = v_slot;
            v_result := 'granted';
          ELSE
            v_result := 'full';
          END IF;
        END IF;

        SELECT count(*) FILTER (WHERE c.holder IS NOT NULL AND c.lease_until >= v_now),
          COALESCE(GREATEST(0, ceil(extract(epoch FROM min(c.lease_until) - v_now) * 1000)), 0)::bigint
        INTO v_in_use, v_wait
        FROM relay_queue.concurrency_slots c
        WHERE c.tenant_id = v_t AND c.environment = v_e AND c.counter_key = p_counter_key
          AND c.slot_no <= p_limit;

        RETURN QUERY SELECT v_result, v_in_use,
          CASE WHEN v_result = 'full' THEN v_wait ELSE 0::bigint END;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.cc_release(p_counter_key text, p_holder text) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_now timestamptz := clock_timestamp();
      BEGIN
        IF p_counter_key IS NULL OR p_holder IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'T-22';
        END IF;
        UPDATE relay_queue.concurrency_slots s
        SET holder = NULL, lease_until = NULL, expires_at = v_now + interval '1 day', updated_at = v_now
        WHERE s.tenant_id = relay_private.ctx_tenant_id()
          AND s.environment = relay_private.ctx_environment()
          AND s.counter_key = p_counter_key AND s.holder = p_holder;
        IF FOUND THEN
          RETURN 'released';
        END IF;
        RETURN 'not_held';
      END
      $fn$
      """
    ]
  end
end
