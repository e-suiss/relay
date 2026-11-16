defmodule Relay.Repo.Migrations.CreateUsageBillingFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"

  @functions [
    {"relay_fn.usage_record_append(uuid, date, text, text, text, text, text, text, boolean, bigint, bigint, bigint, bigint, text, text, bigint, bigint)",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.provider_invoice_record(uuid, text, text, text, date, date, text, bigint, bigint, jsonb, bytea, #{@actor})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.provider_invoice_check(uuid, bigint)", "relay_owner", ~w(relay_app)}
  ]

  # DS-53
  # C-88
  # OP-38
  # OP-42
  # CH-18
  # OP-8
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
      CREATE FUNCTION relay_fn.usage_record_append(p_id uuid, p_usage_day date, p_channel text,
        p_provider text, p_destination_country text, p_destination_operator text,
        p_whatsapp_category text, p_outcome text, p_is_test boolean, p_quantity bigint,
        p_attempt_count bigint, p_sms_segments bigint, p_cost_micros bigint, p_currency text,
        p_billable_unit text, p_billable_units bigint, p_voice_seconds bigint)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.usage_records;
        v_inserted uuid;
      BEGIN
        PERFORM relay_private.assert_new_id(p_id);
        IF p_usage_day IS NULL OR p_channel IS NULL OR p_provider IS NULL OR p_outcome IS NULL
          OR p_is_test IS NULL OR p_quantity IS NULL OR p_quantity < 0
          OR p_attempt_count IS NULL OR p_attempt_count < 0
          OR (p_cost_micros IS NULL) <> (p_currency IS NULL)
          OR p_billable_unit IS NULL
          OR p_billable_unit NOT IN ('segment', 'answered_call', 'message', 'recipient', 'attempt')
          OR p_billable_units IS NULL OR p_billable_units < 0
          OR (p_voice_seconds IS NOT NULL AND (p_channel <> 'voice' OR p_voice_seconds < 0)) THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'DS-53';
        END IF;
        IF p_usage_day >= current_date THEN
          RETURN 'day_open';
        END IF;
        INSERT INTO relay.usage_records AS u (tenant_id, environment, id, usage_day, channel, provider,
          destination_country, destination_operator, whatsapp_category, outcome, is_test, quantity,
          attempt_count, sms_segments, cost_micros, currency, billable_unit, billable_units,
          voice_seconds, created_at)
        VALUES (v_tenant, v_env, p_id, p_usage_day, p_channel, p_provider, p_destination_country,
          p_destination_operator, p_whatsapp_category, p_outcome, p_is_test, p_quantity,
          p_attempt_count, p_sms_segments, p_cost_micros, p_currency, p_billable_unit,
          p_billable_units, p_voice_seconds, now())
        ON CONFLICT DO NOTHING
        RETURNING u.id INTO v_inserted;
        IF v_inserted IS NOT NULL THEN
          RETURN 'recorded';
        END IF;
        SELECT * INTO v_row FROM relay.usage_records u
          WHERE u.tenant_id = v_tenant AND u.environment = v_env AND u.usage_day = p_usage_day
            AND u.channel = p_channel AND u.provider = p_provider
            AND u.destination_country IS NOT DISTINCT FROM p_destination_country
            AND u.destination_operator IS NOT DISTINCT FROM p_destination_operator
            AND u.whatsapp_category IS NOT DISTINCT FROM p_whatsapp_category
            AND u.outcome = p_outcome AND u.is_test = p_is_test;
        IF FOUND AND v_row.quantity = p_quantity AND v_row.attempt_count = p_attempt_count
          AND v_row.sms_segments IS NOT DISTINCT FROM p_sms_segments
          AND v_row.cost_micros IS NOT DISTINCT FROM p_cost_micros
          AND v_row.currency IS NOT DISTINCT FROM p_currency
          AND (v_row.billable_unit IS NULL
            OR (v_row.billable_unit = p_billable_unit AND v_row.billable_units = p_billable_units
              AND v_row.voice_seconds IS NOT DISTINCT FROM p_voice_seconds)) THEN
          RETURN 'duplicate';
        END IF;
        RETURN 'conflict';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.provider_invoice_record(p_id uuid, p_provider text, p_channel text,
        p_invoice_ref text, p_period_start date, p_period_end date, p_currency text,
        p_amount_micros bigint, p_units bigint, p_raw jsonb, p_record_digest bytea,
        p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, invoice_id uuid)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.provider_invoices;
      BEGIN
        IF p_provider IS NULL OR p_invoice_ref IS NULL OR p_period_start IS NULL
          OR p_period_end IS NULL OR p_currency IS NULL OR p_amount_micros IS NULL
          OR p_actor_ref IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-38';
        END IF;
        SELECT * INTO v_row FROM relay.provider_invoices i
          WHERE i.tenant_id = v_tenant AND i.environment = v_env AND i.provider = p_provider
            AND i.invoice_ref = p_invoice_ref;
        IF FOUND THEN
          IF (v_row.channel::text, v_row.period_start, v_row.period_end, v_row.currency,
              v_row.amount_micros, v_row.units, v_row.raw)
            IS NOT DISTINCT FROM (p_channel, p_period_start, p_period_end, p_currency,
              p_amount_micros, p_units, p_raw) THEN
            RETURN QUERY SELECT 'exists'::text, v_row.id;
          ELSE
            RETURN QUERY SELECT 'conflict'::text, v_row.id;
          END IF;
          RETURN;
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        INSERT INTO relay.provider_invoices (tenant_id, environment, id, provider, channel,
          invoice_ref, period_start, period_end, currency, amount_micros, units, raw, created_at,
          updated_at)
        VALUES (v_tenant, v_env, p_id, p_provider, p_channel::relay.channel, p_invoice_ref,
          p_period_start, p_period_end, p_currency, p_amount_micros, p_units, p_raw, now(), now());
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'provider_invoice.recorded',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref,
          'provider_invoice', p_id::text, 'recorded', p_record_digest);
        RETURN QUERY SELECT 'recorded'::text, p_id;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.provider_invoice_check(p_invoice_id uuid, p_tolerance_bp bigint)
        RETURNS TABLE (result text, check_result text)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.provider_invoices;
        v_cost bigint;
        v_units bigint;
        v_unpriced bigint;
        v_drift bigint;
        v_drift_bp bigint;
        v_check text;
      BEGIN
        IF p_invoice_id IS NULL OR p_tolerance_bp IS NULL OR p_tolerance_bp < 0 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-42';
        END IF;
        SELECT * INTO v_row FROM relay.provider_invoices i
          WHERE i.tenant_id = v_tenant AND i.environment = v_env AND i.id = p_invoice_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::text;
          RETURN;
        END IF;
        SELECT coalesce(sum(u.cost_micros) FILTER (WHERE u.currency = v_row.currency), 0)::bigint,
          coalesce(sum(u.billable_units), 0)::bigint,
          coalesce(sum(u.billable_units) FILTER (WHERE u.billable_units > 0
            AND u.currency IS DISTINCT FROM v_row.currency), 0)::bigint
          INTO v_cost, v_units, v_unpriced
        FROM relay.usage_records u
        WHERE u.tenant_id = v_tenant AND u.environment = v_env AND u.provider = v_row.provider
          AND (v_row.channel IS NULL OR u.channel = v_row.channel)
          AND u.usage_day >= v_row.period_start AND u.usage_day < v_row.period_end;
        v_drift := v_row.amount_micros - v_cost;
        v_drift_bp := CASE WHEN v_cost > 0 THEN round(v_drift * 10000.0 / v_cost)::bigint END;
        v_check := CASE
          WHEN abs(v_drift)::numeric * 10000
            <= p_tolerance_bp::numeric * greatest(v_row.amount_micros, v_cost) THEN 'matched'
          ELSE 'drift' END;
        IF v_row.checked_at IS NOT NULL
          AND (v_row.usage_cost_micros, v_row.usage_units, v_row.unpriced_units,
            v_row.drift_micros, v_row.drift_bp, v_row.check_result)
          IS NOT DISTINCT FROM (v_cost, v_units, v_unpriced, v_drift, v_drift_bp, v_check) THEN
          RETURN QUERY SELECT 'unchanged'::text, v_check;
          RETURN;
        END IF;
        UPDATE relay.provider_invoices i SET checked_at = now(), usage_cost_micros = v_cost,
            usage_units = v_units, unpriced_units = v_unpriced, drift_micros = v_drift,
            drift_bp = v_drift_bp, check_result = v_check, updated_at = now()
          WHERE i.tenant_id = v_tenant AND i.environment = v_env AND i.id = p_invoice_id;
        RETURN QUERY SELECT 'changed'::text, v_check;
      END
      $fn$
      """
    ]
  end
end
