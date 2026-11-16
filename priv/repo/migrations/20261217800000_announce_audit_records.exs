defmodule Relay.Repo.Migrations.AnnounceAuditRecords do
  use Ecto.Migration

  @announce "relay_private.audit_announce(uuid, text, uuid, text, text, text, text)"

  # WH-67
  # E-65
  # TN-49
  # WH-20
  # INV-53
  def up do
    execute("GRANT INSERT ON relay.outbox_events TO relay_maint")
    execute("GRANT INSERT, UPDATE ON relay.stream_heads TO relay_maint")
    execute(announce())
    execute("REVOKE ALL ON FUNCTION #{@announce} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@announce} TO relay_owner")
    execute("GRANT EXECUTE ON FUNCTION #{@announce} TO relay_maint")
    execute(write())
    execute("SET LOCAL ROLE relay_owner")
    execute(append())
    execute("RESET ROLE")
  end

  def down, do: :ok

  defp announce do
    ~S"""
    CREATE FUNCTION relay_private.audit_announce(p_tenant_id uuid, p_environment text, p_id uuid,
      p_action text, p_actor_kind text, p_target_type text, p_target_id text) RETURNS void
    LANGUAGE plpgsql VOLATILE
    SET search_path = pg_catalog, pg_temp
    AS $fn$
    DECLARE
      v_single text := 'audit_record:' || p_id::text;
      v_stream text;
      v_lock bigint;
      v_epoch bigint;
      v_seq bigint;
    BEGIN
      IF p_action = 'audit_log.read' OR p_tenant_id = relay_private.installation_tenant_id() THEN
        RETURN;
      END IF;
      IF p_target_type IS NULL OR p_target_id IS NULL THEN
        v_stream := v_single;
      ELSE
        v_stream := 'audit_target:' || p_target_type || ':' || p_target_id;
        IF v_stream !~ '^[a-z_]+:[A-Za-z0-9_.:-]{1,200}$' THEN
          v_stream := 'audit_target_digest:' || encode(
            sha256(convert_to(p_target_type || chr(31) || p_target_id, 'UTF8')), 'hex');
        END IF;
        v_lock := hashtextextended(
          p_tenant_id::text || '|' || p_environment || '|' || v_stream, 0);
        IF current_setting('relay.audit_head', true) = 'held' THEN
          IF NOT pg_try_advisory_xact_lock(v_lock) THEN
            v_stream := v_single;
          END IF;
        ELSE
          PERFORM pg_advisory_xact_lock(v_lock);
          PERFORM set_config('relay.audit_head', 'held', true);
        END IF;
      END IF;
      INSERT INTO relay.stream_heads AS h (tenant_id, environment, stream_key, epoch, last_seq,
        updated_at)
      VALUES (p_tenant_id, p_environment, v_stream, 1, 1, now())
      ON CONFLICT (tenant_id, environment, stream_key)
        DO UPDATE SET last_seq = h.last_seq + 1, updated_at = now()
      RETURNING h.epoch, h.last_seq INTO v_epoch, v_seq;
      INSERT INTO relay.outbox_events (tenant_id, environment, id, created_at, event_type,
        stream_key, epoch, seq, payload, state, dispatched_at, traceparent)
      VALUES (p_tenant_id, p_environment, uuidv7(), now(), 'audit_record.appended', v_stream,
        v_epoch, v_seq,
        jsonb_strip_nulls(jsonb_build_object('audit_record_id', p_id, 'action', p_action,
          'actor_kind', p_actor_kind, 'target_type', p_target_type, 'target_id', p_target_id)),
        'pending', NULL, NULL);
    END
    $fn$
    """
  end

  defp write do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_private.audit_write(p_tenant_id uuid, p_environment text,
      p_action text, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
      p_access_record_ref text, p_target_type text, p_target_id text, p_reason text,
      p_record_digest bytea) RETURNS uuid
    LANGUAGE plpgsql VOLATILE
    SET search_path = pg_catalog, pg_temp
    AS $fn$
    DECLARE
      v_id uuid := uuidv7();
    BEGIN
      IF p_record_digest IS NULL OR p_actor_kind IS NULL OR p_actor_ref IS NULL
        OR p_on_behalf_of_ref IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-48';
      END IF;
      INSERT INTO relay.audit_log (tenant_id, environment, id, created_at, action, actor_kind,
        actor_ref, on_behalf_of_ref, access_record_ref, target_type, target_id, reason,
        record_digest)
      VALUES (p_tenant_id, p_environment, v_id, now(), p_action, p_actor_kind, p_actor_ref,
        p_on_behalf_of_ref, p_access_record_ref, p_target_type, p_target_id, p_reason,
        p_record_digest);
      PERFORM relay_private.audit_announce(p_tenant_id, p_environment, v_id, p_action,
        p_actor_kind, p_target_type, p_target_id);
      RETURN v_id;
    END
    $fn$
    """
  end

  defp append do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_fn.audit_append(p_id uuid, p_action text, p_actor_kind text,
      p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text, p_target_type text,
      p_target_id text, p_reason text, p_details_ct bytea, p_details_key_id uuid,
      p_record_digest bytea) RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    BEGIN
      PERFORM relay_private.assert_new_id(p_id);
      IF p_action IS NULL OR p_actor_kind IS NULL OR p_actor_ref IS NULL
        OR p_on_behalf_of_ref IS NULL OR p_record_digest IS NULL
        OR (p_details_ct IS NULL) <> (p_details_key_id IS NULL) THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-48';
      END IF;
      INSERT INTO relay.audit_log (tenant_id, environment, id, created_at, action, actor_kind,
        actor_ref, on_behalf_of_ref, access_record_ref, target_type, target_id, reason, details_ct,
        details_key_id, record_digest)
      VALUES (relay_private.ctx_tenant_id(), relay_private.ctx_environment(), p_id, now(), p_action,
        p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, p_target_type,
        p_target_id, p_reason, p_details_ct, p_details_key_id, p_record_digest);
      PERFORM relay_private.audit_announce(relay_private.ctx_tenant_id(),
        relay_private.ctx_environment()::text, p_id, p_action, p_actor_kind, p_target_type,
        p_target_id);
      RETURN 'appended';
    END
    $fn$
    """
  end
end
