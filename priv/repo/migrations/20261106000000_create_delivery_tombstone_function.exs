defmodule Relay.Repo.Migrations.CreateDeliveryTombstoneFunction do
  use Ecto.Migration

  @functions [
    {"relay_fn.delivery_tombstone_apply(uuid)", "relay_owner", ~w(relay_app)}
  ]

  # API-58
  # INV-6
  # INV-60
  # C-29
  # OP-8
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
      CREATE FUNCTION relay_fn.delivery_tombstone_apply(p_delivery_id uuid)
        RETURNS TABLE (result text, cancellation_id uuid)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_notification_id uuid;
        v_notification relay.notifications;
        v_delivery relay.deliveries;
        v_cancellation uuid;
        v_rule text;
      BEGIN
        SELECT d.notification_id INTO v_notification_id FROM relay.deliveries d
          WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_delivery_id;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::uuid;
          RETURN;
        END IF;
        SELECT * INTO v_notification FROM relay.notifications n
          WHERE n.tenant_id = v_tenant AND n.environment = v_env AND n.id = v_notification_id
          FOR NO KEY UPDATE;
        SELECT * INTO v_delivery FROM relay.deliveries d
          WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_delivery_id
          FOR UPDATE;
        IF v_delivery.failure_kind IS NOT NULL THEN
          RETURN QUERY SELECT 'terminal'::text, NULL::uuid;
          RETURN;
        END IF;
        IF v_notification.event_id IS NULL THEN
          RETURN QUERY SELECT 'none'::text, NULL::uuid;
          RETURN;
        END IF;
        v_cancellation := relay_fn.cancellation_applies(v_notification.event_id,
          v_notification.recipient_id, v_delivery.channel::text);
        IF v_cancellation IS NULL THEN
          RETURN QUERY SELECT 'none'::text, NULL::uuid;
          RETURN;
        END IF;
        IF v_delivery.delivery_rank > 0 OR EXISTS (SELECT 1 FROM relay.delivery_attempts a
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.delivery_id = v_delivery.id
            AND a.state IN ('pending', 'in_flight', 'succeeded', 'unknown')) THEN
          RETURN QUERY SELECT 'already_sent'::text, v_cancellation;
          RETURN;
        END IF;
        v_rule := 'cancelled:' || v_cancellation::text;
        PERFORM relay_private.ledger_record(uuidv7(), v_delivery, NULL, 'relay',
          'delivery.cancelled', NULL, NULL, NULL, now(), NULL, NULL, 'cancelled', NULL,
          v_rule, NULL, NULL, NULL, v_delivery.traceparent);
        PERFORM relay_private.cancel_close(v_notification.id, v_rule);
        RETURN QUERY SELECT 'cancelled'::text, v_cancellation;
      END
      $fn$
      """
    ]
  end
end
