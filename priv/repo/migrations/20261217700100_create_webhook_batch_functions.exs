defmodule Relay.Repo.Migrations.CreateWebhookBatchFunctions do
  use Ecto.Migration

  @ts "timestamp with time zone"

  @functions [
    "relay_fn.webhook_batch_lock(uuid)",
    "relay_fn.webhook_batch_close(uuid, #{@ts})",
    "relay_fn.webhook_batch_add(uuid, uuid, uuid, #{@ts}, bigint, boolean, #{@ts})",
    "relay_fn.webhook_batch_claim(uuid, uuid, #{@ts}, #{@ts})",
    "relay_fn.webhook_batch_finish(uuid, text, text, bytea, #{@ts})"
  ]

  # WH-21
  # WH-52
  # WH-37
  # OP-8
  def up do
    Enum.each([lock(), close(), add(), claim(), finish()], &execute/1)

    for signature <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      execute("GRANT EXECUTE ON FUNCTION #{signature} TO relay_app")
      execute("ALTER FUNCTION #{signature} OWNER TO relay_owner")
    end
  end

  def down, do: :ok

  defp lock do
    ~S"""
    CREATE FUNCTION relay_fn.webhook_batch_lock(p_endpoint_id uuid)
      RETURNS SETOF relay.webhook_batches
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    BEGIN
      IF p_endpoint_id IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WH-21';
      END IF;
      PERFORM relay_private.lock_scope(ARRAY['webhook_batch', p_endpoint_id::text]);
      RETURN QUERY SELECT b.* FROM relay.webhook_batches b
        WHERE b.tenant_id = relay_private.ctx_tenant_id()
          AND b.environment = relay_private.ctx_environment()
          AND b.endpoint_id = p_endpoint_id AND b.state = 'open'
        FOR UPDATE;
    END
    $fn$
    """
  end

  defp close do
    ~S"""
    CREATE FUNCTION relay_fn.webhook_batch_close(p_batch_id uuid, p_now timestamptz)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_count bigint;
    BEGIN
      IF p_batch_id IS NULL OR p_now IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WH-21';
      END IF;
      UPDATE relay.webhook_batches b SET state = 'closed', closed_at = p_now, updated_at = p_now
        WHERE b.tenant_id = relay_private.ctx_tenant_id()
          AND b.environment = relay_private.ctx_environment()
          AND b.id = p_batch_id AND b.state = 'open';
      GET DIAGNOSTICS v_count = ROW_COUNT;
      RETURN CASE WHEN v_count = 1 THEN 'closed' ELSE 'unchanged' END;
    END
    $fn$
    """
  end

  defp add do
    ~S"""
    CREATE FUNCTION relay_fn.webhook_batch_add(p_message_id uuid, p_lock_token uuid,
      p_batch_id uuid, p_closes_at timestamptz, p_bytes bigint, p_close boolean,
      p_now timestamptz)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_row relay.webhook_messages;
      v_batch relay.webhook_batches;
      v_closes_at timestamptz;
    BEGIN
      IF p_message_id IS NULL OR p_lock_token IS NULL OR p_batch_id IS NULL
        OR p_closes_at IS NULL OR p_bytes IS NULL OR p_bytes < 1 OR p_close IS NULL
        OR p_now IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WH-21';
      END IF;
      SELECT * INTO v_row FROM relay.webhook_messages m
        WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = p_message_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      IF v_row.lock_token IS DISTINCT FROM p_lock_token THEN
        RETURN 'lock_lost';
      END IF;
      SELECT * INTO v_batch FROM relay.webhook_batches b
        WHERE b.tenant_id = v_tenant AND b.environment = v_env AND b.id = p_batch_id
        FOR UPDATE;
      IF NOT FOUND THEN
        PERFORM relay_private.assert_new_id(p_batch_id);
        INSERT INTO relay.webhook_batches (tenant_id, environment, id, endpoint_id, state,
          opened_at, closes_at, event_count, byte_count, attempt_count, created_at, updated_at)
        VALUES (v_tenant, v_env, p_batch_id, v_row.endpoint_id, 'open', p_now, p_closes_at, 0, 0,
          0, p_now, p_now);
        v_closes_at := p_closes_at;
      ELSIF v_batch.state <> 'open' OR v_batch.endpoint_id <> v_row.endpoint_id THEN
        RETURN 'batch_closed';
      ELSE
        v_closes_at := v_batch.closes_at;
      END IF;
      UPDATE relay.webhook_batches b SET event_count = b.event_count + 1,
          byte_count = b.byte_count + p_bytes,
          state = CASE WHEN p_close THEN 'closed' ELSE 'open' END,
          closed_at = CASE WHEN p_close THEN p_now END, updated_at = p_now
        WHERE b.tenant_id = v_tenant AND b.environment = v_env AND b.id = p_batch_id;
      UPDATE relay.webhook_messages m SET batch_id = p_batch_id,
          state = CASE WHEN m.attempt_count = 0 THEN 'pending' ELSE 'scheduled' END,
          hold_reason = NULL, next_attempt_at = v_closes_at, locked_until = NULL,
          lock_token = NULL, state_version = m.state_version + 1, updated_at = p_now
        WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = p_message_id;
      RETURN 'added';
    END
    $fn$
    """
  end

  defp claim do
    ~S"""
    CREATE FUNCTION relay_fn.webhook_batch_claim(p_batch_id uuid, p_lock_token uuid,
      p_locked_until timestamptz, p_now timestamptz)
      RETURNS TABLE (result text, message_id uuid)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_batch relay.webhook_batches;
      v_endpoint relay.webhook_endpoints;
    BEGIN
      IF p_batch_id IS NULL OR p_lock_token IS NULL OR p_locked_until IS NULL OR p_now IS NULL
        OR p_locked_until <= p_now THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WH-21';
      END IF;
      IF relay_private.tenant_status() <> 'active' THEN
        RETURN QUERY SELECT 'tenant_inactive'::text, NULL::uuid;
        RETURN;
      END IF;
      SELECT * INTO v_batch FROM relay.webhook_batches b
        WHERE b.tenant_id = v_tenant AND b.environment = v_env AND b.id = p_batch_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, NULL::uuid;
        RETURN;
      END IF;
      IF v_batch.state IN ('written', 'failed') THEN
        RETURN QUERY SELECT 'finished'::text, NULL::uuid;
        RETURN;
      END IF;
      IF v_batch.state = 'open' AND v_batch.closes_at > p_now THEN
        RETURN QUERY SELECT 'not_due'::text, NULL::uuid;
        RETURN;
      END IF;
      IF v_batch.state = 'open' THEN
        UPDATE relay.webhook_batches b SET state = 'closed', closed_at = p_now,
            updated_at = p_now
          WHERE b.tenant_id = v_tenant AND b.environment = v_env AND b.id = p_batch_id;
      END IF;
      IF EXISTS (SELECT 1 FROM relay.webhook_messages m
        WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.batch_id = p_batch_id
          AND m.state = 'in_flight' AND m.locked_until > p_now) THEN
        RETURN QUERY SELECT 'locked'::text, NULL::uuid;
        RETURN;
      END IF;
      SELECT * INTO v_endpoint FROM relay.webhook_endpoints e
        WHERE e.tenant_id = v_tenant AND e.environment = v_env AND e.id = v_batch.endpoint_id
        FOR SHARE;
      IF v_endpoint.state = 'archived' THEN
        UPDATE relay.webhook_messages m SET state = 'dead_lettered', hold_reason = NULL,
            reason = 'endpoint_archived', next_attempt_at = NULL, locked_until = NULL,
            lock_token = NULL, terminal_at = p_now, state_version = m.state_version + 1,
            updated_at = p_now
          WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.batch_id = p_batch_id
            AND m.terminal_at IS NULL AND m.state IN ('pending', 'scheduled', 'in_flight');
      ELSIF v_endpoint.state IN ('paused', 'disabled') THEN
        UPDATE relay.webhook_messages m SET state = 'held',
            hold_reason = 'endpoint_' || v_endpoint.state, next_attempt_at = NULL,
            locked_until = NULL, lock_token = NULL, state_version = m.state_version + 1,
            updated_at = p_now
          WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.batch_id = p_batch_id
            AND m.terminal_at IS NULL AND m.state IN ('pending', 'scheduled', 'in_flight');
      END IF;
      IF v_endpoint.state <> 'active' THEN
        UPDATE relay.webhook_batches b SET state = 'failed', updated_at = p_now
          WHERE b.tenant_id = v_tenant AND b.environment = v_env AND b.id = p_batch_id;
        RETURN QUERY SELECT ('endpoint_' || v_endpoint.state)::text, NULL::uuid;
        RETURN;
      END IF;
      RETURN QUERY
        UPDATE relay.webhook_messages m SET state = 'in_flight', hold_reason = NULL,
            next_attempt_at = NULL, locked_until = p_locked_until, lock_token = p_lock_token,
            state_version = m.state_version + 1, updated_at = p_now
          WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.batch_id = p_batch_id
            AND m.terminal_at IS NULL AND m.state IN ('pending', 'scheduled', 'in_flight')
          RETURNING 'claimed'::text, m.id;
      IF NOT FOUND THEN
        UPDATE relay.webhook_batches b SET state = 'failed', updated_at = p_now
          WHERE b.tenant_id = v_tenant AND b.environment = v_env AND b.id = p_batch_id;
        RETURN QUERY SELECT 'empty'::text, NULL::uuid;
        RETURN;
      END IF;
      UPDATE relay.webhook_batches b SET attempt_count = b.attempt_count + 1, updated_at = p_now
        WHERE b.tenant_id = v_tenant AND b.environment = v_env AND b.id = p_batch_id;
    END
    $fn$
    """
  end

  defp finish do
    ~S"""
    CREATE FUNCTION relay_fn.webhook_batch_finish(p_batch_id uuid, p_state text,
      p_object_key text, p_object_digest bytea, p_now timestamptz)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_count bigint;
    BEGIN
      IF p_batch_id IS NULL OR p_state IS NULL OR p_state NOT IN ('written', 'failed')
        OR p_now IS NULL
        OR (p_state = 'written' AND (p_object_key IS NULL OR p_object_digest IS NULL)) THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WH-21';
      END IF;
      UPDATE relay.webhook_batches b SET state = p_state, object_key = p_object_key,
          object_digest = p_object_digest,
          written_at = CASE WHEN p_state = 'written' THEN p_now END, updated_at = p_now
        WHERE b.tenant_id = relay_private.ctx_tenant_id()
          AND b.environment = relay_private.ctx_environment()
          AND b.id = p_batch_id AND b.state = 'closed';
      GET DIAGNOSTICS v_count = ROW_COUNT;
      RETURN CASE WHEN v_count = 1 THEN 'finished' ELSE 'not_found' END;
    END
    $fn$
    """
  end
end
