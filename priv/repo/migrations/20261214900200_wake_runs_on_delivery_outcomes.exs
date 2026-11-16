defmodule Relay.Repo.Migrations.WakeRunsOnDeliveryOutcomes do
  use Ecto.Migration

  # WF-15
  # WF-21
  # WF-22
  # WF-43
  def up do
    execute(~S"""
    CREATE FUNCTION relay_private.workflow_run_outcome_wake() RETURNS trigger
      LANGUAGE plpgsql
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_at timestamptz := relay_private.business_now() + interval '5 seconds';
    BEGIN
      UPDATE relay.workflow_runs r SET state = 'waiting', wake_at = v_at, updated_at = now()
        WHERE r.tenant_id = NEW.tenant_id AND r.environment = NEW.environment
          AND r.notification_id = NEW.notification_id
          AND r.state IN ('running', 'waiting')
          AND (r.wake_at IS NULL OR r.wake_at > v_at)
          AND jsonb_path_exists(r.step_cursor, '$.routes.* ? (@.status == "running")');
      RETURN NULL;
    END
    $fn$
    """)

    execute("REVOKE ALL ON FUNCTION relay_private.workflow_run_outcome_wake() FROM PUBLIC")

    execute("""
    CREATE TRIGGER deliveries_wake_workflow_runs
      AFTER UPDATE OF delivery_rank, failure_kind, seen_at, read_at, clicked_at
      ON relay.deliveries
      FOR EACH ROW WHEN (OLD.delivery_rank IS DISTINCT FROM NEW.delivery_rank
        OR OLD.failure_kind IS DISTINCT FROM NEW.failure_kind
        OR OLD.seen_at IS DISTINCT FROM NEW.seen_at
        OR OLD.read_at IS DISTINCT FROM NEW.read_at
        OR OLD.clicked_at IS DISTINCT FROM NEW.clicked_at)
      EXECUTE FUNCTION relay_private.workflow_run_outcome_wake()
    """)
  end

  def down, do: :ok
end
