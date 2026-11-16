defmodule Relay.Repo.Migrations.CreateTopicFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"

  @functions [
    {"relay_fn.topic_create(uuid, text, text, bytea, #{@actor})", "relay_owner", ~w(relay_app)},
    {"relay_fn.topic_archive(text, bytea, #{@actor})", "relay_owner", ~w(relay_app)},
    {"relay_fn.topic_subscribe(text, bytea[], uuid[], bytea, #{@actor})", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.topic_unsubscribe(text, bytea[], bytea, #{@actor})", "relay_owner", ~w(relay_app)},
    {"relay_fn.audience_record(uuid, text, uuid, uuid[], uuid[], uuid[], boolean[])",
     "relay_owner", ~w(relay_app)}
  ]

  # WF-51
  # WF-52
  # WF-53
  # WF-55
  # L-31
  # F-5
  # OP-8
  def up do
    Enum.each(statements(), &execute/1)

    for {signature, owner, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
    end

    execute("REVOKE ALL ON FUNCTION relay_private.topic_subscriptions_erase() FROM PUBLIC")

    execute("""
    CREATE TRIGGER recipients_erase_topic_subscriptions AFTER UPDATE OF state ON relay.recipients
      FOR EACH ROW WHEN (NEW.state = 'deleted' AND OLD.state IS DISTINCT FROM 'deleted')
      EXECUTE FUNCTION relay_private.topic_subscriptions_erase()
    """)
  end

  def down, do: :ok

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_fn.topic_create(p_id uuid, p_key text, p_parent_key text,
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text)
        RETURNS TABLE (result text, topic_id uuid, version bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_existing relay.topics;
        v_parent relay.topics;
      BEGIN
        IF relay_private.tenant_status() <> 'active' THEN
          RETURN QUERY SELECT 'tenant_inactive'::text, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        IF p_key IS NULL OR p_key !~ '^[a-z0-9][a-z0-9_.:-]{0,127}$' OR p_record_digest IS NULL
          OR p_parent_key = p_key THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-51';
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['topic', p_key]);
        SELECT * INTO v_existing FROM relay.topics t
          WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.key = p_key;
        IF FOUND THEN
          RETURN QUERY SELECT 'key_conflict'::text, v_existing.id, v_existing.version;
          RETURN;
        END IF;
        IF p_parent_key IS NOT NULL THEN
          SELECT * INTO v_parent FROM relay.topics t
            WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.key = p_parent_key
            FOR UPDATE;
          IF NOT FOUND THEN
            RETURN QUERY SELECT 'parent_not_found'::text, NULL::uuid, NULL::bigint;
            RETURN;
          END IF;
          IF v_parent.parent_id IS NOT NULL THEN
            RETURN QUERY SELECT 'too_deep'::text, NULL::uuid, NULL::bigint;
            RETURN;
          END IF;
          IF v_parent.state <> 'active' THEN
            RETURN QUERY SELECT 'parent_archived'::text, NULL::uuid, NULL::bigint;
            RETURN;
          END IF;
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        INSERT INTO relay.topics (tenant_id, environment, id, key, parent_id, state, version,
          archived_at, created_at, updated_at)
        VALUES (v_tenant, v_env, p_id, p_key, v_parent.id, 'active', 1, NULL, now(), now());
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'topic.created',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'topic',
          p_id::text, NULL, p_record_digest);
        RETURN QUERY SELECT 'created'::text, p_id, 1::bigint;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.topic_archive(p_key text, p_record_digest bytea,
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
        v_topic relay.topics;
        v_version bigint;
      BEGIN
        IF p_key IS NULL OR p_record_digest IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-51';
        END IF;
        SELECT * INTO v_topic FROM relay.topics t
          WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.key = p_key
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
          RETURN;
        END IF;
        IF v_topic.state = 'archived' THEN
          RETURN QUERY SELECT 'already_archived'::text, v_topic.version;
          RETURN;
        END IF;
        UPDATE relay.topics t SET state = 'archived', archived_at = now(),
            version = t.version + 1, updated_at = now()
          WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.id = v_topic.id
          RETURNING t.version INTO v_version;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'topic.archived',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'topic',
          v_topic.id::text, NULL, p_record_digest);
        RETURN QUERY SELECT 'archived'::text, v_version;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.topic_subscribe(p_key text, p_bidxs bytea[], p_ids uuid[],
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text)
        RETURNS TABLE (ordinal bigint, result text, recipient_id uuid, subscription_id uuid)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_topic relay.topics;
        v_recipient uuid;
        v_existing uuid;
        v_added bigint := 0;
      BEGIN
        IF relay_private.tenant_status() <> 'active' THEN
          RETURN QUERY SELECT 0::bigint, 'tenant_inactive'::text, NULL::uuid, NULL::uuid;
          RETURN;
        END IF;
        IF p_key IS NULL OR p_bidxs IS NULL OR p_ids IS NULL OR p_record_digest IS NULL
          OR cardinality(p_bidxs) < 1 OR cardinality(p_bidxs) <> cardinality(p_ids) THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-51';
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['topic', p_key]);
        SELECT * INTO v_topic FROM relay.topics t
          WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.key = p_key;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 0::bigint, 'topic_not_found'::text, NULL::uuid, NULL::uuid;
          RETURN;
        END IF;
        IF v_topic.state <> 'active' THEN
          RETURN QUERY SELECT 0::bigint, 'topic_archived'::text, NULL::uuid, NULL::uuid;
          RETURN;
        END IF;
        FOR i IN 1 .. cardinality(p_bidxs) LOOP
          SELECT r.id INTO v_recipient FROM relay.recipients r
            WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.kind = 'subscriber'
              AND r.state = 'active'
              AND (r.external_id_bidx = p_bidxs[i] OR r.external_id_bidx_next = p_bidxs[i]);
          IF NOT FOUND THEN
            RETURN QUERY SELECT i::bigint, 'recipient_not_found'::text, NULL::uuid, NULL::uuid;
            CONTINUE;
          END IF;
          SELECT s.id INTO v_existing FROM relay.topic_subscriptions s
            WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.topic_id = v_topic.id
              AND s.recipient_id = v_recipient AND s.state = 'active';
          IF FOUND THEN
            RETURN QUERY SELECT i::bigint, 'exists'::text, v_recipient, v_existing;
            CONTINUE;
          END IF;
          PERFORM relay_private.assert_new_id(p_ids[i]);
          INSERT INTO relay.topic_subscriptions (tenant_id, environment, id, topic_id,
            recipient_id, state, removed_reason, removed_at, created_at, updated_at)
          VALUES (v_tenant, v_env, p_ids[i], v_topic.id, v_recipient, 'active', NULL, NULL,
            now(), now());
          v_added := v_added + 1;
          RETURN QUERY SELECT i::bigint, 'subscribed'::text, v_recipient, p_ids[i];
        END LOOP;
        IF v_added > 0 THEN
          PERFORM relay_private.audit_write(v_tenant, v_env::text, 'topic.subscribed',
            p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'topic',
            v_topic.id::text, NULL, p_record_digest);
        END IF;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.topic_unsubscribe(p_key text, p_bidxs bytea[],
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text)
        RETURNS TABLE (ordinal bigint, result text, recipient_id uuid, subscription_id uuid)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_topic relay.topics;
        v_recipient uuid;
        v_id uuid;
        v_removed bigint := 0;
      BEGIN
        IF p_key IS NULL OR p_bidxs IS NULL OR p_record_digest IS NULL
          OR cardinality(p_bidxs) < 1 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-51';
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['topic', p_key]);
        SELECT * INTO v_topic FROM relay.topics t
          WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.key = p_key;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 0::bigint, 'topic_not_found'::text, NULL::uuid, NULL::uuid;
          RETURN;
        END IF;
        FOR i IN 1 .. cardinality(p_bidxs) LOOP
          SELECT r.id INTO v_recipient FROM relay.recipients r
            WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.kind = 'subscriber'
              AND r.state = 'active'
              AND (r.external_id_bidx = p_bidxs[i] OR r.external_id_bidx_next = p_bidxs[i]);
          IF NOT FOUND THEN
            RETURN QUERY SELECT i::bigint, 'recipient_not_found'::text, NULL::uuid, NULL::uuid;
            CONTINUE;
          END IF;
          v_id := NULL;
          UPDATE relay.topic_subscriptions s SET state = 'removed',
              removed_reason = 'unsubscribed', removed_at = now(), updated_at = now()
            WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.topic_id = v_topic.id
              AND s.recipient_id = v_recipient AND s.state = 'active'
            RETURNING s.id INTO v_id;
          IF v_id IS NOT NULL THEN
            v_removed := v_removed + 1;
            RETURN QUERY SELECT i::bigint, 'unsubscribed'::text, v_recipient, v_id;
            CONTINUE;
          END IF;
          SELECT s.id INTO v_id FROM relay.topic_subscriptions s
            WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.topic_id = v_topic.id
              AND s.recipient_id = v_recipient
            ORDER BY s.created_at DESC, s.id DESC
            LIMIT 1;
          IF v_id IS NOT NULL THEN
            RETURN QUERY SELECT i::bigint, 'already_unsubscribed'::text, v_recipient, v_id;
          ELSE
            RETURN QUERY SELECT i::bigint, 'not_subscribed'::text, v_recipient, NULL::uuid;
          END IF;
        END LOOP;
        IF v_removed > 0 THEN
          PERFORM relay_private.audit_write(v_tenant, v_env::text, 'topic.unsubscribed',
            p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'topic',
            v_topic.id::text, NULL, p_record_digest);
        END IF;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.audience_record(p_id uuid, p_source_kind text, p_source_id uuid,
        p_topic_ids uuid[], p_recipient_ids uuid[], p_via_topic_ids uuid[],
        p_also_direct boolean[])
        RETURNS TABLE (result text, audience_id uuid)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_existing uuid;
        v_count bigint := COALESCE(cardinality(p_recipient_ids), 0);
      BEGIN
        IF p_source_kind IS NULL OR p_source_kind !~ '^[a-z_]{1,32}$' OR p_source_id IS NULL
          OR p_topic_ids IS NULL OR cardinality(p_topic_ids) < 1 OR p_recipient_ids IS NULL
          OR p_via_topic_ids IS NULL OR p_also_direct IS NULL
          OR COALESCE(cardinality(p_via_topic_ids), 0) <> v_count
          OR COALESCE(cardinality(p_also_direct), 0) <> v_count THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-52';
        END IF;
        SELECT a.id INTO v_existing FROM relay.audiences a
          WHERE a.tenant_id = v_tenant AND a.environment = v_env
            AND a.source_kind = p_source_kind AND a.source_id = p_source_id;
        IF FOUND THEN
          RETURN QUERY SELECT 'exists'::text, v_existing;
          RETURN;
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        INSERT INTO relay.audiences (tenant_id, environment, id, source_kind, source_id, topic_ids,
          member_count, rule_id, created_at)
        VALUES (v_tenant, v_env, p_id, p_source_kind, p_source_id, p_topic_ids, v_count,
          CASE WHEN v_count = 0 THEN 'audience.no_subscribers' END, now());
        INSERT INTO relay.audience_members (tenant_id, environment, audience_id, recipient_id,
          topic_id, also_direct, created_at)
        SELECT v_tenant, v_env, p_id, m.recipient_id, m.topic_id, m.also_direct, now()
        FROM unnest(p_recipient_ids, p_via_topic_ids, p_also_direct)
          AS m(recipient_id, topic_id, also_direct);
        RETURN QUERY SELECT 'recorded'::text, p_id;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.topic_subscriptions_erase() RETURNS trigger
        LANGUAGE plpgsql
        SET search_path = pg_catalog, pg_temp
        SET TimeZone = 'UTC'
      AS $fn$
      BEGIN
        UPDATE relay.topic_subscriptions s SET state = 'removed',
            removed_reason = 'subscriber_deleted', removed_at = now(), updated_at = now()
          WHERE s.tenant_id = NEW.tenant_id AND s.environment = NEW.environment
            AND s.recipient_id = NEW.id AND s.state = 'active';
        RETURN NULL;
      END
      $fn$
      """
    ]
  end
end
