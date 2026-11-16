defmodule Relay.Repo.Migrations.CreateRecurrenceFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"

  @functions [
    "relay_fn.recurrence_create(uuid, uuid, text, text, uuid, text, text, text, text, bytea, uuid, timestamptz, bigint, text, timestamptz, bigint, bytea, #{@actor})",
    "relay_fn.recurrence_cancel(uuid, text, bytea, #{@actor})",
    "relay_fn.recurrence_fire(uuid, timestamptz, timestamptz[], bigint[], text[], text[], text[], uuid[], timestamptz, bigint, text, timestamptz)"
  ]

  @scopes "relay_ops.recurrence_due_scopes(bigint, integer)"

  # WF-48
  # WF-49
  # WF-61
  # WF-43
  # TN-13 (4)
  # OP-8
  def up do
    Enum.each(statements(), &execute/1)

    for signature <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      execute("GRANT EXECUTE ON FUNCTION #{signature} TO relay_app")
      execute("ALTER FUNCTION #{signature} OWNER TO relay_owner")
    end

    execute(due_scopes())
    execute("REVOKE ALL ON FUNCTION #{@scopes} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@scopes} TO relay_worker")
  end

  def down, do: :ok

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_fn.recurrence_create(p_id uuid, p_workflow_id uuid,
        p_workflow_key text, p_target_kind text, p_recipient_id uuid, p_topic_key text,
        p_rrule text, p_dtstart text, p_timezone text, p_data_ct bytea, p_data_key_id uuid,
        p_next_at timestamptz, p_next_ordinal bigint, p_next_zone text, p_fire_at timestamptz,
        p_max_active bigint, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
        p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_active bigint;
      BEGIN
        IF p_workflow_id IS NULL OR p_workflow_key IS NULL OR p_target_kind IS NULL
          OR p_rrule IS NULL OR p_dtstart IS NULL OR p_next_at IS NULL OR p_next_zone IS NULL
          OR p_fire_at IS NULL OR p_max_active IS NULL OR p_max_active < 1
          OR p_actor_ref IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-61';
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        PERFORM pg_advisory_xact_lock(hashtextextended(
          'relay.recurrences:' || v_tenant::text || ':' || v_env::text, 0));
        SELECT count(*) INTO v_active FROM relay.recurrences r
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.state = 'active';
        IF v_active >= p_max_active THEN
          RETURN 'limit_reached';
        END IF;
        INSERT INTO relay.recurrences (tenant_id, environment, id, workflow_id, workflow_key,
          target_kind, recipient_id, topic_key, rrule, dtstart, timezone, data_ct, data_key_id,
          state, next_at, next_ordinal, next_zone, fire_at, occurrence_count, created_by, version,
          created_at, updated_at)
        VALUES (v_tenant, v_env, p_id, p_workflow_id, p_workflow_key, p_target_kind,
          p_recipient_id, p_topic_key, p_rrule, p_dtstart, p_timezone, p_data_ct, p_data_key_id,
          'active', p_next_at, p_next_ordinal, p_next_zone, p_fire_at, 0, p_actor_ref, 1, now(),
          now());
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'recurrence.created',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref,
          'recurrence', p_id::text, p_workflow_key, p_record_digest);
        RETURN 'created';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.recurrence_cancel(p_id uuid, p_reason text, p_record_digest bytea,
        p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_state text;
      BEGIN
        IF p_id IS NULL OR p_reason IS NULL OR p_reason NOT IN ('request', 'subject_erasure')
          OR p_actor_ref IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-49';
        END IF;
        SELECT r.state INTO v_state FROM relay.recurrences r
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_state <> 'active' THEN
          RETURN 'closed';
        END IF;
        UPDATE relay.recurrences r SET state = 'cancelled', cancel_reason = p_reason,
            cancelled_at = relay_private.business_now(), next_at = NULL, next_ordinal = NULL,
            next_zone = NULL, fire_at = NULL, version = r.version + 1, updated_at = now()
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_id;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'recurrence.cancelled',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref,
          'recurrence', p_id::text, p_reason, p_record_digest);
        RETURN 'cancelled';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.recurrence_fire(p_id uuid, p_expected_next_at timestamptz,
        p_occurrence_ats timestamptz[], p_ordinals bigint[], p_outcomes text[], p_rule_ids text[],
        p_error_codes text[], p_event_ids uuid[], p_next_at timestamptz, p_next_ordinal bigint,
        p_next_zone text, p_fire_at timestamptz)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.recurrences;
        v_count bigint := cardinality(COALESCE(p_occurrence_ats, ARRAY[]::timestamptz[]));
        v_now timestamptz := relay_private.business_now();
      BEGIN
        IF p_id IS NULL OR p_expected_next_at IS NULL
          OR cardinality(COALESCE(p_ordinals, ARRAY[]::bigint[])) <> v_count
          OR cardinality(COALESCE(p_outcomes, ARRAY[]::text[])) <> v_count
          OR cardinality(COALESCE(p_rule_ids, ARRAY[]::text[])) <> v_count
          OR cardinality(COALESCE(p_error_codes, ARRAY[]::text[])) <> v_count
          OR cardinality(COALESCE(p_event_ids, ARRAY[]::uuid[])) <> v_count
          OR (p_next_at IS NULL) <> (p_fire_at IS NULL)
          OR (p_next_at IS NULL) <> (p_next_zone IS NULL) THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-61';
        END IF;
        SELECT * INTO v_row FROM relay.recurrences r
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_row.state <> 'active' OR v_row.next_at <> p_expected_next_at THEN
          RETURN 'stale';
        END IF;
        INSERT INTO relay.recurrence_occurrences (tenant_id, environment, id, recurrence_id,
          occurrence_at, ordinal, outcome, rule_id, error_code, event_id, recorded_at, created_at)
        SELECT v_tenant, v_env, uuidv7(), p_id, o.occurrence_at, o.ordinal, o.outcome, o.rule_id,
          o.error_code, o.event_id, v_now, now()
        FROM unnest(p_occurrence_ats, p_ordinals, p_outcomes, p_rule_ids, p_error_codes,
          p_event_ids) AS o(occurrence_at, ordinal, outcome, rule_id, error_code, event_id);
        IF p_next_at IS NULL THEN
          UPDATE relay.recurrences r SET state = 'completed', completed_at = v_now,
              next_at = NULL, next_ordinal = NULL, next_zone = NULL, fire_at = NULL,
              occurrence_count = r.occurrence_count + v_count,
              last_occurrence_at = COALESCE((SELECT max(a) FROM unnest(p_occurrence_ats) AS a),
                r.last_occurrence_at),
              version = r.version + 1, updated_at = now()
            WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_id;
          RETURN 'completed';
        END IF;
        UPDATE relay.recurrences r SET next_at = p_next_at, next_ordinal = p_next_ordinal,
            next_zone = p_next_zone, fire_at = p_fire_at,
            occurrence_count = r.occurrence_count + v_count,
            last_occurrence_at = COALESCE((SELECT max(a) FROM unnest(p_occurrence_ats) AS a),
              r.last_occurrence_at),
            version = r.version + 1, updated_at = now()
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_id;
        RETURN 'advanced';
      END
      $fn$
      """
    ]
  end

  defp due_scopes do
    ~S"""
    CREATE FUNCTION relay_ops.recurrence_due_scopes(p_min_age_ms bigint, p_limit integer)
      RETURNS TABLE (tenant_id uuid, environment text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
      SELECT DISTINCT r.tenant_id, r.environment::text
      FROM relay.recurrences r
      LEFT JOIN relay.virtual_clocks v ON v.tenant_id = r.tenant_id
        AND v.environment = r.environment
      WHERE r.state = 'active'
        AND r.fire_at <= now() + coalesce(v.offset_ms, 0) * interval '1 millisecond'
          - GREATEST(COALESCE(p_min_age_ms, 0), 0) * interval '1 millisecond'
      LIMIT GREATEST(COALESCE(p_limit, 100), 1)
    $fn$
    """
  end
end
