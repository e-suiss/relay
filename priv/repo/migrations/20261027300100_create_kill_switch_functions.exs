defmodule Relay.Repo.Migrations.CreateKillSwitchFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"
  @ts "timestamp with time zone"

  @functions [
    {"relay_private.canary_bucket(uuid, text, uuid)", "relay_migrator", ~w(relay_owner)},
    {"relay_private.kill_switch_rank(text)", "relay_migrator", ~w(relay_owner)},
    {"relay_private.kill_switch_bump()", "relay_migrator", ~w(relay_owner)},
    {"relay_private.kill_switch_announce(text, relay.kill_switches, bigint)", "relay_migrator",
     ~w(relay_owner)},
    {"relay_fn.kill_switch_engage(uuid, text, text, text, text, text, text, text, text, smallint, #{@ts}, text, text, #{@ts}, text, text, bytea, #{@actor})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.kill_switch_release(uuid, text, text, bytea, #{@actor})", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.kill_switch_replace(uuid, uuid, text, smallint, #{@ts}, text, #{@ts}, text, text, bytea, #{@actor})",
     "relay_owner", ~w(relay_app)},
    {"relay_ops.kill_switch_snapshot()", "relay_migrator", ~w(relay_api relay_worker)},
    {"relay_fn.kill_switch_list(boolean, uuid, integer)", "relay_owner",
     ~w(relay_app relay_report)},
    {"relay_ops.kill_switch_scopes(uuid)", "relay_migrator", ~w(relay_worker)},
    {"relay_fn.deliveries_pause_matching(uuid, integer)", "relay_owner", ~w(relay_app)},
    {"relay_fn.paused_deliveries_cancel(uuid, text, integer)", "relay_owner", ~w(relay_app)},
    {"relay_fn.paused_deliveries_expire(integer)", "relay_owner", ~w(relay_app)}
  ]

  # TN-36
  # TN-37
  # TN-40
  # TN-41
  # TN-42
  # TN-43
  # TN-47
  # TN-70
  # T-9 (2)
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
      CREATE FUNCTION relay_private.canary_bucket(p_tenant_id uuid, p_environment text,
        p_notification_id uuid) RETURNS integer
      LANGUAGE plpgsql STABLE
      SET search_path = pg_catalog, pg_temp
      AS $fn$
      DECLARE
        v_h bigint;
        v_u numeric;
      BEGIN
        v_h := ('x' || encode(substr(sha256('\x856f'::bytea || convert_to('relay.jitter.v1', 'UTF8')
          || '\x66'::bytea || convert_to('canary', 'UTF8')
          || '\x7824'::bytea || convert_to(p_tenant_id::text, 'UTF8')
          || '\x64'::bytea || convert_to(p_environment, 'UTF8')
          || '\x7824'::bytea || convert_to(p_notification_id::text, 'UTF8')), 1, 8), 'hex'))::bit(64)::bigint;
        v_u := v_h::numeric + CASE WHEN v_h < 0 THEN 18446744073709551616 ELSE 0 END;
        RETURN floor(v_u * 100 / 18446744073709551616)::integer;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.kill_switch_rank(p_state text) RETURNS integer
      LANGUAGE sql IMMUTABLE
      SET search_path = pg_catalog, pg_temp
      AS $fn$
        SELECT CASE p_state WHEN 'off' THEN 3 WHEN 'paused_until' THEN 2 WHEN 'canary' THEN 1
          ELSE 0 END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.kill_switch_bump() RETURNS bigint
      LANGUAGE sql VOLATILE
      SET search_path = pg_catalog, pg_temp
      AS $fn$
        UPDATE relay.kill_switch_generation g SET generation = g.generation + 1, updated_at = now()
        WHERE g.singleton
        RETURNING g.generation
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.kill_switch_announce(p_event text, p_record relay.kill_switches,
        p_generation bigint) RETURNS void
      LANGUAGE plpgsql VOLATILE
      SET search_path = pg_catalog, pg_temp
      AS $fn$
      BEGIN
        PERFORM relay_fn.outbox_append(uuidv7(), p_event, 'killswitch:' || p_record.id::text,
          jsonb_strip_nulls(jsonb_build_object('kill_switch_id', p_record.id,
            'scope_kind', p_record.scope_kind, 'scope_ref', p_record.scope_ref,
            'channel', p_record.channel, 'target_kind', p_record.target_kind,
            'target_ref', p_record.target_ref, 'message_class', p_record.message_class,
            'state', p_record.state, 'canary_percent', p_record.canary_percent,
            'paused_until', p_record.paused_until, 'origin', p_record.origin,
            'expires_at', p_record.expires_at, 'status', p_record.status,
            'generation', p_generation)),
          NULL);
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.kill_switch_engage(p_id uuid, p_scope_kind text, p_scope_ref text,
        p_channel text, p_target_kind text, p_target_ref text, p_message_class text,
        p_security_approval_ref text, p_state text, p_canary_percent smallint,
        p_paused_until timestamptz, p_reason text, p_ticket_ref text, p_expires_at timestamptz,
        p_no_ttl_approval_ref text, p_origin text, p_record_digest bytea, p_actor_kind text,
        p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, kill_switch_id uuid, generation bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_installation boolean := v_tenant = relay_private.installation_tenant_id();
        v_existing relay.kill_switches;
        v_record relay.kill_switches;
        v_generation bigint;
      BEGIN
        IF p_scope_kind IS NULL OR p_scope_kind NOT IN ('platform', 'tenant', 'subtenant',
            'campaign', 'workflow', 'api_client', 'sender')
          OR p_target_kind IS NULL OR p_target_kind NOT IN ('all', 'provider_account', 'template')
          OR p_state IS NULL OR p_state NOT IN ('on', 'off', 'canary', 'paused_until')
          OR p_origin IS NULL OR p_origin NOT IN ('operator', 'dead_man')
          OR (p_state = 'canary') <> (p_canary_percent IS NOT NULL)
          OR p_canary_percent NOT BETWEEN 1 AND 99
          OR (p_state = 'paused_until') <> (p_paused_until IS NOT NULL)
          OR p_paused_until <= now()
          OR (p_paused_until = 'infinity'::timestamptz AND p_origin <> 'dead_man')
          OR p_expires_at <= now()
          OR (p_expires_at IS NOT NULL AND p_no_ttl_approval_ref IS NOT NULL)
          OR (p_state = 'paused_until' AND p_paused_until > p_expires_at)
          OR (coalesce(p_message_class, '') <> 'security' AND p_security_approval_ref IS NOT NULL)
          OR char_length(p_reason) > 2000 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-36';
        END IF;
        IF p_reason IS NULL OR btrim(p_reason) = '' THEN
          RETURN QUERY SELECT 'reason_required'::text, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        IF p_expires_at IS NULL AND coalesce(btrim(p_no_ttl_approval_ref), '') = '' THEN
          RETURN QUERY SELECT 'ttl_required'::text, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        IF p_message_class = 'security' AND coalesce(btrim(p_security_approval_ref), '') = '' THEN
          RETURN QUERY SELECT 'security_approval_required'::text, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        IF (p_scope_kind = 'platform') <> (v_installation AND v_env = 'live')
          OR (p_scope_kind <> 'platform' AND v_installation)
          OR (p_scope_kind IN ('platform', 'tenant')) <> (p_scope_ref IS NULL)
          OR (p_target_kind = 'all') <> (p_target_ref IS NULL)
          OR (p_origin = 'dead_man' AND p_scope_kind NOT IN ('tenant', 'campaign', 'workflow')) THEN
          RETURN QUERY SELECT 'invalid_scope'::text, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        IF p_scope_kind = 'subtenant' AND NOT (CASE
            WHEN p_scope_ref ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            THEN EXISTS (SELECT 1 FROM relay.subtenants s
              WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = p_scope_ref::uuid)
            ELSE false END) THEN
          RETURN QUERY SELECT 'scope_not_found'::text, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        SELECT g.generation INTO v_generation FROM relay.kill_switch_generation g
          WHERE g.singleton FOR UPDATE;
        SELECT * INTO v_existing FROM relay.kill_switches k
          WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.id = p_id;
        IF FOUND THEN
          RETURN QUERY SELECT 'exists'::text, p_id, v_generation;
          RETURN;
        END IF;
        IF p_origin = 'dead_man' THEN
          SELECT * INTO v_existing FROM relay.kill_switches k
            WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.origin = 'dead_man'
              AND k.status = 'active' AND k.scope_kind = p_scope_kind
              AND k.scope_ref IS NOT DISTINCT FROM p_scope_ref;
          IF FOUND THEN
            RETURN QUERY SELECT 'dead_man_active'::text, v_existing.id, v_generation;
            RETURN;
          END IF;
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        INSERT INTO relay.kill_switches (tenant_id, environment, id, scope_kind, scope_ref, channel,
          target_kind, target_ref, message_class, security_approval_ref, state, canary_percent,
          paused_until, reason, ticket_ref, origin, created_by_ref, expires_at, no_ttl_approval_ref,
          supersedes_id, status, released_at, released_by_ref, release_reason, release_approval_ref,
          created_at)
        VALUES (v_tenant, v_env, p_id, p_scope_kind, p_scope_ref, p_channel, p_target_kind,
          p_target_ref, p_message_class, p_security_approval_ref, p_state, p_canary_percent,
          p_paused_until, p_reason, p_ticket_ref, p_origin, p_actor_ref, p_expires_at,
          p_no_ttl_approval_ref, NULL, 'active', NULL, NULL, NULL, NULL, now())
        RETURNING * INTO v_record;
        v_generation := relay_private.kill_switch_bump();
        PERFORM relay_private.audit_write(v_tenant, v_env,
          CASE WHEN p_origin = 'dead_man' THEN 'killswitch.auto_paused' ELSE 'killswitch.engaged' END,
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'kill_switch',
          p_id::text, p_reason, p_record_digest);
        PERFORM relay_private.kill_switch_announce(
          CASE WHEN p_origin = 'dead_man' THEN 'killswitch.auto_paused' ELSE 'killswitch.engaged' END,
          v_record, v_generation);
        RETURN QUERY SELECT 'engaged'::text, p_id, v_generation;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.kill_switch_release(p_kill_switch_id uuid, p_release_reason text,
        p_release_approval_ref text, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
        p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, generation bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_record relay.kill_switches;
        v_generation bigint;
      BEGIN
        IF char_length(p_release_reason) > 2000 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-41';
        END IF;
        IF p_release_reason IS NULL OR btrim(p_release_reason) = '' THEN
          RETURN QUERY SELECT 'reason_required'::text, NULL::bigint;
          RETURN;
        END IF;
        IF coalesce(btrim(p_release_approval_ref), '') = '' THEN
          RETURN QUERY SELECT 'approval_required'::text, NULL::bigint;
          RETURN;
        END IF;
        SELECT g.generation INTO v_generation FROM relay.kill_switch_generation g
          WHERE g.singleton FOR UPDATE;
        SELECT * INTO v_record FROM relay.kill_switches k
          WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.id = p_kill_switch_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
          RETURN;
        END IF;
        IF v_record.status = 'released' THEN
          RETURN QUERY SELECT 'already_released'::text, v_generation;
          RETURN;
        END IF;
        UPDATE relay.kill_switches k SET status = 'released', released_at = now(),
            released_by_ref = p_actor_ref, release_reason = p_release_reason,
            release_approval_ref = p_release_approval_ref
          WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.id = p_kill_switch_id
          RETURNING * INTO v_record;
        v_generation := relay_private.kill_switch_bump();
        PERFORM relay_private.audit_write(v_tenant, v_env, 'killswitch.released', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'kill_switch',
          p_kill_switch_id::text, p_release_reason, p_record_digest);
        PERFORM relay_private.kill_switch_announce('killswitch.released', v_record, v_generation);
        RETURN QUERY SELECT 'released'::text, v_generation;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.kill_switch_replace(p_old_id uuid, p_new_id uuid, p_state text,
        p_canary_percent smallint, p_paused_until timestamptz, p_reason text,
        p_expires_at timestamptz, p_no_ttl_approval_ref text, p_release_approval_ref text,
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text)
        RETURNS TABLE (result text, kill_switch_id uuid, generation bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_old relay.kill_switches;
        v_new relay.kill_switches;
        v_old_rank integer;
        v_new_rank integer;
        v_relax boolean;
        v_generation bigint;
      BEGIN
        IF p_state IS NULL OR p_state NOT IN ('on', 'off', 'canary', 'paused_until')
          OR (p_state = 'canary') <> (p_canary_percent IS NOT NULL)
          OR p_canary_percent NOT BETWEEN 1 AND 99
          OR (p_state = 'paused_until') <> (p_paused_until IS NOT NULL)
          OR p_paused_until <= now() OR p_paused_until = 'infinity'::timestamptz
          OR p_expires_at <= now()
          OR (p_expires_at IS NOT NULL AND p_no_ttl_approval_ref IS NOT NULL)
          OR (p_state = 'paused_until' AND p_paused_until > p_expires_at)
          OR char_length(p_reason) > 2000 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-36';
        END IF;
        IF p_reason IS NULL OR btrim(p_reason) = '' THEN
          RETURN QUERY SELECT 'reason_required'::text, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        IF p_expires_at IS NULL AND coalesce(btrim(p_no_ttl_approval_ref), '') = '' THEN
          RETURN QUERY SELECT 'ttl_required'::text, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        SELECT g.generation INTO v_generation FROM relay.kill_switch_generation g
          WHERE g.singleton FOR UPDATE;
        SELECT * INTO v_old FROM relay.kill_switches k
          WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.id = p_old_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        IF v_old.status = 'released' THEN
          RETURN QUERY SELECT 'already_released'::text, NULL::uuid, v_generation;
          RETURN;
        END IF;
        v_old_rank := relay_private.kill_switch_rank(v_old.state);
        v_new_rank := relay_private.kill_switch_rank(p_state);
        v_relax := v_new_rank < v_old_rank OR (v_new_rank = v_old_rank AND (
          (p_state = 'paused_until' AND p_paused_until < v_old.paused_until)
          OR (p_state = 'canary' AND p_canary_percent > v_old.canary_percent)
          OR (p_expires_at IS NOT NULL AND (v_old.expires_at IS NULL OR p_expires_at < v_old.expires_at))));
        IF v_relax AND coalesce(btrim(p_release_approval_ref), '') = '' THEN
          RETURN QUERY SELECT 'approval_required'::text, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        PERFORM relay_private.assert_new_id(p_new_id);
        UPDATE relay.kill_switches k SET status = 'released', released_at = now(),
            released_by_ref = p_actor_ref, release_reason = p_reason,
            release_approval_ref = coalesce(nullif(btrim(p_release_approval_ref), ''),
              'superseded:' || p_new_id::text)
          WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.id = p_old_id
          RETURNING * INTO v_old;
        INSERT INTO relay.kill_switches (tenant_id, environment, id, scope_kind, scope_ref, channel,
          target_kind, target_ref, message_class, security_approval_ref, state, canary_percent,
          paused_until, reason, ticket_ref, origin, created_by_ref, expires_at, no_ttl_approval_ref,
          supersedes_id, status, released_at, released_by_ref, release_reason, release_approval_ref,
          created_at)
        VALUES (v_tenant, v_env, p_new_id, v_old.scope_kind, v_old.scope_ref, v_old.channel,
          v_old.target_kind, v_old.target_ref, v_old.message_class, v_old.security_approval_ref,
          p_state, p_canary_percent, p_paused_until, p_reason, v_old.ticket_ref, 'operator',
          p_actor_ref, p_expires_at, p_no_ttl_approval_ref, p_old_id, 'active', NULL, NULL, NULL,
          NULL, now())
        RETURNING * INTO v_new;
        v_generation := relay_private.kill_switch_bump();
        PERFORM relay_private.audit_write(v_tenant, v_env, 'killswitch.released', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'kill_switch', p_old_id::text,
          p_reason, p_record_digest);
        PERFORM relay_private.audit_write(v_tenant, v_env, 'killswitch.engaged', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'kill_switch', p_new_id::text,
          p_reason, p_record_digest);
        PERFORM relay_private.kill_switch_announce('killswitch.released', v_old, v_generation);
        PERFORM relay_private.kill_switch_announce('killswitch.engaged', v_new, v_generation);
        RETURN QUERY SELECT 'replaced'::text, p_new_id, v_generation;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.kill_switch_snapshot()
        RETURNS TABLE (generation bigint, tenant_id uuid, environment text, id uuid,
          scope_kind text, scope_ref text, channel text, target_kind text, target_ref text,
          message_class text, security_approval_ref text, state text, canary_percent smallint,
          paused_until timestamptz, reason text, ticket_ref text, origin text,
          created_by_ref text, expires_at timestamptz, no_ttl_approval_ref text,
          supersedes_id uuid, status text, released_at timestamptz, released_by_ref text,
          release_reason text, release_approval_ref text, created_at timestamptz)
      LANGUAGE sql STABLE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT g.generation, k.tenant_id, k.environment::text, k.id, k.scope_kind, k.scope_ref,
          k.channel::text, k.target_kind, k.target_ref, k.message_class::text,
          k.security_approval_ref, k.state, k.canary_percent,
          nullif(k.paused_until, 'infinity'::timestamptz), k.reason,
          k.ticket_ref, k.origin, k.created_by_ref, k.expires_at, k.no_ttl_approval_ref,
          k.supersedes_id, k.status, k.released_at, k.released_by_ref, k.release_reason,
          k.release_approval_ref, k.created_at
        FROM relay.kill_switch_generation g
        LEFT JOIN relay.kill_switches k ON k.status = 'active'
          AND (k.expires_at IS NULL OR k.expires_at > now())
        WHERE g.singleton
        ORDER BY k.created_at, k.id
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.kill_switch_list(p_include_released boolean, p_after_id uuid,
        p_limit integer)
        RETURNS SETOF relay.kill_switches
      LANGUAGE sql STABLE SECURITY INVOKER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT k.* FROM relay.kill_switches k
        WHERE (coalesce(p_include_released, false) OR k.status = 'active')
          AND (p_after_id IS NULL OR k.id > p_after_id)
        ORDER BY k.id
        LIMIT least(greatest(coalesce(p_limit, 100), 1), 1000)
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.kill_switch_scopes(p_kill_switch_id uuid)
        RETURNS TABLE (tenant_id uuid, environment text)
      LANGUAGE sql STABLE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT DISTINCT d.tenant_id, d.environment::text
        FROM relay.deliveries d
        WHERE d.paused_at IS NOT NULL AND d.failure_kind IS NULL AND d.delivery_rank = 0
          AND (p_kill_switch_id IS NULL OR d.pause_kill_switch_id = p_kill_switch_id)
        UNION
        SELECT t.id, e.environment
        FROM relay.kill_switches k
        CROSS JOIN relay.tenants t
        CROSS JOIN (VALUES ('live'), ('test')) AS e (environment)
        WHERE k.id = p_kill_switch_id AND k.scope_kind = 'platform' AND k.status = 'active'
          AND k.tenant_id = relay_private.installation_tenant_id()
          AND EXISTS (SELECT 1 FROM relay.deliveries d
            WHERE d.tenant_id = t.id AND d.environment = e.environment::relay.environment
              AND d.delivery_rank = 0 AND d.failure_kind IS NULL AND d.paused_at IS NULL)
        ORDER BY 1, 2
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.deliveries_pause_matching(p_kill_switch_id uuid, p_limit integer)
        RETURNS TABLE (paused bigint, has_more boolean)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_limit integer := least(greatest(coalesce(p_limit, 500), 1), 5000);
        v_ks relay.kill_switches;
        v_rule text;
        v_ids uuid[];
        v_id uuid;
        v_count bigint := 0;
      BEGIN
        SELECT * INTO v_ks FROM relay.kill_switches k
          WHERE k.id = p_kill_switch_id AND k.status = 'active'
            AND (k.expires_at IS NULL OR k.expires_at > now())
            AND (k.state = 'off' OR k.state = 'canary'
              OR (k.state = 'paused_until' AND k.paused_until > now()));
        IF NOT FOUND THEN
          RETURN QUERY SELECT 0::bigint, false;
          RETURN;
        END IF;
        v_rule := 'killswitch.' || v_ks.state;
        SELECT array_agg(c.id) INTO v_ids FROM (
          SELECT d.id FROM relay.deliveries d
          JOIN relay.notifications n ON n.tenant_id = d.tenant_id
            AND n.environment = d.environment AND n.id = d.notification_id
          WHERE d.tenant_id = v_tenant AND d.environment = v_env
            AND d.delivery_rank = 0 AND d.failure_kind IS NULL AND d.paused_at IS NULL
            AND CASE v_ks.scope_kind
              WHEN 'platform' THEN true
              WHEN 'tenant' THEN true
              WHEN 'subtenant' THEN n.subtenant_id::text = v_ks.scope_ref
              ELSE false END
            AND (v_ks.channel IS NULL OR d.channel = v_ks.channel)
            AND CASE v_ks.target_kind
              WHEN 'all' THEN true
              WHEN 'provider_account' THEN d.provider_account_id::text = v_ks.target_ref
              ELSE false END
            AND ((v_ks.message_class IS NULL AND n.message_class <> 'security')
              OR n.message_class = v_ks.message_class)
            AND (v_ks.state <> 'canary' OR relay_private.canary_bucket(d.tenant_id,
              d.environment::text, d.notification_id) >= v_ks.canary_percent)
          ORDER BY d.created_at, d.id
          LIMIT v_limit + 1
          FOR UPDATE OF d) c;
        IF v_ids IS NULL THEN
          RETURN QUERY SELECT 0::bigint, false;
          RETURN;
        END IF;
        FOREACH v_id IN ARRAY v_ids[1:v_limit]
        LOOP
          IF relay_fn.delivery_pause(v_id, v_rule, p_kill_switch_id) = 'paused' THEN
            v_count := v_count + 1;
          END IF;
        END LOOP;
        RETURN QUERY SELECT v_count, cardinality(v_ids) > v_limit;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.paused_deliveries_cancel(p_kill_switch_id uuid, p_rule_id text,
        p_limit integer)
        RETURNS TABLE (cancelled bigint, has_more boolean)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_limit integer := least(greatest(coalesce(p_limit, 500), 1), 5000);
        v_delivery relay.deliveries;
        v_count bigint := 0;
        v_more boolean := false;
      BEGIN
        IF p_kill_switch_id IS NULL OR p_rule_id IS NULL
          OR NOT starts_with(p_rule_id, 'killswitch.bulk_cancel:') THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-47';
        END IF;
        FOR v_delivery IN
          SELECT * FROM relay.deliveries d
          WHERE d.tenant_id = v_tenant AND d.environment = v_env
            AND d.pause_kill_switch_id = p_kill_switch_id AND d.paused_at IS NOT NULL
            AND d.failure_kind IS NULL AND d.delivery_rank = 0
          ORDER BY d.created_at, d.id
          LIMIT v_limit + 1
          FOR UPDATE
        LOOP
          IF v_count = v_limit THEN
            v_more := true;
            EXIT;
          END IF;
          PERFORM relay_private.ledger_record(uuidv7(), v_delivery, NULL, 'relay',
            'delivery.cancelled', NULL, NULL, NULL, now(), NULL, NULL, 'cancelled', NULL, p_rule_id,
            NULL, NULL, jsonb_build_object('kill_switch_id', p_kill_switch_id),
            v_delivery.traceparent);
          v_count := v_count + 1;
        END LOOP;
        RETURN QUERY SELECT v_count, v_more;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.paused_deliveries_expire(p_limit integer) RETURNS bigint
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_limit integer := least(greatest(coalesce(p_limit, 500), 1), 5000);
        v_id uuid;
        v_count bigint := 0;
      BEGIN
        FOR v_id IN
          SELECT d.id FROM relay.deliveries d
          JOIN relay.notifications n ON n.tenant_id = d.tenant_id
            AND n.environment = d.environment AND n.id = d.notification_id
          WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.paused_at IS NOT NULL
            AND d.failure_kind IS NULL AND d.delivery_rank = 0 AND n.expires_at <= now()
          ORDER BY n.expires_at, d.id
          LIMIT v_limit
        LOOP
          IF relay_fn.delivery_expire(v_id, 'killswitch.paused_expired') = 'expired' THEN
            v_count := v_count + 1;
          END IF;
        END LOOP;
        RETURN v_count;
      END
      $fn$
      """
    ]
  end
end
