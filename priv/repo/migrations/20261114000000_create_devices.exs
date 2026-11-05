defmodule Relay.Repo.Migrations.CreateDevices do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  # C-23
  # CH-28
  # CH-31
  # CH-74
  # API-67
  # TN-12
  # TN-13
  # TN-33
  # OP-9
  def up do
    execute(~S"""
    CREATE TABLE relay.devices (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      id uuid NOT NULL,
      recipient_id uuid NOT NULL,
      platform text NOT NULL
        CONSTRAINT devices_platform_check
          CHECK (platform IN ('apns', 'fcm', 'hms', 'web_push', 'unified_push')),
      app text NOT NULL
        CONSTRAINT devices_app_check
          CHECK (char_length(app) BETWEEN 1 AND 256 AND app ~ '^[A-Za-z0-9._:/-]+$'),
      token_ct bytea NOT NULL,
      token_key_id uuid NOT NULL,
      token_bidx bytea CONSTRAINT devices_token_bidx_check CHECK (octet_length(token_bidx) = 32),
      token_bidx_key_id uuid,
      token_bidx_next bytea
        CONSTRAINT devices_token_bidx_next_check CHECK (octet_length(token_bidx_next) = 32),
      fingerprint text NOT NULL
        CONSTRAINT devices_fingerprint_check CHECK (fingerprint ~ '^[0-9a-f]{16}$'),
      apns_environment text
        CONSTRAINT devices_apns_environment_check
          CHECK (apns_environment IN ('production', 'sandbox')),
      permission text NOT NULL
        CONSTRAINT devices_permission_check
          CHECK (permission IN ('granted', 'denied', 'provisional', 'not_determined')),
      android_channels jsonb NOT NULL
        CONSTRAINT devices_android_channels_check
          CHECK (jsonb_typeof(android_channels) = 'array' AND pg_column_size(android_channels) <= 8192),
      locale text CONSTRAINT devices_locale_check CHECK (locale ~ '^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$'),
      state text NOT NULL
        CONSTRAINT devices_state_check CHECK (state IN ('active', 'stale', 'disabled')),
      disabled_reason text
        CONSTRAINT devices_disabled_reason_check
          CHECK (disabled_reason IN ('unregistered', 'logout', 'removed', 'replaced', 'inactive',
            'device_limit', 'reassigned', 'erased')),
      registered_at timestamptz NOT NULL,
      last_seen_at timestamptz NOT NULL,
      deleted_at timestamptz,
      created_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      CONSTRAINT devices_pkey PRIMARY KEY (tenant_id, environment, id),
      CONSTRAINT devices_disabled_check
        CHECK ((state = 'disabled') = (disabled_reason IS NOT NULL)
          AND (state = 'disabled') = (deleted_at IS NOT NULL)),
      CONSTRAINT devices_apns_check CHECK ((platform = 'apns') = (apns_environment IS NOT NULL)),
      CONSTRAINT devices_token_bidx_present_check
        CHECK (state = 'disabled' OR (token_bidx IS NOT NULL AND token_bidx_key_id IS NOT NULL)),
      CONSTRAINT devices_recipient_id_fkey FOREIGN KEY (tenant_id, environment, recipient_id)
        REFERENCES relay.recipients (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
      CONSTRAINT devices_token_key_id_fkey FOREIGN KEY (tenant_id, environment, token_key_id)
        REFERENCES relay.subject_keys (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
      CONSTRAINT devices_token_bidx_key_id_fkey
        FOREIGN KEY (tenant_id, environment, token_bidx_key_id)
        REFERENCES relay.blind_index_keys (tenant_id, environment, id)
        ON DELETE RESTRICT ON UPDATE RESTRICT
    )
    """)

    execute("""
    CREATE UNIQUE INDEX devices_token_key ON relay.devices
      (tenant_id, environment, token_bidx) WHERE state <> 'disabled'
    """)

    execute("""
    CREATE INDEX devices_token_bidx_next_index ON relay.devices
      (tenant_id, environment, token_bidx_next) WHERE token_bidx_next IS NOT NULL
    """)

    execute("""
    CREATE INDEX devices_recipient_index ON relay.devices
      (tenant_id, environment, recipient_id, last_seen_at) WHERE state <> 'disabled'
    """)

    execute("""
    CREATE INDEX devices_last_seen_index ON relay.devices
      (tenant_id, environment, last_seen_at) WHERE state <> 'disabled'
    """)

    execute(~S"""
    CREATE FUNCTION relay_private.devices_guard() RETURNS trigger
      LANGUAGE plpgsql
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
    AS $fn$
    BEGIN
      IF NEW.tenant_id = OLD.tenant_id AND NEW.environment = OLD.environment
        AND NEW.id = OLD.id AND NEW.recipient_id = OLD.recipient_id
        AND NEW.platform = OLD.platform AND NEW.token_ct = OLD.token_ct
        AND NEW.token_key_id = OLD.token_key_id AND NEW.fingerprint = OLD.fingerprint
        AND NEW.created_at = OLD.created_at
        AND (OLD.state <> 'disabled' OR (NEW.state = 'disabled'
          AND NEW.disabled_reason = OLD.disabled_reason AND NEW.deleted_at = OLD.deleted_at)) THEN
        RETURN NEW;
      END IF;
      RAISE EXCEPTION 'invariant_violation'
        USING DETAIL = format('%s on %I.%I is not allowed', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME),
              HINT = 'C-23';
    END
    $fn$
    """)

    execute("REVOKE ALL ON FUNCTION relay_private.devices_guard() FROM PUBLIC")

    execute("""
    CREATE TRIGGER devices_guard BEFORE UPDATE ON relay.devices
      FOR EACH ROW EXECUTE FUNCTION relay_private.devices_guard()
    """)

    execute("""
    CREATE TRIGGER devices_no_delete BEFORE DELETE ON relay.devices
      FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    execute("ALTER TABLE relay.devices ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE relay.devices FORCE ROW LEVEL SECURITY")

    execute(
      "CREATE POLICY devices_scope ON relay.devices USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})"
    )

    execute("GRANT SELECT, INSERT, UPDATE ON relay.devices TO relay_owner")

    execute(
      "GRANT SELECT ON relay.devices TO relay_app, relay_maint, relay_archive, relay_report"
    )
  end
end
