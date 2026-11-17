defmodule Relay.Repo.Migrations.CreateRefusalTables do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  @tables ~w(refusals unsubscribe_token_revocations)

  # PC-35
  # PC-38
  # PC-39
  # INV-18
  # INV-6
  # TN-12
  # TN-13
  def up do
    Enum.each(statements(), &execute/1)
    Enum.each(@tables, &scoped/1)
  end

  def down, do: :ok

  defp scoped(table) do
    execute("""
    CREATE TRIGGER #{table}_no_mutation BEFORE UPDATE OR DELETE ON relay.#{table}
      FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    execute("""
    CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON relay.#{table}
      FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    execute("ALTER TABLE relay.#{table} ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE relay.#{table} FORCE ROW LEVEL SECURITY")

    execute(
      "CREATE POLICY #{table}_scope ON relay.#{table} USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})"
    )

    execute("GRANT SELECT, INSERT ON relay.#{table} TO relay_owner")

    execute(
      "GRANT SELECT ON relay.#{table} TO relay_app, relay_maint, relay_archive, relay_report"
    )
  end

  defp statements do
    [
      ~S"""
      CREATE TABLE relay.refusals (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        recipient_id uuid NOT NULL,
        brand_subtenant_id uuid,
        channel relay.channel NOT NULL,
        source text NOT NULL
          CONSTRAINT refusals_source_check
            CHECK (source IN ('rfc8058', 'unsubscribe_link', 'mailto', 'unsubscribe_page',
              'sms_keyword', 'complaint', 'whatsapp', 'iys')),
        scope text NOT NULL
          CONSTRAINT refusals_scope_check
            CHECK (scope IN ('category', 'all_marketing', 'all_channel')),
        category_key text
          CONSTRAINT refusals_category_key_check CHECK (char_length(category_key) BETWEEN 1 AND 128),
        request_ref text NOT NULL
          CONSTRAINT refusals_request_ref_check CHECK (char_length(request_ref) BETWEEN 1 AND 256),
        occurred_at timestamptz NOT NULL,
        evidence_ct bytea
          CONSTRAINT refusals_evidence_ct_check CHECK (octet_length(evidence_ct) <= 8192),
        evidence_key_id uuid,
        created_at timestamptz NOT NULL,
        CONSTRAINT refusals_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT refusals_category_check CHECK ((scope = 'category') = (category_key IS NOT NULL)),
        CONSTRAINT refusals_source_scope_check
          CHECK (source NOT IN ('rfc8058', 'unsubscribe_link', 'mailto') OR scope = 'category'),
        CONSTRAINT refusals_evidence_check CHECK ((evidence_ct IS NULL) = (evidence_key_id IS NULL)),
        CONSTRAINT refusals_recipient_id_fkey FOREIGN KEY (tenant_id, environment, recipient_id)
          REFERENCES relay.recipients (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT refusals_brand_subtenant_id_fkey
          FOREIGN KEY (tenant_id, environment, brand_subtenant_id)
          REFERENCES relay.subtenants (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT refusals_evidence_key_id_fkey FOREIGN KEY (tenant_id, environment, evidence_key_id)
          REFERENCES relay.subject_keys (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE UNIQUE INDEX refusals_request_ref_key ON relay.refusals
        (tenant_id, environment, request_ref)
      """,
      """
      CREATE INDEX refusals_recipient_index ON relay.refusals
        (tenant_id, environment, recipient_id, created_at)
      """,
      ~S"""
      CREATE TABLE relay.unsubscribe_token_revocations (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        reason text NOT NULL
          CONSTRAINT unsubscribe_token_revocations_reason_check
            CHECK (char_length(reason) BETWEEN 1 AND 2000),
        revoked_by_ref text NOT NULL
          CONSTRAINT unsubscribe_token_revocations_revoked_by_ref_check
            CHECK (char_length(revoked_by_ref) BETWEEN 1 AND 256),
        created_at timestamptz NOT NULL,
        CONSTRAINT unsubscribe_token_revocations_pkey PRIMARY KEY (tenant_id, environment, id)
      )
      """
    ]
  end
end
