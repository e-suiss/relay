defmodule Relay.Repo.Migrations.CreateCampaignFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"

  @functions [
    {"relay_private.campaign_emit(relay.campaigns, text)", "relay_migrator", ~w(relay_owner)},
    {"relay_fn.campaign_create(uuid, text, text, text, text, uuid, bytea, text, bigint, timestamptz)",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.campaign_members_add(uuid, uuid[], uuid[], text[], bigint)", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.campaign_prepare(uuid, uuid, bigint, text)", "relay_owner", ~w(relay_app)},
    {"relay_fn.campaign_prepare_progress(uuid, uuid, bigint, bigint, text[], text[], bigint[])",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.campaign_prepared(uuid, jsonb, bigint)", "relay_owner", ~w(relay_app)},
    {"relay_fn.campaign_approve_samples(uuid, bytea, bytea, #{@actor})", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.campaign_approve_audience(uuid, text, bytea, #{@actor})", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.campaign_trigger(uuid, bytea, bytea, #{@actor})", "relay_owner", ~w(relay_app)},
    {"relay_fn.campaign_stage_bounds(uuid, bigint)", "relay_owner", ~w(relay_app)},
    {"relay_fn.campaign_stage_open(uuid, bigint, uuid)", "relay_owner", ~w(relay_app)},
    {"relay_fn.campaign_stage_wait(uuid, timestamptz)", "relay_owner", ~w(relay_app)},
    {"relay_fn.campaign_member_mark(uuid, uuid, text, uuid, text)", "relay_owner", ~w(relay_app)},
    {"relay_fn.campaign_pause(uuid, text)", "relay_owner", ~w(relay_app)},
    {"relay_fn.campaign_resume(uuid, text, bytea, #{@actor})", "relay_owner", ~w(relay_app)},
    {"relay_fn.campaign_close(uuid, text)", "relay_owner", ~w(relay_app)},
    {"relay_fn.campaign_cancel(uuid, text, bytea, #{@actor})", "relay_owner", ~w(relay_app)},
    {"relay_fn.campaign_overrun(uuid)", "relay_owner", ~w(relay_app)},
    {"relay_fn.campaign_rates(uuid, bigint)", "relay_owner", ~w(relay_app)}
  ]

  # API-35
  # WF-44
  # WF-62
  # WF-34
  # T-23
  # X-14
  # OP-47
  # OP-8
  def up do
    Enum.each(statements(), &execute/1)

    for {signature, owner, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      if owner == "relay_owner", do: execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
    end
  end

  def down, do: :ok

  defp statements do
    [
      emit(),
      create(),
      members_add(),
      prepare(),
      prepare_progress(),
      prepared(),
      approve_samples(),
      approve_audience(),
      trigger(),
      stage_bounds(),
      stage_open(),
      stage_wait(),
      member_mark(),
      pause(),
      resume(),
      close(),
      cancel(),
      overrun(),
      rates()
    ]
  end

  defp emit do
    ~S"""
    CREATE FUNCTION relay_private.campaign_emit(p_campaign relay.campaigns, p_type text)
      RETURNS void
    LANGUAGE plpgsql VOLATILE
    SET search_path = pg_catalog, pg_temp
    AS $fn$
    BEGIN
      PERFORM relay_fn.outbox_append(uuidv7(), p_type, 'campaign:' || p_campaign.id::text,
        jsonb_build_object('campaign_id', p_campaign.id, 'state', p_campaign.state,
          'audience_count', p_campaign.audience_count,
          'expected_count', p_campaign.expected_count,
          'accepted_count', p_campaign.accepted_count,
          'rejected_count', p_campaign.rejected_count,
          'expired_count', p_campaign.expired_count,
          'cancelled_count', p_campaign.cancelled_count,
          'pause_rule_id', p_campaign.pause_rule_id,
          'close_rule_id', p_campaign.close_rule_id),
        NULL);
    END
    $fn$
    """
  end

  defp create do
    ~S"""
    CREATE FUNCTION relay_fn.campaign_create(p_id uuid, p_name text, p_workflow_key text,
      p_audience_kind text, p_topic_key text, p_data_key_id uuid, p_data_ct bytea,
      p_api_client_ref text, p_expected_count bigint, p_deadline timestamptz)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
    BEGIN
      IF p_name IS NULL OR p_workflow_key IS NULL OR p_audience_kind IS NULL
        OR p_data_key_id IS NULL OR p_data_ct IS NULL OR p_expected_count IS NULL
        OR p_deadline IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'API-35';
      END IF;
      IF relay_private.tenant_status() <> 'active' THEN
        RETURN 'tenant_inactive';
      END IF;
      PERFORM relay_private.assert_new_id(p_id);
      INSERT INTO relay.campaigns (tenant_id, environment, id, name, workflow_key, audience_kind,
        topic_key, data_key_id, data_ct, api_client_ref, expected_count, deadline, state,
        created_at, updated_at)
      VALUES (v_tenant, v_env, p_id, p_name, p_workflow_key, p_audience_kind, p_topic_key,
        p_data_key_id, p_data_ct, p_api_client_ref, p_expected_count, p_deadline, 'draft', now(),
        now());
      RETURN 'created';
    END
    $fn$
    """
  end

  defp members_add do
    ~S"""
    CREATE FUNCTION relay_fn.campaign_members_add(p_campaign_id uuid, p_ids uuid[],
      p_recipient_ids uuid[], p_dedup_keys text[], p_not_found bigint)
      RETURNS TABLE (result text, added bigint, duplicates bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_row relay.campaigns;
      v_n bigint := COALESCE(cardinality(p_ids), 0);
      v_added bigint;
    BEGIN
      IF p_ids IS NULL OR p_recipient_ids IS NULL OR p_dedup_keys IS NULL OR p_not_found IS NULL
        OR p_not_found < 0 OR cardinality(p_recipient_ids) IS DISTINCT FROM cardinality(p_ids)
        OR cardinality(p_dedup_keys) IS DISTINCT FROM cardinality(p_ids) THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'API-35';
      END IF;
      SELECT * INTO v_row FROM relay.campaigns c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_campaign_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, 0::bigint, 0::bigint;
        RETURN;
      END IF;
      IF v_row.state <> 'draft' THEN
        RETURN QUERY SELECT 'not_draft'::text, 0::bigint, 0::bigint;
        RETURN;
      END IF;
      IF v_row.audience_count + v_n > 10000000 THEN
        RETURN QUERY SELECT 'too_large'::text, 0::bigint, 0::bigint;
        RETURN;
      END IF;
      WITH inserted AS (
        INSERT INTO relay.campaign_members (tenant_id, environment, campaign_id, id,
          recipient_id, dedup_key, state, notification_id, reject_code, created_at, updated_at)
        SELECT v_tenant, v_env, p_campaign_id, u.member_id, u.member_recipient_id, u.member_key,
          'pending', NULL, NULL, now(), now()
        FROM unnest(p_ids, p_recipient_ids, p_dedup_keys)
          AS u(member_id, member_recipient_id, member_key)
        ON CONFLICT DO NOTHING
        RETURNING 1
      )
      SELECT count(*) INTO v_added FROM inserted;
      UPDATE relay.campaigns c SET audience_count = c.audience_count + v_added,
          not_found_count = c.not_found_count + p_not_found, version = c.version + 1,
          updated_at = now()
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_campaign_id;
      RETURN QUERY SELECT 'added'::text, v_added, v_n - v_added;
    END
    $fn$
    """
  end

  defp prepare do
    ~S"""
    CREATE FUNCTION relay_fn.campaign_prepare(p_campaign_id uuid, p_workflow_id uuid,
      p_workflow_version_no bigint, p_message_class text)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_row relay.campaigns;
    BEGIN
      IF p_workflow_id IS NULL OR p_workflow_version_no IS NULL OR p_message_class IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-44';
      END IF;
      SELECT * INTO v_row FROM relay.campaigns c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_campaign_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      IF v_row.state <> 'draft' THEN
        RETURN 'not_draft';
      END IF;
      IF v_row.deadline <= relay_private.business_now() THEN
        RETURN 'deadline_passed';
      END IF;
      IF v_row.audience_count = 0 THEN
        RETURN 'empty';
      END IF;
      UPDATE relay.campaigns c SET state = 'preparing', workflow_id = p_workflow_id,
          workflow_version_no = p_workflow_version_no,
          message_class = p_message_class::relay.message_class, prepare_after = NULL,
          version = c.version + 1, updated_at = now()
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_campaign_id;
      RETURN 'preparing';
    END
    $fn$
    """
  end

  defp prepare_progress do
    ~S"""
    CREATE FUNCTION relay_fn.campaign_prepare_progress(p_campaign_id uuid, p_after uuid,
      p_evaluated bigint, p_reachable bigint, p_kinds text[], p_keys text[], p_counts bigint[])
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_row relay.campaigns;
    BEGIN
      IF p_after IS NULL OR p_evaluated IS NULL OR p_reachable IS NULL OR p_kinds IS NULL
        OR p_keys IS NULL OR p_counts IS NULL
        OR cardinality(p_keys) IS DISTINCT FROM cardinality(p_kinds)
        OR cardinality(p_counts) IS DISTINCT FROM cardinality(p_kinds) THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'X-14';
      END IF;
      SELECT * INTO v_row FROM relay.campaigns c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_campaign_id
        FOR UPDATE;
      IF NOT FOUND OR v_row.state <> 'preparing' THEN
        RETURN 'not_preparing';
      END IF;
      IF v_row.prepare_after IS NOT NULL AND p_after <= v_row.prepare_after THEN
        RETURN 'stale';
      END IF;
      INSERT INTO relay.campaign_preview_counts AS p (tenant_id, environment, campaign_id, kind,
        key, count, updated_at)
      SELECT v_tenant, v_env, p_campaign_id, u.count_kind, u.count_key, u.count_value, now()
      FROM unnest(p_kinds, p_keys, p_counts) AS u(count_kind, count_key, count_value)
      ON CONFLICT ON CONSTRAINT campaign_preview_counts_pkey
        DO UPDATE SET count = p.count + EXCLUDED.count, updated_at = now();
      UPDATE relay.campaigns c SET prepare_after = p_after,
          evaluated_count = c.evaluated_count + p_evaluated,
          reachable_count = c.reachable_count + p_reachable, version = c.version + 1,
          updated_at = now()
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_campaign_id;
      RETURN 'recorded';
    END
    $fn$
    """
  end

  defp prepared do
    ~S"""
    CREATE FUNCTION relay_fn.campaign_prepared(p_campaign_id uuid, p_estimate jsonb,
      p_estimated_duration_s bigint)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_row relay.campaigns;
    BEGIN
      IF p_estimate IS NULL OR p_estimated_duration_s IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'X-14';
      END IF;
      SELECT * INTO v_row FROM relay.campaigns c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_campaign_id
        FOR UPDATE;
      IF NOT FOUND OR v_row.state <> 'preparing' THEN
        RETURN 'not_preparing';
      END IF;
      UPDATE relay.campaigns c SET state = 'prepared', estimate = p_estimate,
          estimated_duration_s = p_estimated_duration_s,
          audience_approval_required = c.audience_count * 2 > c.expected_count * 3,
          prepared_at = now(), version = c.version + 1, updated_at = now()
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_campaign_id
        RETURNING * INTO v_row;
      PERFORM relay_private.campaign_emit(v_row, 'campaign.prepared');
      RETURN 'prepared';
    END
    $fn$
    """
  end

  defp approve_samples do
    ~S"""
    CREATE FUNCTION relay_fn.campaign_approve_samples(p_campaign_id uuid, p_samples_digest bytea,
      p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
      p_access_record_ref text)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_row relay.campaigns;
    BEGIN
      IF p_samples_digest IS NULL OR p_record_digest IS NULL OR p_actor_ref IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-62';
      END IF;
      SELECT * INTO v_row FROM relay.campaigns c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_campaign_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      IF v_row.state <> 'prepared' THEN
        RETURN 'not_prepared';
      END IF;
      UPDATE relay.campaigns c SET samples_digest = p_samples_digest, samples_approved_at = now(),
          samples_approved_by = p_actor_ref, version = c.version + 1, updated_at = now()
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_campaign_id;
      PERFORM relay_private.audit_write(v_tenant, v_env::text, 'campaign.samples_approved',
        p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'campaign',
        p_campaign_id::text, NULL, p_record_digest);
      RETURN 'approved';
    END
    $fn$
    """
  end

  defp approve_audience do
    ~S"""
    CREATE FUNCTION relay_fn.campaign_approve_audience(p_campaign_id uuid, p_reason text,
      p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
      p_access_record_ref text)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_row relay.campaigns;
    BEGIN
      IF p_reason IS NULL OR p_record_digest IS NULL OR p_actor_ref IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-62';
      END IF;
      SELECT * INTO v_row FROM relay.campaigns c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_campaign_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      IF v_row.state <> 'prepared' THEN
        RETURN 'not_prepared';
      END IF;
      IF NOT v_row.audience_approval_required THEN
        RETURN 'not_required';
      END IF;
      UPDATE relay.campaigns c SET audience_approved_at = now(), audience_approved_by = p_actor_ref,
          version = c.version + 1, updated_at = now()
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_campaign_id;
      PERFORM relay_private.audit_write(v_tenant, v_env::text, 'campaign.audience_approved',
        p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'campaign',
        p_campaign_id::text, p_reason, p_record_digest);
      RETURN 'approved';
    END
    $fn$
    """
  end

  defp trigger do
    ~S"""
    CREATE FUNCTION relay_fn.campaign_trigger(p_campaign_id uuid, p_samples_digest bytea,
      p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
      p_access_record_ref text)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_row relay.campaigns;
      v_n bigint;
      v_k1 bigint;
      v_k2 bigint;
      v_b1 uuid;
      v_b2 uuid;
    BEGIN
      IF p_samples_digest IS NULL OR p_record_digest IS NULL OR p_actor_ref IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-44';
      END IF;
      SELECT * INTO v_row FROM relay.campaigns c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_campaign_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      IF v_row.state <> 'prepared' THEN
        RETURN 'not_prepared';
      END IF;
      IF v_row.deadline <= relay_private.business_now() THEN
        RETURN 'deadline_passed';
      END IF;
      IF v_row.samples_approved_at IS NULL THEN
        RETURN 'samples_unapproved';
      END IF;
      IF v_row.samples_digest <> p_samples_digest THEN
        RETURN 'samples_changed';
      END IF;
      IF v_row.audience_approval_required AND v_row.audience_approved_at IS NULL THEN
        RETURN 'audience_unapproved';
      END IF;
      v_n := v_row.audience_count;
      IF v_n > 100000 THEN
        v_k1 := (v_n + 99) / 100;
        v_k2 := (v_n + 9) / 10;
        SELECT s.id INTO v_b1 FROM (SELECT m.id, row_number() OVER (ORDER BY m.id) AS rn
            FROM relay.campaign_members m
            WHERE m.tenant_id = v_tenant AND m.environment = v_env
              AND m.campaign_id = p_campaign_id) s
          WHERE s.rn = v_k1 + 1;
        SELECT s.id INTO v_b2 FROM (SELECT m.id, row_number() OVER (ORDER BY m.id) AS rn
            FROM relay.campaign_members m
            WHERE m.tenant_id = v_tenant AND m.environment = v_env
              AND m.campaign_id = p_campaign_id) s
          WHERE s.rn = v_k2 + 1;
        INSERT INTO relay.campaign_stages (tenant_id, environment, id, campaign_id, stage_no,
          percent, range_from, range_to, member_count, done_count, fanout_id, opened_at,
          created_at, updated_at)
        VALUES (v_tenant, v_env, uuidv7(), p_campaign_id, 1, 1, NULL, v_b1, v_k1, 0, NULL, NULL,
            now(), now()),
          (v_tenant, v_env, uuidv7(), p_campaign_id, 2, 10, v_b1, v_b2, v_k2 - v_k1, 0, NULL,
            NULL, now(), now()),
          (v_tenant, v_env, uuidv7(), p_campaign_id, 3, 100, v_b2, NULL, v_n - v_k2, 0, NULL,
            NULL, now(), now());
      ELSE
        INSERT INTO relay.campaign_stages (tenant_id, environment, id, campaign_id, stage_no,
          percent, range_from, range_to, member_count, done_count, fanout_id, opened_at,
          created_at, updated_at)
        VALUES (v_tenant, v_env, uuidv7(), p_campaign_id, 1, 100, NULL, NULL, v_n, 0, NULL, NULL,
          now(), now());
      END IF;
      UPDATE relay.campaigns c SET state = 'running', triggered_at = now(),
          stage_count = CASE WHEN v_n > 100000 THEN 3 ELSE 1 END, stage_no = 0,
          next_stage_at = now(), version = c.version + 1, updated_at = now()
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_campaign_id;
      PERFORM relay_private.audit_write(v_tenant, v_env::text, 'campaign.triggered',
        p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'campaign',
        p_campaign_id::text, NULL, p_record_digest);
      RETURN 'triggered';
    END
    $fn$
    """
  end

  defp stage_bounds do
    ~S"""
    CREATE FUNCTION relay_fn.campaign_stage_bounds(p_stage_id uuid, p_slice_size bigint)
      RETURNS uuid[]
    LANGUAGE plpgsql STABLE SECURITY INVOKER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_stage relay.campaign_stages;
      v_inner uuid[];
    BEGIN
      IF p_slice_size IS NULL OR p_slice_size < 1 THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'T-23';
      END IF;
      SELECT * INTO v_stage FROM relay.campaign_stages s
        WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = p_stage_id;
      IF NOT FOUND THEN
        RETURN NULL;
      END IF;
      SELECT array_agg(x.id ORDER BY x.id) INTO v_inner
        FROM (SELECT m.id, row_number() OVER (ORDER BY m.id) AS rn
          FROM relay.campaign_members m
          WHERE m.tenant_id = v_tenant AND m.environment = v_env
            AND m.campaign_id = v_stage.campaign_id
            AND (v_stage.range_from IS NULL OR m.id >= v_stage.range_from)
            AND (v_stage.range_to IS NULL OR m.id < v_stage.range_to)) x
        WHERE x.rn > 1 AND (x.rn - 1) % p_slice_size = 0;
      RETURN ARRAY[v_stage.range_from] || COALESCE(v_inner, ARRAY[]::uuid[])
        || ARRAY[v_stage.range_to];
    END
    $fn$
    """
  end

  defp stage_open do
    ~S"""
    CREATE FUNCTION relay_fn.campaign_stage_open(p_campaign_id uuid, p_stage_no bigint,
      p_fanout_id uuid)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_row relay.campaigns;
      v_stage relay.campaign_stages;
    BEGIN
      IF p_stage_no IS NULL OR p_fanout_id IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-62';
      END IF;
      SELECT * INTO v_row FROM relay.campaigns c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_campaign_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      IF v_row.state <> 'running' THEN
        RETURN 'not_running';
      END IF;
      SELECT * INTO v_stage FROM relay.campaign_stages s
        WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.campaign_id = p_campaign_id
          AND s.stage_no = p_stage_no
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      IF v_stage.fanout_id IS NOT NULL THEN
        RETURN 'already_open';
      END IF;
      UPDATE relay.campaign_stages s SET fanout_id = p_fanout_id, opened_at = now(),
          updated_at = now()
        WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = v_stage.id;
      UPDATE relay.campaigns c SET stage_no = p_stage_no, next_stage_at = NULL,
          version = c.version + 1, updated_at = now()
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_campaign_id;
      RETURN 'opened';
    END
    $fn$
    """
  end

  defp stage_wait do
    ~S"""
    CREATE FUNCTION relay_fn.campaign_stage_wait(p_campaign_id uuid, p_until timestamptz)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_row relay.campaigns;
    BEGIN
      IF p_until IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-62';
      END IF;
      SELECT * INTO v_row FROM relay.campaigns c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_campaign_id
        FOR UPDATE;
      IF NOT FOUND OR v_row.state <> 'running' THEN
        RETURN 'not_running';
      END IF;
      IF v_row.next_stage_at IS NOT NULL THEN
        RETURN 'waiting';
      END IF;
      UPDATE relay.campaigns c SET next_stage_at = p_until, version = c.version + 1,
          updated_at = now()
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_campaign_id;
      RETURN 'waiting';
    END
    $fn$
    """
  end

  defp member_mark do
    ~S"""
    CREATE FUNCTION relay_fn.campaign_member_mark(p_campaign_id uuid, p_member_id uuid,
      p_state text, p_notification_id uuid, p_reject_code text)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_campaign_state text;
      v_member_state text;
    BEGIN
      IF p_state IS NULL OR p_state NOT IN ('accepted', 'rejected')
        OR ((p_state = 'accepted') <> (p_notification_id IS NOT NULL))
        OR ((p_state = 'rejected') <> (p_reject_code IS NOT NULL)) THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-44';
      END IF;
      SELECT c.state INTO v_campaign_state FROM relay.campaigns c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_campaign_id
        FOR NO KEY UPDATE;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      IF v_campaign_state <> 'running' THEN
        RETURN 'not_running';
      END IF;
      SELECT m.state INTO v_member_state FROM relay.campaign_members m
        WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.campaign_id = p_campaign_id
          AND m.id = p_member_id
        FOR NO KEY UPDATE;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      IF v_member_state <> 'pending' THEN
        RETURN 'not_pending';
      END IF;
      UPDATE relay.campaign_members m SET state = p_state, notification_id = p_notification_id,
          reject_code = p_reject_code, updated_at = now()
        WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.campaign_id = p_campaign_id
          AND m.id = p_member_id;
      UPDATE relay.campaign_stages s SET done_count = s.done_count + 1, updated_at = now()
        WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.campaign_id = p_campaign_id
          AND (s.range_from IS NULL OR p_member_id >= s.range_from)
          AND (s.range_to IS NULL OR p_member_id < s.range_to);
      UPDATE relay.campaigns c SET
          accepted_count = c.accepted_count + CASE WHEN p_state = 'accepted' THEN 1 ELSE 0 END,
          rejected_count = c.rejected_count + CASE WHEN p_state = 'rejected' THEN 1 ELSE 0 END,
          updated_at = now()
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_campaign_id;
      RETURN 'marked';
    END
    $fn$
    """
  end

  defp pause do
    ~S"""
    CREATE FUNCTION relay_fn.campaign_pause(p_campaign_id uuid, p_rule_id text)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_row relay.campaigns;
    BEGIN
      IF p_rule_id IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-62';
      END IF;
      SELECT * INTO v_row FROM relay.campaigns c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_campaign_id
        FOR UPDATE;
      IF NOT FOUND OR v_row.state <> 'running' THEN
        RETURN 'not_running';
      END IF;
      UPDATE relay.campaigns c SET state = 'paused', pause_rule_id = p_rule_id,
          version = c.version + 1, updated_at = now()
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_campaign_id
        RETURNING * INTO v_row;
      PERFORM relay_private.campaign_emit(v_row, 'campaign.paused');
      RETURN 'paused';
    END
    $fn$
    """
  end

  defp resume do
    ~S"""
    CREATE FUNCTION relay_fn.campaign_resume(p_campaign_id uuid, p_reason text,
      p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
      p_access_record_ref text)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_row relay.campaigns;
    BEGIN
      IF p_reason IS NULL OR p_record_digest IS NULL OR p_actor_ref IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-47';
      END IF;
      SELECT * INTO v_row FROM relay.campaigns c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_campaign_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      IF v_row.state <> 'paused' THEN
        RETURN 'not_paused';
      END IF;
      UPDATE relay.campaigns c SET state = 'running', pause_rule_id = NULL,
          version = c.version + 1, updated_at = now()
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_campaign_id
        RETURNING * INTO v_row;
      PERFORM relay_private.audit_write(v_tenant, v_env::text, 'campaign.resumed',
        p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'campaign',
        p_campaign_id::text, p_reason, p_record_digest);
      PERFORM relay_private.campaign_emit(v_row, 'campaign.resumed');
      RETURN 'resumed';
    END
    $fn$
    """
  end

  defp close do
    ~S"""
    CREATE FUNCTION relay_fn.campaign_close(p_campaign_id uuid, p_rule_id text)
      RETURNS TABLE (result text, state text)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_row relay.campaigns;
      v_left bigint;
    BEGIN
      IF p_rule_id IS NULL OR p_rule_id NOT IN ('campaign.completed', 'campaign.deadline_expired')
      THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-34';
      END IF;
      SELECT * INTO v_row FROM relay.campaigns c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_campaign_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, NULL::text;
        RETURN;
      END IF;
      IF v_row.state IN ('completed', 'partial', 'cancelled') THEN
        RETURN QUERY SELECT 'already_closed'::text, v_row.state;
        RETURN;
      END IF;
      IF v_row.state NOT IN ('running', 'paused') THEN
        RETURN QUERY SELECT 'not_running'::text, v_row.state;
        RETURN;
      END IF;
      v_left := greatest(v_row.audience_count - v_row.accepted_count - v_row.rejected_count, 0);
      IF v_left > 0 AND p_rule_id = 'campaign.completed' THEN
        RETURN QUERY SELECT 'not_done'::text, v_row.state;
        RETURN;
      END IF;
      UPDATE relay.campaigns c SET
          state = CASE WHEN v_left = 0 AND c.rejected_count = 0 THEN 'completed' ELSE 'partial' END,
          expired_count = v_left, pause_rule_id = NULL, close_rule_id = p_rule_id,
          closed_at = now(), next_stage_at = NULL, version = c.version + 1, updated_at = now()
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_campaign_id
        RETURNING * INTO v_row;
      IF v_left > 0 THEN
        PERFORM relay_private.campaign_emit(v_row, 'campaign.expired');
      END IF;
      PERFORM relay_private.campaign_emit(v_row, 'campaign.' || v_row.state);
      RETURN QUERY SELECT 'closed'::text, v_row.state;
    END
    $fn$
    """
  end

  defp cancel do
    ~S"""
    CREATE FUNCTION relay_fn.campaign_cancel(p_campaign_id uuid, p_reason text,
      p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
      p_access_record_ref text)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_row relay.campaigns;
    BEGIN
      IF p_reason IS NULL OR p_record_digest IS NULL OR p_actor_ref IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-44';
      END IF;
      SELECT * INTO v_row FROM relay.campaigns c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_campaign_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      IF v_row.state IN ('completed', 'partial', 'cancelled') THEN
        RETURN 'already_closed';
      END IF;
      UPDATE relay.campaigns c SET state = 'cancelled',
          cancelled_count = greatest(c.audience_count - c.accepted_count - c.rejected_count, 0),
          pause_rule_id = NULL, close_rule_id = 'campaign.cancelled', closed_at = now(),
          next_stage_at = NULL, version = c.version + 1, updated_at = now()
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_campaign_id
        RETURNING * INTO v_row;
      PERFORM relay_fn.drr_cancel('campaign_batch', p_campaign_id, 'campaign.cancelled');
      PERFORM relay_private.audit_write(v_tenant, v_env::text, 'campaign.cancelled',
        p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'campaign',
        p_campaign_id::text, p_reason, p_record_digest);
      PERFORM relay_private.campaign_emit(v_row, 'campaign.cancelled');
      RETURN 'cancelled';
    END
    $fn$
    """
  end

  defp overrun do
    ~S"""
    CREATE FUNCTION relay_fn.campaign_overrun(p_campaign_id uuid)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_reported boolean;
    BEGIN
      SELECT c.overrun_reported INTO v_reported FROM relay.campaigns c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_campaign_id
        FOR NO KEY UPDATE;
      IF NOT FOUND OR v_reported THEN
        RETURN 'already_reported';
      END IF;
      UPDATE relay.campaigns c SET overrun_reported = true, updated_at = now()
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_campaign_id;
      RETURN 'reported';
    END
    $fn$
    """
  end

  defp rates do
    ~S"""
    CREATE FUNCTION relay_fn.campaign_rates(p_campaign_id uuid, p_limit bigint)
      RETURNS TABLE (channel text, sent bigint, delivered bigint, permanent bigint,
        complaints bigint)
    LANGUAGE sql STABLE SECURITY INVOKER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
      WITH recent AS (
        SELECT m.notification_id FROM relay.campaign_members m
        WHERE m.tenant_id = relay_private.ctx_tenant_id()
          AND m.environment = relay_private.ctx_environment()
          AND m.campaign_id = p_campaign_id AND m.state = 'accepted'
        ORDER BY m.updated_at DESC
        LIMIT greatest(coalesce(p_limit, 20000), 1)
      )
      SELECT d.channel::text,
        count(*) FILTER (WHERE d.delivery_rank >= 1 OR d.failure_kind IN ('failed', 'bounced')),
        count(*) FILTER (WHERE d.delivery_rank = 2),
        count(*) FILTER (WHERE d.failure_class IN ('permanent_target', 'permanent_content')),
        count(*) FILTER (WHERE d.failure_reason = 'complaint')
      FROM recent r
      JOIN relay.deliveries d ON d.tenant_id = relay_private.ctx_tenant_id()
        AND d.environment = relay_private.ctx_environment() AND d.notification_id = r.notification_id
      GROUP BY d.channel
    $fn$
    """
  end
end
