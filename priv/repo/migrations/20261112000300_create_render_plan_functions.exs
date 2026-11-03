defmodule Relay.Repo.Migrations.CreateRenderPlanFunctions do
  use Ecto.Migration

  @functions [
    {"relay_fn.delivery_plan_pin(uuid, uuid, uuid, uuid[], text, boolean)", ~w(relay_app)},
    {"relay_fn.delivery_render_policy(uuid)", ~w(relay_app relay_report)},
    {"relay_fn.delivery_render_record(uuid, bytea, jsonb, bytea, uuid)", ~w(relay_app)},
    {"relay_fn.delivery_render_fail(uuid, text, jsonb)", ~w(relay_app)}
  ]

  # TP-35
  # TP-40
  # TP-41
  # TP-49
  # TP-50
  # API-26
  # INV-26
  # INV-46
  # INV-48
  # OP-8
  def up do
    Enum.each(statements(), &execute/1)

    for {signature, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      execute("ALTER FUNCTION #{signature} OWNER TO relay_owner")
    end
  end

  def down do
    for {signature, _grantees} <- Enum.reverse(@functions),
        do: execute("DROP FUNCTION #{signature}")
  end

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_fn.delivery_plan_pin(p_delivery_id uuid, p_template_version_id uuid,
        p_layout_version_id uuid, p_partial_version_ids uuid[], p_locale text,
        p_locale_fallback boolean)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_version relay.template_versions;
        v_partials uuid[] := COALESCE(p_partial_version_ids, '{}'::uuid[]);
      BEGIN
        IF p_template_version_id IS NULL OR p_locale IS NULL
          OR p_locale !~ '^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$' OR char_length(p_locale) > 35
          OR p_locale_fallback IS NULL OR cardinality(v_partials) > 50
          OR array_position(v_partials, NULL) IS NOT NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TP-50';
        END IF;
        PERFORM 1 FROM relay.deliveries d
          WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_delivery_id
          FOR SHARE;
        IF NOT FOUND THEN
          RETURN 'delivery_not_found';
        END IF;
        IF EXISTS (SELECT 1 FROM relay.delivery_render_plans p
          WHERE p.tenant_id = v_tenant AND p.environment = v_env
            AND p.delivery_id = p_delivery_id) THEN
          RETURN 'exists';
        END IF;
        SELECT * INTO v_version FROM relay.template_versions v
          WHERE v.tenant_id = v_tenant AND v.environment = v_env AND v.id = p_template_version_id;
        IF NOT FOUND OR v_version.state <> 'published' THEN
          RETURN 'version_not_published';
        END IF;
        IF p_layout_version_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM relay.layout_versions l
          WHERE l.tenant_id = v_tenant AND l.environment = v_env AND l.id = p_layout_version_id
            AND l.state = 'published') THEN
          RETURN 'layout_not_published';
        END IF;
        IF (SELECT count(*) FROM relay.partial_versions p
          WHERE p.tenant_id = v_tenant AND p.environment = v_env AND p.id = ANY (v_partials)
            AND p.state = 'published') <> cardinality(ARRAY(SELECT DISTINCT unnest(v_partials)))
        THEN
          RETURN 'partial_not_published';
        END IF;
        INSERT INTO relay.delivery_render_plans (tenant_id, environment, delivery_id, template_id,
          template_version_id, layout_version_id, partial_version_ids, locale, locale_fallback,
          render_digest, render_measures, rendered_at, render_count, created_at, updated_at)
        VALUES (v_tenant, v_env, p_delivery_id, v_version.template_id, p_template_version_id,
          p_layout_version_id, v_partials, p_locale, p_locale_fallback, NULL, NULL, NULL, 0, now(),
          now());
        RETURN 'pinned';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.delivery_render_policy(p_delivery_id uuid)
        RETURNS TABLE (result text, digest_reason text, retention_class text,
          recipient_id uuid, content_key_id uuid)
      LANGUAGE sql STABLE SECURITY INVOKER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT CASE WHEN d.id IS NULL THEN 'not_found' ELSE 'ok' END,
          CASE WHEN n.security_subtype IS NOT NULL THEN 'security_subtype'
            WHEN e.retention_none THEN 'retention_none' END,
          CASE WHEN d.id IS NULL THEN NULL WHEN n.message_class = 'marketing'
            THEN 'commercial_message' ELSE 'notification_content' END,
          n.recipient_id,
          k.id
        FROM (SELECT p_delivery_id AS id) q
        LEFT JOIN relay.deliveries d ON d.tenant_id = relay_private.ctx_tenant_id()
          AND d.environment = relay_private.ctx_environment() AND d.id = q.id
        LEFT JOIN relay.notifications n ON n.tenant_id = d.tenant_id
          AND n.environment = d.environment AND n.id = d.notification_id
        LEFT JOIN relay.events e ON e.tenant_id = n.tenant_id AND e.environment = n.environment
          AND e.id = n.event_id
        LEFT JOIN relay.subject_keys k ON k.tenant_id = n.tenant_id
          AND k.environment = n.environment AND k.recipient_id = n.recipient_id
          AND k.state = 'active'
          AND k.retention_class = CASE WHEN n.message_class = 'marketing'
            THEN 'commercial_message' ELSE 'notification_content' END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.delivery_render_record(p_delivery_id uuid, p_digest bytea,
        p_measures jsonb, p_content_ct bytea, p_content_key_id uuid)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_delivery relay.deliveries;
        v_plan relay.delivery_render_plans;
        v_notification relay.notifications;
        v_retention_none boolean;
        v_reason text;
        v_class text;
      BEGIN
        IF p_digest IS NULL OR octet_length(p_digest) <> 32 OR p_measures IS NULL
          OR jsonb_typeof(p_measures) <> 'object'
          OR (p_content_ct IS NULL) <> (p_content_key_id IS NULL) THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TP-50';
        END IF;
        SELECT * INTO v_delivery FROM relay.deliveries d
          WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_delivery_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'delivery_not_found';
        END IF;
        IF v_delivery.failure_kind IS NOT NULL THEN
          RETURN 'already_terminal';
        END IF;
        SELECT * INTO v_plan FROM relay.delivery_render_plans p
          WHERE p.tenant_id = v_tenant AND p.environment = v_env AND p.delivery_id = p_delivery_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'plan_not_found';
        END IF;
        IF v_plan.render_digest IS NOT NULL THEN
          UPDATE relay.delivery_render_plans p SET render_count = p.render_count + 1,
              updated_at = now()
            WHERE p.tenant_id = v_tenant AND p.environment = v_env
              AND p.delivery_id = p_delivery_id;
          IF v_plan.render_digest = p_digest THEN
            RETURN 'matched';
          END IF;
          RETURN 'digest_mismatch';
        END IF;
        SELECT * INTO v_notification FROM relay.notifications n
          WHERE n.tenant_id = v_tenant AND n.environment = v_env
            AND n.id = v_delivery.notification_id;
        SELECT e.retention_none INTO v_retention_none FROM relay.events e
          WHERE e.tenant_id = v_tenant AND e.environment = v_env AND e.id = v_notification.event_id;
        v_reason := CASE WHEN v_notification.security_subtype IS NOT NULL THEN 'security_subtype'
          WHEN COALESCE(v_retention_none, false) THEN 'retention_none' END;
        v_class := CASE WHEN v_notification.message_class = 'marketing' THEN 'commercial_message'
          ELSE 'notification_content' END;
        IF v_reason IS NOT NULL AND p_content_ct IS NOT NULL THEN
          RETURN 'content_not_allowed';
        END IF;
        IF v_reason IS NULL AND p_content_ct IS NULL THEN
          RETURN 'content_required';
        END IF;
        IF v_reason IS NULL AND NOT EXISTS (SELECT 1 FROM relay.subject_keys k
          WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.id = p_content_key_id
            AND k.recipient_id = v_notification.recipient_id AND k.retention_class = v_class
            AND k.state = 'active') THEN
          RETURN 'key_invalid';
        END IF;
        UPDATE relay.delivery_render_plans p SET render_digest = p_digest,
            render_measures = p_measures, rendered_at = now(), render_count = p.render_count + 1,
            updated_at = now()
          WHERE p.tenant_id = v_tenant AND p.environment = v_env AND p.delivery_id = p_delivery_id;
        INSERT INTO relay.render_snapshots (tenant_id, environment, delivery_id, recipient_id,
          template_version_id, retention_class, content_digest, content_ct, content_key_id,
          digest_reason, created_at)
        VALUES (v_tenant, v_env, p_delivery_id, v_notification.recipient_id,
          v_plan.template_version_id, v_class, p_digest, p_content_ct, p_content_key_id, v_reason,
          now());
        RETURN 'recorded';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.delivery_render_fail(p_delivery_id uuid, p_failure_reason text,
        p_detail jsonb)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_delivery relay.deliveries;
        v_notification relay.notifications;
        v_workflow jsonb;
        v_template jsonb;
        v_detail jsonb;
      BEGIN
        IF p_failure_reason IS NULL OR p_failure_reason NOT IN ('missing_variable',
          'render_timeout', 'output_too_large', 'schema_violation')
          OR (p_detail IS NOT NULL AND jsonb_typeof(p_detail) <> 'object') THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TP-41';
        END IF;
        SELECT * INTO v_delivery FROM relay.deliveries d
          WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_delivery_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_delivery.failure_kind IS NOT NULL OR v_delivery.delivery_rank > 0 THEN
          RETURN 'already_terminal';
        END IF;
        SELECT * INTO v_notification FROM relay.notifications n
          WHERE n.tenant_id = v_tenant AND n.environment = v_env
            AND n.id = v_delivery.notification_id;
        SELECT jsonb_build_object('key', w.key, 'version', v.version_no) INTO v_workflow
          FROM relay.workflows w
          JOIN relay.workflow_versions v ON v.tenant_id = w.tenant_id
            AND v.environment = w.environment AND v.workflow_id = w.id
          WHERE w.tenant_id = v_tenant AND w.environment = v_env
            AND w.id = v_notification.workflow_id AND v.id = v_notification.workflow_version_id;
        SELECT jsonb_build_object('key', t.key, 'version', v.version_no) INTO v_template
          FROM relay.delivery_render_plans p
          JOIN relay.template_versions v ON v.tenant_id = p.tenant_id
            AND v.environment = p.environment AND v.id = p.template_version_id
          JOIN relay.templates t ON t.tenant_id = v.tenant_id AND t.environment = v.environment
            AND t.id = v.template_id
          WHERE p.tenant_id = v_tenant AND p.environment = v_env
            AND p.delivery_id = p_delivery_id;
        v_detail := COALESCE(p_detail, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object(
          'failure_reason', p_failure_reason, 'template', v_template));
        PERFORM relay_private.ledger_record(uuidv7(), v_delivery,
          NULLIF(v_delivery.attempt_count, 0), 'relay', 'delivery.render_failed', NULL, NULL,
          NULL, now(), NULL, NULL, 'failed', 'permanent_content', NULL, p_failure_reason, NULL,
          v_detail, v_delivery.traceparent);
        PERFORM relay_fn.outbox_append(uuidv7(), 'notification.render_failed',
          'delivery:' || p_delivery_id::text,
          jsonb_strip_nulls(jsonb_build_object('notification_id', v_delivery.notification_id,
            'delivery_id', p_delivery_id, 'recipient_id', v_notification.recipient_id,
            'workflow', v_workflow, 'template', v_template,
            'tenant', v_notification.subtenant_id, 'channel', v_delivery.channel,
            'failure_reason', p_failure_reason)),
          v_delivery.traceparent);
        RETURN 'failed';
      END
      $fn$
      """
    ]
  end
end
