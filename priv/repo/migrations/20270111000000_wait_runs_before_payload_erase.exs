defmodule Relay.Repo.Migrations.WaitRunsBeforePayloadErase do
  use Ecto.Migration

  # INV-22
  # INV-26
  # API-26
  # WF-59 (5)
  def up do
    execute("SET LOCAL ROLE relay_owner")
    execute(event_payload_erase())
    execute("RESET ROLE")
  end

  def down, do: :ok

  defp event_payload_erase do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_fn.event_payload_erase(p_event_id uuid, p_reason text)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_created timestamptz;
      v_erased timestamptz;
    BEGIN
      IF p_reason IS NULL OR p_reason NOT IN ('security_subtype', 'retention_none') THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'API-26';
      END IF;
      SELECT e.payload_created_at INTO v_created FROM relay.events e
        WHERE e.tenant_id = v_tenant AND e.environment = v_env AND e.id = p_event_id;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'API-26';
      END IF;
      SELECT p.erased_at INTO v_erased FROM relay.event_payloads p
        WHERE p.tenant_id = v_tenant AND p.environment = v_env AND p.event_id = p_event_id
          AND p.created_at = v_created
        FOR UPDATE;
      IF v_erased IS NOT NULL THEN
        RETURN 'already_erased';
      END IF;
      IF EXISTS (SELECT 1 FROM relay.notifications n
        JOIN relay.deliveries d ON d.tenant_id = n.tenant_id AND d.environment = n.environment
          AND d.notification_id = n.id
        WHERE n.tenant_id = v_tenant AND n.environment = v_env AND n.event_id = p_event_id
          AND d.delivery_rank = 0 AND d.failure_kind IS NULL) THEN
        RETURN 'not_terminal';
      END IF;
      IF EXISTS (SELECT 1 FROM relay.notifications n
        JOIN relay.workflow_runs r ON r.tenant_id = n.tenant_id
          AND r.environment = n.environment AND r.notification_id = n.id
        WHERE n.tenant_id = v_tenant AND n.environment = v_env AND n.event_id = p_event_id
          AND r.state IN ('running', 'waiting')) THEN
        RETURN 'not_terminal';
      END IF;
      UPDATE relay.event_payloads p SET data_ct = NULL, links_ct = NULL, overrides_ct = NULL,
          erased_at = now(), erase_reason = p_reason
        WHERE p.tenant_id = v_tenant AND p.environment = v_env AND p.event_id = p_event_id
          AND p.created_at = v_created;
      RETURN 'erased';
    END
    $fn$
    """
  end
end
