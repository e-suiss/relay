defmodule Relay.Repo.Migrations.CreateRoutes do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  # WF-13
  # WF-14
  # WF-59
  # TN-12
  # TN-13
  # OP-9
  def up do
    execute(~S"""
    CREATE TABLE relay.routes (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      id uuid NOT NULL,
      key text NOT NULL CONSTRAINT routes_key_check CHECK (key ~ '^[a-z][a-z0-9_]{0,63}$'),
      name text NOT NULL CONSTRAINT routes_name_check CHECK (char_length(name) BETWEEN 1 AND 200),
      tree jsonb NOT NULL CONSTRAINT routes_tree_check CHECK (pg_column_size(tree) <= 65536),
      state text NOT NULL CONSTRAINT routes_state_check CHECK (state IN ('active', 'archived')),
      archived_at timestamptz,
      version bigint NOT NULL CONSTRAINT routes_version_check CHECK (version >= 1),
      created_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      CONSTRAINT routes_pkey PRIMARY KEY (tenant_id, environment, id),
      CONSTRAINT routes_key_key UNIQUE (tenant_id, environment, key),
      CONSTRAINT routes_archived_check CHECK ((state = 'archived') = (archived_at IS NOT NULL))
    )
    """)

    execute("""
    CREATE TRIGGER routes_no_delete BEFORE DELETE ON relay.routes
      FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    execute("ALTER TABLE relay.routes ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE relay.routes FORCE ROW LEVEL SECURITY")

    execute(
      "CREATE POLICY routes_scope ON relay.routes USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})"
    )

    execute("GRANT SELECT, INSERT, UPDATE ON relay.routes TO relay_owner")
    execute("GRANT SELECT ON relay.routes TO relay_app, relay_maint, relay_archive, relay_report")

    execute("ALTER TABLE relay.categories ADD COLUMN default_route text")

    execute(~S"""
    ALTER TABLE relay.categories ADD CONSTRAINT categories_default_route_check
      CHECK (default_route ~ '^[a-z][a-z0-9_]{0,63}$') NOT VALID
    """)
  end

  def down, do: :ok
end
