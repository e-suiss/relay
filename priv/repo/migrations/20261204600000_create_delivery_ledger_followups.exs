defmodule Relay.Repo.Migrations.CreateDeliveryLedgerFollowups do
  use Ecto.Migration

  @backfill "relay_fn.delivery_failure_actor_backfill(uuid, integer)"

  # DS-2
  # DS-4 (3)
  # DS-20
  # DS-44
  # OP-3
  def up do
    execute(projection_reduce())
    execute(ledger_record())
    execute(backfill())
    execute("REVOKE ALL ON FUNCTION #{@backfill} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@backfill} TO relay_app")
    execute("ALTER FUNCTION #{@backfill} OWNER TO relay_owner")
  end

  def down, do: :ok

  defp projection_reduce do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_private.projection_reduce(p_state relay_private.delivery_projection,
      p_actor text, p_event_type text, p_attempt_no bigint, p_provider_seq bigint,
      p_occurred_at timestamptz, p_received_at timestamptz, p_effect jsonb,
      p_other_attempt_delivered boolean)
      RETURNS relay_private.delivery_projection
    LANGUAGE plpgsql IMMUTABLE
    SET search_path = pg_catalog, pg_temp
    AS $fn$
    DECLARE
      s relay_private.delivery_projection := p_state;
      v_effect jsonb := COALESCE(p_effect, '{}'::jsonb);
      v_rank smallint := (v_effect ->> 'delivery_rank')::smallint;
      v_kind text := v_effect ->> 'failure_kind';
      v_after text := v_effect ->> 'after_delivered';
      v_engagement jsonb := v_effect -> 'engagement';
      v_source text := CASE WHEN p_actor IN ('provider_webhook', 'provider_api') THEN p_actor END;
      v_changed boolean := false;
      v_conflict boolean := false;
      v_newer boolean;
      v_stage smallint;
      v_by text;
    BEGIN
      IF v_effect ->> 'retention_ended' = 'true' THEN
        s.late_event_count := s.late_event_count + 1;
        s.last_event_at := GREATEST(s.last_event_at, p_received_at);
        s.result := 'stale_ignored';
        RETURN s;
      END IF;
      IF p_event_type = 'delivery.replay_opened' AND s.failure_kind IS NOT NULL THEN
        s.failure_kind := NULL;
        s.failure_class := NULL;
        s.failure_rule_id := NULL;
        s.failure_reason := NULL;
        s.failure_attempt_no := NULL;
        s.failure_provider_seq := NULL;
        s.failure_occurred_at := NULL;
        s.failure_received_at := NULL;
        s.failure_actor := NULL;
        v_changed := true;
      END IF;
      IF p_event_type IN ('delivery.queued', 'delivery.deferred') AND s.projection_version = 0 THEN
        v_changed := true;
      END IF;
      IF v_rank IS NOT NULL THEN
        IF v_rank > s.delivery_rank THEN
          s.delivery_rank := v_rank;
          IF s.accepted_at IS NULL THEN
            s.accepted_at := p_occurred_at;
          END IF;
          IF v_rank = 2 THEN
            s.delivered_at := p_occurred_at;
            IF s.failure_kind IN ('failed', 'bounced')
              AND s.failure_attempt_no IS NOT DISTINCT FROM p_attempt_no THEN
              s.failure_kind := NULL;
              s.failure_class := NULL;
              s.failure_rule_id := NULL;
              s.failure_reason := NULL;
              s.failure_attempt_no := NULL;
              s.failure_provider_seq := NULL;
              s.failure_occurred_at := NULL;
              s.failure_received_at := NULL;
              s.failure_actor := NULL;
            END IF;
          END IF;
          v_changed := true;
        ELSE
          s.late_event_count := s.late_event_count + 1;
        END IF;
        IF v_rank = 2 AND COALESCE(p_other_attempt_delivered, false)
          AND NOT s.duplicate_delivered THEN
          s.duplicate_delivered := true;
          v_changed := true;
        END IF;
      END IF;
      IF v_kind IS NOT NULL THEN
        IF s.failure_kind IS NULL THEN
          v_newer := true;
        ELSIF s.failure_kind = v_kind
          AND COALESCE(p_attempt_no, 0) = COALESCE(s.failure_attempt_no, 0) THEN
          v_newer := (COALESCE(p_provider_seq, -1), p_occurred_at,
              CASE v_source WHEN 'provider_webhook' THEN 2 WHEN 'provider_api' THEN 1 ELSE 0 END,
              p_received_at)
            > (COALESCE(s.failure_provider_seq, -1), s.failure_occurred_at,
              CASE s.failure_actor WHEN 'provider_webhook' THEN 2 WHEN 'provider_api' THEN 1
                ELSE 0 END,
              s.failure_received_at);
        ELSE
          v_newer := (COALESCE(p_attempt_no, 0), COALESCE(p_provider_seq, -1), p_occurred_at,
              p_received_at)
            > (COALESCE(s.failure_attempt_no, 0), COALESCE(s.failure_provider_seq, -1),
              s.failure_occurred_at, s.failure_received_at);
        END IF;
        IF v_newer THEN
          IF s.delivery_rank = 2 AND COALESCE(v_after, 'stale') <> 'valid' THEN
            IF v_after = 'conflict' AND NOT s.has_conflict THEN
              s.has_conflict := true;
              v_conflict := true;
            END IF;
          ELSE
            s.failure_kind := v_kind;
            s.failure_class := v_effect ->> 'failure_class';
            s.failure_rule_id := v_effect ->> 'failure_rule_id';
            s.failure_reason := v_effect ->> 'failure_reason';
            s.failure_attempt_no := p_attempt_no;
            s.failure_provider_seq := p_provider_seq;
            s.failure_occurred_at := p_occurred_at;
            s.failure_received_at := p_received_at;
            s.failure_actor := v_source;
            v_changed := true;
          END IF;
        END IF;
      END IF;
      IF p_event_type IN ('delivery.unknown_pending', 'delivery.unknown') THEN
        v_stage := CASE p_event_type WHEN 'delivery.unknown' THEN 2 ELSE 1 END;
        IF v_stage > COALESCE(s.window_stage, 0) THEN
          s.window_stage := v_stage;
          s.window_stage_at := p_occurred_at;
          v_changed := true;
        END IF;
      END IF;
      IF jsonb_typeof(v_engagement) = 'object' THEN
        v_by := v_engagement ->> 'clicked_by';
        CASE v_engagement ->> 'kind'
          WHEN 'seen' THEN
            IF s.seen_at IS NULL OR p_occurred_at < s.seen_at THEN
              s.seen_at := p_occurred_at;
              s.seen_source := v_engagement ->> 'source';
              v_changed := true;
            END IF;
          WHEN 'read' THEN
            IF s.read_at IS NULL OR p_occurred_at < s.read_at THEN
              s.read_at := p_occurred_at;
              s.read_source := v_engagement ->> 'source';
              v_changed := true;
            END IF;
          WHEN 'archived' THEN
            IF s.archived_at IS NULL OR p_occurred_at < s.archived_at THEN
              s.archived_at := p_occurred_at;
              s.archived_source := v_engagement ->> 'source';
              v_changed := true;
            END IF;
          WHEN 'clicked' THEN
            IF s.clicked_at IS NULL
              OR (v_by = 'human' AND s.clicked_by <> 'human')
              OR (v_by = s.clicked_by AND p_occurred_at < s.clicked_at) THEN
              s.clicked_at := p_occurred_at;
              s.clicked_source := v_engagement ->> 'source';
              s.clicked_by := v_by;
              v_changed := true;
            END IF;
          ELSE
            NULL;
        END CASE;
      END IF;
      s.last_event_at := GREATEST(s.last_event_at, p_received_at);
      s.result := CASE
        WHEN v_changed THEN 'applied'
        WHEN v_conflict THEN 'conflict_flagged'
        ELSE 'stale_ignored'
      END;
      IF s.result <> 'stale_ignored' THEN
        s.projection_version := s.projection_version + 1;
      END IF;
      RETURN s;
    END
    $fn$
    """
  end

  defp ledger_record do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_private.ledger_record(p_id uuid, p_delivery relay.deliveries,
      p_attempt_no bigint, p_actor text, p_event_type text, p_raw_code text, p_provider text,
      p_provider_seq bigint, p_occurred_at timestamptz, p_receipt_id uuid,
      p_delivery_rank smallint, p_failure_kind text, p_failure_class text,
      p_failure_rule_id text, p_failure_reason text, p_after_delivered text, p_detail jsonb,
      p_traceparent text)
      RETURNS relay_private.delivery_projection
    LANGUAGE plpgsql VOLATILE
    SET search_path = pg_catalog, pg_temp
    AS $fn$
    DECLARE
      v_received timestamptz := clock_timestamp();
      v_other boolean := false;
      v_new relay_private.delivery_projection;
      v_effect jsonb;
      v_ended boolean := false;
    BEGIN
      IF p_delivery_rank IS NOT NULL OR p_failure_kind IS NOT NULL
        OR COALESCE(p_detail ? 'engagement', false) THEN
        v_ended := EXISTS (
          SELECT 1 FROM relay.subject_keys k
          WHERE k.tenant_id = p_delivery.tenant_id AND k.environment = p_delivery.environment
            AND k.recipient_id = p_delivery.recipient_id
            AND k.retention_class = 'delivery_record' AND k.state = 'destroyed');
      END IF;
      IF p_delivery_rank = 2 THEN
        v_other := EXISTS (
          SELECT 1 FROM relay.delivery_events e
          WHERE e.tenant_id = p_delivery.tenant_id AND e.environment = p_delivery.environment
            AND e.delivery_id = p_delivery.id
            AND e.detail -> 'effect' ->> 'delivery_rank' = '2'
            AND e.attempt_no IS DISTINCT FROM p_attempt_no);
      END IF;
      v_effect := jsonb_strip_nulls(jsonb_build_object('delivery_rank', p_delivery_rank,
        'failure_kind', p_failure_kind, 'failure_class', p_failure_class,
        'failure_rule_id', p_failure_rule_id, 'failure_reason', p_failure_reason,
        'after_delivered', p_after_delivered, 'engagement', p_detail -> 'engagement',
        'retention_ended', CASE WHEN v_ended THEN true END));
      v_new := relay_private.projection_reduce(relay_private.projection_of(p_delivery), p_actor,
        p_event_type, p_attempt_no, p_provider_seq, p_occurred_at, v_received, v_effect, v_other);
      INSERT INTO relay.delivery_events (tenant_id, environment, id, received_at, delivery_id,
        attempt_no, actor, event_type, raw_code, provider, provider_seq, occurred_at, receipt_id,
        projection_result, detail, evidence_version_id, traceparent)
      VALUES (p_delivery.tenant_id, p_delivery.environment, p_id, v_received, p_delivery.id,
        p_attempt_no, p_actor, p_event_type, p_raw_code, p_provider, p_provider_seq, p_occurred_at,
        p_receipt_id, v_new.result,
        COALESCE(p_detail, '{}'::jsonb) || jsonb_build_object('effect', v_effect), NULL,
        p_traceparent);
      UPDATE relay.deliveries d SET
          delivery_rank = v_new.delivery_rank,
          accepted_at = v_new.accepted_at,
          delivered_at = v_new.delivered_at,
          failure_kind = v_new.failure_kind,
          failure_class = v_new.failure_class,
          failure_rule_id = v_new.failure_rule_id,
          failure_reason = v_new.failure_reason,
          failure_attempt_no = v_new.failure_attempt_no,
          failure_provider_seq = v_new.failure_provider_seq,
          failure_occurred_at = v_new.failure_occurred_at,
          failure_received_at = v_new.failure_received_at,
          failure_actor = v_new.failure_actor,
          has_conflict = v_new.has_conflict,
          duplicate_delivered = v_new.duplicate_delivered,
          late_event_count = v_new.late_event_count,
          projection_version = v_new.projection_version,
          last_event_at = v_new.last_event_at,
          window_stage = v_new.window_stage,
          window_stage_at = v_new.window_stage_at,
          seen_at = v_new.seen_at,
          seen_source = v_new.seen_source,
          read_at = v_new.read_at,
          read_source = v_new.read_source,
          clicked_at = v_new.clicked_at,
          clicked_source = v_new.clicked_source,
          clicked_by = v_new.clicked_by,
          archived_at = v_new.archived_at,
          archived_source = v_new.archived_source,
          updated_at = now()
        WHERE d.tenant_id = p_delivery.tenant_id AND d.environment = p_delivery.environment
          AND d.id = p_delivery.id AND d.delivery_rank <= v_new.delivery_rank;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'invariant_violation' USING HINT = 'OP-4';
      END IF;
      RETURN v_new;
    END
    $fn$
    """
  end

  defp backfill do
    ~S"""
    CREATE FUNCTION relay_fn.delivery_failure_actor_backfill(p_after_id uuid, p_limit integer)
      RETURNS TABLE (scanned bigint, updated bigint, last_id uuid)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_scanned bigint := 0;
      v_updated bigint := 0;
      v_last uuid;
      v_actor text;
      r record;
    BEGIN
      FOR r IN
        SELECT d.id FROM relay.deliveries d
        WHERE d.tenant_id = v_tenant AND d.environment = v_env
          AND (p_after_id IS NULL OR d.id > p_after_id)
        ORDER BY d.id
        LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 1000)
      LOOP
        v_scanned := v_scanned + 1;
        v_last := r.id;
        v_actor := NULL;
        SELECT x.rebuilt INTO v_actor
          FROM relay_fn.delivery_projection_rebuild(r.id) x
          WHERE x.column_name = 'failure_actor' AND x.stored IS NULL;
        IF v_actor IS NOT NULL THEN
          UPDATE relay.deliveries d SET failure_actor = v_actor
            WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = r.id
              AND d.failure_actor IS NULL AND d.failure_kind IS NOT NULL;
          IF FOUND THEN
            v_updated := v_updated + 1;
          END IF;
        END IF;
      END LOOP;
      RETURN QUERY SELECT v_scanned, v_updated, v_last;
    END
    $fn$
    """
  end
end
