defmodule Relay.Repo.Migrations.CreateReportVariantRollups do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  # WF-50
  # DS-35
  # DS-39
  # TN-18
  def up do
    execute(~S"""
    CREATE TABLE relay.report_variant_rollups (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      report_day date NOT NULL,
      workflow_key text NOT NULL
        CONSTRAINT report_variant_rollups_workflow_key_check
          CHECK (char_length(workflow_key) <= 128),
      step_key text NOT NULL
        CONSTRAINT report_variant_rollups_step_key_check CHECK (char_length(step_key) <= 128),
      variant text NOT NULL
        CONSTRAINT report_variant_rollups_variant_check CHECK (char_length(variant) <= 128),
      channel relay.channel NOT NULL,
      is_test boolean NOT NULL,
      accepted bigint NOT NULL,
      sent bigint NOT NULL,
      delivered bigint NOT NULL,
      seen bigint NOT NULL,
      human_clicks bigint NOT NULL,
      bot_clicks bigint NOT NULL,
      recomputed_at timestamptz NOT NULL,
      CONSTRAINT report_variant_rollups_pkey PRIMARY KEY
        (tenant_id, environment, report_day, workflow_key, step_key, variant, channel, is_test),
      CONSTRAINT report_variant_rollups_counts_check CHECK (accepted >= 0 AND sent >= 0
        AND delivered >= 0 AND seen >= 0 AND human_clicks >= 0 AND bot_clicks >= 0)
    )
    """)

    execute("""
    CREATE TRIGGER report_variant_rollups_no_delete BEFORE DELETE ON relay.report_variant_rollups
      FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    execute("ALTER TABLE relay.report_variant_rollups ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE relay.report_variant_rollups FORCE ROW LEVEL SECURITY")

    execute(
      "CREATE POLICY report_variant_rollups_scope ON relay.report_variant_rollups USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})"
    )

    execute("GRANT SELECT, INSERT, UPDATE ON relay.report_variant_rollups TO relay_owner")

    execute(
      "GRANT SELECT ON relay.report_variant_rollups TO relay_app, relay_maint, relay_archive, relay_report"
    )
  end

  def down, do: :ok
end
