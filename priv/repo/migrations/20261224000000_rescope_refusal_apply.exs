defmodule Relay.Repo.Migrations.RescopeRefusalApply do
  use Ecto.Migration

  @previous "relay_fn.refusal_apply(uuid, uuid, uuid, text, text, text, text, text, timestamptz, bytea, uuid, bytea, bytea, uuid, bytea, text)"
  @signature "relay_fn.refusal_apply(uuid, uuid, uuid, text, text, text, text, text, timestamptz, bytea, uuid, bytea, uuid, text)"

  # PC-37
  # PC-38
  # PC-39
  # PC-61
  # INV-18
  # WH-15
  # OP-8
  def up do
    execute("SET LOCAL ROLE relay_owner")
    execute("DROP FUNCTION #{@previous}")
    execute("RESET ROLE")
    execute(apply_refusal())
    execute("REVOKE ALL ON FUNCTION #{@signature} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@signature} TO relay_app")
    execute("ALTER FUNCTION #{@signature} OWNER TO relay_owner")
  end

  def down, do: :ok

  defp apply_refusal do
    ~S"""
    CREATE FUNCTION relay_fn.refusal_apply(p_id uuid, p_recipient_id uuid,
      p_brand_subtenant_id uuid, p_channel text, p_source text, p_scope text,
      p_category_key text, p_request_ref text, p_occurred_at timestamptz, p_evidence_ct bytea,
      p_evidence_key_id uuid, p_consent_evidence_ct bytea, p_provider_account_id uuid,
      p_actor_ref text)
      RETURNS TABLE (result text, refusal_id uuid)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_kind text;
      v_code text;
      v_changed boolean := false;
      v_latest relay.consents;
      v_sequence bigint;
      v_existing uuid;
      v_stream text;
      v_at text;
    BEGIN
      IF p_recipient_id IS NULL OR p_channel IS NULL OR p_source IS NULL OR p_scope IS NULL
        OR p_source NOT IN ('rfc8058', 'unsubscribe_link', 'mailto', 'unsubscribe_page',
          'sms_keyword', 'complaint', 'whatsapp', 'iys')
        OR p_scope NOT IN ('category', 'all_marketing', 'all_channel')
        OR (p_scope = 'category') <> (p_category_key IS NOT NULL)
        OR (p_source IN ('rfc8058', 'unsubscribe_link', 'mailto') AND p_scope <> 'category')
        OR p_request_ref IS NULL OR char_length(p_request_ref) NOT BETWEEN 1 AND 256
        OR p_occurred_at IS NULL OR p_actor_ref IS NULL
        OR char_length(p_actor_ref) NOT BETWEEN 1 AND 256
        OR (p_evidence_ct IS NULL) <> (p_evidence_key_id IS NULL)
        OR (p_consent_evidence_ct IS NOT NULL AND p_evidence_key_id IS NULL) THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'PC-38';
      END IF;
      SELECT r.kind INTO v_kind FROM relay.recipients r
        WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_recipient_id
          AND r.state = 'active';
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'recipient_not_found'::text, NULL::uuid;
        RETURN;
      END IF;
      IF p_brand_subtenant_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM relay.subtenants s
        WHERE s.tenant_id = v_tenant AND s.environment = v_env
          AND s.id = p_brand_subtenant_id) THEN
        RETURN QUERY SELECT 'subtenant_not_found'::text, NULL::uuid;
        RETURN;
      END IF;
      IF p_evidence_key_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM relay.subject_keys k
        WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.id = p_evidence_key_id
          AND k.recipient_id = p_recipient_id AND k.retention_class = 'commercial_consent'
          AND k.state = 'active') THEN
        RETURN QUERY SELECT 'evidence_key_invalid'::text, NULL::uuid;
        RETURN;
      END IF;
      PERFORM relay_private.lock_scope(ARRAY['refusal', p_recipient_id::text, p_channel]);
      v_stream := 'recipient:' || p_recipient_id::text;
      v_at := to_char(p_occurred_at, 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"');
      IF p_scope = 'category' THEN
        SELECT s.result INTO v_code FROM relay_fn.preference_set(uuidv7(), p_recipient_id,
          'category_channel', p_category_key, p_channel, 'opt_out', 'unsubscribe',
          p_actor_ref) s;
        IF v_code = 'category_not_found' THEN
          RETURN QUERY SELECT 'category_not_found'::text, NULL::uuid;
          RETURN;
        END IF;
        IF v_code NOT IN ('set', 'unchanged') THEN
          RETURN QUERY SELECT 'not_allowed'::text, NULL::uuid;
          RETURN;
        END IF;
        IF v_code = 'set' THEN
          v_changed := true;
          PERFORM relay_fn.outbox_append(uuidv7(), 'preference.changed', v_stream,
            jsonb_build_object('recipient_id', p_recipient_id, 'recipient_kind', v_kind,
              'level', 'category_channel', 'value', 'opt_out', 'category', p_category_key,
              'channel', p_channel, 'changed_at', v_at),
            NULL);
        END IF;
      ELSE
        SELECT * INTO v_latest FROM relay.consents c
          WHERE c.tenant_id = v_tenant AND c.environment = v_env
            AND c.recipient_id = p_recipient_id
            AND c.brand_subtenant_id IS NOT DISTINCT FROM p_brand_subtenant_id
            AND c.channel = p_channel AND c.source = p_source
          ORDER BY c.source_sequence DESC
          LIMIT 1;
        IF v_latest.id IS NULL OR v_latest.status <> 'revoked' THEN
          v_sequence := GREATEST(floor(extract(epoch FROM p_occurred_at) * 1000)::bigint,
            COALESCE(v_latest.source_sequence, -1) + 1);
          SELECT c.result INTO v_code FROM relay_fn.consent_record(uuidv7(), p_recipient_id,
            p_brand_subtenant_id, p_channel, 'revoked', NULL, NULL, p_source, v_sequence,
            p_occurred_at, NULL, p_consent_evidence_ct,
            CASE WHEN p_consent_evidence_ct IS NULL THEN NULL ELSE p_evidence_key_id END, NULL,
            'relay', p_request_ref) c;
          IF v_code IS DISTINCT FROM 'recorded' THEN
            RAISE EXCEPTION 'refusal_not_applied' USING HINT = 'PC-38';
          END IF;
          v_changed := true;
        END IF;
      END IF;
      SELECT r.id INTO v_existing FROM relay.refusals r
        WHERE r.tenant_id = v_tenant AND r.environment = v_env
          AND r.request_ref = p_request_ref;
      IF FOUND AND NOT v_changed THEN
        RETURN QUERY SELECT 'exists'::text, v_existing;
        RETURN;
      END IF;
      IF v_existing IS NULL THEN
        PERFORM relay_private.assert_new_id(p_id);
        INSERT INTO relay.refusals (tenant_id, environment, id, recipient_id,
          brand_subtenant_id, channel, source, scope, category_key, request_ref, occurred_at,
          evidence_ct, evidence_key_id, created_at)
        VALUES (v_tenant, v_env, p_id, p_recipient_id, p_brand_subtenant_id, p_channel,
          p_source, p_scope, p_category_key, p_request_ref, p_occurred_at, p_evidence_ct,
          p_evidence_key_id, now());
        IF p_channel = 'sms' AND p_source = 'sms_keyword' THEN
          PERFORM relay_fn.outbox_append(uuidv7(), 'sms.opted_out', v_stream,
            jsonb_build_object('recipient_id', p_recipient_id, 'recipient_kind', v_kind,
              'provider_account_id', p_provider_account_id, 'rule_id', 'consent.revoked',
              'opted_out_at', v_at),
            NULL);
        END IF;
      END IF;
      IF NOT v_changed THEN
        RETURN QUERY SELECT 'applied'::text, p_id;
        RETURN;
      END IF;
      IF p_scope = 'category' THEN
        PERFORM relay_fn.outbox_append(uuidv7(), 'subscription.unsubscribed', v_stream,
          jsonb_build_object('recipient_id', p_recipient_id, 'recipient_kind', v_kind,
            'channel', p_channel, 'category', p_category_key, 'notification_id', NULL,
            'unsubscribed_at', v_at),
          NULL);
      ELSE
        PERFORM relay_fn.outbox_append(uuidv7(), 'consent.revoked', v_stream,
          jsonb_build_object('recipient_id', p_recipient_id, 'recipient_kind', v_kind,
            'channel', p_channel, 'source', p_source, 'scope', p_scope, 'revoked_at', v_at),
          NULL);
      END IF;
      IF v_existing IS NOT NULL THEN
        RETURN QUERY SELECT 'reapplied'::text, v_existing;
        RETURN;
      END IF;
      RETURN QUERY SELECT 'applied'::text, p_id;
    END
    $fn$
    """
  end
end
