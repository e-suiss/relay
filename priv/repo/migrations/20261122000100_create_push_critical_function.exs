defmodule Relay.Repo.Migrations.CreatePushCriticalFunction do
  use Ecto.Migration

  @actor "text, text, text, text"

  @functions [
    {"relay_fn.push_critical_set(jsonb, text, text, bytea, #{@actor})", "relay_owner",
     ~w(relay_app)}
  ]

  # CH-20
  # TN-21
  # TN-23
  # TN-47
  def up do
    Enum.each(statements(), &execute/1)

    for {signature, owner, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
    end
  end

  def down do
    for {signature, _owner, _grantees} <- Enum.reverse(@functions),
        do: execute("DROP FUNCTION #{signature}")
  end

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_fn.push_critical_set(p_value jsonb, p_reason text,
        p_step_up_record_ref text, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
        p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, updated_at timestamptz)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.settings;
        v_value jsonb := CASE WHEN p_value IS NULL OR jsonb_typeof(p_value) = 'null' THEN NULL
          ELSE p_value END;
        v_result text;
      BEGIN
        IF v_env <> 'live' THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-23';
        END IF;
        IF p_reason IS NULL OR p_step_up_record_ref IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-21';
        END IF;
        IF v_value IS NOT NULL AND (jsonb_typeof(v_value) <> 'object'
          OR jsonb_typeof(v_value -> 'templates') IS DISTINCT FROM 'array'
          OR jsonb_array_length(v_value -> 'templates') NOT BETWEEN 1 AND 50
          OR jsonb_typeof(v_value -> 'entitlements') IS DISTINCT FROM 'array'
          OR jsonb_array_length(v_value -> 'entitlements') NOT BETWEEN 1 AND 3) THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'CH-20';
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['setting', NULL, 'push.critical']);
        SELECT * INTO v_row FROM relay.settings s
          WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.subtenant_id IS NULL
            AND s.key = 'push.critical'
          FOR UPDATE;
        IF FOUND AND v_row.value IS NOT DISTINCT FROM v_value THEN
          RETURN QUERY SELECT 'unchanged'::text, v_row.updated_at;
          RETURN;
        END IF;
        IF NOT FOUND AND v_value IS NULL THEN
          RETURN QUERY SELECT 'unchanged'::text, NULL::timestamptz;
          RETURN;
        END IF;
        IF NOT FOUND THEN
          INSERT INTO relay.settings (tenant_id, environment, id, subtenant_id, key, value,
            version, created_at, updated_at)
          VALUES (v_tenant, v_env, uuidv7(), NULL, 'push.critical', v_value, 1, now(), now());
          v_result := 'opened';
        ELSE
          UPDATE relay.settings s
            SET value = v_value, version = s.version + 1, updated_at = now()
            WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = v_row.id;
          v_result := CASE WHEN v_value IS NULL THEN 'closed'
            WHEN v_row.value IS NULL THEN 'opened' ELSE 'changed' END;
        END IF;
        PERFORM relay_private.audit_write(v_tenant, v_env, 'push_critical.changed',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'setting',
          'push.critical', p_reason, p_record_digest);
        RETURN QUERY SELECT v_result, now();
      END
      $fn$
      """
    ]
  end
end
