defmodule Relay.Repo.Migrations.CreateWaitpointCompletions do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  # WH-68
  # AG-11
  # TN-27
  # OP-9
  def up do
    Enum.each(statements(), &execute/1)
  end

  def down, do: :ok

  defp statements do
    [
      ~S"""
      CREATE TABLE relay.waitpoint_completions (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        waitpoint_id uuid NOT NULL,
        receipt_id uuid NOT NULL,
        outcome text NOT NULL
          CONSTRAINT waitpoint_completions_outcome_check
            CHECK (outcome IN ('completed', 'failed')),
        result_ct bytea
          CONSTRAINT waitpoint_completions_result_ct_check
            CHECK (octet_length(result_ct) <= 8192),
        result_key_id uuid,
        created_at timestamptz NOT NULL,
        CONSTRAINT waitpoint_completions_pkey PRIMARY KEY (tenant_id, environment, waitpoint_id),
        CONSTRAINT waitpoint_completions_result_check
          CHECK ((result_ct IS NULL) = (result_key_id IS NULL)),
        CONSTRAINT waitpoint_completions_waitpoint_id_fkey
          FOREIGN KEY (tenant_id, environment, waitpoint_id)
          REFERENCES relay.waitpoints (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT waitpoint_completions_receipt_id_fkey
          FOREIGN KEY (tenant_id, environment, receipt_id)
          REFERENCES relay.webhook_receipts (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT waitpoint_completions_result_key_id_fkey
          FOREIGN KEY (tenant_id, environment, result_key_id)
          REFERENCES relay.tenant_keys (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE TRIGGER waitpoint_completions_no_delete BEFORE DELETE ON relay.waitpoint_completions
        FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
      """,
      """
      CREATE TRIGGER waitpoint_completions_no_truncate BEFORE TRUNCATE ON relay.waitpoint_completions
        FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
      """,
      "ALTER TABLE relay.waitpoint_completions ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE relay.waitpoint_completions FORCE ROW LEVEL SECURITY",
      "CREATE POLICY waitpoint_completions_scope ON relay.waitpoint_completions USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})",
      "GRANT SELECT, INSERT, UPDATE ON relay.waitpoint_completions TO relay_owner",
      "GRANT SELECT ON relay.waitpoint_completions TO relay_app, relay_maint, relay_archive, relay_report"
    ]
  end
end
