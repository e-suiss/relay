defmodule Relay.Repo.Migrations.CreateApiVersionFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"

  @signature "relay_fn.tenant_api_version_pin(date, boolean, bytea, #{@actor})"

  # API-52
  # API-54
  # OP-8
  def up do
    Enum.each(statements(), &execute/1)
    execute("REVOKE ALL ON FUNCTION #{@signature} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@signature} TO relay_app")
    execute("ALTER FUNCTION #{@signature} OWNER TO relay_owner")
  end

  def down, do: execute("DROP FUNCTION #{@signature}")

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_fn.tenant_api_version_pin(p_version date, p_automatic boolean,
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env text := relay_private.ctx_environment()::text;
        v_current date;
        v_count bigint;
      BEGIN
        IF p_version IS NULL OR p_automatic IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'API-52';
        END IF;
        IF p_version < DATE '2026-11-01' THEN
          RETURN 'unsupported';
        END IF;
        IF p_automatic THEN
          UPDATE relay.tenants t
            SET api_version = p_version, api_version_pinned_at = now(), updated_at = now()
            WHERE t.id = v_tenant AND t.api_version IS NULL;
          GET DIAGNOSTICS v_count = ROW_COUNT;
          IF v_count = 0 THEN
            RETURN 'already_pinned';
          END IF;
          PERFORM relay_private.audit_write(v_tenant, v_env, 'api_version.pinned', p_actor_kind,
            p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'tenant', v_tenant::text, NULL,
            p_record_digest);
          RETURN 'pinned';
        END IF;
        SELECT t.api_version INTO v_current FROM relay.tenants t WHERE t.id = v_tenant FOR UPDATE;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'scope_missing' USING HINT = 'TN-13';
        END IF;
        IF v_current = p_version THEN
          RETURN 'unchanged';
        END IF;
        UPDATE relay.tenants t
          SET api_version = p_version, api_version_pinned_at = now(), updated_at = now()
          WHERE t.id = v_tenant;
        PERFORM relay_private.audit_write(v_tenant, v_env, 'api_version.pinned', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'tenant', v_tenant::text, NULL,
          p_record_digest);
        IF v_current IS NULL THEN
          RETURN 'pinned';
        END IF;
        RETURN 'changed';
      END
      $fn$
      """
    ]
  end
end
