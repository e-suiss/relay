defmodule Relay.Repo.Migrations.CreateFirstContactTables do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  @mutable ~w(agent_relationships agent_blocks)
  @append_only ~w(agent_messages first_contact_tokens mailbox_abuse_reports)

  # AG-56
  # AG-57
  # AG-59
  # AG-60
  # AG-61
  # AG-67
  # AG-73
  # TN-12
  # TN-13
  # OP-9
  # OP-57
  def up do
    Enum.each(statements(), &execute/1)
    Enum.each(@mutable, &mutable/1)
    Enum.each(@append_only, &append_only/1)
    Enum.each(record_kinds(), &execute/1)
  end

  def down, do: :ok

  defp scoped(table) do
    execute("ALTER TABLE relay.#{table} ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE relay.#{table} FORCE ROW LEVEL SECURITY")

    execute(
      "CREATE POLICY #{table}_scope ON relay.#{table} USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})"
    )

    execute(
      "GRANT SELECT ON relay.#{table} TO relay_app, relay_maint, relay_archive, relay_report"
    )
  end

  defp mutable(table) do
    execute("""
    CREATE TRIGGER #{table}_no_delete BEFORE DELETE ON relay.#{table}
      FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    execute("""
    CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON relay.#{table}
      FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    scoped(table)
    execute("GRANT SELECT, INSERT, UPDATE ON relay.#{table} TO relay_owner")
  end

  # INV-6
  # INV-49
  defp append_only(table) do
    execute("""
    CREATE TRIGGER #{table}_append_only BEFORE UPDATE OR DELETE ON relay.#{table}
      FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    execute("""
    CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON relay.#{table}
      FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    scoped(table)
    execute("GRANT SELECT, INSERT ON relay.#{table} TO relay_owner")
  end

  defp record_kinds do
    [
      "ALTER TABLE relay.mailbox_records DROP CONSTRAINT mailbox_records_kind_check",
      """
      ALTER TABLE relay.mailbox_records ADD CONSTRAINT mailbox_records_kind_check
        CHECK (kind IN ('message', 'waitpoint_event', 'early_event', 'request_message',
          'blocked_message'))
        NOT VALID
      """,
      "ALTER TABLE relay.mailbox_records DROP CONSTRAINT mailbox_records_held_check",
      """
      ALTER TABLE relay.mailbox_records ADD CONSTRAINT mailbox_records_held_check
        CHECK ((kind IN ('early_event', 'request_message', 'blocked_message'))
          = (delivery_state = 'held'))
        NOT VALID
      """
    ]
  end

  defp statements do
    [
      ~S"""
      CREATE TABLE relay.agent_relationships (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        owner_agent_id uuid NOT NULL,
        peer_agent_id uuid NOT NULL,
        level text NOT NULL
          CONSTRAINT agent_relationships_level_check
            CHECK (level IN ('unknown', 'known', 'verified', 'trusted')),
        sequence bigint NOT NULL
          CONSTRAINT agent_relationships_sequence_check CHECK (sequence >= 0),
        source_event_ref text NOT NULL
          CONSTRAINT agent_relationships_source_event_ref_check
            CHECK (char_length(source_event_ref) BETWEEN 1 AND 256),
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT agent_relationships_pkey
          PRIMARY KEY (tenant_id, environment, owner_agent_id, peer_agent_id),
        CONSTRAINT agent_relationships_pair_check CHECK (owner_agent_id <> peer_agent_id),
        CONSTRAINT agent_relationships_owner_agent_id_fkey
          FOREIGN KEY (tenant_id, environment, owner_agent_id)
          REFERENCES relay.recipients (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT agent_relationships_peer_agent_id_fkey
          FOREIGN KEY (tenant_id, environment, peer_agent_id)
          REFERENCES relay.recipients (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      ~S"""
      CREATE TABLE relay.agent_blocks (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        owner_agent_id uuid NOT NULL,
        sender_agent_id uuid NOT NULL,
        state text NOT NULL
          CONSTRAINT agent_blocks_state_check CHECK (state IN ('blocked', 'lifted')),
        blocked_at timestamptz NOT NULL,
        lifted_at timestamptz,
        changed_by_ref text NOT NULL
          CONSTRAINT agent_blocks_changed_by_ref_check
            CHECK (char_length(changed_by_ref) BETWEEN 1 AND 256),
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT agent_blocks_pkey
          PRIMARY KEY (tenant_id, environment, owner_agent_id, sender_agent_id),
        CONSTRAINT agent_blocks_pair_check CHECK (owner_agent_id <> sender_agent_id),
        CONSTRAINT agent_blocks_lifted_at_check
          CHECK ((state = 'lifted') = (lifted_at IS NOT NULL)),
        CONSTRAINT agent_blocks_owner_agent_id_fkey
          FOREIGN KEY (tenant_id, environment, owner_agent_id)
          REFERENCES relay.recipients (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT agent_blocks_sender_agent_id_fkey
          FOREIGN KEY (tenant_id, environment, sender_agent_id)
          REFERENCES relay.recipients (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      ~S"""
      CREATE TABLE relay.agent_messages (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        record_id uuid NOT NULL,
        record_created_at timestamptz NOT NULL,
        mailbox_id uuid NOT NULL,
        recipient_agent_id uuid NOT NULL,
        sender_agent_id uuid NOT NULL,
        box text NOT NULL
          CONSTRAINT agent_messages_box_check CHECK (box IN ('inbox', 'requests', 'blocked')),
        trust_label text NOT NULL
          CONSTRAINT agent_messages_trust_label_check
            CHECK (trust_label IN ('authenticated', 'unauthenticated', 'spam', 'blocked')),
        relationship text NOT NULL
          CONSTRAINT agent_messages_relationship_check
            CHECK (relationship IN ('unknown', 'known', 'verified', 'trusted')),
        content_encryption text NOT NULL
          CONSTRAINT agent_messages_content_encryption_check
            CHECK (content_encryption ~ '^[A-Za-z0-9][A-Za-z0-9._+:/-]{0,63}$'),
        size bigint NOT NULL
          CONSTRAINT agent_messages_size_check CHECK (size BETWEEN 1 AND 262144),
        first_contact boolean NOT NULL,
        created_at timestamptz NOT NULL,
        CONSTRAINT agent_messages_pkey PRIMARY KEY (tenant_id, environment, record_id),
        CONSTRAINT agent_messages_pair_check CHECK (recipient_agent_id <> sender_agent_id),
        CONSTRAINT agent_messages_blocked_check
          CHECK ((box = 'blocked') = (trust_label = 'blocked')),
        CONSTRAINT agent_messages_requests_check
          CHECK (box = 'blocked' OR (box = 'requests') = (relationship = 'unknown')),
        CONSTRAINT agent_messages_first_contact_check
          CHECK (first_contact = (relationship = 'unknown')),
        CONSTRAINT agent_messages_record_id_fkey
          FOREIGN KEY (tenant_id, environment, record_id, record_created_at)
          REFERENCES relay.mailbox_records (tenant_id, environment, id, created_at)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT agent_messages_mailbox_id_fkey FOREIGN KEY (tenant_id, environment, mailbox_id)
          REFERENCES relay.mailboxes (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT agent_messages_recipient_agent_id_fkey
          FOREIGN KEY (tenant_id, environment, recipient_agent_id)
          REFERENCES relay.recipients (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT agent_messages_sender_agent_id_fkey
          FOREIGN KEY (tenant_id, environment, sender_agent_id)
          REFERENCES relay.recipients (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE INDEX agent_messages_box_index ON relay.agent_messages
        (tenant_id, environment, recipient_agent_id, box, record_id)
      """,
      """
      CREATE INDEX agent_messages_first_contact_index ON relay.agent_messages
        (tenant_id, environment, sender_agent_id, created_at)
        WHERE first_contact
      """,
      ~S"""
      CREATE TABLE relay.first_contact_tokens (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        token_digest relay.sha256 NOT NULL,
        token_key_id relay.sha256 NOT NULL,
        spent_at timestamptz NOT NULL,
        CONSTRAINT first_contact_tokens_pkey PRIMARY KEY (tenant_id, environment, token_digest)
      )
      """,
      ~S"""
      CREATE TABLE relay.mailbox_abuse_reports (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        record_id uuid NOT NULL,
        mailbox_id uuid NOT NULL,
        reporter_agent_id uuid NOT NULL,
        sender_agent_id uuid NOT NULL,
        statement_attached boolean NOT NULL,
        created_at timestamptz NOT NULL,
        CONSTRAINT mailbox_abuse_reports_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT mailbox_abuse_reports_record_id_key UNIQUE (tenant_id, environment, record_id),
        CONSTRAINT mailbox_abuse_reports_record_id_fkey
          FOREIGN KEY (tenant_id, environment, record_id)
          REFERENCES relay.agent_messages (tenant_id, environment, record_id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT mailbox_abuse_reports_mailbox_id_fkey
          FOREIGN KEY (tenant_id, environment, mailbox_id)
          REFERENCES relay.mailboxes (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT mailbox_abuse_reports_reporter_agent_id_fkey
          FOREIGN KEY (tenant_id, environment, reporter_agent_id)
          REFERENCES relay.recipients (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT mailbox_abuse_reports_sender_agent_id_fkey
          FOREIGN KEY (tenant_id, environment, sender_agent_id)
          REFERENCES relay.recipients (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """
    ]
  end
end
