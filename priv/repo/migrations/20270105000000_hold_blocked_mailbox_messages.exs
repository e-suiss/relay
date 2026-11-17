defmodule Relay.Repo.Migrations.HoldBlockedMailboxMessages do
  use Ecto.Migration

  # AG-38
  # AG-61
  # AG-69
  # AG-84
  def up do
    execute("SET LOCAL ROLE relay_owner")
    execute(message_append())
    execute("RESET ROLE")
  end

  def down, do: :ok

  defp message_append do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_fn.mailbox_message_append(p_id uuid, p_mailbox_id uuid,
      p_trust_label text, p_payload_ct bytea, p_content_ref_ct bytea,
      p_payload_tenant_key_id uuid, p_payload_digest bytea, p_traceparent text)
      RETURNS TABLE (result text, epoch bigint, seq bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_state text;
      v_stream text;
      v_epoch bigint;
      v_seq bigint;
    BEGIN
      PERFORM relay_private.assert_new_id(p_id);
      IF p_trust_label IS NULL
        OR p_trust_label NOT IN ('blocked', 'spam', 'authenticated', 'unauthenticated')
        OR p_payload_ct IS NULL OR p_payload_tenant_key_id IS NULL
        OR p_payload_digest IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-69';
      END IF;
      SELECT m.state, m.stream_key INTO v_state, v_stream FROM relay.mailboxes m
        WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = p_mailbox_id
          AND m.owner_kind IN ('agent', 'api_client');
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'mailbox_not_found'::text, NULL::bigint, NULL::bigint;
        RETURN;
      END IF;
      IF v_state <> 'active' THEN
        RETURN QUERY SELECT 'mailbox_inactive'::text, NULL::bigint, NULL::bigint;
        RETURN;
      END IF;
      IF p_trust_label = 'blocked' THEN
        SELECT n.epoch, n.seq INTO v_epoch, v_seq FROM relay_fn.stream_next_seq(v_stream) n;
        INSERT INTO relay.mailbox_records (tenant_id, environment, id, created_at, mailbox_id,
          epoch, seq, kind, event_type, payload_ct, payload_tenant_key_id, payload_digest,
          delivery_state, delivery_count, traceparent, updated_at, trust_label, content_ref_ct)
        VALUES (v_tenant, v_env, p_id, now(), p_mailbox_id, v_epoch, v_seq, 'blocked_message',
          'message.blocked', p_payload_ct, p_payload_tenant_key_id, p_payload_digest, 'held', 0,
          p_traceparent, now(), NULL, NULL);
        RETURN QUERY SELECT 'appended'::text, v_epoch, v_seq;
        RETURN;
      END IF;
      SELECT o.epoch, o.seq INTO v_epoch, v_seq
        FROM relay_fn.outbox_append(uuidv7(),
          CASE WHEN p_trust_label = 'spam' THEN 'mailbox.record_flagged'
            ELSE 'mailbox.record_appended' END,
          v_stream,
          jsonb_build_object('mailbox_id', p_mailbox_id, 'record_id', p_id, 'kind', 'message',
            'trust_label', p_trust_label),
          p_traceparent) o;
      INSERT INTO relay.mailbox_records (tenant_id, environment, id, created_at, mailbox_id, epoch,
        seq, kind, event_type, payload_ct, payload_tenant_key_id, payload_digest, delivery_state,
        delivery_count, traceparent, updated_at, trust_label, content_ref_ct)
      VALUES (v_tenant, v_env, p_id, now(), p_mailbox_id, v_epoch, v_seq, 'message',
        'message.' || p_trust_label, p_payload_ct, p_payload_tenant_key_id, p_payload_digest,
        'available', 0, p_traceparent, now(), p_trust_label, p_content_ref_ct);
      RETURN QUERY SELECT 'appended'::text, v_epoch, v_seq;
    END
    $fn$
    """
  end
end
