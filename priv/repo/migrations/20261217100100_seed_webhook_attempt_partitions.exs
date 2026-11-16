defmodule Relay.Repo.Migrations.SeedWebhookAttemptPartitions do
  use Ecto.Migration

  # WH-10
  # WH-30
  # OP-13
  # OP-14
  def up do
    execute("""
    INSERT INTO relay.partition_policies (table_name, partition_interval, premake_horizon,
      alarm_threshold, hot_retention, updated_at, updated_by_ref)
    VALUES ('webhook_attempts', 'month', interval '2 months', interval '3 days',
      interval '13 months', now(), 'migration')
    """)

    execute(~S"""
    DO $$
    DECLARE
      v_from timestamptz;
      v_result text;
    BEGIN
      v_from := date_trunc('month', now(), 'UTC');
      WHILE v_from < now() + interval '2 months' LOOP
        v_result := relay_private.partition_create('webhook_attempts', v_from,
          v_from + interval '1 month');
        IF v_result NOT IN ('created', 'exists') THEN
          RAISE EXCEPTION 'partition % of webhook_attempts not created: %', v_from, v_result;
        END IF;
        v_from := v_from + interval '1 month';
      END LOOP;
    END
    $$
    """)
  end

  def down, do: :ok
end
