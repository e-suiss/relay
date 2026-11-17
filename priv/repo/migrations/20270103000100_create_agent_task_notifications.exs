defmodule Relay.Repo.Migrations.CreateAgentTaskNotifications do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  # AG-37
  # AG-42
  # INV-35
  # OP-9
  def up do
    Enum.each(statements(), &execute/1)
  end

  def down, do: :ok

  defp statements do
    [
      ~S"""
      CREATE TABLE relay.agent_task_notifications (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        source_id uuid NOT NULL,
        task text NOT NULL
          CONSTRAINT agent_task_notifications_task_check
            CHECK (task ~ '^[\x21-\x7e]+$' AND char_length(task) <= 256),
        protocol text NOT NULL
          CONSTRAINT agent_task_notifications_protocol_check CHECK (protocol IN ('a2a')),
        seq bigint NOT NULL
          CONSTRAINT agent_task_notifications_seq_check CHECK (seq >= 0),
        state text
          CONSTRAINT agent_task_notifications_state_check
            CHECK (state ~ '^[A-Za-z][A-Za-z_]*$' AND char_length(state) <= 64),
        receipt_id uuid,
        reconciled_at timestamptz,
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT agent_task_notifications_pkey
          PRIMARY KEY (tenant_id, environment, source_id, task),
        CONSTRAINT agent_task_notifications_source_id_fkey
          FOREIGN KEY (tenant_id, environment, source_id)
          REFERENCES relay.webhook_sources (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT agent_task_notifications_receipt_id_fkey
          FOREIGN KEY (tenant_id, environment, receipt_id)
          REFERENCES relay.webhook_receipts (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE TRIGGER agent_task_notifications_no_delete
        BEFORE DELETE ON relay.agent_task_notifications
        FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
      """,
      """
      CREATE TRIGGER agent_task_notifications_no_truncate
        BEFORE TRUNCATE ON relay.agent_task_notifications
        FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
      """,
      "ALTER TABLE relay.agent_task_notifications ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE relay.agent_task_notifications FORCE ROW LEVEL SECURITY",
      "CREATE POLICY agent_task_notifications_scope ON relay.agent_task_notifications USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})",
      "GRANT SELECT, INSERT, UPDATE ON relay.agent_task_notifications TO relay_owner",
      "GRANT SELECT ON relay.agent_task_notifications TO relay_app, relay_maint, relay_archive, relay_report"
    ]
  end
end
