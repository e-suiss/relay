defmodule Relay.Repo.Migrations.CreateInboxTables do
  use Ecto.Migration

  @partitions 16

  @grants %{
    tenant: [
      {"SELECT, INSERT, UPDATE", "relay_owner"},
      {"SELECT", "relay_app, relay_maint, relay_archive, relay_report"}
    ],
    tenant_append: [
      {"SELECT, INSERT", "relay_owner"},
      {"SELECT", "relay_app, relay_maint, relay_archive, relay_report"}
    ]
  }

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  # IN-2
  # IN-4
  # IN-5
  # IN-7
  # IN-9
  # IN-11
  # IN-18
  # IN-19
  # IN-44
  # IN-49
  def up do
    Enum.each(statements(), &execute/1)
  end

  def down, do: :ok

  defp statements do
    List.flatten([items(), partitions(), deliveries(), counters()])
  end

  defp items do
    [
      ~S"""
      CREATE TABLE relay.inbox_items (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        recipient_id uuid NOT NULL,
        subtenant_id uuid,
        notification_id uuid NOT NULL,
        delivery_id uuid NOT NULL,
        message_class text NOT NULL
          CONSTRAINT inbox_items_message_class_check CHECK (message_class ~ '^[a-z_]{1,32}$'),
        retention_class text NOT NULL
          CONSTRAINT inbox_items_retention_class_check
            CHECK (retention_class IN ('notification_content', 'commercial_message')),
        category text
          CONSTRAINT inbox_items_category_check CHECK (char_length(category) BETWEEN 1 AND 128),
        tags text[] NOT NULL DEFAULT '{}'
          CONSTRAINT inbox_items_tags_check CHECK (cardinality(tags) <= 10),
        severity text
          CONSTRAINT inbox_items_severity_check CHECK (severity ~ '^[a-z_]{1,32}$'),
        group_key text
          CONSTRAINT inbox_items_group_key_check CHECK (octet_length(group_key) BETWEEN 1 AND 128),
        content_ct bytea NOT NULL
          CONSTRAINT inbox_items_content_ct_check CHECK (octet_length(content_ct) <= 16384 + 29),
        content_key_id uuid NOT NULL,
        content_digest relay.sha256 NOT NULL,
        locale text CONSTRAINT inbox_items_locale_check CHECK (char_length(locale) BETWEEN 2 AND 35),
        dir text CONSTRAINT inbox_items_dir_check CHECK (dir IN ('ltr', 'rtl', 'auto')),
        activity_count bigint NOT NULL DEFAULT 1
          CONSTRAINT inbox_items_activity_count_check CHECK (activity_count >= 1),
        actor_count bigint NOT NULL DEFAULT 0
          CONSTRAINT inbox_items_actor_count_check CHECK (actor_count >= 0),
        last_activity_at timestamptz NOT NULL,
        expires_at timestamptz,
        expired_at timestamptz,
        snoozed_until timestamptz,
        seen_at timestamptz,
        read_at timestamptz,
        unread_marked_at timestamptz,
        archived_at timestamptz,
        unarchived_at timestamptz,
        hidden_at timestamptz,
        hidden_reason text
          CONSTRAINT inbox_items_hidden_reason_check CHECK (hidden_reason IN ('user', 'retracted')),
        counted_total boolean NOT NULL DEFAULT false,
        counted_unseen boolean NOT NULL DEFAULT false,
        counted_unread boolean NOT NULL DEFAULT false,
        state_version bigint NOT NULL DEFAULT 1
          CONSTRAINT inbox_items_state_version_check CHECK (state_version >= 1),
        created_epoch bigint NOT NULL,
        created_seq bigint NOT NULL,
        change_epoch bigint NOT NULL,
        change_seq bigint NOT NULL,
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT inbox_items_pkey PRIMARY KEY (tenant_id, environment, id, recipient_id),
        CONSTRAINT inbox_items_notification_key
          UNIQUE (tenant_id, environment, recipient_id, notification_id),
        CONSTRAINT inbox_items_position_check
          CHECK (created_epoch >= 1 AND created_seq >= 1 AND change_epoch >= 1 AND change_seq >= 1),
        CONSTRAINT inbox_items_hidden_check CHECK ((hidden_at IS NULL) = (hidden_reason IS NULL)),
        CONSTRAINT inbox_items_expired_check
          CHECK (expired_at IS NULL OR (expires_at IS NOT NULL AND expired_at >= expires_at)),
        CONSTRAINT inbox_items_counted_check
          CHECK ((NOT counted_unseen AND NOT counted_unread) OR counted_total),
        CONSTRAINT inbox_items_recipient_id_fkey FOREIGN KEY (tenant_id, environment, recipient_id)
          REFERENCES relay.recipients (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT inbox_items_subtenant_id_fkey FOREIGN KEY (tenant_id, environment, subtenant_id)
          REFERENCES relay.subtenants (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT inbox_items_notification_id_fkey
          FOREIGN KEY (tenant_id, environment, notification_id, recipient_id)
          REFERENCES relay.notifications (tenant_id, environment, id, recipient_id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT inbox_items_delivery_id_fkey FOREIGN KEY (tenant_id, environment, delivery_id)
          REFERENCES relay.deliveries (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT inbox_items_content_key_id_fkey FOREIGN KEY (tenant_id, environment, content_key_id)
          REFERENCES relay.subject_keys (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      ) PARTITION BY HASH (recipient_id)
      """,
      """
      CREATE INDEX inbox_items_list_index ON relay.inbox_items
        (tenant_id, environment, recipient_id, last_activity_at DESC, id DESC)
      """,
      """
      CREATE INDEX inbox_items_change_index ON relay.inbox_items
        (tenant_id, environment, recipient_id, change_epoch, change_seq)
      """,
      """
      CREATE INDEX inbox_items_group_index ON relay.inbox_items
        (tenant_id, environment, recipient_id, group_key)
        WHERE group_key IS NOT NULL AND hidden_at IS NULL
      """,
      """
      CREATE TRIGGER inbox_items_no_delete BEFORE DELETE ON relay.inbox_items
        FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
      """,
      """
      CREATE TRIGGER inbox_items_no_truncate BEFORE TRUNCATE ON relay.inbox_items
        FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
      """,
      scoped("inbox_items", :tenant)
    ]
  end

  defp partitions do
    for remainder <- 0..(@partitions - 1) do
      name = "inbox_items_p" <> String.pad_leading(Integer.to_string(remainder), 6, "0")

      [
        """
        CREATE TABLE relay.#{name} PARTITION OF relay.inbox_items
          FOR VALUES WITH (MODULUS #{@partitions}, REMAINDER #{remainder})
        """,
        "ALTER TABLE relay.#{name} ENABLE ROW LEVEL SECURITY",
        "ALTER TABLE relay.#{name} FORCE ROW LEVEL SECURITY",
        "CREATE POLICY #{name}_scope ON relay.#{name} USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})",
        """
        CREATE TRIGGER #{name}_no_truncate BEFORE TRUNCATE ON relay.#{name}
          FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
        """,
        "GRANT SELECT ON relay.#{name} TO relay_maint, relay_archive"
      ]
    end
  end

  defp deliveries do
    [
      ~S"""
      CREATE TABLE relay.inbox_item_deliveries (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        delivery_id uuid NOT NULL,
        item_id uuid NOT NULL,
        recipient_id uuid NOT NULL,
        outcome text NOT NULL
          CONSTRAINT inbox_item_deliveries_outcome_check
            CHECK (outcome IN ('created', 'updated', 'exists')),
        created_at timestamptz NOT NULL,
        CONSTRAINT inbox_item_deliveries_pkey PRIMARY KEY (tenant_id, environment, delivery_id),
        CONSTRAINT inbox_item_deliveries_delivery_id_fkey
          FOREIGN KEY (tenant_id, environment, delivery_id)
          REFERENCES relay.deliveries (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT inbox_item_deliveries_item_id_fkey
          FOREIGN KEY (tenant_id, environment, item_id, recipient_id)
          REFERENCES relay.inbox_items (tenant_id, environment, id, recipient_id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE INDEX inbox_item_deliveries_item_index ON relay.inbox_item_deliveries
        (tenant_id, environment, item_id)
      """,
      """
      CREATE TRIGGER inbox_item_deliveries_append_only BEFORE UPDATE OR DELETE
        ON relay.inbox_item_deliveries FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
      """,
      """
      CREATE TRIGGER inbox_item_deliveries_no_truncate BEFORE TRUNCATE ON relay.inbox_item_deliveries
        FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
      """,
      scoped("inbox_item_deliveries", :tenant_append)
    ]
  end

  defp counters do
    [
      ~S"""
      CREATE TABLE relay.inbox_counters (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        recipient_id uuid NOT NULL,
        unseen_count bigint NOT NULL DEFAULT 0
          CONSTRAINT inbox_counters_unseen_count_check CHECK (unseen_count >= 0),
        unread_count bigint NOT NULL DEFAULT 0
          CONSTRAINT inbox_counters_unread_count_check CHECK (unread_count >= 0),
        total_count bigint NOT NULL DEFAULT 0
          CONSTRAINT inbox_counters_total_count_check CHECK (total_count >= 0),
        version bigint NOT NULL DEFAULT 0 CONSTRAINT inbox_counters_version_check CHECK (version >= 0),
        updated_at timestamptz NOT NULL,
        CONSTRAINT inbox_counters_pkey PRIMARY KEY (tenant_id, environment, recipient_id),
        CONSTRAINT inbox_counters_bounds_check
          CHECK (unseen_count <= total_count AND unread_count <= total_count),
        CONSTRAINT inbox_counters_recipient_id_fkey FOREIGN KEY (tenant_id, environment, recipient_id)
          REFERENCES relay.recipients (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE TRIGGER inbox_counters_no_delete BEFORE DELETE ON relay.inbox_counters
        FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
      """,
      """
      CREATE TRIGGER inbox_counters_no_truncate BEFORE TRUNCATE ON relay.inbox_counters
        FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
      """,
      scoped("inbox_counters", :tenant)
    ]
  end

  defp scoped(table, group) do
    grants =
      for {privileges, roles} <- Map.fetch!(@grants, group),
          do: "GRANT #{privileges} ON relay.#{table} TO #{roles}"

    [
      "ALTER TABLE relay.#{table} ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE relay.#{table} FORCE ROW LEVEL SECURITY",
      "CREATE POLICY #{table}_scope ON relay.#{table} USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})",
      grants
    ]
  end
end
