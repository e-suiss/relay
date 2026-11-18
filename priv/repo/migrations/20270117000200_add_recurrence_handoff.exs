defmodule Relay.Repo.Migrations.AddRecurrenceHandoff do
  use Ecto.Migration

  @handoff "relay_fn.recurrence_handoff(uuid, timestamptz, text)"

  # OP-97
  # OP-56
  # OP-57
  def up do
    execute("ALTER TABLE relay.recurrences ADD COLUMN handoff_at timestamptz")
    execute("ALTER TABLE relay.recurrences ADD COLUMN handoff_last_run_at timestamptz")
    execute("ALTER TABLE relay.recurrences ADD COLUMN handoff_cursor text")

    execute(
      "ALTER TABLE relay.recurrences ADD COLUMN handoff_dry_run boolean NOT NULL DEFAULT false"
    )

    execute(~S"""
    ALTER TABLE relay.recurrences ADD CONSTRAINT recurrences_handoff_cursor_check
      CHECK (char_length(handoff_cursor) BETWEEN 1 AND 1024) NOT VALID
    """)

    execute(~S"""
    ALTER TABLE relay.recurrences ADD CONSTRAINT recurrences_handoff_check
      CHECK (handoff_at IS NOT NULL OR (handoff_last_run_at IS NULL AND handoff_cursor IS NULL
        AND NOT handoff_dry_run)) NOT VALID
    """)

    execute(~S"""
    CREATE FUNCTION relay_fn.recurrence_handoff(p_id uuid, p_last_run_at timestamptz,
      p_cursor text)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_row relay.recurrences;
    BEGIN
      IF p_id IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-97';
      END IF;
      SELECT * INTO v_row FROM relay.recurrences r
        WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      IF v_row.state <> 'active' OR v_row.occurrence_count <> 0 OR v_row.handoff_at IS NOT NULL
        OR (p_last_run_at IS NOT NULL AND p_last_run_at >= v_row.next_at) THEN
        RETURN 'not_new';
      END IF;
      UPDATE relay.recurrences r SET handoff_at = relay_private.business_now(),
          handoff_last_run_at = p_last_run_at, handoff_cursor = p_cursor, handoff_dry_run = true,
          updated_at = now()
        WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_id;
      RETURN 'handed_over';
    END
    $fn$
    """)

    execute("REVOKE ALL ON FUNCTION #{@handoff} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@handoff} TO relay_app")
    execute("ALTER FUNCTION #{@handoff} OWNER TO relay_owner")
  end

  def down, do: :ok
end
