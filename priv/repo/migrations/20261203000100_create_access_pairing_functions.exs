defmodule Relay.Repo.Migrations.CreateAccessPairingFunctions do
  use Ecto.Migration

  @signatures [
    "relay_ops.access_pairing_tenants(text, integer)",
    "relay_ops.access_pairing_seen(text, uuid[], text[])",
    "relay_ops.access_pairing_apply(text, uuid, text, bytea, bytea, bytea, bytea, text)",
    "relay_ops.access_event_stream_record(uuid, text, boolean)"
  ]

  # E-101
  # TN-13 (4)
  # OP-8
  def up do
    Enum.each(statements(), &execute/1)

    for signature <- @signatures do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      execute("GRANT EXECUTE ON FUNCTION #{signature} TO relay_worker")
    end
  end

  def down, do: :ok

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_ops.access_pairing_tenants(p_after text, p_limit integer)
        RETURNS TABLE (access_tenant_id text)
      LANGUAGE sql STABLE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT t.access_tenant_id FROM relay.tenants t
        WHERE t.kind = 'tenant' AND t.status = 'active'
          AND t.access_tenant_id COLLATE "C" > COALESCE(p_after, '') COLLATE "C"
        ORDER BY t.access_tenant_id COLLATE "C"
        LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 1000)
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.access_pairing_seen(p_access_tenant_id text, p_realms uuid[],
        p_slugs text[]) RETURNS bigint
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_retired bigint;
      BEGIN
        IF p_access_tenant_id IS NULL OR p_realms IS NULL OR p_slugs IS NULL
          OR cardinality(p_realms) <> cardinality(p_slugs) THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'E-101';
        END IF;
        INSERT INTO relay.access_pairing_realms AS r (access_tenant_id, realm, slug, state,
          failed_runs, created_at, updated_at)
        SELECT p_access_tenant_id, l.realm, l.slug, 'unpaired', 0, now(), now()
        FROM unnest(p_realms, p_slugs) AS l (realm, slug)
        ON CONFLICT (access_tenant_id, realm) DO UPDATE SET slug = EXCLUDED.slug,
          state = CASE WHEN r.state = 'retired' THEN 'unpaired' ELSE r.state END,
          failed_runs = CASE WHEN r.state = 'retired' THEN 0 ELSE r.failed_runs END,
          updated_at = now()
        WHERE r.slug <> EXCLUDED.slug OR r.state = 'retired';
        UPDATE relay.access_pairing_realms r
          SET state = 'retired', refusal_code = NULL, updated_at = now()
          WHERE r.access_tenant_id = p_access_tenant_id AND r.state <> 'retired'
            AND r.realm <> ALL (p_realms);
        GET DIAGNOSTICS v_retired = ROW_COUNT;
        RETURN v_retired;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.access_pairing_apply(p_access_tenant_id text, p_realm uuid,
        p_change text, p_kid bytea, p_governing_domain bytea, p_service_party bytea,
        p_service_instance bytea, p_code text) RETURNS TABLE (result text, runs bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_runs bigint;
      BEGIN
        IF p_change IS NULL OR p_change NOT IN ('unpaired', 'paired', 'refused', 'failed') THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'E-101';
        END IF;
        IF p_change = 'unpaired' THEN
          UPDATE relay.access_pairing_realms r
            SET state = 'unpaired', refusal_code = NULL, kid = p_kid,
              governing_domain = p_governing_domain, service_party = p_service_party,
              updated_at = now()
            WHERE r.access_tenant_id = p_access_tenant_id AND r.realm = p_realm
              AND r.state <> 'retired'
            RETURNING r.failed_runs INTO v_runs;
        ELSIF p_change = 'paired' THEN
          UPDATE relay.access_pairing_realms r
            SET state = 'paired', refusal_code = NULL, kid = p_kid,
              governing_domain = COALESCE(p_governing_domain, r.governing_domain),
              service_party = p_service_party, service_instance = p_service_instance,
              failed_runs = 0,
              paired_at = CASE WHEN r.state = 'paired' AND r.kid = p_kid THEN r.paired_at
                ELSE now() END,
              updated_at = now()
            WHERE r.access_tenant_id = p_access_tenant_id AND r.realm = p_realm
              AND r.state <> 'retired'
            RETURNING r.failed_runs INTO v_runs;
        ELSIF p_change = 'refused' THEN
          UPDATE relay.access_pairing_realms r
            SET state = 'refused', refusal_code = p_code, updated_at = now()
            WHERE r.access_tenant_id = p_access_tenant_id AND r.realm = p_realm
              AND r.state <> 'retired'
            RETURNING r.failed_runs INTO v_runs;
        ELSE
          UPDATE relay.access_pairing_realms r
            SET failed_runs = r.failed_runs + 1, updated_at = now()
            WHERE r.access_tenant_id = p_access_tenant_id AND r.realm = p_realm
              AND r.state <> 'retired'
            RETURNING r.failed_runs INTO v_runs;
        END IF;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
          RETURN;
        END IF;
        RETURN QUERY SELECT 'stored'::text, v_runs;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.access_event_stream_record(p_stream uuid, p_status text,
        p_recreated boolean) RETURNS bigint
      LANGUAGE sql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        INSERT INTO relay.access_event_stream AS s (singleton, stream, status, recreated,
          checked_at, updated_at)
        VALUES (true, p_stream, p_status, CASE WHEN p_recreated THEN 1 ELSE 0 END, now(), now())
        ON CONFLICT (singleton) DO UPDATE SET stream = EXCLUDED.stream,
          status = EXCLUDED.status, recreated = s.recreated + EXCLUDED.recreated,
          checked_at = now(), updated_at = now()
        RETURNING s.recreated
      $fn$
      """
    ]
  end
end
