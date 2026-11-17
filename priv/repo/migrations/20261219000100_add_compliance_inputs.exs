defmodule Relay.Repo.Migrations.AddComplianceInputs do
  use Ecto.Migration

  @recipient_locality_set "relay_fn.recipient_locality_set(uuid, text[], text, text)"
  @device_time_zone_set "relay_fn.device_time_zone_set(uuid, text)"

  # PC-40
  # PC-47
  # WF-45
  # OP-57
  def up do
    execute("ALTER TABLE relay.recipients ADD COLUMN country text")
    execute("ALTER TABLE relay.recipient_addresses ADD COLUMN calling_code text")
    execute("ALTER TABLE relay.devices ADD COLUMN time_zone text")

    execute(~S"""
    ALTER TABLE relay.recipients ADD CONSTRAINT recipients_country_check
      CHECK (country ~ '^[A-Z]{2}$') NOT VALID
    """)

    execute(~S"""
    ALTER TABLE relay.recipient_addresses ADD CONSTRAINT recipient_addresses_calling_code_check
      CHECK (calling_code ~ '^[1-9][0-9]{0,2}$' AND (calling_code IS NULL OR kind = 'phone'))
      NOT VALID
    """)

    execute(~S"""
    ALTER TABLE relay.devices ADD CONSTRAINT devices_time_zone_check
      CHECK (time_zone ~ '^[A-Za-z]+(/[A-Za-z0-9_+-]+)*$' AND time_zone !~ '^Etc/GMT'
        AND time_zone !~ '^(UTC|GMT)[+-]' AND char_length(time_zone) <= 64) NOT VALID
    """)

    execute(~S"""
    CREATE FUNCTION relay_fn.recipient_locality_set(p_recipient_id uuid, p_fields text[],
      p_country text, p_calling_code text)
      RETURNS TABLE (result text, version bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_recipient relay.recipients;
      v_version bigint;
    BEGIN
      IF p_recipient_id IS NULL OR p_fields IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'PC-40';
      END IF;
      SELECT * INTO v_recipient FROM relay.recipients r
        WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_recipient_id
          AND r.kind = 'subscriber' AND r.state = 'active'
        FOR NO KEY UPDATE;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
        RETURN;
      END IF;
      IF 'phone' = ANY (p_fields) THEN
        UPDATE relay.recipient_addresses a SET calling_code = p_calling_code, updated_at = now()
          WHERE a.tenant_id = v_tenant AND a.environment = v_env
            AND a.recipient_id = p_recipient_id AND a.kind = 'phone' AND a.state = 'active'
            AND a.calling_code IS DISTINCT FROM p_calling_code;
      END IF;
      IF 'country' = ANY (p_fields) AND p_country IS DISTINCT FROM v_recipient.country THEN
        UPDATE relay.recipients r SET country = p_country, version = r.version + 1,
            updated_at = now()
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_recipient_id
          RETURNING r.version INTO v_version;
        RETURN QUERY SELECT 'set'::text, v_version;
        RETURN;
      END IF;
      RETURN QUERY SELECT 'unchanged'::text, v_recipient.version;
    END
    $fn$
    """)

    execute(~S"""
    CREATE FUNCTION relay_fn.device_time_zone_set(p_device_id uuid, p_time_zone text)
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
      IF p_device_id IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-45';
      END IF;
      SELECT * INTO v_device FROM relay.devices d
        WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_device_id
        FOR NO KEY UPDATE;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      IF v_device.time_zone IS NOT DISTINCT FROM p_time_zone THEN
        RETURN 'unchanged';
      END IF;
      UPDATE relay.devices d SET time_zone = p_time_zone
        WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_device_id;
      RETURN 'set';
    END
    $fn$
    """)

    for signature <- [@recipient_locality_set, @device_time_zone_set] do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      execute("GRANT EXECUTE ON FUNCTION #{signature} TO relay_app")
      execute("ALTER FUNCTION #{signature} OWNER TO relay_owner")
    end
  end

  def down, do: :ok
end
