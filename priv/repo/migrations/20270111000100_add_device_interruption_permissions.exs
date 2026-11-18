defmodule Relay.Repo.Migrations.AddDeviceInterruptionPermissions do
  use Ecto.Migration

  @set "relay_fn.device_interruption_permissions_set(uuid, jsonb)"

  # CH-65
  # OP-57
  def up do
    execute("ALTER TABLE relay.devices ADD COLUMN interruption_permissions jsonb")

    execute(~S"""
    ALTER TABLE relay.devices ADD CONSTRAINT devices_interruption_permissions_check
      CHECK (jsonb_typeof(interruption_permissions) = 'object'
        AND pg_column_size(interruption_permissions) <= 512) NOT VALID
    """)

    execute(~S"""
    CREATE FUNCTION relay_fn.device_interruption_permissions_set(p_device_id uuid,
      p_permissions jsonb)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_device relay.devices;
    BEGIN
      IF p_device_id IS NULL
        OR (p_permissions IS NOT NULL AND jsonb_typeof(p_permissions) <> 'object') THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'CH-65';
      END IF;
      SELECT * INTO v_device FROM relay.devices d
        WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_device_id
        FOR NO KEY UPDATE;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      IF v_device.interruption_permissions IS NOT DISTINCT FROM p_permissions THEN
        RETURN 'unchanged';
      END IF;
      UPDATE relay.devices d SET interruption_permissions = p_permissions
        WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_device_id;
      RETURN 'set';
    END
    $fn$
    """)

    execute("REVOKE ALL ON FUNCTION #{@set} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@set} TO relay_app")
    execute("ALTER FUNCTION #{@set} OWNER TO relay_owner")
  end

  def down, do: :ok
end
