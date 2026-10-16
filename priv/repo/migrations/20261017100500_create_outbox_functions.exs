defmodule Relay.Repo.Migrations.CreateOutboxFunctions do
  use Ecto.Migration

  @functions [
    {"relay_fn.stream_next_seq(text)", "relay_owner", ~w(relay_app)},
    {"relay_fn.outbox_append(uuid, text, text, jsonb, text)", "relay_owner", ~w(relay_app)},
    {"relay_ops.outbox_pending_scopes(integer)", "relay_maint", ~w(relay_worker)},
    {"relay_fn.outbox_claim(integer)", "relay_owner", ~w(relay_app)},
    {"relay_fn.outbox_mark_dispatched(uuid[])", "relay_owner", ~w(relay_app)},
    {"relay_fn.usage_record_append(uuid, date, text, text, text, text, text, text, boolean, bigint, bigint, bigint, bigint, text)",
     "relay_owner", ~w(relay_app)}
  ]

  # OP-5
  # OP-7
  # OP-38
  # INV-2
  def up do
    Enum.each(statements(), &execute/1)

    for {signature, owner, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      if owner == "relay_owner", do: execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
    end
  end

  def down do
    for {signature, _owner, _grantees} <- Enum.reverse(@functions),
        do: execute("DROP FUNCTION #{signature}")
  end

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_fn.stream_next_seq(p_stream_key text)
        RETURNS TABLE (epoch bigint, seq bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_epoch bigint;
        v_seq bigint;
      BEGIN
        IF p_stream_key IS NULL OR p_stream_key !~ '^[a-z_]+:[A-Za-z0-9_.:-]{1,200}$' THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-5';
        END IF;
        INSERT INTO relay.stream_heads AS h (tenant_id, environment, stream_key, epoch, last_seq,
          updated_at)
        VALUES (relay_private.ctx_tenant_id(), relay_private.ctx_environment(), p_stream_key, 1, 1,
          now())
        ON CONFLICT (tenant_id, environment, stream_key)
          DO UPDATE SET last_seq = h.last_seq + 1, updated_at = now()
        RETURNING h.epoch, h.last_seq INTO v_epoch, v_seq;
        RETURN QUERY SELECT v_epoch, v_seq;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.outbox_append(p_id uuid, p_event_type text, p_stream_key text,
        p_payload jsonb, p_traceparent text)
        RETURNS TABLE (result text, epoch bigint, seq bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_epoch bigint;
        v_seq bigint;
      BEGIN
        PERFORM relay_private.assert_new_id(p_id);
        IF p_event_type IS NULL OR p_payload IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'INV-2';
        END IF;
        SELECT n.epoch, n.seq INTO v_epoch, v_seq FROM relay_fn.stream_next_seq(p_stream_key) n;
        INSERT INTO relay.outbox_events (tenant_id, environment, id, created_at, event_type,
          stream_key, epoch, seq, payload, state, dispatched_at, traceparent)
        VALUES (relay_private.ctx_tenant_id(), relay_private.ctx_environment(), p_id, now(),
          p_event_type, p_stream_key, v_epoch, v_seq, p_payload, 'pending', NULL, p_traceparent);
        RETURN QUERY SELECT 'appended'::text, v_epoch, v_seq;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.outbox_pending_scopes(p_limit integer)
        RETURNS TABLE (tenant_id uuid, environment text, oldest_created_at timestamptz)
      LANGUAGE sql STABLE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT o.tenant_id, o.environment::text, min(o.created_at)
        FROM relay.outbox_events o
        WHERE o.state = 'pending'
        GROUP BY o.tenant_id, o.environment
        ORDER BY min(o.created_at)
        LIMIT GREATEST(COALESCE(p_limit, 100), 1)
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.outbox_claim(p_limit integer)
        RETURNS TABLE (id uuid, created_at timestamptz, event_type text, stream_key text,
          epoch bigint, seq bigint, payload jsonb, traceparent text)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      BEGIN
        IF p_limit IS NULL OR p_limit < 1 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-5';
        END IF;
        RETURN QUERY
          SELECT o.id, o.created_at, o.event_type::text, o.stream_key, o.epoch, o.seq, o.payload,
            o.traceparent
          FROM relay.outbox_events o
          WHERE o.tenant_id = relay_private.ctx_tenant_id()
            AND o.environment = relay_private.ctx_environment()
            AND o.state = 'pending'
          ORDER BY o.created_at, o.id
          LIMIT p_limit
          FOR UPDATE SKIP LOCKED;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.outbox_mark_dispatched(p_ids uuid[])
        RETURNS TABLE (id uuid, result text)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_id uuid;
      BEGIN
        FOR v_id IN
          SELECT DISTINCT r.rid FROM unnest(COALESCE(p_ids, ARRAY[]::uuid[])) AS r(rid)
          WHERE r.rid IS NOT NULL ORDER BY r.rid
        LOOP
          UPDATE relay.outbox_events o SET state = 'dispatched', dispatched_at = now()
            WHERE o.tenant_id = v_tenant AND o.environment = v_env AND o.id = v_id
              AND o.state = 'pending';
          id := v_id;
          IF FOUND THEN
            result := 'dispatched';
          ELSIF EXISTS (SELECT 1 FROM relay.outbox_events x
            WHERE x.tenant_id = v_tenant AND x.environment = v_env AND x.id = v_id) THEN
            result := 'already_dispatched';
          ELSE
            result := 'not_found';
          END IF;
          RETURN NEXT;
        END LOOP;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.usage_record_append(p_id uuid, p_usage_day date, p_channel text,
        p_provider text, p_destination_country text, p_destination_operator text,
        p_whatsapp_category text, p_outcome text, p_is_test boolean, p_quantity bigint,
        p_attempt_count bigint, p_sms_segments bigint, p_cost_micros bigint, p_currency text)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.usage_records;
        v_inserted uuid;
      BEGIN
        PERFORM relay_private.assert_new_id(p_id);
        IF p_usage_day IS NULL OR p_channel IS NULL OR p_provider IS NULL OR p_outcome IS NULL
          OR p_is_test IS NULL OR p_quantity IS NULL OR p_quantity < 0
          OR p_attempt_count IS NULL OR p_attempt_count < 0
          OR (p_cost_micros IS NULL) <> (p_currency IS NULL) THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'C-88';
        END IF;
        IF p_usage_day >= current_date THEN
          RETURN 'day_open';
        END IF;
        INSERT INTO relay.usage_records AS u (tenant_id, environment, id, usage_day, channel, provider,
          destination_country, destination_operator, whatsapp_category, outcome, is_test, quantity,
          attempt_count, sms_segments, cost_micros, currency, created_at)
        VALUES (v_tenant, v_env, p_id, p_usage_day, p_channel, p_provider, p_destination_country,
          p_destination_operator, p_whatsapp_category, p_outcome, p_is_test, p_quantity,
          p_attempt_count, p_sms_segments, p_cost_micros, p_currency, now())
        ON CONFLICT DO NOTHING
        RETURNING u.id INTO v_inserted;
        IF v_inserted IS NOT NULL THEN
          RETURN 'recorded';
        END IF;
        SELECT * INTO v_row FROM relay.usage_records u
          WHERE u.tenant_id = v_tenant AND u.environment = v_env AND u.usage_day = p_usage_day
            AND u.channel = p_channel AND u.provider = p_provider
            AND u.destination_country IS NOT DISTINCT FROM p_destination_country
            AND u.destination_operator IS NOT DISTINCT FROM p_destination_operator
            AND u.whatsapp_category IS NOT DISTINCT FROM p_whatsapp_category
            AND u.outcome = p_outcome AND u.is_test = p_is_test;
        IF FOUND AND v_row.quantity = p_quantity AND v_row.attempt_count = p_attempt_count
          AND v_row.sms_segments IS NOT DISTINCT FROM p_sms_segments
          AND v_row.cost_micros IS NOT DISTINCT FROM p_cost_micros
          AND v_row.currency IS NOT DISTINCT FROM p_currency THEN
          RETURN 'duplicate';
        END IF;
        RETURN 'conflict';
      END
      $fn$
      """
    ]
  end
end
