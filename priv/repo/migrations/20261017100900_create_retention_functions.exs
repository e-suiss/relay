defmodule Relay.Repo.Migrations.CreateRetentionFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"

  @functions [
    {"relay_ops.receipt_keys_due(date, integer)", "relay_maint", ~w(relay_worker)},
    {"relay_fn.subject_key_retire(uuid, bytea, #{@actor})", "relay_owner", ~w(relay_app)},
    {"relay_ops.retention_due(integer)", "relay_maint", ~w(relay_worker)}
  ]

  # OP-16
  # OP-18
  # OP-26
  def up do
    Enum.each(statements(), &execute/1)

    for {signature, owner, grantees} <- @functions do
      execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
    end
  end

  def down do
    for {signature, _owner, _grantees} <- Enum.reverse(@functions),
        do: execute("DROP FUNCTION #{signature}")
  end

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_ops.receipt_keys_due(p_last_day date, p_limit integer)
        RETURNS TABLE (tenant_id uuid, environment text, key_id uuid, valid_day date)
      LANGUAGE sql STABLE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT k.tenant_id, k.environment::text, k.id, k.valid_day
        FROM relay.tenant_keys k
        WHERE k.purpose = 'receipt_day' AND k.state <> 'destroyed'
          AND k.valid_day <= p_last_day AND k.valid_day + 7 <= current_date
        ORDER BY k.valid_day, k.tenant_id, k.environment, k.id
        LIMIT GREATEST(COALESCE(p_limit, 100), 1)
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.subject_key_retire(p_subject_key_id uuid, p_record_digest bytea,
        p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_key relay.subject_keys;
      BEGIN
        SELECT * INTO v_key FROM relay.subject_keys k
          WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.id = p_subject_key_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_key.state = 'destroyed' THEN
          RETURN 'already_destroyed';
        END IF;
        IF EXISTS (SELECT 1 FROM relay.legal_holds h
          WHERE h.tenant_id = v_tenant AND h.environment = v_env AND h.state = 'active'
            AND (h.scope = 'tenant' OR h.recipient_id = v_key.recipient_id)) THEN
          RETURN 'held';
        END IF;
        UPDATE relay.subject_keys k SET wrapped_dek = NULL, state = 'destroyed',
            destroyed_at = now(), destroy_reason = 'retention_end'
          WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.id = p_subject_key_id;
        PERFORM relay_private.audit_write(v_tenant, v_env, 'subject_key.retired', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'subject_key',
          p_subject_key_id::text, v_key.retention_class, p_record_digest);
        RETURN 'retired';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.retention_due(p_limit integer)
        RETURNS TABLE (tenant_id uuid, environment text, subject_key_id uuid, recipient_id uuid,
          retention_class text, due_at timestamptz)
      LANGUAGE sql STABLE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        WITH periods AS (
          SELECT p ->> 'region' AS region, p ->> 'sector' AS sector,
            p ->> 'retention_class' AS retention_class, (p ->> 'days')::integer AS days
          FROM relay.dataset_active a
          JOIN relay.dataset_versions v
            ON v.tenant_id = a.tenant_id AND v.environment = a.environment AND v.id = a.version_id
          CROSS JOIN LATERAL jsonb_array_elements(v.content -> 'periods') AS p
          WHERE a.tenant_id = relay_private.installation_tenant_id() AND a.environment = 'live'
            AND a.dataset_name = 'retention_periods'
        )
        SELECT k.tenant_id, k.environment::text, k.id, k.recipient_id, k.retention_class::text,
          k.created_at + make_interval(days => p.days)
        FROM relay.subject_keys k
        JOIN relay.tenants t ON t.id = k.tenant_id
        JOIN periods p
          ON p.region = t.region AND p.sector = t.sector AND p.retention_class = k.retention_class
        WHERE k.state IN ('active', 'restricted')
          AND k.created_at + make_interval(days => p.days) <= now()
          AND NOT EXISTS (SELECT 1 FROM relay.legal_holds h
            WHERE h.tenant_id = k.tenant_id AND h.environment = k.environment AND h.state = 'active'
              AND (h.scope = 'tenant' OR h.recipient_id = k.recipient_id))
        ORDER BY 6, k.tenant_id, k.environment, k.id
        LIMIT GREATEST(COALESCE(p_limit, 100), 1)
      $fn$
      """
    ]
  end
end
