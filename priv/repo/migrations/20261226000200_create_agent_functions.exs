defmodule Relay.Repo.Migrations.CreateAgentFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"

  @functions [
    {"relay_private.agent_endpoints_known(uuid, relay.environment, uuid, uuid)", "relay_migrator",
     ~w(relay_owner)},
    {"relay_private.agent_topics_check(uuid, relay.environment, uuid, text[])", "relay_migrator",
     ~w(relay_owner)},
    {"relay_private.agent_topics_set(uuid, relay.environment, uuid, text[])", "relay_migrator",
     ~w(relay_owner)},
    {"relay_fn.agent_create(uuid, bytea, uuid, bytea, uuid, bytea, uuid, text, text, uuid, uuid, boolean, text[], bytea, #{@actor})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.agent_update(uuid, text[], text, text, uuid, uuid, boolean, text[], bigint, bytea, #{@actor})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.agent_set_state(uuid, bytea[], text, text, bytea, #{@actor})", "relay_owner",
     ~w(relay_app)}
  ]

  # C-21
  # E-28
  # E-29
  # AG-5
  # AG-23
  # INV-47
  # OP-8
  def up do
    Enum.each(statements(), &execute/1)

    for {signature, owner, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      if owner == "relay_owner", do: execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
    end

    execute("REVOKE ALL ON FUNCTION relay_private.agents_erase() FROM PUBLIC")

    execute("""
    CREATE TRIGGER recipients_erase_agents AFTER UPDATE OF state ON relay.recipients
      FOR EACH ROW WHEN (NEW.state = 'deleted' AND OLD.state IS DISTINCT FROM 'deleted'
        AND NEW.kind = 'agent')
      EXECUTE FUNCTION relay_private.agents_erase()
    """)
  end

  def down, do: :ok

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_private.agent_endpoints_known(p_tenant_id uuid,
        p_environment relay.environment, p_webhook_endpoint_id uuid, p_a2a_push_endpoint_id uuid)
        RETURNS boolean
      LANGUAGE sql STABLE
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT (p_webhook_endpoint_id IS NULL OR EXISTS (SELECT 1 FROM relay.webhook_endpoints e
            WHERE e.tenant_id = p_tenant_id AND e.environment = p_environment
              AND e.id = p_webhook_endpoint_id AND e.state <> 'archived'))
          AND (p_a2a_push_endpoint_id IS NULL OR EXISTS (SELECT 1 FROM relay.webhook_endpoints e
            WHERE e.tenant_id = p_tenant_id AND e.environment = p_environment
              AND e.id = p_a2a_push_endpoint_id AND e.state <> 'archived'))
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.agent_topics_check(p_tenant_id uuid,
        p_environment relay.environment, p_agent_id uuid, p_keys text[])
        RETURNS text
      LANGUAGE plpgsql STABLE
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_key text;
        v_topic relay.topics;
      BEGIN
        FOREACH v_key IN ARRAY p_keys LOOP
          SELECT * INTO v_topic FROM relay.topics t
            WHERE t.tenant_id = p_tenant_id AND t.environment = p_environment AND t.key = v_key;
          IF NOT FOUND THEN
            RETURN 'topic_not_found';
          END IF;
          IF v_topic.state <> 'active' AND NOT EXISTS (SELECT 1 FROM relay.topic_subscriptions s
            WHERE s.tenant_id = p_tenant_id AND s.environment = p_environment
              AND s.topic_id = v_topic.id AND s.recipient_id = p_agent_id
              AND s.state = 'active') THEN
            RETURN 'topic_archived';
          END IF;
        END LOOP;
        RETURN 'ok';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.agent_topics_set(p_tenant_id uuid,
        p_environment relay.environment, p_agent_id uuid, p_keys text[])
        RETURNS void
      LANGUAGE plpgsql VOLATILE
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_topic_ids uuid[];
      BEGIN
        SELECT coalesce(array_agg(t.id), '{}') INTO v_topic_ids FROM relay.topics t
          WHERE t.tenant_id = p_tenant_id AND t.environment = p_environment
            AND t.key = ANY (p_keys);
        UPDATE relay.topic_subscriptions s SET state = 'removed',
            removed_reason = 'unsubscribed', removed_at = now(), updated_at = now()
          WHERE s.tenant_id = p_tenant_id AND s.environment = p_environment
            AND s.recipient_id = p_agent_id AND s.state = 'active'
            AND NOT (s.topic_id = ANY (v_topic_ids));
        INSERT INTO relay.topic_subscriptions (tenant_id, environment, id, topic_id,
          recipient_id, state, removed_reason, removed_at, created_at, updated_at)
        SELECT p_tenant_id, p_environment, uuidv7(), t.id, p_agent_id, 'active', NULL, NULL,
          now(), now()
        FROM relay.topics t
        WHERE t.tenant_id = p_tenant_id AND t.environment = p_environment
          AND t.id = ANY (v_topic_ids)
          AND NOT EXISTS (SELECT 1 FROM relay.topic_subscriptions s
            WHERE s.tenant_id = p_tenant_id AND s.environment = p_environment
              AND s.topic_id = t.id AND s.recipient_id = p_agent_id AND s.state = 'active');
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.agent_create(p_id uuid, p_party_bidx bytea, p_bidx_key_id uuid,
        p_party_ct bytea, p_profile_dek_id uuid, p_profile_wrapped_dek bytea,
        p_wrapping_key_id uuid, p_name text, p_owner_ref text, p_webhook_endpoint_id uuid,
        p_a2a_push_endpoint_id uuid, p_realtime boolean, p_topics text[], p_record_digest bytea,
        p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, agent_id uuid, mailbox_id uuid)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_result text;
        v_mailbox uuid;
      BEGIN
        IF p_party_bidx IS NULL OR p_bidx_key_id IS NULL OR p_name IS NULL OR p_owner_ref IS NULL
          OR p_realtime IS NULL OR p_topics IS NULL OR cardinality(p_topics) > 100
          OR p_record_digest IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-5';
        END IF;
        IF relay_private.tenant_status() <> 'active' THEN
          RETURN QUERY SELECT 'tenant_inactive'::text, NULL::uuid, NULL::uuid;
          RETURN;
        END IF;
        IF NOT relay_private.agent_endpoints_known(v_tenant, v_env, p_webhook_endpoint_id,
          p_a2a_push_endpoint_id) THEN
          RETURN QUERY SELECT 'endpoint_not_found'::text, NULL::uuid, NULL::uuid;
          RETURN;
        END IF;
        v_result := relay_private.agent_topics_check(v_tenant, v_env, p_id, p_topics);
        IF v_result <> 'ok' THEN
          RETURN QUERY SELECT v_result, NULL::uuid, NULL::uuid;
          RETURN;
        END IF;
        SELECT c.result INTO v_result
          FROM relay_fn.recipient_create(p_id, 'agent', p_party_bidx, p_bidx_key_id, p_party_ct,
            p_profile_dek_id, p_profile_wrapped_dek, p_wrapping_key_id) c;
        IF v_result = 'exists' THEN
          RETURN QUERY SELECT 'party_conflict'::text, NULL::uuid, NULL::uuid;
          RETURN;
        END IF;
        IF v_result <> 'created' THEN
          RETURN QUERY SELECT 'tenant_inactive'::text, NULL::uuid, NULL::uuid;
          RETURN;
        END IF;
        INSERT INTO relay.agents (tenant_id, environment, id, recipient_kind, name, owner_ref,
          webhook_endpoint_id, a2a_push_endpoint_id, realtime, state, suspended_at, deleted_at,
          access_event_ref, version, created_at, updated_at)
        VALUES (v_tenant, v_env, p_id, 'agent', p_name, p_owner_ref, p_webhook_endpoint_id,
          p_a2a_push_endpoint_id, p_realtime, 'active', NULL, NULL, NULL, 1, now(), now());
        SELECT m.mailbox_id INTO v_mailbox FROM relay_fn.mailbox_ensure(uuidv7(), 'agent', p_id) m;
        PERFORM relay_private.agent_topics_set(v_tenant, v_env, p_id, p_topics);
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'agent.created',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'agent',
          p_id::text, NULL, p_record_digest);
        RETURN QUERY SELECT 'created'::text, p_id, v_mailbox;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.agent_update(p_id uuid, p_fields text[], p_name text,
        p_owner_ref text, p_webhook_endpoint_id uuid, p_a2a_push_endpoint_id uuid,
        p_realtime boolean, p_topics text[], p_expected_version bigint, p_record_digest bytea,
        p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, version bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_agent relay.agents;
        v_result text;
        v_version bigint;
      BEGIN
        IF p_id IS NULL OR p_fields IS NULL OR p_record_digest IS NULL
          OR ('name' = ANY (p_fields) AND p_name IS NULL)
          OR ('owner_ref' = ANY (p_fields) AND p_owner_ref IS NULL)
          OR ('realtime' = ANY (p_fields) AND p_realtime IS NULL)
          OR ('topics' = ANY (p_fields) AND (p_topics IS NULL OR cardinality(p_topics) > 100)) THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-5';
        END IF;
        SELECT * INTO v_agent FROM relay.agents a
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = p_id
          FOR NO KEY UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
          RETURN;
        END IF;
        IF v_agent.state = 'deleted' THEN
          RETURN QUERY SELECT 'deleted'::text, v_agent.version;
          RETURN;
        END IF;
        IF p_expected_version IS NOT NULL AND p_expected_version <> v_agent.version THEN
          RETURN QUERY SELECT 'version_conflict'::text, v_agent.version;
          RETURN;
        END IF;
        IF NOT relay_private.agent_endpoints_known(v_tenant, v_env,
          CASE WHEN 'webhook_endpoint_id' = ANY (p_fields) THEN p_webhook_endpoint_id END,
          CASE WHEN 'a2a_push_endpoint_id' = ANY (p_fields) THEN p_a2a_push_endpoint_id END) THEN
          RETURN QUERY SELECT 'endpoint_not_found'::text, v_agent.version;
          RETURN;
        END IF;
        IF 'topics' = ANY (p_fields) THEN
          v_result := relay_private.agent_topics_check(v_tenant, v_env, p_id, p_topics);
          IF v_result <> 'ok' THEN
            RETURN QUERY SELECT v_result, v_agent.version;
            RETURN;
          END IF;
        END IF;
        UPDATE relay.agents a SET
            name = CASE WHEN 'name' = ANY (p_fields) THEN p_name ELSE a.name END,
            owner_ref = CASE WHEN 'owner_ref' = ANY (p_fields) THEN p_owner_ref
              ELSE a.owner_ref END,
            webhook_endpoint_id = CASE WHEN 'webhook_endpoint_id' = ANY (p_fields)
              THEN p_webhook_endpoint_id ELSE a.webhook_endpoint_id END,
            a2a_push_endpoint_id = CASE WHEN 'a2a_push_endpoint_id' = ANY (p_fields)
              THEN p_a2a_push_endpoint_id ELSE a.a2a_push_endpoint_id END,
            realtime = CASE WHEN 'realtime' = ANY (p_fields) THEN p_realtime ELSE a.realtime END,
            version = a.version + 1, updated_at = now()
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = p_id
          RETURNING a.version INTO v_version;
        IF 'topics' = ANY (p_fields) THEN
          PERFORM relay_private.agent_topics_set(v_tenant, v_env, p_id, p_topics);
        END IF;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'agent.updated',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'agent',
          p_id::text, NULL, p_record_digest);
        RETURN QUERY SELECT 'updated'::text, v_version;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.agent_set_state(p_id uuid, p_party_bidxs bytea[], p_state text,
        p_access_event_ref text, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
        p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, agent_id uuid, version bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_agent relay.agents;
        v_id uuid;
        v_version bigint;
        v_action text;
      BEGIN
        IF p_state IS NULL OR p_state NOT IN ('active', 'suspended', 'deleted')
          OR p_record_digest IS NULL OR (p_id IS NULL) = (p_party_bidxs IS NULL) THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-5';
        END IF;
        v_id := p_id;
        IF v_id IS NULL THEN
          SELECT r.id INTO v_id FROM relay.recipients r
            WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.kind = 'agent'
              AND (r.external_id_bidx = ANY (p_party_bidxs)
                OR r.external_id_bidx_next = ANY (p_party_bidxs));
        END IF;
        SELECT * INTO v_agent FROM relay.agents a
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = v_id
          FOR NO KEY UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        IF v_agent.state = p_state OR v_agent.state = 'deleted'
          OR (p_state = 'active' AND v_agent.state <> 'suspended') THEN
          RETURN QUERY SELECT 'unchanged'::text, v_agent.id, v_agent.version;
          RETURN;
        END IF;
        UPDATE relay.agents a SET state = p_state,
            suspended_at = CASE WHEN p_state = 'suspended' THEN now() END,
            deleted_at = CASE WHEN p_state = 'deleted' THEN now() END,
            access_event_ref = coalesce(p_access_event_ref, a.access_event_ref),
            version = a.version + 1, updated_at = now()
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = v_agent.id
          RETURNING a.version INTO v_version;
        UPDATE relay.mailboxes m
          SET state = CASE WHEN p_state = 'active' THEN 'active' ELSE 'suspended' END,
            updated_at = now()
          WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.owner_kind = 'agent'
            AND m.owner_ref = v_agent.id AND m.state IN ('active', 'suspended');
        IF p_state = 'deleted' THEN
          UPDATE relay.recipients r SET state = 'deleted', deleted_at = now(),
              deleted_reason = 'operator', external_id_bidx = NULL,
              external_id_bidx_key_id = NULL, external_id_bidx_next = NULL,
              version = r.version + 1, updated_at = now()
            WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = v_agent.id
              AND r.state <> 'deleted';
        END IF;
        v_action := CASE p_state WHEN 'suspended' THEN 'agent.suspended'
          WHEN 'active' THEN 'agent.reactivated' ELSE 'agent.deleted' END;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, v_action, p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'agent', v_agent.id::text, NULL,
          p_record_digest);
        RETURN QUERY SELECT CASE p_state WHEN 'active' THEN 'reactivated' ELSE p_state END,
          v_agent.id, v_version;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.agents_erase() RETURNS trigger
        LANGUAGE plpgsql
        SET search_path = pg_catalog, pg_temp
        SET TimeZone = 'UTC'
      AS $fn$
      BEGIN
        UPDATE relay.agents a SET state = 'deleted', suspended_at = NULL, deleted_at = now(),
            version = a.version + 1, updated_at = now()
          WHERE a.tenant_id = NEW.tenant_id AND a.environment = NEW.environment AND a.id = NEW.id
            AND a.state <> 'deleted';
        RETURN NULL;
      END
      $fn$
      """
    ]
  end
end
