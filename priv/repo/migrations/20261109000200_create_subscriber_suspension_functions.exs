defmodule Relay.Repo.Migrations.CreateSubscriberSuspensionFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"

  @functions [
    {"relay_fn.recipient_suspend(uuid, text, bytea, #{@actor})", "relay_owner", ~w(relay_app)},
    {"relay_fn.recipient_resume(uuid, text, bytea, #{@actor})", "relay_owner", ~w(relay_app)},
    {"relay_ops.subscriber_tenants(uuid, integer)", "relay_migrator", ~w(relay_worker)}
  ]

  # TN-73
  # TN-22
  # TN-40
  # TN-47
  # OP-8
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
      CREATE FUNCTION relay_fn.recipient_suspend(p_recipient_id uuid, p_reason text,
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
        v_recipient relay.recipients;
        v_version bigint;
      BEGIN
        IF p_recipient_id IS NULL OR p_actor_ref IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-73';
        END IF;
        SELECT * INTO v_recipient FROM relay.recipients r
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_recipient_id
          FOR NO KEY UPDATE;
        IF NOT FOUND OR v_recipient.kind <> 'subscriber' OR v_recipient.state = 'deleted' THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
          RETURN;
        END IF;
        IF v_recipient.suspended_at IS NOT NULL THEN
          RETURN QUERY SELECT 'already_suspended'::text, v_recipient.version;
          RETURN;
        END IF;
        UPDATE relay.recipients r SET suspended_at = now(), version = r.version + 1,
            updated_at = now()
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_recipient_id
          RETURNING r.version INTO v_version;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'subscriber.suspended',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'recipient',
          p_recipient_id::text, p_reason, p_record_digest);
        RETURN QUERY SELECT 'suspended'::text, v_version;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.recipient_resume(p_recipient_id uuid, p_reason text,
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
        v_recipient relay.recipients;
        v_version bigint;
      BEGIN
        IF p_recipient_id IS NULL OR p_actor_ref IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-73';
        END IF;
        SELECT * INTO v_recipient FROM relay.recipients r
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_recipient_id
          FOR NO KEY UPDATE;
        IF NOT FOUND OR v_recipient.kind <> 'subscriber' OR v_recipient.state = 'deleted' THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
          RETURN;
        END IF;
        IF v_recipient.suspended_at IS NULL THEN
          RETURN QUERY SELECT 'not_suspended'::text, v_recipient.version;
          RETURN;
        END IF;
        UPDATE relay.recipients r SET suspended_at = NULL, version = r.version + 1,
            updated_at = now()
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_recipient_id
          RETURNING r.version INTO v_version;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'subscriber.resumed',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'recipient',
          p_recipient_id::text, p_reason, p_record_digest);
        RETURN QUERY SELECT 'resumed'::text, v_version;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.subscriber_tenants(p_after_id uuid, p_limit integer)
        RETURNS TABLE (tenant_id uuid)
      LANGUAGE sql STABLE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT t.id
        FROM relay.tenants t
        WHERE t.status IN ('active', 'suspended')
          AND (p_after_id IS NULL OR t.id > p_after_id)
        ORDER BY t.id
        LIMIT least(greatest(coalesce(p_limit, 100), 1), 1000)
      $fn$
      """
    ]
  end
end
