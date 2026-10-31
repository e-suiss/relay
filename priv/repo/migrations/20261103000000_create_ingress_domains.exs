defmodule Relay.Repo.Migrations.CreateIngressDomains do
  use Ecto.Migration

  # API-6
  # API-57
  # OP-51
  # API-62
  def up do
    execute(~S"""
    CREATE DOMAIN relay.workflow_key AS text
      CONSTRAINT workflow_key_check
        CHECK (VALUE ~ '^[a-z0-9]+(-[a-z0-9]+)*$' AND char_length(VALUE) <= 100)
    """)

    execute(~S"""
    CREATE DOMAIN relay.cancellation_key AS text
      CONSTRAINT cancellation_key_check
        CHECK (VALUE ~ '^[\x21-\x7e]+$' AND char_length(VALUE) <= 256)
    """)

    execute(~S"""
    DO $do$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = 'relay' AND t.typname = 'send_mode') THEN
        CREATE DOMAIN relay.send_mode AS text
          CONSTRAINT send_mode_check CHECK (VALUE IN ('live', 'shadow', 'dry_run', 'off'));
      END IF;
    END
    $do$
    """)
  end
end
