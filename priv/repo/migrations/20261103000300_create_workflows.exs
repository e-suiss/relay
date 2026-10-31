defmodule Relay.Repo.Migrations.CreateWorkflows do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  # WF-1
  # WF-5
  # WF-6
  # WF-7
  # INV-48
  # C-40
  # API-69
  # TN-12
  # TN-13
  def up do
    execute(~S"""
    CREATE TABLE relay.workflows (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      id uuid NOT NULL,
      key relay.workflow_key NOT NULL,
      name text NOT NULL CONSTRAINT workflows_name_check CHECK (char_length(name) BETWEEN 1 AND 200),
      managed_by text NOT NULL DEFAULT 'panel'
        CONSTRAINT workflows_managed_by_check CHECK (managed_by IN ('panel', 'code')),
      state text NOT NULL CONSTRAINT workflows_state_check CHECK (state IN ('active', 'archived')),
      published_version_id uuid,
      published_version_no bigint
        CONSTRAINT workflows_published_version_no_check CHECK (published_version_no >= 1),
      version bigint NOT NULL CONSTRAINT workflows_version_check CHECK (version >= 1),
      created_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      CONSTRAINT workflows_pkey PRIMARY KEY (tenant_id, environment, id),
      CONSTRAINT workflows_key_key UNIQUE (tenant_id, environment, key),
      CONSTRAINT workflows_published_check
        CHECK ((published_version_id IS NULL) = (published_version_no IS NULL))
    )
    """)

    execute(~S"""
    CREATE TABLE relay.workflow_versions (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      id uuid NOT NULL,
      workflow_id uuid NOT NULL,
      state text NOT NULL
        CONSTRAINT workflow_versions_state_check
          CHECK (state IN ('draft', 'pending', 'published', 'rejected', 'discarded')),
      version_no bigint CONSTRAINT workflow_versions_version_no_check CHECK (version_no >= 1),
      definition jsonb NOT NULL
        CONSTRAINT workflow_versions_definition_check CHECK (pg_column_size(definition) <= 524288),
      definition_digest relay.sha256 NOT NULL,
      event_schema jsonb NOT NULL
        CONSTRAINT workflow_versions_event_schema_check CHECK (pg_column_size(event_schema) <= 65536),
      message_class relay.message_class NOT NULL,
      category text NOT NULL
        CONSTRAINT workflow_versions_category_check CHECK (category ~ '^[a-z][a-z0-9_]{0,63}$'),
      promoted_from_version_no bigint
        CONSTRAINT workflow_versions_promoted_from_version_no_check
          CHECK (promoted_from_version_no >= 1),
      publication_errors jsonb
        CONSTRAINT workflow_versions_publication_errors_check
          CHECK (pg_column_size(publication_errors) <= 65536),
      requested_at timestamptz,
      published_at timestamptz,
      published_by_ref text
        CONSTRAINT workflow_versions_published_by_ref_check
          CHECK (char_length(published_by_ref) BETWEEN 1 AND 256),
      created_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      CONSTRAINT workflow_versions_pkey PRIMARY KEY (tenant_id, environment, id),
      CONSTRAINT workflow_versions_version_no_key
        UNIQUE (tenant_id, environment, workflow_id, version_no),
      CONSTRAINT workflow_versions_published_check
        CHECK ((state = 'published') = (version_no IS NOT NULL)),
      CONSTRAINT workflow_versions_published_at_check
        CHECK ((state = 'published') = (published_at IS NOT NULL)),
      CONSTRAINT workflow_versions_requested_at_check
        CHECK (state IN ('draft', 'discarded') OR requested_at IS NOT NULL),
      CONSTRAINT workflow_versions_workflow_id_fkey FOREIGN KEY (tenant_id, environment, workflow_id)
        REFERENCES relay.workflows (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
    )
    """)

    execute("""
    CREATE UNIQUE INDEX workflow_versions_draft_key ON relay.workflow_versions
      (tenant_id, environment, workflow_id) WHERE state = 'draft'
    """)

    execute("""
    CREATE UNIQUE INDEX workflow_versions_pending_key ON relay.workflow_versions
      (tenant_id, environment, workflow_id) WHERE state = 'pending'
    """)

    execute("""
    ALTER TABLE relay.workflows ADD CONSTRAINT workflows_published_version_id_fkey
      FOREIGN KEY (tenant_id, environment, published_version_id)
      REFERENCES relay.workflow_versions (tenant_id, environment, id)
      ON DELETE RESTRICT ON UPDATE RESTRICT DEFERRABLE INITIALLY DEFERRED
    """)

    execute(~S"""
    CREATE FUNCTION relay_private.workflow_versions_guard() RETURNS trigger
      LANGUAGE plpgsql
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
    AS $fn$
    BEGIN
      IF TG_OP = 'UPDATE'
        AND ((OLD.state = 'draft' AND NEW.state IN ('discarded', 'pending'))
          OR (OLD.state = 'pending' AND NEW.state IN ('published', 'rejected')))
        AND NEW.tenant_id = OLD.tenant_id AND NEW.environment = OLD.environment
        AND NEW.id = OLD.id AND NEW.workflow_id = OLD.workflow_id
        AND NEW.definition = OLD.definition AND NEW.definition_digest = OLD.definition_digest
        AND NEW.event_schema = OLD.event_schema AND NEW.message_class = OLD.message_class
        AND NEW.category = OLD.category
        AND NEW.promoted_from_version_no IS NOT DISTINCT FROM OLD.promoted_from_version_no
        AND NEW.created_at = OLD.created_at THEN
        RETURN NEW;
      END IF;
      RAISE EXCEPTION 'invariant_violation'
        USING DETAIL = format('%s on %I.%I is not allowed', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME),
              HINT = 'INV-48';
    END
    $fn$
    """)

    execute("REVOKE ALL ON FUNCTION relay_private.workflow_versions_guard() FROM PUBLIC")

    execute("""
    CREATE TRIGGER workflow_versions_guard BEFORE UPDATE ON relay.workflow_versions
      FOR EACH ROW EXECUTE FUNCTION relay_private.workflow_versions_guard()
    """)

    execute("""
    CREATE TRIGGER workflow_versions_no_delete BEFORE DELETE ON relay.workflow_versions
      FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    execute("""
    CREATE TRIGGER workflow_versions_no_truncate BEFORE TRUNCATE ON relay.workflow_versions
      FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    scoped("workflows")
    scoped("workflow_versions")
  end

  defp scoped(table) do
    execute("ALTER TABLE relay.#{table} ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE relay.#{table} FORCE ROW LEVEL SECURITY")

    execute(
      "CREATE POLICY #{table}_scope ON relay.#{table} USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})"
    )

    execute("GRANT SELECT, INSERT, UPDATE ON relay.#{table} TO relay_owner")

    execute(
      "GRANT SELECT ON relay.#{table} TO relay_app, relay_maint, relay_archive, relay_report"
    )
  end
end
