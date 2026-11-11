defmodule Relay.Repo.Migrations.ExtendDeliveryProjectionAxes do
  use Ecto.Migration

  @projection "relay_private.delivery_projection"
  @time "timestamp with time zone"

  @private [
    {"relay_private.projection_reduce(#{@projection}, text, text, bigint, bigint, #{@time}, #{@time}, jsonb, boolean)",
     ~w(relay_owner relay_app relay_report)},
    {"relay_private.delivery_status(relay.deliveries)", ~w(relay_owner relay_app relay_report)}
  ]

  @advance "relay_fn.delivery_windows_advance(jsonb, integer)"
  @scopes "relay_ops.delivery_window_scopes(bigint, integer)"

  # C-67
  # INV-5
  # INV-6
  # INV-7
  # INV-8
  # DS-3
  # DS-4
  # DS-5
  # DS-6
  # DS-7
  # DS-8
  # DS-17
  # DS-18
  # DS-20
  # OP-4
  def up do
    execute(projection_type())

    execute(projection_zero())
    execute(projection_of())
    execute(projection_reduce())
    execute(projection_apply())
    execute(ledger_record())
    execute(delivery_status())

    for {signature, grantees} <- @private do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
    end

    execute(windows_advance())
    execute("REVOKE ALL ON FUNCTION #{@advance} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@advance} TO relay_app")
    execute("ALTER FUNCTION #{@advance} OWNER TO relay_owner")

    execute(window_scopes())
    execute("REVOKE ALL ON FUNCTION #{@scopes} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@scopes} TO relay_worker")

    execute("SET LOCAL ROLE relay_owner")
    execute(ledger_append())
    execute(projection_rebuild())
    execute("RESET ROLE")
  end

  def down, do: :ok

  defp projection_type do
    """
    ALTER TYPE relay_private.delivery_projection
      ADD ATTRIBUTE window_stage smallint,
      ADD ATTRIBUTE window_stage_at timestamptz,
      ADD ATTRIBUTE failure_actor text,
      ADD ATTRIBUTE seen_at timestamptz,
      ADD ATTRIBUTE seen_source text,
      ADD ATTRIBUTE read_at timestamptz,
      ADD ATTRIBUTE read_source text,
      ADD ATTRIBUTE clicked_at timestamptz,
      ADD ATTRIBUTE clicked_source text,
      ADD ATTRIBUTE clicked_by text,
      ADD ATTRIBUTE archived_at timestamptz,
      ADD ATTRIBUTE archived_source text
    """
  end

  defp projection_zero do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_private.projection_zero()
      RETURNS relay_private.delivery_projection
    LANGUAGE sql IMMUTABLE
    SET search_path = pg_catalog, pg_temp
    AS $fn$
      SELECT ROW(0::smallint, NULL::timestamptz, NULL::timestamptz, NULL::text, NULL::text,
        NULL::text, NULL::text, NULL::bigint, NULL::bigint, NULL::timestamptz, NULL::timestamptz,
        false, false, 0::bigint, 0::bigint, NULL::timestamptz, NULL::text,
        0::smallint, NULL::timestamptz, NULL::text, NULL::timestamptz, NULL::text,
        NULL::timestamptz, NULL::text, NULL::timestamptz, NULL::text, NULL::text,
        NULL::timestamptz, NULL::text
      )::relay_private.delivery_projection
    $fn$
    """
  end

  defp projection_of do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_private.projection_of(p_delivery relay.deliveries)
      RETURNS relay_private.delivery_projection
    LANGUAGE sql IMMUTABLE
    SET search_path = pg_catalog, pg_temp
    AS $fn$
      SELECT ROW(p_delivery.delivery_rank, p_delivery.accepted_at, p_delivery.delivered_at,
        p_delivery.failure_kind, p_delivery.failure_class, p_delivery.failure_rule_id,
        p_delivery.failure_reason, p_delivery.failure_attempt_no, p_delivery.failure_provider_seq,
        p_delivery.failure_occurred_at, p_delivery.failure_received_at, p_delivery.has_conflict,
        p_delivery.duplicate_delivered, p_delivery.late_event_count,
        p_delivery.projection_version, p_delivery.last_event_at, NULL::text,
        p_delivery.window_stage, p_delivery.window_stage_at, p_delivery.failure_actor,
        p_delivery.seen_at, p_delivery.seen_source, p_delivery.read_at, p_delivery.read_source,
        p_delivery.clicked_at, p_delivery.clicked_source, p_delivery.clicked_by,
        p_delivery.archived_at, p_delivery.archived_source
      )::relay_private.delivery_projection
    $fn$
    """
  end

  defp projection_reduce do
    ~S"""
    CREATE FUNCTION relay_private.projection_reduce(p_state relay_private.delivery_projection,
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

  defp projection_apply do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_private.projection_apply(p_state relay_private.delivery_projection,
      p_event_type text, p_attempt_no bigint, p_provider_seq bigint, p_occurred_at timestamptz,
      p_received_at timestamptz, p_delivery_rank smallint, p_failure_kind text,
      p_failure_class text, p_failure_rule_id text, p_failure_reason text,
      p_after_delivered text, p_other_attempt_delivered boolean)
      RETURNS relay_private.delivery_projection
    LANGUAGE plpgsql IMMUTABLE
    SET search_path = pg_catalog, pg_temp
    AS $fn$
    BEGIN
      RETURN relay_private.projection_reduce(p_state, NULL, p_event_type, p_attempt_no,
        p_provider_seq, p_occurred_at, p_received_at,
        jsonb_strip_nulls(jsonb_build_object('delivery_rank', p_delivery_rank,
          'failure_kind', p_failure_kind, 'failure_class', p_failure_class,
          'failure_rule_id', p_failure_rule_id, 'failure_reason', p_failure_reason,
          'after_delivered', p_after_delivered)),
        p_other_attempt_delivered);
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
    BEGIN
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
        'after_delivered', p_after_delivered, 'engagement', p_detail -> 'engagement'));
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

  defp delivery_status do
    ~S"""
    CREATE FUNCTION relay_private.delivery_status(p_delivery relay.deliveries) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path = pg_catalog, pg_temp
    AS $fn$
      SELECT CASE
        WHEN p_delivery.failure_kind = 'skipped' THEN 'skipped'
        WHEN p_delivery.failure_kind = 'cancelled' THEN 'cancelled'
        WHEN p_delivery.failure_kind = 'expired' THEN 'expired'
        WHEN p_delivery.failure_kind IN ('failed', 'bounced') THEN 'failed'
        WHEN p_delivery.delivery_rank = 2 THEN 'delivered'
        WHEN p_delivery.delivery_rank = 1 AND p_delivery.window_stage = 2 THEN 'unknown'
        WHEN p_delivery.delivery_rank = 1 AND p_delivery.window_stage = 1 THEN 'unknown_pending'
        WHEN p_delivery.delivery_rank = 1 THEN 'sent'
        ELSE 'queued'
      END
    $fn$
    """
  end

  defp windows_advance do
    ~S"""
    CREATE FUNCTION relay_fn.delivery_windows_advance(p_windows jsonb, p_limit integer)
      RETURNS TABLE (delivery_id uuid, channel text, provider text, window_stage smallint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_now timestamptz := relay_private.business_now();
      v_delivery relay.deliveries;
      v_stage smallint;
      v_due timestamptz;
      r record;
    BEGIN
      IF p_windows IS NULL OR jsonb_typeof(p_windows) <> 'array' THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'DS-18';
      END IF;
      FOR r IN
        SELECT c.id, c.channel, c.provider, c.accepted_at, w.short_ms, w.long_ms
        FROM (
          SELECT d.id, d.channel::text AS channel, d.accepted_at,
            COALESCE((SELECT a.provider FROM relay.delivery_attempts a
              WHERE a.tenant_id = d.tenant_id AND a.environment = d.environment
                AND a.delivery_id = d.id AND a.attempt_no = d.attempt_count
              LIMIT 1), d.provider) AS provider
          FROM relay.deliveries d
          WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.delivery_rank = 1
            AND d.failure_kind IS NULL AND d.window_stage < 2
            AND d.channel IN ('sms', 'email', 'whatsapp', 'voice')
            AND d.accepted_at <= v_now - interval '15 minutes'
        ) c
        CROSS JOIN LATERAL (
          SELECT (x ->> 'short_ms')::bigint AS short_ms, (x ->> 'long_ms')::bigint AS long_ms
          FROM jsonb_array_elements(p_windows) AS x
          WHERE x ->> 'channel' = c.channel
            AND (x ->> 'provider' IS NULL OR x ->> 'provider' = c.provider)
          ORDER BY (x ->> 'provider') IS NULL
          LIMIT 1
        ) w
        WHERE c.accepted_at + w.short_ms * interval '1 millisecond' <= v_now
        ORDER BY c.accepted_at, c.id
        LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 1000)
      LOOP
        v_stage := CASE WHEN r.accepted_at + r.long_ms * interval '1 millisecond' <= v_now
          THEN 2 ELSE 1 END;
        SELECT * INTO v_delivery FROM relay.deliveries d
          WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = r.id
          FOR UPDATE SKIP LOCKED;
        CONTINUE WHEN NOT FOUND;
        CONTINUE WHEN v_delivery.delivery_rank <> 1 OR v_delivery.failure_kind IS NOT NULL
          OR v_delivery.window_stage >= v_stage;
        IF v_delivery.window_stage < 1 THEN
          v_due := r.accepted_at + r.short_ms * interval '1 millisecond';
          PERFORM relay_private.ledger_record(uuidv7(), v_delivery, NULL, 'relay',
            'delivery.unknown_pending', NULL, NULL, NULL, LEAST(v_due, now()), NULL, NULL, NULL,
            NULL, NULL, NULL, NULL,
            jsonb_build_object('window', jsonb_build_object('short_ms', r.short_ms,
              'long_ms', r.long_ms, 'due_at', v_due)),
            v_delivery.traceparent);
        END IF;
        IF v_stage = 2 THEN
          SELECT * INTO v_delivery FROM relay.deliveries d
            WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = r.id;
          v_due := r.accepted_at + r.long_ms * interval '1 millisecond';
          PERFORM relay_private.ledger_record(uuidv7(), v_delivery, NULL, 'relay',
            'delivery.unknown', NULL, NULL, NULL, LEAST(v_due, now()), NULL, NULL, NULL,
            NULL, NULL, NULL, NULL,
            jsonb_build_object('window', jsonb_build_object('short_ms', r.short_ms,
              'long_ms', r.long_ms, 'due_at', v_due)),
            v_delivery.traceparent);
        END IF;
        delivery_id := r.id;
        channel := r.channel;
        provider := r.provider;
        window_stage := v_stage;
        RETURN NEXT;
      END LOOP;
    END
    $fn$
    """
  end

  defp window_scopes do
    ~S"""
    CREATE FUNCTION relay_ops.delivery_window_scopes(p_min_age_ms bigint, p_limit integer)
      RETURNS TABLE (tenant_id uuid, environment text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
      SELECT DISTINCT d.tenant_id, d.environment::text
      FROM relay.deliveries d
      LEFT JOIN relay.virtual_clocks v ON v.tenant_id = d.tenant_id
        AND v.environment = d.environment
      WHERE d.delivery_rank = 1 AND d.failure_kind IS NULL AND d.window_stage < 2
        AND d.channel IN ('sms', 'email', 'whatsapp', 'voice')
        AND d.accepted_at <= now() + coalesce(v.offset_ms, 0) * interval '1 millisecond'
          - GREATEST(COALESCE(p_min_age_ms, 0), 0) * interval '1 millisecond'
      LIMIT GREATEST(COALESCE(p_limit, 100), 1)
    $fn$
    """
  end

  defp ledger_append do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_fn.ledger_append(p_id uuid, p_delivery_id uuid,
      p_attempt_no bigint, p_actor text, p_event_type text, p_raw_code text, p_provider text,
      p_provider_seq bigint, p_occurred_at timestamptz, p_receipt_id uuid,
      p_delivery_rank smallint, p_failure_kind text, p_failure_class text,
      p_failure_rule_id text, p_after_delivered text, p_detail jsonb, p_traceparent text)
      RETURNS TABLE (result text, delivery_rank smallint, projection_version bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_delivery relay.deliveries;
      v_receipt_state text;
      v_occurred timestamptz := p_occurred_at;
      v_new relay_private.delivery_projection;
      v_engagement jsonb;
    BEGIN
      PERFORM relay_private.assert_new_id(p_id);
      IF p_actor IS NULL
        OR p_actor NOT IN ('relay', 'provider_api', 'provider_webhook', 'client_sdk', 'user')
        OR p_event_type IS NULL OR p_occurred_at IS NULL
        OR (p_delivery_rank IS NOT NULL AND p_delivery_rank NOT IN (0, 1, 2))
        OR (p_failure_kind IS NOT NULL
          AND p_failure_kind NOT IN ('skipped', 'failed', 'bounced', 'expired', 'cancelled'))
        OR (p_after_delivered IS NOT NULL AND p_after_delivered NOT IN ('valid', 'stale', 'conflict'))
        OR (p_detail IS NOT NULL AND jsonb_typeof(p_detail) <> 'object') THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'DS-2';
      END IF;
      v_engagement := p_detail -> 'engagement';
      IF v_engagement IS NOT NULL AND (jsonb_typeof(v_engagement) <> 'object'
        OR v_engagement ->> 'kind' IS NULL
        OR v_engagement ->> 'kind' NOT IN ('seen', 'read', 'clicked', 'archived')
        OR v_engagement ->> 'source' IS NULL
        OR v_engagement ->> 'source'
          NOT IN ('inbox_action', 'provider_signal', 'client_sdk', 'tracked_link')
        OR (v_engagement ->> 'kind' = 'clicked') <> (v_engagement ->> 'clicked_by' IS NOT NULL)
        OR COALESCE(v_engagement ->> 'clicked_by', 'human') NOT IN ('human', 'likely_bot')) THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'DS-3';
      END IF;
      SELECT * INTO v_delivery FROM relay.deliveries d
        WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_delivery_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'delivery_not_found'::text, NULL::smallint, NULL::bigint;
        RETURN;
      END IF;
      IF p_attempt_no IS NOT NULL
        AND (p_attempt_no < 1 OR p_attempt_no > v_delivery.attempt_count) THEN
        RETURN QUERY SELECT 'attempt_not_found'::text, v_delivery.delivery_rank,
          v_delivery.projection_version;
        RETURN;
      END IF;
      IF p_receipt_id IS NOT NULL THEN
        SELECT w.state INTO v_receipt_state FROM relay.webhook_receipts w
          WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_receipt_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'WH-49';
        END IF;
        IF v_receipt_state <> 'received' THEN
          RETURN QUERY SELECT 'duplicate_ignored'::text, v_delivery.delivery_rank,
            v_delivery.projection_version;
          RETURN;
        END IF;
      END IF;
      IF p_occurred_at > now() + interval '1 hour' THEN
        IF p_actor IN ('client_sdk', 'user') THEN
          v_occurred := now();
        ELSE
          RETURN QUERY SELECT 'rejected_future_timestamp'::text, v_delivery.delivery_rank,
            v_delivery.projection_version;
          RETURN;
        END IF;
      END IF;
      IF p_receipt_id IS NOT NULL THEN
        UPDATE relay.webhook_receipts w SET state = 'processed', processed_at = now(),
            updated_at = now()
          WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_receipt_id;
      END IF;
      v_new := relay_private.ledger_record(p_id, v_delivery, p_attempt_no, p_actor, p_event_type,
        p_raw_code, p_provider, p_provider_seq, v_occurred, p_receipt_id, p_delivery_rank,
        p_failure_kind, p_failure_class, p_failure_rule_id, NULL, p_after_delivered, p_detail,
        p_traceparent);
      RETURN QUERY SELECT v_new.result, v_new.delivery_rank, v_new.projection_version;
    END
    $fn$
    """
  end

  defp projection_rebuild do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_fn.delivery_projection_rebuild(p_delivery_id uuid)
      RETURNS TABLE (column_name text, stored text, rebuilt text)
    LANGUAGE plpgsql STABLE SECURITY INVOKER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_delivery relay.deliveries;
      s relay_private.delivery_projection := relay_private.projection_zero();
      e relay.delivery_events;
      v_effect jsonb;
      v_rank smallint;
      v_delivered bigint[] := ARRAY[]::bigint[];
      v_delivered_null boolean := false;
      v_other boolean;
      v_paused_at timestamptz;
      v_pause_rule_id text;
      v_pause_kill_switch_id uuid;
      v_replay_depth smallint := 0;
      v_replay_dead_letter_id uuid;
      v_replay_dead_letter_created_at timestamptz;
    BEGIN
      SELECT * INTO v_delivery FROM relay.deliveries d
        WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_delivery_id;
      IF NOT FOUND THEN
        RETURN;
      END IF;
      FOR e IN
        SELECT * FROM relay.delivery_events x
        WHERE x.tenant_id = v_tenant AND x.environment = v_env AND x.delivery_id = p_delivery_id
        ORDER BY x.received_at, x.id
      LOOP
        v_effect := COALESCE(e.detail -> 'effect', '{}'::jsonb);
        v_rank := (v_effect ->> 'delivery_rank')::smallint;
        v_other := false;
        IF v_rank = 2 THEN
          v_other := (e.attempt_no IS NULL AND cardinality(v_delivered) > 0)
            OR (e.attempt_no IS NOT NULL
              AND (v_delivered_null OR EXISTS (
                SELECT 1 FROM unnest(v_delivered) AS x(n) WHERE x.n <> e.attempt_no)));
        END IF;
        s := relay_private.projection_reduce(s, e.actor, e.event_type, e.attempt_no,
          e.provider_seq, e.occurred_at, e.received_at, v_effect, v_other);
        IF e.event_type = 'delivery.paused' THEN
          v_paused_at := e.occurred_at;
          v_pause_rule_id := e.detail ->> 'rule_id';
          v_pause_kill_switch_id := (e.detail ->> 'kill_switch_id')::uuid;
        ELSIF e.event_type = 'delivery.resumed' THEN
          v_paused_at := NULL;
          v_pause_rule_id := NULL;
          v_pause_kill_switch_id := NULL;
        ELSIF e.event_type = 'delivery.replay_opened' THEN
          v_replay_depth := 1;
          v_replay_dead_letter_id := (e.detail ->> 'dead_letter_id')::uuid;
          v_replay_dead_letter_created_at := (e.detail ->> 'dead_letter_created_at')::timestamptz;
        END IF;
        IF v_rank = 2 THEN
          IF e.attempt_no IS NULL THEN
            v_delivered_null := true;
          ELSE
            v_delivered := array_append(v_delivered, e.attempt_no);
          END IF;
        END IF;
      END LOOP;
      RETURN QUERY
        SELECT c.name, c.stored, c.rebuilt
        FROM (VALUES
          ('delivery_rank', v_delivery.delivery_rank::text, s.delivery_rank::text),
          ('accepted_at', v_delivery.accepted_at::text, s.accepted_at::text),
          ('delivered_at', v_delivery.delivered_at::text, s.delivered_at::text),
          ('failure_kind', v_delivery.failure_kind, s.failure_kind),
          ('failure_class', v_delivery.failure_class, s.failure_class),
          ('failure_rule_id', v_delivery.failure_rule_id, s.failure_rule_id),
          ('failure_reason', v_delivery.failure_reason, s.failure_reason),
          ('failure_attempt_no', v_delivery.failure_attempt_no::text, s.failure_attempt_no::text),
          ('failure_provider_seq', v_delivery.failure_provider_seq::text,
            s.failure_provider_seq::text),
          ('failure_occurred_at', v_delivery.failure_occurred_at::text,
            s.failure_occurred_at::text),
          ('failure_received_at', v_delivery.failure_received_at::text,
            s.failure_received_at::text),
          ('failure_actor', v_delivery.failure_actor, s.failure_actor),
          ('has_conflict', v_delivery.has_conflict::text, s.has_conflict::text),
          ('duplicate_delivered', v_delivery.duplicate_delivered::text,
            s.duplicate_delivered::text),
          ('late_event_count', v_delivery.late_event_count::text, s.late_event_count::text),
          ('projection_version', v_delivery.projection_version::text, s.projection_version::text),
          ('last_event_at', v_delivery.last_event_at::text, s.last_event_at::text),
          ('window_stage', v_delivery.window_stage::text, s.window_stage::text),
          ('window_stage_at', v_delivery.window_stage_at::text, s.window_stage_at::text),
          ('seen_at', v_delivery.seen_at::text, s.seen_at::text),
          ('seen_source', v_delivery.seen_source, s.seen_source),
          ('read_at', v_delivery.read_at::text, s.read_at::text),
          ('read_source', v_delivery.read_source, s.read_source),
          ('clicked_at', v_delivery.clicked_at::text, s.clicked_at::text),
          ('clicked_source', v_delivery.clicked_source, s.clicked_source),
          ('clicked_by', v_delivery.clicked_by, s.clicked_by),
          ('archived_at', v_delivery.archived_at::text, s.archived_at::text),
          ('archived_source', v_delivery.archived_source, s.archived_source),
          ('paused_at', v_delivery.paused_at::text, v_paused_at::text),
          ('pause_rule_id', v_delivery.pause_rule_id::text, v_pause_rule_id),
          ('pause_kill_switch_id', v_delivery.pause_kill_switch_id::text,
            v_pause_kill_switch_id::text),
          ('replay_depth', v_delivery.replay_depth::text, v_replay_depth::text),
          ('replay_dead_letter_id', v_delivery.replay_dead_letter_id::text,
            v_replay_dead_letter_id::text),
          ('replay_dead_letter_created_at', v_delivery.replay_dead_letter_created_at::text,
            v_replay_dead_letter_created_at::text)
        ) AS c(name, stored, rebuilt)
        WHERE c.stored IS DISTINCT FROM c.rebuilt;
    END
    $fn$
    """
  end
end
