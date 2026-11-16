defmodule Relay.Repo.Migrations.CreateWebhookFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"

  @functions [
    {"relay_fn.webhook_consumer_create(uuid, text, text, text, uuid, bytea, #{@actor})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.webhook_consumer_update(uuid, bigint, jsonb, bytea, #{@actor})", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.webhook_consumer_archive(uuid, bytea, #{@actor})", "relay_owner", ~w(relay_app)},
    {"relay_fn.webhook_event_type_create(uuid, text, text, jsonb, bytea, text[], jsonb, bytea, #{@actor})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.webhook_event_type_version_add(uuid, jsonb, bytea, text[], jsonb, bytea, #{@actor})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.webhook_event_type_archive(uuid, bytea, #{@actor})", "relay_owner", ~w(relay_app)},
    {"relay_fn.webhook_endpoint_create(uuid, text, text, text, text, jsonb, uuid, text[], text, text[], text, jsonb, text, uuid, bytea, bytea, uuid, bigint, bigint, bytea, #{@actor})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.webhook_endpoint_update(uuid, bigint, jsonb, bytea, #{@actor})", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.webhook_endpoint_archive(uuid, bytea, #{@actor})", "relay_owner", ~w(relay_app)},
    {"relay_fn.webhook_endpoint_key_rotate(uuid, uuid, text, bytea, bytea, uuid, bigint, bytea, #{@actor})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.webhook_endpoint_keys_expire()", "relay_owner", ~w(relay_app)},
    {"relay_fn.operations_contacts_replace(uuid[], bytea[], uuid, bigint, bytea, #{@actor})",
     "relay_owner", ~w(relay_app)}
  ]

  # WH-2
  # WH-5
  # WH-6
  # WH-12
  # WH-14
  # WH-16
  # WH-45
  # WH-48
  # WH-52
  # WH-56
  # OP-8
  def up do
    Enum.each(statements(), &execute/1)

    for {signature, owner, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
    end

    execute("REVOKE ALL ON FUNCTION relay_private.webhook_event_types_known(text[]) FROM PUBLIC")

    execute(
      "GRANT EXECUTE ON FUNCTION relay_private.webhook_event_types_known(text[]) TO relay_owner"
    )
  end

  def down, do: :ok

  defp statements do
    [
      known(),
      consumer_create(),
      consumer_update(),
      consumer_archive(),
      event_type_create(),
      event_type_version_add(),
      event_type_archive(),
      endpoint_create(),
      endpoint_update(),
      endpoint_archive(),
      key_rotate(),
      keys_expire(),
      contacts_replace()
    ]
  end

  defp known do
    ~S"""
    CREATE FUNCTION relay_private.webhook_event_types_known(p_names text[]) RETURNS boolean
    LANGUAGE sql STABLE
    SET search_path = pg_catalog, pg_temp
    AS $fn$
      SELECT NOT EXISTS (
        SELECT 1 FROM unnest(p_names) AS n(name)
        WHERE n.name <> '*' AND NOT EXISTS (
          SELECT 1 FROM relay.webhook_event_types t
          WHERE t.tenant_id = relay_private.ctx_tenant_id()
            AND t.environment = relay_private.ctx_environment()
            AND t.name = n.name AND t.state = 'active'))
    $fn$
    """
  end

  defp consumer_create do
    ~S"""
    CREATE FUNCTION relay_fn.webhook_consumer_create(p_id uuid, p_key text, p_name text,
      p_source text, p_subtenant_id uuid, p_record_digest bytea, p_actor_kind text,
      p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
      RETURNS TABLE (result text, consumer_id uuid, version bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_existing relay.webhook_consumers;
    BEGIN
      IF relay_private.tenant_status() <> 'active' THEN
        RETURN QUERY SELECT 'tenant_inactive'::text, NULL::uuid, NULL::bigint;
        RETURN;
      END IF;
      IF p_key IS NULL OR p_record_digest IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WH-2';
      END IF;
      PERFORM relay_private.lock_scope(ARRAY['webhook_consumer', p_key]);
      SELECT * INTO v_existing FROM relay.webhook_consumers c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.key = p_key;
      IF FOUND THEN
        RETURN QUERY SELECT 'key_conflict'::text, v_existing.id, v_existing.version;
        RETURN;
      END IF;
      IF p_subtenant_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM relay.subtenants s
        WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = p_subtenant_id) THEN
        RETURN QUERY SELECT 'subtenant_not_found'::text, NULL::uuid, NULL::bigint;
        RETURN;
      END IF;
      PERFORM relay_private.assert_new_id(p_id);
      INSERT INTO relay.webhook_consumers (tenant_id, environment, id, key, name, source,
        subtenant_id, state, version, archived_at, created_at, updated_at)
      VALUES (v_tenant, v_env, p_id, p_key, p_name, p_source, p_subtenant_id, 'active', 1, NULL,
        now(), now());
      PERFORM relay_private.audit_write(v_tenant, v_env::text, 'webhook_consumer.created',
        p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'webhook_consumer',
        p_id::text, NULL, p_record_digest);
      RETURN QUERY SELECT 'created'::text, p_id, 1::bigint;
    END
    $fn$
    """
  end

  defp consumer_update do
    ~S"""
    CREATE FUNCTION relay_fn.webhook_consumer_update(p_consumer_id uuid, p_expected_version bigint,
      p_changes jsonb, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
      p_on_behalf_of_ref text, p_access_record_ref text)
      RETURNS TABLE (result text, version bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_row relay.webhook_consumers;
      v_name text;
      v_source text;
      v_version bigint;
    BEGIN
      IF p_consumer_id IS NULL OR p_changes IS NULL OR jsonb_typeof(p_changes) <> 'object'
        OR p_record_digest IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WH-2';
      END IF;
      SELECT * INTO v_row FROM relay.webhook_consumers c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_consumer_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
        RETURN;
      END IF;
      IF v_row.state = 'archived' THEN
        RETURN QUERY SELECT 'archived'::text, v_row.version;
        RETURN;
      END IF;
      IF p_expected_version IS NOT NULL AND p_expected_version <> v_row.version THEN
        RETURN QUERY SELECT 'version_conflict'::text, v_row.version;
        RETURN;
      END IF;
      v_name := CASE WHEN p_changes ? 'name' THEN p_changes ->> 'name' ELSE v_row.name END;
      v_source := CASE WHEN p_changes ? 'source' THEN p_changes ->> 'source' ELSE v_row.source END;
      IF v_name IS NOT DISTINCT FROM v_row.name AND v_source IS NOT DISTINCT FROM v_row.source THEN
        RETURN QUERY SELECT 'unchanged'::text, v_row.version;
        RETURN;
      END IF;
      UPDATE relay.webhook_consumers c SET name = v_name, source = v_source,
          version = c.version + 1, updated_at = now()
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_consumer_id
        RETURNING c.version INTO v_version;
      PERFORM relay_private.audit_write(v_tenant, v_env::text, 'webhook_consumer.updated',
        p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'webhook_consumer',
        p_consumer_id::text, NULL, p_record_digest);
      RETURN QUERY SELECT 'updated'::text, v_version;
    END
    $fn$
    """
  end

  defp consumer_archive do
    ~S"""
    CREATE FUNCTION relay_fn.webhook_consumer_archive(p_consumer_id uuid, p_record_digest bytea,
      p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
      RETURNS TABLE (result text, version bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_row relay.webhook_consumers;
      v_version bigint;
    BEGIN
      IF p_consumer_id IS NULL OR p_record_digest IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WH-2';
      END IF;
      PERFORM relay_private.lock_scope(ARRAY['webhook_endpoints']);
      SELECT * INTO v_row FROM relay.webhook_consumers c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_consumer_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
        RETURN;
      END IF;
      IF v_row.state = 'archived' THEN
        RETURN QUERY SELECT 'already_archived'::text, v_row.version;
        RETURN;
      END IF;
      IF EXISTS (SELECT 1 FROM relay.webhook_endpoints e
        WHERE e.tenant_id = v_tenant AND e.environment = v_env AND e.consumer_id = p_consumer_id
          AND e.state <> 'archived') THEN
        RETURN QUERY SELECT 'in_use'::text, v_row.version;
        RETURN;
      END IF;
      UPDATE relay.webhook_consumers c SET state = 'archived', archived_at = now(),
          version = c.version + 1, updated_at = now()
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_consumer_id
        RETURNING c.version INTO v_version;
      PERFORM relay_private.audit_write(v_tenant, v_env::text, 'webhook_consumer.archived',
        p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'webhook_consumer',
        p_consumer_id::text, NULL, p_record_digest);
      RETURN QUERY SELECT 'archived'::text, v_version;
    END
    $fn$
    """
  end

  defp event_type_create do
    ~S"""
    CREATE FUNCTION relay_fn.webhook_event_type_create(p_id uuid, p_name text, p_description text,
      p_json_schema jsonb, p_schema_digest bytea, p_identifiers text[], p_example jsonb,
      p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
      p_access_record_ref text)
      RETURNS TABLE (result text, event_type_id uuid)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_existing uuid;
    BEGIN
      IF relay_private.tenant_status() <> 'active' THEN
        RETURN QUERY SELECT 'tenant_inactive'::text, NULL::uuid;
        RETURN;
      END IF;
      IF p_name IS NULL OR p_json_schema IS NULL OR p_schema_digest IS NULL
        OR p_identifiers IS NULL OR p_record_digest IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WH-14';
      END IF;
      PERFORM relay_private.lock_scope(ARRAY['webhook_event_type', p_name]);
      SELECT t.id INTO v_existing FROM relay.webhook_event_types t
        WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.name = p_name;
      IF FOUND THEN
        RETURN QUERY SELECT 'name_conflict'::text, v_existing;
        RETURN;
      END IF;
      PERFORM relay_private.assert_new_id(p_id);
      INSERT INTO relay.webhook_event_types (tenant_id, environment, id, name, description, state,
        current_version, version, archived_at, created_at, updated_at)
      VALUES (v_tenant, v_env, p_id, p_name, p_description, 'active', 1, 1, NULL, now(), now());
      INSERT INTO relay.webhook_event_type_versions (tenant_id, environment, event_type_id,
        version, json_schema, schema_digest, identifiers, example, created_by_ref, created_at)
      VALUES (v_tenant, v_env, p_id, 1, p_json_schema, p_schema_digest, p_identifiers, p_example,
        p_actor_ref, now());
      PERFORM relay_private.audit_write(v_tenant, v_env::text, 'webhook_event_type.created',
        p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref,
        'webhook_event_type', p_id::text, NULL, p_record_digest);
      RETURN QUERY SELECT 'created'::text, p_id;
    END
    $fn$
    """
  end

  defp event_type_version_add do
    ~S"""
    CREATE FUNCTION relay_fn.webhook_event_type_version_add(p_event_type_id uuid,
      p_json_schema jsonb, p_schema_digest bytea, p_identifiers text[], p_example jsonb,
      p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
      p_access_record_ref text)
      RETURNS TABLE (result text, version bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_row relay.webhook_event_types;
      v_current relay.webhook_event_type_versions;
      v_next bigint;
    BEGIN
      IF p_event_type_id IS NULL OR p_json_schema IS NULL OR p_schema_digest IS NULL
        OR p_identifiers IS NULL OR p_record_digest IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WH-14';
      END IF;
      SELECT * INTO v_row FROM relay.webhook_event_types t
        WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.id = p_event_type_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
        RETURN;
      END IF;
      IF v_row.state = 'archived' THEN
        RETURN QUERY SELECT 'archived'::text, v_row.current_version;
        RETURN;
      END IF;
      SELECT * INTO v_current FROM relay.webhook_event_type_versions v
        WHERE v.tenant_id = v_tenant AND v.environment = v_env
          AND v.event_type_id = p_event_type_id AND v.version = v_row.current_version;
      IF v_current.schema_digest = p_schema_digest AND v_current.identifiers = p_identifiers
        AND v_current.example IS NOT DISTINCT FROM p_example THEN
        RETURN QUERY SELECT 'unchanged'::text, v_row.current_version;
        RETURN;
      END IF;
      v_next := v_row.current_version + 1;
      INSERT INTO relay.webhook_event_type_versions (tenant_id, environment, event_type_id,
        version, json_schema, schema_digest, identifiers, example, created_by_ref, created_at)
      VALUES (v_tenant, v_env, p_event_type_id, v_next, p_json_schema, p_schema_digest,
        p_identifiers, p_example, p_actor_ref, now());
      UPDATE relay.webhook_event_types t SET current_version = v_next, version = t.version + 1,
          updated_at = now()
        WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.id = p_event_type_id;
      PERFORM relay_private.audit_write(v_tenant, v_env::text,
        'webhook_event_type.version_added', p_actor_kind, p_actor_ref, p_on_behalf_of_ref,
        p_access_record_ref, 'webhook_event_type', p_event_type_id::text, NULL, p_record_digest);
      RETURN QUERY SELECT 'added'::text, v_next;
    END
    $fn$
    """
  end

  defp event_type_archive do
    ~S"""
    CREATE FUNCTION relay_fn.webhook_event_type_archive(p_event_type_id uuid,
      p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
      p_access_record_ref text)
      RETURNS TABLE (result text, version bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_row relay.webhook_event_types;
      v_version bigint;
    BEGIN
      IF p_event_type_id IS NULL OR p_record_digest IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WH-14';
      END IF;
      SELECT * INTO v_row FROM relay.webhook_event_types t
        WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.id = p_event_type_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
        RETURN;
      END IF;
      IF v_row.state = 'archived' THEN
        RETURN QUERY SELECT 'already_archived'::text, v_row.version;
        RETURN;
      END IF;
      UPDATE relay.webhook_event_types t SET state = 'archived', archived_at = now(),
          version = t.version + 1, updated_at = now()
        WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.id = p_event_type_id
        RETURNING t.version INTO v_version;
      PERFORM relay_private.audit_write(v_tenant, v_env::text, 'webhook_event_type.archived',
        p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref,
        'webhook_event_type', p_event_type_id::text, NULL, p_record_digest);
      RETURN QUERY SELECT 'archived'::text, v_version;
    END
    $fn$
    """
  end

  defp endpoint_create do
    ~S"""
    CREATE FUNCTION relay_fn.webhook_endpoint_create(p_id uuid, p_use_kind text,
      p_consumer_key text, p_kind text, p_url text, p_destination jsonb,
      p_credential_ref_id uuid, p_event_types text[], p_signature_scheme text, p_snapshot text[],
      p_description text, p_settings jsonb, p_payload_version text, p_key_id uuid,
      p_public_key bytea, p_secret_ct bytea, p_secret_key_id uuid, p_max_per_tenant bigint,
      p_max_per_consumer bigint, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
      p_on_behalf_of_ref text, p_access_record_ref text)
      RETURNS TABLE (result text, endpoint_id uuid)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_consumer relay.webhook_consumers;
      v_count bigint;
      v_schedule bigint[];
    BEGIN
      IF relay_private.tenant_status() <> 'active' THEN
        RETURN QUERY SELECT 'tenant_inactive'::text, NULL::uuid;
        RETURN;
      END IF;
      IF p_use_kind IS NULL OR p_kind IS NULL OR p_destination IS NULL OR p_event_types IS NULL
        OR p_snapshot IS NULL OR p_settings IS NULL OR jsonb_typeof(p_settings) <> 'object'
        OR p_payload_version IS NULL OR p_max_per_tenant IS NULL OR p_max_per_consumer IS NULL
        OR p_record_digest IS NULL OR (p_use_kind = 'destination') <> (p_consumer_key IS NOT NULL)
        OR (p_kind = 'https') <> (p_key_id IS NOT NULL)
        OR (p_kind = 'https') <> (p_secret_ct IS NOT NULL) THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WH-2';
      END IF;
      PERFORM relay_private.lock_scope(ARRAY['webhook_endpoints']);
      IF p_use_kind = 'destination' THEN
        SELECT * INTO v_consumer FROM relay.webhook_consumers c
          WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.key = p_consumer_key;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'consumer_not_found'::text, NULL::uuid;
          RETURN;
        END IF;
        IF v_consumer.state <> 'active' THEN
          RETURN QUERY SELECT 'consumer_archived'::text, NULL::uuid;
          RETURN;
        END IF;
        SELECT count(*) INTO v_count FROM relay.webhook_endpoints e
          WHERE e.tenant_id = v_tenant AND e.environment = v_env
            AND e.consumer_id = v_consumer.id AND e.state <> 'archived';
        IF v_count >= p_max_per_consumer THEN
          RETURN QUERY SELECT 'consumer_limit_reached'::text, NULL::uuid;
          RETURN;
        END IF;
        IF NOT relay_private.webhook_event_types_known(p_event_types) THEN
          RETURN QUERY SELECT 'event_type_not_found'::text, NULL::uuid;
          RETURN;
        END IF;
      ELSE
        SELECT count(*) INTO v_count FROM relay.webhook_endpoints e
          WHERE e.tenant_id = v_tenant AND e.environment = v_env
            AND e.use_kind = 'relay_events' AND e.managed_by = 'tenant'
            AND e.state <> 'archived';
        IF v_count >= p_max_per_tenant THEN
          RETURN QUERY SELECT 'tenant_limit_reached'::text, NULL::uuid;
          RETURN;
        END IF;
      END IF;
      IF p_credential_ref_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM relay.secret_refs s
        WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = p_credential_ref_id
          AND s.state = 'active') THEN
        RETURN QUERY SELECT 'credential_not_found'::text, NULL::uuid;
        RETURN;
      END IF;
      IF jsonb_typeof(p_settings -> 'retry_schedule') = 'array' THEN
        v_schedule := ARRAY(SELECT x::bigint
          FROM jsonb_array_elements_text(p_settings -> 'retry_schedule') WITH ORDINALITY AS a(x, n)
          ORDER BY a.n);
      END IF;
      PERFORM relay_private.assert_new_id(p_id);
      INSERT INTO relay.webhook_endpoints (tenant_id, environment, id, use_kind, consumer_id,
        kind, url, destination, credential_ref_id, event_types, signature_scheme, description,
        managed_by, product, state, auto_disable, retry_schedule, max_concurrency,
        rate_per_second, payload_version, current_version, version, created_at, updated_at)
      VALUES (v_tenant, v_env, p_id, p_use_kind, v_consumer.id, p_kind, p_url, p_destination,
        p_credential_ref_id, p_event_types, p_signature_scheme, p_description, 'tenant', NULL,
        'active', COALESCE((p_settings ->> 'auto_disable')::boolean, true), v_schedule,
        (p_settings ->> 'max_concurrency')::bigint, (p_settings ->> 'rate_per_second')::bigint,
        p_payload_version, 1, 1, now(), now());
      INSERT INTO relay.webhook_endpoint_versions (tenant_id, environment, endpoint_id, version,
        snapshot, payload_version, created_by_ref, created_at)
      VALUES (v_tenant, v_env, p_id, 1, p_snapshot, p_payload_version, p_actor_ref, now());
      INSERT INTO relay.webhook_endpoint_health (tenant_id, environment, endpoint_id, updated_at)
      VALUES (v_tenant, v_env, p_id, now());
      IF p_key_id IS NOT NULL THEN
        PERFORM relay_private.assert_new_id(p_key_id);
        INSERT INTO relay.webhook_endpoint_keys (tenant_id, environment, id, endpoint_id, scheme,
          state, public_key, secret_ct, secret_key_id, activated_at, created_at, updated_at)
        VALUES (v_tenant, v_env, p_key_id, p_id, p_signature_scheme, 'active', p_public_key,
          p_secret_ct, p_secret_key_id, now(), now(), now());
      END IF;
      PERFORM relay_private.audit_write(v_tenant, v_env::text, 'webhook_endpoint.created',
        p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'webhook_endpoint',
        p_id::text, NULL, p_record_digest);
      RETURN QUERY SELECT 'created'::text, p_id;
    END
    $fn$
    """
  end

  defp endpoint_update do
    ~S"""
    CREATE FUNCTION relay_fn.webhook_endpoint_update(p_endpoint_id uuid, p_expected_version bigint,
      p_changes jsonb, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
      p_on_behalf_of_ref text, p_access_record_ref text)
      RETURNS TABLE (result text, version bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_old relay.webhook_endpoints;
      v_new relay.webhook_endpoints;
      v_old_snapshot text[];
      v_snapshot text[];
      v_state text;
      v_action text;
      v_version bigint;
    BEGIN
      IF p_endpoint_id IS NULL OR p_changes IS NULL OR jsonb_typeof(p_changes) <> 'object'
        OR p_record_digest IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WH-2';
      END IF;
      SELECT * INTO v_old FROM relay.webhook_endpoints e
        WHERE e.tenant_id = v_tenant AND e.environment = v_env AND e.id = p_endpoint_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
        RETURN;
      END IF;
      IF v_old.state = 'archived' THEN
        RETURN QUERY SELECT 'archived'::text, v_old.version;
        RETURN;
      END IF;
      IF v_old.managed_by = 'product' AND (p_changes - 'event_types') <> '{}'::jsonb THEN
        RETURN QUERY SELECT 'managed'::text, v_old.version;
        RETURN;
      END IF;
      IF p_expected_version IS NOT NULL AND p_expected_version <> v_old.version THEN
        RETURN QUERY SELECT 'version_conflict'::text, v_old.version;
        RETURN;
      END IF;
      v_new := v_old;
      IF p_changes ? 'url' THEN
        v_new.url := p_changes ->> 'url';
      END IF;
      IF p_changes ? 'destination' THEN
        v_new.destination := p_changes -> 'destination';
      END IF;
      IF p_changes ? 'description' THEN
        v_new.description := p_changes ->> 'description';
      END IF;
      IF p_changes ? 'auto_disable' THEN
        v_new.auto_disable := (p_changes ->> 'auto_disable')::boolean;
      END IF;
      IF p_changes ? 'max_concurrency' THEN
        v_new.max_concurrency := (p_changes ->> 'max_concurrency')::bigint;
      END IF;
      IF p_changes ? 'rate_per_second' THEN
        v_new.rate_per_second := (p_changes ->> 'rate_per_second')::bigint;
      END IF;
      IF p_changes ? 'retry_schedule' THEN
        v_new.retry_schedule := CASE WHEN jsonb_typeof(p_changes -> 'retry_schedule') = 'array'
          THEN ARRAY(SELECT x::bigint
            FROM jsonb_array_elements_text(p_changes -> 'retry_schedule') WITH ORDINALITY AS a(x, n)
            ORDER BY a.n) END;
      END IF;
      IF p_changes ? 'event_types' THEN
        v_new.event_types := ARRAY(SELECT x
          FROM jsonb_array_elements_text(p_changes -> 'event_types') WITH ORDINALITY AS a(x, n)
          ORDER BY a.n);
        IF v_old.use_kind = 'destination'
          AND NOT relay_private.webhook_event_types_known(v_new.event_types) THEN
          RETURN QUERY SELECT 'event_type_not_found'::text, v_old.version;
          RETURN;
        END IF;
      END IF;
      IF p_changes ? 'credential_ref_id' THEN
        v_new.credential_ref_id := (p_changes ->> 'credential_ref_id')::uuid;
        IF v_new.credential_ref_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM relay.secret_refs s
          WHERE s.tenant_id = v_tenant AND s.environment = v_env
            AND s.id = v_new.credential_ref_id AND s.state = 'active') THEN
          RETURN QUERY SELECT 'credential_not_found'::text, v_old.version;
          RETURN;
        END IF;
      END IF;
      IF p_changes ? 'state' THEN
        v_state := p_changes ->> 'state';
        IF v_state NOT IN ('active', 'disabled') OR (v_state = 'active' AND v_old.state = 'paused')
        THEN
          RETURN QUERY SELECT 'invalid_state'::text, v_old.version;
          RETURN;
        END IF;
        IF v_state = 'disabled' AND v_old.state <> 'disabled' THEN
          v_new.state := 'disabled';
          v_new.disabled_at := now();
          v_new.disabled_reason := 'manual';
          v_new.paused_at := NULL;
        ELSIF v_state = 'active' AND v_old.state = 'disabled' THEN
          v_new.state := 'active';
          v_new.disabled_at := NULL;
          v_new.disabled_reason := NULL;
        END IF;
      END IF;
      SELECT v.snapshot INTO v_old_snapshot FROM relay.webhook_endpoint_versions v
        WHERE v.tenant_id = v_tenant AND v.environment = v_env AND v.endpoint_id = p_endpoint_id
          AND v.version = v_old.current_version;
      v_snapshot := v_old_snapshot;
      IF p_changes ? 'snapshot' THEN
        v_snapshot := ARRAY(SELECT x
          FROM jsonb_array_elements_text(p_changes -> 'snapshot') WITH ORDINALITY AS a(x, n)
          ORDER BY a.n);
      END IF;
      IF v_new IS NOT DISTINCT FROM v_old AND v_snapshot = v_old_snapshot THEN
        RETURN QUERY SELECT 'unchanged'::text, v_old.version;
        RETURN;
      END IF;
      IF v_snapshot <> v_old_snapshot THEN
        v_new.current_version := v_old.current_version + 1;
        INSERT INTO relay.webhook_endpoint_versions (tenant_id, environment, endpoint_id, version,
          snapshot, payload_version, created_by_ref, created_at)
        VALUES (v_tenant, v_env, p_endpoint_id, v_new.current_version, v_snapshot,
          v_old.payload_version, p_actor_ref, now());
      END IF;
      UPDATE relay.webhook_endpoints e SET url = v_new.url, destination = v_new.destination,
          description = v_new.description, auto_disable = v_new.auto_disable,
          max_concurrency = v_new.max_concurrency, rate_per_second = v_new.rate_per_second,
          retry_schedule = v_new.retry_schedule, event_types = v_new.event_types,
          credential_ref_id = v_new.credential_ref_id, state = v_new.state,
          disabled_at = v_new.disabled_at, disabled_reason = v_new.disabled_reason,
          paused_at = v_new.paused_at, current_version = v_new.current_version,
          version = e.version + 1, updated_at = now()
        WHERE e.tenant_id = v_tenant AND e.environment = v_env AND e.id = p_endpoint_id
        RETURNING e.version INTO v_version;
      IF v_old.state = 'disabled' AND v_new.state = 'active' THEN
        UPDATE relay.webhook_endpoint_health h SET breaker_state = 'closed',
            breaker_opened_at = NULL, breaker_open_seconds = NULL, breaker_retry_at = NULL,
            consecutive_failures = 0, failing_since = NULL, failure_count = 0, warned_at = NULL,
            version = h.version + 1, updated_at = now()
          WHERE h.tenant_id = v_tenant AND h.environment = v_env
            AND h.endpoint_id = p_endpoint_id;
      END IF;
      v_action := CASE WHEN v_old.auto_disable AND NOT v_new.auto_disable
        THEN 'webhook_endpoint.auto_disable_switched_off' ELSE 'webhook_endpoint.updated' END;
      PERFORM relay_private.audit_write(v_tenant, v_env::text, v_action, p_actor_kind,
        p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'webhook_endpoint',
        p_endpoint_id::text, NULL, p_record_digest);
      RETURN QUERY SELECT 'updated'::text, v_version;
    END
    $fn$
    """
  end

  defp endpoint_archive do
    ~S"""
    CREATE FUNCTION relay_fn.webhook_endpoint_archive(p_endpoint_id uuid, p_record_digest bytea,
      p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
      RETURNS TABLE (result text, version bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_row relay.webhook_endpoints;
      v_version bigint;
    BEGIN
      IF p_endpoint_id IS NULL OR p_record_digest IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WH-48';
      END IF;
      SELECT * INTO v_row FROM relay.webhook_endpoints e
        WHERE e.tenant_id = v_tenant AND e.environment = v_env AND e.id = p_endpoint_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
        RETURN;
      END IF;
      IF v_row.state = 'archived' THEN
        RETURN QUERY SELECT 'already_archived'::text, v_row.version;
        RETURN;
      END IF;
      IF v_row.managed_by = 'product' THEN
        RETURN QUERY SELECT 'managed'::text, v_row.version;
        RETURN;
      END IF;
      UPDATE relay.webhook_endpoints e SET state = 'archived', archived_at = now(),
          disabled_at = NULL, disabled_reason = NULL, paused_at = NULL,
          version = e.version + 1, updated_at = now()
        WHERE e.tenant_id = v_tenant AND e.environment = v_env AND e.id = p_endpoint_id
        RETURNING e.version INTO v_version;
      UPDATE relay.webhook_endpoint_keys k SET state = 'retired', secret_ct = NULL,
          superseded_at = COALESCE(k.superseded_at, now()), retired_at = now(), updated_at = now()
        WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.endpoint_id = p_endpoint_id
          AND k.state <> 'retired';
      PERFORM relay_private.audit_write(v_tenant, v_env::text, 'webhook_endpoint.archived',
        p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'webhook_endpoint',
        p_endpoint_id::text, NULL, p_record_digest);
      RETURN QUERY SELECT 'archived'::text, v_version;
    END
    $fn$
    """
  end

  defp key_rotate do
    ~S"""
    CREATE FUNCTION relay_fn.webhook_endpoint_key_rotate(p_endpoint_id uuid, p_key_id uuid,
      p_scheme text, p_public_key bytea, p_secret_ct bytea, p_secret_key_id uuid,
      p_overlap_seconds bigint, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
      p_on_behalf_of_ref text, p_access_record_ref text)
      RETURNS TABLE (result text, previous_key_id uuid, previous_expires_at timestamptz)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_row relay.webhook_endpoints;
      v_previous uuid;
      v_until timestamptz;
    BEGIN
      IF p_endpoint_id IS NULL OR p_key_id IS NULL OR p_scheme IS NULL OR p_secret_ct IS NULL
        OR p_secret_key_id IS NULL OR p_overlap_seconds IS NULL OR p_overlap_seconds < 0
        OR p_record_digest IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WH-6';
      END IF;
      SELECT * INTO v_row FROM relay.webhook_endpoints e
        WHERE e.tenant_id = v_tenant AND e.environment = v_env AND e.id = p_endpoint_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::timestamptz;
        RETURN;
      END IF;
      IF v_row.state = 'archived' THEN
        RETURN QUERY SELECT 'archived'::text, NULL::uuid, NULL::timestamptz;
        RETURN;
      END IF;
      IF v_row.managed_by = 'product' THEN
        RETURN QUERY SELECT 'managed'::text, NULL::uuid, NULL::timestamptz;
        RETURN;
      END IF;
      IF v_row.kind <> 'https' THEN
        RETURN QUERY SELECT 'not_signed'::text, NULL::uuid, NULL::timestamptz;
        RETURN;
      END IF;
      UPDATE relay.webhook_endpoint_keys k SET state = 'retired', secret_ct = NULL,
          retired_at = now(), updated_at = now()
        WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.endpoint_id = p_endpoint_id
          AND k.state = 'previous';
      IF p_overlap_seconds = 0 THEN
        UPDATE relay.webhook_endpoint_keys k SET state = 'retired', secret_ct = NULL,
            superseded_at = now(), retired_at = now(), updated_at = now()
          WHERE k.tenant_id = v_tenant AND k.environment = v_env
            AND k.endpoint_id = p_endpoint_id AND k.state = 'active'
          RETURNING k.id INTO v_previous;
      ELSE
        v_until := now() + p_overlap_seconds * interval '1 second';
        UPDATE relay.webhook_endpoint_keys k SET state = 'previous', superseded_at = now(),
            expires_at = v_until, updated_at = now()
          WHERE k.tenant_id = v_tenant AND k.environment = v_env
            AND k.endpoint_id = p_endpoint_id AND k.state = 'active'
          RETURNING k.id INTO v_previous;
      END IF;
      PERFORM relay_private.assert_new_id(p_key_id);
      INSERT INTO relay.webhook_endpoint_keys (tenant_id, environment, id, endpoint_id, scheme,
        state, public_key, secret_ct, secret_key_id, activated_at, created_at, updated_at)
      VALUES (v_tenant, v_env, p_key_id, p_endpoint_id, p_scheme, 'active', p_public_key,
        p_secret_ct, p_secret_key_id, now(), now(), now());
      UPDATE relay.webhook_endpoints e SET signature_scheme = p_scheme, version = e.version + 1,
          updated_at = now()
        WHERE e.tenant_id = v_tenant AND e.environment = v_env AND e.id = p_endpoint_id;
      PERFORM relay_private.audit_write(v_tenant, v_env::text, 'webhook_endpoint.key_rotated',
        p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'webhook_endpoint',
        p_endpoint_id::text, NULL, p_record_digest);
      RETURN QUERY SELECT 'rotated'::text, v_previous, v_until;
    END
    $fn$
    """
  end

  defp keys_expire do
    ~S"""
    CREATE FUNCTION relay_fn.webhook_endpoint_keys_expire() RETURNS bigint
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_count bigint;
    BEGIN
      UPDATE relay.webhook_endpoint_keys k SET state = 'retired', secret_ct = NULL,
          retired_at = now(), updated_at = now()
        WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.state = 'previous'
          AND k.expires_at <= now();
      GET DIAGNOSTICS v_count = ROW_COUNT;
      RETURN v_count;
    END
    $fn$
    """
  end

  defp contacts_replace do
    ~S"""
    CREATE FUNCTION relay_fn.operations_contacts_replace(p_ids uuid[], p_address_cts bytea[],
      p_address_key_id uuid, p_max bigint, p_record_digest bytea, p_actor_kind text,
      p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
      RETURNS TABLE (result text, active bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
    BEGIN
      IF relay_private.tenant_status() <> 'active' THEN
        RETURN QUERY SELECT 'tenant_inactive'::text, NULL::bigint;
        RETURN;
      END IF;
      IF p_ids IS NULL OR p_address_cts IS NULL OR p_max IS NULL OR p_record_digest IS NULL
        OR cardinality(p_ids) <> cardinality(p_address_cts) OR cardinality(p_ids) > p_max
        OR (cardinality(p_ids) > 0 AND p_address_key_id IS NULL) THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WH-56';
      END IF;
      PERFORM relay_private.lock_scope(ARRAY['operations_contacts']);
      UPDATE relay.operations_contacts c SET state = 'removed', address_ct = NULL,
          removed_at = now(), updated_at = now()
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.state = 'active';
      FOR i IN 1 .. cardinality(p_ids) LOOP
        PERFORM relay_private.assert_new_id(p_ids[i]);
        INSERT INTO relay.operations_contacts (tenant_id, environment, id, address_ct,
          address_key_id, state, removed_at, created_at, updated_at)
        VALUES (v_tenant, v_env, p_ids[i], p_address_cts[i], p_address_key_id, 'active', NULL,
          now(), now());
      END LOOP;
      PERFORM relay_private.audit_write(v_tenant, v_env::text, 'operations_contacts.replaced',
        p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref,
        'operations_contacts', NULL, NULL, p_record_digest);
      RETURN QUERY SELECT 'replaced'::text, cardinality(p_ids)::bigint;
    END
    $fn$
    """
  end
end
