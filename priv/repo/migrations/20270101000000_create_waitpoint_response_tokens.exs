defmodule Relay.Repo.Migrations.CreateWaitpointResponseTokens do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  @table "waitpoint_response_tokens"

  # AG-31
  # AG-35
  # INV-33
  # L-36
  # TN-12
  # TN-13
  # OP-9
  def up do
    Enum.each(statements(), &execute/1)

    execute("""
    CREATE TRIGGER #{@table}_no_delete BEFORE DELETE ON relay.#{@table}
      FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    execute("""
    CREATE TRIGGER #{@table}_no_truncate BEFORE TRUNCATE ON relay.#{@table}
      FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    execute("ALTER TABLE relay.#{@table} ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE relay.#{@table} FORCE ROW LEVEL SECURITY")

    execute(
      "CREATE POLICY #{@table}_scope ON relay.#{@table} USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})"
    )

    execute(
      "GRANT SELECT ON relay.#{@table} TO relay_app, relay_maint, relay_archive, relay_report"
    )

    execute("GRANT SELECT, INSERT, UPDATE ON relay.#{@table} TO relay_owner")
  end

  def down, do: :ok

  defp statements do
    [
      ~S"""
      CREATE TABLE relay.waitpoint_response_tokens (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        waitpoint_id uuid NOT NULL,
        recipient_id uuid NOT NULL,
        state text NOT NULL
          CONSTRAINT waitpoint_response_tokens_state_check
            CHECK (state IN ('issued', 'processing', 'settled', 'rotated')),
        expires_at timestamptz NOT NULL,
        via text
          CONSTRAINT waitpoint_response_tokens_via_check CHECK (via ~ '^[a-z_]{1,32}$'),
        value_ct bytea
          CONSTRAINT waitpoint_response_tokens_value_ct_check
            CHECK (octet_length(value_ct) <= 65536 + 29),
        value_key_id uuid,
        value_digest relay.sha256,
        consumed_at timestamptz,
        outcome text
          CONSTRAINT waitpoint_response_tokens_outcome_check CHECK (outcome ~ '^[a-z_]{1,48}$'),
        settled_at timestamptz,
        rotated_at timestamptz,
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT waitpoint_response_tokens_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT waitpoint_response_tokens_consumed_check
          CHECK ((state IN ('processing', 'settled')) = (consumed_at IS NOT NULL AND via IS NOT NULL
            AND value_key_id IS NOT NULL AND value_digest IS NOT NULL)),
        CONSTRAINT waitpoint_response_tokens_value_check
          CHECK ((state = 'processing') = (value_ct IS NOT NULL)),
        CONSTRAINT waitpoint_response_tokens_settled_check
          CHECK ((state = 'settled') = (settled_at IS NOT NULL AND outcome IS NOT NULL)),
        CONSTRAINT waitpoint_response_tokens_rotated_check
          CHECK ((state = 'rotated') = (rotated_at IS NOT NULL)),
        CONSTRAINT waitpoint_response_tokens_recipient_id_fkey
          FOREIGN KEY (tenant_id, environment, waitpoint_id, recipient_id)
          REFERENCES relay.waitpoint_responders (tenant_id, environment, waitpoint_id, recipient_id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT waitpoint_response_tokens_value_key_id_fkey
          FOREIGN KEY (tenant_id, environment, value_key_id)
          REFERENCES relay.subject_keys (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE INDEX waitpoint_response_tokens_issued_index ON relay.waitpoint_response_tokens
        (tenant_id, environment, waitpoint_id, recipient_id) WHERE state = 'issued'
      """
    ]
  end
end
