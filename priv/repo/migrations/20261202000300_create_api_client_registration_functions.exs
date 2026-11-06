defmodule Relay.Repo.Migrations.CreateApiClientRegistrationFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"
  @resolve "relay_ops.api_client_resolve(text, text)"

  @functions [
    {"relay_fn.api_client_register(uuid, text, text, bytea, #{@actor})", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.api_client_assign(text, text, bytea, #{@actor})", "relay_owner", ~w(relay_app)}
  ]

  # E-99
  # API-44
  # API-71
  # TN-24
  # TN-36
  def up do
    Enum.each(statements(), &execute/1)

    for {signature, owner, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
    end

    execute("DROP FUNCTION #{@resolve}")
    execute(resolve())
    execute("REVOKE ALL ON FUNCTION #{@resolve} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@resolve} TO relay_api, relay_worker")
  end

  def down, do: :ok

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_fn.api_client_register(p_id uuid, p_access_client_id text,
        p_access_event_ref text, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
        p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, registration_id uuid)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env text := relay_private.ctx_environment()::text;
        v_existing uuid;
      BEGIN
        IF p_access_client_id IS NULL OR v_env <> 'live' THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'E-99';
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['api_client', p_access_client_id]);
        SELECT r.id INTO v_existing FROM relay.api_client_registrations r
          WHERE r.access_client_id = p_access_client_id;
        IF FOUND THEN
          RETURN QUERY SELECT 'exists'::text, v_existing;
          RETURN;
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        INSERT INTO relay.api_client_registrations (tenant_id, environment, id, access_client_id,
          state, assigned_environment, assigned_at, access_event_ref, version, created_at,
          updated_at)
        VALUES (v_tenant, v_env, p_id, p_access_client_id, 'pending', NULL, NULL,
          p_access_event_ref, 1, now(), now());
        PERFORM relay_private.audit_write(v_tenant, v_env, 'api_client.registered', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'api_client', p_access_client_id,
          NULL, p_record_digest);
        RETURN QUERY SELECT 'created'::text, p_id;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.api_client_assign(p_access_client_id text, p_environment text,
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text)
        RETURNS TABLE (result text, access_tenant_id text, generation bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env text := relay_private.ctx_environment()::text;
        v_registration relay.api_client_registrations;
        v_access_tenant text;
        v_generation bigint;
      BEGIN
        IF p_access_client_id IS NULL OR p_environment IS NULL
          OR p_environment NOT IN ('live', 'test') OR v_env <> 'live' THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'E-99';
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['api_client', p_access_client_id]);
        SELECT t.access_tenant_id INTO v_access_tenant FROM relay.tenants t WHERE t.id = v_tenant;
        SELECT * INTO v_registration FROM relay.api_client_registrations r
          WHERE r.access_client_id = p_access_client_id FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::text, NULL::bigint;
          RETURN;
        END IF;
        IF v_registration.state = 'assigned' THEN
          RETURN QUERY SELECT
            CASE WHEN v_registration.assigned_environment::text = p_environment
              THEN 'already_assigned' ELSE 'environment_conflict' END,
            v_access_tenant, NULL::bigint;
          RETURN;
        END IF;
        UPDATE relay.api_client_registrations r SET state = 'assigned',
            assigned_environment = p_environment::relay.environment, assigned_at = now(),
            version = r.version + 1, updated_at = now()
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = v_registration.id;
        v_generation := relay_private.api_client_bump();
        PERFORM relay_private.audit_write(v_tenant, v_env, 'api_client.assigned', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'api_client', p_access_client_id,
          p_environment, p_record_digest);
        RETURN QUERY SELECT 'assigned'::text, v_access_tenant, v_generation;
      END
      $fn$
      """
    ]
  end

  defp resolve do
    ~S"""
    CREATE FUNCTION relay_ops.api_client_resolve(p_access_tenant_id text, p_access_client_id text)
      RETURNS TABLE (tenant_id uuid, environment text, api_client_id uuid, subtenant_id uuid,
        scopes text[], status text, tenant_status text, generation bigint)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
      SELECT c.tenant_id, c.environment::text, c.id, c.subtenant_id, c.scopes::text[], c.status,
        CASE WHEN t.status <> 'active' THEN t.status
          WHEN s.state IS NOT NULL AND s.state <> 'active' THEN 'suspended'
          ELSE 'active' END,
        (SELECT g.generation FROM relay.api_client_generation g WHERE g.singleton)
      FROM relay.tenants t
      JOIN relay.api_clients c ON c.tenant_id = t.id
      LEFT JOIN relay.subtenants s ON s.tenant_id = c.tenant_id
        AND s.environment = c.environment AND s.id = c.subtenant_id
      WHERE t.access_tenant_id = p_access_tenant_id AND t.kind = 'tenant'
        AND c.access_client_id = p_access_client_id
      UNION ALL
      SELECT r.tenant_id, NULL::text, r.id, NULL::uuid, ARRAY[]::text[], 'pending',
        CASE WHEN t.status <> 'active' THEN t.status ELSE 'active' END,
        (SELECT g.generation FROM relay.api_client_generation g WHERE g.singleton)
      FROM relay.tenants t
      JOIN relay.api_client_registrations r ON r.tenant_id = t.id
      WHERE t.access_tenant_id = p_access_tenant_id AND t.kind = 'tenant'
        AND r.access_client_id = p_access_client_id
        AND NOT EXISTS (SELECT 1 FROM relay.api_clients c
          WHERE c.tenant_id = r.tenant_id AND c.access_client_id = r.access_client_id)
    $fn$
    """
  end
end
