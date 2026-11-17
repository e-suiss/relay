defmodule Relay.Repo.Migrations.AllowRefusalSuppressions do
  use Ecto.Migration

  # PC-38
  # PC-39
  # PC-59 (2)
  # OP-57
  def up do
    execute("ALTER TABLE relay.suppressions DROP CONSTRAINT suppressions_reason_check")

    execute("""
    ALTER TABLE relay.suppressions ADD CONSTRAINT suppressions_reason_check
      CHECK (reason IN ('hard_bounce', 'complaint', 'invalid', 'soft_bounce', 'manual',
        'refusal')) NOT VALID
    """)

    execute("SET LOCAL ROLE relay_owner")
    execute(add())
    execute("RESET ROLE")
  end

  def down, do: :ok

  defp add do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_fn.suppression_add(p_id uuid, p_channel text,
      p_target_digest bytea, p_target_digest_key_id uuid, p_target_digest_next bytea,
      p_reason text, p_expires_at timestamptz, p_record_digest bytea, p_actor_kind text,
      p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
      RETURNS TABLE (result text, suppression_id uuid)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_existing uuid;
    BEGIN
      IF p_channel IS NULL OR p_target_digest IS NULL OR octet_length(p_target_digest) <> 32
        OR p_target_digest_key_id IS NULL OR p_reason IS NULL
        OR p_reason NOT IN ('hard_bounce', 'complaint', 'invalid', 'soft_bounce', 'manual',
          'refusal')
        OR p_actor_ref IS NULL
        OR (p_reason = 'manual' AND p_record_digest IS NULL) THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'PC-59';
      END IF;
      IF (p_reason = 'soft_bounce' AND (p_expires_at IS NULL OR p_expires_at <= now()))
        OR (p_reason = 'manual' AND p_expires_at IS NOT NULL AND p_expires_at <= now())
        OR (p_reason IN ('hard_bounce', 'complaint', 'invalid', 'refusal')
          AND p_expires_at IS NOT NULL) THEN
        RETURN QUERY SELECT 'invalid_expiry'::text, NULL::uuid;
        RETURN;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM relay.blind_index_keys k
        WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.id = p_target_digest_key_id
          AND k.state IN ('active', 'rotating')) THEN
        RETURN QUERY SELECT 'key_not_found'::text, NULL::uuid;
        RETURN;
      END IF;
      PERFORM relay_private.lock_scope(ARRAY['suppression', p_channel,
        encode(p_target_digest, 'hex')]);
      SELECT s.id INTO v_existing FROM relay.suppressions s
        WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.channel = p_channel
          AND (s.target_digest = p_target_digest OR s.target_digest_next = p_target_digest)
          AND s.reason = p_reason AND s.lifted_at IS NULL
          AND (s.expires_at IS NULL OR s.expires_at > now())
        LIMIT 1;
      IF FOUND THEN
        RETURN QUERY SELECT 'exists'::text, v_existing;
        RETURN;
      END IF;
      PERFORM relay_private.assert_new_id(p_id);
      INSERT INTO relay.suppressions (tenant_id, environment, id, channel, target_digest,
        target_digest_key_id, target_digest_next, reason, expires_at, created_by_ref,
        lifted_at, lifted_by_ref, lift_reason, created_at, updated_at)
      VALUES (v_tenant, v_env, p_id, p_channel, p_target_digest, p_target_digest_key_id,
        p_target_digest_next, p_reason, p_expires_at, p_actor_ref, NULL, NULL, NULL, now(),
        now());
      IF p_reason = 'manual' THEN
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'suppression.added',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'suppression',
          p_id::text, p_reason, p_record_digest);
      END IF;
      RETURN QUERY SELECT 'added'::text, p_id;
    END
    $fn$
    """
  end
end
