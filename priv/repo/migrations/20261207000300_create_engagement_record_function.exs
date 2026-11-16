defmodule Relay.Repo.Migrations.CreateEngagementRecordFunction do
  use Ecto.Migration

  @signature "relay_fn.engagement_record(uuid, uuid, text, text, timestamptz, smallint, jsonb, text, text)"

  # DS-33
  # DS-34
  # DS-13
  # E-84
  def up do
    execute(~S"""
    CREATE FUNCTION relay_fn.engagement_record(p_id uuid, p_delivery_id uuid, p_actor text,
      p_event_type text, p_occurred_at timestamptz, p_delivery_rank smallint, p_detail jsonb,
      p_announce text, p_link_rel text)
      RETURNS TABLE (result text, delivery_rank smallint, projection_version bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_result text;
      v_rank smallint;
      v_version bigint;
      v_delivery relay.deliveries;
    BEGIN
      IF p_event_type IS NULL OR p_event_type NOT IN ('engagement.opened', 'engagement.clicked',
          'engagement.displayed')
        OR (p_announce IS NOT NULL AND p_announce NOT IN ('seen', 'clicked')) THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'DS-33';
      END IF;
      SELECT a.result, a.delivery_rank, a.projection_version INTO v_result, v_rank, v_version
        FROM relay_fn.ledger_append(p_id, p_delivery_id, NULL, p_actor, p_event_type, NULL, NULL,
          NULL, p_occurred_at, NULL, p_delivery_rank, NULL, NULL, NULL, NULL, p_detail, NULL) a;
      IF p_announce IS NOT NULL
        AND v_result IN ('applied', 'stale_ignored', 'conflict_flagged') THEN
        SELECT * INTO v_delivery FROM relay.deliveries d
          WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_delivery_id;
        PERFORM relay_private.engagement_announce(v_delivery, p_announce, p_link_rel,
          LEAST(p_occurred_at, now()));
      END IF;
      RETURN QUERY SELECT v_result, v_rank, v_version;
    END
    $fn$
    """)

    execute("REVOKE ALL ON FUNCTION #{@signature} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@signature} TO relay_app")
    execute("ALTER FUNCTION #{@signature} OWNER TO relay_owner")
  end

  def down, do: :ok
end
