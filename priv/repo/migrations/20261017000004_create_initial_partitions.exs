defmodule Relay.Repo.Migrations.CreateInitialPartitions do
  use Ecto.Migration

  # OP-13
  # OP-14
  # OP-66
  # TN-13
  def up do
    execute(~S"""
    DO $$
    DECLARE
      p record;
      v_column text;
      v_is_date boolean;
      v_step interval;
      v_from timestamptz;
      v_to timestamptz;
      v_leaf text;
      v_lo text;
      v_hi text;
    BEGIN
      PERFORM set_config('TimeZone', 'UTC', true);
      PERFORM set_config('relay.tenant_id', '00000000-0000-0000-0000-000000000000', true);
      PERFORM set_config('relay.environment', 'live', true);

      FOR p IN
        SELECT table_name, partition_interval, premake_horizon
        FROM relay.partition_policies
        ORDER BY table_name
      LOOP
        SELECT a.attname, a.atttypid = 'date'::regtype
          INTO v_column, v_is_date
        FROM pg_catalog.pg_partitioned_table pt
        JOIN pg_catalog.pg_attribute a ON a.attrelid = pt.partrelid AND a.attnum = pt.partattrs[0]
        WHERE pt.partrelid = format('relay.%I', p.table_name)::regclass;

        v_step := CASE p.partition_interval WHEN 'day' THEN interval '1 day' ELSE interval '1 month' END;
        v_from := date_trunc(p.partition_interval, now(), 'UTC');

        WHILE v_from < now() + p.premake_horizon LOOP
          v_to := v_from + v_step;
          v_leaf := p.table_name || '_p' ||
            to_char(v_from, CASE p.partition_interval WHEN 'day' THEN 'YYYYMMDD' ELSE 'YYYYMM' END);

          IF v_is_date THEN
            v_lo := to_char(v_from, 'YYYY-MM-DD');
            v_hi := to_char(v_to, 'YYYY-MM-DD');
          ELSE
            v_lo := to_char(v_from, 'YYYY-MM-DD"T"HH24:MI:SS"+00:00"');
            v_hi := to_char(v_to, 'YYYY-MM-DD"T"HH24:MI:SS"+00:00"');
          END IF;

          EXECUTE format('CREATE TABLE relay.%I (LIKE relay.%I INCLUDING ALL)', v_leaf, p.table_name);
          EXECUTE format('ALTER TABLE relay.%I ADD CONSTRAINT %I CHECK (%I >= %L AND %I < %L)',
            v_leaf, v_leaf || '_bounds', v_column, v_lo, v_column, v_hi);
          EXECUTE format('ALTER TABLE relay.%I ENABLE ROW LEVEL SECURITY', v_leaf);
          EXECUTE format('ALTER TABLE relay.%I FORCE ROW LEVEL SECURITY', v_leaf);
          EXECUTE format($f$CREATE POLICY %I ON relay.%I USING (tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)) WITH CHECK (tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment))$f$,
            v_leaf || '_scope', v_leaf);
          EXECUTE format('GRANT SELECT ON relay.%I TO relay_maint, relay_archive', v_leaf);

          IF p.table_name IN ('delivery_events', 'audit_log', 'usage_records') THEN
            EXECUTE format('CREATE TRIGGER %I BEFORE TRUNCATE ON relay.%I FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()',
              v_leaf || '_no_truncate', v_leaf);
          END IF;

          EXECUTE format('ALTER TABLE relay.%I ATTACH PARTITION relay.%I FOR VALUES FROM (%L) TO (%L)',
            p.table_name, v_leaf, v_lo, v_hi);

          v_from := v_to;
        END LOOP;
      END LOOP;
    END
    $$
    """)
  end
end
