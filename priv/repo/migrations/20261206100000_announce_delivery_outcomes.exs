defmodule Relay.Repo.Migrations.AnnounceDeliveryOutcomes do
  use Ecto.Migration

  @functions [
    {"relay_private.delivery_status(relay.deliveries)", ~w(relay_owner relay_app relay_report)},
    {"relay_private.delivery_reason(relay.deliveries)", ~w(relay_owner relay_app relay_report)},
    {"relay_private.delivery_failure(relay.deliveries)", ~w(relay_owner relay_app relay_report)},
    {"relay_private.notification_emit(relay.notifications, text, text, jsonb, text)",
     ~w(relay_owner)},
    {"relay_private.notification_announce(relay.notifications, text, text, jsonb, text)",
     ~w(relay_owner)},
    {"relay_private.engagement_announce(relay.deliveries, text, text, timestamp with time zone)",
     ~w(relay_owner)}
  ]

  # DS-14
  # DS-17
  # E-84
  # E-85
  # X-1
  # INV-2
  def up do
    execute(~S"""
    ALTER TABLE relay.notifications
      ADD COLUMN announcements jsonb
        CONSTRAINT notifications_announcements_check
          CHECK (jsonb_typeof(announcements) = 'object' AND pg_column_size(announcements) <= 4096)
    """)

    Enum.each(statements(), &execute/1)

    for {signature, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
    end

    execute("REVOKE ALL ON FUNCTION relay_private.delivery_announce() FROM PUBLIC")

    execute("""
    CREATE TRIGGER deliveries_announce AFTER UPDATE ON relay.deliveries
      FOR EACH ROW EXECUTE FUNCTION relay_private.delivery_announce()
    """)
  end

  def down, do: :ok

  defp statements do
    [
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
          WHEN p_delivery.delivery_rank = 1 THEN 'sent'
          ELSE 'queued'
        END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.delivery_reason(p_delivery relay.deliveries)
        RETURNS TABLE (reason text, rule_id text)
      LANGUAGE sql IMMUTABLE
      SET search_path = pg_catalog, pg_temp
      AS $fn$
        SELECT CASE
            WHEN p_delivery.failure_kind IS NOT NULL
              THEN COALESCE(p_delivery.failure_reason, p_delivery.failure_kind)
            WHEN p_delivery.paused_at IS NOT NULL THEN 'paused'
            ELSE p_delivery.decision_reason
          END,
          CASE
            WHEN p_delivery.failure_kind IS NOT NULL THEN p_delivery.failure_rule_id
            WHEN p_delivery.paused_at IS NOT NULL THEN p_delivery.pause_rule_id
            ELSE p_delivery.decision_rule_id
          END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.delivery_failure(p_delivery relay.deliveries) RETURNS jsonb
      LANGUAGE sql IMMUTABLE
      SET search_path = pg_catalog, pg_temp
      AS $fn$
        SELECT CASE
          WHEN p_delivery.failure_kind IN ('failed', 'bounced')
            AND p_delivery.failure_class IS NOT NULL
            THEN jsonb_strip_nulls(jsonb_build_object('kind', p_delivery.failure_kind,
              'class', p_delivery.failure_class, 'code', p_delivery.failure_reason,
              'retryable', p_delivery.failure_class = 'transient'))
        END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.notification_emit(p_notification relay.notifications,
        p_event_type text, p_stream_key text, p_fields jsonb, p_traceparent text)
        RETURNS void
      LANGUAGE plpgsql VOLATILE
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_base jsonb;
      BEGIN
        IF p_notification.id IS NULL OR p_event_type IS NULL OR jsonb_typeof(p_fields) <> 'object'
          THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'E-84';
        END IF;
        SELECT jsonb_strip_nulls(jsonb_build_object('notification_id', p_notification.id,
            'recipient_id', p_notification.recipient_id,
            'recipient_kind', (SELECT r.kind FROM relay.recipients r
              WHERE r.tenant_id = p_notification.tenant_id
                AND r.environment = p_notification.environment
                AND r.id = p_notification.recipient_id),
            'workflow', (SELECT jsonb_build_object('key', w.key, 'version', v.version_no)
              FROM relay.workflows w
              JOIN relay.workflow_versions v ON v.tenant_id = w.tenant_id
                AND v.environment = w.environment AND v.workflow_id = w.id
              WHERE w.tenant_id = p_notification.tenant_id
                AND w.environment = p_notification.environment
                AND w.id = p_notification.workflow_id
                AND v.id = p_notification.workflow_version_id),
            'tenant', p_notification.subtenant_id,
            'item', (SELECT e.item FROM relay.events e
              WHERE e.tenant_id = p_notification.tenant_id
                AND e.environment = p_notification.environment
                AND e.id = p_notification.event_id)))
          INTO v_base;
        PERFORM relay_fn.outbox_append(uuidv7(), p_event_type, p_stream_key,
          v_base || jsonb_strip_nulls(p_fields),
          COALESCE(p_traceparent, p_notification.traceparent));
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.notification_announce(p_notification relay.notifications,
        p_key text, p_event_type text, p_fields jsonb, p_traceparent text)
        RETURNS boolean
      LANGUAGE plpgsql VOLATILE
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      BEGIN
        IF p_key IS NULL OR char_length(p_key) > 64 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'E-84';
        END IF;
        IF COALESCE(p_notification.announcements, '{}'::jsonb) ? p_key THEN
          RETURN false;
        END IF;
        UPDATE relay.notifications n
          SET announcements = COALESCE(n.announcements, '{}'::jsonb)
            || jsonb_build_object(p_key, now())
          WHERE n.tenant_id = p_notification.tenant_id
            AND n.environment = p_notification.environment AND n.id = p_notification.id
            AND NOT (COALESCE(n.announcements, '{}'::jsonb) ? p_key);
        IF NOT FOUND THEN
          RETURN false;
        END IF;
        PERFORM relay_private.notification_emit(p_notification, p_event_type,
          'notification:' || p_notification.id::text, p_fields, p_traceparent);
        RETURN true;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.engagement_announce(p_delivery relay.deliveries,
        p_kind text, p_link_rel text, p_occurred_at timestamptz)
        RETURNS boolean
      LANGUAGE plpgsql VOLATILE
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_notification relay.notifications;
      BEGIN
        IF p_kind IS NULL OR p_kind NOT IN ('seen', 'read', 'archived', 'clicked')
          OR p_occurred_at IS NULL
          OR (p_kind = 'clicked') <> (p_link_rel IS NOT NULL)
          OR p_link_rel !~ '^[a-z][a-z0-9_]{0,31}$' THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'E-84';
        END IF;
        SELECT * INTO v_notification FROM relay.notifications n
          WHERE n.tenant_id = p_delivery.tenant_id AND n.environment = p_delivery.environment
            AND n.id = p_delivery.notification_id;
        RETURN relay_private.notification_announce(v_notification,
          CASE WHEN p_kind = 'clicked' THEN 'clicked:' || p_link_rel ELSE p_kind END,
          'notification.' || p_kind,
          jsonb_build_object('channel', p_delivery.channel, 'link_rel', p_link_rel,
            p_kind || '_at', p_occurred_at),
          p_delivery.traceparent);
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.delivery_announce() RETURNS trigger
      LANGUAGE plpgsql
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_old text := relay_private.delivery_status(OLD);
        v_new text := relay_private.delivery_status(NEW);
        v_terminal text[] := ARRAY['delivered', 'failed', 'skipped', 'expired', 'cancelled'];
        v_notification relay.notifications;
        v_reason record;
        v_open boolean;
        v_failed boolean;
        v_expired boolean;
      BEGIN
        IF v_old = v_new THEN
          RETURN NULL;
        END IF;
        SELECT * INTO v_notification FROM relay.notifications n
          WHERE n.tenant_id = NEW.tenant_id AND n.environment = NEW.environment
            AND n.id = NEW.notification_id;
        SELECT * INTO v_reason FROM relay_private.delivery_reason(NEW);
        PERFORM relay_private.notification_emit(v_notification, 'delivery.status_changed',
          'delivery:' || NEW.id::text,
          jsonb_build_object('delivery_id', NEW.id, 'channel', NEW.channel, 'status', v_new,
            'previous_status', v_old, 'reason', v_reason.reason, 'rule_id', v_reason.rule_id,
            'failure', relay_private.delivery_failure(NEW), 'changed_at', now()),
          NEW.traceparent);
        IF v_new = 'delivered' THEN
          PERFORM relay_private.notification_announce(v_notification, 'delivered',
            'notification.delivered',
            jsonb_build_object('delivery_id', NEW.id, 'channel', NEW.channel,
              'delivered_at', COALESCE(NEW.delivered_at, now())),
            NEW.traceparent);
          RETURN NULL;
        END IF;
        IF NOT (v_new = ANY (v_terminal)) THEN
          RETURN NULL;
        END IF;
        SELECT bool_or(NOT (relay_private.delivery_status(d) = ANY (v_terminal))
              OR relay_private.delivery_status(d) = 'delivered'),
            bool_or(relay_private.delivery_status(d) = 'failed'),
            bool_or(relay_private.delivery_status(d) = 'expired')
          INTO v_open, v_failed, v_expired
          FROM relay.deliveries d
          WHERE d.tenant_id = NEW.tenant_id AND d.environment = NEW.environment
            AND d.notification_id = NEW.notification_id;
        IF v_open THEN
          RETURN NULL;
        END IF;
        IF v_failed THEN
          PERFORM relay_private.notification_announce(v_notification, 'failed',
            'notification.failed', jsonb_build_object('failed_at', now()), NEW.traceparent);
        ELSIF v_expired THEN
          PERFORM relay_private.notification_announce(v_notification, 'expired',
            'notification.expired', jsonb_build_object('expired_at', now()), NEW.traceparent);
        END IF;
        RETURN NULL;
      END
      $fn$
      """
    ]
  end
end
