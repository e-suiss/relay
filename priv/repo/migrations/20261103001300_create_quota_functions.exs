defmodule Relay.Repo.Migrations.CreateQuotaFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"

  @functions [
    {"relay_fn.quota_consume(text, bigint, smallint)", ~w(relay_app)},
    {"relay_fn.quota_policy_set(text, bigint, jsonb, smallint, bigint, bytea, #{@actor})",
     ~w(relay_app)},
    {"relay_fn.quota_usage(text)", ~w(relay_app relay_report)}
  ]

  # API-51
  # API-79 (1)
  # TN-52
  # OP-8
  def up do
    Enum.each(statements(), &execute/1)

    for {signature, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      execute("ALTER FUNCTION #{signature} OWNER TO relay_owner")
    end
  end

  def down do
    for {signature, _grantees} <- Enum.reverse(@functions),
        do: execute("DROP FUNCTION #{signature}")
  end

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_fn.quota_consume(p_message_class text, p_count bigint,
        p_shard smallint)
        RETURNS TABLE (result text, period text, limit_total bigint, used bigint, marks text[])
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_policy relay.quota_policies;
        v_start timestamptz;
        v_used bigint;
        v_reserve_used bigint;
        v_class_used bigint;
        v_cap bigint;
        v_reserve_limit bigint;
        v_marks text[];
        v_result text;
        v_in_reserve boolean;
        v_mark text;
        v_any boolean := false;
      BEGIN
        IF p_message_class IS NULL OR p_count IS NULL OR p_count < 1 OR p_shard IS NULL
          OR p_shard NOT BETWEEN 0 AND 15 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-52';
        END IF;
        FOR v_policy IN
          SELECT * FROM relay.quota_policies q
          WHERE q.tenant_id = v_tenant AND q.environment = v_env AND q.state = 'active'
          ORDER BY q.period
        LOOP
          v_any := true;
          v_marks := ARRAY[]::text[];
          v_start := date_trunc(v_policy.period, now());
          SELECT COALESCE(sum(c.used) FILTER (WHERE NOT c.in_reserve), 0),
            COALESCE(sum(c.used) FILTER (WHERE c.in_reserve), 0),
            COALESCE(sum(c.used) FILTER (WHERE NOT c.in_reserve
              AND c.message_class = p_message_class), 0)
            INTO v_used, v_reserve_used, v_class_used
            FROM relay.quota_counters c
            WHERE c.tenant_id = v_tenant AND c.environment = v_env
              AND c.period = v_policy.period AND c.period_start = v_start;
          v_cap := (v_policy.class_caps ->> p_message_class)::bigint;
          v_reserve_limit := v_policy.limit_total * v_policy.security_reserve_bp / 10000;
          v_in_reserve := false;
          IF v_cap IS NOT NULL
            AND v_class_used + p_count > v_policy.limit_total * v_cap / 10000 THEN
            v_result := 'class_cap';
          ELSIF v_used + p_count <= v_policy.limit_total THEN
            v_result := 'allowed';
            IF v_used * 10 < v_policy.limit_total * 8
              AND (v_used + p_count) * 10 >= v_policy.limit_total * 8 THEN
              v_marks := v_marks || 'p80'::text;
            END IF;
            IF v_used < v_policy.limit_total AND v_used + p_count >= v_policy.limit_total THEN
              v_marks := v_marks || 'p100'::text;
            END IF;
          ELSIF p_message_class = 'security'
            AND v_reserve_used + p_count <= v_reserve_limit THEN
            v_result := 'reserve';
            v_in_reserve := true;
            v_marks := ARRAY['reserve'];
          ELSE
            v_result := 'exhausted';
          END IF;
          IF v_result IN ('allowed', 'reserve') THEN
            INSERT INTO relay.quota_counters AS c (tenant_id, environment, period, period_start,
              message_class, in_reserve, shard, used, updated_at)
            VALUES (v_tenant, v_env, v_policy.period, v_start, p_message_class, v_in_reserve,
              p_shard, p_count, now())
            ON CONFLICT (tenant_id, environment, period, period_start, message_class, in_reserve,
              shard) DO UPDATE SET used = c.used + EXCLUDED.used, updated_at = now();
            FOREACH v_mark IN ARRAY v_marks LOOP
              INSERT INTO relay.quota_threshold_marks (tenant_id, environment, period,
                period_start, mark, created_at)
              VALUES (v_tenant, v_env, v_policy.period, v_start, v_mark, now())
              ON CONFLICT DO NOTHING;
              IF NOT FOUND THEN
                v_marks := array_remove(v_marks, v_mark);
              ELSIF v_mark = 'reserve' THEN
                PERFORM relay_fn.outbox_append(uuidv7(), 'quota.reserve_opened',
                  'quota:' || v_policy.period, jsonb_build_object('period', v_policy.period,
                    'period_start', v_start, 'reserve_limit', v_reserve_limit), NULL);
              ELSE
                PERFORM relay_fn.outbox_append(uuidv7(), 'quota.threshold_reached',
                  'quota:' || v_policy.period, jsonb_build_object('bucket', 'general',
                    'period', v_policy.period, 'period_start', v_start,
                    'threshold_percent', CASE v_mark WHEN 'p80' THEN 80 ELSE 100 END,
                    'limit', v_policy.limit_total, 'used', v_used + p_count), NULL);
              END IF;
            END LOOP;
          ELSE
            v_marks := ARRAY[]::text[];
          END IF;
          RETURN QUERY SELECT v_result, v_policy.period,
            CASE WHEN v_in_reserve THEN v_reserve_limit ELSE v_policy.limit_total END,
            CASE WHEN v_in_reserve THEN v_reserve_used + p_count
              WHEN v_result IN ('allowed') THEN v_used + p_count
              WHEN v_result = 'class_cap' THEN v_class_used ELSE v_used END,
            v_marks;
        END LOOP;
        IF NOT v_any THEN
          RETURN QUERY SELECT 'no_policy'::text, NULL::text, NULL::bigint, NULL::bigint,
            ARRAY[]::text[];
        END IF;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.quota_policy_set(p_period text, p_limit_total bigint,
        p_class_caps jsonb, p_security_reserve_bp smallint, p_expected_version bigint,
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text)
        RETURNS TABLE (result text, version bigint, relaxed boolean)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_policy relay.quota_policies;
        v_caps jsonb := COALESCE(p_class_caps, '{}'::jsonb);
        v_reserve smallint := COALESCE(p_security_reserve_bp, 1000);
        v_relaxed boolean;
        v_version bigint;
      BEGIN
        IF p_period IS NULL OR p_period NOT IN ('day', 'month') OR p_actor_ref IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-52';
        END IF;
        IF jsonb_typeof(v_caps) <> 'object' OR EXISTS (SELECT 1 FROM jsonb_each(v_caps) AS x(k, v)
          WHERE x.k NOT IN ('security', 'transactional', 'operational', 'social', 'marketing',
            'system', 'action_required')
            OR CASE WHEN jsonb_typeof(x.v) = 'number' AND x.v::text ~ '^[0-9]{1,5}$'
              THEN x.v::text::bigint NOT BETWEEN 1 AND 10000 ELSE true END) THEN
          RETURN QUERY SELECT 'invalid_caps'::text, NULL::bigint, false;
          RETURN;
        END IF;
        SELECT * INTO v_policy FROM relay.quota_policies q
          WHERE q.tenant_id = v_tenant AND q.environment = v_env AND q.period = p_period
          FOR UPDATE;
        IF FOUND AND p_expected_version IS NOT NULL AND p_expected_version <> v_policy.version THEN
          RETURN QUERY SELECT 'version_conflict'::text, v_policy.version, false;
          RETURN;
        END IF;
        IF p_limit_total IS NULL THEN
          IF NOT FOUND OR v_policy.state = 'removed' THEN
            RETURN QUERY SELECT 'unchanged'::text, v_policy.version, false;
            RETURN;
          END IF;
          UPDATE relay.quota_policies q SET state = 'removed', version = q.version + 1,
              updated_by_ref = p_actor_ref, updated_at = now()
            WHERE q.tenant_id = v_tenant AND q.environment = v_env AND q.period = p_period
            RETURNING q.version INTO v_version;
          PERFORM relay_private.audit_write(v_tenant, v_env::text, 'quota_policy.changed',
            p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'quota_policy',
            p_period, 'removed', p_record_digest);
          RETURN QUERY SELECT 'removed'::text, v_version, true;
          RETURN;
        END IF;
        IF NOT FOUND THEN
          INSERT INTO relay.quota_policies (tenant_id, environment, period, limit_total,
            class_caps, security_reserve_bp, state, version, updated_by_ref, created_at,
            updated_at)
          VALUES (v_tenant, v_env, p_period, p_limit_total, v_caps, v_reserve, 'active', 1,
            p_actor_ref, now(), now());
          PERFORM relay_private.audit_write(v_tenant, v_env::text, 'quota_policy.changed',
            p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'quota_policy',
            p_period, 'created', p_record_digest);
          RETURN QUERY SELECT 'created'::text, 1::bigint, false;
          RETURN;
        END IF;
        IF v_policy.state = 'active' AND v_policy.limit_total = p_limit_total
          AND v_policy.class_caps = v_caps AND v_policy.security_reserve_bp = v_reserve THEN
          RETURN QUERY SELECT 'unchanged'::text, v_policy.version, false;
          RETURN;
        END IF;
        v_relaxed := v_policy.state = 'removed' OR p_limit_total > v_policy.limit_total
          OR v_reserve > v_policy.security_reserve_bp
          OR EXISTS (SELECT 1 FROM jsonb_each(v_policy.class_caps) AS o(k, v)
            WHERE NOT (v_caps ? o.k) OR (v_caps ->> o.k)::bigint > (o.v::text)::bigint);
        UPDATE relay.quota_policies q SET limit_total = p_limit_total, class_caps = v_caps,
            security_reserve_bp = v_reserve, state = 'active', version = q.version + 1,
            updated_by_ref = p_actor_ref, updated_at = now()
          WHERE q.tenant_id = v_tenant AND q.environment = v_env AND q.period = p_period
          RETURNING q.version INTO v_version;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'quota_policy.changed',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'quota_policy',
          p_period, 'updated', p_record_digest);
        RETURN QUERY SELECT 'updated'::text, v_version, v_relaxed;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.quota_usage(p_period text)
        RETURNS TABLE (period_start timestamptz, used bigint, reserve_used bigint, by_class jsonb)
      LANGUAGE sql STABLE SECURITY INVOKER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT date_trunc(p_period, now()),
          COALESCE(sum(c.used) FILTER (WHERE NOT c.in_reserve), 0)::bigint,
          COALESCE(sum(c.used) FILTER (WHERE c.in_reserve), 0)::bigint,
          COALESCE((SELECT jsonb_object_agg(x.message_class, x.used) FROM (
            SELECT k.message_class::text AS message_class, sum(k.used) AS used
            FROM relay.quota_counters k
            WHERE k.tenant_id = relay_private.ctx_tenant_id()
              AND k.environment = relay_private.ctx_environment()
              AND k.period = p_period AND k.period_start = date_trunc(p_period, now())
            GROUP BY k.message_class) x), '{}'::jsonb)
        FROM relay.quota_counters c
        WHERE c.tenant_id = relay_private.ctx_tenant_id()
          AND c.environment = relay_private.ctx_environment()
          AND c.period = p_period AND c.period_start = date_trunc(p_period, now())
      $fn$
      """
    ]
  end
end
