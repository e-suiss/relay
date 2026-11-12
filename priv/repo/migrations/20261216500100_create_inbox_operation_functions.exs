defmodule Relay.Repo.Migrations.CreateInboxOperationFunctions do
  use Ecto.Migration

  @functions [
    {"relay_private.inbox_lock(uuid, relay.environment, uuid)", "relay_migrator",
     ~w(relay_owner)},
    {"relay_private.inbox_stream(uuid, relay.environment, uuid)", "relay_migrator",
     ~w(relay_owner)},
    {"relay_private.inbox_recount(uuid, relay.environment, uuid, timestamptz, boolean)",
     "relay_migrator", ~w(relay_owner)},
    {"relay_private.inbox_engage(relay.inbox_items, text, timestamptz)", "relay_migrator",
     ~w(relay_owner)},
    {"relay_private.inbox_bulk_apply(uuid, relay.environment, uuid, uuid[], text, timestamptz)",
     "relay_migrator", ~w(relay_owner)},
    {"relay_private.inbox_bulk_publish(uuid, relay.environment, uuid, text, text, bigint, bigint)",
     "relay_migrator", ~w(relay_owner)},
    {"relay_fn.inbox_read_all(uuid, text)", "relay_owner", ~w(relay_app)},
    {"relay_fn.inbox_bulk_start(uuid, uuid, text, text, text, text)", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.inbox_bulk_chunk(uuid, integer)", "relay_owner", ~w(relay_app)},
    {"relay_fn.inbox_engage(uuid, uuid, text)", "relay_owner", ~w(relay_app)},
    {"relay_fn.inbox_reconcile(uuid)", "relay_owner", ~w(relay_app)},
    {"relay_fn.inbox_reconcile_changed(timestamptz, uuid, integer)", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.inbox_trim(uuid, bigint)", "relay_owner", ~w(relay_app)},
    {"relay_fn.inbox_retire_due(bigint, bigint, integer)", "relay_owner", ~w(relay_app)},
    {"relay_fn.inbox_announcement_create(uuid, text, uuid, text, text, text[], text, jsonb, text, text, timestamptz, bytea, text, text, text, text)",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.inbox_announcement_retract(uuid, bytea, text, text, text, text)", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.inbox_announcement_expire(uuid)", "relay_owner", ~w(relay_app)},
    {"relay_fn.inbox_announcement_intent(uuid, uuid, text, bigint)", "relay_owner", ~w(relay_app)}
  ]

  @archived "(i.archived_at IS NOT NULL AND (i.unarchived_at IS NULL OR i.archived_at > i.unarchived_at))"
  @live "(i.hidden_at IS NULL AND i.expired_at IS NULL AND (i.expires_at IS NULL OR i.expires_at > v_now))"
  @awake "(i.snoozed_until IS NULL OR i.snoozed_until <= v_now)"
  @read "(i.read_at IS NOT NULL AND i.read_at >= i.last_activity_at AND (i.unread_marked_at IS NULL OR i.read_at > i.unread_marked_at))"
  @seen "(i.seen_at IS NOT NULL AND i.seen_at >= i.last_activity_at)"
  @visible "(a.audience = 'tenant' OR (a.audience = 'topic' AND EXISTS (SELECT 1 FROM relay.topic_subscriptions t WHERE t.tenant_id = a.tenant_id AND t.environment = a.environment AND t.topic_id = a.topic_id AND t.recipient_id = p_recipient_id AND t.state = 'active')) OR (a.audience = 'subtenant' AND EXISTS (SELECT 1 FROM relay.inbox_items s WHERE s.tenant_id = a.tenant_id AND s.environment = a.environment AND s.recipient_id = p_recipient_id AND s.subtenant_id = a.subtenant_id)))"

  # IN-3
  # C-70
  # API-35
  # IN-14
  # IN-50
  # X-17
  # IN-18
  # IN-21
  # OP-42
  # IN-44
  # OP-22
  # DS-7
  # DS-12
  # IN-25
  # IN-26
  def up do
    Enum.each(statements(), &execute/1)

    for {signature, owner, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      if owner == "relay_owner", do: execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
    end
  end

  def down, do: :ok

  defp statements do
    [
      lock(),
      stream(),
      recount(),
      engage_private(),
      bulk_apply(),
      bulk_publish(),
      read_all(),
      bulk_start(),
      bulk_chunk(),
      engage(),
      reconcile(),
      reconcile_changed(),
      trim(),
      retire_due(),
      announcement_create(),
      announcement_retract(),
      announcement_expire(),
      announcement_intent()
    ]
  end

  defp lock do
    ~S"""
    CREATE FUNCTION relay_private.inbox_lock(p_tenant uuid, p_env relay.environment,
      p_recipient uuid)
      RETURNS void
    LANGUAGE sql VOLATILE
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
      SELECT pg_advisory_xact_lock(hashtextextended('inbox:' || p_tenant::text || p_env::text
        || p_recipient::text, 0));
    $fn$
    """
  end

  defp stream do
    ~S"""
    CREATE FUNCTION relay_private.inbox_stream(p_tenant uuid, p_env relay.environment,
      p_recipient uuid)
      RETURNS text
    LANGUAGE plpgsql VOLATILE
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_stream text;
    BEGIN
      SELECT m.stream_key INTO v_stream FROM relay.mailboxes m
        WHERE m.tenant_id = p_tenant AND m.environment = p_env
          AND m.owner_kind = 'subscriber' AND m.owner_ref = p_recipient;
      IF v_stream IS NULL THEN
        SELECT e.stream_key INTO v_stream
          FROM relay_fn.mailbox_ensure(uuidv7(), 'subscriber', p_recipient) e;
      END IF;
      IF v_stream IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'IN-1';
      END IF;
      RETURN v_stream;
    END
    $fn$
    """
  end

  defp recount do
    """
    CREATE FUNCTION relay_private.inbox_recount(p_tenant uuid, p_env relay.environment,
      p_recipient uuid, p_now timestamptz, p_force boolean)
      RETURNS TABLE (drifted boolean, version bigint)
    LANGUAGE plpgsql VOLATILE
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_now timestamptz := p_now;
      v_fixed bigint;
      v_total bigint;
      v_unseen bigint;
      v_unread bigint;
      v_row relay.inbox_counters;
      v_found boolean;
      v_drift boolean;
      v_version bigint;
    BEGIN
      WITH computed AS (
        SELECT i.id, (#{@live} AND #{@awake} AND NOT #{@archived}) AS t,
          #{@seen} AS s, #{@read} AS r
        FROM relay.inbox_items i
        WHERE i.tenant_id = p_tenant AND i.environment = p_env AND i.recipient_id = p_recipient
      ), fixed AS (
        UPDATE relay.inbox_items i SET counted_total = c.t,
            counted_unseen = c.t AND NOT c.s, counted_unread = c.t AND NOT c.r
          FROM computed c
          WHERE i.tenant_id = p_tenant AND i.environment = p_env
            AND i.recipient_id = p_recipient AND i.id = c.id
            AND (i.counted_total, i.counted_unseen, i.counted_unread)
              IS DISTINCT FROM (c.t, c.t AND NOT c.s, c.t AND NOT c.r)
          RETURNING 1
      )
      SELECT count(*) INTO v_fixed FROM fixed;
      SELECT count(*) FILTER (WHERE i.counted_total), count(*) FILTER (WHERE i.counted_unseen),
          count(*) FILTER (WHERE i.counted_unread)
        INTO v_total, v_unseen, v_unread
        FROM relay.inbox_items i
        WHERE i.tenant_id = p_tenant AND i.environment = p_env AND i.recipient_id = p_recipient;
      SELECT * INTO v_row FROM relay.inbox_counters c
        WHERE c.tenant_id = p_tenant AND c.environment = p_env AND c.recipient_id = p_recipient;
      v_found := FOUND;
      v_drift := v_fixed > 0
        OR (v_found AND (v_row.total_count, v_row.unseen_count, v_row.unread_count)
          IS DISTINCT FROM (v_total, v_unseen, v_unread))
        OR (NOT v_found AND v_total > 0);
      IF v_drift OR p_force THEN
        IF v_found THEN
          UPDATE relay.inbox_counters c SET total_count = v_total, unseen_count = v_unseen,
              unread_count = v_unread, version = c.version + 1, updated_at = p_now
            WHERE c.tenant_id = p_tenant AND c.environment = p_env
              AND c.recipient_id = p_recipient
            RETURNING c.version INTO v_version;
        ELSE
          INSERT INTO relay.inbox_counters (tenant_id, environment, recipient_id, unseen_count,
            unread_count, total_count, version, updated_at)
          VALUES (p_tenant, p_env, p_recipient, v_unseen, v_unread, v_total, 1, p_now);
          v_version := 1;
        END IF;
      ELSE
        v_version := COALESCE(v_row.version, 0);
      END IF;
      RETURN QUERY SELECT v_drift, v_version;
    END
    $fn$
    """
  end

  defp engage_private do
    ~S"""
    CREATE FUNCTION relay_private.inbox_engage(p_item relay.inbox_items, p_kind text,
      p_now timestamptz)
      RETURNS void
    LANGUAGE plpgsql VOLATILE
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_result text;
      v_delivery relay.deliveries;
      v_engagement jsonb;
    BEGIN
      IF p_kind IS NULL OR p_kind NOT IN ('seen', 'read', 'clicked', 'archived') THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'DS-7';
      END IF;
      v_engagement := jsonb_build_object('kind', p_kind, 'source', 'inbox_action');
      IF p_kind = 'clicked' THEN
        v_engagement := v_engagement || jsonb_build_object('clicked_by', 'human');
      END IF;
      SELECT a.result INTO v_result
        FROM relay_fn.ledger_append(uuidv7(), p_item.delivery_id, NULL::bigint, 'user',
          'engagement.' || p_kind, NULL::text, NULL::text, NULL::bigint, p_now, NULL::uuid,
          NULL::smallint, NULL::text, NULL::text, NULL::text, NULL::text,
          jsonb_build_object('decision_grade', 'reliable', 'engagement', v_engagement,
            'inbox_item_id', p_item.id),
          NULL::text) a;
      IF v_result IN ('applied', 'stale_ignored', 'conflict_flagged') THEN
        SELECT * INTO v_delivery FROM relay.deliveries d
          WHERE d.tenant_id = p_item.tenant_id AND d.environment = p_item.environment
            AND d.id = p_item.delivery_id;
        PERFORM relay_private.engagement_announce(v_delivery, p_kind,
          CASE WHEN p_kind = 'clicked' THEN 'inbox' END, p_now);
      END IF;
    END
    $fn$
    """
  end

  defp bulk_apply do
    """
    CREATE FUNCTION relay_private.inbox_bulk_apply(p_tenant uuid, p_env relay.environment,
      p_recipient uuid, p_ids uuid[], p_action text, p_now timestamptz)
      RETURNS TABLE (changed bigint, notification_ids uuid[])
    LANGUAGE plpgsql VOLATILE
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_now timestamptz := p_now;
      v_ids uuid[];
      v_count bigint;
      v_stream text;
      v_epoch bigint;
      v_first bigint;
      v_offset bigint := 0;
      v_item relay.inbox_items;
      v_notifications uuid[] := ARRAY[]::uuid[];
    BEGIN
      IF p_action IS NULL OR p_action NOT IN ('read', 'archive', 'hide') THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'IN-14';
      END IF;
      SELECT COALESCE(array_agg(i.id ORDER BY i.id), ARRAY[]::uuid[]) INTO v_ids
        FROM relay.inbox_items i
        WHERE i.tenant_id = p_tenant AND i.environment = p_env AND i.recipient_id = p_recipient
          AND i.id = ANY (COALESCE(p_ids, ARRAY[]::uuid[])) AND i.hidden_at IS NULL
          AND CASE p_action
            WHEN 'read' THEN NOT #{@read}
            WHEN 'archive' THEN NOT #{@archived}
            ELSE true END;
      v_count := cardinality(v_ids);
      IF v_count = 0 THEN
        RETURN QUERY SELECT 0::bigint, v_notifications;
        RETURN;
      END IF;
      v_stream := relay_private.inbox_stream(p_tenant, p_env, p_recipient);
      SELECT n.epoch, n.seq INTO v_epoch, v_first FROM relay_fn.stream_next_seq(v_stream) n;
      IF v_count > 1 THEN
        UPDATE relay.stream_heads h SET last_seq = h.last_seq + v_count - 1, updated_at = now()
          WHERE h.tenant_id = p_tenant AND h.environment = p_env AND h.stream_key = v_stream;
      END IF;
      FOR v_item IN
        SELECT * FROM relay.inbox_items i
        WHERE i.tenant_id = p_tenant AND i.environment = p_env AND i.recipient_id = p_recipient
          AND i.id = ANY (v_ids)
        ORDER BY i.id
      LOOP
        CASE p_action
          WHEN 'read' THEN
            v_item.read_at := GREATEST(p_now, v_item.last_activity_at,
              v_item.unread_marked_at + interval '1 microsecond');
            v_item.seen_at := GREATEST(v_item.seen_at, v_item.read_at);
          WHEN 'archive' THEN
            v_item.archived_at := GREATEST(p_now, v_item.unarchived_at + interval '1 microsecond');
          ELSE
            v_item.hidden_at := p_now;
            v_item.hidden_reason := 'user';
        END CASE;
        UPDATE relay.inbox_items i SET read_at = v_item.read_at, seen_at = v_item.seen_at,
            archived_at = v_item.archived_at, hidden_at = v_item.hidden_at,
            hidden_reason = v_item.hidden_reason, state_version = i.state_version + 1,
            change_epoch = v_epoch, change_seq = v_first + v_offset, updated_at = p_now
          WHERE i.tenant_id = p_tenant AND i.environment = p_env
            AND i.recipient_id = p_recipient AND i.id = v_item.id;
        v_offset := v_offset + 1;
        IF p_action = 'read' THEN
          PERFORM relay_private.inbox_engage(v_item, 'read', p_now);
          v_notifications := v_notifications || v_item.notification_id;
        ELSIF p_action = 'archive' THEN
          PERFORM relay_private.inbox_engage(v_item, 'archived', p_now);
        END IF;
      END LOOP;
      RETURN QUERY SELECT v_count, v_notifications;
    END
    $fn$
    """
  end

  defp bulk_publish do
    ~S"""
    CREATE FUNCTION relay_private.inbox_bulk_publish(p_tenant uuid, p_env relay.environment,
      p_recipient uuid, p_scope text, p_action text, p_count bigint, p_version bigint)
      RETURNS void
    LANGUAGE plpgsql VOLATILE
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_stream text := relay_private.inbox_stream(p_tenant, p_env, p_recipient);
    BEGIN
      PERFORM relay_fn.outbox_append(uuidv7(), 'inbox.items_bulk_updated', v_stream,
        jsonb_build_object('recipient_id', p_recipient, 'scope', p_scope, 'action', p_action,
          'count', p_count, 'counters_version', p_version), NULL);
      PERFORM relay_fn.outbox_append(uuidv7(), 'inbox.counters_changed', v_stream,
        jsonb_build_object('recipient_id', p_recipient, 'counters_version', p_version), NULL);
    END
    $fn$
    """
  end

  defp read_all do
    """
    CREATE FUNCTION relay_fn.inbox_read_all(p_recipient_id uuid, p_category text)
      RETURNS TABLE (result text, updated bigint, counters_version bigint,
        notification_ids uuid[], cut_off timestamptz)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_now timestamptz;
      v_ids uuid[];
      v_count bigint;
      v_notifications uuid[];
      v_version bigint;
    BEGIN
      IF p_recipient_id IS NULL
        OR (p_category IS NOT NULL AND char_length(p_category) NOT BETWEEN 1 AND 128) THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'IN-50';
      END IF;
      PERFORM relay_private.inbox_lock(v_tenant, v_env, p_recipient_id);
      v_now := clock_timestamp();
      SELECT COALESCE(array_agg(i.id), ARRAY[]::uuid[]) INTO v_ids FROM relay.inbox_items i
        WHERE i.tenant_id = v_tenant AND i.environment = v_env AND i.recipient_id = p_recipient_id
          AND #{@live} AND #{@awake} AND NOT #{@archived} AND NOT #{@read}
          AND (p_category IS NULL OR i.category = p_category)
          AND i.last_activity_at <= v_now;
      SELECT b.changed, b.notification_ids INTO v_count, v_notifications
        FROM relay_private.inbox_bulk_apply(v_tenant, v_env, p_recipient_id, v_ids, 'read', v_now) b;
      INSERT INTO relay.inbox_read_marks AS m (tenant_id, environment, id, recipient_id, category,
        read_through, created_at, updated_at)
      VALUES (v_tenant, v_env, uuidv7(), p_recipient_id, p_category, v_now, v_now, v_now)
      ON CONFLICT ON CONSTRAINT inbox_read_marks_scope_key
        DO UPDATE SET read_through = GREATEST(m.read_through, EXCLUDED.read_through),
          updated_at = EXCLUDED.updated_at;
      SELECT r.version INTO v_version
        FROM relay_private.inbox_recount(v_tenant, v_env, p_recipient_id, v_now, true) r;
      PERFORM relay_private.inbox_bulk_publish(v_tenant, v_env, p_recipient_id,
        CASE WHEN p_category IS NULL THEN 'all' ELSE 'category:' || p_category END, 'read',
        v_count, v_version);
      RETURN QUERY SELECT 'applied'::text, v_count, v_version, v_notifications, v_now;
    END
    $fn$
    """
  end

  defp bulk_start do
    ~S"""
    CREATE FUNCTION relay_fn.inbox_bulk_start(p_id uuid, p_recipient_id uuid, p_action text,
      p_status text, p_category text, p_tag text)
      RETURNS TABLE (result text, cut_off timestamptz)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_now timestamptz := clock_timestamp();
    BEGIN
      IF p_recipient_id IS NULL OR p_action IS NULL OR p_action NOT IN ('read', 'archive', 'hide')
        OR p_status IS NULL
        OR p_status NOT IN ('inbox', 'unread', 'archived', 'snoozed', 'all') THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'IN-14';
      END IF;
      PERFORM relay_private.assert_new_id(p_id);
      INSERT INTO relay.inbox_bulk_operations (tenant_id, environment, id, recipient_id, action,
        status_filter, category, tag, cut_off, state, after_id, matched_count, updated_count,
        chunk_count, created_at, updated_at, completed_at)
      VALUES (v_tenant, v_env, p_id, p_recipient_id, p_action, p_status, p_category, p_tag, v_now,
        'running', NULL, 0, 0, 0, v_now, v_now, NULL);
      RETURN QUERY SELECT 'created'::text, v_now;
    END
    $fn$
    """
  end

  defp bulk_chunk do
    """
    CREATE FUNCTION relay_fn.inbox_bulk_chunk(p_operation_id uuid, p_limit integer)
      RETURNS TABLE (result text, recipient_id uuid, changed bigint, counters_version bigint,
        notification_ids uuid[])
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_op relay.inbox_bulk_operations;
      v_now timestamptz;
      v_ids uuid[];
      v_matched bigint;
      v_count bigint;
      v_notifications uuid[];
      v_version bigint;
      v_done boolean;
    BEGIN
      IF p_operation_id IS NULL OR p_limit IS NULL OR p_limit < 1 THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'IN-14';
      END IF;
      SELECT * INTO v_op FROM relay.inbox_bulk_operations o
        WHERE o.tenant_id = v_tenant AND o.environment = v_env AND o.id = p_operation_id;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, NULL::uuid, 0::bigint, NULL::bigint,
          ARRAY[]::uuid[];
        RETURN;
      END IF;
      PERFORM relay_private.inbox_lock(v_tenant, v_env, v_op.recipient_id);
      SELECT * INTO v_op FROM relay.inbox_bulk_operations o
        WHERE o.tenant_id = v_tenant AND o.environment = v_env AND o.id = p_operation_id;
      IF v_op.state = 'completed' THEN
        RETURN QUERY SELECT 'already_completed'::text, v_op.recipient_id, 0::bigint, NULL::bigint,
          ARRAY[]::uuid[];
        RETURN;
      END IF;
      v_now := clock_timestamp();
      SELECT COALESCE(array_agg(c.id ORDER BY c.id DESC), ARRAY[]::uuid[]) INTO v_ids
        FROM (
          SELECT i.id FROM relay.inbox_items i
          WHERE i.tenant_id = v_tenant AND i.environment = v_env
            AND i.recipient_id = v_op.recipient_id AND i.created_at <= v_op.cut_off
            AND (v_op.after_id IS NULL OR i.id < v_op.after_id)
            AND (v_op.category IS NULL OR i.category = v_op.category)
            AND (v_op.tag IS NULL OR v_op.tag = ANY (i.tags))
            AND CASE v_op.status_filter
              WHEN 'inbox' THEN #{@live} AND #{@awake} AND NOT #{@archived}
              WHEN 'unread' THEN #{@live} AND #{@awake} AND NOT #{@archived} AND NOT #{@read}
              WHEN 'archived' THEN #{@live} AND #{@archived}
              WHEN 'snoozed' THEN #{@live} AND NOT #{@awake}
              ELSE #{@live} END
          ORDER BY i.id DESC
          LIMIT p_limit
        ) c;
      v_matched := cardinality(v_ids);
      SELECT b.changed, b.notification_ids INTO v_count, v_notifications
        FROM relay_private.inbox_bulk_apply(v_tenant, v_env, v_op.recipient_id, v_ids,
          v_op.action, v_now) b;
      IF v_count > 0 THEN
        SELECT r.version INTO v_version
          FROM relay_private.inbox_recount(v_tenant, v_env, v_op.recipient_id, v_now, false) r;
        PERFORM relay_private.inbox_bulk_publish(v_tenant, v_env, v_op.recipient_id, 'filter',
          v_op.action, v_count, v_version);
      END IF;
      v_done := v_matched < p_limit;
      UPDATE relay.inbox_bulk_operations o
        SET after_id = COALESCE(v_ids[v_matched], o.after_id),
          matched_count = o.matched_count + v_matched, updated_count = o.updated_count + v_count,
          chunk_count = o.chunk_count + 1,
          state = CASE WHEN v_done THEN 'completed' ELSE o.state END,
          completed_at = CASE WHEN v_done THEN v_now END, updated_at = v_now
        WHERE o.tenant_id = v_tenant AND o.environment = v_env AND o.id = p_operation_id;
      RETURN QUERY SELECT CASE WHEN v_done THEN 'completed' ELSE 'chunk' END,
        v_op.recipient_id, v_count, v_version, v_notifications;
    END
    $fn$
    """
  end

  defp engage do
    ~S"""
    CREATE FUNCTION relay_fn.inbox_engage(p_recipient_id uuid, p_item_id uuid, p_kind text)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_item relay.inbox_items;
    BEGIN
      IF p_recipient_id IS NULL OR p_item_id IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'DS-7';
      END IF;
      SELECT * INTO v_item FROM relay.inbox_items i
        WHERE i.tenant_id = v_tenant AND i.environment = v_env
          AND i.recipient_id = p_recipient_id AND i.id = p_item_id;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      PERFORM relay_private.inbox_engage(v_item, p_kind, clock_timestamp());
      RETURN 'recorded';
    END
    $fn$
    """
  end

  defp reconcile do
    ~S"""
    CREATE FUNCTION relay_fn.inbox_reconcile(p_recipient_id uuid)
      RETURNS TABLE (result text, counters_version bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_now timestamptz;
      v_drift boolean;
      v_version bigint;
    BEGIN
      IF p_recipient_id IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'IN-21';
      END IF;
      PERFORM relay_private.inbox_lock(v_tenant, v_env, p_recipient_id);
      v_now := clock_timestamp();
      SELECT r.drifted, r.version INTO v_drift, v_version
        FROM relay_private.inbox_recount(v_tenant, v_env, p_recipient_id, v_now, false) r;
      IF v_drift THEN
        PERFORM relay_fn.outbox_append(uuidv7(), 'inbox.counters_changed',
          relay_private.inbox_stream(v_tenant, v_env, p_recipient_id),
          jsonb_build_object('recipient_id', p_recipient_id, 'counters_version', v_version), NULL);
      END IF;
      RETURN QUERY SELECT CASE WHEN v_drift THEN 'repaired' ELSE 'consistent' END, v_version;
    END
    $fn$
    """
  end

  defp reconcile_changed do
    ~S"""
    CREATE FUNCTION relay_fn.inbox_reconcile_changed(p_since timestamptz, p_after uuid,
      p_limit integer)
      RETURNS TABLE (result text, checked bigint, repaired bigint, last_recipient_id uuid)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_recipient uuid;
      v_last uuid;
      v_checked bigint := 0;
      v_repaired bigint := 0;
      v_drift boolean;
      v_version bigint;
    BEGIN
      IF p_since IS NULL OR p_limit IS NULL OR p_limit < 1 THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'IN-18';
      END IF;
      FOR v_recipient IN
        SELECT DISTINCT s.recipient_id FROM (
          SELECT c.recipient_id FROM relay.inbox_counters c
          WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.updated_at >= p_since
          UNION
          SELECT i.recipient_id FROM relay.inbox_items i
          WHERE i.tenant_id = v_tenant AND i.environment = v_env AND i.updated_at >= p_since
        ) s
        WHERE p_after IS NULL OR s.recipient_id > p_after
        ORDER BY s.recipient_id
        LIMIT p_limit
      LOOP
        PERFORM relay_private.inbox_lock(v_tenant, v_env, v_recipient);
        SELECT r.drifted, r.version INTO v_drift, v_version
          FROM relay_private.inbox_recount(v_tenant, v_env, v_recipient, clock_timestamp(),
            false) r;
        IF v_drift THEN
          PERFORM relay_fn.outbox_append(uuidv7(), 'inbox.counters_changed',
            relay_private.inbox_stream(v_tenant, v_env, v_recipient),
            jsonb_build_object('recipient_id', v_recipient, 'counters_version', v_version), NULL);
          v_repaired := v_repaired + 1;
        END IF;
        v_checked := v_checked + 1;
        v_last := v_recipient;
      END LOOP;
      RETURN QUERY SELECT 'checked'::text, v_checked, v_repaired, v_last;
    END
    $fn$
    """
  end

  defp trim do
    """
    CREATE FUNCTION relay_fn.inbox_trim(p_recipient_id uuid, p_visible_max bigint)
      RETURNS TABLE (result text, retired bigint, counters_version bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_now timestamptz;
      v_item relay.inbox_items;
      v_count bigint := 0;
      v_version bigint;
    BEGIN
      IF p_recipient_id IS NULL OR p_visible_max IS NULL OR p_visible_max < 1 THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'IN-44';
      END IF;
      PERFORM relay_private.inbox_lock(v_tenant, v_env, p_recipient_id);
      v_now := clock_timestamp();
      FOR v_item IN
        SELECT * FROM relay.inbox_items i
        WHERE i.tenant_id = v_tenant AND i.environment = v_env AND i.recipient_id = p_recipient_id
          AND #{@live} AND #{@awake} AND NOT #{@archived}
        ORDER BY i.last_activity_at DESC, i.id DESC
        OFFSET p_visible_max
      LOOP
        v_item.hidden_at := v_now;
        v_item.hidden_reason := 'retention';
        v_item.state_version := v_item.state_version + 1;
        v_version := relay_private.inbox_commit(v_item, false, v_now, 'inbox.item_updated', NULL);
        v_count := v_count + 1;
      END LOOP;
      IF v_count = 0 THEN
        SELECT c.version INTO v_version FROM relay.inbox_counters c
          WHERE c.tenant_id = v_tenant AND c.environment = v_env
            AND c.recipient_id = p_recipient_id;
      END IF;
      RETURN QUERY SELECT CASE WHEN v_count > 0 THEN 'trimmed' ELSE 'within' END, v_count,
        COALESCE(v_version, 0);
    END
    $fn$
    """
  end

  defp retire_due do
    """
    CREATE FUNCTION relay_fn.inbox_retire_due(p_active_days bigint, p_archive_days bigint,
      p_limit integer)
      RETURNS TABLE (result text, retired bigint, recipient_ids uuid[])
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_now timestamptz := clock_timestamp();
      v_ref record;
      v_item relay.inbox_items;
      v_count bigint := 0;
      v_recipients uuid[] := ARRAY[]::uuid[];
    BEGIN
      IF p_active_days IS NULL OR p_active_days < 1 OR p_archive_days IS NULL
        OR p_archive_days < 1 OR p_limit IS NULL OR p_limit < 1 THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'IN-44';
      END IF;
      FOR v_ref IN
        SELECT i.recipient_id, i.id FROM relay.inbox_items i
        WHERE i.tenant_id = v_tenant AND i.environment = v_env AND i.retired_at IS NULL
          AND i.last_activity_at < v_now - LEAST(p_active_days, p_archive_days) * interval '1 day'
          AND ((NOT #{@archived}
              AND i.last_activity_at < v_now - p_active_days * interval '1 day')
            OR (#{@archived} AND i.archived_at < v_now - p_archive_days * interval '1 day'))
        ORDER BY i.recipient_id, i.id
        LIMIT p_limit
      LOOP
        PERFORM relay_private.inbox_lock(v_tenant, v_env, v_ref.recipient_id);
        SELECT * INTO v_item FROM relay.inbox_items i
          WHERE i.tenant_id = v_tenant AND i.environment = v_env
            AND i.recipient_id = v_ref.recipient_id AND i.id = v_ref.id AND i.retired_at IS NULL;
        IF FOUND THEN
          IF v_item.hidden_at IS NULL THEN
            v_item.hidden_at := v_now;
            v_item.hidden_reason := 'retention';
          END IF;
          v_item.content_ct := NULL;
          v_item.state_version := v_item.state_version + 1;
          PERFORM relay_private.inbox_commit(v_item, false, v_now, 'inbox.item_updated', NULL);
          UPDATE relay.inbox_items i SET retired_at = v_now
            WHERE i.tenant_id = v_tenant AND i.environment = v_env
              AND i.recipient_id = v_item.recipient_id AND i.id = v_item.id;
          v_count := v_count + 1;
          IF NOT v_item.recipient_id = ANY (v_recipients) THEN
            v_recipients := v_recipients || v_item.recipient_id;
          END IF;
        END IF;
      END LOOP;
      RETURN QUERY SELECT CASE WHEN v_count > 0 THEN 'retired' ELSE 'none_due' END, v_count,
        v_recipients;
    END
    $fn$
    """
  end

  defp announcement_create do
    ~S"""
    CREATE FUNCTION relay_fn.inbox_announcement_create(p_id uuid, p_audience text,
      p_subtenant_id uuid, p_topic_key text, p_category text, p_tags text[], p_severity text,
      p_content jsonb, p_locale text, p_dir text, p_expires_at timestamptz,
      p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
      p_access_record_ref text)
      RETURNS TABLE (result text, announcement_id uuid, change_seq bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_now timestamptz;
      v_topic uuid;
      v_seq bigint;
    BEGIN
      IF relay_private.tenant_status() <> 'active' THEN
        RETURN QUERY SELECT 'tenant_inactive'::text, NULL::uuid, NULL::bigint;
        RETURN;
      END IF;
      IF p_audience IS NULL OR p_audience NOT IN ('tenant', 'subtenant', 'topic')
        OR (p_audience = 'subtenant') <> (p_subtenant_id IS NOT NULL)
        OR (p_audience = 'topic') <> (p_topic_key IS NOT NULL)
        OR p_content IS NULL OR jsonb_typeof(p_content) <> 'object'
        OR (p_tags IS NOT NULL AND cardinality(p_tags) > 10) OR p_record_digest IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'IN-3';
      END IF;
      PERFORM relay_private.lock_scope(ARRAY['inbox_announcements']);
      v_now := clock_timestamp();
      IF p_expires_at IS NOT NULL AND p_expires_at <= v_now THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'IN-17';
      END IF;
      IF p_audience = 'subtenant' AND NOT EXISTS (SELECT 1 FROM relay.subtenants s
        WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = p_subtenant_id
          AND s.state = 'active') THEN
        RETURN QUERY SELECT 'subtenant_not_found'::text, NULL::uuid, NULL::bigint;
        RETURN;
      END IF;
      IF p_audience = 'topic' THEN
        SELECT t.id INTO v_topic FROM relay.topics t
          WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.key = p_topic_key
            AND t.state = 'active';
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'topic_not_found'::text, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
      END IF;
      PERFORM relay_private.assert_new_id(p_id);
      SELECT COALESCE(max(a.change_seq), 0) + 1 INTO v_seq FROM relay.inbox_announcements a
        WHERE a.tenant_id = v_tenant AND a.environment = v_env;
      INSERT INTO relay.inbox_announcements (tenant_id, environment, id, audience, subtenant_id,
        topic_id, category, tags, severity, content, locale, dir, state, published_at, expires_at,
        closed_at, change_seq, version, created_at, updated_at)
      VALUES (v_tenant, v_env, p_id, p_audience, p_subtenant_id, v_topic, p_category,
        COALESCE(p_tags, ARRAY[]::text[]), p_severity, p_content, p_locale, p_dir, 'active', v_now,
        p_expires_at, NULL, v_seq, 1, v_now, v_now);
      PERFORM relay_private.audit_write(v_tenant, v_env::text, 'inbox_announcement.published',
        p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'inbox_announcement',
        p_id::text, NULL, p_record_digest);
      RETURN QUERY SELECT 'created'::text, p_id, v_seq;
    END
    $fn$
    """
  end

  defp announcement_retract do
    ~S"""
    CREATE FUNCTION relay_fn.inbox_announcement_retract(p_announcement_id uuid,
      p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
      p_access_record_ref text)
      RETURNS TABLE (result text, change_seq bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_announcement relay.inbox_announcements;
      v_seq bigint;
    BEGIN
      IF p_announcement_id IS NULL OR p_record_digest IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'IN-16';
      END IF;
      PERFORM relay_private.lock_scope(ARRAY['inbox_announcements']);
      SELECT * INTO v_announcement FROM relay.inbox_announcements a
        WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = p_announcement_id;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
        RETURN;
      END IF;
      IF v_announcement.state <> 'active' THEN
        RETURN QUERY SELECT 'already_closed'::text, v_announcement.change_seq;
        RETURN;
      END IF;
      SELECT COALESCE(max(a.change_seq), 0) + 1 INTO v_seq FROM relay.inbox_announcements a
        WHERE a.tenant_id = v_tenant AND a.environment = v_env;
      UPDATE relay.inbox_announcements a SET state = 'retracted', closed_at = clock_timestamp(),
          change_seq = v_seq, version = a.version + 1, updated_at = clock_timestamp()
        WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = p_announcement_id;
      PERFORM relay_private.audit_write(v_tenant, v_env::text, 'inbox_announcement.retracted',
        p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'inbox_announcement',
        p_announcement_id::text, NULL, p_record_digest);
      RETURN QUERY SELECT 'retracted'::text, v_seq;
    END
    $fn$
    """
  end

  defp announcement_expire do
    ~S"""
    CREATE FUNCTION relay_fn.inbox_announcement_expire(p_announcement_id uuid)
      RETURNS TABLE (result text, change_seq bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_announcement relay.inbox_announcements;
      v_seq bigint;
    BEGIN
      IF p_announcement_id IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'IN-17';
      END IF;
      PERFORM relay_private.lock_scope(ARRAY['inbox_announcements']);
      SELECT * INTO v_announcement FROM relay.inbox_announcements a
        WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = p_announcement_id;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
        RETURN;
      END IF;
      IF v_announcement.state <> 'active' THEN
        RETURN QUERY SELECT 'already_closed'::text, v_announcement.change_seq;
        RETURN;
      END IF;
      IF v_announcement.expires_at IS NULL OR v_announcement.expires_at > clock_timestamp() THEN
        RETURN QUERY SELECT 'not_due'::text, v_announcement.change_seq;
        RETURN;
      END IF;
      SELECT COALESCE(max(a.change_seq), 0) + 1 INTO v_seq FROM relay.inbox_announcements a
        WHERE a.tenant_id = v_tenant AND a.environment = v_env;
      UPDATE relay.inbox_announcements a SET state = 'expired', closed_at = clock_timestamp(),
          change_seq = v_seq, version = a.version + 1, updated_at = clock_timestamp()
        WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = p_announcement_id;
      RETURN QUERY SELECT 'expired'::text, v_seq;
    END
    $fn$
    """
  end

  defp announcement_intent do
    """
    CREATE FUNCTION relay_fn.inbox_announcement_intent(p_recipient_id uuid,
      p_announcement_id uuid, p_op text, p_base_state_version bigint)
      RETURNS TABLE (result text, state_version bigint, counters_version bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_now timestamptz;
      v_announcement relay.inbox_announcements;
      v_state relay.inbox_announcement_states;
      v_found boolean;
      v_mark timestamptz;
      v_read_at timestamptz;
      v_read boolean;
      v_seen boolean;
      v_archived boolean;
      v_current bigint;
      v_changed boolean := false;
      v_version bigint;
      v_epoch bigint;
      v_seq bigint;
    BEGIN
      IF p_recipient_id IS NULL OR p_announcement_id IS NULL OR p_op IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'IN-12';
      END IF;
      PERFORM relay_private.inbox_lock(v_tenant, v_env, p_recipient_id);
      v_now := clock_timestamp();
      SELECT * INTO v_announcement FROM relay.inbox_announcements a
        WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = p_announcement_id
          AND a.state = 'active' AND (a.expires_at IS NULL OR a.expires_at > v_now)
          AND #{@visible};
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, NULL::bigint, NULL::bigint;
        RETURN;
      END IF;
      SELECT c.version INTO v_version FROM relay.inbox_counters c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.recipient_id = p_recipient_id;
      v_version := COALESCE(v_version, 0);
      SELECT * INTO v_state FROM relay.inbox_announcement_states s
        WHERE s.tenant_id = v_tenant AND s.environment = v_env
          AND s.announcement_id = p_announcement_id AND s.recipient_id = p_recipient_id;
      v_found := FOUND;
      v_current := CASE WHEN v_found THEN v_state.state_version ELSE 1 END;
      IF p_op NOT IN ('seen', 'read', 'unread', 'archive', 'unarchive', 'hide') THEN
        RETURN QUERY SELECT 'invalid'::text, v_current, v_version;
        RETURN;
      END IF;
      IF p_op IN ('unread', 'unarchive') AND p_base_state_version IS DISTINCT FROM v_current THEN
        RETURN QUERY SELECT 'conflict'::text, v_current, v_version;
        RETURN;
      END IF;
      IF v_state.hidden_at IS NOT NULL THEN
        RETURN QUERY SELECT 'unchanged'::text, v_current, v_version;
        RETURN;
      END IF;
      SELECT max(m.read_through) INTO v_mark FROM relay.inbox_read_marks m
        WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.recipient_id = p_recipient_id
          AND (m.category IS NULL OR m.category = v_announcement.category)
          AND m.read_through >= v_announcement.published_at;
      v_read_at := GREATEST(v_state.read_at, v_mark);
      v_read := v_read_at IS NOT NULL
        AND (v_state.unread_marked_at IS NULL OR v_read_at > v_state.unread_marked_at);
      v_seen := v_state.seen_at IS NOT NULL OR v_read_at IS NOT NULL;
      v_archived := v_state.archived_at IS NOT NULL
        AND (v_state.unarchived_at IS NULL OR v_state.archived_at > v_state.unarchived_at);
      CASE p_op
        WHEN 'seen' THEN
          IF NOT v_seen THEN
            v_state.seen_at := v_now;
            v_changed := true;
          END IF;
        WHEN 'read' THEN
          IF NOT v_read THEN
            v_state.read_at := GREATEST(v_now, v_state.unread_marked_at + interval '1 microsecond');
            v_state.seen_at := COALESCE(v_state.seen_at, v_state.read_at);
            v_changed := true;
          END IF;
        WHEN 'unread' THEN
          IF v_read THEN
            v_state.unread_marked_at := GREATEST(v_now, v_read_at + interval '1 microsecond');
            v_changed := true;
          END IF;
        WHEN 'archive' THEN
          IF NOT v_archived THEN
            v_state.archived_at := GREATEST(v_now,
              v_state.unarchived_at + interval '1 microsecond');
            v_changed := true;
          END IF;
        WHEN 'unarchive' THEN
          IF v_archived THEN
            v_state.unarchived_at := GREATEST(v_now,
              v_state.archived_at + interval '1 microsecond');
            v_changed := true;
          END IF;
        WHEN 'hide' THEN
          v_state.hidden_at := v_now;
          v_changed := true;
      END CASE;
      IF NOT v_changed THEN
        RETURN QUERY SELECT 'unchanged'::text, v_current, v_version;
        RETURN;
      END IF;
      UPDATE relay.inbox_counters c SET version = c.version + 1, updated_at = v_now
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.recipient_id = p_recipient_id
        RETURNING c.version INTO v_version;
      IF NOT FOUND THEN
        INSERT INTO relay.inbox_counters (tenant_id, environment, recipient_id, unseen_count,
          unread_count, total_count, version, updated_at)
        VALUES (v_tenant, v_env, p_recipient_id, 0, 0, 0, 1, v_now);
        v_version := 1;
      END IF;
      SELECT o.epoch, o.seq INTO v_epoch, v_seq
        FROM relay_fn.outbox_append(uuidv7(), 'inbox.item_updated',
          relay_private.inbox_stream(v_tenant, v_env, p_recipient_id),
          jsonb_build_object('announcement_id', p_announcement_id, 'recipient_id', p_recipient_id,
            'state_version', v_current + 1, 'counters_version', v_version), NULL) o;
      IF v_found THEN
        UPDATE relay.inbox_announcement_states s SET seen_at = v_state.seen_at,
            read_at = v_state.read_at, unread_marked_at = v_state.unread_marked_at,
            archived_at = v_state.archived_at, unarchived_at = v_state.unarchived_at,
            hidden_at = v_state.hidden_at, state_version = v_current + 1, change_epoch = v_epoch,
            change_seq = v_seq, updated_at = v_now
          WHERE s.tenant_id = v_tenant AND s.environment = v_env
            AND s.announcement_id = p_announcement_id AND s.recipient_id = p_recipient_id;
      ELSE
        INSERT INTO relay.inbox_announcement_states (tenant_id, environment, announcement_id,
          recipient_id, seen_at, read_at, unread_marked_at, archived_at, unarchived_at, hidden_at,
          state_version, change_epoch, change_seq, created_at, updated_at)
        VALUES (v_tenant, v_env, p_announcement_id, p_recipient_id, v_state.seen_at,
          v_state.read_at, v_state.unread_marked_at, v_state.archived_at, v_state.unarchived_at,
          v_state.hidden_at, v_current + 1, v_epoch, v_seq, v_now, v_now);
      END IF;
      RETURN QUERY SELECT 'applied'::text, v_current + 1, v_version;
    END
    $fn$
    """
  end
end
