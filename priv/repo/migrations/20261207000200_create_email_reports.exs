defmodule Relay.Repo.Migrations.CreateEmailReports do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"
  @signature "relay_fn.email_report_record(uuid, text, text, text, text, timestamptz, timestamptz, bytea, jsonb, jsonb)"

  # CH-46
  # TN-12
  # TN-13
  # OP-9
  def up do
    execute(~S"""
    CREATE TABLE relay.email_reports (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      id uuid NOT NULL,
      kind text NOT NULL
        CONSTRAINT email_reports_kind_check CHECK (kind IN ('dmarc_aggregate', 'tls_rpt')),
      reporter text NOT NULL
        CONSTRAINT email_reports_reporter_check CHECK (char_length(reporter) BETWEEN 1 AND 256),
      report_ref text NOT NULL
        CONSTRAINT email_reports_report_ref_check CHECK (char_length(report_ref) BETWEEN 1 AND 256),
      domain text NOT NULL
        CONSTRAINT email_reports_domain_check
          CHECK (char_length(domain) BETWEEN 1 AND 253 AND domain = lower(domain)),
      begin_at timestamptz NOT NULL,
      end_at timestamptz NOT NULL,
      content_digest relay.sha256 NOT NULL,
      summary jsonb NOT NULL
        CONSTRAINT email_reports_summary_check
          CHECK (jsonb_typeof(summary) = 'object' AND pg_column_size(summary) <= 16384),
      records jsonb NOT NULL
        CONSTRAINT email_reports_records_check
          CHECK (jsonb_typeof(records) = 'array' AND pg_column_size(records) <= 4194304),
      record_count bigint NOT NULL
        CONSTRAINT email_reports_record_count_check CHECK (record_count BETWEEN 0 AND 10000),
      created_at timestamptz NOT NULL,
      CONSTRAINT email_reports_pkey PRIMARY KEY (tenant_id, environment, id),
      CONSTRAINT email_reports_report_key UNIQUE (tenant_id, environment, kind, reporter, report_ref),
      CONSTRAINT email_reports_range_check CHECK (end_at >= begin_at)
    )
    """)

    execute("""
    CREATE INDEX email_reports_domain_index ON relay.email_reports
      (tenant_id, environment, domain, end_at)
    """)

    execute("""
    CREATE TRIGGER email_reports_no_mutation BEFORE UPDATE OR DELETE ON relay.email_reports
      FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    execute("ALTER TABLE relay.email_reports ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE relay.email_reports FORCE ROW LEVEL SECURITY")

    execute(
      "CREATE POLICY email_reports_scope ON relay.email_reports USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})"
    )

    execute("GRANT SELECT, INSERT ON relay.email_reports TO relay_owner")

    execute(
      "GRANT SELECT ON relay.email_reports TO relay_app, relay_maint, relay_archive, relay_report"
    )

    execute(~S"""
    CREATE FUNCTION relay_fn.email_report_record(p_id uuid, p_kind text, p_reporter text,
      p_report_ref text, p_domain text, p_begin_at timestamptz, p_end_at timestamptz,
      p_content_digest bytea, p_summary jsonb, p_records jsonb)
      RETURNS TABLE (result text, email_report_id uuid)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_existing uuid;
    BEGIN
      PERFORM relay_private.assert_new_id(p_id);
      IF p_kind IS NULL OR p_reporter IS NULL OR p_report_ref IS NULL OR p_domain IS NULL
        OR p_begin_at IS NULL OR p_end_at IS NULL OR p_content_digest IS NULL
        OR p_summary IS NULL OR p_records IS NULL OR jsonb_typeof(p_records) <> 'array' THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'CH-46';
      END IF;
      PERFORM relay_private.lock_scope(ARRAY['email_report', p_kind, p_reporter, p_report_ref]);
      SELECT r.id INTO v_existing FROM relay.email_reports r
        WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.kind = p_kind
          AND r.reporter = p_reporter AND r.report_ref = p_report_ref;
      IF FOUND THEN
        RETURN QUERY SELECT 'duplicate'::text, v_existing;
        RETURN;
      END IF;
      INSERT INTO relay.email_reports (tenant_id, environment, id, kind, reporter, report_ref,
        domain, begin_at, end_at, content_digest, summary, records, record_count, created_at)
      VALUES (v_tenant, v_env, p_id, p_kind, p_reporter, p_report_ref, p_domain, p_begin_at,
        p_end_at, p_content_digest, p_summary, p_records, jsonb_array_length(p_records), now());
      RETURN QUERY SELECT 'recorded'::text, p_id;
    END
    $fn$
    """)

    execute("REVOKE ALL ON FUNCTION #{@signature} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@signature} TO relay_app")
    execute("ALTER FUNCTION #{@signature} OWNER TO relay_owner")
  end

  def down, do: :ok
end
