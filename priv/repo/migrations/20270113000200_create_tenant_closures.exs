defmodule Relay.Repo.Migrations.CreateTenantClosures do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"
  @actor "text, text, text, text"
  @functions [
    "relay_fn.tenant_close_request(uuid, text, text[], text, text, bytea, #{@actor})",
    "relay_fn.tenant_close_export_ready(uuid, jsonb, bytea, #{@actor})",
    "relay_fn.tenant_close_confirm(uuid, text, bytea, #{@actor})",
    "relay_fn.tenant_close_shred_begin(uuid, text, bytea, #{@actor})",
    "relay_fn.tenant_shred(text[], text[], bytea, #{@actor})",
    "relay_fn.tenant_close_shred_finish(uuid)"
  ]

  # OP-26
  # OP-86
  # TN-12
  # TN-13
  # OP-9
  def up do
    execute(~S"""
    CREATE TABLE relay.tenant_closures (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      id uuid NOT NULL,
      state text NOT NULL
        CONSTRAINT tenant_closures_state_check
          CHECK (state IN ('exporting', 'export_ready', 'shredding', 'shredded')),
      reason text NOT NULL
        CONSTRAINT tenant_closures_reason_check CHECK (char_length(reason) BETWEEN 1 AND 2000),
      formats text[] NOT NULL
        CONSTRAINT tenant_closures_formats_check
          CHECK (cardinality(formats) BETWEEN 1 AND 8
            AND formats <@ ARRAY['jsonl', 'csv', 'parquet']::text[]),
      export_prefix text NOT NULL
        CONSTRAINT tenant_closures_export_prefix_check CHECK (char_length(export_prefix) <= 512),
      export_manifest jsonb
        CONSTRAINT tenant_closures_export_manifest_check
          CHECK (pg_column_size(export_manifest) <= 4194304),
      requested_step_up_ref text
        CONSTRAINT tenant_closures_requested_step_up_ref_check
          CHECK (char_length(requested_step_up_ref) <= 256),
      export_ready_at timestamptz,
      shred_after timestamptz,
      confirmed_at timestamptz,
      confirmation_ref text
        CONSTRAINT tenant_closures_confirmation_ref_check
          CHECK (char_length(confirmation_ref) BETWEEN 1 AND 256),
      shred_step_up_ref text
        CONSTRAINT tenant_closures_shred_step_up_ref_check
          CHECK (char_length(shred_step_up_ref) <= 256),
      shred_started_at timestamptz,
      shredded_at timestamptz,
      created_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      CONSTRAINT tenant_closures_pkey PRIMARY KEY (tenant_id, environment, id),
      CONSTRAINT tenant_closures_tenant_key UNIQUE (tenant_id, environment),
      CONSTRAINT tenant_closures_ready_check
        CHECK ((state = 'exporting') = (export_ready_at IS NULL)
          AND (export_ready_at IS NULL) = (shred_after IS NULL)
          AND (export_ready_at IS NULL) = (export_manifest IS NULL)),
      CONSTRAINT tenant_closures_confirmed_check
        CHECK ((confirmed_at IS NULL) = (confirmation_ref IS NULL)),
      CONSTRAINT tenant_closures_shred_check
        CHECK ((state IN ('shredding', 'shredded')) = (shred_started_at IS NOT NULL)
          AND (state = 'shredded') = (shredded_at IS NOT NULL))
    )
    """)

    execute("""
    CREATE TRIGGER tenant_closures_no_delete BEFORE DELETE ON relay.tenant_closures
      FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    execute("""
    CREATE TRIGGER tenant_closures_no_truncate BEFORE TRUNCATE ON relay.tenant_closures
      FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    execute("ALTER TABLE relay.tenant_closures ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE relay.tenant_closures FORCE ROW LEVEL SECURITY")

    execute(
      "CREATE POLICY tenant_closures_scope ON relay.tenant_closures USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})"
    )

    execute("GRANT SELECT, INSERT, UPDATE ON relay.tenant_closures TO relay_owner")

    execute(
      "GRANT SELECT ON relay.tenant_closures TO relay_app, relay_maint, relay_archive, relay_report"
    )

    Enum.each(
      [request(), export_ready(), confirm(), shred_begin(), shred(), shred_finish()],
      &execute/1
    )

    for signature <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      execute("GRANT EXECUTE ON FUNCTION #{signature} TO relay_app")
      execute("ALTER FUNCTION #{signature} OWNER TO relay_owner")
    end
  end

  def down, do: :ok

  defp request do
    ~S"""
    CREATE FUNCTION relay_fn.tenant_close_request(p_id uuid, p_reason text, p_formats text[],
      p_export_prefix text, p_step_up_ref text, p_record_digest bytea, p_actor_kind text,
      p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
      RETURNS TABLE (result text, closure_id uuid)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant relay.tenants;
      v_existing uuid;
    BEGIN
      IF p_id IS NULL OR p_reason IS NULL OR p_formats IS NULL OR p_export_prefix IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-86';
      END IF;
      IF relay_private.ctx_environment() <> 'live' THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-86';
      END IF;
      SELECT * INTO v_tenant FROM relay.tenants t
        WHERE t.id = relay_private.ctx_tenant_id() FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'scope_missing' USING HINT = 'TN-13';
      END IF;
      IF v_tenant.kind <> 'tenant' THEN
        RETURN QUERY SELECT 'not_allowed'::text, NULL::uuid;
        RETURN;
      END IF;
      SELECT c.id INTO v_existing FROM relay.tenant_closures c
        WHERE c.tenant_id = v_tenant.id AND c.environment = 'live';
      IF FOUND THEN
        RETURN QUERY SELECT 'exists'::text, v_existing;
        RETURN;
      END IF;
      PERFORM relay_private.assert_new_id(p_id);
      INSERT INTO relay.tenant_closures (tenant_id, environment, id, state, reason, formats,
        export_prefix, export_manifest, requested_step_up_ref, export_ready_at, shred_after,
        confirmed_at, confirmation_ref, shred_step_up_ref, shred_started_at, shredded_at,
        created_at, updated_at)
      VALUES (v_tenant.id, 'live', p_id, 'exporting', p_reason, p_formats, p_export_prefix, NULL,
        p_step_up_ref, NULL, NULL, NULL, NULL, NULL, NULL, NULL, now(), now());
      IF v_tenant.status <> 'closed' THEN
        UPDATE relay.tenants t SET status = 'closed', status_reason = p_reason,
            status_changed_at = now(), closed_at = now(), version = t.version + 1,
            updated_at = now()
          WHERE t.id = v_tenant.id;
      END IF;
      PERFORM relay_private.audit_write(v_tenant.id, 'live', 'tenant.closed', p_actor_kind,
        p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'tenant', v_tenant.id::text,
        p_reason, p_record_digest);
      RETURN QUERY SELECT 'requested'::text, p_id;
    END
    $fn$
    """
  end

  defp export_ready do
    ~S"""
    CREATE FUNCTION relay_fn.tenant_close_export_ready(p_id uuid, p_manifest jsonb,
      p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
      p_access_record_ref text) RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_closure relay.tenant_closures;
    BEGIN
      IF p_id IS NULL OR p_manifest IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-86';
      END IF;
      SELECT * INTO v_closure FROM relay.tenant_closures c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_id FOR UPDATE;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      IF v_closure.state <> 'exporting' THEN
        RETURN 'not_exporting';
      END IF;
      UPDATE relay.tenant_closures c SET state = 'export_ready', export_manifest = p_manifest,
          export_ready_at = now(), shred_after = now() + interval '30 days', updated_at = now()
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_id;
      PERFORM relay_private.audit_write(v_tenant, v_env, 'tenant.export_ready', p_actor_kind,
        p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'tenant_closure', p_id::text, NULL,
        p_record_digest);
      RETURN 'ready';
    END
    $fn$
    """
  end

  defp confirm do
    ~S"""
    CREATE FUNCTION relay_fn.tenant_close_confirm(p_id uuid, p_confirmation_ref text,
      p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
      p_access_record_ref text) RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_closure relay.tenant_closures;
    BEGIN
      IF p_id IS NULL OR p_confirmation_ref IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-86';
      END IF;
      SELECT * INTO v_closure FROM relay.tenant_closures c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_id FOR UPDATE;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      IF v_closure.confirmed_at IS NOT NULL THEN
        RETURN 'already_confirmed';
      END IF;
      IF v_closure.state <> 'export_ready' THEN
        RETURN 'not_ready';
      END IF;
      UPDATE relay.tenant_closures c SET confirmed_at = now(),
          confirmation_ref = p_confirmation_ref, shred_after = LEAST(c.shred_after, now()),
          updated_at = now()
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_id;
      PERFORM relay_private.audit_write(v_tenant, v_env, 'tenant.closure_confirmed',
        p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'tenant_closure',
        p_id::text, p_confirmation_ref, p_record_digest);
      RETURN 'confirmed';
    END
    $fn$
    """
  end

  defp shred_begin do
    ~S"""
    CREATE FUNCTION relay_fn.tenant_close_shred_begin(p_id uuid, p_step_up_ref text,
      p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
      p_access_record_ref text) RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_closure relay.tenant_closures;
    BEGIN
      IF p_id IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-86';
      END IF;
      SELECT * INTO v_closure FROM relay.tenant_closures c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_id FOR UPDATE;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      IF v_closure.state IN ('shredding', 'shredded') THEN
        RETURN 'already_started';
      END IF;
      IF v_closure.state <> 'export_ready' THEN
        RETURN 'not_ready';
      END IF;
      IF now() < v_closure.shred_after THEN
        RETURN 'not_due';
      END IF;
      UPDATE relay.tenant_closures c SET state = 'shredding', shred_started_at = now(),
          shred_step_up_ref = p_step_up_ref, updated_at = now()
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_id;
      PERFORM relay_private.audit_write(v_tenant, v_env, 'tenant.shred_started', p_actor_kind,
        p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'tenant_closure', p_id::text, NULL,
        p_record_digest);
      RETURN 'started';
    END
    $fn$
    """
  end

  defp shred do
    ~S"""
    CREATE FUNCTION relay_fn.tenant_shred(p_destroy_classes text[], p_restrict_classes text[],
      p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
      p_access_record_ref text)
      RETURNS TABLE (result text, destroyed_keys bigint, destroyed_deks bigint,
        restricted_deks bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_keys bigint := 0;
      v_wraps bigint := 0;
      v_deks bigint := 0;
      v_restricted bigint := 0;
    BEGIN
      IF p_destroy_classes IS NULL OR p_restrict_classes IS NULL
        OR p_destroy_classes && p_restrict_classes THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-26';
      END IF;
      IF relay_private.tenant_status() <> 'closed' THEN
        RETURN QUERY SELECT 'not_allowed'::text, 0::bigint, 0::bigint, 0::bigint;
        RETURN;
      END IF;
      IF EXISTS (SELECT 1 FROM relay.legal_holds h
        WHERE h.tenant_id = v_tenant AND h.environment = v_env AND h.scope = 'tenant'
          AND h.state = 'active') THEN
        RETURN QUERY SELECT 'held'::text, 0::bigint, 0::bigint, 0::bigint;
        RETURN;
      END IF;
      UPDATE relay.subject_keys s SET state = 'destroyed', wrapped_dek = NULL,
          destroyed_at = now(), destroy_reason = 'tenant_closed'
        WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.state <> 'destroyed'
          AND s.retention_class::text = ANY (p_destroy_classes)
          AND NOT EXISTS (SELECT 1 FROM relay.legal_holds h
            WHERE h.tenant_id = v_tenant AND h.environment = v_env AND h.scope = 'recipient'
              AND h.recipient_id = s.recipient_id AND h.state = 'active');
      GET DIAGNOSTICS v_deks = ROW_COUNT;
      UPDATE relay.subject_keys s SET state = 'restricted', restricted_at = now()
        WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.state = 'active'
          AND s.retention_class::text = ANY (p_restrict_classes);
      GET DIAGNOSTICS v_restricted = ROW_COUNT;
      UPDATE relay.tenant_keys k SET state = 'destroyed', wrapped_key = NULL, destroyed_at = now()
        WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.state <> 'destroyed'
          AND k.purpose = 'data';
      GET DIAGNOSTICS v_keys = ROW_COUNT;
      UPDATE relay.tenant_keys k SET state = 'destroyed', wrapped_key = NULL, destroyed_at = now()
        WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.state <> 'destroyed'
          AND k.purpose = 'dek_wrap'
          AND NOT EXISTS (SELECT 1 FROM relay.subject_keys s
            WHERE s.tenant_id = v_tenant AND s.environment = v_env
              AND s.wrapping_key_id = k.id AND s.state <> 'destroyed');
      GET DIAGNOSTICS v_wraps = ROW_COUNT;
      IF v_keys + v_wraps + v_deks + v_restricted > 0 THEN
        PERFORM relay_private.audit_write(v_tenant, v_env, 'tenant.shredded', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'tenant', v_tenant::text,
          'tenant_closed', p_record_digest);
      END IF;
      RETURN QUERY SELECT 'shredded'::text, v_keys + v_wraps, v_deks, v_restricted;
    END
    $fn$
    """
  end

  defp shred_finish do
    ~S"""
    CREATE FUNCTION relay_fn.tenant_close_shred_finish(p_id uuid) RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_closure relay.tenant_closures;
    BEGIN
      SELECT * INTO v_closure FROM relay.tenant_closures c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_id FOR UPDATE;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      IF v_closure.state = 'shredded' THEN
        RETURN 'already_shredded';
      END IF;
      IF v_closure.state <> 'shredding' THEN
        RETURN 'not_shredding';
      END IF;
      UPDATE relay.tenant_closures c SET state = 'shredded', shredded_at = now(),
          updated_at = now()
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_id;
      RETURN 'shredded';
    END
    $fn$
    """
  end
end
