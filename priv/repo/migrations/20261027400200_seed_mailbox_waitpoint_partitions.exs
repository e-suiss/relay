defmodule Relay.Repo.Migrations.SeedMailboxWaitpointPartitions do
  use Ecto.Migration

  @tables ~w(mailbox_records waitpoint_response_rejections waitpoint_unmatched_events)

  # OP-13
  # OP-14
  # OP-66
  def up do
    for table <- @tables do
      execute("""
      INSERT INTO relay.partition_policies (table_name, partition_interval, premake_horizon,
        alarm_threshold, hot_retention, updated_at, updated_by_ref)
      VALUES ('#{table}', 'month', interval '2 months', interval '3 days', interval '13 months',
        now(), 'migration')
      """)
    end

    execute(~S"""
    DO $$
    DECLARE
      v_table text;
      v_from timestamptz;
      v_result text;
    BEGIN
      FOREACH v_table IN ARRAY ARRAY['mailbox_records', 'waitpoint_response_rejections',
        'waitpoint_unmatched_events']
      LOOP
        v_from := date_trunc('month', now(), 'UTC');
        WHILE v_from < now() + interval '2 months' LOOP
          v_result := relay_private.partition_create(v_table, v_from, v_from + interval '1 month');
          IF v_result NOT IN ('created', 'exists') THEN
            RAISE EXCEPTION 'partition % of % not created: %', v_from, v_table, v_result;
          END IF;
          v_from := v_from + interval '1 month';
        END LOOP;
      END LOOP;
    END
    $$
    """)
  end
end
