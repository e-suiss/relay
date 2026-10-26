defmodule Relay.Repo.Migrations.CreateVirtualClockFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"

  @functions [
    {"relay_private.business_now()", "relay_migrator", ~w(relay_owner relay_app relay_report)},
    {"relay_fn.virtual_clock_advance(bigint, bytea, #{@actor})", "relay_owner", ~w(relay_app)},
    {"relay_fn.virtual_clock_get()", "relay_owner", ~w(relay_app relay_report)}
  ]

  # TN-8
  # X-27
  # C-13
  # T-57 (3)
  def up do
    Enum.each(statements(), &execute/1)

    for {signature, owner, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      if owner == "relay_owner", do: execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
    end
  end

  def down do
    for {signature, _owner, _grantees} <- Enum.reverse(@functions),
        do: execute("DROP FUNCTION #{signature}")
  end

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_private.business_now() RETURNS timestamptz
      LANGUAGE sql STABLE
      SET search_path = pg_catalog, pg_temp
      AS $fn$
        SELECT now() + CASE WHEN relay_private.ctx_environment() = 'test'
          THEN coalesce((SELECT offset_ms FROM relay.virtual_clocks
                         WHERE tenant_id = relay_private.ctx_tenant_id() AND environment = 'test'), 0)
               * interval '1 millisecond'
          ELSE interval '0' END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.virtual_clock_advance(p_by_ms bigint, p_record_digest bytea,
        p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, offset_ms bigint, business_now timestamptz)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_offset bigint;
      BEGIN
        IF v_env <> 'test' THEN
          RETURN QUERY SELECT 'not_test_environment'::text, NULL::bigint, NULL::timestamptz;
          RETURN;
        END IF;
        IF p_by_ms IS NULL OR p_by_ms < 1 OR p_by_ms > 31622400000 THEN
          RETURN QUERY SELECT 'invalid_step'::text, NULL::bigint, NULL::timestamptz;
          RETURN;
        END IF;
        SELECT v.offset_ms INTO v_offset FROM relay.virtual_clocks v
          WHERE v.tenant_id = v_tenant AND v.environment = 'test'
          FOR NO KEY UPDATE;
        IF COALESCE(v_offset, 0) + p_by_ms > 315360000000 THEN
          RETURN QUERY SELECT 'invalid_step'::text, v_offset, NULL::timestamptz;
          RETURN;
        END IF;
        INSERT INTO relay.virtual_clocks AS v (tenant_id, environment, offset_ms, version,
          updated_at, updated_by_ref)
        VALUES (v_tenant, 'test', p_by_ms, 1, now(), p_actor_ref)
        ON CONFLICT (tenant_id, environment) DO UPDATE
          SET offset_ms = v.offset_ms + p_by_ms, version = v.version + 1, updated_at = now(),
            updated_by_ref = p_actor_ref
        RETURNING v.offset_ms INTO v_offset;
        PERFORM relay_private.audit_write(v_tenant, v_env, 'virtual_clock.advanced', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'virtual_clock', v_tenant::text,
          p_by_ms::text, p_record_digest);
        RETURN QUERY SELECT 'advanced'::text, v_offset, now() + v_offset * interval '1 millisecond';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.virtual_clock_get()
        RETURNS TABLE (result text, offset_ms bigint, business_now timestamptz)
      LANGUAGE plpgsql STABLE SECURITY INVOKER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      BEGIN
        IF relay_private.ctx_environment() <> 'test' THEN
          RETURN QUERY SELECT 'not_test_environment'::text, NULL::bigint, NULL::timestamptz;
          RETURN;
        END IF;
        RETURN QUERY SELECT 'ok'::text,
          COALESCE((SELECT v.offset_ms FROM relay.virtual_clocks v
            WHERE v.tenant_id = relay_private.ctx_tenant_id() AND v.environment = 'test'), 0)::bigint,
          relay_private.business_now();
      END
      $fn$
      """
    ]
  end
end
