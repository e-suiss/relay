defmodule Relay.Repo.Migrations.CreateKillSwitches do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"
  @release_columns "ARRAY['status', 'released_at', 'released_by_ref', 'release_reason', 'release_approval_ref']"

  # TN-36
  # TN-41
  # TN-42
  # INV-49
  def up do
    Enum.each(statements(), &execute/1)
  end

  defp statements do
    [
      ~S"""
      CREATE TABLE relay.kill_switches (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        scope_kind text NOT NULL
          CONSTRAINT kill_switches_scope_kind_check CHECK (scope_kind IN ('platform', 'tenant',
            'subtenant', 'campaign', 'workflow', 'api_client', 'sender')),
        scope_ref text
          CONSTRAINT kill_switches_scope_ref_length_check CHECK (char_length(scope_ref) <= 128),
        channel relay.channel,
        target_kind text NOT NULL
          CONSTRAINT kill_switches_target_kind_check
            CHECK (target_kind IN ('all', 'provider_account', 'template')),
        target_ref text
          CONSTRAINT kill_switches_target_ref_length_check CHECK (char_length(target_ref) <= 128),
        message_class relay.message_class,
        security_approval_ref text,
        state text NOT NULL
          CONSTRAINT kill_switches_state_check
            CHECK (state IN ('on', 'off', 'canary', 'paused_until')),
        canary_percent smallint
          CONSTRAINT kill_switches_canary_percent_range_check CHECK (canary_percent BETWEEN 1 AND 99),
        paused_until timestamptz,
        reason text NOT NULL
          CONSTRAINT kill_switches_reason_check CHECK (char_length(btrim(reason)) BETWEEN 1 AND 2000),
        ticket_ref text
          CONSTRAINT kill_switches_ticket_ref_check CHECK (char_length(ticket_ref) <= 512),
        origin text NOT NULL
          CONSTRAINT kill_switches_origin_check CHECK (origin IN ('operator', 'dead_man')),
        created_by_ref text NOT NULL
          CONSTRAINT kill_switches_created_by_ref_check CHECK (char_length(created_by_ref) <= 256),
        expires_at timestamptz,
        no_ttl_approval_ref text,
        supersedes_id uuid,
        status text NOT NULL
          CONSTRAINT kill_switches_status_check CHECK (status IN ('active', 'released')),
        released_at timestamptz,
        released_by_ref text,
        release_reason text,
        release_approval_ref text,
        created_at timestamptz NOT NULL,
        CONSTRAINT kill_switches_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT kill_switches_scope_ref_check
          CHECK ((scope_kind IN ('platform', 'tenant')) = (scope_ref IS NULL)),
        CONSTRAINT kill_switches_target_ref_check CHECK ((target_kind = 'all') = (target_ref IS NULL)),
        CONSTRAINT kill_switches_security_approval_check
          CHECK (coalesce(message_class = 'security', false) = (security_approval_ref IS NOT NULL)),
        CONSTRAINT kill_switches_canary_percent_check
          CHECK ((state = 'canary') = (canary_percent IS NOT NULL)),
        CONSTRAINT kill_switches_paused_until_check
          CHECK ((state = 'paused_until') = (paused_until IS NOT NULL)),
        CONSTRAINT kill_switches_paused_until_infinity_check
          CHECK (paused_until <> 'infinity'::timestamptz OR origin = 'dead_man'),
        CONSTRAINT kill_switches_expires_at_check
          CHECK (expires_at IS NULL OR expires_at > created_at),
        CONSTRAINT kill_switches_no_ttl_approval_check
          CHECK ((expires_at IS NULL) = (no_ttl_approval_ref IS NOT NULL)),
        CONSTRAINT kill_switches_paused_until_expiry_check
          CHECK (state <> 'paused_until' OR expires_at IS NULL OR paused_until <= expires_at),
        CONSTRAINT kill_switches_released_at_check
          CHECK ((status = 'released') = (released_at IS NOT NULL)),
        CONSTRAINT kill_switches_release_check
          CHECK (status = 'active' OR (released_by_ref IS NOT NULL
            AND char_length(btrim(release_reason)) BETWEEN 1 AND 2000
            AND release_approval_ref IS NOT NULL)),
        CONSTRAINT kill_switches_supersedes_id_fkey FOREIGN KEY (tenant_id, environment, supersedes_id)
          REFERENCES relay.kill_switches (tenant_id, environment, id) ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE UNIQUE INDEX kill_switches_dead_man_key ON relay.kill_switches
        (tenant_id, environment, scope_kind, scope_ref) NULLS NOT DISTINCT
        WHERE origin = 'dead_man' AND status = 'active'
      """,
      """
      CREATE INDEX kill_switches_active_index ON relay.kill_switches (tenant_id, environment)
        WHERE status = 'active'
      """,
      """
      CREATE FUNCTION relay_private.kill_switches_guard() RETURNS trigger
        LANGUAGE plpgsql
        SET search_path = pg_catalog, pg_temp
        SET TimeZone = 'UTC'
      AS $fn$
      BEGIN
        IF OLD.status = 'active' AND NEW.status = 'released'
          AND (to_jsonb(NEW) - #{@release_columns}) = (to_jsonb(OLD) - #{@release_columns}) THEN
          RETURN NEW;
        END IF;
        RAISE EXCEPTION 'invariant_violation'
          USING DETAIL = format('%s on %I.%I is not allowed', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME),
                HINT = 'TN-41';
      END
      $fn$
      """,
      "REVOKE ALL ON FUNCTION relay_private.kill_switches_guard() FROM PUBLIC",
      """
      CREATE TRIGGER kill_switches_guard BEFORE UPDATE ON relay.kill_switches
        FOR EACH ROW EXECUTE FUNCTION relay_private.kill_switches_guard()
      """,
      """
      CREATE TRIGGER kill_switches_no_delete BEFORE DELETE ON relay.kill_switches
        FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
      """,
      """
      CREATE TRIGGER kill_switches_no_truncate BEFORE TRUNCATE ON relay.kill_switches
        FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
      """,
      "ALTER TABLE relay.kill_switches ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE relay.kill_switches FORCE ROW LEVEL SECURITY",
      """
      CREATE POLICY kill_switches_scope ON relay.kill_switches
        USING ((#{@tenant_match} OR (tenant_id = (select relay_private.installation_tenant_id()) AND scope_kind = 'platform')) AND #{@context_guard})
        WITH CHECK (#{@tenant_scope})
      """,
      "GRANT SELECT, INSERT, UPDATE ON relay.kill_switches TO relay_owner",
      "GRANT SELECT ON relay.kill_switches TO relay_app, relay_maint, relay_archive, relay_report",
      ~S"""
      CREATE TABLE relay.kill_switch_generation (
        singleton boolean NOT NULL
          CONSTRAINT kill_switch_generation_singleton_check CHECK (singleton),
        generation bigint NOT NULL
          CONSTRAINT kill_switch_generation_generation_check CHECK (generation >= 0),
        updated_at timestamptz NOT NULL,
        CONSTRAINT kill_switch_generation_pkey PRIMARY KEY (singleton)
      )
      """,
      "GRANT SELECT, UPDATE ON relay.kill_switch_generation TO relay_owner",
      "GRANT SELECT ON relay.kill_switch_generation TO relay_app, relay_maint, relay_archive",
      """
      INSERT INTO relay.kill_switch_generation (singleton, generation, updated_at)
      VALUES (true, 0, now())
      """
    ]
  end
end
