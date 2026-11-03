defmodule Relay.Repo.Migrations.CreateTemplateFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"

  @functions [
    {"relay_private.template_definition_check(uuid, jsonb, boolean)", "relay_migrator",
     ~w(relay_owner)},
    {"relay_private.template_draft_write(relay.templates, uuid, jsonb, text)", "relay_migrator",
     ~w(relay_owner)},
    {"relay_fn.template_create(uuid, uuid, text, uuid, text, text, text, jsonb, bytea, #{@actor})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.template_update(text, uuid, text, text, text, bigint, bytea, #{@actor})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.template_draft_put(uuid, text, uuid, text, jsonb, bigint, bytea, #{@actor})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.template_publish(text, uuid, text, bytea, jsonb, jsonb, jsonb, boolean, jsonb, bigint, bytea, #{@actor})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.template_rollback(text, uuid, text, bigint, bigint, bytea, #{@actor})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.template_archive(text, uuid, text, bigint, bytea, #{@actor})", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.template_version_archive(text, uuid, text, bigint, bytea, #{@actor})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.template_live(text[], uuid)", "relay_owner", ~w(relay_app relay_report)},
    {"relay_fn.brand_resolve(uuid, uuid)", "relay_owner", ~w(relay_app relay_report)}
  ]

  # TP-1
  # TP-11
  # TP-21
  # TP-26
  # TP-30
  # TP-31
  # TP-32
  # TP-35
  # TP-36
  # TP-37
  # TP-48
  # TP-51
  # TP-52
  # INV-21
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
      CREATE FUNCTION relay_private.template_definition_check(p_subtenant_id uuid,
        p_definition jsonb, p_producer boolean)
        RETURNS text
      LANGUAGE plpgsql STABLE
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_cells jsonb := p_definition -> 'cells';
        v_layout text := p_definition ->> 'layout';
        v_partials jsonb := COALESCE(NULLIF(p_definition -> 'partials', 'null'::jsonb), '[]'::jsonb);
        v_channel record;
        v_cell record;
        v_key text;
      BEGIN
        IF p_definition IS NULL OR jsonb_typeof(p_definition) <> 'object'
          OR EXISTS (SELECT 1 FROM jsonb_object_keys(p_definition) k
            WHERE k NOT IN ('cells', 'default_locale', 'sensitivity', 'sensitivity_approval',
              'sms_encoding', 'transliterate', 'allow_raw', 'layout', 'partials', 'producer_brand'))
          OR jsonb_typeof(v_cells) IS DISTINCT FROM 'object'
          OR jsonb_typeof(p_definition -> 'default_locale') IS DISTINCT FROM 'string'
          OR (p_definition ->> 'default_locale') !~ '^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$'
          OR char_length(p_definition ->> 'default_locale') > 35
          OR COALESCE(p_definition ->> 'sensitivity', 'public')
            NOT IN ('public', 'personal', 'sensitive')
          OR COALESCE(jsonb_typeof(NULLIF(p_definition -> 'sensitivity_approval', 'null'::jsonb)),
            'object') <> 'object'
          OR COALESCE(p_definition ->> 'sms_encoding', 'turkish_shift')
            NOT IN ('transliterate', 'turkish_shift', 'ucs2')
          OR COALESCE(jsonb_typeof(NULLIF(p_definition -> 'transliterate', 'null'::jsonb)),
            'boolean') <> 'boolean'
          OR COALESCE(jsonb_typeof(NULLIF(p_definition -> 'allow_raw', 'null'::jsonb)),
            'boolean') <> 'boolean'
          OR COALESCE(jsonb_typeof(NULLIF(p_definition -> 'layout', 'null'::jsonb)), 'string')
            <> 'string'
          OR v_layout !~ '^[a-z][a-z0-9_.-]{0,63}$'
          OR jsonb_typeof(v_partials) <> 'array' OR jsonb_array_length(v_partials) > 50
          OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_partials) e
            WHERE jsonb_typeof(e) <> 'string' OR (e #>> '{}') !~ '^[a-z][a-z0-9_.-]{0,63}$')
          OR COALESCE(jsonb_typeof(NULLIF(p_definition -> 'producer_brand', 'null'::jsonb)),
            'object') <> 'object'
          OR (NOT COALESCE(p_producer, false)
            AND NULLIF(p_definition -> 'producer_brand', 'null'::jsonb) IS NOT NULL) THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TP-48';
        END IF;
        FOR v_channel IN SELECT c.key, c.value FROM jsonb_each(v_cells) c LOOP
          IF v_channel.key NOT IN ('push', 'web_push', 'email', 'sms', 'voice', 'whatsapp', 'slack',
            'teams', 'telegram', 'discord', 'in_app', 'webhook')
            OR jsonb_typeof(v_channel.value) <> 'object' THEN
            RAISE EXCEPTION 'invalid_argument' USING HINT = 'TP-9';
          END IF;
          FOR v_cell IN SELECT l.key, l.value FROM jsonb_each(v_channel.value) l LOOP
            IF v_cell.key !~ '^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$' OR char_length(v_cell.key) > 35
              OR jsonb_typeof(v_cell.value) <> 'object' THEN
              RAISE EXCEPTION 'invalid_argument' USING HINT = 'TP-9';
            END IF;
          END LOOP;
        END LOOP;
        IF v_layout IS NOT NULL AND NOT EXISTS (SELECT 1 FROM relay.layouts l
          WHERE l.tenant_id = v_tenant AND l.environment = v_env AND l.key = v_layout
            AND l.state = 'active'
            AND (l.subtenant_id IS NULL OR l.subtenant_id = p_subtenant_id)) THEN
          RETURN 'layout_not_found';
        END IF;
        FOR v_key IN SELECT e FROM jsonb_array_elements_text(v_partials) e LOOP
          IF NOT EXISTS (SELECT 1 FROM relay.partials p
            WHERE p.tenant_id = v_tenant AND p.environment = v_env AND p.key = v_key
              AND p.state = 'active'
              AND (p.subtenant_id IS NULL OR p.subtenant_id = p_subtenant_id)) THEN
            RETURN 'partial_not_found';
          END IF;
        END LOOP;
        RETURN 'ok';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.template_draft_write(p_template relay.templates,
        p_version_id uuid, p_definition jsonb, p_drafted_by_ref text)
        RETURNS TABLE (result text, version_id uuid)
      LANGUAGE plpgsql VOLATILE
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_draft relay.template_versions;
        v_cells jsonb := p_definition -> 'cells';
        v_locale text := p_definition ->> 'default_locale';
        v_sensitivity text := p_definition ->> 'sensitivity';
        v_approval jsonb := NULLIF(p_definition -> 'sensitivity_approval', 'null'::jsonb);
        v_encoding text := COALESCE(p_definition ->> 'sms_encoding', 'turkish_shift');
        v_transliterate boolean := COALESCE((p_definition ->> 'transliterate')::boolean, false);
        v_allow_raw boolean := COALESCE((p_definition ->> 'allow_raw')::boolean, false);
        v_layout text := p_definition ->> 'layout';
        v_partials text[] := ARRAY(SELECT DISTINCT e FROM jsonb_array_elements_text(
          COALESCE(NULLIF(p_definition -> 'partials', 'null'::jsonb), '[]'::jsonb)) e ORDER BY e);
        v_brand jsonb := NULLIF(p_definition -> 'producer_brand', 'null'::jsonb);
        v_checksum bytea;
      BEGIN
        v_checksum := sha256(convert_to(jsonb_build_object('cells', v_cells,
          'default_locale', v_locale, 'sensitivity', v_sensitivity,
          'sensitivity_approval', v_approval, 'sms_encoding', v_encoding,
          'transliterate', v_transliterate, 'allow_raw', v_allow_raw, 'layout', v_layout,
          'partials', to_jsonb(v_partials), 'producer_brand', v_brand)::text, 'UTF8'));
        SELECT * INTO v_draft FROM relay.template_versions v
          WHERE v.tenant_id = p_template.tenant_id AND v.environment = p_template.environment
            AND v.template_id = p_template.id AND v.state = 'draft'
          FOR UPDATE;
        IF NOT FOUND THEN
          PERFORM relay_private.assert_new_id(p_version_id);
          INSERT INTO relay.template_versions (tenant_id, environment, id, template_id, state,
            version_no, checksum, cells, default_locale, sensitivity, sensitivity_approval,
            sms_encoding, transliterate, allow_raw, layout_key, partial_keys, producer_brand,
            variables, measures, findings, warnings_accepted, warnings_accepted_by_ref, diff,
            previous_version_no, drafted_by_ref, published_at, published_by_ref, archived_at,
            created_at, updated_at)
          VALUES (p_template.tenant_id, p_template.environment, p_version_id, p_template.id,
            'draft', NULL, v_checksum, v_cells, v_locale, v_sensitivity, v_approval, v_encoding,
            v_transliterate, v_allow_raw, v_layout, v_partials, v_brand, NULL, NULL, NULL, false,
            NULL, NULL, NULL, p_drafted_by_ref, NULL, NULL, NULL, now(), now());
          RETURN QUERY SELECT 'created'::text, p_version_id;
          RETURN;
        END IF;
        IF v_draft.checksum = v_checksum THEN
          RETURN QUERY SELECT 'unchanged'::text, v_draft.id;
          RETURN;
        END IF;
        UPDATE relay.template_versions v SET checksum = v_checksum, cells = v_cells,
            default_locale = v_locale, sensitivity = v_sensitivity,
            sensitivity_approval = v_approval, sms_encoding = v_encoding,
            transliterate = v_transliterate, allow_raw = v_allow_raw, layout_key = v_layout,
            partial_keys = v_partials, producer_brand = v_brand,
            drafted_by_ref = p_drafted_by_ref, updated_at = now()
          WHERE v.tenant_id = v_draft.tenant_id AND v.environment = v_draft.environment
            AND v.id = v_draft.id;
        RETURN QUERY SELECT 'replaced'::text, v_draft.id;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.template_create(p_id uuid, p_version_id uuid, p_key text,
        p_subtenant_id uuid, p_owner_product text, p_name text, p_category text,
        p_definition jsonb, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
        p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, template_id uuid, version_id uuid, version bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_category relay.categories;
        v_existing relay.templates;
        v_template relay.templates;
        v_check text;
        v_draft record;
      BEGIN
        IF relay_private.tenant_status() <> 'active' THEN
          RETURN QUERY SELECT 'tenant_inactive'::text, NULL::uuid, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        IF p_key IS NULL OR p_key !~ '^[a-z][a-z0-9_.-]{0,63}$' OR p_name IS NULL
          OR char_length(p_name) NOT BETWEEN 1 AND 200 OR p_category IS NULL
          OR (p_subtenant_id IS NOT NULL AND p_owner_product IS NOT NULL) THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TP-48';
        END IF;
        IF p_subtenant_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM relay.subtenants s
          WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = p_subtenant_id
            AND s.state = 'active') THEN
          RETURN QUERY SELECT 'subtenant_not_found'::text, NULL::uuid, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        SELECT * INTO v_category FROM relay.categories c
          WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.key = p_category;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'category_not_found'::text, NULL::uuid, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        IF v_category.state = 'archived' THEN
          RETURN QUERY SELECT 'category_archived'::text, NULL::uuid, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        v_check := relay_private.template_definition_check(p_subtenant_id, p_definition,
          p_owner_product IS NOT NULL);
        IF v_check <> 'ok' THEN
          RETURN QUERY SELECT v_check, NULL::uuid, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['template', COALESCE(p_subtenant_id::text, ''),
          p_key]);
        SELECT * INTO v_existing FROM relay.templates t
          WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.key = p_key
            AND t.subtenant_id IS NOT DISTINCT FROM p_subtenant_id;
        IF FOUND THEN
          RETURN QUERY SELECT 'key_conflict'::text, v_existing.id, NULL::uuid, v_existing.version;
          RETURN;
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        INSERT INTO relay.templates AS t (tenant_id, environment, id, key, subtenant_id, owner,
          owner_product, name, category_id, message_class, template_type, state, archived_at,
          live_version_id, live_version_no, first_published_at, version, created_at, updated_at)
        VALUES (v_tenant, v_env, p_id, p_key, p_subtenant_id,
          CASE WHEN p_owner_product IS NOT NULL THEN 'producer'
            WHEN p_subtenant_id IS NOT NULL THEN 'subtenant' ELSE 'tenant' END,
          p_owner_product, p_name, v_category.id, v_category.message_class,
          CASE WHEN v_category.message_class = 'marketing' THEN 'marketing'
            ELSE 'transactional' END,
          'active', NULL, NULL, NULL, NULL, 1, now(), now())
        RETURNING t.* INTO v_template;
        SELECT * INTO v_draft FROM relay_private.template_draft_write(v_template, p_version_id,
          p_definition, p_actor_ref);
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'template.created',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'template',
          p_id::text, NULL, p_record_digest);
        RETURN QUERY SELECT 'created'::text, p_id, v_draft.version_id, 1::bigint;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.template_update(p_key text, p_subtenant_id uuid,
        p_owner_product text, p_name text, p_category text, p_expected_version bigint,
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
        v_template relay.templates;
        v_category relay.categories;
        v_version bigint;
      BEGIN
        IF p_name IS NULL OR char_length(p_name) NOT BETWEEN 1 AND 200 OR p_category IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TP-48';
        END IF;
        SELECT * INTO v_template FROM relay.templates t
          WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.key = p_key
            AND t.subtenant_id IS NOT DISTINCT FROM p_subtenant_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
          RETURN;
        END IF;
        IF v_template.state = 'archived' THEN
          RETURN QUERY SELECT 'archived'::text, v_template.version;
          RETURN;
        END IF;
        IF v_template.owner_product IS DISTINCT FROM p_owner_product THEN
          RETURN QUERY SELECT 'protected'::text, v_template.version;
          RETURN;
        END IF;
        IF p_expected_version IS NOT NULL AND p_expected_version <> v_template.version THEN
          RETURN QUERY SELECT 'version_conflict'::text, v_template.version;
          RETURN;
        END IF;
        SELECT * INTO v_category FROM relay.categories c
          WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.key = p_category;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'category_not_found'::text, v_template.version;
          RETURN;
        END IF;
        IF v_category.state = 'archived' AND v_category.id <> v_template.category_id THEN
          RETURN QUERY SELECT 'category_archived'::text, v_template.version;
          RETURN;
        END IF;
        IF v_template.first_published_at IS NOT NULL
          AND v_category.message_class <> v_template.message_class THEN
          RETURN QUERY SELECT 'class_locked'::text, v_template.version;
          RETURN;
        END IF;
        IF v_template.name = p_name AND v_template.category_id = v_category.id THEN
          RETURN QUERY SELECT 'unchanged'::text, v_template.version;
          RETURN;
        END IF;
        UPDATE relay.templates t SET name = p_name, category_id = v_category.id,
            message_class = v_category.message_class,
            template_type = CASE WHEN v_category.message_class = 'marketing' THEN 'marketing'
              ELSE 'transactional' END,
            version = t.version + 1, updated_at = now()
          WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.id = v_template.id
          RETURNING t.version INTO v_version;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'template.updated',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'template',
          v_template.id::text, NULL, p_record_digest);
        RETURN QUERY SELECT 'updated'::text, v_version;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.template_draft_put(p_version_id uuid, p_key text,
        p_subtenant_id uuid, p_owner_product text, p_definition jsonb, p_expected_version bigint,
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text)
        RETURNS TABLE (result text, version_id uuid, version bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_template relay.templates;
        v_check text;
        v_draft record;
        v_version bigint;
      BEGIN
        SELECT * INTO v_template FROM relay.templates t
          WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.key = p_key
            AND t.subtenant_id IS NOT DISTINCT FROM p_subtenant_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        IF v_template.state = 'archived' THEN
          RETURN QUERY SELECT 'archived'::text, NULL::uuid, v_template.version;
          RETURN;
        END IF;
        IF v_template.owner_product IS DISTINCT FROM p_owner_product THEN
          RETURN QUERY SELECT 'protected'::text, NULL::uuid, v_template.version;
          RETURN;
        END IF;
        IF p_expected_version IS NOT NULL AND p_expected_version <> v_template.version THEN
          RETURN QUERY SELECT 'version_conflict'::text, NULL::uuid, v_template.version;
          RETURN;
        END IF;
        v_check := relay_private.template_definition_check(p_subtenant_id, p_definition,
          v_template.owner = 'producer');
        IF v_check <> 'ok' THEN
          RETURN QUERY SELECT v_check, NULL::uuid, v_template.version;
          RETURN;
        END IF;
        SELECT * INTO v_draft FROM relay_private.template_draft_write(v_template, p_version_id,
          p_definition, p_actor_ref);
        IF v_draft.result = 'unchanged' THEN
          RETURN QUERY SELECT 'unchanged'::text, v_draft.version_id, v_template.version;
          RETURN;
        END IF;
        UPDATE relay.templates t SET version = t.version + 1, updated_at = now()
          WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.id = v_template.id
          RETURNING t.version INTO v_version;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'template.drafted',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'template',
          v_template.id::text, NULL, p_record_digest);
        RETURN QUERY SELECT v_draft.result, v_draft.version_id, v_version;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.template_publish(p_key text, p_subtenant_id uuid,
        p_owner_product text, p_checksum bytea, p_variables jsonb, p_measures jsonb,
        p_findings jsonb, p_accept_warnings boolean, p_diff jsonb, p_expected_version bigint,
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text)
        RETURNS TABLE (result text, version_id uuid, version_no bigint, version bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_template relay.templates;
        v_draft relay.template_versions;
        v_duplicate bigint;
        v_warnings boolean;
        v_accepted boolean;
        v_no bigint;
        v_version bigint;
        v_key text;
      BEGIN
        IF p_variables IS NULL OR jsonb_typeof(p_variables) <> 'object'
          OR p_measures IS NULL OR jsonb_typeof(p_measures) <> 'object'
          OR p_findings IS NULL OR jsonb_typeof(p_findings) <> 'array'
          OR EXISTS (SELECT 1 FROM jsonb_array_elements(p_findings) f
            WHERE jsonb_typeof(f) <> 'object' OR f ->> 'level' IS NULL
              OR f ->> 'level' NOT IN ('hard', 'warning'))
          OR (p_diff IS NOT NULL AND jsonb_typeof(p_diff) <> 'object')
          OR p_accept_warnings IS NULL OR p_actor_ref IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TP-32';
        END IF;
        SELECT * INTO v_template FROM relay.templates t
          WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.key = p_key
            AND t.subtenant_id IS NOT DISTINCT FROM p_subtenant_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::bigint, NULL::bigint;
          RETURN;
        END IF;
        IF v_template.state = 'archived' THEN
          RETURN QUERY SELECT 'archived'::text, NULL::uuid, NULL::bigint, v_template.version;
          RETURN;
        END IF;
        IF v_template.owner_product IS DISTINCT FROM p_owner_product THEN
          RETURN QUERY SELECT 'protected'::text, NULL::uuid, NULL::bigint, v_template.version;
          RETURN;
        END IF;
        IF p_expected_version IS NOT NULL AND p_expected_version <> v_template.version THEN
          RETURN QUERY SELECT 'version_conflict'::text, NULL::uuid, NULL::bigint,
            v_template.version;
          RETURN;
        END IF;
        SELECT * INTO v_draft FROM relay.template_versions v
          WHERE v.tenant_id = v_tenant AND v.environment = v_env
            AND v.template_id = v_template.id AND v.state = 'draft'
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'no_draft'::text, NULL::uuid, NULL::bigint, v_template.version;
          RETURN;
        END IF;
        IF p_checksum IS NOT NULL AND p_checksum <> v_draft.checksum THEN
          RETURN QUERY SELECT 'draft_changed'::text, v_draft.id, NULL::bigint,
            v_template.version;
          RETURN;
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_findings) f WHERE f ->> 'level' = 'hard')
        THEN
          RETURN QUERY SELECT 'gate_failed'::text, v_draft.id, NULL::bigint, v_template.version;
          RETURN;
        END IF;
        v_warnings := jsonb_array_length(p_findings) > 0;
        IF v_warnings AND NOT p_accept_warnings THEN
          RETURN QUERY SELECT 'warnings_unaccepted'::text, v_draft.id, NULL::bigint,
            v_template.version;
          RETURN;
        END IF;
        v_accepted := v_warnings AND p_accept_warnings;
        IF v_draft.sensitivity IS NULL THEN
          RETURN QUERY SELECT 'sensitivity_missing'::text, v_draft.id, NULL::bigint,
            v_template.version;
          RETURN;
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_each(v_draft.cells) c, jsonb_each(c.value) l
          WHERE l.value -> 'machine_translated' = 'true'::jsonb
            AND NULLIF(l.value -> 'translation_approved_by', 'null'::jsonb) IS NULL) THEN
          RETURN QUERY SELECT 'translation_unapproved'::text, v_draft.id, NULL::bigint,
            v_template.version;
          RETURN;
        END IF;
        IF v_draft.layout_key IS NOT NULL AND NOT EXISTS (SELECT 1 FROM relay.layouts l
          WHERE l.tenant_id = v_tenant AND l.environment = v_env AND l.key = v_draft.layout_key
            AND l.state = 'active' AND l.live_version_id IS NOT NULL
            AND (l.subtenant_id IS NULL OR l.subtenant_id = p_subtenant_id)) THEN
          RETURN QUERY SELECT 'layout_not_published'::text, v_draft.id, NULL::bigint,
            v_template.version;
          RETURN;
        END IF;
        FOREACH v_key IN ARRAY v_draft.partial_keys LOOP
          IF NOT EXISTS (SELECT 1 FROM relay.partials p
            WHERE p.tenant_id = v_tenant AND p.environment = v_env AND p.key = v_key
              AND p.state = 'active' AND p.live_version_id IS NOT NULL
              AND (p.subtenant_id IS NULL OR p.subtenant_id = p_subtenant_id)) THEN
            RETURN QUERY SELECT 'partial_not_published'::text, v_draft.id, NULL::bigint,
              v_template.version;
            RETURN;
          END IF;
        END LOOP;
        SELECT v.version_no INTO v_duplicate FROM relay.template_versions v
          WHERE v.tenant_id = v_tenant AND v.environment = v_env
            AND v.template_id = v_template.id AND v.version_no IS NOT NULL
            AND v.checksum = v_draft.checksum;
        IF FOUND THEN
          RETURN QUERY SELECT 'duplicate'::text, v_draft.id, v_duplicate, v_template.version;
          RETURN;
        END IF;
        SELECT COALESCE(max(v.version_no), 0) + 1 INTO v_no FROM relay.template_versions v
          WHERE v.tenant_id = v_tenant AND v.environment = v_env
            AND v.template_id = v_template.id;
        UPDATE relay.template_versions v SET state = 'published', version_no = v_no,
            variables = p_variables, measures = p_measures, findings = p_findings,
            warnings_accepted = v_accepted,
            warnings_accepted_by_ref = CASE WHEN v_accepted THEN p_actor_ref END,
            diff = p_diff, previous_version_no = v_template.live_version_no,
            published_at = now(), published_by_ref = p_actor_ref, updated_at = now()
          WHERE v.tenant_id = v_tenant AND v.environment = v_env AND v.id = v_draft.id;
        UPDATE relay.templates t SET live_version_id = v_draft.id, live_version_no = v_no,
            first_published_at = COALESCE(t.first_published_at, now()),
            version = t.version + 1, updated_at = now()
          WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.id = v_template.id
          RETURNING t.version INTO v_version;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'template.published',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'template',
          v_template.id::text,
          format('version %s checksum %s previous %s', v_no, encode(v_draft.checksum, 'hex'),
            COALESCE(v_template.live_version_no::text, 'none')),
          p_record_digest);
        RETURN QUERY SELECT 'published'::text, v_draft.id, v_no, v_version;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.template_rollback(p_key text, p_subtenant_id uuid,
        p_owner_product text, p_version_no bigint, p_expected_version bigint,
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text)
        RETURNS TABLE (result text, version_id uuid, version bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_template relay.templates;
        v_target relay.template_versions;
        v_version bigint;
      BEGIN
        IF p_version_no IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TP-31';
        END IF;
        SELECT * INTO v_template FROM relay.templates t
          WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.key = p_key
            AND t.subtenant_id IS NOT DISTINCT FROM p_subtenant_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        IF v_template.state = 'archived' THEN
          RETURN QUERY SELECT 'archived'::text, NULL::uuid, v_template.version;
          RETURN;
        END IF;
        IF v_template.owner_product IS DISTINCT FROM p_owner_product THEN
          RETURN QUERY SELECT 'protected'::text, NULL::uuid, v_template.version;
          RETURN;
        END IF;
        IF p_expected_version IS NOT NULL AND p_expected_version <> v_template.version THEN
          RETURN QUERY SELECT 'version_conflict'::text, NULL::uuid, v_template.version;
          RETURN;
        END IF;
        SELECT * INTO v_target FROM relay.template_versions v
          WHERE v.tenant_id = v_tenant AND v.environment = v_env
            AND v.template_id = v_template.id AND v.version_no = p_version_no;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'version_not_found'::text, NULL::uuid, v_template.version;
          RETURN;
        END IF;
        IF v_target.state = 'archived' THEN
          RETURN QUERY SELECT 'version_archived'::text, v_target.id, v_template.version;
          RETURN;
        END IF;
        IF v_template.live_version_id = v_target.id THEN
          RETURN QUERY SELECT 'unchanged'::text, v_target.id, v_template.version;
          RETURN;
        END IF;
        UPDATE relay.templates t SET live_version_id = v_target.id, live_version_no = p_version_no,
            version = t.version + 1, updated_at = now()
          WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.id = v_template.id
          RETURNING t.version INTO v_version;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'template.rolled_back',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'template',
          v_template.id::text,
          format('version %s checksum %s previous %s', p_version_no,
            encode(v_target.checksum, 'hex'), COALESCE(v_template.live_version_no::text, 'none')),
          p_record_digest);
        RETURN QUERY SELECT 'rolled_back'::text, v_target.id, v_version;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.template_archive(p_key text, p_subtenant_id uuid,
        p_owner_product text, p_expected_version bigint, p_record_digest bytea,
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
        v_template relay.templates;
        v_version bigint;
      BEGIN
        SELECT * INTO v_template FROM relay.templates t
          WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.key = p_key
            AND t.subtenant_id IS NOT DISTINCT FROM p_subtenant_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
          RETURN;
        END IF;
        IF v_template.state = 'archived' THEN
          RETURN QUERY SELECT 'already_archived'::text, v_template.version;
          RETURN;
        END IF;
        IF v_template.owner_product IS DISTINCT FROM p_owner_product THEN
          RETURN QUERY SELECT 'protected'::text, v_template.version;
          RETURN;
        END IF;
        IF p_expected_version IS NOT NULL AND p_expected_version <> v_template.version THEN
          RETURN QUERY SELECT 'version_conflict'::text, v_template.version;
          RETURN;
        END IF;
        UPDATE relay.template_versions v SET state = 'archived', archived_at = now(),
            updated_at = now()
          WHERE v.tenant_id = v_tenant AND v.environment = v_env
            AND v.template_id = v_template.id AND v.state = 'draft';
        UPDATE relay.templates t SET state = 'archived', archived_at = now(),
            version = t.version + 1, updated_at = now()
          WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.id = v_template.id
          RETURNING t.version INTO v_version;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'template.archived',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'template',
          v_template.id::text, NULL, p_record_digest);
        RETURN QUERY SELECT 'archived'::text, v_version;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.template_version_archive(p_key text, p_subtenant_id uuid,
        p_owner_product text, p_version_no bigint, p_record_digest bytea, p_actor_kind text,
        p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_template relay.templates;
        v_target relay.template_versions;
      BEGIN
        SELECT * INTO v_template FROM relay.templates t
          WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.key = p_key
            AND t.subtenant_id IS NOT DISTINCT FROM p_subtenant_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_template.owner_product IS DISTINCT FROM p_owner_product THEN
          RETURN 'protected';
        END IF;
        SELECT * INTO v_target FROM relay.template_versions v
          WHERE v.tenant_id = v_tenant AND v.environment = v_env
            AND v.template_id = v_template.id
            AND ((p_version_no IS NULL AND v.state = 'draft') OR v.version_no = p_version_no)
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'version_not_found';
        END IF;
        IF v_target.state = 'archived' THEN
          RETURN 'already_archived';
        END IF;
        IF v_template.live_version_id = v_target.id THEN
          RETURN 'live_version';
        END IF;
        UPDATE relay.template_versions v SET state = 'archived', archived_at = now(),
            updated_at = now()
          WHERE v.tenant_id = v_tenant AND v.environment = v_env AND v.id = v_target.id;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'template.version_archived',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'template',
          v_template.id::text, format('version %s', COALESCE(p_version_no::text, 'draft')),
          p_record_digest);
        RETURN 'archived';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.template_live(p_keys text[], p_subtenant_id uuid)
        RETURNS TABLE (key text, template_id uuid, owner text, message_class text,
          template_version_id uuid, version_no bigint, layout_version_id uuid,
          partial_keys text[], partial_version_ids uuid[], source text, rule_id text)
      LANGUAGE sql STABLE SECURITY INVOKER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT k.key, t.id, t.owner, t.message_class::text, v.id, v.version_no, lv.id,
          v.partial_keys, COALESCE(pv.ids, '{}'::uuid[]),
          CASE WHEN t.id IS NULL THEN NULL WHEN t.subtenant_id IS NULL THEN 'tenant'
            ELSE 'subtenant' END,
          CASE WHEN t.id IS NULL OR (t.state = 'active' AND t.live_version_id IS NULL)
              THEN 'template.not_published'
            WHEN t.state = 'archived' THEN 'template.archived' END
        FROM unnest(p_keys) WITH ORDINALITY AS k(key, n)
        LEFT JOIN LATERAL (
          SELECT x.* FROM relay.templates x
          WHERE x.tenant_id = relay_private.ctx_tenant_id()
            AND x.environment = relay_private.ctx_environment() AND x.key = k.key
            AND (x.subtenant_id IS NULL OR (x.subtenant_id = p_subtenant_id
              AND x.state = 'active' AND x.live_version_id IS NOT NULL))
          ORDER BY x.subtenant_id IS NULL
          LIMIT 1) t ON true
        LEFT JOIN relay.template_versions v
          ON t.state = 'active' AND v.tenant_id = t.tenant_id AND v.environment = t.environment
          AND v.id = t.live_version_id
        LEFT JOIN LATERAL (
          SELECT y.live_version_id AS id FROM relay.layouts y
          WHERE y.tenant_id = t.tenant_id AND y.environment = t.environment
            AND y.key = v.layout_key AND y.state = 'active' AND y.live_version_id IS NOT NULL
            AND (y.subtenant_id IS NULL OR y.subtenant_id = p_subtenant_id)
          ORDER BY y.subtenant_id IS NULL
          LIMIT 1) lv ON true
        LEFT JOIN LATERAL (
          SELECT array_agg((SELECT z.live_version_id FROM relay.partials z
              WHERE z.tenant_id = t.tenant_id AND z.environment = t.environment
                AND z.key = e.key AND z.state = 'active' AND z.live_version_id IS NOT NULL
                AND (z.subtenant_id IS NULL OR z.subtenant_id = p_subtenant_id)
              ORDER BY z.subtenant_id IS NULL
              LIMIT 1) ORDER BY e.n) AS ids
          FROM unnest(v.partial_keys) WITH ORDINALITY AS e(key, n)) pv ON true
        ORDER BY k.n
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.brand_resolve(p_subtenant_id uuid, p_template_version_id uuid)
        RETURNS TABLE (field text, value jsonb, source text)
      LANGUAGE sql STABLE SECURITY INVOKER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        WITH producer AS (
          SELECT v.producer_brand AS brand FROM relay.template_versions v
          JOIN relay.templates t ON t.tenant_id = v.tenant_id AND t.environment = v.environment
            AND t.id = v.template_id
          WHERE v.tenant_id = relay_private.ctx_tenant_id()
            AND v.environment = relay_private.ctx_environment()
            AND v.id = p_template_version_id AND t.owner = 'producer'
        ),
        fields (field, overridable) AS (
          VALUES ('contact', false), ('footer', true), ('legal_name', false),
            ('logo_url', true), ('mersis', false), ('postal_address', false),
            ('primary_color', true), ('secondary_color', false), ('sender_name', true)
        ),
        stored AS (
          SELECT substr(r.key, 7) AS field, r.value, r.source
          FROM relay_fn.setting_resolve(p_subtenant_id,
            ARRAY(SELECT 'brand.' || f.field FROM fields f)) r
          WHERE r.value IS NOT NULL AND r.value <> 'null'::jsonb
        )
        SELECT f.field,
          CASE
            WHEN p.brand ? f.field AND (NOT f.overridable OR s.value IS NULL)
              THEN p.brand -> f.field
            ELSE s.value
          END,
          CASE
            WHEN p.brand ? f.field AND (NOT f.overridable OR s.value IS NULL) THEN 'producer'
            WHEN s.value IS NOT NULL THEN s.source
            ELSE 'none'
          END
        FROM fields f
        LEFT JOIN stored s ON s.field = f.field
        LEFT JOIN producer p ON true
        ORDER BY f.field
      $fn$
      """
    ]
  end
end
