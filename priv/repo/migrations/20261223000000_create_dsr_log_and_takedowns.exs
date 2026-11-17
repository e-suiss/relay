defmodule Relay.Repo.Migrations.CreateDsrLogAndTakedowns do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  # OP-19
  # OP-24
  # DS-44
  # TN-60
  # OP-9
  # OP-57
  def up do
    Enum.each(statements(), &execute/1)
  end

  def down, do: :ok

  defp statements do
    List.flatten([dsr_log(), takedowns(), record_classes(), reasons()])
  end

  defp dsr_log do
    [
      ~S"""
      CREATE TABLE relay.dsr_log (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        recipient_id uuid NOT NULL,
        request_id uuid NOT NULL,
        request_kind text NOT NULL
          CONSTRAINT dsr_log_request_kind_check CHECK (request_kind IN ('erasure')),
        entry text NOT NULL
          CONSTRAINT dsr_log_entry_check CHECK (entry IN ('request', 'answer')),
        outcome text
          CONSTRAINT dsr_log_outcome_check CHECK (outcome IN ('completed', 'held')),
        retention_class text NOT NULL
          CONSTRAINT dsr_log_retention_class_check CHECK (retention_class = 'dsr_log'),
        created_at timestamptz NOT NULL,
        CONSTRAINT dsr_log_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT dsr_log_entry_key UNIQUE (tenant_id, environment, request_id, entry),
        CONSTRAINT dsr_log_answer_check CHECK ((entry = 'answer') = (outcome IS NOT NULL)),
        CONSTRAINT dsr_log_recipient_id_fkey FOREIGN KEY (tenant_id, environment, recipient_id)
          REFERENCES relay.recipients (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT dsr_log_request_id_fkey FOREIGN KEY (tenant_id, environment, request_id)
          REFERENCES relay.recipient_deletion_requests (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE INDEX dsr_log_recipient_id_index ON relay.dsr_log
        (tenant_id, environment, recipient_id, created_at)
      """,
      """
      CREATE TRIGGER dsr_log_append_only BEFORE UPDATE OR DELETE ON relay.dsr_log
        FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
      """,
      """
      CREATE TRIGGER dsr_log_no_truncate BEFORE TRUNCATE ON relay.dsr_log
        FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
      """,
      "ALTER TABLE relay.dsr_log ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE relay.dsr_log FORCE ROW LEVEL SECURITY",
      "CREATE POLICY dsr_log_scope ON relay.dsr_log USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})",
      "GRANT SELECT, INSERT ON relay.dsr_log TO relay_owner",
      "GRANT SELECT ON relay.dsr_log TO relay_app, relay_maint, relay_archive, relay_report"
    ]
  end

  defp takedowns do
    [
      ~S"""
      CREATE TABLE relay.takedowns (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        target_kind text NOT NULL
          CONSTRAINT takedowns_target_kind_check
            CHECK (target_kind IN ('message', 'template', 'sender_identity')),
        notification_id uuid,
        template_id uuid,
        sender_identity_id uuid,
        reason text NOT NULL
          CONSTRAINT takedowns_reason_check CHECK (char_length(reason) BETWEEN 1 AND 500),
        state text NOT NULL
          CONSTRAINT takedowns_state_check CHECK (state IN ('active', 'lifted')),
        restores boolean NOT NULL,
        hidden_items bigint NOT NULL
          CONSTRAINT takedowns_hidden_items_check CHECK (hidden_items >= 0),
        cancelled_deliveries bigint NOT NULL
          CONSTRAINT takedowns_cancelled_deliveries_check CHECK (cancelled_deliveries >= 0),
        lift_reason text
          CONSTRAINT takedowns_lift_reason_check CHECK (char_length(lift_reason) BETWEEN 1 AND 500),
        lifted_at timestamptz,
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT takedowns_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT takedowns_target_check
          CHECK ((target_kind = 'message') = (notification_id IS NOT NULL)
            AND (target_kind = 'template') = (template_id IS NOT NULL)
            AND (target_kind = 'sender_identity') = (sender_identity_id IS NOT NULL)),
        CONSTRAINT takedowns_lifted_check
          CHECK ((state = 'lifted') = (lifted_at IS NOT NULL)
            AND (state = 'lifted') = (lift_reason IS NOT NULL)),
        CONSTRAINT takedowns_notification_id_fkey
          FOREIGN KEY (tenant_id, environment, notification_id)
          REFERENCES relay.notifications (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT takedowns_template_id_fkey FOREIGN KEY (tenant_id, environment, template_id)
          REFERENCES relay.templates (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT takedowns_sender_identity_id_fkey
          FOREIGN KEY (tenant_id, environment, sender_identity_id)
          REFERENCES relay.sender_identities (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE UNIQUE INDEX takedowns_active_notification_key ON relay.takedowns
        (tenant_id, environment, notification_id) WHERE state = 'active'
      """,
      """
      CREATE UNIQUE INDEX takedowns_active_template_key ON relay.takedowns
        (tenant_id, environment, template_id) WHERE state = 'active'
      """,
      """
      CREATE UNIQUE INDEX takedowns_active_sender_identity_key ON relay.takedowns
        (tenant_id, environment, sender_identity_id) WHERE state = 'active'
      """,
      """
      CREATE TRIGGER takedowns_no_delete BEFORE DELETE ON relay.takedowns
        FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
      """,
      """
      CREATE TRIGGER takedowns_no_truncate BEFORE TRUNCATE ON relay.takedowns
        FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
      """,
      "ALTER TABLE relay.takedowns ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE relay.takedowns FORCE ROW LEVEL SECURITY",
      "CREATE POLICY takedowns_scope ON relay.takedowns USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})",
      "GRANT SELECT, INSERT, UPDATE ON relay.takedowns TO relay_owner",
      "GRANT SELECT ON relay.takedowns TO relay_app, relay_maint, relay_archive, relay_report"
    ]
  end

  defp record_classes do
    [
      "ALTER TABLE relay.notifications ADD COLUMN retention_class text",
      """
      ALTER TABLE relay.notifications ADD CONSTRAINT notifications_retention_class_check
        CHECK (retention_class IN ('delivery_record', 'commercial_message')) NOT VALID
      """,
      "ALTER TABLE relay.deliveries ADD COLUMN retention_class text",
      """
      ALTER TABLE relay.deliveries ADD CONSTRAINT deliveries_retention_class_check
        CHECK (retention_class IN ('delivery_record', 'commercial_message')) NOT VALID
      """
    ]
  end

  defp reasons do
    [
      "ALTER TABLE relay.inbox_items DROP CONSTRAINT inbox_items_hidden_reason_check",
      """
      ALTER TABLE relay.inbox_items ADD CONSTRAINT inbox_items_hidden_reason_check
        CHECK (hidden_reason IN ('user', 'retracted', 'retention', 'takedown')) NOT VALID
      """,
      "ALTER TABLE relay.digest_windows DROP CONSTRAINT digest_windows_close_reason_check",
      """
      ALTER TABLE relay.digest_windows ADD CONSTRAINT digest_windows_close_reason_check
        CHECK (close_reason IN ('due', 'max_items', 'read', 'deadline', 'subject_erasure'))
        NOT VALID
      """
    ]
  end
end
