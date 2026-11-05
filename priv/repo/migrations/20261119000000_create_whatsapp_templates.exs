defmodule Relay.Repo.Migrations.CreateWhatsappTemplates do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  # CH-57
  # TP-23
  # CH-14
  def up do
    execute(~S"""
    CREATE TABLE relay.whatsapp_templates (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      id uuid NOT NULL,
      provider_account_id uuid NOT NULL,
      waba_id text NOT NULL CONSTRAINT whatsapp_templates_waba_id_check CHECK (waba_id ~ '^[0-9]{1,32}$'),
      name text NOT NULL
        CONSTRAINT whatsapp_templates_name_check CHECK (name ~ '^[a-z0-9_]{1,512}$'),
      language text NOT NULL
        CONSTRAINT whatsapp_templates_language_check
          CHECK (language ~ '^[a-z]{2,3}(_[A-Za-z0-9]{2,8}){0,2}$'),
      message_class text NOT NULL
        CONSTRAINT whatsapp_templates_message_class_check
          CHECK (message_class IN ('security', 'action_required', 'transactional', 'operational',
            'social', 'marketing')),
      category text NOT NULL
        CONSTRAINT whatsapp_templates_category_check
          CHECK (category IN ('authentication', 'utility', 'marketing')),
      meta_category text
        CONSTRAINT whatsapp_templates_meta_category_check
          CHECK (meta_category IN ('authentication', 'utility', 'marketing')),
      status text NOT NULL
        CONSTRAINT whatsapp_templates_status_check
          CHECK (status IN ('pending_approval', 'approved', 'rejected', 'paused', 'disabled')),
      meta_status text
        CONSTRAINT whatsapp_templates_meta_status_check CHECK (meta_status ~ '^[A-Z_]{1,64}$'),
      meta_template_id text
        CONSTRAINT whatsapp_templates_meta_template_id_check
          CHECK (meta_template_id ~ '^[0-9]{1,32}$'),
      rejection_reason text
        CONSTRAINT whatsapp_templates_rejection_reason_check
          CHECK (char_length(rejection_reason) BETWEEN 1 AND 512),
      quality text CONSTRAINT whatsapp_templates_quality_check CHECK (quality ~ '^[A-Z_]{1,32}$'),
      components jsonb NOT NULL
        CONSTRAINT whatsapp_templates_components_check
          CHECK (jsonb_typeof(components) = 'array' AND pg_column_size(components) <= 65536),
      approved_components jsonb
        CONSTRAINT whatsapp_templates_approved_components_check
          CHECK (jsonb_typeof(approved_components) = 'array'
            AND pg_column_size(approved_components) <= 65536),
      content_digest relay.sha256 NOT NULL,
      edits timestamptz[] NOT NULL
        CONSTRAINT whatsapp_templates_edits_check CHECK (cardinality(edits) <= 64),
      status_changed_at timestamptz NOT NULL,
      version bigint NOT NULL,
      created_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      CONSTRAINT whatsapp_templates_pkey PRIMARY KEY (tenant_id, environment, id),
      CONSTRAINT whatsapp_templates_name_key
        UNIQUE (tenant_id, environment, provider_account_id, name, language),
      CONSTRAINT whatsapp_templates_rejection_check
        CHECK (status = 'rejected' OR rejection_reason IS NULL),
      CONSTRAINT whatsapp_templates_provider_account_id_fkey
        FOREIGN KEY (tenant_id, environment, provider_account_id)
        REFERENCES relay.provider_accounts (tenant_id, environment, id)
        ON DELETE RESTRICT ON UPDATE RESTRICT
    )
    """)

    execute("""
    CREATE INDEX whatsapp_templates_list_index ON relay.whatsapp_templates
      (tenant_id, environment, created_at, id)
    """)

    scoped("whatsapp_templates")
  end

  def down, do: :ok

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
