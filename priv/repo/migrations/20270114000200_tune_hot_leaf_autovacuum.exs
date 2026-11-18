defmodule Relay.Repo.Migrations.TuneHotLeafAutovacuum do
  use Ecto.Migration

  @options "autovacuum_vacuum_scale_factor = 0.01, autovacuum_vacuum_threshold = 1000, autovacuum_analyze_scale_factor = 0.02, autovacuum_vacuum_cost_limit = 2000"
  @ledger ~w(delivery_events delivery_attempts outbox_events webhook_attempts)

  # OP-81
  # OP-31
  # OP-14
  def up do
    execute("SET LOCAL lock_timeout = '10s'")
    execute("ALTER TABLE relay_queue.oban_jobs SET (#{@options})")

    execute("""
    DO $$
    DECLARE
      v_leaf regclass;
    BEGIN
      FOR v_leaf IN
        SELECT i.inhrelid::regclass
        FROM pg_inherits i
        JOIN pg_class p ON p.oid = i.inhparent
        JOIN pg_namespace n ON n.oid = p.relnamespace
        WHERE n.nspname = 'relay' AND p.relname = ANY (ARRAY['#{Enum.join(@ledger, "', '")}'])
      LOOP
        EXECUTE format('ALTER TABLE %s SET (#{@options})', v_leaf);
      END LOOP;
    END
    $$
    """)
  end

  def down, do: :ok
end
