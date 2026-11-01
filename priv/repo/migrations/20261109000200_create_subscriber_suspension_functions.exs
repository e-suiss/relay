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
  # MD-12
  # OP-8
  def up do
    Enum.each(statements(), &execute/1)

    for {signature, owner, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      if owner == "relay_owner", do: execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
    end

    execute("SET LOCAL ROLE relay_owner")
    execute(notification_accept())
    execute(recipient_deletion_complete())
    execute("RESET ROLE")
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
        UPDATE relay.recipients r SET suspended_at = now(),
            state = CASE WHEN r.state = 'active' THEN 'suspended' ELSE r.state END,
            version = r.version + 1, updated_at = now()
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
        UPDATE relay.recipients r SET suspended_at = NULL,
            state = CASE WHEN r.state = 'suspended' THEN 'active' ELSE r.state END,
            version = r.version + 1, updated_at = now()
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

  defp notification_accept do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_fn.notification_accept(p_id uuid, p_recipient_id uuid,
      p_subtenant_id uuid, p_dedup_key text, p_message_class text, p_security_subtype text,
      p_sender_type text, p_subject_type text, p_subject_id text, p_expires_at timestamptz,
      p_is_test boolean, p_traceparent text, p_event_id uuid DEFAULT NULL,
      p_workflow_id uuid DEFAULT NULL, p_workflow_version_id uuid DEFAULT NULL)
      RETURNS TABLE (result text, notification_id uuid, original_event_id uuid)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_id uuid;
      v_event uuid;
    BEGIN
      IF relay_private.tenant_status() <> 'active' THEN
        RETURN QUERY SELECT 'tenant_inactive'::text, NULL::uuid, NULL::uuid;
        RETURN;
      END IF;
      PERFORM relay_private.assert_new_id(p_id);
      IF p_dedup_key IS NULL OR char_length(p_dedup_key) NOT BETWEEN 1 AND 512
        OR p_message_class IS NULL OR p_sender_type IS NULL OR p_is_test IS NULL
        OR (p_event_id IS NULL) <> (p_workflow_id IS NULL)
        OR (p_workflow_id IS NULL) <> (p_workflow_version_id IS NULL) THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'C-29';
      END IF;
      IF NOT EXISTS (SELECT 1 FROM relay.recipients r
        WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_recipient_id
          AND r.state IN ('active', 'suspended')) THEN
        RETURN QUERY SELECT 'recipient_not_found'::text, NULL::uuid, NULL::uuid;
        RETURN;
      END IF;
      IF p_subtenant_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM relay.subtenants s
        WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = p_subtenant_id
          AND s.state = 'active') THEN
        RETURN QUERY SELECT 'subtenant_not_found'::text, NULL::uuid, NULL::uuid;
        RETURN;
      END IF;
      INSERT INTO relay.notifications AS n (tenant_id, environment, id, recipient_id,
        subtenant_id, dedup_key, message_class, security_subtype, sender_type, subject_type,
        subject_id, expires_at, is_test, state, closed_at, close_rule_id, duplicate_count,
        last_duplicate_at, traceparent, event_id, workflow_id, workflow_version_id, created_at,
        updated_at)
      VALUES (v_tenant, v_env, p_id, p_recipient_id, p_subtenant_id, p_dedup_key,
        p_message_class, p_security_subtype, p_sender_type, p_subject_type, p_subject_id,
        p_expires_at, p_is_test, 'active', NULL, NULL, 0, NULL, p_traceparent, p_event_id,
        p_workflow_id, p_workflow_version_id, now(), now())
      ON CONFLICT (tenant_id, environment, dedup_key, recipient_id) DO NOTHING
      RETURNING n.id INTO v_id;
      IF v_id IS NOT NULL THEN
        RETURN QUERY SELECT 'created'::text, v_id, p_event_id;
        RETURN;
      END IF;
      UPDATE relay.notifications n SET duplicate_count = n.duplicate_count + 1,
          last_duplicate_at = now(), updated_at = now()
        WHERE n.tenant_id = v_tenant AND n.environment = v_env AND n.dedup_key = p_dedup_key
          AND n.recipient_id = p_recipient_id
        RETURNING n.id, n.event_id INTO v_id, v_event;
      RETURN QUERY SELECT 'duplicate'::text, v_id, v_event;
    END
    $fn$
    """
  end

  defp recipient_deletion_complete do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_fn.recipient_deletion_complete(p_request_id uuid,
      p_erasure_id uuid)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_request relay.recipient_deletion_requests;
    BEGIN
      SELECT * INTO v_request FROM relay.recipient_deletion_requests q
        WHERE q.tenant_id = v_tenant AND q.environment = v_env AND q.id = p_request_id
        FOR UPDATE;
      IF NOT FOUND OR v_request.status <> 'pending' THEN
        RETURN 'not_pending';
      END IF;
      IF p_erasure_id IS NULL THEN
        UPDATE relay.recipient_deletion_requests q SET status = 'held', updated_at = now()
          WHERE q.tenant_id = v_tenant AND q.environment = v_env AND q.id = p_request_id;
        UPDATE relay.recipients r
          SET state = CASE WHEN r.suspended_at IS NULL THEN 'active' ELSE 'suspended' END,
            version = r.version + 1, updated_at = now()
          WHERE r.tenant_id = v_tenant AND r.environment = v_env
            AND r.id = v_request.recipient_id AND r.state = 'deletion_requested';
        RETURN 'held';
      END IF;
      UPDATE relay.recipient_deletion_requests q SET status = 'completed',
          erasure_id = p_erasure_id, completed_at = now(), updated_at = now()
        WHERE q.tenant_id = v_tenant AND q.environment = v_env AND q.id = p_request_id;
      RETURN 'completed';
    END
    $fn$
    """
  end
end
