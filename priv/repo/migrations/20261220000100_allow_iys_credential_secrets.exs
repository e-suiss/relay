defmodule Relay.Repo.Migrations.AllowIysCredentialSecrets do
  use Ecto.Migration

  # PC-29
  # TN-26
  # OP-57
  def up do
    execute("ALTER TABLE relay.secret_refs DROP CONSTRAINT secret_refs_kind_check")

    execute("""
    ALTER TABLE relay.secret_refs ADD CONSTRAINT secret_refs_kind_check
      CHECK (kind IN ('provider_credential', 'channel_identity', 'webhook_signing',
        'webhook_destination', 'iys_credential')) NOT VALID
    """)

    execute("SET LOCAL ROLE relay_owner")
    execute(register())
    execute("RESET ROLE")
  end

  def down, do: :ok

  defp register do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_fn.secret_ref_register(p_id uuid, p_kind text, p_ref text,
      p_secret_ct bytea, p_secret_key_id uuid, p_ref_version bigint, p_fingerprint bytea,
      p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
      p_access_record_ref text) RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
    BEGIN
      IF p_kind IS NULL OR p_kind NOT IN ('provider_credential', 'channel_identity',
          'webhook_signing', 'webhook_destination', 'iys_credential')
        OR (p_ref IS NULL) = (p_secret_ct IS NULL)
        OR (p_secret_ct IS NULL) <> (p_secret_key_id IS NULL)
        OR p_ref ~ '://[^/]*:[^@/]*@'
        OR p_ref_version IS NULL
        OR p_fingerprint IS NULL OR octet_length(p_fingerprint) <> 32 THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-26';
      END IF;
      PERFORM relay_private.lock_scope(ARRAY['secret_ref', p_kind, encode(p_fingerprint, 'hex')]);
      IF EXISTS (SELECT 1 FROM relay.secret_refs s
        WHERE s.tenant_id = v_tenant AND s.environment = v_env
          AND (s.id = p_id OR (s.kind = p_kind AND s.fingerprint = p_fingerprint))) THEN
        RETURN 'exists';
      END IF;
      PERFORM relay_private.assert_new_id(p_id);
      INSERT INTO relay.secret_refs (tenant_id, environment, id, kind, ref, secret_ct,
        secret_key_id, ref_version, fingerprint, state, created_at, retired_at)
      VALUES (v_tenant, v_env, p_id, p_kind, p_ref, p_secret_ct, p_secret_key_id, p_ref_version,
        p_fingerprint, 'active', now(), NULL);
      PERFORM relay_private.audit_write(v_tenant, v_env, 'secret_ref.registered', p_actor_kind,
        p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'secret_ref', p_id::text, NULL,
        p_record_digest);
      RETURN 'created';
    END
    $fn$
    """
  end
end
