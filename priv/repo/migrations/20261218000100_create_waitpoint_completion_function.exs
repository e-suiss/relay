defmodule Relay.Repo.Migrations.CreateWaitpointCompletionFunction do
  use Ecto.Migration

  @signature "relay_fn.waitpoint_completion_record(uuid, uuid, text, bytea, uuid)"

  # WH-68
  # AG-11
  # OP-8
  def up do
    execute(record())
    execute("REVOKE ALL ON FUNCTION #{@signature} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@signature} TO relay_app")
    execute("ALTER FUNCTION #{@signature} OWNER TO relay_owner")
  end

  def down, do: :ok

  defp record do
    ~S"""
    CREATE FUNCTION relay_fn.waitpoint_completion_record(p_waitpoint_id uuid, p_receipt_id uuid,
      p_outcome text, p_result_ct bytea, p_result_key_id uuid)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_state text;
    BEGIN
      IF p_waitpoint_id IS NULL OR p_receipt_id IS NULL OR p_outcome IS NULL
        OR p_outcome NOT IN ('completed', 'failed')
        OR (p_result_ct IS NULL) <> (p_result_key_id IS NULL) THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WH-68';
      END IF;
      SELECT w.state INTO v_state FROM relay.waitpoints w
        WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_waitpoint_id
        FOR NO KEY UPDATE;
      IF NOT FOUND OR v_state <> 'resolved' THEN
        RETURN 'not_resolved';
      END IF;
      IF EXISTS (SELECT 1 FROM relay.waitpoint_completions c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env
          AND c.waitpoint_id = p_waitpoint_id) THEN
        RETURN 'exists';
      END IF;
      INSERT INTO relay.waitpoint_completions (tenant_id, environment, waitpoint_id, receipt_id,
        outcome, result_ct, result_key_id, created_at)
      VALUES (v_tenant, v_env, p_waitpoint_id, p_receipt_id, p_outcome, p_result_ct,
        p_result_key_id, now());
      RETURN 'recorded';
    END
    $fn$
    """
  end
end
