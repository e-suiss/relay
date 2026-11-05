defmodule Relay.Repo.Migrations.CreateDeviceFunctions do
  use Ecto.Migration

  @time "timestamp with time zone"

  @functions [
    {"relay_private.device_retire(relay.devices, text)", "relay_migrator", ~w(relay_owner)},
    {"relay_fn.device_register(uuid, uuid, text, text, bytea[], uuid, bytea, text, text, jsonb, text, bytea[], bigint)",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.device_disable(uuid, bytea[], uuid, text, #{@time})", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.device_sweep(bigint, bigint, bigint)", "relay_owner", ~w(relay_app)},
    {"relay_ops.device_sweep_scopes(bigint, bigint, integer)", "relay_maint", ~w(relay_worker)}
  ]

  # C-23
  # CH-11
  # CH-28
  # CH-31
  # CH-74
  # API-67
  # INV-14
  # OP-44
  # OP-8
  def up do
    Enum.each(statements(), &execute/1)

    for {signature, owner, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      if owner == "relay_owner", do: execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
    end

    execute("REVOKE ALL ON FUNCTION relay_private.devices_erase() FROM PUBLIC")

    execute("""
    CREATE TRIGGER recipients_erase_devices AFTER UPDATE OF state ON relay.recipients
      FOR EACH ROW WHEN (NEW.state = 'deleted' AND OLD.state IS DISTINCT FROM 'deleted')
      EXECUTE FUNCTION relay_private.devices_erase()
    """)
  end

  def down do
    execute("DROP TRIGGER recipients_erase_devices ON relay.recipients")
    execute("DROP FUNCTION relay_private.devices_erase()")

    for {signature, _owner, _grantees} <- Enum.reverse(@functions),
        do: execute("DROP FUNCTION #{signature}")
  end

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_private.device_retire(p_device relay.devices, p_reason text)
        RETURNS void
      LANGUAGE plpgsql VOLATILE
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      BEGIN
        UPDATE relay.devices d SET state = 'disabled', disabled_reason = p_reason,
            deleted_at = now(), updated_at = now()
          WHERE d.tenant_id = p_device.tenant_id AND d.environment = p_device.environment
            AND d.id = p_device.id AND d.state <> 'disabled';
        IF FOUND AND p_reason <> 'reassigned' THEN
          PERFORM relay_fn.outbox_append(uuidv7(), 'device.unregistered',
            'device:' || p_device.id::text,
            jsonb_build_object('device_id', p_device.id,
              'device_fingerprint', p_device.fingerprint,
              'recipient_id', p_device.recipient_id, 'disabled_reason', p_reason),
            NULL);
        END IF;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.device_register(p_id uuid, p_recipient_id uuid, p_platform text,
        p_app text, p_token_digests bytea[], p_token_bidx_key_id uuid, p_token_ct bytea,
        p_apns_environment text, p_permission text, p_android_channels jsonb, p_locale text,
        p_previous_digests bytea[], p_limit bigint)
        RETURNS TABLE (result text, device_id uuid)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_now timestamptz := relay_private.business_now();
        v_bidx bytea := p_token_digests[1];
        v_fingerprint text;
        v_key uuid;
        v_found relay.devices;
        v_old relay.devices;
        v_result text;
        v_device uuid;
      BEGIN
        IF p_id IS NULL OR p_recipient_id IS NULL OR p_platform IS NULL
          OR p_platform NOT IN ('apns', 'fcm', 'hms', 'web_push', 'unified_push')
          OR p_app IS NULL OR p_token_ct IS NULL OR v_bidx IS NULL OR octet_length(v_bidx) <> 32
          OR p_token_bidx_key_id IS NULL OR p_permission IS NULL
          OR p_permission NOT IN ('granted', 'denied', 'provisional', 'not_determined')
          OR (p_platform = 'apns') <> (p_apns_environment IS NOT NULL)
          OR p_android_channels IS NULL OR jsonb_typeof(p_android_channels) <> 'array'
          OR p_limit IS NULL OR p_limit < 1 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'API-67';
        END IF;
        PERFORM 1 FROM relay.recipients r
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_recipient_id
            AND r.kind = 'subscriber' AND r.state = 'active';
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'recipient_not_found'::text, NULL::uuid;
          RETURN;
        END IF;
        SELECT k.id INTO v_key FROM relay.subject_keys k
          WHERE k.tenant_id = v_tenant AND k.environment = v_env
            AND k.recipient_id = p_recipient_id AND k.retention_class = 'recipient_profile'
            AND k.state = 'active'
          ORDER BY k.created_at DESC, k.id DESC
          LIMIT 1;
        IF v_key IS NULL OR NOT EXISTS (SELECT 1 FROM relay.blind_index_keys b
          WHERE b.tenant_id = v_tenant AND b.environment = v_env AND b.id = p_token_bidx_key_id
            AND b.state IN ('active', 'rotating')) THEN
          RETURN QUERY SELECT 'key_not_found'::text, NULL::uuid;
          RETURN;
        END IF;
        v_fingerprint := left(encode(v_bidx, 'hex'), 16);
        PERFORM relay_private.lock_scope(ARRAY['device', encode(v_bidx, 'hex')]);
        PERFORM relay_private.lock_scope(ARRAY['device_owner', p_recipient_id::text]);
        IF p_previous_digests IS NOT NULL THEN
          FOR v_old IN
            SELECT * FROM relay.devices d
            WHERE d.tenant_id = v_tenant AND d.environment = v_env
              AND d.recipient_id = p_recipient_id AND d.state <> 'disabled'
              AND (d.token_bidx = ANY (p_previous_digests)
                OR d.token_bidx_next = ANY (p_previous_digests))
              AND NOT (d.token_bidx = ANY (p_token_digests)
                OR COALESCE(d.token_bidx_next = ANY (p_token_digests), false))
            ORDER BY d.id
            FOR UPDATE
          LOOP
            PERFORM relay_private.device_retire(v_old, 'replaced');
          END LOOP;
        END IF;
        SELECT * INTO v_found FROM relay.devices d
          WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.state <> 'disabled'
            AND (d.token_bidx = ANY (p_token_digests) OR d.token_bidx_next = ANY (p_token_digests))
          ORDER BY d.last_seen_at DESC, d.id DESC
          LIMIT 1
          FOR UPDATE;
        IF v_found.id IS NOT NULL AND v_found.recipient_id = p_recipient_id
          AND v_found.platform = p_platform THEN
          UPDATE relay.devices d SET app = p_app, apns_environment = p_apns_environment,
              permission = p_permission, android_channels = p_android_channels,
              locale = p_locale, state = 'active', registered_at = v_now, last_seen_at = v_now,
              updated_at = now()
            WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = v_found.id;
          v_result := 'updated';
          v_device := v_found.id;
        ELSE
          IF v_found.id IS NOT NULL THEN
            PERFORM relay_private.device_retire(v_found,
              CASE WHEN v_found.recipient_id = p_recipient_id THEN 'replaced'
                ELSE 'reassigned' END);
          END IF;
          PERFORM relay_private.assert_new_id(p_id);
          INSERT INTO relay.devices (tenant_id, environment, id, recipient_id, platform, app,
            token_ct, token_key_id, token_bidx, token_bidx_key_id, token_bidx_next, fingerprint,
            apns_environment, permission, android_channels, locale, state, disabled_reason,
            registered_at, last_seen_at, deleted_at, created_at, updated_at)
          VALUES (v_tenant, v_env, p_id, p_recipient_id, p_platform, p_app, p_token_ct, v_key,
            v_bidx, p_token_bidx_key_id, p_token_digests[2], v_fingerprint, p_apns_environment,
            p_permission, p_android_channels, p_locale, 'active', NULL, v_now, v_now, NULL,
            now(), now());
          v_device := p_id;
          IF v_found.id IS NOT NULL AND v_found.recipient_id <> p_recipient_id THEN
            PERFORM relay_fn.outbox_append(uuidv7(), 'device.reassigned',
              'device:' || p_id::text,
              jsonb_build_object('device_id', p_id, 'device_fingerprint', v_fingerprint,
                'from_recipient_id', v_found.recipient_id, 'to_recipient_id', p_recipient_id),
              NULL);
            v_result := 'reassigned';
          ELSE
            v_result := 'created';
          END IF;
        END IF;
        FOR v_old IN
          SELECT * FROM relay.devices d
          WHERE d.tenant_id = v_tenant AND d.environment = v_env
            AND d.recipient_id = p_recipient_id AND d.state <> 'disabled' AND d.id <> v_device
          ORDER BY d.last_seen_at DESC, d.id DESC
          OFFSET p_limit - 1
          FOR UPDATE
        LOOP
          PERFORM relay_private.device_retire(v_old, 'device_limit');
        END LOOP;
        RETURN QUERY SELECT v_result, v_device;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.device_disable(p_device_id uuid, p_token_digests bytea[],
        p_recipient_id uuid, p_reason text, p_failed_at timestamptz)
        RETURNS TABLE (result text, device_id uuid)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_device relay.devices;
      BEGIN
        IF (p_device_id IS NULL) = (p_token_digests IS NULL) OR p_reason IS NULL
          OR p_reason NOT IN ('unregistered', 'logout', 'removed') THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'CH-11';
        END IF;
        SELECT * INTO v_device FROM relay.devices d
          WHERE d.tenant_id = v_tenant AND d.environment = v_env
            AND ((p_device_id IS NOT NULL AND d.id = p_device_id)
              OR (p_token_digests IS NOT NULL AND (d.token_bidx = ANY (p_token_digests)
                OR d.token_bidx_next = ANY (p_token_digests))))
            AND (p_recipient_id IS NULL OR d.recipient_id = p_recipient_id)
          ORDER BY (d.state <> 'disabled') DESC, d.last_seen_at DESC, d.id DESC
          LIMIT 1
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::uuid;
          RETURN;
        END IF;
        IF v_device.state = 'disabled' THEN
          RETURN QUERY SELECT 'already_disabled'::text, v_device.id;
          RETURN;
        END IF;
        IF p_failed_at IS NOT NULL AND p_failed_at < v_device.registered_at THEN
          RETURN QUERY SELECT 'reregistered'::text, v_device.id;
          RETURN;
        END IF;
        PERFORM relay_private.device_retire(v_device, p_reason);
        RETURN QUERY SELECT 'disabled'::text, v_device.id;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.device_sweep(p_stale_after_s bigint, p_inactive_after_s bigint,
        p_limit bigint)
        RETURNS TABLE (staled bigint, disabled bigint, has_more boolean)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_now timestamptz := relay_private.business_now();
        v_device relay.devices;
        v_disabled bigint := 0;
        v_staled bigint := 0;
      BEGIN
        IF p_stale_after_s IS NULL OR p_inactive_after_s IS NULL OR p_limit IS NULL
          OR p_limit < 1 OR p_stale_after_s < 1 OR p_inactive_after_s <= p_stale_after_s THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-44';
        END IF;
        FOR v_device IN
          SELECT * FROM relay.devices d
          WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.state <> 'disabled'
            AND d.last_seen_at <= v_now - p_inactive_after_s * interval '1 second'
          ORDER BY d.last_seen_at, d.id
          LIMIT p_limit
          FOR UPDATE SKIP LOCKED
        LOOP
          PERFORM relay_private.device_retire(v_device, 'inactive');
          v_disabled := v_disabled + 1;
        END LOOP;
        WITH due AS (
          SELECT x.id FROM relay.devices x
          WHERE x.tenant_id = v_tenant AND x.environment = v_env AND x.state = 'active'
            AND x.last_seen_at <= v_now - p_stale_after_s * interval '1 second'
          ORDER BY x.last_seen_at, x.id
          LIMIT p_limit - v_disabled
          FOR UPDATE SKIP LOCKED
        ), marked AS (
          UPDATE relay.devices d SET state = 'stale', updated_at = now()
          FROM due
          WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = due.id
          RETURNING d.id
        )
        SELECT count(*) INTO v_staled FROM marked;
        RETURN QUERY SELECT v_staled, v_disabled, v_staled + v_disabled >= p_limit;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.device_sweep_scopes(p_stale_after_s bigint,
        p_inactive_after_s bigint, p_limit integer)
        RETURNS TABLE (tenant_id uuid, environment text)
      LANGUAGE sql STABLE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT DISTINCT d.tenant_id, d.environment::text
        FROM relay.devices d
        LEFT JOIN relay.virtual_clocks v ON v.tenant_id = d.tenant_id
          AND v.environment = d.environment
        WHERE d.state <> 'disabled'
          AND d.last_seen_at <= now() + coalesce(v.offset_ms, 0) * interval '1 millisecond'
            - CASE WHEN d.state = 'active' THEN p_stale_after_s ELSE p_inactive_after_s END
              * interval '1 second'
        LIMIT GREATEST(COALESCE(p_limit, 100), 1)
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.devices_erase() RETURNS trigger
        LANGUAGE plpgsql
        SET search_path = pg_catalog, pg_temp
        SET TimeZone = 'UTC'
      AS $fn$
      BEGIN
        UPDATE relay.devices d SET state = 'disabled',
            disabled_reason = COALESCE(d.disabled_reason, 'erased'),
            deleted_at = COALESCE(d.deleted_at, now()), token_bidx = NULL,
            token_bidx_key_id = NULL, token_bidx_next = NULL, updated_at = now()
          WHERE d.tenant_id = NEW.tenant_id AND d.environment = NEW.environment
            AND d.recipient_id = NEW.id
            AND (d.state <> 'disabled' OR d.token_bidx IS NOT NULL);
        RETURN NULL;
      END
      $fn$
      """
    ]
  end
end
