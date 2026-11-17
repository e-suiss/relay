defmodule Relay.Repo.Migrations.CreateRecordFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"
  @functions [
    {"relay_fn.inbox_takedown(uuid, boolean)", "relay_owner", ~w(relay_app)},
    {"relay_fn.takedown_apply(uuid, text, uuid, text, bytea, #{@actor})", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.takedown_lift(uuid, text, bytea, #{@actor})", "relay_owner", ~w(relay_app)}
  ]
  @triggers ~w(notification_retention_class delivery_retention_class dsr_log_record)

  # OP-19
  # OP-24
  # DS-44
  # TN-60
  # OP-8
  def up do
    Enum.each(statements(), &execute/1)

    for {signature, owner, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
    end

    for name <- @triggers,
        do: execute("REVOKE ALL ON FUNCTION relay_private.#{name}() FROM PUBLIC")

    Enum.each(triggers(), &execute/1)

    execute("DROP FUNCTION relay_ops.retention_due(integer)")
    execute(retention_due())
    execute("REVOKE ALL ON FUNCTION relay_ops.retention_due(integer) FROM PUBLIC")

    execute("SET LOCAL ROLE relay_owner")
    execute(subject_erase())
    execute("RESET ROLE")
  end

  def down, do: :ok

  defp statements do
    [
      notification_retention_class(),
      delivery_retention_class(),
      dsr_log_record(),
      inbox_takedown(),
      takedown_apply(),
      takedown_lift()
    ]
  end

  defp triggers do
    [
      """
      CREATE TRIGGER notifications_retention_class BEFORE INSERT ON relay.notifications
        FOR EACH ROW EXECUTE FUNCTION relay_private.notification_retention_class()
      """,
      """
      CREATE TRIGGER deliveries_retention_class BEFORE INSERT ON relay.deliveries
        FOR EACH ROW EXECUTE FUNCTION relay_private.delivery_retention_class()
      """,
      """
      CREATE TRIGGER recipient_deletion_requests_dsr_request
        AFTER INSERT ON relay.recipient_deletion_requests
        FOR EACH ROW EXECUTE FUNCTION relay_private.dsr_log_record()
      """,
      """
      CREATE TRIGGER recipient_deletion_requests_dsr_answer
        AFTER UPDATE OF status ON relay.recipient_deletion_requests
        FOR EACH ROW WHEN (OLD.status = 'pending' AND NEW.status IN ('completed', 'held'))
        EXECUTE FUNCTION relay_private.dsr_log_record()
      """
    ]
  end

  defp notification_retention_class do
    ~S"""
    CREATE FUNCTION relay_private.notification_retention_class() RETURNS trigger
      LANGUAGE plpgsql
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
    AS $fn$
    BEGIN
      NEW.retention_class := CASE WHEN NEW.message_class = 'marketing' THEN 'commercial_message'
        ELSE 'delivery_record' END;
      RETURN NEW;
    END
    $fn$
    """
  end

  defp delivery_retention_class do
    ~S"""
    CREATE FUNCTION relay_private.delivery_retention_class() RETURNS trigger
      LANGUAGE plpgsql
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_class text;
    BEGIN
      SELECT COALESCE(n.retention_class, CASE WHEN n.message_class = 'marketing'
          THEN 'commercial_message' ELSE 'delivery_record' END) INTO v_class
        FROM relay.notifications n
        WHERE n.tenant_id = NEW.tenant_id AND n.environment = NEW.environment
          AND n.id = NEW.notification_id;
      NEW.retention_class := COALESCE(v_class, 'delivery_record');
      RETURN NEW;
    END
    $fn$
    """
  end

  defp dsr_log_record do
    ~S"""
    CREATE FUNCTION relay_private.dsr_log_record() RETURNS trigger
      LANGUAGE plpgsql
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
    AS $fn$
    BEGIN
      INSERT INTO relay.dsr_log (tenant_id, environment, id, recipient_id, request_id,
        request_kind, entry, outcome, retention_class, created_at)
      VALUES (NEW.tenant_id, NEW.environment, uuidv7(), NEW.recipient_id, NEW.id, 'erasure',
        CASE WHEN TG_OP = 'INSERT' THEN 'request' ELSE 'answer' END,
        CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE NEW.status END, 'dsr_log', now());
      RETURN NULL;
    END
    $fn$
    """
  end

  defp inbox_takedown do
    ~S"""
    CREATE FUNCTION relay_fn.inbox_takedown(p_notification_id uuid, p_hidden boolean)
      RETURNS TABLE (result text, changed bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_ref record;
      v_item relay.inbox_items;
      v_now timestamptz;
      v_count bigint := 0;
    BEGIN
      IF p_notification_id IS NULL OR p_hidden IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-60';
      END IF;
      FOR v_ref IN
        SELECT DISTINCT x.recipient_id, x.item_id
        FROM relay.deliveries d
        JOIN relay.inbox_item_deliveries x ON x.tenant_id = d.tenant_id
          AND x.environment = d.environment AND x.delivery_id = d.id
        JOIN relay.recipients r ON r.tenant_id = x.tenant_id AND r.environment = x.environment
          AND r.id = x.recipient_id
        WHERE d.tenant_id = v_tenant AND d.environment = v_env
          AND d.notification_id = p_notification_id AND r.state <> 'deleted'
        ORDER BY x.recipient_id, x.item_id
      LOOP
        PERFORM relay_private.inbox_lock(v_tenant, v_env, v_ref.recipient_id);
        v_now := clock_timestamp();
        SELECT * INTO v_item FROM relay.inbox_items i
          WHERE i.tenant_id = v_tenant AND i.environment = v_env
            AND i.recipient_id = v_ref.recipient_id AND i.id = v_ref.item_id;
        IF FOUND AND p_hidden AND v_item.hidden_at IS NULL THEN
          v_item.hidden_at := v_now;
          v_item.hidden_reason := 'takedown';
          v_item.state_version := v_item.state_version + 1;
          PERFORM relay_private.inbox_commit(v_item, false, v_now, 'inbox.item_updated', NULL);
          v_count := v_count + 1;
        ELSIF FOUND AND NOT p_hidden AND v_item.hidden_reason = 'takedown' THEN
          v_item.hidden_at := NULL;
          v_item.hidden_reason := NULL;
          v_item.state_version := v_item.state_version + 1;
          PERFORM relay_private.inbox_commit(v_item, false, v_now, 'inbox.item_updated', NULL);
          v_count := v_count + 1;
        END IF;
      END LOOP;
      IF p_hidden THEN
        RETURN QUERY SELECT 'hidden'::text, v_count;
      ELSE
        RETURN QUERY SELECT 'restored'::text, v_count;
      END IF;
    END
    $fn$
    """
  end

  defp takedown_apply do
    ~S"""
    CREATE FUNCTION relay_fn.takedown_apply(p_id uuid, p_target_kind text, p_target_id uuid,
      p_reason text, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
      p_on_behalf_of_ref text, p_access_record_ref text)
      RETURNS TABLE (result text, takedown_id uuid)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_existing uuid;
      v_state text;
      v_restores boolean := false;
      v_hidden bigint := 0;
      v_cancelled bigint := 0;
      v_rule text := 'takedown.message:' || p_id::text;
    BEGIN
      IF p_id IS NULL OR p_target_id IS NULL OR p_target_kind IS NULL
        OR p_target_kind NOT IN ('message', 'template', 'sender_identity')
        OR p_reason IS NULL OR char_length(p_reason) NOT BETWEEN 1 AND 500
        OR p_actor_ref IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-60';
      END IF;
      PERFORM relay_private.lock_scope(ARRAY['takedown', p_target_id::text]);
      IF p_target_kind = 'message' THEN
        SELECT n.state INTO v_state FROM relay.notifications n
          WHERE n.tenant_id = v_tenant AND n.environment = v_env AND n.id = p_target_id
          FOR NO KEY UPDATE;
      ELSIF p_target_kind = 'template' THEN
        SELECT t.state INTO v_state FROM relay.templates t
          WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.id = p_target_id
          FOR UPDATE;
      ELSE
        SELECT i.kind INTO v_state FROM relay.sender_identities i
          WHERE i.tenant_id = v_tenant AND i.environment = v_env AND i.id = p_target_id
          FOR UPDATE;
      END IF;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, NULL::uuid;
        RETURN;
      END IF;
      SELECT k.id INTO v_existing FROM relay.takedowns k
        WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.state = 'active'
          AND ((p_target_kind = 'message' AND k.notification_id = p_target_id)
            OR (p_target_kind = 'template' AND k.template_id = p_target_id)
            OR (p_target_kind = 'sender_identity' AND k.sender_identity_id = p_target_id));
      IF FOUND THEN
        RETURN QUERY SELECT 'already_active'::text, v_existing;
        RETURN;
      END IF;
      IF p_target_kind = 'message' THEN
        IF v_state = 'active' THEN
          SELECT count(*) FILTER (WHERE c.outcome = 'cancelled') INTO v_cancelled
            FROM relay_private.cancel_deliveries(p_target_id, NULL, v_rule) c;
          PERFORM relay_private.cancel_close(p_target_id, v_rule);
        END IF;
        PERFORM relay_fn.workflow_run_cancel(NULL, p_target_id, NULL, NULL);
        SELECT h.changed INTO v_hidden FROM relay_fn.inbox_takedown(p_target_id, true) h;
        v_restores := v_hidden > 0;
      ELSIF p_target_kind = 'template' THEN
        UPDATE relay.templates t SET state = 'archived', archived_at = now(),
            version = t.version + 1, updated_at = now()
          WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.id = p_target_id
            AND t.state = 'active';
        v_restores := FOUND;
      ELSE
        UPDATE relay.sender_identities i SET suspended_at = now(),
            suspension_rule_id = 'takedown.sender_identity', version = i.version + 1,
            updated_at = now()
          WHERE i.tenant_id = v_tenant AND i.environment = v_env AND i.id = p_target_id
            AND i.suspended_at IS NULL;
        v_restores := FOUND;
      END IF;
      INSERT INTO relay.takedowns (tenant_id, environment, id, target_kind, notification_id,
        template_id, sender_identity_id, reason, state, restores, hidden_items,
        cancelled_deliveries, created_at, updated_at)
      VALUES (v_tenant, v_env, p_id, p_target_kind,
        CASE WHEN p_target_kind = 'message' THEN p_target_id END,
        CASE WHEN p_target_kind = 'template' THEN p_target_id END,
        CASE WHEN p_target_kind = 'sender_identity' THEN p_target_id END,
        p_reason, 'active', v_restores, COALESCE(v_hidden, 0), COALESCE(v_cancelled, 0), now(),
        now());
      PERFORM relay_private.audit_write(v_tenant, v_env::text, 'takedown.applied', p_actor_kind,
        p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'takedown', p_id::text, p_reason,
        p_record_digest);
      RETURN QUERY SELECT 'applied'::text, p_id;
    END
    $fn$
    """
  end

  defp takedown_lift do
    ~S"""
    CREATE FUNCTION relay_fn.takedown_lift(p_id uuid, p_reason text, p_record_digest bytea,
      p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
      RETURNS TABLE (result text, restored_items bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_row relay.takedowns;
      v_restored bigint := 0;
    BEGIN
      IF p_id IS NULL OR p_reason IS NULL OR char_length(p_reason) NOT BETWEEN 1 AND 500
        OR p_actor_ref IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-60';
      END IF;
      SELECT * INTO v_row FROM relay.takedowns k
        WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.id = p_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, 0::bigint;
        RETURN;
      END IF;
      IF v_row.state = 'lifted' THEN
        RETURN QUERY SELECT 'already_lifted'::text, 0::bigint;
        RETURN;
      END IF;
      IF v_row.target_kind = 'message' THEN
        SELECT h.changed INTO v_restored
          FROM relay_fn.inbox_takedown(v_row.notification_id, false) h;
      ELSIF v_row.target_kind = 'template' AND v_row.restores THEN
        UPDATE relay.templates t SET state = 'active', archived_at = NULL,
            version = t.version + 1, updated_at = now()
          WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.id = v_row.template_id
            AND t.state = 'archived';
      ELSIF v_row.target_kind = 'sender_identity' AND v_row.restores THEN
        UPDATE relay.sender_identities i SET suspended_at = NULL, suspension_rule_id = NULL,
            version = i.version + 1, updated_at = now()
          WHERE i.tenant_id = v_tenant AND i.environment = v_env
            AND i.id = v_row.sender_identity_id
            AND i.suspension_rule_id = 'takedown.sender_identity';
      END IF;
      UPDATE relay.takedowns k SET state = 'lifted', lifted_at = now(), lift_reason = p_reason,
          updated_at = now()
        WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.id = p_id;
      PERFORM relay_private.audit_write(v_tenant, v_env::text, 'takedown.lifted', p_actor_kind,
        p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'takedown', p_id::text, p_reason,
        p_record_digest);
      RETURN QUERY SELECT 'lifted'::text, COALESCE(v_restored, 0);
    END
    $fn$
    """
  end

  defp retention_due do
    ~S"""
    CREATE FUNCTION relay_ops.retention_due(p_limit integer)
      RETURNS TABLE (tenant_id uuid, environment text, subject_key_id uuid, recipient_id uuid,
        retention_class text, due_at timestamptz)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
      WITH periods AS (
        SELECT p ->> 'region' AS region, p ->> 'sector' AS sector,
          p ->> 'retention_class' AS retention_class, (p ->> 'days')::integer AS days
        FROM relay.dataset_active a
        JOIN relay.dataset_versions v
          ON v.tenant_id = a.tenant_id AND v.environment = a.environment AND v.id = a.version_id
        CROSS JOIN LATERAL jsonb_array_elements(v.content -> 'periods') AS p
        WHERE a.tenant_id = relay_private.installation_tenant_id() AND a.environment = 'live'
          AND a.dataset_name = 'retention_periods'
      ),
      due AS (
        SELECT k.tenant_id, k.environment, k.id, k.recipient_id, k.retention_class,
          k.created_at + make_interval(days => GREATEST(p.days, COALESCE((
            SELECT floor((s.value #>> '{}')::numeric)::integer FROM relay.settings s
            WHERE s.tenant_id = k.tenant_id AND s.environment = k.environment
              AND s.subtenant_id IS NULL AND s.key = 'retention.' || k.retention_class
              AND jsonb_typeof(s.value) = 'number'), 0))) AS due_at
        FROM relay.subject_keys k
        JOIN relay.tenants t ON t.id = k.tenant_id
        JOIN periods p
          ON p.region = t.region AND p.sector = t.sector AND p.retention_class = k.retention_class
        WHERE k.state IN ('active', 'restricted')
          AND NOT EXISTS (SELECT 1 FROM relay.legal_holds h
            WHERE h.tenant_id = k.tenant_id AND h.environment = k.environment AND h.state = 'active'
              AND (h.scope = 'tenant' OR h.recipient_id = k.recipient_id))
      )
      SELECT d.tenant_id, d.environment::text, d.id, d.recipient_id, d.retention_class::text,
        d.due_at
      FROM due d
      WHERE d.due_at <= now()
      ORDER BY 6, d.tenant_id, d.environment, d.id
      LIMIT GREATEST(COALESCE(p_limit, 100), 1)
    $fn$
    """
  end

  defp subject_erase do
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
      v_waitpoint relay.waitpoints;
      v_now timestamptz := relay_private.business_now();
    BEGIN
      IF p_request_ref IS NULL OR v_destroy && v_restrict THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-18';
      END IF;
      SELECT r.state INTO v_state FROM relay.recipients r
        WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_recipient_id
        FOR NO KEY UPDATE;
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
          external_id_bidx_next = NULL, version = r.version + 1, updated_at = now()
        WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_recipient_id;
      UPDATE relay.recipient_addresses a SET state = 'deleted', address_bidx = NULL,
          address_bidx_key_id = NULL, address_bidx_next = NULL, disabled_rule_id = NULL,
          state_changed_at = now(), updated_at = now()
        WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.recipient_id = p_recipient_id
          AND a.state <> 'deleted';
      UPDATE relay.event_payloads p SET data_ct = NULL, metadata_ct = NULL, actor_ct = NULL,
          links_ct = NULL, overrides_ct = NULL, erased_at = COALESCE(p.erased_at, now()),
          erase_reason = COALESCE(p.erase_reason, 'subject_erasure')
        FROM relay.events e
        WHERE p.tenant_id = v_tenant AND p.environment = v_env
          AND e.tenant_id = p.tenant_id AND e.environment = p.environment AND e.id = p.event_id
          AND p.created_at = e.payload_created_at
          AND EXISTS (SELECT 1 FROM relay.notifications n
            WHERE n.tenant_id = e.tenant_id AND n.environment = e.environment
              AND n.event_id = e.id AND n.recipient_id = p_recipient_id);
      FOR v_delivery IN
        SELECT * FROM relay.deliveries d
        WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.recipient_id = p_recipient_id
          AND d.delivery_rank = 0 AND d.failure_kind IS NULL
        ORDER BY d.created_at, d.id
        FOR NO KEY UPDATE
      LOOP
        PERFORM relay_private.ledger_record(uuidv7(), v_delivery, NULL, 'relay',
          'delivery.cancelled', NULL, NULL, NULL, now(), NULL, NULL, 'cancelled', NULL,
          'erasure.subject', NULL, NULL, NULL, v_delivery.traceparent);
        v_count := v_count + 1;
      END LOOP;
      FOR v_waitpoint IN
        SELECT * FROM relay.waitpoints w
        WHERE w.tenant_id = v_tenant AND w.environment = v_env
          AND ((w.waiter_kind IN ('agent', 'subscriber') AND w.waiter_ref = p_recipient_id)
            OR EXISTS (SELECT 1 FROM relay.waitpoint_responders s
              WHERE s.tenant_id = w.tenant_id AND s.environment = w.environment
                AND s.waitpoint_id = w.id AND s.recipient_id = p_recipient_id))
        ORDER BY w.id
        FOR NO KEY UPDATE
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
      UPDATE relay.workflow_runs r SET state = 'cancelled', wake_at = NULL, outcome = 'cancelled',
          rule_id = 'erasure.subject', finished_at = now(), version = r.version + 1,
          updated_at = now()
        WHERE r.tenant_id = v_tenant AND r.environment = v_env
          AND r.state IN ('running', 'waiting')
          AND r.notification_id IN (SELECT n.id FROM relay.notifications n
            WHERE n.tenant_id = v_tenant AND n.environment = v_env
              AND n.recipient_id = p_recipient_id);
      UPDATE relay.recurrences c SET state = 'cancelled', cancel_reason = 'subject_erasure',
          cancelled_at = v_now, next_at = NULL, next_ordinal = NULL, next_zone = NULL,
          fire_at = NULL, version = c.version + 1, updated_at = now()
        WHERE c.tenant_id = v_tenant AND c.environment = v_env
          AND c.recipient_id = p_recipient_id AND c.state = 'active';
      UPDATE relay.digest_windows g SET state = 'cancelled', closed_at = v_now,
          close_reason = 'subject_erasure', updated_at = now()
        WHERE g.tenant_id = v_tenant AND g.environment = v_env
          AND g.recipient_id = p_recipient_id AND g.state = 'open';
      UPDATE relay.mailboxes m SET state = 'deleted', deleted_at = now(), deleted_reason = 'erasure',
          updated_at = now()
        WHERE m.tenant_id = v_tenant AND m.environment = v_env
          AND m.owner_kind IN ('subscriber', 'agent') AND m.owner_ref = p_recipient_id
          AND m.state <> 'deleted';
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
end
