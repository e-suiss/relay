defmodule Relay.Repo.Migrations.AddWaitpointInteractionFields do
  use Ecto.Migration

  @describe "relay_fn.waitpoint_describe(uuid, text, text, text, text)"
  @guard "relay_private.waitpoints_interaction_guard()"

  # AG-8
  # AG-11
  # AG-53
  # AG-62
  # C-75
  # OP-57
  def up do
    execute("ALTER TABLE relay.waitpoints ADD COLUMN profile text")
    execute("ALTER TABLE relay.waitpoints ADD COLUMN outcome_class text")
    execute("ALTER TABLE relay.waitpoints ADD COLUMN risk_tier text")
    execute("ALTER TABLE relay.waitpoints ADD COLUMN correlation_id text")

    execute(~S"""
    ALTER TABLE relay.waitpoints ADD CONSTRAINT waitpoints_profile_check
      CHECK (profile IS NULL
        OR (profile = 'guardian_approval' AND kind = 'review' AND default_response_ct IS NULL))
      NOT VALID
    """)

    execute(~S"""
    ALTER TABLE relay.waitpoints ADD CONSTRAINT waitpoints_outcome_class_check
      CHECK (outcome_class IS NULL OR (kind <> 'event'
        AND char_length(outcome_class) BETWEEN 1 AND 64
        AND translate(outcome_class, 'abcdefghijklmnopqrstuvwxyz0123456789_.:-', '') = ''))
      NOT VALID
    """)

    execute(~S"""
    ALTER TABLE relay.waitpoints ADD CONSTRAINT waitpoints_risk_tier_check
      CHECK (risk_tier IS NULL OR (kind <> 'event'
        AND char_length(risk_tier) BETWEEN 1 AND 64
        AND translate(risk_tier, 'abcdefghijklmnopqrstuvwxyz0123456789_.:-', '') = ''))
      NOT VALID
    """)

    execute(~S"""
    ALTER TABLE relay.waitpoints ADD CONSTRAINT waitpoints_correlation_id_check
      CHECK (correlation_id IS NULL OR (char_length(correlation_id) BETWEEN 1 AND 128
        AND octet_length(correlation_id) = char_length(correlation_id)))
      NOT VALID
    """)

    execute(~S"""
    ALTER TABLE relay.waitpoint_responses ADD CONSTRAINT waitpoint_responses_value_ct_check
      CHECK (octet_length(value_ct) <= 65536 + 29) NOT VALID
    """)

    execute(~S"""
    CREATE FUNCTION relay_private.waitpoints_interaction_guard() RETURNS trigger
      LANGUAGE plpgsql
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
    AS $fn$
    BEGIN
      IF (OLD.profile IS NOT NULL AND NEW.profile IS DISTINCT FROM OLD.profile)
        OR (OLD.outcome_class IS NOT NULL AND NEW.outcome_class IS DISTINCT FROM OLD.outcome_class)
        OR (OLD.risk_tier IS NOT NULL AND NEW.risk_tier IS DISTINCT FROM OLD.risk_tier)
        OR (OLD.correlation_id IS NOT NULL
          AND NEW.correlation_id IS DISTINCT FROM OLD.correlation_id) THEN
        RAISE EXCEPTION 'invariant_violation'
          USING DETAIL = 'a waitpoint keeps its profile and labels', HINT = 'AG-11';
      END IF;
      RETURN NEW;
    END
    $fn$
    """)

    execute("REVOKE ALL ON FUNCTION #{@guard} FROM PUBLIC")

    execute("""
    CREATE TRIGGER waitpoints_interaction_guard BEFORE UPDATE ON relay.waitpoints
      FOR EACH ROW EXECUTE FUNCTION #{@guard}
    """)

    execute(~S"""
    CREATE FUNCTION relay_fn.waitpoint_describe(p_waitpoint_id uuid, p_profile text,
      p_outcome_class text, p_risk_tier text, p_correlation_id text)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_row relay.waitpoints;
    BEGIN
      IF p_waitpoint_id IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-8';
      END IF;
      SELECT * INTO v_row FROM relay.waitpoints w
        WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_waitpoint_id
        FOR NO KEY UPDATE;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      IF v_row.state NOT IN ('open', 'stalled') THEN
        RETURN 'not_open';
      END IF;
      IF v_row.profile IS NOT NULL OR v_row.outcome_class IS NOT NULL
        OR v_row.risk_tier IS NOT NULL OR v_row.correlation_id IS NOT NULL THEN
        RETURN 'exists';
      END IF;
      IF p_profile IS NOT NULL AND (p_profile <> 'guardian_approval' OR v_row.kind <> 'review'
        OR v_row.default_response_ct IS NOT NULL) THEN
        RETURN 'profile_refused';
      END IF;
      IF v_row.kind = 'event' AND (p_outcome_class IS NOT NULL OR p_risk_tier IS NOT NULL) THEN
        RETURN 'labels_refused';
      END IF;
      UPDATE relay.waitpoints w SET profile = p_profile, outcome_class = p_outcome_class,
          risk_tier = p_risk_tier, correlation_id = p_correlation_id, updated_at = now()
        WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_waitpoint_id;
      RETURN 'described';
    END
    $fn$
    """)

    execute("REVOKE ALL ON FUNCTION #{@describe} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@describe} TO relay_app")
    execute("ALTER FUNCTION #{@describe} OWNER TO relay_owner")
  end

  def down, do: :ok
end
