defmodule Relay.Repo.Migrations.CreateWebhookSources do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  # WH-68
  # WH-50
  # TN-26
  # OP-9
  def up do
    Enum.each(statements(), &execute/1)
  end

  def down, do: :ok

  defp statements do
    [
      ~S"""
      CREATE TABLE relay.webhook_sources (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        name text NOT NULL
          CONSTRAINT webhook_sources_name_check CHECK (char_length(name) BETWEEN 1 AND 256),
        scheme text NOT NULL
          CONSTRAINT webhook_sources_scheme_check CHECK (scheme IN ('v1a', 'v1')),
        public_key bytea
          CONSTRAINT webhook_sources_public_key_check CHECK (octet_length(public_key) = 32),
        secret_ref_id uuid,
        state text NOT NULL
          CONSTRAINT webhook_sources_state_check CHECK (state IN ('active', 'archived')),
        archived_at timestamptz,
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT webhook_sources_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT webhook_sources_key_check
          CHECK ((scheme = 'v1a') = (public_key IS NOT NULL)
            AND (scheme = 'v1') = (secret_ref_id IS NOT NULL)),
        CONSTRAINT webhook_sources_archived_check
          CHECK ((state = 'archived') = (archived_at IS NOT NULL)),
        CONSTRAINT webhook_sources_secret_ref_id_fkey
          FOREIGN KEY (tenant_id, environment, secret_ref_id)
          REFERENCES relay.secret_refs (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE TRIGGER webhook_sources_no_delete BEFORE DELETE ON relay.webhook_sources
        FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
      """,
      """
      CREATE TRIGGER webhook_sources_no_truncate BEFORE TRUNCATE ON relay.webhook_sources
        FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
      """,
      "ALTER TABLE relay.webhook_sources ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE relay.webhook_sources FORCE ROW LEVEL SECURITY",
      "CREATE POLICY webhook_sources_scope ON relay.webhook_sources USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})",
      "GRANT SELECT, INSERT, UPDATE ON relay.webhook_sources TO relay_owner",
      "GRANT SELECT ON relay.webhook_sources TO relay_app, relay_maint, relay_archive, relay_report"
    ]
  end
end
