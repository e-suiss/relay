defmodule Relay.Repo.Migrations.CreateLimiterTables do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  # T-19
  # T-20
  # T-22
  # OP-74
  def up do
    execute(~S"""
    CREATE TABLE relay_queue.limiter_states (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      limit_key text NOT NULL,
      algorithm text NOT NULL,
      tat_us bigint,
      win_index bigint,
      cur_count bigint NOT NULL DEFAULT 0,
      prev_count bigint NOT NULL DEFAULT 0,
      log_us bigint[],
      buckets bigint[],
      expires_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      CONSTRAINT limiter_states_pkey PRIMARY KEY (tenant_id, environment, limit_key),
      CONSTRAINT limiter_states_limit_key_check
        CHECK (limit_key ~ '^[a-z][a-z0-9_.]{2,63}(:[0-9A-Za-z_.-]{1,128}){1,6}$'),
      CONSTRAINT limiter_states_algorithm_check
        CHECK (algorithm IN ('gcra', 'fixed_window', 'sliding_counter', 'sliding_log', 'bucket_ring')),
      CONSTRAINT limiter_states_tat_check CHECK ((algorithm = 'gcra') = (tat_us IS NOT NULL)),
      CONSTRAINT limiter_states_counts_check CHECK (cur_count >= 0 AND prev_count >= 0),
      CONSTRAINT limiter_states_log_check CHECK (cardinality(log_us) <= 1000),
      CONSTRAINT limiter_states_buckets_check
        CHECK ((algorithm = 'bucket_ring') = (buckets IS NOT NULL)),
      CONSTRAINT limiter_states_buckets_size_check
        CHECK (buckets IS NULL OR cardinality(buckets) = 120)
    )
    """)

    execute(~S"""
    CREATE TABLE relay_queue.concurrency_slots (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      counter_key text NOT NULL,
      slot_no bigint NOT NULL,
      holder text,
      lease_until timestamptz,
      expires_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      CONSTRAINT concurrency_slots_pkey PRIMARY KEY (tenant_id, environment, counter_key, slot_no),
      CONSTRAINT concurrency_slots_counter_key_check
        CHECK (counter_key ~ '^cc\.[a-z_]+(:[0-9A-Za-z_.-]{1,128})?$'),
      CONSTRAINT concurrency_slots_slot_no_check CHECK (slot_no >= 1),
      CONSTRAINT concurrency_slots_holder_check CHECK (char_length(holder) <= 128),
      CONSTRAINT concurrency_slots_lease_check CHECK ((holder IS NULL) = (lease_until IS NULL))
    )
    """)

    for table <- ~w(limiter_states concurrency_slots) do
      execute("CREATE INDEX #{table}_expires_at_idx ON relay_queue.#{table} (expires_at)")
      execute("ALTER TABLE relay_queue.#{table} ENABLE ROW LEVEL SECURITY")
      execute("ALTER TABLE relay_queue.#{table} FORCE ROW LEVEL SECURITY")

      execute(
        "CREATE POLICY #{table}_scope ON relay_queue.#{table} USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})"
      )

      execute("""
      CREATE POLICY #{table}_prune_read ON relay_queue.#{table} FOR SELECT TO relay_queue
        USING (expires_at < now() - interval '1 hour')
      """)

      execute("""
      CREATE POLICY #{table}_prune ON relay_queue.#{table} FOR DELETE TO relay_queue
        USING (expires_at < now() - interval '1 hour')
      """)

      execute("REVOKE ALL ON relay_queue.#{table} FROM PUBLIC")
      execute("GRANT SELECT, INSERT, UPDATE ON relay_queue.#{table} TO relay_owner")
      execute("GRANT SELECT, DELETE ON relay_queue.#{table} TO relay_queue")
    end
  end
end
