defmodule Relay.Repo.Migrations.CreateCampaigns do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"
  @tables ~w(campaigns campaign_members campaign_stages campaign_preview_counts)

  # API-35
  # WF-44
  # WF-62
  # WF-34
  # T-23
  # X-14
  # TN-12
  # TN-13
  def up do
    Enum.each(tables(), &execute/1)
    Enum.each(indexes(), &execute/1)

    for table <- @tables do
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

  defp tables do
    [
      ~S"""
      CREATE TABLE relay.campaigns (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        name text NOT NULL CONSTRAINT campaigns_name_check CHECK (char_length(name) BETWEEN 1 AND 200),
        workflow_key text NOT NULL
          CONSTRAINT campaigns_workflow_key_check CHECK (char_length(workflow_key) BETWEEN 1 AND 128),
        workflow_id uuid,
        workflow_version_no bigint
          CONSTRAINT campaigns_workflow_version_no_check CHECK (workflow_version_no >= 1),
        message_class relay.message_class,
        audience_kind text NOT NULL
          CONSTRAINT campaigns_audience_kind_check CHECK (audience_kind IN ('list', 'topic')),
        topic_key text CONSTRAINT campaigns_topic_key_check CHECK (char_length(topic_key) BETWEEN 1 AND 256),
        data_key_id uuid NOT NULL,
        data_ct bytea NOT NULL CONSTRAINT campaigns_data_ct_check CHECK (octet_length(data_ct) <= 262144 + 64),
        api_client_ref text
          CONSTRAINT campaigns_api_client_ref_check CHECK (char_length(api_client_ref) <= 64),
        expected_count bigint NOT NULL
          CONSTRAINT campaigns_expected_count_check CHECK (expected_count BETWEEN 1 AND 10000000),
        deadline timestamptz NOT NULL,
        state text NOT NULL
          CONSTRAINT campaigns_state_check
            CHECK (state IN ('draft', 'preparing', 'prepared', 'running', 'paused', 'completed',
              'partial', 'cancelled')),
        audience_count bigint NOT NULL DEFAULT 0
          CONSTRAINT campaigns_audience_count_check CHECK (audience_count BETWEEN 0 AND 10000000),
        not_found_count bigint NOT NULL DEFAULT 0
          CONSTRAINT campaigns_not_found_count_check CHECK (not_found_count >= 0),
        prepare_after uuid,
        evaluated_count bigint NOT NULL DEFAULT 0
          CONSTRAINT campaigns_evaluated_count_check CHECK (evaluated_count >= 0),
        reachable_count bigint NOT NULL DEFAULT 0
          CONSTRAINT campaigns_reachable_count_check CHECK (reachable_count >= 0),
        estimate jsonb
          CONSTRAINT campaigns_estimate_check
            CHECK (estimate IS NULL OR (jsonb_typeof(estimate) = 'object'
              AND pg_column_size(estimate) <= 16384)),
        estimated_duration_s bigint
          CONSTRAINT campaigns_estimated_duration_s_check CHECK (estimated_duration_s >= 0),
        samples_digest bytea
          CONSTRAINT campaigns_samples_digest_check CHECK (octet_length(samples_digest) = 32),
        samples_approved_at timestamptz,
        samples_approved_by text
          CONSTRAINT campaigns_samples_approved_by_check CHECK (char_length(samples_approved_by) <= 256),
        audience_approval_required boolean NOT NULL DEFAULT false,
        audience_approved_at timestamptz,
        audience_approved_by text
          CONSTRAINT campaigns_audience_approved_by_check CHECK (char_length(audience_approved_by) <= 256),
        stage_count bigint CONSTRAINT campaigns_stage_count_check CHECK (stage_count IN (1, 3)),
        stage_no bigint NOT NULL DEFAULT 0
          CONSTRAINT campaigns_stage_no_check CHECK (stage_no BETWEEN 0 AND 3),
        next_stage_at timestamptz,
        accepted_count bigint NOT NULL DEFAULT 0
          CONSTRAINT campaigns_accepted_count_check CHECK (accepted_count >= 0),
        rejected_count bigint NOT NULL DEFAULT 0
          CONSTRAINT campaigns_rejected_count_check CHECK (rejected_count >= 0),
        expired_count bigint NOT NULL DEFAULT 0
          CONSTRAINT campaigns_expired_count_check CHECK (expired_count >= 0),
        cancelled_count bigint NOT NULL DEFAULT 0
          CONSTRAINT campaigns_cancelled_count_check CHECK (cancelled_count >= 0),
        pause_rule_id relay.rule_id,
        close_rule_id relay.rule_id,
        overrun_reported boolean NOT NULL DEFAULT false,
        prepared_at timestamptz,
        triggered_at timestamptz,
        closed_at timestamptz,
        version bigint NOT NULL DEFAULT 1 CONSTRAINT campaigns_version_check CHECK (version >= 1),
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT campaigns_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT campaigns_topic_check CHECK ((audience_kind = 'topic') = (topic_key IS NOT NULL)),
        CONSTRAINT campaigns_pause_check CHECK ((state = 'paused') = (pause_rule_id IS NOT NULL)),
        CONSTRAINT campaigns_closed_check
          CHECK ((state IN ('completed', 'partial', 'cancelled')) = (closed_at IS NOT NULL)),
        CONSTRAINT campaigns_frozen_check
          CHECK (state IN ('draft', 'cancelled')
            OR (workflow_id IS NOT NULL AND workflow_version_no IS NOT NULL
              AND message_class IS NOT NULL)),
        CONSTRAINT campaigns_triggered_check
          CHECK (state NOT IN ('running', 'paused')
            OR (triggered_at IS NOT NULL AND stage_count IS NOT NULL)),
        CONSTRAINT campaigns_workflow_id_fkey FOREIGN KEY (tenant_id, environment, workflow_id)
          REFERENCES relay.workflows (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT campaigns_data_key_id_fkey FOREIGN KEY (tenant_id, environment, data_key_id)
          REFERENCES relay.tenant_keys (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      ~S"""
      CREATE TABLE relay.campaign_members (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        campaign_id uuid NOT NULL,
        id uuid NOT NULL,
        recipient_id uuid NOT NULL,
        dedup_key text NOT NULL
          CONSTRAINT campaign_members_dedup_key_check CHECK (char_length(dedup_key) BETWEEN 1 AND 128),
        state text NOT NULL
          CONSTRAINT campaign_members_state_check CHECK (state IN ('pending', 'accepted', 'rejected')),
        notification_id uuid,
        reject_code text
          CONSTRAINT campaign_members_reject_code_check CHECK (char_length(reject_code) BETWEEN 1 AND 64),
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT campaign_members_pkey PRIMARY KEY (tenant_id, environment, campaign_id, id),
        CONSTRAINT campaign_members_recipient_key
          UNIQUE (tenant_id, environment, campaign_id, recipient_id),
        CONSTRAINT campaign_members_accepted_check
          CHECK ((state = 'accepted') = (notification_id IS NOT NULL)),
        CONSTRAINT campaign_members_rejected_check
          CHECK ((state = 'rejected') = (reject_code IS NOT NULL)),
        CONSTRAINT campaign_members_campaign_id_fkey FOREIGN KEY (tenant_id, environment, campaign_id)
          REFERENCES relay.campaigns (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT campaign_members_recipient_id_fkey FOREIGN KEY (tenant_id, environment, recipient_id)
          REFERENCES relay.recipients (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT campaign_members_notification_id_fkey
          FOREIGN KEY (tenant_id, environment, notification_id)
          REFERENCES relay.notifications (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      ~S"""
      CREATE TABLE relay.campaign_stages (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        campaign_id uuid NOT NULL,
        stage_no bigint NOT NULL CONSTRAINT campaign_stages_stage_no_check CHECK (stage_no BETWEEN 1 AND 3),
        percent bigint NOT NULL CONSTRAINT campaign_stages_percent_check CHECK (percent IN (1, 10, 100)),
        range_from uuid,
        range_to uuid,
        member_count bigint NOT NULL CONSTRAINT campaign_stages_member_count_check CHECK (member_count >= 0),
        done_count bigint NOT NULL DEFAULT 0
          CONSTRAINT campaign_stages_done_count_check CHECK (done_count BETWEEN 0 AND member_count),
        fanout_id uuid,
        opened_at timestamptz,
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT campaign_stages_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT campaign_stages_stage_key UNIQUE (tenant_id, environment, campaign_id, stage_no),
        CONSTRAINT campaign_stages_range_check
          CHECK (range_from IS NULL OR range_to IS NULL OR range_from < range_to),
        CONSTRAINT campaign_stages_opened_check CHECK ((fanout_id IS NULL) = (opened_at IS NULL)),
        CONSTRAINT campaign_stages_campaign_id_fkey FOREIGN KEY (tenant_id, environment, campaign_id)
          REFERENCES relay.campaigns (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT campaign_stages_fanout_id_fkey FOREIGN KEY (tenant_id, environment, fanout_id)
          REFERENCES relay.fanouts (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      ~S"""
      CREATE TABLE relay.campaign_preview_counts (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        campaign_id uuid NOT NULL,
        kind text NOT NULL
          CONSTRAINT campaign_preview_counts_kind_check CHECK (kind IN ('send', 'defer', 'drop')),
        key text NOT NULL
          CONSTRAINT campaign_preview_counts_key_check CHECK (char_length(key) BETWEEN 1 AND 128),
        count bigint NOT NULL CONSTRAINT campaign_preview_counts_count_check CHECK (count >= 0),
        updated_at timestamptz NOT NULL,
        CONSTRAINT campaign_preview_counts_pkey PRIMARY KEY (tenant_id, environment, campaign_id, kind, key),
        CONSTRAINT campaign_preview_counts_campaign_id_fkey
          FOREIGN KEY (tenant_id, environment, campaign_id)
          REFERENCES relay.campaigns (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """
    ]
  end

  defp indexes do
    [
      """
      CREATE INDEX campaigns_created_at_index ON relay.campaigns (tenant_id, environment, created_at, id)
      """,
      """
      CREATE INDEX campaign_members_notification_id_index ON relay.campaign_members
        (tenant_id, environment, notification_id) WHERE notification_id IS NOT NULL
      """,
      """
      CREATE INDEX campaign_members_accepted_index ON relay.campaign_members
        (tenant_id, environment, campaign_id, updated_at) WHERE state = 'accepted'
      """,
      """
      CREATE INDEX campaign_members_recipient_id_index ON relay.campaign_members
        (tenant_id, environment, recipient_id)
      """,
      """
      CREATE INDEX campaign_stages_fanout_id_index ON relay.campaign_stages
        (tenant_id, environment, fanout_id) WHERE fanout_id IS NOT NULL
      """
    ]
  end
end
