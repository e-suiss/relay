defmodule Relay.Repo.Migrations.CreateProviderTables do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  # C-25
  # C-26
  # C-45
  # INV-43
  # MD-4
  # CH-6
  # CH-13
  # CH-14
  # TN-10
  # TN-26
  # TN-58
  def up do
    execute(~S"""
    CREATE TABLE relay.provider_accounts (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      id uuid NOT NULL,
      channel relay.channel NOT NULL,
      provider text NOT NULL
        CONSTRAINT provider_accounts_provider_check CHECK (provider ~ '^[a-z][a-z0-9_]{1,31}$'),
      ownership text NOT NULL
        CONSTRAINT provider_accounts_ownership_check CHECK (ownership IN ('shared', 'tenant')),
      credential_ref_id uuid,
      role text NOT NULL CONSTRAINT provider_accounts_role_check CHECK (role IN ('primary', 'backup')),
      priority bigint NOT NULL
        CONSTRAINT provider_accounts_priority_check CHECK (priority BETWEEN 0 AND 99),
      weight bigint NOT NULL CONSTRAINT provider_accounts_weight_check CHECK (weight BETWEEN 0 AND 10000),
      state text NOT NULL CONSTRAINT provider_accounts_state_check CHECK (state IN ('active', 'disabled')),
      verification_state text NOT NULL
        CONSTRAINT provider_accounts_verification_state_check
          CHECK (verification_state IN ('unverified', 'pending', 'verified', 'failed')),
      verified_at timestamptz,
      verification_rule_id relay.rule_id,
      in_installation boolean NOT NULL,
      processing_countries text[] NOT NULL
        CONSTRAINT provider_accounts_processing_countries_check
          CHECK (cardinality(processing_countries) <= 16
            AND array_to_string(processing_countries, ',') ~ '^([A-Z]{2}(,[A-Z]{2})*)?$'),
      transfer_basis text NOT NULL
        CONSTRAINT provider_accounts_transfer_basis_check
          CHECK (transfer_basis IN ('none', 'adequacy', 'scc', 'explicit_consent', 'derogation')),
      scc_notified_on date,
      health text NOT NULL
        CONSTRAINT provider_accounts_health_check
          CHECK (health IN ('unknown', 'healthy', 'degraded', 'down')),
      health_checked_at timestamptz,
      settings jsonb NOT NULL
        CONSTRAINT provider_accounts_settings_check CHECK (pg_column_size(settings) <= 8192),
      version bigint NOT NULL,
      created_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      CONSTRAINT provider_accounts_pkey PRIMARY KEY (tenant_id, environment, id),
      CONSTRAINT provider_accounts_credential_check
        CHECK ((ownership = 'tenant') = (credential_ref_id IS NOT NULL)),
      CONSTRAINT provider_accounts_verified_check
        CHECK ((verification_state = 'verified') = (verified_at IS NOT NULL)),
      CONSTRAINT provider_accounts_residency_check
        CHECK (in_installation OR cardinality(processing_countries) >= 1),
      CONSTRAINT provider_accounts_scc_check
        CHECK (transfer_basis <> 'scc' OR scc_notified_on IS NOT NULL),
      CONSTRAINT provider_accounts_credential_ref_id_fkey
        FOREIGN KEY (tenant_id, environment, credential_ref_id)
        REFERENCES relay.secret_refs (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
    )
    """)

    execute("""
    CREATE INDEX provider_accounts_route_index ON relay.provider_accounts
      (tenant_id, environment, channel, priority)
    """)

    scoped("provider_accounts")

    execute(~S"""
    CREATE TABLE relay.sender_identities (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      id uuid NOT NULL,
      provider_account_id uuid NOT NULL,
      subtenant_id uuid,
      channel relay.channel NOT NULL,
      kind text NOT NULL
        CONSTRAINT sender_identities_kind_check
          CHECK (kind IN ('email_domain', 'email_address', 'sms_sender', 'phone_number',
            'whatsapp_number', 'bot')),
      value text NOT NULL
        CONSTRAINT sender_identities_value_check CHECK (char_length(value) BETWEEN 1 AND 320),
      country text CONSTRAINT sender_identities_country_check CHECK (country ~ '^[A-Z]{2}$'),
      approval_state text NOT NULL
        CONSTRAINT sender_identities_approval_state_check
          CHECK (approval_state IN ('pending', 'approved', 'rejected')),
      suspended_at timestamptz,
      suspension_rule_id relay.rule_id,
      version bigint NOT NULL,
      created_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      CONSTRAINT sender_identities_pkey PRIMARY KEY (tenant_id, environment, id),
      CONSTRAINT sender_identities_value_key
        UNIQUE (tenant_id, environment, provider_account_id, kind, value),
      CONSTRAINT sender_identities_suspension_check
        CHECK ((suspended_at IS NULL) = (suspension_rule_id IS NULL)),
      CONSTRAINT sender_identities_provider_account_id_fkey
        FOREIGN KEY (tenant_id, environment, provider_account_id)
        REFERENCES relay.provider_accounts (tenant_id, environment, id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
      CONSTRAINT sender_identities_subtenant_id_fkey FOREIGN KEY (tenant_id, environment, subtenant_id)
        REFERENCES relay.subtenants (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
    )
    """)

    scoped("sender_identities")

    execute(~S"""
    CREATE TABLE relay.channel_identities (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      id uuid NOT NULL,
      channel relay.channel NOT NULL,
      kind text NOT NULL
        CONSTRAINT channel_identities_kind_check
          CHECK (kind IN ('apns_key', 'fcm_project', 'hms_app', 'vapid', 'slack_app', 'teams_bot',
            'telegram_bot', 'discord_bot')),
      app_ref text NOT NULL
        CONSTRAINT channel_identities_app_ref_check CHECK (char_length(app_ref) BETWEEN 1 AND 256),
      secret_ref_id uuid NOT NULL,
      state text NOT NULL CONSTRAINT channel_identities_state_check CHECK (state IN ('active', 'retired')),
      version bigint NOT NULL,
      created_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      CONSTRAINT channel_identities_pkey PRIMARY KEY (tenant_id, environment, id),
      CONSTRAINT channel_identities_app_ref_key UNIQUE (tenant_id, environment, kind, app_ref),
      CONSTRAINT channel_identities_secret_ref_id_fkey FOREIGN KEY (tenant_id, environment, secret_ref_id)
        REFERENCES relay.secret_refs (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
    )
    """)

    scoped("channel_identities")
  end

  def down, do: :ok

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
