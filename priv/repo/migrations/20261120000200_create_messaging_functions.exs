defmodule Relay.Repo.Migrations.CreateMessagingFunctions do
  use Ecto.Migration

  @functions [
    {"relay_fn.messaging_target_put(uuid, uuid, text, uuid, bytea)", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.messaging_target_disable(uuid, text, text)", "relay_owner", ~w(relay_app)},
    {"relay_fn.messaging_message_put(uuid, uuid, bytea, text, uuid)", "relay_owner",
     ~w(relay_app)}
  ]

  # CH-62
  # CH-23
  # CH-11
  # INV-14
  # OP-8
  def up do
    Enum.each(statements(), &execute/1)

    for {signature, owner, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      if owner == "relay_owner", do: execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
    end

    execute("REVOKE ALL ON FUNCTION relay_private.messaging_targets_erase() FROM PUBLIC")

    execute("""
    CREATE TRIGGER recipients_erase_messaging_targets AFTER UPDATE OF state ON relay.recipients
      FOR EACH ROW WHEN (NEW.state = 'deleted' AND OLD.state IS DISTINCT FROM 'deleted')
      EXECUTE FUNCTION relay_private.messaging_targets_erase()
    """)
  end

  def down do
    execute("DROP TRIGGER recipients_erase_messaging_targets ON relay.recipients")
    execute("DROP FUNCTION relay_private.messaging_targets_erase()")

    for {signature, _owner, _grantees} <- Enum.reverse(@functions),
        do: execute("DROP FUNCTION #{signature}")
  end

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_fn.messaging_target_put(p_id uuid, p_recipient_id uuid,
        p_channel text, p_provider_account_id uuid, p_target_ct bytea)
        RETURNS TABLE (result text, target_id uuid)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_key uuid;
        v_result text := 'created';
      BEGIN
        PERFORM relay_private.assert_new_id(p_id);
        IF p_recipient_id IS NULL OR p_channel IS NULL
          OR p_channel NOT IN ('slack', 'teams', 'telegram', 'discord')
          OR p_provider_account_id IS NULL OR p_target_ct IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'CH-62';
        END IF;
        PERFORM 1 FROM relay.recipients r
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_recipient_id
            AND r.kind = 'subscriber' AND r.state = 'active';
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'recipient_not_found'::text, NULL::uuid;
          RETURN;
        END IF;
        PERFORM 1 FROM relay.provider_accounts a
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = p_provider_account_id
            AND a.channel = p_channel::relay.channel AND a.state = 'active';
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'account_not_found'::text, NULL::uuid;
          RETURN;
        END IF;
        SELECT k.id INTO v_key FROM relay.subject_keys k
          WHERE k.tenant_id = v_tenant AND k.environment = v_env
            AND k.recipient_id = p_recipient_id AND k.retention_class = 'recipient_profile'
            AND k.state = 'active'
          ORDER BY k.created_at DESC, k.id DESC
          LIMIT 1;
        IF v_key IS NULL THEN
          RETURN QUERY SELECT 'key_not_found'::text, NULL::uuid;
          RETURN;
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['messaging_target', p_recipient_id::text, p_channel]);
        UPDATE relay.messaging_targets t SET state = 'disabled',
            disabled_rule_id = 'messaging.target_replaced', deleted_at = now(), updated_at = now()
          WHERE t.tenant_id = v_tenant AND t.environment = v_env
            AND t.recipient_id = p_recipient_id AND t.channel = p_channel::relay.channel
            AND t.state = 'active';
        IF FOUND THEN
          v_result := 'replaced';
        END IF;
        INSERT INTO relay.messaging_targets (tenant_id, environment, id, recipient_id, channel,
          provider_account_id, target_ct, target_key_id, state, disabled_rule_id, deleted_at,
          created_at, updated_at)
        VALUES (v_tenant, v_env, p_id, p_recipient_id, p_channel::relay.channel,
          p_provider_account_id, p_target_ct, v_key, 'active', NULL, NULL, now(), now());
        RETURN QUERY SELECT v_result, p_id;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.messaging_target_disable(p_recipient_id uuid, p_channel text,
        p_rule_id text)
        RETURNS TABLE (result text, target_id uuid)
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
        IF p_recipient_id IS NULL OR p_channel IS NULL
          OR p_channel NOT IN ('slack', 'teams', 'telegram', 'discord') OR p_rule_id IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'CH-11';
        END IF;
        UPDATE relay.messaging_targets t SET state = 'disabled', disabled_rule_id = p_rule_id,
            deleted_at = now(), updated_at = now()
          WHERE t.tenant_id = v_tenant AND t.environment = v_env
            AND t.recipient_id = p_recipient_id AND t.channel = p_channel::relay.channel
            AND t.state = 'active'
          RETURNING t.id INTO v_id;
        IF v_id IS NULL THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::uuid;
          RETURN;
        END IF;
        PERFORM relay_fn.outbox_append(uuidv7(), 'messaging_target.disabled',
          'recipient:' || p_recipient_id::text,
          jsonb_build_object('target_id', v_id, 'recipient_id', p_recipient_id,
            'channel', p_channel, 'rule_id', p_rule_id),
          NULL);
        RETURN QUERY SELECT 'disabled'::text, v_id;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.messaging_message_put(p_id uuid, p_target_id uuid,
        p_topic_key bytea, p_provider_message_ref text, p_delivery_id uuid)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_account uuid;
      BEGIN
        PERFORM relay_private.assert_new_id(p_id);
        IF p_target_id IS NULL OR p_topic_key IS NULL OR octet_length(p_topic_key) <> 32
          OR p_provider_message_ref IS NULL OR p_delivery_id IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'CH-23';
        END IF;
        SELECT t.provider_account_id INTO v_account FROM relay.messaging_targets t
          WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.id = p_target_id;
        IF v_account IS NULL THEN
          RETURN 'target_not_found';
        END IF;
        INSERT INTO relay.messaging_messages AS m (tenant_id, environment, id, target_id,
          provider_account_id, topic_key, provider_message_ref, delivery_id, created_at,
          updated_at)
        VALUES (v_tenant, v_env, p_id, p_target_id, v_account, p_topic_key,
          p_provider_message_ref, p_delivery_id, now(), now())
        ON CONFLICT (tenant_id, environment, target_id, topic_key) DO UPDATE
          SET provider_message_ref = EXCLUDED.provider_message_ref,
            delivery_id = EXCLUDED.delivery_id, updated_at = now();
        RETURN 'recorded';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.messaging_targets_erase() RETURNS trigger
        LANGUAGE plpgsql
        SET search_path = pg_catalog, pg_temp
        SET TimeZone = 'UTC'
      AS $fn$
      BEGIN
        UPDATE relay.messaging_targets t SET state = 'disabled',
            disabled_rule_id = 'messaging.target_erased', deleted_at = now(), updated_at = now()
          WHERE t.tenant_id = NEW.tenant_id AND t.environment = NEW.environment
            AND t.recipient_id = NEW.id AND t.state = 'active';
        UPDATE relay.messaging_messages m SET provider_message_ref = 'erased', updated_at = now()
          FROM relay.messaging_targets t
          WHERE m.tenant_id = NEW.tenant_id AND m.environment = NEW.environment
            AND t.tenant_id = m.tenant_id AND t.environment = m.environment AND t.id = m.target_id
            AND t.recipient_id = NEW.id AND m.provider_message_ref <> 'erased';
        RETURN NULL;
      END
      $fn$
      """
    ]
  end
end
