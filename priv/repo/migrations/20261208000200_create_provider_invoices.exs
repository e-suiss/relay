defmodule Relay.Repo.Migrations.CreateProviderInvoices do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  # OP-38
  # OP-42
  # CH-18
  # TN-12
  # TN-13
  def up do
    execute(~S"""
    CREATE TABLE relay.provider_invoices (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      id uuid NOT NULL,
      provider text NOT NULL
        CONSTRAINT provider_invoices_provider_check CHECK (provider ~ '^[a-z][a-z0-9_]{1,31}$'),
      channel relay.channel,
      invoice_ref text NOT NULL
        CONSTRAINT provider_invoices_invoice_ref_check
          CHECK (char_length(invoice_ref) BETWEEN 1 AND 128),
      period_start date NOT NULL,
      period_end date NOT NULL,
      currency text NOT NULL
        CONSTRAINT provider_invoices_currency_check CHECK (currency ~ '^[A-Z]{3}$'),
      amount_micros bigint NOT NULL
        CONSTRAINT provider_invoices_amount_micros_check CHECK (amount_micros >= 0),
      units bigint CONSTRAINT provider_invoices_units_check CHECK (units >= 0),
      raw jsonb CONSTRAINT provider_invoices_raw_check CHECK (pg_column_size(raw) <= 65536),
      checked_at timestamptz,
      usage_cost_micros bigint,
      usage_units bigint,
      unpriced_units bigint,
      drift_micros bigint,
      drift_bp bigint,
      check_result text
        CONSTRAINT provider_invoices_check_result_check CHECK (check_result IN ('matched', 'drift')),
      created_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      CONSTRAINT provider_invoices_pkey PRIMARY KEY (tenant_id, environment, id),
      CONSTRAINT provider_invoices_invoice_ref_key
        UNIQUE (tenant_id, environment, provider, invoice_ref),
      CONSTRAINT provider_invoices_period_check
        CHECK (period_end > period_start AND period_end - period_start <= 92),
      CONSTRAINT provider_invoices_checked_check
        CHECK ((checked_at IS NULL) = (check_result IS NULL))
    )
    """)

    execute("""
    CREATE INDEX provider_invoices_period_index ON relay.provider_invoices
      (tenant_id, environment, period_start, period_end)
    """)

    execute("""
    CREATE INDEX provider_invoices_created_at_index ON relay.provider_invoices
      (tenant_id, environment, created_at, id)
    """)

    execute("""
    CREATE TRIGGER provider_invoices_no_delete BEFORE DELETE ON relay.provider_invoices
      FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    execute("ALTER TABLE relay.provider_invoices ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE relay.provider_invoices FORCE ROW LEVEL SECURITY")

    execute(
      "CREATE POLICY provider_invoices_scope ON relay.provider_invoices USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})"
    )

    execute("GRANT SELECT, INSERT, UPDATE ON relay.provider_invoices TO relay_owner")

    execute(
      "GRANT SELECT ON relay.provider_invoices TO relay_app, relay_maint, relay_archive, relay_report"
    )
  end

  def down, do: :ok
end
