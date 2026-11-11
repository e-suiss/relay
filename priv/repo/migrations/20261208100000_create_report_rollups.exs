defmodule Relay.Repo.Migrations.CreateReportRollups do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  # DS-35
  # DS-36
  # DS-39
  # OP-39
  # F-7
  # TN-12
  # TN-13
  # TN-18
  def up do
    execute(~S"""
    CREATE TABLE relay.report_delivery_rollups (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      report_day date NOT NULL,
      channel relay.channel NOT NULL,
      provider text NOT NULL
        CONSTRAINT report_delivery_rollups_provider_check CHECK (char_length(provider) <= 64),
      is_test boolean NOT NULL,
      accepted bigint NOT NULL,
      enqueued bigint NOT NULL,
      dispatched bigint NOT NULL,
      provider_accepted bigint NOT NULL,
      delivered bigint NOT NULL,
      engaged bigint NOT NULL,
      sdk_receipts bigint NOT NULL,
      skipped bigint NOT NULL,
      failed bigint NOT NULL,
      uncertain bigint NOT NULL,
      expired bigint NOT NULL,
      cancelled bigint NOT NULL,
      duplicate_delivered bigint NOT NULL,
      conflicts bigint NOT NULL,
      human_clicks bigint NOT NULL,
      bot_clicks bigint NOT NULL,
      opens bigint NOT NULL,
      machine_opens bigint NOT NULL,
      recomputed_at timestamptz NOT NULL,
      CONSTRAINT report_delivery_rollups_pkey
        PRIMARY KEY (tenant_id, environment, report_day, channel, provider, is_test),
      CONSTRAINT report_delivery_rollups_counts_check CHECK (accepted >= 0 AND enqueued >= 0
        AND dispatched >= 0 AND provider_accepted >= 0 AND delivered >= 0 AND engaged >= 0
        AND sdk_receipts >= 0 AND skipped >= 0 AND failed >= 0 AND uncertain >= 0
        AND expired >= 0 AND cancelled >= 0 AND duplicate_delivered >= 0 AND conflicts >= 0
        AND human_clicks >= 0 AND bot_clicks >= 0 AND opens >= 0 AND machine_opens >= 0)
    )
    """)

    execute(~S"""
    CREATE TABLE relay.report_skip_rollups (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      report_day date NOT NULL,
      channel relay.channel NOT NULL,
      is_test boolean NOT NULL,
      reason text NOT NULL
        CONSTRAINT report_skip_rollups_reason_check CHECK (char_length(reason) <= 128),
      rule_id text NOT NULL
        CONSTRAINT report_skip_rollups_rule_id_check CHECK (char_length(rule_id) <= 128),
      skipped bigint NOT NULL CONSTRAINT report_skip_rollups_skipped_check CHECK (skipped >= 0),
      recomputed_at timestamptz NOT NULL,
      CONSTRAINT report_skip_rollups_pkey
        PRIMARY KEY (tenant_id, environment, report_day, channel, is_test, reason, rule_id)
    )
    """)

    for table <- ~w(report_delivery_rollups report_skip_rollups) do
      execute("""
      CREATE TRIGGER #{table}_no_delete BEFORE DELETE ON relay.#{table}
        FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
      """)

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

  def down, do: :ok
end
