defmodule Relay.Repo.Migrations.CreateAccessTables do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  # E-40
  # E-78
  # API-41
  # API-44
  # API-75
  # TN-24
  # INV-41
  def up do
    Enum.each(statements(), &execute/1)
  end

  defp statements do
    [
      ~S"""
      CREATE DOMAIN relay.api_scope AS text
        CONSTRAINT api_scope_check
          CHECK (VALUE IN ('publish', 'read', 'subscribers', 'config', 'kill_switch'))
      """,
      ~S"""
      CREATE TABLE relay.access_link (
        singleton boolean NOT NULL CONSTRAINT access_link_singleton_check CHECK (singleton),
        issuer text NOT NULL
          CONSTRAINT access_link_issuer_check
            CHECK (issuer ~ '^https://' AND char_length(issuer) <= 512),
        discovery jsonb CONSTRAINT access_link_discovery_check CHECK (pg_column_size(discovery) <= 65536),
        authzen jsonb CONSTRAINT access_link_authzen_check CHECK (pg_column_size(authzen) <= 16384),
        jwks jsonb CONSTRAINT access_link_jwks_check CHECK (pg_column_size(jwks) <= 65536),
        discovery_digest relay.sha256,
        jwks_digest relay.sha256,
        access_region relay.region,
        management_api text
          CONSTRAINT access_link_management_api_check CHECK (char_length(management_api) <= 512),
        event_subscriptions text
          CONSTRAINT access_link_event_subscriptions_check
            CHECK (char_length(event_subscriptions) <= 512),
        state text NOT NULL
          CONSTRAINT access_link_state_check
            CHECK (state IN ('pending', 'ok', 'stale', 'region_mismatch')),
        fetched_at timestamptz,
        jwks_fetched_at timestamptz,
        updated_at timestamptz NOT NULL,
        CONSTRAINT access_link_pkey PRIMARY KEY (singleton)
      )
      """,
      "GRANT SELECT ON relay.access_link TO relay_owner, relay_app",
      "GRANT SELECT, INSERT, UPDATE ON relay.access_link TO relay_maint",
      ~S"""
      CREATE TABLE relay.access_event_receipts (
        id uuid NOT NULL,
        webhook_id text NOT NULL
          CONSTRAINT access_event_receipts_webhook_id_check
            CHECK (char_length(webhook_id) BETWEEN 1 AND 512),
        event_type relay.event_name NOT NULL,
        access_tenant_id text
          CONSTRAINT access_event_receipts_access_tenant_id_check
            CHECK (char_length(access_tenant_id) <= 128),
        payload jsonb NOT NULL
          CONSTRAINT access_event_receipts_payload_check CHECK (pg_column_size(payload) <= 65536),
        body_digest relay.sha256 NOT NULL,
        state text NOT NULL
          CONSTRAINT access_event_receipts_state_check
            CHECK (state IN ('received', 'processed', 'rejected', 'deferred')),
        reason text CONSTRAINT access_event_receipts_reason_check CHECK (char_length(reason) <= 128),
        traceparent text
          CONSTRAINT access_event_receipts_traceparent_check CHECK (char_length(traceparent) <= 64),
        received_at timestamptz NOT NULL,
        processed_at timestamptz,
        CONSTRAINT access_event_receipts_pkey PRIMARY KEY (id),
        CONSTRAINT access_event_receipts_webhook_id_key UNIQUE (webhook_id)
      )
      """,
      """
      CREATE INDEX access_event_receipts_deferred_idx ON relay.access_event_receipts
        (access_tenant_id, received_at) WHERE state = 'deferred'
      """,
      "GRANT SELECT, INSERT, UPDATE ON relay.access_event_receipts TO relay_maint",
      "GRANT SELECT ON relay.access_event_receipts TO relay_archive",
      ~S"""
      CREATE TABLE relay.api_client_generation (
        singleton boolean NOT NULL
          CONSTRAINT api_client_generation_singleton_check CHECK (singleton),
        generation bigint NOT NULL
          CONSTRAINT api_client_generation_generation_check CHECK (generation >= 0),
        updated_at timestamptz NOT NULL,
        CONSTRAINT api_client_generation_pkey PRIMARY KEY (singleton)
      )
      """,
      "GRANT SELECT, UPDATE ON relay.api_client_generation TO relay_owner",
      "GRANT SELECT ON relay.api_client_generation TO relay_app, relay_maint, relay_archive",
      """
      INSERT INTO relay.api_client_generation (singleton, generation, updated_at)
      VALUES (true, 0, now())
      """,
      ~S"""
      CREATE TABLE relay.api_clients (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        access_client_id text NOT NULL
          CONSTRAINT api_clients_access_client_id_check
            CHECK (char_length(access_client_id) BETWEEN 1 AND 256),
        subtenant_id uuid,
        scopes relay.api_scope[] NOT NULL
          CONSTRAINT api_clients_scopes_check CHECK (cardinality(scopes) BETWEEN 1 AND 5),
        status text NOT NULL
          CONSTRAINT api_clients_status_check CHECK (status IN ('active', 'suspended', 'revoked')),
        status_changed_at timestamptz NOT NULL,
        last_used_at timestamptz,
        last_used_ip inet,
        access_event_ref text
          CONSTRAINT api_clients_access_event_ref_check CHECK (char_length(access_event_ref) <= 512),
        version bigint NOT NULL DEFAULT 1,
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT api_clients_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT api_clients_access_client_id_key
          UNIQUE (tenant_id, environment, access_client_id),
        CONSTRAINT api_clients_subtenant_id_fkey FOREIGN KEY (tenant_id, environment, subtenant_id)
          REFERENCES relay.subtenants (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      "CREATE INDEX api_clients_access_client_id_idx ON relay.api_clients (access_client_id)",
      """
      CREATE INDEX api_clients_last_used_at_idx ON relay.api_clients
        (tenant_id, environment, last_used_at)
      """,
      "ALTER TABLE relay.api_clients ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE relay.api_clients FORCE ROW LEVEL SECURITY",
      "CREATE POLICY api_clients_scope ON relay.api_clients USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})",
      "GRANT SELECT, INSERT, UPDATE ON relay.api_clients TO relay_owner",
      "GRANT SELECT ON relay.api_clients TO relay_app, relay_maint, relay_archive, relay_report"
    ]
  end
end
