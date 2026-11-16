defmodule Relay.Repo.Migrations.CreateDigestAndThrottleFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"

  @functions [
    {"relay_fn.digest_item_add(uuid, uuid, uuid, bytea, text, text, text, bigint, bigint, text, text, timestamptz, bigint, bigint, uuid, uuid, bytea)",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.digest_window_plan(uuid, timestamptz)", "relay_owner", ~w(relay_app)},
    {"relay_fn.digest_window_fire(uuid)", "relay_owner", ~w(relay_app)},
    {"relay_fn.digest_read(uuid, uuid)", "relay_owner", ~w(relay_app)},
    {"relay_fn.digest_due(integer)", "relay_owner", ~w(relay_app)},
    {"relay_fn.throttle_hit(bytea, bytea, bigint, bigint, timestamptz, timestamptz)",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.throttle_reset(bytea, bytea, #{@actor})", "relay_owner", ~w(relay_app)},
    {"relay_fn.content_dedup_check(uuid, bigint)", "relay_owner", ~w(relay_app)},
    {"relay_ops.digest_due_scopes(integer)", "relay_maint", ~w(relay_worker)}
  ]

  # WF-26
  # WF-27
  # WF-29
  # WF-32
  # WF-35
  # WF-36
  # INV-3
  # INV-12
  # INV-32
  # OP-8
  def up do
    Enum.each(statements(), &execute/1)

    for {signature, owner, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      if owner == "relay_owner", do: execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
    end
  end

  def down, do: :ok

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_fn.digest_item_add(p_window_id uuid, p_item_id uuid,
        p_recipient_id uuid, p_window_key bytea, p_origin text, p_window_mode text,
        p_leading_mode text, p_debounce_ms bigint, p_max_wait_ms bigint, p_schedule_rule text,
        p_time_zone text, p_release_at timestamptz, p_max_items bigint, p_max_open_ms bigint,
        p_notification_id uuid, p_delivery_id uuid, p_actor_digest bytea)
        RETURNS TABLE (result text, window_id uuid, generation bigint, item_seq bigint,
          sent_alone boolean, item_count bigint, first_at timestamptz, last_at timestamptz)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_now timestamptz := relay_private.business_now();
        v_window relay.digest_windows;
        v_item relay.digest_items;
        v_generation bigint;
        v_seq bigint;
        v_alone boolean := false;
      BEGIN
        IF p_window_id IS NULL OR p_item_id IS NULL OR p_recipient_id IS NULL
          OR p_window_key IS NULL OR octet_length(p_window_key) <> 32
          OR p_notification_id IS NULL OR p_max_open_ms IS NULL
          OR p_max_open_ms NOT BETWEEN 1 AND 2678400000 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-27';
        END IF;
        PERFORM pg_advisory_xact_lock(hashtextextended(v_tenant::text || '/' || v_env::text
          || '/digest/' || p_recipient_id::text || '/' || encode(p_window_key, 'hex'), 0));
        SELECT i.* INTO v_item FROM relay.digest_items i
          JOIN relay.digest_windows w ON w.tenant_id = i.tenant_id
            AND w.environment = i.environment AND w.id = i.window_id
          WHERE i.tenant_id = v_tenant AND i.environment = v_env
            AND i.notification_id = p_notification_id AND i.recipient_id = p_recipient_id
            AND w.window_key = p_window_key
          LIMIT 1;
        IF FOUND THEN
          SELECT * INTO v_window FROM relay.digest_windows w
            WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = v_item.window_id;
          RETURN QUERY SELECT 'exists'::text, v_window.id, v_window.generation, v_item.seq,
            v_item.sent_alone, v_window.item_count, v_window.first_at, v_window.last_at;
          RETURN;
        END IF;
        SELECT * INTO v_window FROM relay.digest_windows w
          WHERE w.tenant_id = v_tenant AND w.environment = v_env
            AND w.recipient_id = p_recipient_id AND w.window_key = p_window_key
            AND w.state = 'open'
          FOR UPDATE;
        IF NOT FOUND THEN
          IF NOT EXISTS (SELECT 1 FROM relay.recipients r
            WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_recipient_id) THEN
            RETURN QUERY SELECT 'recipient_not_found'::text, NULL::uuid, NULL::bigint,
              NULL::bigint, NULL::boolean, NULL::bigint, NULL::timestamptz, NULL::timestamptz;
            RETURN;
          END IF;
          PERFORM relay_private.assert_new_id(p_window_id);
          SELECT COALESCE(max(w.generation), 0) + 1 INTO v_generation
            FROM relay.digest_windows w
            WHERE w.tenant_id = v_tenant AND w.environment = v_env
              AND w.recipient_id = p_recipient_id AND w.window_key = p_window_key;
          INSERT INTO relay.digest_windows (tenant_id, environment, id, recipient_id, window_key,
            generation, chain_start, origin, window_mode, leading_mode, debounce_ms, max_wait_ms,
            schedule_rule, time_zone, release_at, max_items, state, item_count,
            cumulative_count, first_at, last_at, deadline_at, fire_at, timer_at, closed_at,
            close_reason, read_at, created_at, updated_at)
          VALUES (v_tenant, v_env, p_window_id, p_recipient_id, p_window_key, v_generation, NULL,
            p_origin, p_window_mode, p_leading_mode, p_debounce_ms, p_max_wait_ms,
            p_schedule_rule, p_time_zone, p_release_at, p_max_items, 'open', 0, NULL, v_now,
            v_now, v_now + p_max_open_ms * interval '1 millisecond', NULL, NULL, NULL, NULL,
            NULL, now(), now())
          RETURNING * INTO v_window;
          v_alone := p_leading_mode = 'immediate';
        END IF;
        SELECT COALESCE(max(i.seq), 0) + 1 INTO v_seq FROM relay.digest_items i
          WHERE i.tenant_id = v_tenant AND i.environment = v_env AND i.window_id = v_window.id;
        INSERT INTO relay.digest_items (tenant_id, environment, id, window_id, recipient_id,
          notification_id, delivery_id, seq, sent_alone, actor_digest, occurred_at, created_at)
        VALUES (v_tenant, v_env, p_item_id, v_window.id, p_recipient_id, p_notification_id,
          p_delivery_id, v_seq, v_alone, p_actor_digest, v_now, now());
        UPDATE relay.digest_windows w
          SET item_count = w.item_count + CASE WHEN v_alone THEN 0 ELSE 1 END, last_at = v_now,
            updated_at = now()
          WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = v_window.id
          RETURNING * INTO v_window;
        RETURN QUERY SELECT CASE WHEN v_seq = 1 THEN 'opened' ELSE 'added' END::text,
          v_window.id, v_window.generation, v_seq, v_alone, v_window.item_count,
          v_window.first_at, v_window.last_at;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.digest_window_plan(p_window_id uuid, p_fire_at timestamptz)
        RETURNS TABLE (result text, fire_at timestamptz, timer_at timestamptz)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_window relay.digest_windows;
        v_fire timestamptz;
      BEGIN
        IF p_window_id IS NULL OR p_fire_at IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-27';
        END IF;
        SELECT * INTO v_window FROM relay.digest_windows w
          WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_window_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::timestamptz, NULL::timestamptz;
          RETURN;
        END IF;
        IF v_window.state <> 'open' THEN
          RETURN QUERY SELECT 'not_open'::text, v_window.fire_at, v_window.timer_at;
          RETURN;
        END IF;
        v_fire := least(p_fire_at, v_window.deadline_at);
        IF v_window.timer_at IS NULL OR v_fire < v_window.timer_at THEN
          UPDATE relay.digest_windows w SET fire_at = v_fire, timer_at = v_fire, updated_at = now()
            WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_window_id;
          RETURN QUERY SELECT 'schedule'::text, v_fire, v_fire;
          RETURN;
        END IF;
        UPDATE relay.digest_windows w SET fire_at = v_fire, updated_at = now()
          WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_window_id;
        RETURN QUERY SELECT 'kept'::text, v_fire, v_window.timer_at;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.digest_window_fire(p_window_id uuid)
        RETURNS TABLE (result text, next_at timestamptz, item_count bigint,
          cumulative_count bigint, chain_start bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_now timestamptz := relay_private.business_now();
        v_window relay.digest_windows;
        v_prev relay.digest_windows;
        v_due timestamptz;
        v_reason text;
        v_chain bigint;
        v_total bigint;
      BEGIN
        IF p_window_id IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-27';
        END IF;
        SELECT * INTO v_window FROM relay.digest_windows w
          WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_window_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::timestamptz, NULL::bigint, NULL::bigint,
            NULL::bigint;
          RETURN;
        END IF;
        IF v_window.state <> 'open' THEN
          RETURN QUERY SELECT 'not_open'::text, NULL::timestamptz, v_window.item_count,
            v_window.cumulative_count, v_window.chain_start;
          RETURN;
        END IF;
        v_due := COALESCE(v_window.fire_at, v_window.deadline_at);
        IF v_due > v_now THEN
          UPDATE relay.digest_windows w SET timer_at = v_due, updated_at = now()
            WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_window_id;
          RETURN QUERY SELECT 'not_due'::text, v_due, v_window.item_count, NULL::bigint,
            NULL::bigint;
          RETURN;
        END IF;
        v_reason := CASE
          WHEN v_window.max_items IS NOT NULL AND v_window.item_count >= v_window.max_items
            THEN 'max_items'
          WHEN v_window.fire_at IS NULL OR v_window.fire_at >= v_window.deadline_at THEN 'deadline'
          ELSE 'due' END;
        IF v_window.item_count = 0 THEN
          UPDATE relay.digest_windows w SET state = 'empty', closed_at = v_now,
              close_reason = v_reason, updated_at = now()
            WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_window_id;
          RETURN QUERY SELECT 'empty'::text, NULL::timestamptz, 0::bigint, NULL::bigint,
            NULL::bigint;
          RETURN;
        END IF;
        SELECT * INTO v_prev FROM relay.digest_windows w
          WHERE w.tenant_id = v_tenant AND w.environment = v_env
            AND w.recipient_id = v_window.recipient_id AND w.window_key = v_window.window_key
            AND w.generation = v_window.generation - 1;
        IF FOUND AND v_prev.state = 'fired' AND v_prev.read_at IS NULL THEN
          v_chain := v_prev.chain_start;
          v_total := v_prev.cumulative_count + v_window.item_count;
        ELSE
          v_chain := v_window.generation;
          v_total := v_window.item_count;
        END IF;
        UPDATE relay.digest_windows w SET state = 'fired', chain_start = v_chain,
            cumulative_count = v_total, closed_at = v_now, close_reason = v_reason,
            updated_at = now()
          WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_window_id;
        RETURN QUERY SELECT 'fired'::text, NULL::timestamptz, v_window.item_count, v_total,
          v_chain;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.digest_read(p_recipient_id uuid, p_notification_id uuid)
        RETURNS TABLE (window_id uuid, result text)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_now timestamptz := relay_private.business_now();
        v_key bytea;
        v_id uuid;
      BEGIN
        IF p_recipient_id IS NULL OR p_notification_id IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-27';
        END IF;
        FOR v_key IN
          SELECT DISTINCT w.window_key FROM relay.digest_items i
          JOIN relay.digest_windows w ON w.tenant_id = i.tenant_id
            AND w.environment = i.environment AND w.id = i.window_id
          WHERE i.tenant_id = v_tenant AND i.environment = v_env
            AND i.recipient_id = p_recipient_id AND i.notification_id = p_notification_id
        LOOP
          PERFORM pg_advisory_xact_lock(hashtextextended(v_tenant::text || '/' || v_env::text
            || '/digest/' || p_recipient_id::text || '/' || encode(v_key, 'hex'), 0));
          FOR v_id IN
            UPDATE relay.digest_windows w SET state = 'cancelled', closed_at = v_now,
                close_reason = 'read', read_at = v_now, updated_at = now()
              WHERE w.tenant_id = v_tenant AND w.environment = v_env
                AND w.recipient_id = p_recipient_id AND w.window_key = v_key
                AND w.state = 'open'
              RETURNING w.id
          LOOP
            window_id := v_id;
            result := 'cancelled';
            RETURN NEXT;
          END LOOP;
          FOR v_id IN
            UPDATE relay.digest_windows w SET read_at = v_now, updated_at = now()
              WHERE w.tenant_id = v_tenant AND w.environment = v_env
                AND w.recipient_id = p_recipient_id AND w.window_key = v_key
                AND w.state = 'fired' AND w.read_at IS NULL
              RETURNING w.id
          LOOP
            window_id := v_id;
            result := 'read';
            RETURN NEXT;
          END LOOP;
        END LOOP;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.digest_due(p_limit integer)
        RETURNS TABLE (window_id uuid, due_at timestamptz)
      LANGUAGE sql STABLE
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT w.id, COALESCE(w.fire_at, w.deadline_at)
        FROM relay.digest_windows w
        WHERE w.tenant_id = relay_private.ctx_tenant_id()
          AND w.environment = relay_private.ctx_environment() AND w.state = 'open'
          AND (w.timer_at IS NULL
            OR COALESCE(w.fire_at, w.deadline_at) <= relay_private.business_now())
        ORDER BY COALESCE(w.fire_at, w.deadline_at), w.id
        LIMIT GREATEST(COALESCE(p_limit, 100), 1)
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.digest_due_scopes(p_limit integer)
        RETURNS TABLE (tenant_id uuid, environment text)
      LANGUAGE sql STABLE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT DISTINCT w.tenant_id, w.environment::text
        FROM relay.digest_windows w
        LEFT JOIN relay.virtual_clocks v ON v.tenant_id = w.tenant_id
          AND v.environment = w.environment
        WHERE w.state = 'open'
          AND (w.timer_at IS NULL
            OR COALESCE(w.fire_at, w.deadline_at)
              <= now() + coalesce(v.offset_ms, 0) * interval '1 millisecond')
        LIMIT GREATEST(COALESCE(p_limit, 100), 1)
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.throttle_hit(p_key_digest bytea, p_hit_key bytea, p_limit bigint,
        p_window_ms bigint, p_window_start timestamptz, p_window_end timestamptz)
        RETURNS TABLE (result text, counter_id uuid, hit_count bigint, window_end timestamptz,
          repeated boolean)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_now timestamptz := relay_private.business_now();
        v_hit relay.throttle_hits;
        v_counter relay.throttle_counters;
        v_start timestamptz;
        v_end timestamptz;
        v_outcome text;
      BEGIN
        IF p_key_digest IS NULL OR octet_length(p_key_digest) <> 32 OR p_hit_key IS NULL
          OR octet_length(p_hit_key) <> 32 OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 10000
          OR (p_window_ms IS NULL) = (p_window_end IS NULL)
          OR (p_window_ms IS NOT NULL AND p_window_ms NOT BETWEEN 1 AND 2678400000) THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-32';
        END IF;
        PERFORM pg_advisory_xact_lock(hashtextextended(v_tenant::text || '/' || v_env::text
          || '/throttle/' || encode(p_key_digest, 'hex'), 0));
        SELECT * INTO v_hit FROM relay.throttle_hits h
          WHERE h.tenant_id = v_tenant AND h.environment = v_env
            AND h.key_digest = p_key_digest AND h.hit_key = p_hit_key;
        IF FOUND THEN
          SELECT * INTO v_counter FROM relay.throttle_counters c
            WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = v_hit.counter_id;
          RETURN QUERY SELECT v_hit.outcome, v_counter.id, v_counter.hit_count,
            v_counter.window_end, true;
          RETURN;
        END IF;
        SELECT * INTO v_counter FROM relay.throttle_counters c
          WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.key_digest = p_key_digest
            AND c.window_start <= v_now AND c.window_end > v_now
          ORDER BY c.window_start DESC
          LIMIT 1
          FOR UPDATE;
        IF NOT FOUND THEN
          v_start := COALESCE(p_window_start, v_now);
          v_end := COALESCE(p_window_end, v_now + p_window_ms * interval '1 millisecond');
          IF v_start > v_now OR v_end <= v_now OR v_end > v_start + interval '31 days' THEN
            RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-37';
          END IF;
          INSERT INTO relay.throttle_counters (tenant_id, environment, id, key_digest,
            window_start, window_end, hit_count, limited_count, reset_count, last_reset_at,
            created_at, updated_at)
          VALUES (v_tenant, v_env, uuidv7(), p_key_digest, v_start, v_end, 0, 0, 0, NULL, now(),
            now())
          RETURNING * INTO v_counter;
        END IF;
        IF v_counter.hit_count >= p_limit THEN
          v_outcome := 'limited';
          UPDATE relay.throttle_counters c SET limited_count = c.limited_count + 1,
              updated_at = now()
            WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = v_counter.id
            RETURNING * INTO v_counter;
        ELSE
          v_outcome := 'allowed';
          UPDATE relay.throttle_counters c SET hit_count = c.hit_count + 1, updated_at = now()
            WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = v_counter.id
            RETURNING * INTO v_counter;
        END IF;
        INSERT INTO relay.throttle_hits (tenant_id, environment, key_digest, hit_key, counter_id,
          outcome, hit_limit, created_at)
        VALUES (v_tenant, v_env, p_key_digest, p_hit_key, v_counter.id, v_outcome, p_limit, now());
        RETURN QUERY SELECT v_outcome, v_counter.id, v_counter.hit_count, v_counter.window_end,
          false;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.throttle_reset(p_key_digest bytea, p_record_digest bytea,
        p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, counter_id uuid)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_now timestamptz := relay_private.business_now();
        v_counter relay.throttle_counters;
      BEGIN
        IF p_key_digest IS NULL OR octet_length(p_key_digest) <> 32 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-32';
        END IF;
        PERFORM pg_advisory_xact_lock(hashtextextended(v_tenant::text || '/' || v_env::text
          || '/throttle/' || encode(p_key_digest, 'hex'), 0));
        SELECT * INTO v_counter FROM relay.throttle_counters c
          WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.key_digest = p_key_digest
            AND c.window_start <= v_now AND c.window_end > v_now
          ORDER BY c.window_start DESC
          LIMIT 1
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_active'::text, NULL::uuid;
          RETURN;
        END IF;
        UPDATE relay.throttle_counters c SET hit_count = 0, reset_count = c.reset_count + 1,
            last_reset_at = v_now, updated_at = now()
          WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = v_counter.id;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'throttle.reset',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref,
          'throttle', v_counter.id::text, NULL, p_record_digest);
        RETURN QUERY SELECT 'reset'::text, v_counter.id;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.content_dedup_check(p_delivery_id uuid, p_window_ms bigint)
        RETURNS TABLE (result text, duplicate_of uuid)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_delivery relay.deliveries;
        v_plan relay.delivery_render_plans;
        v_duplicate uuid;
      BEGIN
        IF p_delivery_id IS NULL OR p_window_ms IS NULL
          OR p_window_ms NOT BETWEEN 1 AND 86400000 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-35';
        END IF;
        SELECT * INTO v_delivery FROM relay.deliveries d
          WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_delivery_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::uuid;
          RETURN;
        END IF;
        IF v_delivery.failure_kind IS NOT NULL OR v_delivery.delivery_rank > 0
          OR v_delivery.decision <> 'send' THEN
          RETURN QUERY SELECT 'closed'::text, NULL::uuid;
          RETURN;
        END IF;
        SELECT * INTO v_plan FROM relay.delivery_render_plans p
          WHERE p.tenant_id = v_tenant AND p.environment = v_env AND p.delivery_id = p_delivery_id;
        IF NOT FOUND OR v_plan.render_digest IS NULL THEN
          RETURN QUERY SELECT 'not_rendered'::text, NULL::uuid;
          RETURN;
        END IF;
        PERFORM pg_advisory_xact_lock(hashtextextended(v_tenant::text || '/' || v_env::text
          || '/content/' || v_delivery.recipient_id::text || '/' || v_delivery.channel::text
          || '/' || encode(v_plan.render_digest, 'hex'), 0));
        SELECT d.id INTO v_duplicate FROM relay.delivery_render_plans p
          JOIN relay.deliveries d ON d.tenant_id = p.tenant_id AND d.environment = p.environment
            AND d.id = p.delivery_id
          WHERE p.tenant_id = v_tenant AND p.environment = v_env
            AND p.render_digest = v_plan.render_digest
            AND p.rendered_at >= v_plan.rendered_at - p_window_ms * interval '1 millisecond'
            AND (p.rendered_at, p.delivery_id) < (v_plan.rendered_at, v_plan.delivery_id)
            AND d.recipient_id = v_delivery.recipient_id AND d.channel = v_delivery.channel
            AND d.decision = 'send'
            AND (d.failure_kind IS NULL OR d.failure_kind NOT IN ('skipped', 'cancelled', 'expired'))
          ORDER BY p.rendered_at DESC, p.delivery_id DESC
          LIMIT 1;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'unique'::text, NULL::uuid;
          RETURN;
        END IF;
        PERFORM relay_fn.delivery_decide(p_delivery_id, 'skip', 'duplicate_content',
          'content_dedup.same_content', NULL,
          jsonb_build_object('duplicate_of', v_duplicate, 'window_ms', p_window_ms));
        RETURN QUERY SELECT 'duplicate'::text, v_duplicate;
      END
      $fn$
      """
    ]
  end
end
