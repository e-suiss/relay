defmodule Relay.Repo.Migrations.CreateTopics do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  # WF-51
  # WF-52
  # WF-53
  # WF-55
  # C-51
  # L-3
  # F-5
  # TN-12
  # TN-13
  # OP-9
  def up do
    execute(~S"""
    CREATE TABLE relay.topics (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      id uuid NOT NULL,
      key text NOT NULL CONSTRAINT topics_key_check CHECK (key ~ '^[a-z0-9][a-z0-9_.:-]{0,127}$'),
      parent_id uuid,
      state text NOT NULL CONSTRAINT topics_state_check CHECK (state IN ('active', 'archived')),
      version bigint NOT NULL CONSTRAINT topics_version_check CHECK (version >= 1),
      archived_at timestamptz,
      created_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      CONSTRAINT topics_pkey PRIMARY KEY (tenant_id, environment, id),
      CONSTRAINT topics_key_key UNIQUE (tenant_id, environment, key),
      CONSTRAINT topics_archived_check CHECK ((state = 'archived') = (archived_at IS NOT NULL)),
      CONSTRAINT topics_parent_check CHECK (parent_id IS DISTINCT FROM id),
      CONSTRAINT topics_parent_id_fkey FOREIGN KEY (tenant_id, environment, parent_id)
        REFERENCES relay.topics (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
    )
    """)

    execute("""
    CREATE INDEX topics_parent_index ON relay.topics (tenant_id, environment, parent_id)
      WHERE parent_id IS NOT NULL
    """)

    execute(~S"""
    CREATE TABLE relay.topic_subscriptions (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      id uuid NOT NULL,
      topic_id uuid NOT NULL,
      recipient_id uuid NOT NULL,
      state text NOT NULL
        CONSTRAINT topic_subscriptions_state_check CHECK (state IN ('active', 'removed')),
      removed_reason text
        CONSTRAINT topic_subscriptions_removed_reason_check
          CHECK (removed_reason IN ('unsubscribed', 'subscriber_deleted')),
      removed_at timestamptz,
      created_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      CONSTRAINT topic_subscriptions_pkey PRIMARY KEY (tenant_id, environment, id),
      CONSTRAINT topic_subscriptions_removed_check
        CHECK ((state = 'removed') = (removed_at IS NOT NULL)
          AND (state = 'removed') = (removed_reason IS NOT NULL)),
      CONSTRAINT topic_subscriptions_topic_id_fkey FOREIGN KEY (tenant_id, environment, topic_id)
        REFERENCES relay.topics (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
      CONSTRAINT topic_subscriptions_recipient_id_fkey
        FOREIGN KEY (tenant_id, environment, recipient_id)
        REFERENCES relay.recipients (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
    )
    """)

    execute("""
    CREATE UNIQUE INDEX topic_subscriptions_active_key ON relay.topic_subscriptions
      (tenant_id, environment, topic_id, recipient_id) WHERE state = 'active'
    """)

    execute("""
    CREATE INDEX topic_subscriptions_topic_index ON relay.topic_subscriptions
      (tenant_id, environment, topic_id, created_at, id)
    """)

    execute("""
    CREATE INDEX topic_subscriptions_recipient_index ON relay.topic_subscriptions
      (tenant_id, environment, recipient_id, created_at, id)
    """)

    execute(~S"""
    CREATE TABLE relay.audiences (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      id uuid NOT NULL,
      source_kind text NOT NULL
        CONSTRAINT audiences_source_kind_check CHECK (source_kind ~ '^[a-z_]{1,32}$'),
      source_id uuid NOT NULL,
      topic_ids uuid[] NOT NULL
        CONSTRAINT audiences_topic_ids_check CHECK (cardinality(topic_ids) BETWEEN 1 AND 100),
      member_count bigint NOT NULL CONSTRAINT audiences_member_count_check CHECK (member_count >= 0),
      rule_id text CONSTRAINT audiences_rule_id_check CHECK (char_length(rule_id) <= 128),
      created_at timestamptz NOT NULL,
      CONSTRAINT audiences_pkey PRIMARY KEY (tenant_id, environment, id),
      CONSTRAINT audiences_source_key UNIQUE (tenant_id, environment, source_kind, source_id),
      CONSTRAINT audiences_reached_check CHECK ((member_count = 0) = (rule_id IS NOT NULL))
    )
    """)

    execute(~S"""
    CREATE TABLE relay.audience_members (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      audience_id uuid NOT NULL,
      recipient_id uuid NOT NULL,
      topic_id uuid NOT NULL,
      also_direct boolean NOT NULL,
      created_at timestamptz NOT NULL,
      CONSTRAINT audience_members_pkey PRIMARY KEY (tenant_id, environment, audience_id, recipient_id),
      CONSTRAINT audience_members_audience_id_fkey FOREIGN KEY (tenant_id, environment, audience_id)
        REFERENCES relay.audiences (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
      CONSTRAINT audience_members_recipient_id_fkey
        FOREIGN KEY (tenant_id, environment, recipient_id)
        REFERENCES relay.recipients (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
      CONSTRAINT audience_members_topic_id_fkey FOREIGN KEY (tenant_id, environment, topic_id)
        REFERENCES relay.topics (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
    )
    """)

    execute("""
    CREATE INDEX audience_members_recipient_index ON relay.audience_members
      (tenant_id, environment, recipient_id)
    """)

    execute("""
    CREATE INDEX audience_members_topic_index ON relay.audience_members
      (tenant_id, environment, topic_id)
    """)

    for table <- ~w(topics topic_subscriptions audiences audience_members) do
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

  def down, do: :ok
end
