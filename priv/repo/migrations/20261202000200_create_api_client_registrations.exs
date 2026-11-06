defmodule Relay.Repo.Migrations.CreateApiClientRegistrations do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  # E-99
  # API-44
  # TN-13
  # OP-9
  def up do
    execute(~S"""
    CREATE TABLE relay.api_client_registrations (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      id uuid NOT NULL,
      access_client_id text NOT NULL
        CONSTRAINT api_client_registrations_access_client_id_check
          CHECK (char_length(access_client_id) BETWEEN 1 AND 256),
      state text NOT NULL
        CONSTRAINT api_client_registrations_state_check CHECK (state IN ('pending', 'assigned')),
      assigned_environment relay.environment,
      assigned_at timestamptz,
      access_event_ref text
        CONSTRAINT api_client_registrations_access_event_ref_check
          CHECK (char_length(access_event_ref) <= 512),
      version bigint NOT NULL DEFAULT 1,
      created_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      CONSTRAINT api_client_registrations_pkey PRIMARY KEY (tenant_id, environment, id),
      CONSTRAINT api_client_registrations_access_client_id_key
        UNIQUE (tenant_id, environment, access_client_id),
      CONSTRAINT api_client_registrations_live_check CHECK (environment = 'live'),
      CONSTRAINT api_client_registrations_assigned_check
        CHECK ((state = 'assigned') = (assigned_environment IS NOT NULL AND assigned_at IS NOT NULL))
    )
    """)

    execute("""
    CREATE INDEX api_client_registrations_access_client_id_idx
      ON relay.api_client_registrations (access_client_id)
    """)

    execute("""
    CREATE TRIGGER api_client_registrations_no_delete BEFORE DELETE
      ON relay.api_client_registrations
      FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    execute("ALTER TABLE relay.api_client_registrations ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE relay.api_client_registrations FORCE ROW LEVEL SECURITY")

    execute(
      "CREATE POLICY api_client_registrations_scope ON relay.api_client_registrations USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})"
    )

    execute("GRANT SELECT, INSERT, UPDATE ON relay.api_client_registrations TO relay_owner")

    execute(
      "GRANT SELECT ON relay.api_client_registrations TO relay_app, relay_maint, relay_archive, relay_report"
    )
  end

  def down, do: :ok
end
