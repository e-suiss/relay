defmodule Relay.Repo.Migrations.EraseSubjectWaitpointsAndMailbox do
  use Ecto.Migration

  # OP-24
  # C-86
  # TN-16 (7)
  # AG-5
  def up do
    execute("SET LOCAL ROLE relay_owner")
    execute(function(true))
    execute("RESET ROLE")
  end

  def down do
    execute("SET LOCAL ROLE relay_owner")
    execute(function(false))
    execute("RESET ROLE")
  end

  defp function(stage_two?) do
    """
    CREATE OR REPLACE FUNCTION relay_fn.subject_erase(p_recipient_id uuid, p_request_ref text,
      p_destroy_classes text[], p_restrict_classes text[], p_record_digest bytea,
      p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
      RETURNS TABLE (result text, cancelled_deliveries bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_state text;
      v_delivery relay.deliveries;
      v_count bigint := 0;
      v_destroy text[] := COALESCE(p_destroy_classes, ARRAY[]::text[]);
      v_restrict text[] := COALESCE(p_restrict_classes, ARRAY[]::text[]);
    #{if stage_two?, do: "  v_waitpoint relay.waitpoints;\n    v_now timestamptz := relay_private.business_now();", else: ""}
    BEGIN
      IF p_request_ref IS NULL OR v_destroy && v_restrict THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-18';
      END IF;
      SELECT r.state INTO v_state FROM relay.recipients r
        WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_recipient_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, 0::bigint;
        RETURN;
      END IF;
      IF v_state = 'deleted' THEN
        RETURN QUERY SELECT 'already_erased'::text, 0::bigint;
        RETURN;
      END IF;
      IF EXISTS (SELECT 1 FROM relay.legal_holds h
        WHERE h.tenant_id = v_tenant AND h.environment = v_env AND h.state = 'active'
          AND (h.scope = 'tenant' OR h.recipient_id = p_recipient_id)) THEN
        RETURN QUERY SELECT 'held'::text, 0::bigint;
        RETURN;
      END IF;
      UPDATE relay.subject_keys k SET wrapped_dek = NULL, state = 'destroyed',
          destroyed_at = now(), destroy_reason = 'erasure'
        WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.recipient_id = p_recipient_id
          AND k.retention_class = ANY (v_destroy) AND k.state <> 'destroyed';
      UPDATE relay.subject_keys k SET state = 'restricted', restricted_at = now()
        WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.recipient_id = p_recipient_id
          AND k.retention_class = ANY (v_restrict) AND k.state = 'active';
      UPDATE relay.recipients r SET state = 'deleted', deleted_at = now(),
          deleted_reason = 'erasure', external_id_bidx = NULL, external_id_bidx_key_id = NULL,
          external_id_bidx_next = NULL, updated_at = now()
        WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_recipient_id;
      FOR v_delivery IN
        SELECT * FROM relay.deliveries d
        WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.recipient_id = p_recipient_id
          AND d.delivery_rank = 0 AND d.failure_kind IS NULL
        ORDER BY d.created_at, d.id
        FOR UPDATE
      LOOP
        PERFORM relay_private.ledger_record(uuidv7(), v_delivery, NULL, 'relay',
          'delivery.cancelled', NULL, NULL, NULL, now(), NULL, NULL, 'cancelled', NULL,
          'subject_erasure', NULL, NULL, NULL, v_delivery.traceparent);
        v_count := v_count + 1;
      END LOOP;
    #{if stage_two?, do: stage_two(), else: ""}
      INSERT INTO relay.erasure_log (tenant_id, environment, id, recipient_id, request_ref,
        destroyed_classes, restricted_classes, cancelled_deliveries, backup_copies_expire_at,
        created_at)
      VALUES (v_tenant, v_env, uuidv7(), p_recipient_id, p_request_ref, v_destroy, v_restrict,
        v_count, now() + interval '35 days', now());
      PERFORM relay_private.audit_write(v_tenant, v_env, 'subject.erased', p_actor_kind,
        p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'recipient', p_recipient_id::text,
        NULL, p_record_digest);
      RETURN QUERY SELECT 'erased'::text, v_count;
    END
    $fn$
    """
  end

  defp stage_two do
    """
      FOR v_waitpoint IN
        SELECT * FROM relay.waitpoints w
        WHERE w.tenant_id = v_tenant AND w.environment = v_env
          AND ((w.waiter_kind = 'agent' AND w.waiter_ref = p_recipient_id)
            OR EXISTS (SELECT 1 FROM relay.waitpoint_responders s
              WHERE s.tenant_id = w.tenant_id AND s.environment = w.environment
                AND s.waitpoint_id = w.id AND s.recipient_id = p_recipient_id))
        ORDER BY w.id
        FOR UPDATE
      LOOP
        UPDATE relay.waitpoints w SET content_ct = NULL, claim_text_ct = NULL,
            default_response_ct = NULL, field_key_id = NULL,
            fields_erased_at = COALESCE(w.fields_erased_at, now()),
            state = CASE WHEN w.state IN ('open', 'stalled') THEN 'cancelled' ELSE w.state END,
            cancelled_at = CASE WHEN w.state IN ('open', 'stalled') THEN v_now ELSE w.cancelled_at END,
            cancel_reason = CASE WHEN w.state IN ('open', 'stalled') THEN 'subject_erasure'
              ELSE w.cancel_reason END,
            stalled_at = CASE WHEN w.state IN ('open', 'stalled') THEN NULL ELSE w.stalled_at END,
            state_changed_at = CASE WHEN w.state IN ('open', 'stalled') THEN v_now
              ELSE w.state_changed_at END,
            version = CASE WHEN w.state IN ('open', 'stalled') THEN w.version + 1 ELSE w.version END,
            updated_at = now()
          WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = v_waitpoint.id;
        IF v_waitpoint.state IN ('open', 'stalled') THEN
          SELECT * INTO v_waitpoint FROM relay.waitpoints w
            WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = v_waitpoint.id;
          PERFORM relay_private.waitpoint_release(v_waitpoint);
          PERFORM relay_private.waitpoint_emit(v_waitpoint, 'waitpoint.cancelled', NULL, NULL, NULL,
            NULL);
        END IF;
      END LOOP;
      UPDATE relay.mailboxes m SET state = 'deleted', deleted_at = now(), deleted_reason = 'erasure',
          updated_at = now()
        WHERE m.tenant_id = v_tenant AND m.environment = v_env
          AND m.owner_kind IN ('subscriber', 'agent') AND m.owner_ref = p_recipient_id
          AND m.state <> 'deleted';
    """
  end
end
