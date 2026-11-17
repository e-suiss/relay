defmodule Relay.Repo.Migrations.CreateSmsDestinationStops do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  # CH-54
  # E-33
  # OP-9
  def up do
    Enum.each(statements(), &execute/1)
  end

  def down, do: :ok

  defp statements do
    [
      ~S"""
      CREATE TABLE relay.sms_destination_stops (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        kind text NOT NULL
          CONSTRAINT sms_destination_stops_kind_check CHECK (kind IN ('prefix', 'country')),
        value text NOT NULL
          CONSTRAINT sms_destination_stops_value_check
            CHECK (value ~ '^(\+[1-9][0-9]{1,14}|[A-Z]{2})$'),
        country text NOT NULL
          CONSTRAINT sms_destination_stops_country_check CHECK (country ~ '^[A-Z]{2}$'),
        rule_id text NOT NULL
          CONSTRAINT sms_destination_stops_rule_id_check
            CHECK (char_length(rule_id) BETWEEN 3 AND 128),
        detail jsonb NOT NULL
          CONSTRAINT sms_destination_stops_detail_check CHECK (pg_column_size(detail) <= 4096),
        state text NOT NULL
          CONSTRAINT sms_destination_stops_state_check CHECK (state IN ('active', 'lifted')),
        lifted_at timestamptz,
        lifted_by_ref text
          CONSTRAINT sms_destination_stops_lifted_by_ref_check
            CHECK (char_length(lifted_by_ref) BETWEEN 1 AND 256),
        lift_reason text
          CONSTRAINT sms_destination_stops_lift_reason_check
            CHECK (char_length(lift_reason) BETWEEN 1 AND 2000),
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT sms_destination_stops_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT sms_destination_stops_kind_value_check
          CHECK ((kind = 'country') = (value ~ '^[A-Z]{2}$')),
        CONSTRAINT sms_destination_stops_lifted_check
          CHECK ((state = 'lifted') = (lifted_at IS NOT NULL)
            AND (state = 'lifted') = (lifted_by_ref IS NOT NULL)
            AND (state = 'lifted') = (lift_reason IS NOT NULL))
      )
      """,
      """
      CREATE UNIQUE INDEX sms_destination_stops_active_key ON relay.sms_destination_stops
        (tenant_id, environment, kind, value) WHERE state = 'active'
      """,
      """
      CREATE INDEX sms_destination_stops_created_index ON relay.sms_destination_stops
        (tenant_id, environment, created_at DESC, id DESC)
      """,
      """
      CREATE TRIGGER sms_destination_stops_no_delete BEFORE DELETE ON relay.sms_destination_stops
        FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
      """,
      """
      CREATE TRIGGER sms_destination_stops_no_truncate
        BEFORE TRUNCATE ON relay.sms_destination_stops
        FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
      """,
      "ALTER TABLE relay.sms_destination_stops ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE relay.sms_destination_stops FORCE ROW LEVEL SECURITY",
      "CREATE POLICY sms_destination_stops_scope ON relay.sms_destination_stops USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})",
      "GRANT SELECT, INSERT, UPDATE ON relay.sms_destination_stops TO relay_owner",
      "GRANT SELECT ON relay.sms_destination_stops TO relay_app, relay_maint, relay_archive, relay_report"
    ]
  end
end
