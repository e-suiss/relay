defmodule Relay.Repo.Migrations.CreateQuotaTables do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  # API-51
  # API-79 (1)
  # TN-52
  # TN-12
  # TN-13
  def up do
    execute(~S"""
    CREATE TABLE relay.quota_policies (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      period text NOT NULL CONSTRAINT quota_policies_period_check CHECK (period IN ('day', 'month')),
      limit_total bigint NOT NULL
        CONSTRAINT quota_policies_limit_total_check CHECK (limit_total >= 0),
      class_caps jsonb NOT NULL DEFAULT '{}'
        CONSTRAINT quota_policies_class_caps_check CHECK (pg_column_size(class_caps) <= 1024),
      security_reserve_bp smallint NOT NULL DEFAULT 1000
        CONSTRAINT quota_policies_security_reserve_bp_check
          CHECK (security_reserve_bp BETWEEN 0 AND 10000),
      state text NOT NULL
        CONSTRAINT quota_policies_state_check CHECK (state IN ('active', 'removed')),
      version bigint NOT NULL CONSTRAINT quota_policies_version_check CHECK (version >= 1),
      updated_by_ref text NOT NULL
        CONSTRAINT quota_policies_updated_by_ref_check
          CHECK (char_length(updated_by_ref) BETWEEN 1 AND 256),
      created_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      CONSTRAINT quota_policies_pkey PRIMARY KEY (tenant_id, environment, period)
    )
    """)

    scoped("quota_policies", "relay_app, relay_maint, relay_archive, relay_report")

    execute(~S"""
    CREATE TABLE relay.quota_counters (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      period text NOT NULL CONSTRAINT quota_counters_period_check CHECK (period IN ('day', 'month')),
      period_start timestamptz NOT NULL,
      message_class relay.message_class NOT NULL,
      in_reserve boolean NOT NULL,
      shard smallint NOT NULL CONSTRAINT quota_counters_shard_check CHECK (shard BETWEEN 0 AND 15),
      used bigint NOT NULL CONSTRAINT quota_counters_used_check CHECK (used >= 0),
      updated_at timestamptz NOT NULL,
      CONSTRAINT quota_counters_pkey
        PRIMARY KEY (tenant_id, environment, period, period_start, message_class, in_reserve, shard)
    )
    """)

    scoped("quota_counters", "relay_app, relay_maint, relay_archive, relay_report")

    execute(~S"""
    CREATE TABLE relay.quota_threshold_marks (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      period text NOT NULL
        CONSTRAINT quota_threshold_marks_period_check CHECK (period IN ('day', 'month')),
      period_start timestamptz NOT NULL,
      mark text NOT NULL
        CONSTRAINT quota_threshold_marks_mark_check CHECK (mark IN ('p80', 'p100', 'reserve')),
      created_at timestamptz NOT NULL,
      CONSTRAINT quota_threshold_marks_pkey
        PRIMARY KEY (tenant_id, environment, period, period_start, mark)
    )
    """)

    scoped("quota_threshold_marks", "relay_app, relay_maint, relay_archive")
  end

  defp scoped(table, readers) do
    execute("ALTER TABLE relay.#{table} ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE relay.#{table} FORCE ROW LEVEL SECURITY")

    execute(
      "CREATE POLICY #{table}_scope ON relay.#{table} USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})"
    )

    execute("GRANT SELECT, INSERT, UPDATE ON relay.#{table} TO relay_owner")
    execute("GRANT SELECT ON relay.#{table} TO #{readers}")
  end
end
