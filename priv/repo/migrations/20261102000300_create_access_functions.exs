defmodule Relay.Repo.Migrations.CreateAccessFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"

  @functions [
    {"relay_private.api_client_bump()", "relay_migrator", ~w(relay_owner)},
    {"relay_ops.access_link_store(text, jsonb, jsonb, jsonb, bytea, bytea, text, text, text)",
     "relay_maint", ~w(relay_api relay_worker)},
    {"relay_ops.access_event_receipt_record(uuid, text, text, text, jsonb, bytea, text)",
     "relay_maint", ~w(relay_api relay_worker)},
    {"relay_ops.access_event_receipt_read(uuid)", "relay_maint", ~w(relay_worker)},
    {"relay_ops.access_event_receipt_mark(uuid, text, text)", "relay_maint", ~w(relay_worker)},
    {"relay_ops.access_event_receipts_deferred(text, text, integer)", "relay_maint",
     ~w(relay_worker)},
    {"relay_ops.tenant_lookup(text)", "relay_maint", ~w(relay_app)},
    {"relay_ops.api_client_resolve(text, text)", "relay_maint", ~w(relay_api relay_worker)},
    {"relay_ops.api_client_generation()", "relay_maint", ~w(relay_api relay_worker)},
    {"relay_fn.api_client_upsert(uuid, text, uuid, text[], text, bytea, #{@actor})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.api_client_set_status(text, text, text, bytea, #{@actor})", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.api_client_touch(uuid, inet)", "relay_owner", ~w(relay_app)}
  ]

  # E-5
  # E-75
  # E-78
  # INV-41
  # API-44
  # API-71
  # TN-6
  # TN-24
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
      CREATE FUNCTION relay_private.api_client_bump() RETURNS bigint
      LANGUAGE sql VOLATILE
      SET search_path = pg_catalog, pg_temp
      AS $fn$
        UPDATE relay.api_client_generation g SET generation = g.generation + 1, updated_at = now()
        WHERE g.singleton
        RETURNING g.generation
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.access_link_store(p_issuer text, p_discovery jsonb, p_authzen jsonb,
        p_jwks jsonb, p_discovery_digest bytea, p_jwks_digest bytea, p_access_region text,
        p_management_api text, p_event_subscriptions text) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_link relay.access_link;
        v_found boolean;
        v_region text;
        v_state text;
      BEGIN
        IF p_issuer IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'E-78';
        END IF;
        SELECT i.region INTO v_region FROM relay.installation i WHERE i.singleton;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'invariant_violation' USING HINT = 'INV-41';
        END IF;
        SELECT * INTO v_link FROM relay.access_link l WHERE l.singleton FOR UPDATE;
        v_found := FOUND;
        IF v_found AND v_link.issuer <> p_issuer THEN
          RETURN 'issuer_mismatch';
        END IF;
        IF p_discovery IS NULL OR p_jwks IS NULL THEN
          v_state := CASE
            WHEN v_found AND v_link.state = 'region_mismatch' THEN 'region_mismatch'
            WHEN v_found AND v_link.jwks IS NOT NULL THEN 'stale'
            ELSE 'pending' END;
          INSERT INTO relay.access_link AS l (singleton, issuer, state, updated_at)
          VALUES (true, p_issuer, v_state, now())
          ON CONFLICT (singleton) DO UPDATE SET state = EXCLUDED.state, updated_at = now();
          RETURN 'unchanged';
        END IF;
        IF p_access_region IS NULL OR p_access_region <> v_region THEN
          INSERT INTO relay.access_link AS l (singleton, issuer, access_region, state, fetched_at,
            updated_at)
          VALUES (true, p_issuer,
            CASE WHEN p_access_region IN ('tr', 'eu', 'us') THEN p_access_region END,
            'region_mismatch', now(), now())
          ON CONFLICT (singleton) DO UPDATE SET discovery = NULL, authzen = NULL, jwks = NULL,
            discovery_digest = NULL, jwks_digest = NULL, access_region = EXCLUDED.access_region,
            management_api = NULL, event_subscriptions = NULL, state = 'region_mismatch',
            fetched_at = now(), jwks_fetched_at = NULL, updated_at = now();
          RETURN 'region_mismatch';
        END IF;
        IF v_found AND v_link.state = 'ok' AND v_link.discovery_digest = p_discovery_digest
          AND v_link.jwks_digest = p_jwks_digest
          AND v_link.authzen IS NOT DISTINCT FROM p_authzen THEN
          UPDATE relay.access_link l SET fetched_at = now(), jwks_fetched_at = now(),
              updated_at = now()
            WHERE l.singleton;
          RETURN 'unchanged';
        END IF;
        INSERT INTO relay.access_link AS l (singleton, issuer, discovery, authzen, jwks,
          discovery_digest, jwks_digest, access_region, management_api, event_subscriptions, state,
          fetched_at, jwks_fetched_at, updated_at)
        VALUES (true, p_issuer, p_discovery, p_authzen, p_jwks, p_discovery_digest, p_jwks_digest,
          p_access_region, p_management_api, p_event_subscriptions, 'ok', now(), now(), now())
        ON CONFLICT (singleton) DO UPDATE SET discovery = EXCLUDED.discovery,
          authzen = EXCLUDED.authzen, jwks = EXCLUDED.jwks,
          discovery_digest = EXCLUDED.discovery_digest, jwks_digest = EXCLUDED.jwks_digest,
          access_region = EXCLUDED.access_region, management_api = EXCLUDED.management_api,
          event_subscriptions = EXCLUDED.event_subscriptions, state = 'ok', fetched_at = now(),
          jwks_fetched_at = now(), updated_at = now();
        RETURN 'stored';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.access_event_receipt_record(p_id uuid, p_webhook_id text,
        p_event_type text, p_access_tenant_id text, p_payload jsonb, p_body_digest bytea,
        p_traceparent text) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      BEGIN
        IF p_id IS NULL OR p_webhook_id IS NULL OR p_event_type IS NULL OR p_payload IS NULL
          OR p_body_digest IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'E-36';
        END IF;
        INSERT INTO relay.access_event_receipts (id, webhook_id, event_type, access_tenant_id,
          payload, body_digest, state, reason, traceparent, received_at, processed_at)
        VALUES (p_id, p_webhook_id, p_event_type, p_access_tenant_id, p_payload, p_body_digest,
          'received', NULL, p_traceparent, now(), NULL)
        ON CONFLICT (webhook_id) DO NOTHING;
        IF FOUND THEN
          RETURN 'recorded';
        END IF;
        RETURN 'duplicate';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.access_event_receipt_read(p_id uuid)
        RETURNS TABLE (webhook_id text, event_type text, access_tenant_id text, payload jsonb,
          state text)
      LANGUAGE sql STABLE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT r.webhook_id, r.event_type::text, r.access_tenant_id, r.payload, r.state
        FROM relay.access_event_receipts r
        WHERE r.id = p_id
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.access_event_receipt_mark(p_id uuid, p_state text, p_reason text)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_state text;
      BEGIN
        IF p_state IS NULL OR p_state NOT IN ('processed', 'rejected', 'deferred') THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'E-36';
        END IF;
        SELECT r.state INTO v_state FROM relay.access_event_receipts r WHERE r.id = p_id FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_state IN ('processed', 'rejected') THEN
          RETURN 'already_final';
        END IF;
        UPDATE relay.access_event_receipts r SET state = p_state, reason = p_reason,
            processed_at = CASE WHEN p_state = 'deferred' THEN NULL ELSE now() END
          WHERE r.id = p_id;
        RETURN 'marked';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.access_event_receipts_deferred(p_access_tenant_id text,
        p_reason text, p_limit integer) RETURNS TABLE (id uuid)
      LANGUAGE sql STABLE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT r.id FROM relay.access_event_receipts r
        WHERE r.state = 'deferred'
          AND (p_access_tenant_id IS NULL OR r.access_tenant_id = p_access_tenant_id)
          AND (p_reason IS NULL OR r.reason = p_reason)
        ORDER BY r.received_at, r.id
        LIMIT greatest(least(coalesce(p_limit, 100), 1000), 1)
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.tenant_lookup(p_access_tenant_id text)
        RETURNS TABLE (tenant_id uuid, status text, platform_product text)
      LANGUAGE sql STABLE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT t.id, t.status, t.platform_product FROM relay.tenants t
        WHERE t.access_tenant_id = p_access_tenant_id AND t.kind = 'tenant'
      $fn$
      """,
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
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.api_client_generation() RETURNS bigint
      LANGUAGE sql STABLE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT g.generation FROM relay.api_client_generation g WHERE g.singleton
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.api_client_upsert(p_id uuid, p_access_client_id text,
        p_subtenant_id uuid, p_scopes text[], p_access_event_ref text, p_record_digest bytea,
        p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, api_client_id uuid, generation bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env text := relay_private.ctx_environment()::text;
        v_client relay.api_clients;
        v_scopes text[];
        v_generation bigint;
      BEGIN
        IF p_access_client_id IS NULL OR p_scopes IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'API-44';
        END IF;
        v_scopes := ARRAY(SELECT DISTINCT s FROM unnest(p_scopes) AS u(s) ORDER BY s);
        PERFORM relay_private.lock_scope(ARRAY['api_client', p_access_client_id]);
        SELECT * INTO v_client FROM relay.api_clients c
          WHERE c.access_client_id = p_access_client_id FOR UPDATE;
        IF FOUND THEN
          IF v_client.status = 'revoked' THEN
            RETURN QUERY SELECT 'revoked_terminal'::text, v_client.id, NULL::bigint;
            RETURN;
          END IF;
          IF v_client.subtenant_id IS DISTINCT FROM p_subtenant_id THEN
            RETURN QUERY SELECT 'subtenant_changed'::text, v_client.id, NULL::bigint;
            RETURN;
          END IF;
          IF v_client.scopes::text[] = v_scopes THEN
            RETURN QUERY SELECT 'unchanged'::text, v_client.id, NULL::bigint;
            RETURN;
          END IF;
          UPDATE relay.api_clients c SET scopes = v_scopes::relay.api_scope[],
              access_event_ref = p_access_event_ref, version = c.version + 1, updated_at = now()
            WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = v_client.id;
          v_generation := relay_private.api_client_bump();
          PERFORM relay_private.audit_write(v_tenant, v_env, 'api_client.updated', p_actor_kind,
            p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'api_client', p_access_client_id,
            NULL, p_record_digest);
          RETURN QUERY SELECT 'updated'::text, v_client.id, v_generation;
          RETURN;
        END IF;
        IF p_subtenant_id IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM relay.subtenants s WHERE s.id = p_subtenant_id) THEN
          RETURN QUERY SELECT 'subtenant_not_found'::text, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        INSERT INTO relay.api_clients (tenant_id, environment, id, access_client_id, subtenant_id,
          scopes, status, status_changed_at, last_used_at, last_used_ip, access_event_ref, version,
          created_at, updated_at)
        VALUES (v_tenant, v_env, p_id, p_access_client_id, p_subtenant_id,
          v_scopes::relay.api_scope[], 'active', now(), NULL, NULL, p_access_event_ref, 1, now(),
          now());
        v_generation := relay_private.api_client_bump();
        PERFORM relay_private.audit_write(v_tenant, v_env, 'api_client.created', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'api_client', p_access_client_id,
          NULL, p_record_digest);
        RETURN QUERY SELECT 'created'::text, p_id, v_generation;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.api_client_set_status(p_access_client_id text, p_status text,
        p_access_event_ref text, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
        p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, generation bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env text := relay_private.ctx_environment()::text;
        v_client relay.api_clients;
        v_action text;
        v_generation bigint;
      BEGIN
        IF p_access_client_id IS NULL OR p_status IS NULL
          OR p_status NOT IN ('active', 'suspended', 'revoked') THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'API-44';
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['api_client', p_access_client_id]);
        SELECT * INTO v_client FROM relay.api_clients c
          WHERE c.access_client_id = p_access_client_id FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
          RETURN;
        END IF;
        IF v_client.status = p_status THEN
          RETURN QUERY SELECT 'unchanged'::text, NULL::bigint;
          RETURN;
        END IF;
        IF v_client.status = 'revoked' THEN
          RETURN QUERY SELECT 'invalid_transition'::text, NULL::bigint;
          RETURN;
        END IF;
        v_action := CASE p_status
          WHEN 'suspended' THEN 'api_client.suspended'
          WHEN 'revoked' THEN 'api_client.revoked'
          ELSE 'api_client.reactivated' END;
        UPDATE relay.api_clients c SET status = p_status, status_changed_at = now(),
            access_event_ref = p_access_event_ref, version = c.version + 1, updated_at = now()
          WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = v_client.id;
        v_generation := relay_private.api_client_bump();
        PERFORM relay_private.audit_write(v_tenant, v_env, v_action, p_actor_kind, p_actor_ref,
          p_on_behalf_of_ref, p_access_record_ref, 'api_client', p_access_client_id, NULL,
          p_record_digest);
        RETURN QUERY SELECT 'changed'::text, v_generation;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.api_client_touch(p_api_client_id uuid, p_ip inet) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_count bigint;
      BEGIN
        IF p_api_client_id IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'API-44';
        END IF;
        UPDATE relay.api_clients c SET last_used_at = now(), last_used_ip = p_ip
          WHERE c.id = p_api_client_id
            AND (c.last_used_at IS NULL OR c.last_used_at < now() - interval '60 seconds');
        GET DIAGNOSTICS v_count = ROW_COUNT;
        IF v_count > 0 THEN
          RETURN 'touched';
        END IF;
        IF EXISTS (SELECT 1 FROM relay.api_clients c WHERE c.id = p_api_client_id) THEN
          RETURN 'throttled';
        END IF;
        RETURN 'not_found';
      END
      $fn$
      """
    ]
  end
end
