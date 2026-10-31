defmodule Relay.Repo.Migrations.RecreateTenantCreateForPlatformTenants do
  use Ecto.Migration

  @old "relay_ops.tenant_create(uuid, text, text, text, text, text, bytea, text, text, text, text)"
  @new "relay_ops.tenant_create(uuid, text, text, text, text, text, text, text, bytea, text, text, text, text)"

  # TN-1
  # TN-2
  # TN-9
  # E-9
  # INV-41
  def up do
    execute("DROP FUNCTION #{@old}")
    execute(tenant_create())
    execute("REVOKE ALL ON FUNCTION #{@new} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@new} TO relay_app")
  end

  defp tenant_create do
    ~S"""
    CREATE FUNCTION relay_ops.tenant_create(p_id uuid, p_access_tenant_id text, p_region text,
      p_sector text, p_default_timezone text, p_default_locale text,
      p_access_organization_id text, p_platform_product text, p_record_digest bytea,
      p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
      RETURNS TABLE (result text, tenant_id uuid)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_region text;
      v_sector text := COALESCE(p_sector, 'general');
      v_existing relay.tenants;
      v_inserted uuid;
    BEGIN
      PERFORM relay_private.assert_new_id(p_id);
      IF p_access_tenant_id IS NULL OR p_region IS NULL OR p_default_timezone IS NULL
        OR p_default_locale IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-2';
      END IF;
      SELECT i.region INTO v_region FROM relay.installation i;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'invariant_violation' USING HINT = 'INV-41';
      END IF;
      IF v_region <> p_region THEN
        RETURN QUERY SELECT 'region_mismatch'::text, NULL::uuid;
        RETURN;
      END IF;
      PERFORM pg_advisory_xact_lock(hashtextextended('tenant|' || p_access_tenant_id, 0));
      INSERT INTO relay.tenants AS t (id, kind, access_tenant_id, region, sector, default_timezone,
        default_locale, access_organization_id, platform_product, status, status_reason,
        status_changed_at, closed_at, version, created_at, updated_at)
      VALUES (p_id, 'tenant', p_access_tenant_id, p_region, v_sector, p_default_timezone,
        p_default_locale, p_access_organization_id, p_platform_product, 'active', NULL, now(),
        NULL, 1, now(), now())
      ON CONFLICT DO NOTHING
      RETURNING t.id INTO v_inserted;
      IF v_inserted IS NULL THEN
        SELECT * INTO v_existing FROM relay.tenants t WHERE t.access_tenant_id = p_access_tenant_id;
        IF FOUND AND v_existing.kind = 'tenant'
          AND v_existing.region = p_region
          AND v_existing.sector = v_sector
          AND v_existing.default_timezone = p_default_timezone
          AND v_existing.default_locale = p_default_locale
          AND v_existing.platform_product IS NOT DISTINCT FROM p_platform_product THEN
          RETURN QUERY SELECT 'exists'::text, v_existing.id;
        ELSE
          RETURN QUERY SELECT 'conflict'::text, v_existing.id;
        END IF;
        RETURN;
      END IF;
      PERFORM relay_private.audit_write(p_id, 'live', 'tenant.created', p_actor_kind, p_actor_ref,
        p_on_behalf_of_ref, p_access_record_ref, 'tenant', p_id::text, NULL, p_record_digest);
      RETURN QUERY SELECT 'created'::text, p_id;
    END
    $fn$
    """
  end
end
