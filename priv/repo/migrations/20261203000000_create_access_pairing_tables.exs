defmodule Relay.Repo.Migrations.CreateAccessPairingTables do
  use Ecto.Migration

  # E-101
  # INV-47
  def up do
    Enum.each(statements(), &execute/1)
  end

  def down, do: :ok

  defp statements do
    [
      ~S"""
      CREATE TABLE relay.access_pairing_realms (
        access_tenant_id text NOT NULL
          CONSTRAINT access_pairing_realms_access_tenant_id_check
            CHECK (char_length(access_tenant_id) BETWEEN 1 AND 128),
        realm uuid NOT NULL,
        slug text NOT NULL
          CONSTRAINT access_pairing_realms_slug_check CHECK (char_length(slug) BETWEEN 1 AND 255),
        state text NOT NULL
          CONSTRAINT access_pairing_realms_state_check
            CHECK (state IN ('unpaired', 'paired', 'refused', 'retired')),
        kid bytea CONSTRAINT access_pairing_realms_kid_check CHECK (octet_length(kid) = 32),
        governing_domain bytea
          CONSTRAINT access_pairing_realms_governing_domain_check
            CHECK (octet_length(governing_domain) = 32),
        service_party bytea
          CONSTRAINT access_pairing_realms_service_party_check
            CHECK (octet_length(service_party) = 16),
        service_instance bytea
          CONSTRAINT access_pairing_realms_service_instance_check
            CHECK (octet_length(service_instance) = 16),
        refusal_code text
          CONSTRAINT access_pairing_realms_refusal_code_check
            CHECK (char_length(refusal_code) BETWEEN 1 AND 128),
        failed_runs bigint NOT NULL
          CONSTRAINT access_pairing_realms_failed_runs_check CHECK (failed_runs >= 0),
        paired_at timestamptz,
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT access_pairing_realms_pkey PRIMARY KEY (access_tenant_id, realm),
        CONSTRAINT access_pairing_realms_paired_check
          CHECK (state <> 'paired' OR (kid IS NOT NULL AND service_party IS NOT NULL
            AND service_instance IS NOT NULL AND paired_at IS NOT NULL)),
        CONSTRAINT access_pairing_realms_refused_check
          CHECK ((state = 'refused') = (refusal_code IS NOT NULL))
      )
      """,
      """
      CREATE INDEX access_pairing_realms_stalled_idx ON relay.access_pairing_realms
        (failed_runs) WHERE state IN ('unpaired', 'refused')
      """,
      "GRANT SELECT ON relay.access_pairing_realms TO relay_app",
      "GRANT SELECT, INSERT, UPDATE ON relay.access_pairing_realms TO relay_maint",
      ~S"""
      CREATE TABLE relay.access_event_stream (
        singleton boolean NOT NULL
          CONSTRAINT access_event_stream_singleton_check CHECK (singleton),
        stream uuid,
        status text
          CONSTRAINT access_event_stream_status_check
            CHECK (status IN ('enabled', 'paused', 'disabled', 'unreachable')),
        recreated bigint NOT NULL
          CONSTRAINT access_event_stream_recreated_check CHECK (recreated >= 0),
        checked_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT access_event_stream_pkey PRIMARY KEY (singleton),
        CONSTRAINT access_event_stream_status_stream_check
          CHECK (status IS NULL OR stream IS NOT NULL)
      )
      """,
      "GRANT SELECT ON relay.access_event_stream TO relay_app",
      "GRANT SELECT, INSERT, UPDATE ON relay.access_event_stream TO relay_maint"
    ]
  end
end
