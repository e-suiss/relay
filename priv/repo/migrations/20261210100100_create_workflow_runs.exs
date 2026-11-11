defmodule Relay.Repo.Migrations.CreateWorkflowRuns do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  # WF-59 (5)
  # WF-43
  # WF-6
  # WF-7
  # TN-12
  # TN-13
  def up do
    execute(~S"""
    CREATE TABLE relay.workflow_runs (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      id uuid NOT NULL,
      notification_id uuid NOT NULL,
      workflow_id uuid NOT NULL,
      workflow_version_id uuid NOT NULL,
      plan jsonb NOT NULL
        CONSTRAINT workflow_runs_plan_check CHECK (pg_column_size(plan) <= 262144),
      step_cursor jsonb NOT NULL
        CONSTRAINT workflow_runs_step_cursor_check CHECK (pg_column_size(step_cursor) <= 8192),
      step_results jsonb NOT NULL
        CONSTRAINT workflow_runs_step_results_check
          CHECK (pg_column_size(step_results) <= 131072),
      state text NOT NULL
        CONSTRAINT workflow_runs_state_check
          CHECK (state IN ('running', 'waiting', 'completed', 'cancelled')),
      wake_at timestamptz,
      outcome text
        CONSTRAINT workflow_runs_outcome_check
          CHECK (outcome IN ('completed', 'stopped', 'cancelled')),
      rule_id text
        CONSTRAINT workflow_runs_rule_id_check CHECK (char_length(rule_id) BETWEEN 1 AND 128),
      started_at timestamptz NOT NULL,
      finished_at timestamptz,
      version bigint NOT NULL CONSTRAINT workflow_runs_version_check CHECK (version >= 1),
      created_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      CONSTRAINT workflow_runs_pkey PRIMARY KEY (tenant_id, environment, id),
      CONSTRAINT workflow_runs_notification_id_key
        UNIQUE (tenant_id, environment, notification_id),
      CONSTRAINT workflow_runs_wake_at_check CHECK ((state = 'waiting') = (wake_at IS NOT NULL)),
      CONSTRAINT workflow_runs_finished_check
        CHECK ((state IN ('completed', 'cancelled')) = (finished_at IS NOT NULL)),
      CONSTRAINT workflow_runs_outcome_state_check
        CHECK ((state IN ('completed', 'cancelled')) = (outcome IS NOT NULL)),
      CONSTRAINT workflow_runs_notification_id_fkey
        FOREIGN KEY (tenant_id, environment, notification_id)
        REFERENCES relay.notifications (tenant_id, environment, id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
      CONSTRAINT workflow_runs_workflow_id_fkey FOREIGN KEY (tenant_id, environment, workflow_id)
        REFERENCES relay.workflows (tenant_id, environment, id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
      CONSTRAINT workflow_runs_workflow_version_id_fkey
        FOREIGN KEY (tenant_id, environment, workflow_version_id)
        REFERENCES relay.workflow_versions (tenant_id, environment, id)
        ON DELETE RESTRICT ON UPDATE RESTRICT
    )
    """)

    execute("""
    CREATE INDEX workflow_runs_wake_at_idx ON relay.workflow_runs (tenant_id, environment, wake_at)
      WHERE state = 'waiting'
    """)

    execute(
      "CREATE INDEX workflow_runs_wake_idx ON relay.workflow_runs (wake_at) WHERE state = 'waiting'"
    )

    execute("""
    CREATE TRIGGER workflow_runs_no_delete BEFORE DELETE ON relay.workflow_runs
      FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    execute("""
    CREATE TRIGGER workflow_runs_no_truncate BEFORE TRUNCATE ON relay.workflow_runs
      FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    execute("ALTER TABLE relay.workflow_runs ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE relay.workflow_runs FORCE ROW LEVEL SECURITY")

    execute(
      "CREATE POLICY workflow_runs_scope ON relay.workflow_runs USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})"
    )

    execute("GRANT SELECT, INSERT, UPDATE ON relay.workflow_runs TO relay_owner")

    execute(
      "GRANT SELECT ON relay.workflow_runs TO relay_app, relay_maint, relay_archive, relay_report"
    )
  end

  def down, do: :ok
end
