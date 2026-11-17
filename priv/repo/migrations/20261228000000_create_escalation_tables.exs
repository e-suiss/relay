defmodule Relay.Repo.Migrations.CreateEscalationTables do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"

  @mutable ~w(escalation_policies waitpoint_steps waitpoint_invitations)
  @append_only ~w(escalation_policy_versions)

  # AG-17
  # AG-12
  # AG-19
  # AG-63
  # INV-35
  # WF-43
  # TN-12
  # TN-13
  # OP-9
  def up do
    Enum.each(statements(), &execute/1)
    Enum.each(@mutable, &mutable/1)
    Enum.each(@append_only, &append_only/1)
    Enum.each(guards(), &execute/1)
  end

  def down, do: :ok

  defp scoped(table) do
    execute("ALTER TABLE relay.#{table} ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE relay.#{table} FORCE ROW LEVEL SECURITY")

    execute(
      "CREATE POLICY #{table}_scope ON relay.#{table} USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})"
    )

    execute(
      "GRANT SELECT ON relay.#{table} TO relay_app, relay_maint, relay_archive, relay_report"
    )
  end

  defp mutable(table) do
    execute("""
    CREATE TRIGGER #{table}_no_delete BEFORE DELETE ON relay.#{table}
      FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    execute("""
    CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON relay.#{table}
      FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    scoped(table)
    execute("GRANT SELECT, INSERT, UPDATE ON relay.#{table} TO relay_owner")
  end

  # INV-6
  # INV-49
  defp append_only(table) do
    execute("""
    CREATE TRIGGER #{table}_append_only BEFORE UPDATE OR DELETE ON relay.#{table}
      FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    execute("""
    CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON relay.#{table}
      FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    scoped(table)
    execute("GRANT SELECT, INSERT ON relay.#{table} TO relay_owner")
  end

  defp statements do
    [
      ~S"""
      CREATE TABLE relay.escalation_policies (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        key text NOT NULL
          CONSTRAINT escalation_policies_key_check
            CHECK (key ~ '^[a-z0-9]+(-[a-z0-9]+)*$' AND char_length(key) <= 100),
        state text NOT NULL
          CONSTRAINT escalation_policies_state_check CHECK (state IN ('active', 'archived')),
        archived_at timestamptz,
        version bigint NOT NULL
          CONSTRAINT escalation_policies_version_check CHECK (version >= 1),
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT escalation_policies_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT escalation_policies_key_key UNIQUE (tenant_id, environment, key),
        CONSTRAINT escalation_policies_archived_check
          CHECK ((state = 'archived') = (archived_at IS NOT NULL))
      )
      """,
      ~S"""
      CREATE TABLE relay.escalation_policy_versions (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        policy_id uuid NOT NULL,
        version bigint NOT NULL
          CONSTRAINT escalation_policy_versions_version_check CHECK (version >= 1),
        description text
          CONSTRAINT escalation_policy_versions_description_check
            CHECK (char_length(description) <= 500),
        tiers jsonb NOT NULL
          CONSTRAINT escalation_policy_versions_tiers_check
            CHECK (pg_column_size(tiers) <= 65536),
        created_by_ref text NOT NULL
          CONSTRAINT escalation_policy_versions_created_by_ref_check
            CHECK (char_length(created_by_ref) BETWEEN 1 AND 256),
        created_at timestamptz NOT NULL,
        CONSTRAINT escalation_policy_versions_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT escalation_policy_versions_version_key
          UNIQUE (tenant_id, environment, policy_id, version),
        CONSTRAINT escalation_policy_versions_tiers_array_check
          CHECK (jsonb_typeof(tiers) = 'array'),
        CONSTRAINT escalation_policy_versions_policy_id_fkey
          FOREIGN KEY (tenant_id, environment, policy_id)
          REFERENCES relay.escalation_policies (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      ~S"""
      CREATE TABLE relay.waitpoint_steps (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        waitpoint_id uuid NOT NULL,
        track text NOT NULL
          CONSTRAINT waitpoint_steps_track_check CHECK (track IN ('escalation', 'surface')),
        recipient_id uuid,
        ordinal bigint NOT NULL CONSTRAINT waitpoint_steps_ordinal_check CHECK (ordinal >= 1),
        level bigint NOT NULL CONSTRAINT waitpoint_steps_level_check CHECK (level >= 1),
        after_ms bigint NOT NULL CONSTRAINT waitpoint_steps_after_ms_check CHECK (after_ms >= 0),
        spec jsonb NOT NULL
          CONSTRAINT waitpoint_steps_spec_check CHECK (pg_column_size(spec) <= 16384),
        state text NOT NULL
          CONSTRAINT waitpoint_steps_state_check
            CHECK (state IN ('pending', 'armed', 'suspended', 'fired', 'skipped', 'cancelled')),
        due_at timestamptz,
        remaining_ms bigint
          CONSTRAINT waitpoint_steps_remaining_ms_check CHECK (remaining_ms >= 0),
        rule_id relay.rule_id,
        settled_at timestamptz,
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT waitpoint_steps_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT waitpoint_steps_ordinal_key UNIQUE NULLS NOT DISTINCT
          (tenant_id, environment, waitpoint_id, track, recipient_id, ordinal),
        CONSTRAINT waitpoint_steps_recipient_check
          CHECK ((track = 'surface') = (recipient_id IS NOT NULL)),
        CONSTRAINT waitpoint_steps_due_at_check CHECK ((state = 'armed') = (due_at IS NOT NULL)),
        CONSTRAINT waitpoint_steps_remaining_check
          CHECK ((state = 'suspended') = (remaining_ms IS NOT NULL)),
        CONSTRAINT waitpoint_steps_settled_at_check
          CHECK ((state IN ('fired', 'skipped', 'cancelled')) = (settled_at IS NOT NULL)),
        CONSTRAINT waitpoint_steps_rule_id_check
          CHECK ((state IN ('suspended', 'skipped', 'cancelled')) = (rule_id IS NOT NULL)),
        CONSTRAINT waitpoint_steps_waitpoint_id_fkey
          FOREIGN KEY (tenant_id, environment, waitpoint_id)
          REFERENCES relay.waitpoints (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT waitpoint_steps_recipient_id_fkey
          FOREIGN KEY (tenant_id, environment, waitpoint_id, recipient_id)
          REFERENCES relay.waitpoint_responders (tenant_id, environment, waitpoint_id, recipient_id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE INDEX waitpoint_steps_armed_index ON relay.waitpoint_steps
        (tenant_id, environment, waitpoint_id, due_at) WHERE state = 'armed'
      """,
      ~S"""
      CREATE TABLE relay.waitpoint_invitations (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        waitpoint_id uuid NOT NULL,
        recipient_id uuid NOT NULL,
        step_id uuid,
        source text NOT NULL
          CONSTRAINT waitpoint_invitations_source_check
            CHECK (source IN ('creation', 'escalation', 'surface')),
        surfaces jsonb
          CONSTRAINT waitpoint_invitations_surfaces_check
            CHECK (pg_column_size(surfaces) <= 16384),
        inbox boolean NOT NULL,
        state text NOT NULL
          CONSTRAINT waitpoint_invitations_state_check
            CHECK (state IN ('requested', 'delivered', 'unreachable', 'cancelled')),
        rule_id relay.rule_id,
        invited_at timestamptz NOT NULL,
        settled_at timestamptz,
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT waitpoint_invitations_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT waitpoint_invitations_step_check
          CHECK ((source = 'creation') = (step_id IS NULL)),
        CONSTRAINT waitpoint_invitations_settled_at_check
          CHECK ((state = 'requested') = (settled_at IS NULL)),
        CONSTRAINT waitpoint_invitations_rule_id_check
          CHECK ((state IN ('unreachable', 'cancelled')) = (rule_id IS NOT NULL)),
        CONSTRAINT waitpoint_invitations_recipient_id_fkey
          FOREIGN KEY (tenant_id, environment, waitpoint_id, recipient_id)
          REFERENCES relay.waitpoint_responders (tenant_id, environment, waitpoint_id, recipient_id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT waitpoint_invitations_step_id_fkey
          FOREIGN KEY (tenant_id, environment, step_id)
          REFERENCES relay.waitpoint_steps (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE INDEX waitpoint_invitations_recipient_index ON relay.waitpoint_invitations
        (tenant_id, environment, waitpoint_id, recipient_id)
      """
    ]
  end

  defp guards do
    [
      ~S"""
      CREATE FUNCTION relay_private.waitpoint_steps_guard() RETURNS trigger
        LANGUAGE plpgsql
        SET search_path = pg_catalog, pg_temp
        SET TimeZone = 'UTC'
      AS $fn$
      BEGIN
        IF TG_OP = 'UPDATE' THEN
          IF NEW.waitpoint_id IS DISTINCT FROM OLD.waitpoint_id
            OR NEW.track IS DISTINCT FROM OLD.track
            OR NEW.recipient_id IS DISTINCT FROM OLD.recipient_id
            OR NEW.ordinal IS DISTINCT FROM OLD.ordinal OR NEW.level IS DISTINCT FROM OLD.level
            OR NEW.after_ms IS DISTINCT FROM OLD.after_ms OR NEW.spec IS DISTINCT FROM OLD.spec
            OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
            RAISE EXCEPTION 'invariant_violation'
              USING DETAIL = 'a pinned step keeps its place, delay and targets', HINT = 'AG-17';
          END IF;
          IF NEW.state IS DISTINCT FROM OLD.state AND (OLD.state IN ('skipped', 'cancelled')
            OR (OLD.state = 'fired' AND NEW.state <> 'skipped')) THEN
            RAISE EXCEPTION 'invariant_violation'
              USING DETAIL = 'a settled step does not run again', HINT = 'AG-19';
          END IF;
        END IF;
        IF NEW.state = 'fired' AND (TG_OP = 'INSERT' OR OLD.state <> 'fired')
          AND NOT EXISTS (SELECT 1 FROM relay.waitpoints w
            WHERE w.tenant_id = NEW.tenant_id AND w.environment = NEW.environment
              AND w.id = NEW.waitpoint_id AND w.state = 'open'
              AND NEW.settled_at < w.expires_at) THEN
          RAISE EXCEPTION 'invariant_violation'
            USING DETAIL = 'a step fires only on an open waitpoint before its deadline',
              HINT = 'AG-19';
        END IF;
        RETURN NEW;
      END
      $fn$
      """,
      "REVOKE ALL ON FUNCTION relay_private.waitpoint_steps_guard() FROM PUBLIC",
      """
      CREATE TRIGGER waitpoint_steps_guard BEFORE INSERT OR UPDATE ON relay.waitpoint_steps
        FOR EACH ROW EXECUTE FUNCTION relay_private.waitpoint_steps_guard()
      """,
      ~S"""
      CREATE FUNCTION relay_private.waitpoint_invitations_guard() RETURNS trigger
        LANGUAGE plpgsql
        SET search_path = pg_catalog, pg_temp
        SET TimeZone = 'UTC'
      AS $fn$
      BEGIN
        IF TG_OP = 'INSERT' THEN
          IF NEW.state <> 'requested' OR NOT EXISTS (SELECT 1 FROM relay.waitpoints w
            WHERE w.tenant_id = NEW.tenant_id AND w.environment = NEW.environment
              AND w.id = NEW.waitpoint_id AND w.state = 'open'
              AND NEW.invited_at < w.expires_at) THEN
            RAISE EXCEPTION 'invariant_violation'
              USING DETAIL = 'an invitation needs an open waitpoint before its deadline',
                HINT = 'AG-63';
          END IF;
          RETURN NEW;
        END IF;
        IF NEW.waitpoint_id IS DISTINCT FROM OLD.waitpoint_id
          OR NEW.recipient_id IS DISTINCT FROM OLD.recipient_id
          OR NEW.step_id IS DISTINCT FROM OLD.step_id OR NEW.source IS DISTINCT FROM OLD.source
          OR NEW.surfaces IS DISTINCT FROM OLD.surfaces OR NEW.inbox IS DISTINCT FROM OLD.inbox
          OR NEW.invited_at IS DISTINCT FROM OLD.invited_at
          OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
          RAISE EXCEPTION 'invariant_violation'
            USING DETAIL = 'an invitation keeps its recipient and surfaces', HINT = 'AG-63';
        END IF;
        IF NEW.state IS DISTINCT FROM OLD.state AND OLD.state <> 'requested' THEN
          RAISE EXCEPTION 'invariant_violation'
            USING DETAIL = 'a settled invitation does not change', HINT = 'INV-35';
        END IF;
        RETURN NEW;
      END
      $fn$
      """,
      "REVOKE ALL ON FUNCTION relay_private.waitpoint_invitations_guard() FROM PUBLIC",
      """
      CREATE TRIGGER waitpoint_invitations_guard BEFORE INSERT OR UPDATE
        ON relay.waitpoint_invitations
        FOR EACH ROW EXECUTE FUNCTION relay_private.waitpoint_invitations_guard()
      """,
      ~S"""
      CREATE FUNCTION relay_private.waitpoint_steps_follow() RETURNS trigger
        LANGUAGE plpgsql
        SET search_path = pg_catalog, pg_temp
        SET TimeZone = 'UTC'
      AS $fn$
      BEGIN
        IF NEW.state IS NOT DISTINCT FROM OLD.state THEN
          RETURN NEW;
        END IF;
        IF NEW.state IN ('resolved', 'expired', 'cancelled') THEN
          UPDATE relay.waitpoint_steps s SET state = 'cancelled', due_at = NULL,
              remaining_ms = NULL, rule_id = 'waitpoint.step_cancelled',
              settled_at = NEW.state_changed_at, updated_at = now()
            WHERE s.tenant_id = NEW.tenant_id AND s.environment = NEW.environment
              AND s.waitpoint_id = NEW.id AND s.state IN ('pending', 'armed', 'suspended');
          UPDATE relay.waitpoint_invitations i SET state = 'cancelled',
              rule_id = 'waitpoint.invitation_cancelled', settled_at = NEW.state_changed_at,
              updated_at = now()
            WHERE i.tenant_id = NEW.tenant_id AND i.environment = NEW.environment
              AND i.waitpoint_id = NEW.id AND i.state = 'requested';
          NEW.next_escalation_at := NULL;
        ELSIF NEW.state = 'stalled' THEN
          UPDATE relay.waitpoint_steps s SET state = 'suspended',
              remaining_ms = GREATEST(0,
                (extract(epoch FROM (s.due_at - NEW.state_changed_at)) * 1000)::bigint),
              due_at = NULL, rule_id = 'waitpoint.step_suspended', updated_at = now()
            WHERE s.tenant_id = NEW.tenant_id AND s.environment = NEW.environment
              AND s.waitpoint_id = NEW.id AND s.state = 'armed';
          NEW.next_escalation_at := NULL;
        ELSE
          UPDATE relay.waitpoint_steps s SET state = 'armed',
              due_at = NEW.state_changed_at + s.remaining_ms * interval '1 millisecond',
              remaining_ms = NULL, rule_id = NULL, updated_at = now()
            WHERE s.tenant_id = NEW.tenant_id AND s.environment = NEW.environment
              AND s.waitpoint_id = NEW.id AND s.state = 'suspended';
          NEW.next_escalation_at := (SELECT min(s.due_at) FROM relay.waitpoint_steps s
            WHERE s.tenant_id = NEW.tenant_id AND s.environment = NEW.environment
              AND s.waitpoint_id = NEW.id AND s.state = 'armed');
        END IF;
        RETURN NEW;
      END
      $fn$
      """,
      "REVOKE ALL ON FUNCTION relay_private.waitpoint_steps_follow() FROM PUBLIC",
      """
      CREATE TRIGGER waitpoints_steps_follow BEFORE UPDATE OF state ON relay.waitpoints
        FOR EACH ROW EXECUTE FUNCTION relay_private.waitpoint_steps_follow()
      """
    ]
  end
end
