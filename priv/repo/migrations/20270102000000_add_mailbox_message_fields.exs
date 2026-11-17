defmodule Relay.Repo.Migrations.AddMailboxMessageFields do
  use Ecto.Migration

  @signature "relay_fn.mailbox_message_append(uuid, uuid, text, bytea, bytea, uuid, bytea, text)"

  # C-76
  # C-77
  # AG-38
  # AG-40
  # AG-69
  # AG-70
  # OP-57
  def up do
    execute("ALTER TABLE relay.mailbox_records ADD COLUMN trust_label text")
    execute("ALTER TABLE relay.mailbox_records ADD COLUMN content_ref_ct bytea")

    execute(~S"""
    ALTER TABLE relay.mailbox_records ADD CONSTRAINT mailbox_records_trust_label_check
      CHECK (trust_label IS NULL OR (kind = 'message'
        AND trust_label IN ('blocked', 'spam', 'authenticated', 'unauthenticated')))
      NOT VALID
    """)

    execute(~S"""
    ALTER TABLE relay.mailbox_records ADD CONSTRAINT mailbox_records_content_ref_ct_check
      CHECK (content_ref_ct IS NULL
        OR (kind = 'message' AND octet_length(content_ref_ct) <= 1048576 + 29))
      NOT VALID
    """)

    execute(message_append())
    execute("REVOKE ALL ON FUNCTION #{@signature} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@signature} TO relay_app")
    execute("ALTER FUNCTION #{@signature} OWNER TO relay_owner")
  end

  def down, do: :ok

  defp message_append do
    ~S"""
    CREATE FUNCTION relay_fn.mailbox_message_append(p_id uuid, p_mailbox_id uuid,
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
      SELECT o.epoch, o.seq INTO v_epoch, v_seq
        FROM relay_fn.outbox_append(uuidv7(),
          CASE WHEN p_trust_label IN ('blocked', 'spam') THEN 'mailbox.record_flagged'
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
