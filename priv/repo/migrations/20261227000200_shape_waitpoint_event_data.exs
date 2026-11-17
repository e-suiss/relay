defmodule Relay.Repo.Migrations.ShapeWaitpointEventData do
  use Ecto.Migration

  # AG-16
  # AG-7
  # API-3
  # INV-12
  def up do
    execute(~S"""
    CREATE OR REPLACE FUNCTION relay_private.waitpoint_emit(p_waitpoint relay.waitpoints,
      p_event_type text, p_record_id uuid, p_source_event_id uuid, p_payload_ct bytea,
      p_payload_key_id uuid)
      RETURNS bigint
    LANGUAGE plpgsql VOLATILE
    SET search_path = pg_catalog, pg_temp
    AS $fn$
    DECLARE
      v_seq bigint;
      v_data jsonb := jsonb_build_object('waitpoint_id', p_waitpoint.id, 'kind', p_waitpoint.kind);
      v_response relay.waitpoint_responses;
      v_reader uuid;
      v_mailbox uuid;
    BEGIN
      SELECT a.seq INTO v_seq
        FROM relay_fn.mailbox_append(COALESCE(p_record_id, uuidv7()), p_waitpoint.waiter_mailbox_id,
          'waitpoint_event', p_event_type, NULL, p_waitpoint.id, p_source_event_id,
          CASE WHEN p_payload_key_id IS NOT NULL THEN p_payload_ct END, NULL,
          CASE WHEN p_payload_ct IS NOT NULL THEN p_payload_key_id END,
          sha256(convert_to(jsonb_build_object('waitpoint_id', p_waitpoint.id, 'event_type',
            p_event_type, 'state', p_waitpoint.state)::text, 'UTF8')),
          p_waitpoint.traceparent) a;
      IF p_event_type = 'waitpoint.cancelled' AND p_waitpoint.cancel_reason IS NOT NULL THEN
        v_data := v_data || jsonb_build_object('reason', p_waitpoint.cancel_reason);
      ELSIF p_event_type = 'waitpoint.resolved'
        AND p_waitpoint.resolution_response_id IS NOT NULL THEN
        SELECT * INTO v_response FROM relay.waitpoint_responses r
          WHERE r.tenant_id = p_waitpoint.tenant_id AND r.environment = p_waitpoint.environment
            AND r.id = p_waitpoint.resolution_response_id;
        IF FOUND THEN
          v_data := v_data || jsonb_build_object('response_id', v_response.id,
            'evidence_level', v_response.evidence_level,
            'subject_digest', 'sha256:' || encode(v_response.subject_digest, 'hex'),
            'response_digest', 'sha256:' || encode(v_response.value_digest, 'hex'));
        END IF;
      END IF;
      PERFORM relay_fn.outbox_append(uuidv7(), p_event_type,
        'waitpoint:' || p_waitpoint.id::text, v_data, p_waitpoint.traceparent);
      IF cardinality(p_waitpoint.deliver_to_topics) > 0
        AND p_event_type IN ('waitpoint.resolved', 'waitpoint.expired', 'waitpoint.cancelled') THEN
        FOR v_reader IN
          SELECT DISTINCT s.recipient_id
          FROM relay.topics t
          LEFT JOIN relay.topics p ON p.tenant_id = t.tenant_id AND p.environment = t.environment
            AND p.id = t.parent_id AND p.state = 'active'
          JOIN relay.topic_subscriptions s ON s.tenant_id = t.tenant_id
            AND s.environment = t.environment AND s.topic_id IN (t.id, p.id) AND s.state = 'active'
          JOIN relay.recipients r ON r.tenant_id = s.tenant_id AND r.environment = s.environment
            AND r.id = s.recipient_id AND r.kind = 'agent' AND r.state = 'active'
          WHERE t.tenant_id = p_waitpoint.tenant_id AND t.environment = p_waitpoint.environment
            AND t.key = ANY (p_waitpoint.deliver_to_topics) AND t.state = 'active'
            AND (p_waitpoint.waiter_kind <> 'agent' OR s.recipient_id <> p_waitpoint.waiter_ref)
          ORDER BY s.recipient_id
        LOOP
          v_mailbox := NULL;
          SELECT e.mailbox_id INTO v_mailbox
            FROM relay_fn.mailbox_ensure(uuidv7(), 'agent', v_reader) e
            WHERE e.result IN ('created', 'exists');
          IF v_mailbox IS NOT NULL THEN
            PERFORM relay_fn.mailbox_append(uuidv7(), v_mailbox, 'waitpoint_event', p_event_type,
              NULL, p_waitpoint.id, p_source_event_id, NULL, NULL, NULL,
              sha256(convert_to(jsonb_build_object('waitpoint_id', p_waitpoint.id, 'event_type',
                p_event_type, 'state', p_waitpoint.state)::text, 'UTF8')),
              p_waitpoint.traceparent);
          END IF;
        END LOOP;
      END IF;
      RETURN v_seq;
    END
    $fn$
    """)
  end

  def down, do: :ok
end
