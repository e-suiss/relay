defmodule Relay.Repo.Migrations.AddNextBreakTiming do
  use Ecto.Migration

  @event_timing_set "relay_fn.event_timing_set(uuid, text, timestamp with time zone)"
  @delivery_break_release "relay_fn.delivery_break_release(uuid)"
  @recipient_break_release "relay_fn.recipient_break_release(uuid, integer)"

  # WF-56
  # WF-57
  # WF-43
  # IN-48
  # OP-57
  def up do
    execute("ALTER TABLE relay.events ADD COLUMN timing text")
    execute("ALTER TABLE relay.events ADD COLUMN max_defer_until timestamptz")
    execute("ALTER TABLE relay.deliveries ADD COLUMN timing_released_at timestamptz")

    execute("""
    ALTER TABLE relay.events ADD CONSTRAINT events_timing_check
      CHECK (timing IN ('next_break')) NOT VALID
    """)

    execute("""
    ALTER TABLE relay.events ADD CONSTRAINT events_max_defer_until_check
      CHECK ((timing IS NULL) = (max_defer_until IS NULL)) NOT VALID
    """)

    execute(~S"""
    CREATE FUNCTION relay_fn.event_timing_set(p_event_id uuid, p_timing text,
      p_max_defer_until timestamptz)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_event relay.events;
    BEGIN
      IF p_event_id IS NULL OR p_timing IS NULL OR p_timing <> 'next_break'
        OR p_max_defer_until IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-56';
      END IF;
      SELECT * INTO v_event FROM relay.events e
        WHERE e.tenant_id = v_tenant AND e.environment = v_env AND e.id = p_event_id;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      IF v_event.timing IS NOT DISTINCT FROM p_timing
        AND v_event.max_defer_until IS NOT DISTINCT FROM p_max_defer_until THEN
        RETURN 'unchanged';
      END IF;
      UPDATE relay.events e SET timing = p_timing, max_defer_until = p_max_defer_until
        WHERE e.tenant_id = v_tenant AND e.environment = v_env AND e.id = p_event_id;
      RETURN 'set';
    END
    $fn$
    """)

    execute(~S"""
    CREATE FUNCTION relay_fn.delivery_break_release(p_delivery_id uuid)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_released timestamptz;
    BEGIN
      IF p_delivery_id IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-56';
      END IF;
      SELECT d.timing_released_at INTO v_released FROM relay.deliveries d
        WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_delivery_id;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      IF v_released IS NOT NULL THEN
        RETURN 'unchanged';
      END IF;
      UPDATE relay.deliveries d SET timing_released_at = now(), updated_at = now()
        WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_delivery_id;
      RETURN 'released';
    END
    $fn$
    """)

    execute(~S"""
    CREATE FUNCTION relay_fn.recipient_break_release(p_recipient_id uuid, p_limit integer)
      RETURNS TABLE(delivery_id uuid)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
    BEGIN
      IF p_recipient_id IS NULL OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 1000 THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-56';
      END IF;
      RETURN QUERY
        WITH waiting AS (
          SELECT d.id FROM relay.deliveries d
          WHERE d.tenant_id = v_tenant AND d.environment = v_env
            AND d.recipient_id = p_recipient_id AND d.decision = 'defer'
            AND d.decision_rule_id = 'next_break.deferred' AND d.timing_released_at IS NULL
            AND d.failure_kind IS NULL AND d.delivery_rank = 0 AND d.paused_at IS NULL
          ORDER BY d.deferred_until, d.id
          LIMIT p_limit
        )
        UPDATE relay.deliveries d SET timing_released_at = now(), updated_at = now()
        FROM waiting w
        WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = w.id
        RETURNING d.id;
    END
    $fn$
    """)

    for signature <- [@event_timing_set, @delivery_break_release, @recipient_break_release] do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      execute("GRANT EXECUTE ON FUNCTION #{signature} TO relay_app")
      execute("ALTER FUNCTION #{signature} OWNER TO relay_owner")
    end
  end

  def down, do: :ok
end
