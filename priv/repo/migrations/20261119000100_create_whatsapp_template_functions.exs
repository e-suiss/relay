defmodule Relay.Repo.Migrations.CreateWhatsappTemplateFunctions do
  use Ecto.Migration

  @time "timestamp with time zone"

  @functions [
    {"relay_fn.whatsapp_template_register(uuid, uuid, text, text, text, text, text, jsonb, bytea)",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.whatsapp_template_status(uuid, text, text, text, text, text, text, bigint)",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.whatsapp_template_category(uuid, text, text, text)", "relay_owner", ~w(relay_app)},
    {"relay_fn.whatsapp_template_edit(uuid, text, text, jsonb, #{@time})", "relay_owner",
     ~w(relay_app)}
  ]

  # CH-57
  # TP-23
  def up do
    Enum.each(statements(), &execute/1)

    for {signature, owner, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
    end
  end

  def down, do: :ok

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_fn.whatsapp_template_register(p_id uuid, p_provider_account_id uuid,
        p_waba_id text, p_name text, p_language text, p_message_class text, p_category text,
        p_components jsonb, p_content_digest bytea)
        RETURNS TABLE (result text, template_id uuid)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.whatsapp_templates;
      BEGIN
        IF p_provider_account_id IS NULL OR p_waba_id IS NULL OR p_name IS NULL
          OR p_language IS NULL OR p_message_class IS NULL OR p_category IS NULL
          OR p_components IS NULL OR p_content_digest IS NULL
          OR octet_length(p_content_digest) <> 32 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'CH-57';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM relay.provider_accounts a
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = p_provider_account_id
            AND a.channel = 'whatsapp' AND a.state = 'active') THEN
          RETURN QUERY SELECT 'account_not_found'::text, NULL::uuid;
          RETURN;
        END IF;
        SELECT * INTO v_row FROM relay.whatsapp_templates t
          WHERE t.tenant_id = v_tenant AND t.environment = v_env
            AND t.provider_account_id = p_provider_account_id AND t.name = p_name
            AND t.language = p_language
          FOR UPDATE;
        IF FOUND THEN
          IF v_row.content_digest = p_content_digest AND v_row.message_class = p_message_class
            AND v_row.waba_id = p_waba_id THEN
            RETURN QUERY SELECT 'exists'::text, v_row.id;
          ELSE
            RETURN QUERY SELECT 'content_conflict'::text, v_row.id;
          END IF;
          RETURN;
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        INSERT INTO relay.whatsapp_templates (tenant_id, environment, id, provider_account_id,
          waba_id, name, language, message_class, category, meta_category, status, meta_status,
          meta_template_id, rejection_reason, quality, components, approved_components,
          content_digest, edits, status_changed_at, version, created_at, updated_at)
        VALUES (v_tenant, v_env, p_id, p_provider_account_id, p_waba_id, p_name, p_language,
          p_message_class, p_category, NULL, 'pending_approval', NULL, NULL, NULL, NULL,
          p_components, NULL, p_content_digest, '{}', now(), 1, now(), now());
        RETURN QUERY SELECT 'created'::text, p_id;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.whatsapp_template_status(p_provider_account_id uuid, p_name text,
        p_language text, p_meta_template_id text, p_meta_status text, p_status text,
        p_reason text, p_expected_version bigint)
        RETURNS TABLE (result text, template_id uuid, previous_status text)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.whatsapp_templates;
      BEGIN
        IF p_provider_account_id IS NULL OR p_name IS NULL OR p_language IS NULL
          OR p_status IS NULL OR p_expected_version IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TP-23';
        END IF;
        SELECT * INTO v_row FROM relay.whatsapp_templates t
          WHERE t.tenant_id = v_tenant AND t.environment = v_env
            AND t.provider_account_id = p_provider_account_id AND t.name = p_name
            AND t.language = p_language
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text;
          RETURN;
        END IF;
        IF v_row.version <> p_expected_version THEN
          RETURN QUERY SELECT 'version_conflict'::text, v_row.id, v_row.status;
          RETURN;
        END IF;
        IF v_row.status = p_status
          AND v_row.meta_status IS NOT DISTINCT FROM p_meta_status
          AND v_row.meta_template_id IS NOT DISTINCT FROM
            coalesce(p_meta_template_id, v_row.meta_template_id) THEN
          RETURN QUERY SELECT 'unchanged'::text, v_row.id, v_row.status;
          RETURN;
        END IF;
        UPDATE relay.whatsapp_templates t SET status = p_status, meta_status = p_meta_status,
            meta_template_id = coalesce(p_meta_template_id, t.meta_template_id),
            rejection_reason = CASE WHEN p_status = 'rejected'
              THEN left(coalesce(p_reason, 'NONE'), 512) END,
            approved_components = CASE WHEN p_status = 'approved'
              THEN coalesce(t.approved_components, t.components) ELSE t.approved_components END,
            status_changed_at = CASE WHEN t.status <> p_status THEN now()
              ELSE t.status_changed_at END,
            version = t.version + 1, updated_at = now()
          WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.id = v_row.id;
        IF v_row.status <> p_status THEN
          PERFORM relay_fn.outbox_append(uuidv7(), 'whatsapp_template.status_changed',
            'whatsapp_template:' || v_row.id::text,
            jsonb_build_object('whatsapp_template_id', v_row.id, 'name', v_row.name,
              'language', v_row.language, 'previous_status', v_row.status,
              'status', p_status, 'meta_status', p_meta_status,
              'rejection_reason', CASE WHEN p_status = 'rejected'
                THEN left(coalesce(p_reason, 'NONE'), 512) END),
            NULL);
          RETURN QUERY SELECT 'changed'::text, v_row.id, v_row.status;
          RETURN;
        END IF;
        RETURN QUERY SELECT 'recorded'::text, v_row.id, v_row.status;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.whatsapp_template_category(p_provider_account_id uuid,
        p_name text, p_language text, p_meta_category text)
        RETURNS TABLE (result text, template_id uuid)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.whatsapp_templates;
      BEGIN
        IF p_provider_account_id IS NULL OR p_name IS NULL OR p_language IS NULL
          OR p_meta_category IS NULL
          OR p_meta_category NOT IN ('authentication', 'utility', 'marketing') THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'CH-57';
        END IF;
        SELECT * INTO v_row FROM relay.whatsapp_templates t
          WHERE t.tenant_id = v_tenant AND t.environment = v_env
            AND t.provider_account_id = p_provider_account_id AND t.name = p_name
            AND t.language = p_language
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::uuid;
          RETURN;
        END IF;
        IF v_row.meta_category IS NOT DISTINCT FROM p_meta_category THEN
          RETURN QUERY SELECT 'unchanged'::text, v_row.id;
          RETURN;
        END IF;
        UPDATE relay.whatsapp_templates t SET meta_category = p_meta_category,
            version = t.version + 1, updated_at = now()
          WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.id = v_row.id;
        IF p_meta_category = v_row.category THEN
          RETURN QUERY SELECT 'aligned'::text, v_row.id;
          RETURN;
        END IF;
        PERFORM relay_fn.outbox_append(uuidv7(), 'whatsapp_template.category_changed',
          'whatsapp_template:' || v_row.id::text,
          jsonb_build_object('whatsapp_template_id', v_row.id, 'name', v_row.name,
            'language', v_row.language, 'message_class', v_row.message_class,
            'category', v_row.category,
            'previous_category', coalesce(v_row.meta_category, v_row.category),
            'new_category', p_meta_category),
          NULL);
        RETURN QUERY SELECT 'drifted'::text, v_row.id;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.whatsapp_template_edit(p_provider_account_id uuid, p_name text,
        p_language text, p_components jsonb, p_edited_at timestamptz)
        RETURNS TABLE (result text, template_id uuid)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.whatsapp_templates;
      BEGIN
        IF p_provider_account_id IS NULL OR p_name IS NULL OR p_language IS NULL
          OR p_edited_at IS NULL
          OR (p_components IS NOT NULL AND jsonb_typeof(p_components) <> 'array') THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TP-23';
        END IF;
        SELECT * INTO v_row FROM relay.whatsapp_templates t
          WHERE t.tenant_id = v_tenant AND t.environment = v_env
            AND t.provider_account_id = p_provider_account_id AND t.name = p_name
            AND t.language = p_language
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::uuid;
          RETURN;
        END IF;
        IF p_edited_at = ANY (v_row.edits) THEN
          RETURN QUERY SELECT 'unchanged'::text, v_row.id;
          RETURN;
        END IF;
        UPDATE relay.whatsapp_templates t
          SET edits = (SELECT coalesce(array_agg(e ORDER BY e), '{}') FROM (
              SELECT e FROM unnest(t.edits || p_edited_at) AS e ORDER BY e DESC LIMIT 64) s),
            approved_components = coalesce(p_components, t.approved_components),
            version = t.version + 1, updated_at = now()
          WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.id = v_row.id;
        RETURN QUERY SELECT 'recorded'::text, v_row.id;
      END
      $fn$
      """
    ]
  end
end
