defmodule Relay.Repo.Migrations.AddEventItemAndCorrelationId do
  use Ecto.Migration

  @old_accept "relay_fn.event_accept(uuid, uuid, uuid, uuid, uuid, text, bytea, text, text, text, text, text, text, timestamp with time zone, timestamp with time zone, boolean, text, boolean, bigint, bytea, bytea, bytea, bytea, uuid, bigint, text, text, bytea, bytea)"
  @accept "relay_fn.event_accept(uuid, uuid, uuid, uuid, uuid, text, bytea, text, text, text, text, text, text, timestamp with time zone, timestamp with time zone, boolean, text, boolean, bigint, bytea, bytea, bytea, bytea, uuid, bigint, text, text, bytea, bytea, text, jsonb)"

  # E-83
  # E-85
  # OP-24
  def up do
    execute(~S"""
    ALTER TABLE relay.events
      ADD COLUMN correlation_id text
        CONSTRAINT events_correlation_id_check CHECK (correlation_id ~ '^[\x20-\x7E]{1,128}$'),
      ADD COLUMN item jsonb
        CONSTRAINT events_item_check CHECK (jsonb_typeof(item) = 'object'
          AND item ?& ARRAY['ref', 'version', 'digest'] AND pg_column_size(item) <= 1024)
    """)

    execute("SET LOCAL ROLE relay_owner")
    execute("DROP FUNCTION #{@old_accept}")
    execute("RESET ROLE")
    execute(event_accept())
    execute("REVOKE ALL ON FUNCTION #{@accept} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@accept} TO relay_app")
    execute("ALTER FUNCTION #{@accept} OWNER TO relay_owner")
  end

  def down, do: :ok

  defp event_accept do
    ~S"""
    CREATE FUNCTION relay_fn.event_accept(p_id uuid, p_workflow_id uuid,
      p_workflow_version_id uuid, p_api_client_id uuid, p_subtenant_id uuid, p_source text,
      p_ce_key_digest bytea, p_dedup_key text, p_cancellation_key text, p_sender_type text,
      p_priority text, p_security_subtype text, p_on_expire text, p_send_at timestamptz,
      p_expires_at timestamptz, p_retention_none boolean, p_send_mode text, p_is_test boolean,
      p_recipient_count bigint, p_data_ct bytea, p_metadata_ct bytea, p_actor_ct bytea,
      p_ce_attributes_ct bytea, p_key_id uuid, p_plain_size bigint, p_traceparent text,
      p_interruption text, p_links_ct bytea, p_overrides_ct bytea, p_correlation_id text,
      p_item jsonb)
      RETURNS TABLE (result text, event_id uuid, created_at timestamptz)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_now timestamptz := clock_timestamp();
      v_published uuid;
      v_subtenant uuid;
      v_state text;
    BEGIN
      IF relay_private.tenant_status() <> 'active' THEN
        RETURN QUERY SELECT 'tenant_inactive'::text, NULL::uuid, NULL::timestamptz;
        RETURN;
      END IF;
      PERFORM relay_private.assert_new_id(p_id);
      IF p_workflow_id IS NULL OR p_workflow_version_id IS NULL OR p_source IS NULL
        OR p_sender_type IS NULL OR p_priority IS NULL OR p_retention_none IS NULL
        OR p_is_test IS NULL OR p_recipient_count IS NULL OR p_key_id IS NULL
        OR p_plain_size IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'API-20';
      END IF;
      SELECT w.published_version_id INTO v_published FROM relay.workflows w
        WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_workflow_id
          AND w.state = 'active';
      IF v_published IS NULL THEN
        RETURN QUERY SELECT 'workflow_not_published'::text, NULL::uuid, NULL::timestamptz;
        RETURN;
      END IF;
      IF v_published <> p_workflow_version_id THEN
        RETURN QUERY SELECT 'version_not_current'::text, NULL::uuid, NULL::timestamptz;
        RETURN;
      END IF;
      IF p_send_mode IS NOT NULL AND v_env <> 'test' THEN
        RETURN QUERY SELECT 'send_mode_not_allowed'::text, NULL::uuid, NULL::timestamptz;
        RETURN;
      END IF;
      IF p_send_at IS NOT NULL
        AND (p_send_at <= v_now OR p_send_at > v_now + interval '90 days') THEN
        RETURN QUERY SELECT 'send_at_invalid'::text, NULL::uuid, NULL::timestamptz;
        RETURN;
      END IF;
      IF p_subtenant_id IS NOT NULL THEN
        SELECT s.state INTO v_state FROM relay.subtenants s
          WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = p_subtenant_id;
        IF v_state = 'suspended' THEN
          RETURN QUERY SELECT 'subtenant_suspended'::text, NULL::uuid, NULL::timestamptz;
          RETURN;
        END IF;
        IF v_state = 'active' THEN
          v_subtenant := p_subtenant_id;
        END IF;
      END IF;
      INSERT INTO relay.events (tenant_id, environment, id, workflow_id, workflow_version_id,
        api_client_id, subtenant_id, source, ce_key_digest, dedup_key, cancellation_key,
        sender_type, priority, security_subtype, on_expire, send_at, expires_at,
        retention_none, send_mode, is_test, recipient_count, state, cancelled_at,
        cancellation_id, payload_created_at, traceparent, interruption, correlation_id, item,
        created_at)
      VALUES (v_tenant, v_env, p_id, p_workflow_id, p_workflow_version_id, p_api_client_id,
        v_subtenant, p_source, p_ce_key_digest, p_dedup_key, p_cancellation_key, p_sender_type,
        p_priority, p_security_subtype, p_on_expire, p_send_at, p_expires_at, p_retention_none,
        p_send_mode, p_is_test, p_recipient_count, 'accepted', NULL, NULL, v_now,
        p_traceparent, p_interruption, p_correlation_id, p_item, v_now);
      INSERT INTO relay.event_payloads (tenant_id, environment, event_id, created_at, data_ct,
        metadata_ct, actor_ct, ce_attributes_ct, links_ct, overrides_ct, key_id, plain_size,
        erased_at, erase_reason)
      VALUES (v_tenant, v_env, p_id, v_now, p_data_ct, p_metadata_ct, p_actor_ct,
        p_ce_attributes_ct, p_links_ct, p_overrides_ct, p_key_id, p_plain_size, NULL, NULL);
      RETURN QUERY SELECT 'accepted'::text, p_id, v_now;
    END
    $fn$
    """
  end
end
