defmodule Relay.Repo.Migrations.CreateTemplateTables do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  @key "'^[a-z0-9]+(-[a-z0-9]+)*$'"
  @locale "'^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$'"

  @tables ~w(templates template_versions layouts layout_versions partials partial_versions
             delivery_render_plans render_snapshots)
  @append_only ~w(render_snapshots)

  # TP-1
  # TP-12
  # TP-31
  # TP-35
  # TP-36
  # TP-37
  # TP-40
  # TP-48
  # TP-50
  # TP-52
  # INV-21
  # INV-48
  # TN-12
  # TN-13
  # INV-6
  def up do
    Enum.each(template_statements(), &execute/1)
    Enum.each(["layout", "partial"], fn kind -> Enum.each(asset_statements(kind), &execute/1) end)
    Enum.each(plan_statements(), &execute/1)
    Enum.each(@tables, &scoped/1)
    Enum.each(@append_only, &append_only/1)
  end

  defp scoped(table) do
    execute("ALTER TABLE relay.#{table} ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE relay.#{table} FORCE ROW LEVEL SECURITY")

    execute(
      "CREATE POLICY #{table}_scope ON relay.#{table} USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})"
    )

    privileges = if table in @append_only, do: "SELECT, INSERT", else: "SELECT, INSERT, UPDATE"
    execute("GRANT #{privileges} ON relay.#{table} TO relay_owner")

    execute(
      "GRANT SELECT ON relay.#{table} TO relay_app, relay_maint, relay_archive, relay_report"
    )
  end

  defp append_only(table) do
    execute("""
    CREATE TRIGGER #{table}_no_mutation BEFORE UPDATE OR DELETE ON relay.#{table}
      FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    execute("""
    CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON relay.#{table}
      FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
    """)
  end

  defp no_delete(table) do
    [
      """
      CREATE TRIGGER #{table}_no_delete BEFORE DELETE ON relay.#{table}
        FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
      """,
      """
      CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON relay.#{table}
        FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
      """
    ]
  end

  defp template_statements do
    [
      """
      CREATE TABLE relay.templates (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        key text NOT NULL CONSTRAINT templates_key_check CHECK (key ~ #{@key} AND char_length(key) <= 100),
        subtenant_id uuid,
        owner text NOT NULL
          CONSTRAINT templates_owner_check CHECK (owner IN ('tenant', 'subtenant', 'producer')),
        owner_product text
          CONSTRAINT templates_owner_product_check CHECK (owner_product ~ '^[a-z][a-z0-9_]{0,63}$'),
        name text NOT NULL CONSTRAINT templates_name_check CHECK (char_length(name) BETWEEN 1 AND 200),
        category_id uuid NOT NULL,
        message_class relay.message_class NOT NULL,
        template_type text NOT NULL
          CONSTRAINT templates_template_type_check
            CHECK (template_type IN ('transactional', 'marketing')),
        state text NOT NULL CONSTRAINT templates_state_check CHECK (state IN ('active', 'archived')),
        archived_at timestamptz,
        live_version_id uuid,
        live_version_no bigint CONSTRAINT templates_live_version_no_check CHECK (live_version_no >= 1),
        first_published_at timestamptz,
        version bigint NOT NULL CONSTRAINT templates_version_check CHECK (version >= 1),
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT templates_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT templates_key_key UNIQUE NULLS NOT DISTINCT (tenant_id, environment, subtenant_id, key),
        CONSTRAINT templates_subtenant_check CHECK ((owner = 'subtenant') = (subtenant_id IS NOT NULL)),
        CONSTRAINT templates_producer_check CHECK ((owner = 'producer') = (owner_product IS NOT NULL)),
        CONSTRAINT templates_type_class_check
          CHECK ((template_type = 'marketing') = (message_class = 'marketing')),
        CONSTRAINT templates_live_check CHECK ((live_version_id IS NULL) = (live_version_no IS NULL)),
        CONSTRAINT templates_first_published_check
          CHECK (live_version_id IS NULL OR first_published_at IS NOT NULL),
        CONSTRAINT templates_archived_check CHECK ((state = 'archived') = (archived_at IS NOT NULL)),
        CONSTRAINT templates_subtenant_id_fkey FOREIGN KEY (tenant_id, environment, subtenant_id)
          REFERENCES relay.subtenants (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT templates_category_id_fkey FOREIGN KEY (tenant_id, environment, category_id)
          REFERENCES relay.categories (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE TABLE relay.template_versions (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        template_id uuid NOT NULL,
        state text NOT NULL
          CONSTRAINT template_versions_state_check CHECK (state IN ('draft', 'published', 'archived')),
        version_no bigint CONSTRAINT template_versions_version_no_check CHECK (version_no >= 1),
        checksum relay.sha256 NOT NULL,
        cells jsonb NOT NULL
          CONSTRAINT template_versions_cells_check
            CHECK (jsonb_typeof(cells) = 'object' AND pg_column_size(cells) <= 4194304),
        default_locale text NOT NULL
          CONSTRAINT template_versions_default_locale_check
            CHECK (default_locale ~ #{@locale} AND char_length(default_locale) <= 35),
        sensitivity text
          CONSTRAINT template_versions_sensitivity_check
            CHECK (sensitivity IN ('public', 'personal', 'sensitive')),
        sensitivity_approval jsonb
          CONSTRAINT template_versions_sensitivity_approval_check
            CHECK (jsonb_typeof(sensitivity_approval) = 'object'
              AND pg_column_size(sensitivity_approval) <= 16384),
        sms_encoding text NOT NULL
          CONSTRAINT template_versions_sms_encoding_check
            CHECK (sms_encoding IN ('transliterate', 'turkish_shift', 'ucs2')),
        transliterate boolean NOT NULL,
        allow_raw boolean NOT NULL,
        layout_key text CONSTRAINT template_versions_layout_key_check CHECK (layout_key ~ #{@key} AND char_length(layout_key) <= 100),
        partial_keys text[] NOT NULL
          CONSTRAINT template_versions_partial_keys_check CHECK (cardinality(partial_keys) <= 50),
        producer_brand jsonb
          CONSTRAINT template_versions_producer_brand_check
            CHECK (jsonb_typeof(producer_brand) = 'object' AND pg_column_size(producer_brand) <= 16384),
        variables jsonb
          CONSTRAINT template_versions_variables_check
            CHECK (jsonb_typeof(variables) = 'object' AND pg_column_size(variables) <= 262144),
        measures jsonb
          CONSTRAINT template_versions_measures_check
            CHECK (jsonb_typeof(measures) = 'object' AND pg_column_size(measures) <= 262144),
        findings jsonb
          CONSTRAINT template_versions_findings_check
            CHECK (jsonb_typeof(findings) = 'array' AND pg_column_size(findings) <= 262144),
        warnings_accepted boolean NOT NULL,
        warnings_accepted_by_ref text
          CONSTRAINT template_versions_warnings_accepted_by_ref_check
            CHECK (char_length(warnings_accepted_by_ref) BETWEEN 1 AND 256),
        diff jsonb
          CONSTRAINT template_versions_diff_check
            CHECK (jsonb_typeof(diff) = 'object' AND pg_column_size(diff) <= 262144),
        previous_version_no bigint
          CONSTRAINT template_versions_previous_version_no_check CHECK (previous_version_no >= 1),
        drafted_by_ref text
          CONSTRAINT template_versions_drafted_by_ref_check
            CHECK (char_length(drafted_by_ref) BETWEEN 1 AND 256),
        published_at timestamptz,
        published_by_ref text
          CONSTRAINT template_versions_published_by_ref_check
            CHECK (char_length(published_by_ref) BETWEEN 1 AND 256),
        archived_at timestamptz,
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT template_versions_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT template_versions_version_no_key
          UNIQUE (tenant_id, environment, template_id, version_no),
        CONSTRAINT template_versions_numbered_check
          CHECK ((state <> 'draft' OR version_no IS NULL)
            AND (state <> 'published' OR version_no IS NOT NULL)),
        CONSTRAINT template_versions_published_check
          CHECK ((version_no IS NULL) = (published_at IS NULL)
            AND (version_no IS NULL) = (published_by_ref IS NULL)),
        CONSTRAINT template_versions_gate_check
          CHECK (version_no IS NULL OR (sensitivity IS NOT NULL AND variables IS NOT NULL
            AND measures IS NOT NULL AND findings IS NOT NULL)),
        CONSTRAINT template_versions_warnings_check
          CHECK (warnings_accepted = (warnings_accepted_by_ref IS NOT NULL)),
        CONSTRAINT template_versions_archived_check
          CHECK ((state = 'archived') = (archived_at IS NOT NULL)),
        CONSTRAINT template_versions_template_id_fkey FOREIGN KEY (tenant_id, environment, template_id)
          REFERENCES relay.templates (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE UNIQUE INDEX template_versions_draft_key ON relay.template_versions
        (tenant_id, environment, template_id) WHERE state = 'draft'
      """,
      """
      CREATE UNIQUE INDEX template_versions_checksum_key ON relay.template_versions
        (tenant_id, environment, template_id, checksum) WHERE version_no IS NOT NULL
      """,
      """
      ALTER TABLE relay.templates ADD CONSTRAINT templates_live_version_id_fkey
        FOREIGN KEY (tenant_id, environment, live_version_id)
        REFERENCES relay.template_versions (tenant_id, environment, id)
        ON DELETE RESTRICT ON UPDATE RESTRICT DEFERRABLE INITIALLY DEFERRED
      """,
      """
      CREATE INDEX templates_category_index ON relay.templates (tenant_id, environment, category_id)
      """,
      ~S"""
      CREATE FUNCTION relay_private.templates_guard() RETURNS trigger
        LANGUAGE plpgsql
        SET search_path = pg_catalog, pg_temp
        SET TimeZone = 'UTC'
      AS $fn$
      BEGIN
        IF NEW.tenant_id = OLD.tenant_id AND NEW.environment = OLD.environment
          AND NEW.id = OLD.id AND NEW.key = OLD.key
          AND NEW.subtenant_id IS NOT DISTINCT FROM OLD.subtenant_id AND NEW.owner = OLD.owner
          AND NEW.owner_product IS NOT DISTINCT FROM OLD.owner_product
          AND NEW.created_at = OLD.created_at AND OLD.state = 'active'
          AND (OLD.first_published_at IS NULL
            OR (NEW.first_published_at = OLD.first_published_at
              AND NEW.message_class = OLD.message_class
              AND NEW.template_type = OLD.template_type)) THEN
          RETURN NEW;
        END IF;
        RAISE EXCEPTION 'invariant_violation'
          USING DETAIL = format('%s on %I.%I is not allowed', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME),
                HINT = 'INV-21';
      END
      $fn$
      """,
      "REVOKE ALL ON FUNCTION relay_private.templates_guard() FROM PUBLIC",
      """
      CREATE TRIGGER templates_guard BEFORE UPDATE ON relay.templates
        FOR EACH ROW EXECUTE FUNCTION relay_private.templates_guard()
      """,
      ~S"""
      CREATE FUNCTION relay_private.template_versions_guard() RETURNS trigger
        LANGUAGE plpgsql
        SET search_path = pg_catalog, pg_temp
        SET TimeZone = 'UTC'
      AS $fn$
      BEGIN
        IF NEW.tenant_id = OLD.tenant_id AND NEW.environment = OLD.environment
          AND NEW.id = OLD.id AND NEW.template_id = OLD.template_id
          AND NEW.created_at = OLD.created_at
          AND ((OLD.state = 'draft' AND NEW.state IN ('draft', 'published', 'archived'))
            OR (OLD.state = 'published' AND NEW.state = 'archived'
              AND NEW.version_no = OLD.version_no AND NEW.checksum = OLD.checksum
              AND NEW.cells = OLD.cells AND NEW.default_locale = OLD.default_locale
              AND NEW.sensitivity = OLD.sensitivity
              AND NEW.sensitivity_approval IS NOT DISTINCT FROM OLD.sensitivity_approval
              AND NEW.sms_encoding = OLD.sms_encoding AND NEW.transliterate = OLD.transliterate
              AND NEW.allow_raw = OLD.allow_raw
              AND NEW.layout_key IS NOT DISTINCT FROM OLD.layout_key
              AND NEW.partial_keys = OLD.partial_keys
              AND NEW.producer_brand IS NOT DISTINCT FROM OLD.producer_brand
              AND NEW.variables = OLD.variables AND NEW.measures = OLD.measures
              AND NEW.findings = OLD.findings AND NEW.warnings_accepted = OLD.warnings_accepted
              AND NEW.warnings_accepted_by_ref IS NOT DISTINCT FROM OLD.warnings_accepted_by_ref
              AND NEW.diff IS NOT DISTINCT FROM OLD.diff
              AND NEW.previous_version_no IS NOT DISTINCT FROM OLD.previous_version_no
              AND NEW.drafted_by_ref IS NOT DISTINCT FROM OLD.drafted_by_ref
              AND NEW.published_at = OLD.published_at
              AND NEW.published_by_ref = OLD.published_by_ref)) THEN
          RETURN NEW;
        END IF;
        RAISE EXCEPTION 'invariant_violation'
          USING DETAIL = format('%s on %I.%I is not allowed', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME),
                HINT = 'TP-31';
      END
      $fn$
      """,
      "REVOKE ALL ON FUNCTION relay_private.template_versions_guard() FROM PUBLIC",
      """
      CREATE TRIGGER template_versions_guard BEFORE UPDATE ON relay.template_versions
        FOR EACH ROW EXECUTE FUNCTION relay_private.template_versions_guard()
      """
    ] ++ no_delete("templates") ++ no_delete("template_versions")
  end

  defp asset_statements(kind) do
    table = kind <> "s"
    versions = kind <> "_versions"

    [
      """
      CREATE TABLE relay.#{table} (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        key text NOT NULL CONSTRAINT #{table}_key_check CHECK (key ~ #{@key} AND char_length(key) <= 100),
        subtenant_id uuid,
        owner text NOT NULL CONSTRAINT #{table}_owner_check CHECK (owner IN ('tenant', 'subtenant')),
        name text NOT NULL CONSTRAINT #{table}_name_check CHECK (char_length(name) BETWEEN 1 AND 200),
        state text NOT NULL CONSTRAINT #{table}_state_check CHECK (state IN ('active', 'archived')),
        archived_at timestamptz,
        live_version_id uuid,
        live_version_no bigint CONSTRAINT #{table}_live_version_no_check CHECK (live_version_no >= 1),
        version bigint NOT NULL CONSTRAINT #{table}_version_check CHECK (version >= 1),
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT #{table}_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT #{table}_key_key UNIQUE NULLS NOT DISTINCT (tenant_id, environment, subtenant_id, key),
        CONSTRAINT #{table}_subtenant_check CHECK ((owner = 'subtenant') = (subtenant_id IS NOT NULL)),
        CONSTRAINT #{table}_live_check CHECK ((live_version_id IS NULL) = (live_version_no IS NULL)),
        CONSTRAINT #{table}_archived_check CHECK ((state = 'archived') = (archived_at IS NOT NULL)),
        CONSTRAINT #{table}_subtenant_id_fkey FOREIGN KEY (tenant_id, environment, subtenant_id)
          REFERENCES relay.subtenants (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE TABLE relay.#{versions} (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        #{kind}_id uuid NOT NULL,
        state text NOT NULL
          CONSTRAINT #{versions}_state_check CHECK (state IN ('draft', 'published', 'archived')),
        version_no bigint CONSTRAINT #{versions}_version_no_check CHECK (version_no >= 1),
        checksum relay.sha256 NOT NULL,
        content jsonb NOT NULL
          CONSTRAINT #{versions}_content_check
            CHECK (jsonb_typeof(content) = 'object' AND pg_column_size(content) <= 1048576),
        findings jsonb
          CONSTRAINT #{versions}_findings_check
            CHECK (jsonb_typeof(findings) = 'array' AND pg_column_size(findings) <= 262144),
        warnings_accepted boolean NOT NULL,
        warnings_accepted_by_ref text
          CONSTRAINT #{versions}_warnings_accepted_by_ref_check
            CHECK (char_length(warnings_accepted_by_ref) BETWEEN 1 AND 256),
        diff jsonb
          CONSTRAINT #{versions}_diff_check
            CHECK (jsonb_typeof(diff) = 'object' AND pg_column_size(diff) <= 262144),
        previous_version_no bigint
          CONSTRAINT #{versions}_previous_version_no_check CHECK (previous_version_no >= 1),
        drafted_by_ref text
          CONSTRAINT #{versions}_drafted_by_ref_check
            CHECK (char_length(drafted_by_ref) BETWEEN 1 AND 256),
        published_at timestamptz,
        published_by_ref text
          CONSTRAINT #{versions}_published_by_ref_check
            CHECK (char_length(published_by_ref) BETWEEN 1 AND 256),
        archived_at timestamptz,
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT #{versions}_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT #{versions}_version_no_key UNIQUE (tenant_id, environment, #{kind}_id, version_no),
        CONSTRAINT #{versions}_numbered_check
          CHECK ((state <> 'draft' OR version_no IS NULL)
            AND (state <> 'published' OR version_no IS NOT NULL)),
        CONSTRAINT #{versions}_published_check
          CHECK ((version_no IS NULL) = (published_at IS NULL)
            AND (version_no IS NULL) = (published_by_ref IS NULL)
            AND (version_no IS NULL OR findings IS NOT NULL)),
        CONSTRAINT #{versions}_warnings_check
          CHECK (warnings_accepted = (warnings_accepted_by_ref IS NOT NULL)),
        CONSTRAINT #{versions}_archived_check CHECK ((state = 'archived') = (archived_at IS NOT NULL)),
        CONSTRAINT #{versions}_#{kind}_id_fkey FOREIGN KEY (tenant_id, environment, #{kind}_id)
          REFERENCES relay.#{table} (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE UNIQUE INDEX #{versions}_draft_key ON relay.#{versions}
        (tenant_id, environment, #{kind}_id) WHERE state = 'draft'
      """,
      """
      CREATE UNIQUE INDEX #{versions}_checksum_key ON relay.#{versions}
        (tenant_id, environment, #{kind}_id, checksum) WHERE version_no IS NOT NULL
      """,
      """
      ALTER TABLE relay.#{table} ADD CONSTRAINT #{table}_live_version_id_fkey
        FOREIGN KEY (tenant_id, environment, live_version_id)
        REFERENCES relay.#{versions} (tenant_id, environment, id)
        ON DELETE RESTRICT ON UPDATE RESTRICT DEFERRABLE INITIALLY DEFERRED
      """,
      """
      CREATE FUNCTION relay_private.#{table}_guard() RETURNS trigger
        LANGUAGE plpgsql
        SET search_path = pg_catalog, pg_temp
        SET TimeZone = 'UTC'
      AS $fn$
      BEGIN
        IF NEW.tenant_id = OLD.tenant_id AND NEW.environment = OLD.environment
          AND NEW.id = OLD.id AND NEW.key = OLD.key
          AND NEW.subtenant_id IS NOT DISTINCT FROM OLD.subtenant_id AND NEW.owner = OLD.owner
          AND NEW.created_at = OLD.created_at AND OLD.state = 'active' THEN
          RETURN NEW;
        END IF;
        RAISE EXCEPTION 'invariant_violation'
          USING DETAIL = format('%s on %I.%I is not allowed', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME),
                HINT = 'TP-35';
      END
      $fn$
      """,
      "REVOKE ALL ON FUNCTION relay_private.#{table}_guard() FROM PUBLIC",
      """
      CREATE TRIGGER #{table}_guard BEFORE UPDATE ON relay.#{table}
        FOR EACH ROW EXECUTE FUNCTION relay_private.#{table}_guard()
      """,
      """
      CREATE FUNCTION relay_private.#{versions}_guard() RETURNS trigger
        LANGUAGE plpgsql
        SET search_path = pg_catalog, pg_temp
        SET TimeZone = 'UTC'
      AS $fn$
      BEGIN
        IF NEW.tenant_id = OLD.tenant_id AND NEW.environment = OLD.environment
          AND NEW.id = OLD.id AND NEW.#{kind}_id = OLD.#{kind}_id
          AND NEW.created_at = OLD.created_at
          AND ((OLD.state = 'draft' AND NEW.state IN ('draft', 'published', 'archived'))
            OR (OLD.state = 'published' AND NEW.state = 'archived'
              AND NEW.version_no = OLD.version_no AND NEW.checksum = OLD.checksum
              AND NEW.content = OLD.content AND NEW.findings = OLD.findings
              AND NEW.warnings_accepted = OLD.warnings_accepted
              AND NEW.warnings_accepted_by_ref IS NOT DISTINCT FROM OLD.warnings_accepted_by_ref
              AND NEW.diff IS NOT DISTINCT FROM OLD.diff
              AND NEW.previous_version_no IS NOT DISTINCT FROM OLD.previous_version_no
              AND NEW.drafted_by_ref IS NOT DISTINCT FROM OLD.drafted_by_ref
              AND NEW.published_at = OLD.published_at
              AND NEW.published_by_ref = OLD.published_by_ref)) THEN
          RETURN NEW;
        END IF;
        RAISE EXCEPTION 'invariant_violation'
          USING DETAIL = format('%s on %I.%I is not allowed', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME),
                HINT = 'TP-31';
      END
      $fn$
      """,
      "REVOKE ALL ON FUNCTION relay_private.#{versions}_guard() FROM PUBLIC",
      """
      CREATE TRIGGER #{versions}_guard BEFORE UPDATE ON relay.#{versions}
        FOR EACH ROW EXECUTE FUNCTION relay_private.#{versions}_guard()
      """
    ] ++ no_delete(table) ++ no_delete(versions)
  end

  defp plan_statements do
    [
      """
      CREATE TABLE relay.delivery_render_plans (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        delivery_id uuid NOT NULL,
        template_id uuid NOT NULL,
        template_version_id uuid NOT NULL,
        layout_version_id uuid,
        partial_version_ids uuid[] NOT NULL
          CONSTRAINT delivery_render_plans_partial_version_ids_check
            CHECK (cardinality(partial_version_ids) <= 50),
        locale text NOT NULL
          CONSTRAINT delivery_render_plans_locale_check
            CHECK (locale ~ #{@locale} AND char_length(locale) <= 35),
        locale_fallback boolean NOT NULL,
        render_digest relay.sha256,
        render_measures jsonb
          CONSTRAINT delivery_render_plans_render_measures_check
            CHECK (jsonb_typeof(render_measures) = 'object'
              AND pg_column_size(render_measures) <= 65536),
        rendered_at timestamptz,
        render_count bigint NOT NULL
          CONSTRAINT delivery_render_plans_render_count_check CHECK (render_count >= 0),
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT delivery_render_plans_pkey PRIMARY KEY (tenant_id, environment, delivery_id),
        CONSTRAINT delivery_render_plans_rendered_check
          CHECK ((render_digest IS NULL) = (rendered_at IS NULL)
            AND (render_digest IS NULL) = (render_measures IS NULL)),
        CONSTRAINT delivery_render_plans_delivery_id_fkey
          FOREIGN KEY (tenant_id, environment, delivery_id)
          REFERENCES relay.deliveries (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT delivery_render_plans_template_id_fkey
          FOREIGN KEY (tenant_id, environment, template_id)
          REFERENCES relay.templates (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT delivery_render_plans_template_version_id_fkey
          FOREIGN KEY (tenant_id, environment, template_version_id)
          REFERENCES relay.template_versions (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT delivery_render_plans_layout_version_id_fkey
          FOREIGN KEY (tenant_id, environment, layout_version_id)
          REFERENCES relay.layout_versions (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE INDEX delivery_render_plans_template_version_index ON relay.delivery_render_plans
        (tenant_id, environment, template_version_id)
      """,
      ~S"""
      CREATE FUNCTION relay_private.delivery_render_plans_guard() RETURNS trigger
        LANGUAGE plpgsql
        SET search_path = pg_catalog, pg_temp
        SET TimeZone = 'UTC'
      AS $fn$
      BEGIN
        IF NEW.tenant_id = OLD.tenant_id AND NEW.environment = OLD.environment
          AND NEW.delivery_id = OLD.delivery_id AND NEW.template_id = OLD.template_id
          AND NEW.template_version_id = OLD.template_version_id
          AND NEW.layout_version_id IS NOT DISTINCT FROM OLD.layout_version_id
          AND NEW.partial_version_ids = OLD.partial_version_ids AND NEW.locale = OLD.locale
          AND NEW.locale_fallback = OLD.locale_fallback AND NEW.created_at = OLD.created_at
          AND NEW.render_count >= OLD.render_count
          AND (OLD.render_digest IS NULL OR (NEW.render_digest = OLD.render_digest
            AND NEW.render_measures = OLD.render_measures AND NEW.rendered_at = OLD.rendered_at)) THEN
          RETURN NEW;
        END IF;
        RAISE EXCEPTION 'invariant_violation'
          USING DETAIL = format('%s on %I.%I is not allowed', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME),
                HINT = 'TP-50';
      END
      $fn$
      """,
      "REVOKE ALL ON FUNCTION relay_private.delivery_render_plans_guard() FROM PUBLIC",
      """
      CREATE TRIGGER delivery_render_plans_guard BEFORE UPDATE ON relay.delivery_render_plans
        FOR EACH ROW EXECUTE FUNCTION relay_private.delivery_render_plans_guard()
      """,
      """
      CREATE TABLE relay.render_snapshots (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        delivery_id uuid NOT NULL,
        recipient_id uuid NOT NULL,
        template_version_id uuid NOT NULL,
        retention_class relay.retention_class NOT NULL
          CONSTRAINT render_snapshots_retention_class_check
            CHECK (retention_class IN ('notification_content', 'commercial_message')),
        content_digest relay.sha256 NOT NULL,
        content_ct bytea
          CONSTRAINT render_snapshots_content_ct_check CHECK (octet_length(content_ct) <= 4194304),
        content_key_id uuid,
        digest_reason text
          CONSTRAINT render_snapshots_digest_reason_check
            CHECK (digest_reason IN ('security_subtype', 'retention_none')),
        created_at timestamptz NOT NULL,
        CONSTRAINT render_snapshots_pkey PRIMARY KEY (tenant_id, environment, delivery_id),
        CONSTRAINT render_snapshots_content_check
          CHECK ((content_ct IS NULL) = (content_key_id IS NULL)
            AND (content_ct IS NULL) = (digest_reason IS NOT NULL)),
        CONSTRAINT render_snapshots_delivery_id_fkey FOREIGN KEY (tenant_id, environment, delivery_id)
          REFERENCES relay.deliveries (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT render_snapshots_recipient_id_fkey FOREIGN KEY (tenant_id, environment, recipient_id)
          REFERENCES relay.recipients (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT render_snapshots_template_version_id_fkey
          FOREIGN KEY (tenant_id, environment, template_version_id)
          REFERENCES relay.template_versions (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT render_snapshots_content_key_id_fkey
          FOREIGN KEY (tenant_id, environment, content_key_id)
          REFERENCES relay.subject_keys (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE INDEX render_snapshots_recipient_index ON relay.render_snapshots
        (tenant_id, environment, recipient_id)
      """
    ] ++ no_delete("delivery_render_plans")
  end
end
