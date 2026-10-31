defmodule Relay.Repo.Migrations.ExtendRecipientProfiles do
  use Ecto.Migration

  # API-21
  # API-66
  # C-19
  # C-27
  # OP-57 (3)
  def up do
    execute("""
    ALTER TABLE relay.recipients
      ADD COLUMN name_ct bytea,
      ADD COLUMN attributes_ct bytea,
      ADD COLUMN profile_key_id uuid,
      ADD COLUMN locale text,
      ADD COLUMN timezone text,
      ADD COLUMN legal_type text,
      ADD COLUMN inbox_only boolean NOT NULL DEFAULT false,
      ADD COLUMN version bigint NOT NULL DEFAULT 1
    """)

    execute("ALTER TABLE relay.recipients DROP CONSTRAINT recipients_state_check")

    execute(~S"""
    ALTER TABLE relay.recipients ADD CONSTRAINT recipients_state_check
      CHECK (state IN ('active', 'deletion_requested', 'deleted')) NOT VALID
    """)

    execute(~S"""
    ALTER TABLE relay.recipients ADD CONSTRAINT recipients_locale_check
      CHECK (locale ~ '^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$') NOT VALID
    """)

    execute(~S"""
    ALTER TABLE relay.recipients ADD CONSTRAINT recipients_timezone_check
      CHECK (timezone ~ '^[A-Za-z]+(/[A-Za-z0-9_+-]+)*$' AND timezone !~ '^Etc/GMT'
        AND timezone !~ '^(UTC|GMT)[+-]') NOT VALID
    """)

    execute(~S"""
    ALTER TABLE relay.recipients ADD CONSTRAINT recipients_legal_type_check
      CHECK (legal_type IN ('individual', 'merchant')) NOT VALID
    """)

    execute(~S"""
    ALTER TABLE relay.recipients ADD CONSTRAINT recipients_version_check
      CHECK (version >= 1) NOT VALID
    """)

    execute("""
    ALTER TABLE relay.recipients ADD CONSTRAINT recipients_profile_key_id_fkey
      FOREIGN KEY (tenant_id, environment, profile_key_id)
      REFERENCES relay.subject_keys (tenant_id, environment, id)
      ON DELETE RESTRICT ON UPDATE RESTRICT DEFERRABLE INITIALLY DEFERRED NOT VALID
    """)
  end
end
