defmodule Relay.Repo.Migrations.CreateDomains do
  use Ecto.Migration

  # OP-1
  # TN-7
  # C-33
  # C-43
  # OP-18
  # INV-6
  # INV-49
  def up do
    execute(~S"""
    CREATE DOMAIN relay.environment AS text
      CONSTRAINT environment_check CHECK (VALUE IN ('live', 'test'))
    """)

    execute(~S"""
    CREATE DOMAIN relay.region AS text
      CONSTRAINT region_check CHECK (VALUE IN ('tr', 'eu', 'us'))
    """)

    execute(~S"""
    CREATE DOMAIN relay.message_class AS text
      CONSTRAINT message_class_check CHECK (VALUE IN ('security', 'transactional', 'operational',
        'social', 'marketing', 'system', 'action_required'))
    """)

    execute(~S"""
    CREATE DOMAIN relay.channel AS text
      CONSTRAINT channel_check CHECK (VALUE IN ('push', 'web_push', 'email', 'sms', 'voice',
        'whatsapp', 'slack', 'teams', 'telegram', 'discord', 'in_app', 'webhook'))
    """)

    execute(~S"""
    CREATE DOMAIN relay.event_name AS text
      CONSTRAINT event_name_check
        CHECK (VALUE ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$' AND char_length(VALUE) <= 128)
    """)

    execute(~S"""
    CREATE DOMAIN relay.sha256 AS bytea
      CONSTRAINT sha256_check CHECK (octet_length(VALUE) = 32)
    """)

    execute(~S"""
    CREATE DOMAIN relay.idempotency_key AS text
      CONSTRAINT idempotency_key_check CHECK (char_length(VALUE) BETWEEN 8 AND 255)
    """)

    execute(~S"""
    CREATE DOMAIN relay.retention_class AS text
      CONSTRAINT retention_class_check CHECK (VALUE IN ('recipient_profile', 'notification_content',
        'delivery_record', 'commercial_consent', 'commercial_message', 'preference', 'audit',
        'traffic', 'suppression', 'dsr_log', 'erasure_log'))
    """)

    execute(~S"""
    CREATE DOMAIN relay.actor_kind AS text
      CONSTRAINT actor_kind_check CHECK (VALUE IN ('operator', 'installation_operator', 'api_client',
        'access', 'system'))
    """)

    execute(~S"""
    CREATE DOMAIN relay.e164 AS text
      CONSTRAINT e164_check CHECK (VALUE ~ '^\+[1-9][0-9]{6,14}$' AND VALUE !~ '^\+900')
    """)

    execute(~S"""
    CREATE FUNCTION relay_private.reject_mutation() RETURNS trigger
      LANGUAGE plpgsql
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
    AS $$
    BEGIN
      RAISE EXCEPTION 'invariant_violation'
        USING DETAIL = format('%s on %I.%I is not allowed', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME),
              HINT = 'INV-6';
    END
    $$
    """)

    execute("REVOKE ALL ON FUNCTION relay_private.reject_mutation() FROM PUBLIC")
  end
end
