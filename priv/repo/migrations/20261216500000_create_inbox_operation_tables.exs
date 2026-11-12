defmodule Relay.Repo.Migrations.CreateInboxOperationTables do
  use Ecto.Migration

  @grants [
    {"SELECT, INSERT, UPDATE", "relay_owner"},
    {"SELECT", "relay_app, relay_maint, relay_archive, relay_report"}
  ]

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  # IN-3
  # C-70
  # API-35
  # IN-14
  # IN-50
  # IN-44
  # OP-22
  # OP-57
  def up do
    Enum.each(statements(), &execute/1)
  end

  def down, do: :ok

  defp statements do
    List.flatten([items(), announcements(), announcement_states(), read_marks(), bulk()])
  end

  defp items do
    [
      "ALTER TABLE relay.inbox_items ALTER COLUMN content_ct DROP NOT NULL",
      "ALTER TABLE relay.inbox_items ADD COLUMN retired_at timestamptz",
      "ALTER TABLE relay.inbox_items DROP CONSTRAINT inbox_items_hidden_reason_check",
      """
      ALTER TABLE relay.inbox_items ADD CONSTRAINT inbox_items_hidden_reason_check
        CHECK (hidden_reason IN ('user', 'retracted', 'retention')) NOT VALID
      """,
      """
      ALTER TABLE relay.inbox_items ADD CONSTRAINT inbox_items_retired_check
        CHECK (retired_at IS NULL OR (content_ct IS NULL AND hidden_at IS NOT NULL)) NOT VALID
      """,
      """
      ALTER TABLE relay.inbox_items ADD CONSTRAINT inbox_items_content_check
        CHECK (content_ct IS NOT NULL OR hidden_at IS NOT NULL) NOT VALID
      """
    ]
  end

  defp announcements do
    [
      ~S"""
      CREATE TABLE relay.inbox_announcements (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        audience text NOT NULL
          CONSTRAINT inbox_announcements_audience_check
            CHECK (audience IN ('tenant', 'subtenant', 'topic')),
        subtenant_id uuid,
        topic_id uuid,
        category text
          CONSTRAINT inbox_announcements_category_check
            CHECK (char_length(category) BETWEEN 1 AND 128),
        tags text[] NOT NULL DEFAULT '{}'
          CONSTRAINT inbox_announcements_tags_check CHECK (cardinality(tags) <= 10),
        severity text
          CONSTRAINT inbox_announcements_severity_check CHECK (severity ~ '^[a-z_]{1,32}$'),
        content jsonb NOT NULL
          CONSTRAINT inbox_announcements_content_check
            CHECK (
              jsonb_typeof(content) = 'object' AND octet_length(content::text) <= 16384
                AND pg_column_size(content) <= 16384
            ),
        locale text
          CONSTRAINT inbox_announcements_locale_check CHECK (char_length(locale) BETWEEN 2 AND 35),
        dir text CONSTRAINT inbox_announcements_dir_check CHECK (dir IN ('ltr', 'rtl', 'auto')),
        state text NOT NULL
          CONSTRAINT inbox_announcements_state_check
            CHECK (state IN ('active', 'retracted', 'expired')),
        published_at timestamptz NOT NULL,
        expires_at timestamptz,
        closed_at timestamptz,
        change_seq bigint NOT NULL
          CONSTRAINT inbox_announcements_change_seq_check CHECK (change_seq >= 1),
        version bigint NOT NULL DEFAULT 1
          CONSTRAINT inbox_announcements_version_check CHECK (version >= 1),
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT inbox_announcements_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT inbox_announcements_change_seq_key UNIQUE (tenant_id, environment, change_seq),
        CONSTRAINT inbox_announcements_target_check
          CHECK ((audience = 'subtenant') = (subtenant_id IS NOT NULL)
            AND (audience = 'topic') = (topic_id IS NOT NULL)),
        CONSTRAINT inbox_announcements_closed_check
          CHECK ((state = 'active') = (closed_at IS NULL)),
        CONSTRAINT inbox_announcements_expires_check
          CHECK (expires_at IS NULL OR expires_at > published_at),
        CONSTRAINT inbox_announcements_subtenant_id_fkey
          FOREIGN KEY (tenant_id, environment, subtenant_id)
          REFERENCES relay.subtenants (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT inbox_announcements_topic_id_fkey FOREIGN KEY (tenant_id, environment, topic_id)
          REFERENCES relay.topics (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE INDEX inbox_announcements_list_index ON relay.inbox_announcements
        (tenant_id, environment, published_at DESC, id DESC) WHERE state = 'active'
      """,
      no_delete("inbox_announcements"),
      scoped("inbox_announcements")
    ]
  end

  defp announcement_states do
    [
      ~S"""
      CREATE TABLE relay.inbox_announcement_states (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        announcement_id uuid NOT NULL,
        recipient_id uuid NOT NULL,
        seen_at timestamptz,
        read_at timestamptz,
        unread_marked_at timestamptz,
        archived_at timestamptz,
        unarchived_at timestamptz,
        hidden_at timestamptz,
        state_version bigint NOT NULL DEFAULT 1
          CONSTRAINT inbox_announcement_states_state_version_check CHECK (state_version >= 1),
        change_epoch bigint NOT NULL,
        change_seq bigint NOT NULL,
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT inbox_announcement_states_pkey
          PRIMARY KEY (tenant_id, environment, announcement_id, recipient_id),
        CONSTRAINT inbox_announcement_states_position_check
          CHECK (change_epoch >= 1 AND change_seq >= 1),
        CONSTRAINT inbox_announcement_states_announcement_id_fkey
          FOREIGN KEY (tenant_id, environment, announcement_id)
          REFERENCES relay.inbox_announcements (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT inbox_announcement_states_recipient_id_fkey
          FOREIGN KEY (tenant_id, environment, recipient_id)
          REFERENCES relay.recipients (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE INDEX inbox_announcement_states_change_index ON relay.inbox_announcement_states
        (tenant_id, environment, recipient_id, change_epoch, change_seq)
      """,
      no_delete("inbox_announcement_states"),
      scoped("inbox_announcement_states")
    ]
  end

  defp read_marks do
    [
      ~S"""
      CREATE TABLE relay.inbox_read_marks (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        recipient_id uuid NOT NULL,
        category text
          CONSTRAINT inbox_read_marks_category_check CHECK (char_length(category) BETWEEN 1 AND 128),
        read_through timestamptz NOT NULL,
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT inbox_read_marks_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT inbox_read_marks_scope_key
          UNIQUE NULLS NOT DISTINCT (tenant_id, environment, recipient_id, category),
        CONSTRAINT inbox_read_marks_recipient_id_fkey
          FOREIGN KEY (tenant_id, environment, recipient_id)
          REFERENCES relay.recipients (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      no_delete("inbox_read_marks"),
      scoped("inbox_read_marks")
    ]
  end

  defp bulk do
    [
      ~S"""
      CREATE TABLE relay.inbox_bulk_operations (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        recipient_id uuid NOT NULL,
        action text NOT NULL
          CONSTRAINT inbox_bulk_operations_action_check CHECK (action IN ('read', 'archive', 'hide')),
        status_filter text NOT NULL
          CONSTRAINT inbox_bulk_operations_status_filter_check
            CHECK (status_filter IN ('inbox', 'unread', 'archived', 'snoozed', 'all')),
        category text
          CONSTRAINT inbox_bulk_operations_category_check
            CHECK (char_length(category) BETWEEN 1 AND 128),
        tag text CONSTRAINT inbox_bulk_operations_tag_check CHECK (char_length(tag) BETWEEN 1 AND 64),
        cut_off timestamptz NOT NULL,
        state text NOT NULL
          CONSTRAINT inbox_bulk_operations_state_check CHECK (state IN ('running', 'completed')),
        after_id uuid,
        matched_count bigint NOT NULL DEFAULT 0
          CONSTRAINT inbox_bulk_operations_matched_count_check CHECK (matched_count >= 0),
        updated_count bigint NOT NULL DEFAULT 0
          CONSTRAINT inbox_bulk_operations_updated_count_check
            CHECK (updated_count >= 0 AND updated_count <= matched_count),
        chunk_count bigint NOT NULL DEFAULT 0
          CONSTRAINT inbox_bulk_operations_chunk_count_check CHECK (chunk_count >= 0),
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        completed_at timestamptz,
        CONSTRAINT inbox_bulk_operations_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT inbox_bulk_operations_completed_check
          CHECK ((state = 'completed') = (completed_at IS NOT NULL)),
        CONSTRAINT inbox_bulk_operations_recipient_id_fkey
          FOREIGN KEY (tenant_id, environment, recipient_id)
          REFERENCES relay.recipients (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT inbox_bulk_operations_after_id_fkey
          FOREIGN KEY (tenant_id, environment, after_id, recipient_id)
          REFERENCES relay.inbox_items (tenant_id, environment, id, recipient_id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      no_delete("inbox_bulk_operations"),
      scoped("inbox_bulk_operations")
    ]
  end

  defp no_delete(table) do
    [
      """
      CREATE TRIGGER #{table}_no_delete BEFORE DELETE ON relay.#{table}
        FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
      """,
      """
      CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON relay.#{table}
        FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
      """
    ]
  end

  defp scoped(table) do
    grants =
      for {privileges, roles} <- @grants, do: "GRANT #{privileges} ON relay.#{table} TO #{roles}"

    [
      "ALTER TABLE relay.#{table} ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE relay.#{table} FORCE ROW LEVEL SECURITY",
      "CREATE POLICY #{table}_scope ON relay.#{table} USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})",
      grants
    ]
  end
end
