defmodule Relay.Repo.Migrations.CreateMessagingTables do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  # CH-62
  # CH-23
  # C-22
  # TN-12
  # TN-13
  # OP-9
  def up do
    execute(~S"""
    CREATE TABLE relay.messaging_targets (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      id uuid NOT NULL,
      recipient_id uuid NOT NULL,
      channel relay.channel NOT NULL
        CONSTRAINT messaging_targets_channel_check
          CHECK (channel IN ('slack', 'teams', 'telegram', 'discord')),
      provider_account_id uuid NOT NULL,
      target_ct bytea NOT NULL,
      target_key_id uuid NOT NULL,
      state text NOT NULL
        CONSTRAINT messaging_targets_state_check CHECK (state IN ('active', 'disabled')),
      disabled_rule_id relay.rule_id,
      deleted_at timestamptz,
      created_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      CONSTRAINT messaging_targets_pkey PRIMARY KEY (tenant_id, environment, id),
      CONSTRAINT messaging_targets_disabled_check
        CHECK ((state = 'disabled') = (disabled_rule_id IS NOT NULL)
          AND (state = 'disabled') = (deleted_at IS NOT NULL)),
      CONSTRAINT messaging_targets_recipient_id_fkey
        FOREIGN KEY (tenant_id, environment, recipient_id)
        REFERENCES relay.recipients (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
      CONSTRAINT messaging_targets_provider_account_id_fkey
        FOREIGN KEY (tenant_id, environment, provider_account_id)
        REFERENCES relay.provider_accounts (tenant_id, environment, id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
      CONSTRAINT messaging_targets_target_key_id_fkey
        FOREIGN KEY (tenant_id, environment, target_key_id)
        REFERENCES relay.subject_keys (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
    )
    """)

    execute("""
    CREATE UNIQUE INDEX messaging_targets_active_key ON relay.messaging_targets
      (tenant_id, environment, recipient_id, channel) WHERE state = 'active'
    """)

    execute("""
    CREATE INDEX messaging_targets_provider_account_index ON relay.messaging_targets
      (tenant_id, environment, provider_account_id)
    """)

    execute(~S"""
    CREATE TABLE relay.messaging_messages (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      id uuid NOT NULL,
      target_id uuid NOT NULL,
      provider_account_id uuid NOT NULL,
      topic_key relay.sha256 NOT NULL,
      provider_message_ref text NOT NULL
        CONSTRAINT messaging_messages_provider_message_ref_check
          CHECK (char_length(provider_message_ref) BETWEEN 1 AND 256),
      delivery_id uuid NOT NULL,
      created_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      CONSTRAINT messaging_messages_pkey PRIMARY KEY (tenant_id, environment, id),
      CONSTRAINT messaging_messages_topic_key UNIQUE (tenant_id, environment, target_id, topic_key),
      CONSTRAINT messaging_messages_target_id_fkey FOREIGN KEY (tenant_id, environment, target_id)
        REFERENCES relay.messaging_targets (tenant_id, environment, id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
      CONSTRAINT messaging_messages_provider_account_id_fkey
        FOREIGN KEY (tenant_id, environment, provider_account_id)
        REFERENCES relay.provider_accounts (tenant_id, environment, id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
      CONSTRAINT messaging_messages_delivery_id_fkey FOREIGN KEY (tenant_id, environment, delivery_id)
        REFERENCES relay.deliveries (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
    )
    """)

    execute("""
    CREATE INDEX messaging_messages_ref_index ON relay.messaging_messages
      (tenant_id, environment, provider_account_id, provider_message_ref)
    """)

    for table <- ~w(messaging_targets messaging_messages) do
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
end
