defmodule Relay.Repo.Migrations.CreateUsageDayScopes do
  use Ecto.Migration

  @signature "relay_ops.usage_day_scopes(date, uuid, text, integer)"

  # C-88
  # OP-38
  # T-87
  def up do
    execute(~S"""
    CREATE FUNCTION relay_ops.usage_day_scopes(p_day date, p_after_tenant uuid,
      p_after_environment text, p_limit integer)
      RETURNS TABLE (tenant_id uuid, environment text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
      SELECT DISTINCT a.tenant_id, a.environment::text
      FROM relay.delivery_attempts a
      WHERE a.finished_at >= p_day::timestamptz
        AND a.finished_at < (p_day + 1)::timestamptz
        AND a.created_at >= p_day::timestamptz - interval '7 days'
        AND a.created_at < (p_day + 1)::timestamptz
        AND (p_after_tenant IS NULL
          OR (a.tenant_id, a.environment::text) > (p_after_tenant, p_after_environment))
      ORDER BY a.tenant_id, a.environment::text
      LIMIT GREATEST(COALESCE(p_limit, 100), 1)
    $fn$
    """)

    execute("REVOKE ALL ON FUNCTION #{@signature} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@signature} TO relay_worker")
  end

  def down, do: :ok
end
