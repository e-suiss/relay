defmodule Relay.Repo.Migrations.CreateMailboxAgentLease do
  use Ecto.Migration

  @signature "relay_fn.mailbox_agent_lease(uuid, text, integer, bigint, bigint)"

  # C-68
  # AG-20
  # AG-22
  # AG-24
  # T-11
  # TN-8
  # OP-8
  def up do
    execute(agent_lease())
    execute("REVOKE ALL ON FUNCTION #{@signature} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@signature} TO relay_app")
    execute("ALTER FUNCTION #{@signature} OWNER TO relay_owner")
  end

  def down, do: :ok

  defp agent_lease do
    ~S"""
    CREATE FUNCTION relay_fn.mailbox_agent_lease(p_mailbox_id uuid, p_holder text, p_max integer,
      p_lease_ms bigint, p_max_deliveries bigint)
      RETURNS TABLE (id uuid, epoch bigint, seq bigint, kind text, event_type text,
        waitpoint_id uuid, payload_digest bytea, delivery_count bigint, lease_until timestamptz,
        created_at timestamptz)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_now timestamptz := relay_private.business_now();
      v_mailbox relay.mailboxes;
      v_row relay.mailbox_records;
      v_until timestamptz;
    BEGIN
      IF p_holder IS NULL OR char_length(p_holder) NOT BETWEEN 1 AND 128
        OR p_max IS NULL OR p_max NOT BETWEEN 1 AND 100
        OR p_lease_ms IS NULL OR p_lease_ms NOT BETWEEN 1000 AND 3600000
        OR p_max_deliveries IS NULL OR p_max_deliveries NOT BETWEEN 1 AND 1000 THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-22';
      END IF;
      SELECT * INTO v_mailbox FROM relay.mailboxes m
        WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = p_mailbox_id;
      IF NOT FOUND OR v_mailbox.state <> 'active' THEN
        RETURN;
      END IF;
      v_until := v_now + p_lease_ms * interval '1 millisecond';
      FOR v_row IN
        SELECT * FROM relay.mailbox_records r
        WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.mailbox_id = p_mailbox_id
          AND (r.delivery_state = 'available'
            OR (r.delivery_state = 'leased' AND r.lease_until < v_now))
        ORDER BY r.epoch, r.seq
        LIMIT p_max
        FOR NO KEY UPDATE SKIP LOCKED
      LOOP
        IF v_row.delivery_count + 1 > p_max_deliveries THEN
          UPDATE relay.mailbox_records r SET delivery_state = 'dead_lettered',
              dead_lettered_at = v_now, lease_holder = NULL, lease_until = NULL, updated_at = now()
            WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = v_row.id
              AND r.created_at = v_row.created_at;
          PERFORM relay_fn.outbox_append(uuidv7(), 'mailbox.record_dead_lettered',
            v_mailbox.stream_key,
            jsonb_build_object('mailbox_id', p_mailbox_id, 'record_id', v_row.id),
            v_row.traceparent);
        ELSE
          UPDATE relay.mailbox_records r SET delivery_state = 'leased', lease_holder = p_holder,
              lease_until = v_until, delivery_count = r.delivery_count + 1, updated_at = now()
            WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = v_row.id
              AND r.created_at = v_row.created_at;
          id := v_row.id;
          epoch := v_row.epoch;
          seq := v_row.seq;
          kind := v_row.kind;
          event_type := v_row.event_type;
          waitpoint_id := v_row.waitpoint_id;
          payload_digest := v_row.payload_digest;
          delivery_count := v_row.delivery_count + 1;
          lease_until := v_until;
          created_at := v_row.created_at;
          RETURN NEXT;
        END IF;
      END LOOP;
    END
    $fn$
    """
  end
end
