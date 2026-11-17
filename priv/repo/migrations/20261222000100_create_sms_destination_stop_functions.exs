defmodule Relay.Repo.Migrations.CreateSmsDestinationStopFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"

  @functions [
    {"relay_fn.sms_destination_stop_open(uuid, text, text, text, text, jsonb, bigint, bigint, bytea, #{@actor})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.sms_destination_stop_lift(uuid, text, bytea, #{@actor})", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.sms_destination_stop_match(text, text[])", "relay_owner", ~w(relay_app)}
  ]

  # CH-54
  # E-33
  # OP-8
  def up do
    execute(open())
    execute(lift())
    execute(match())

    for {signature, owner, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
    end
  end

  def down, do: :ok

  defp open do
    ~S"""
    CREATE FUNCTION relay_fn.sms_destination_stop_open(p_id uuid, p_kind text, p_value text,
      p_country text, p_rule_id text, p_detail jsonb, p_grace_seconds bigint,
      p_escalation_seconds bigint, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
      p_on_behalf_of_ref text, p_access_record_ref text)
      RETURNS TABLE (result text, stop_id uuid, country_prefix_stops bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_existing uuid;
      v_count bigint;
    BEGIN
      IF p_kind IS NULL OR p_kind NOT IN ('prefix', 'country') OR p_value IS NULL
        OR p_country IS NULL OR p_rule_id IS NULL OR p_detail IS NULL
        OR p_grace_seconds IS NULL OR p_grace_seconds < 0
        OR p_escalation_seconds IS NULL OR p_escalation_seconds < 0
        OR p_record_digest IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'CH-54';
      END IF;
      PERFORM relay_private.lock_scope(ARRAY['sms_destination_stops', p_kind, p_value]);
      SELECT s.id INTO v_existing FROM relay.sms_destination_stops s
        WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.kind = p_kind
          AND s.value = p_value AND s.state = 'active';
      IF FOUND THEN
        RETURN QUERY SELECT 'exists'::text, v_existing, NULL::bigint;
        RETURN;
      END IF;
      IF EXISTS (SELECT 1 FROM relay.sms_destination_stops s
        WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.kind = p_kind
          AND s.value = p_value AND s.state = 'lifted'
          AND s.lifted_at > now() - make_interval(secs => p_grace_seconds)) THEN
        RETURN QUERY SELECT 'recently_lifted'::text, NULL::uuid, NULL::bigint;
        RETURN;
      END IF;
      PERFORM relay_private.assert_new_id(p_id);
      INSERT INTO relay.sms_destination_stops (tenant_id, environment, id, kind, value, country,
        rule_id, detail, state, lifted_at, lifted_by_ref, lift_reason, created_at, updated_at)
      VALUES (v_tenant, v_env, p_id, p_kind, p_value, p_country, p_rule_id, p_detail, 'active',
        NULL, NULL, NULL, now(), now());
      PERFORM relay_private.audit_write(v_tenant, v_env::text, 'sms_destination.stopped',
        p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref,
        'sms_destination_stop', p_id::text, p_rule_id, p_record_digest);
      PERFORM relay_fn.outbox_append(uuidv7(), 'sms_destination.stopped',
        'sms_destination:' || p_kind || ':' || ltrim(p_value, '+'),
        jsonb_build_object('kind', p_kind, 'value', p_value, 'country', p_country,
          'rule_id', p_rule_id, 'stopped_at', now(), 'detail', p_detail), NULL);
      SELECT count(*) INTO v_count FROM relay.sms_destination_stops s
        WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.kind = 'prefix'
          AND s.country = p_country
          AND s.created_at > now() - make_interval(secs => p_escalation_seconds);
      RETURN QUERY SELECT 'opened'::text, p_id, v_count;
    END
    $fn$
    """
  end

  defp lift do
    ~S"""
    CREATE FUNCTION relay_fn.sms_destination_stop_lift(p_stop_id uuid, p_reason text,
      p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
      p_access_record_ref text)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_row relay.sms_destination_stops;
    BEGIN
      IF p_stop_id IS NULL OR p_reason IS NULL OR char_length(p_reason) NOT BETWEEN 1 AND 2000
        OR p_actor_ref IS NULL OR p_record_digest IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'CH-54';
      END IF;
      SELECT * INTO v_row FROM relay.sms_destination_stops s
        WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = p_stop_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      IF v_row.state = 'lifted' THEN
        RETURN 'already_lifted';
      END IF;
      UPDATE relay.sms_destination_stops s SET state = 'lifted', lifted_at = now(),
          lifted_by_ref = p_actor_ref, lift_reason = p_reason, updated_at = now()
        WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = v_row.id;
      PERFORM relay_private.audit_write(v_tenant, v_env::text, 'sms_destination.released',
        p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref,
        'sms_destination_stop', v_row.id::text, p_reason, p_record_digest);
      PERFORM relay_fn.outbox_append(uuidv7(), 'sms_destination.released',
        'sms_destination:' || v_row.kind || ':' || ltrim(v_row.value, '+'),
        jsonb_build_object('kind', v_row.kind, 'value', v_row.value, 'country', v_row.country,
          'rule_id', v_row.rule_id, 'released_at', now()), NULL);
      RETURN 'lifted';
    END
    $fn$
    """
  end

  defp match do
    ~S"""
    CREATE FUNCTION relay_fn.sms_destination_stop_match(p_country text, p_prefixes text[])
      RETURNS TABLE (stop_id uuid, kind text, value text, rule_id text)
    LANGUAGE sql STABLE SECURITY INVOKER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
      SELECT s.id, s.kind, s.value, s.rule_id
      FROM relay.sms_destination_stops s
      WHERE s.tenant_id = relay_private.ctx_tenant_id()
        AND s.environment = relay_private.ctx_environment()
        AND s.state = 'active'
        AND ((s.kind = 'country' AND s.value = p_country)
          OR (s.kind = 'prefix' AND s.value = ANY (p_prefixes)))
      ORDER BY s.kind, s.created_at, s.id
    $fn$
    """
  end
end
