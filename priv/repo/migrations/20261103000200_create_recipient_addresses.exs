defmodule Relay.Repo.Migrations.CreateRecipientAddresses do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  # API-21
  # API-66
  # C-19
  # C-21
  # TN-12
  # TN-13
  # OP-9
  def up do
    execute(~S"""
    CREATE TABLE relay.recipient_addresses (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      id uuid NOT NULL,
      recipient_id uuid NOT NULL,
      kind text NOT NULL CONSTRAINT recipient_addresses_kind_check CHECK (kind IN ('email', 'phone')),
      address_ct bytea NOT NULL,
      address_key_id uuid NOT NULL,
      address_bidx bytea
        CONSTRAINT recipient_addresses_address_bidx_check CHECK (octet_length(address_bidx) = 32),
      address_bidx_key_id uuid,
      address_bidx_next bytea
        CONSTRAINT recipient_addresses_address_bidx_next_check
          CHECK (octet_length(address_bidx_next) = 32),
      state text NOT NULL
        CONSTRAINT recipient_addresses_state_check
          CHECK (state IN ('active', 'replaced', 'disabled', 'deleted')),
      disabled_rule_id relay.rule_id,
      state_changed_at timestamptz NOT NULL,
      created_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      CONSTRAINT recipient_addresses_pkey PRIMARY KEY (tenant_id, environment, id),
      CONSTRAINT recipient_addresses_disabled_check
        CHECK ((state = 'disabled') = (disabled_rule_id IS NOT NULL)),
      CONSTRAINT recipient_addresses_recipient_id_fkey
        FOREIGN KEY (tenant_id, environment, recipient_id)
        REFERENCES relay.recipients (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
      CONSTRAINT recipient_addresses_address_key_id_fkey
        FOREIGN KEY (tenant_id, environment, address_key_id)
        REFERENCES relay.subject_keys (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
      CONSTRAINT recipient_addresses_address_bidx_key_id_fkey
        FOREIGN KEY (tenant_id, environment, address_bidx_key_id)
        REFERENCES relay.blind_index_keys (tenant_id, environment, id)
        ON DELETE RESTRICT ON UPDATE RESTRICT
    )
    """)

    execute("""
    CREATE UNIQUE INDEX recipient_addresses_active_key ON relay.recipient_addresses
      (tenant_id, environment, recipient_id, kind) WHERE state = 'active'
    """)

    execute("""
    CREATE INDEX recipient_addresses_address_bidx_index ON relay.recipient_addresses
      (tenant_id, environment, kind, address_bidx)
    """)

    scoped("recipient_addresses")

    execute(~S"""
    CREATE TABLE relay.recipient_deletion_requests (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      id uuid NOT NULL,
      recipient_id uuid NOT NULL,
      status text NOT NULL
        CONSTRAINT recipient_deletion_requests_status_check
          CHECK (status IN ('pending', 'completed', 'held')),
      erasure_id uuid,
      requested_by_ref text NOT NULL
        CONSTRAINT recipient_deletion_requests_requested_by_ref_check
          CHECK (char_length(requested_by_ref) BETWEEN 1 AND 256),
      created_at timestamptz NOT NULL,
      completed_at timestamptz,
      updated_at timestamptz NOT NULL,
      CONSTRAINT recipient_deletion_requests_pkey PRIMARY KEY (tenant_id, environment, id),
      CONSTRAINT recipient_deletion_requests_erasure_check
        CHECK ((status = 'completed') = (erasure_id IS NOT NULL)),
      CONSTRAINT recipient_deletion_requests_completed_at_check
        CHECK ((status = 'completed') = (completed_at IS NOT NULL)),
      CONSTRAINT recipient_deletion_requests_recipient_id_fkey
        FOREIGN KEY (tenant_id, environment, recipient_id)
        REFERENCES relay.recipients (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT,
      CONSTRAINT recipient_deletion_requests_erasure_id_fkey
        FOREIGN KEY (tenant_id, environment, erasure_id)
        REFERENCES relay.erasure_log (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
    )
    """)

    execute("""
    CREATE UNIQUE INDEX recipient_deletion_requests_pending_key ON relay.recipient_deletion_requests
      (tenant_id, environment, recipient_id) WHERE status = 'pending'
    """)

    scoped("recipient_deletion_requests")
  end

  defp scoped(table) do
    execute("ALTER TABLE relay.#{table} ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE relay.#{table} FORCE ROW LEVEL SECURITY")

    execute(
      "CREATE POLICY #{table}_scope ON relay.#{table} USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})"
    )

    execute("GRANT SELECT, INSERT, UPDATE ON relay.#{table} TO relay_owner")

    execute(
      "GRANT SELECT ON relay.#{table} TO relay_app, relay_maint, relay_archive, relay_report"
    )
  end
end
