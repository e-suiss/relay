defmodule Relay.Repo.Migrations.CreateWebhookSourceFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"

  @functions [
    {"relay_fn.webhook_source_create(uuid, text, text, bytea, uuid, bigint, bytea, #{@actor})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.webhook_source_archive(uuid, bytea, #{@actor})", "relay_owner", ~w(relay_app)}
  ]

  # WH-68
  # TN-26
  # OP-8
  def up do
    execute(create())
    execute(archive())

    for {signature, owner, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
    end
  end

  def down, do: :ok

  defp create do
    ~S"""
    CREATE FUNCTION relay_fn.webhook_source_create(p_id uuid, p_name text, p_scheme text,
      p_public_key bytea, p_secret_ref_id uuid, p_limit bigint, p_record_digest bytea,
      p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
      RETURNS TABLE (result text, source_id uuid)
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
        RETURN QUERY SELECT 'tenant_inactive'::text, NULL::uuid;
        RETURN;
      END IF;
      IF p_name IS NULL OR p_scheme IS NULL OR p_scheme NOT IN ('v1a', 'v1')
        OR (p_scheme = 'v1a') <> (p_public_key IS NOT NULL)
        OR (p_scheme = 'v1') <> (p_secret_ref_id IS NOT NULL)
        OR p_limit IS NULL OR p_limit < 1 OR p_record_digest IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WH-68';
      END IF;
      PERFORM relay_private.lock_scope(ARRAY['webhook_sources']);
      IF p_secret_ref_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM relay.secret_refs s
        WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = p_secret_ref_id
          AND s.kind = 'webhook_signing' AND s.state = 'active') THEN
        RETURN QUERY SELECT 'secret_not_found'::text, NULL::uuid;
        RETURN;
      END IF;
      IF (SELECT count(*) FROM relay.webhook_sources w
        WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.state = 'active')
          >= p_limit THEN
        RETURN QUERY SELECT 'limit_reached'::text, NULL::uuid;
        RETURN;
      END IF;
      PERFORM relay_private.assert_new_id(p_id);
      INSERT INTO relay.webhook_sources (tenant_id, environment, id, name, scheme, public_key,
        secret_ref_id, state, archived_at, created_at, updated_at)
      VALUES (v_tenant, v_env, p_id, p_name, p_scheme, p_public_key, p_secret_ref_id, 'active',
        NULL, now(), now());
      PERFORM relay_private.audit_write(v_tenant, v_env::text, 'webhook_source.created',
        p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'webhook_source',
        p_id::text, NULL, p_record_digest);
      RETURN QUERY SELECT 'created'::text, p_id;
    END
    $fn$
    """
  end

  defp archive do
    ~S"""
    CREATE FUNCTION relay_fn.webhook_source_archive(p_source_id uuid, p_record_digest bytea,
      p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_state text;
    BEGIN
      IF p_source_id IS NULL OR p_record_digest IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WH-68';
      END IF;
      SELECT w.state INTO v_state FROM relay.webhook_sources w
        WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_source_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      IF v_state = 'archived' THEN
        RETURN 'already_archived';
      END IF;
      UPDATE relay.webhook_sources w SET state = 'archived', archived_at = now(),
          updated_at = now()
        WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_source_id;
      PERFORM relay_private.audit_write(v_tenant, v_env::text, 'webhook_source.archived',
        p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'webhook_source',
        p_source_id::text, NULL, p_record_digest);
      RETURN 'archived';
    END
    $fn$
    """
  end
end
