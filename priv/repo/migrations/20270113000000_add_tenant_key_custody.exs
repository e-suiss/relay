defmodule Relay.Repo.Migrations.AddTenantKeyCustody do
  use Ecto.Migration

  @actor "text, text, text, text"
  @functions [
    "relay_fn.tenant_key_custody_set(text, bytea, #{@actor})",
    "relay_fn.tenant_key_rewrap(uuid, text, text, bytea)"
  ]

  # OP-85
  # TN-27
  # TN-63
  # OP-57
  def up do
    execute("ALTER TABLE relay.tenants ADD COLUMN key_ref text")

    execute(~S"""
    ALTER TABLE relay.tenants ADD CONSTRAINT tenants_key_ref_check
      CHECK (key_ref IS NULL OR (char_length(key_ref) <= 512 AND left(key_ref, 7) = 'pkcs11:'))
      NOT VALID
    """)

    execute(custody_set())
    execute(rewrap())

    for signature <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      execute("GRANT EXECUTE ON FUNCTION #{signature} TO relay_app")
      execute("ALTER FUNCTION #{signature} OWNER TO relay_owner")
    end
  end

  def down, do: :ok

  defp custody_set do
    ~S"""
    CREATE FUNCTION relay_fn.tenant_key_custody_set(p_key_ref text, p_record_digest bytea,
      p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant relay.tenants;
    BEGIN
      IF p_key_ref IS NULL OR char_length(p_key_ref) > 512 OR left(p_key_ref, 7) <> 'pkcs11:' THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-85';
      END IF;
      IF relay_private.ctx_environment() <> 'live' THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-46';
      END IF;
      SELECT * INTO v_tenant FROM relay.tenants t
        WHERE t.id = relay_private.ctx_tenant_id() FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'scope_missing' USING HINT = 'TN-13';
      END IF;
      IF v_tenant.status = 'closed' THEN
        RETURN 'tenant_closed';
      END IF;
      IF v_tenant.key_ref IS NOT DISTINCT FROM p_key_ref THEN
        RETURN 'unchanged';
      END IF;
      UPDATE relay.tenants t SET key_ref = p_key_ref, version = t.version + 1, updated_at = now()
        WHERE t.id = v_tenant.id;
      PERFORM relay_private.audit_write(v_tenant.id, 'live', 'tenant.key_custody_changed',
        p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'tenant',
        v_tenant.id::text, p_key_ref, p_record_digest);
      RETURN 'changed';
    END
    $fn$
    """
  end

  defp rewrap do
    ~S"""
    CREATE FUNCTION relay_fn.tenant_key_rewrap(p_key_id uuid, p_expected_kek_ref text,
      p_kek_ref text, p_wrapped_key bytea) RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_key relay.tenant_keys;
    BEGIN
      IF p_key_id IS NULL OR p_expected_kek_ref IS NULL OR p_kek_ref IS NULL
        OR p_wrapped_key IS NULL OR char_length(p_kek_ref) > 512 THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-85';
      END IF;
      SELECT * INTO v_key FROM relay.tenant_keys k
        WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.id = p_key_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      IF v_key.state = 'destroyed' THEN
        RETURN 'destroyed';
      END IF;
      IF v_key.kek_ref = p_kek_ref THEN
        RETURN 'unchanged';
      END IF;
      IF v_key.kek_ref <> p_expected_kek_ref THEN
        RETURN 'conflict';
      END IF;
      UPDATE relay.tenant_keys k SET kek_ref = p_kek_ref, wrapped_key = p_wrapped_key
        WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.id = p_key_id;
      RETURN 'rewrapped';
    END
    $fn$
    """
  end
end
