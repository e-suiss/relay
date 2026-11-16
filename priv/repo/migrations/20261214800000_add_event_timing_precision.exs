defmodule Relay.Repo.Migrations.AddEventTimingPrecision do
  use Ecto.Migration

  @function "relay_fn.event_timing_precision_set(uuid, text)"

  # WF-42
  # WF-58
  # OP-57
  def up do
    execute("ALTER TABLE relay.events ADD COLUMN timing_precision text")

    execute("""
    ALTER TABLE relay.events ADD CONSTRAINT events_timing_precision_check
      CHECK (timing_precision IN ('strict')) NOT VALID
    """)

    execute(~S"""
    CREATE FUNCTION relay_fn.event_timing_precision_set(p_event_id uuid, p_timing_precision text)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_current text;
    BEGIN
      IF p_event_id IS NULL OR p_timing_precision IS NULL OR p_timing_precision <> 'strict' THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-58';
      END IF;
      SELECT e.timing_precision INTO v_current FROM relay.events e
        WHERE e.tenant_id = v_tenant AND e.environment = v_env AND e.id = p_event_id;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      IF v_current IS NOT DISTINCT FROM p_timing_precision THEN
        RETURN 'unchanged';
      END IF;
      UPDATE relay.events e SET timing_precision = p_timing_precision
        WHERE e.tenant_id = v_tenant AND e.environment = v_env AND e.id = p_event_id;
      RETURN 'set';
    END
    $fn$
    """)

    execute("REVOKE ALL ON FUNCTION #{@function} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@function} TO relay_app")
    execute("ALTER FUNCTION #{@function} OWNER TO relay_owner")
  end

  def down, do: :ok
end
