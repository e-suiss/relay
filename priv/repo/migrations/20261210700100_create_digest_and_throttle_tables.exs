defmodule Relay.Repo.Migrations.CreateDigestAndThrottleTables do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  @tables ~w(digest_windows digest_items throttle_counters throttle_hits)

  # WF-26
  # WF-27
  # WF-29
  # WF-32
  # INV-3
  # INV-12
  # INV-32
  # T-87
  def up do
    Enum.each(statements(), &execute/1)

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
      execute("GRANT SELECT ON relay.#{table} TO relay_app, relay_maint, relay_archive")
    end
  end

  def down, do: :ok

  defp statements do
    [
      ~S"""
      CREATE TABLE relay.digest_windows (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        recipient_id uuid NOT NULL,
        window_key relay.sha256 NOT NULL,
        generation bigint NOT NULL CONSTRAINT digest_windows_generation_check CHECK (generation >= 1),
        chain_start bigint CONSTRAINT digest_windows_chain_start_check CHECK (chain_start >= 1),
        origin text NOT NULL
          CONSTRAINT digest_windows_origin_check CHECK (origin IN ('step', 'density', 'quiet_hours')),
        window_mode text NOT NULL
          CONSTRAINT digest_windows_window_mode_check
            CHECK (window_mode IN ('fixed', 'sliding', 'scheduled')),
        leading_mode text NOT NULL
          CONSTRAINT digest_windows_leading_mode_check CHECK (leading_mode IN ('immediate', 'none')),
        debounce_ms bigint
          CONSTRAINT digest_windows_debounce_ms_check
            CHECK (debounce_ms BETWEEN 1 AND 2678400000),
        max_wait_ms bigint
          CONSTRAINT digest_windows_max_wait_ms_check
            CHECK (max_wait_ms BETWEEN 1 AND 2678400000),
        schedule_rule text
          CONSTRAINT digest_windows_schedule_rule_check CHECK (char_length(schedule_rule) <= 256),
        time_zone text
          CONSTRAINT digest_windows_time_zone_check CHECK (char_length(time_zone) <= 64),
        release_at timestamptz,
        max_items bigint
          CONSTRAINT digest_windows_max_items_check CHECK (max_items BETWEEN 2 AND 1000),
        state text NOT NULL
          CONSTRAINT digest_windows_state_check
            CHECK (state IN ('open', 'fired', 'empty', 'cancelled')),
        item_count bigint NOT NULL CONSTRAINT digest_windows_item_count_check CHECK (item_count >= 0),
        cumulative_count bigint
          CONSTRAINT digest_windows_cumulative_count_check CHECK (cumulative_count >= 0),
        first_at timestamptz NOT NULL,
        last_at timestamptz NOT NULL,
        deadline_at timestamptz NOT NULL,
        fire_at timestamptz,
        timer_at timestamptz,
        closed_at timestamptz,
        close_reason text
          CONSTRAINT digest_windows_close_reason_check
            CHECK (close_reason IN ('due', 'max_items', 'read', 'deadline')),
        read_at timestamptz,
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT digest_windows_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT digest_windows_id_recipient_id_key UNIQUE (tenant_id, environment, id, recipient_id),
        CONSTRAINT digest_windows_generation_key
          UNIQUE (tenant_id, environment, recipient_id, window_key, generation),
        CONSTRAINT digest_windows_times_check
          CHECK (last_at >= first_at AND deadline_at > first_at
            AND deadline_at <= first_at + interval '31 days'
            AND (fire_at IS NULL OR fire_at <= deadline_at)),
        CONSTRAINT digest_windows_closed_check
          CHECK ((state = 'open') = (closed_at IS NULL)
            AND (state = 'open') = (close_reason IS NULL)
            AND (state = 'fired') = (cumulative_count IS NOT NULL)
            AND (state = 'fired') = (chain_start IS NOT NULL)),
        CONSTRAINT digest_windows_mode_check
          CHECK ((window_mode = 'scheduled') = (schedule_rule IS NOT NULL)
            AND (window_mode <> 'scheduled' OR time_zone IS NOT NULL)
            AND (window_mode <> 'sliding' OR (debounce_ms IS NOT NULL AND max_wait_ms IS NOT NULL))
            AND (window_mode <> 'fixed' OR max_wait_ms IS NOT NULL OR release_at IS NOT NULL)),
        CONSTRAINT digest_windows_recipient_id_fkey FOREIGN KEY (tenant_id, environment, recipient_id)
          REFERENCES relay.recipients (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE UNIQUE INDEX digest_windows_open_key ON relay.digest_windows
        (tenant_id, environment, recipient_id, window_key) WHERE state = 'open'
      """,
      """
      CREATE INDEX digest_windows_due_index ON relay.digest_windows
        (tenant_id, environment, fire_at) WHERE state = 'open'
      """,
      ~S"""
      CREATE TABLE relay.digest_items (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        window_id uuid NOT NULL,
        recipient_id uuid NOT NULL,
        notification_id uuid NOT NULL,
        delivery_id uuid,
        seq bigint NOT NULL CONSTRAINT digest_items_seq_check CHECK (seq >= 1),
        sent_alone boolean NOT NULL,
        actor_digest relay.sha256,
        occurred_at timestamptz NOT NULL,
        created_at timestamptz NOT NULL,
        CONSTRAINT digest_items_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT digest_items_seq_key UNIQUE (tenant_id, environment, window_id, seq),
        CONSTRAINT digest_items_notification_key
          UNIQUE (tenant_id, environment, window_id, notification_id),
        CONSTRAINT digest_items_window_id_fkey
          FOREIGN KEY (tenant_id, environment, window_id, recipient_id)
          REFERENCES relay.digest_windows (tenant_id, environment, id, recipient_id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT digest_items_notification_id_fkey
          FOREIGN KEY (tenant_id, environment, notification_id, recipient_id)
          REFERENCES relay.notifications (tenant_id, environment, id, recipient_id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT digest_items_delivery_id_fkey FOREIGN KEY (tenant_id, environment, delivery_id)
          REFERENCES relay.deliveries (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE INDEX digest_items_notification_index ON relay.digest_items
        (tenant_id, environment, notification_id)
      """,
      ~S"""
      CREATE TABLE relay.throttle_counters (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        key_digest relay.sha256 NOT NULL,
        window_start timestamptz NOT NULL,
        window_end timestamptz NOT NULL,
        hit_count bigint NOT NULL CONSTRAINT throttle_counters_hit_count_check CHECK (hit_count >= 0),
        limited_count bigint NOT NULL
          CONSTRAINT throttle_counters_limited_count_check CHECK (limited_count >= 0),
        reset_count bigint NOT NULL
          CONSTRAINT throttle_counters_reset_count_check CHECK (reset_count >= 0),
        last_reset_at timestamptz,
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT throttle_counters_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT throttle_counters_window_key UNIQUE (tenant_id, environment, key_digest, window_start),
        CONSTRAINT throttle_counters_window_check
          CHECK (window_end > window_start AND window_end <= window_start + interval '31 days'),
        CONSTRAINT throttle_counters_reset_check CHECK ((reset_count = 0) = (last_reset_at IS NULL))
      )
      """,
      """
      CREATE INDEX throttle_counters_active_index ON relay.throttle_counters
        (tenant_id, environment, key_digest, window_end)
      """,
      ~S"""
      CREATE TABLE relay.throttle_hits (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        key_digest relay.sha256 NOT NULL,
        hit_key relay.sha256 NOT NULL,
        counter_id uuid NOT NULL,
        outcome text NOT NULL
          CONSTRAINT throttle_hits_outcome_check CHECK (outcome IN ('allowed', 'limited')),
        hit_limit bigint NOT NULL
          CONSTRAINT throttle_hits_hit_limit_check CHECK (hit_limit BETWEEN 1 AND 10000),
        created_at timestamptz NOT NULL,
        CONSTRAINT throttle_hits_pkey PRIMARY KEY (tenant_id, environment, key_digest, hit_key),
        CONSTRAINT throttle_hits_counter_id_fkey FOREIGN KEY (tenant_id, environment, counter_id)
          REFERENCES relay.throttle_counters (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE INDEX throttle_hits_counter_index ON relay.throttle_hits
        (tenant_id, environment, counter_id)
      """
    ]
  end
end
