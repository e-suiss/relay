defmodule Relay.Repo.Migrations.CreateTestRecipientFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"

  @functions [
    {"relay_fn.test_recipient_add(uuid, uuid, uuid, bigint, bigint, bytea, #{@actor})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.test_recipient_confirm(uuid, uuid, bytea, #{@actor})", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.test_recipient_remove(uuid, bytea, #{@actor})", "relay_owner", ~w(relay_app)},
    {"relay_fn.test_send_consume(bigint, bigint)", "relay_owner", ~w(relay_app)}
  ]

  # API-61
  # TN-46
  # OP-8
  def up do
    Enum.each(statements(), &execute/1)

    for {signature, owner, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
    end

    execute("REVOKE ALL ON FUNCTION relay_private.test_recipients_erase() FROM PUBLIC")

    execute("""
    CREATE TRIGGER recipients_erase_test_recipients AFTER UPDATE OF state ON relay.recipients
      FOR EACH ROW WHEN (NEW.state = 'deleted' AND OLD.state IS DISTINCT FROM 'deleted')
      EXECUTE FUNCTION relay_private.test_recipients_erase()
    """)
  end

  def down do
    execute("DROP TRIGGER recipients_erase_test_recipients ON relay.recipients")
    execute("DROP FUNCTION relay_private.test_recipients_erase()")

    for {signature, _owner, _grantees} <- Enum.reverse(@functions),
        do: execute("DROP FUNCTION #{signature}")
  end

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_fn.test_recipient_add(p_id uuid, p_recipient_id uuid,
        p_device_id uuid, p_limit bigint, p_window_s bigint, p_record_digest bytea,
        p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, test_recipient_id uuid)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.test_recipients;
        v_listed bigint;
      BEGIN
        PERFORM relay_private.assert_new_id(p_id);
        IF p_recipient_id IS NULL OR p_limit IS NULL OR p_limit < 1 OR p_window_s IS NULL
          OR p_window_s < 1 OR p_record_digest IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'API-61';
        END IF;
        PERFORM 1 FROM relay.recipients r
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_recipient_id
            AND r.kind = 'subscriber' AND r.state = 'active';
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'recipient_not_found'::text, NULL::uuid;
          RETURN;
        END IF;
        IF p_device_id IS NOT NULL THEN
          PERFORM 1 FROM relay.devices d
            WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_device_id
              AND d.recipient_id = p_recipient_id AND d.state IN ('active', 'stale');
          IF NOT FOUND THEN
            RETURN QUERY SELECT 'device_not_found'::text, NULL::uuid;
            RETURN;
          END IF;
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['test_recipient']);
        SELECT * INTO v_row FROM relay.test_recipients t
          WHERE t.tenant_id = v_tenant AND t.environment = v_env
            AND t.recipient_id = p_recipient_id AND t.device_id IS NOT DISTINCT FROM p_device_id
            AND t.state <> 'removed'
          FOR UPDATE;
        IF FOUND AND (v_row.state = 'verified' OR v_row.verify_by > now()) THEN
          RETURN QUERY SELECT 'exists'::text, v_row.id;
          RETURN;
        END IF;
        SELECT count(*) INTO v_listed FROM relay.test_recipients t
          WHERE t.tenant_id = v_tenant AND t.environment = v_env
            AND (t.state = 'verified' OR (t.state = 'pending' AND t.verify_by > now()));
        IF v_listed >= p_limit THEN
          RETURN QUERY SELECT 'limit_reached'::text, NULL::uuid;
          RETURN;
        END IF;
        IF v_row.id IS NOT NULL THEN
          UPDATE relay.test_recipients t SET state = 'removed', removed_at = now(),
              updated_at = now()
            WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.id = v_row.id;
        END IF;
        INSERT INTO relay.test_recipients (tenant_id, environment, id, recipient_id, device_id,
          state, verify_by, verified_at, removed_at, created_at, updated_at)
        VALUES (v_tenant, v_env, p_id, p_recipient_id, p_device_id, 'pending',
          now() + make_interval(secs => p_window_s), NULL, NULL, now(), now());
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'test_recipient.added',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'test_recipient',
          p_id::text, NULL, p_record_digest);
        RETURN QUERY SELECT 'added'::text, p_id;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.test_recipient_confirm(p_id uuid, p_recipient_id uuid,
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.test_recipients;
      BEGIN
        IF p_id IS NULL OR p_recipient_id IS NULL OR p_record_digest IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'API-61';
        END IF;
        SELECT * INTO v_row FROM relay.test_recipients t
          WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.id = p_id
            AND t.recipient_id = p_recipient_id AND t.state <> 'removed'
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_row.state = 'verified' THEN
          RETURN 'already_verified';
        END IF;
        IF v_row.verify_by <= now() THEN
          RETURN 'expired';
        END IF;
        UPDATE relay.test_recipients t SET state = 'verified', verified_at = now(),
            updated_at = now()
          WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.id = p_id;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'test_recipient.verified',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'test_recipient',
          p_id::text, NULL, p_record_digest);
        RETURN 'verified';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.test_recipient_remove(p_id uuid, p_record_digest bytea,
        p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.test_recipients;
      BEGIN
        IF p_id IS NULL OR p_record_digest IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'API-61';
        END IF;
        SELECT * INTO v_row FROM relay.test_recipients t
          WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.id = p_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_row.state = 'removed' THEN
          RETURN 'already_removed';
        END IF;
        UPDATE relay.test_recipients t SET state = 'removed', removed_at = now(),
            updated_at = now()
          WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.id = p_id;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'test_recipient.removed',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'test_recipient',
          p_id::text, NULL, p_record_digest);
        RETURN 'removed';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.test_send_consume(p_count bigint, p_limit bigint)
        RETURNS TABLE (result text, used bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_day date := current_date;
        v_used bigint;
      BEGIN
        IF p_count IS NULL OR p_count < 1 OR p_limit IS NULL OR p_limit < 0 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'API-61';
        END IF;
        IF p_count <= p_limit THEN
          INSERT INTO relay.test_send_counters AS c (tenant_id, environment, usage_day, used,
            updated_at)
          VALUES (v_tenant, v_env, v_day, p_count, now())
          ON CONFLICT (tenant_id, environment, usage_day) DO UPDATE
            SET used = c.used + EXCLUDED.used, updated_at = now()
            WHERE c.used + EXCLUDED.used <= p_limit
          RETURNING c.used INTO v_used;
          IF v_used IS NOT NULL THEN
            RETURN QUERY SELECT 'consumed'::text, v_used;
            RETURN;
          END IF;
        END IF;
        SELECT c.used INTO v_used FROM relay.test_send_counters c
          WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.usage_day = v_day;
        RETURN QUERY SELECT 'exhausted'::text, COALESCE(v_used, 0::bigint);
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.test_recipients_erase() RETURNS trigger
        LANGUAGE plpgsql
        SET search_path = pg_catalog, pg_temp
        SET TimeZone = 'UTC'
      AS $fn$
      BEGIN
        UPDATE relay.test_recipients t SET state = 'removed', removed_at = now(),
            updated_at = now()
          WHERE t.tenant_id = NEW.tenant_id AND t.environment = NEW.environment
            AND t.recipient_id = NEW.id AND t.state <> 'removed';
        RETURN NULL;
      END
      $fn$
      """
    ]
  end
end
