defmodule Relay.Repo.Migrations.CreateKillSwitchEffects do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"
  @record "relay_fn.kill_switch_effect_record(uuid, bigint)"

  # TN-44
  # TN-12
  # TN-13
  def up do
    execute(~S"""
    CREATE TABLE relay.kill_switch_effects (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      kill_switch_id uuid NOT NULL,
      paused_count bigint NOT NULL
        CONSTRAINT kill_switch_effects_paused_count_check CHECK (paused_count >= 0),
      effect_delay_ms bigint NOT NULL
        CONSTRAINT kill_switch_effects_effect_delay_ms_check CHECK (effect_delay_ms >= 0),
      effective_at timestamptz NOT NULL,
      created_at timestamptz NOT NULL,
      CONSTRAINT kill_switch_effects_pkey PRIMARY KEY (tenant_id, environment, kill_switch_id),
      CONSTRAINT kill_switch_effects_kill_switch_id_fkey
        FOREIGN KEY (tenant_id, environment, kill_switch_id)
        REFERENCES relay.kill_switches (tenant_id, environment, id)
        ON DELETE RESTRICT ON UPDATE RESTRICT
    )
    """)

    execute("""
    CREATE TRIGGER kill_switch_effects_no_delete BEFORE DELETE ON relay.kill_switch_effects
      FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    execute("""
    CREATE TRIGGER kill_switch_effects_no_truncate BEFORE TRUNCATE ON relay.kill_switch_effects
      FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    execute("ALTER TABLE relay.kill_switch_effects ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE relay.kill_switch_effects FORCE ROW LEVEL SECURITY")

    execute(
      "CREATE POLICY kill_switch_effects_scope ON relay.kill_switch_effects USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})"
    )

    execute("GRANT SELECT, INSERT, UPDATE ON relay.kill_switch_effects TO relay_owner")

    execute(
      "GRANT SELECT ON relay.kill_switch_effects TO relay_app, relay_maint, relay_archive, relay_report"
    )

    execute(~S"""
    CREATE FUNCTION relay_fn.kill_switch_effect_record(p_kill_switch_id uuid,
      p_effect_delay_ms bigint) RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_paused bigint;
    BEGIN
      IF p_kill_switch_id IS NULL OR p_effect_delay_ms IS NULL OR p_effect_delay_ms < 0 THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-44';
      END IF;
      IF NOT EXISTS (SELECT 1 FROM relay.kill_switches k
        WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.id = p_kill_switch_id) THEN
        RETURN 'not_found';
      END IF;
      SELECT count(*) INTO v_paused FROM relay.deliveries d
        WHERE d.tenant_id = v_tenant AND d.environment = v_env
          AND d.pause_kill_switch_id = p_kill_switch_id AND d.paused_at IS NOT NULL;
      INSERT INTO relay.kill_switch_effects (tenant_id, environment, kill_switch_id,
          paused_count, effect_delay_ms, effective_at, created_at)
        VALUES (v_tenant, v_env, p_kill_switch_id, v_paused, p_effect_delay_ms, now(), now())
        ON CONFLICT (tenant_id, environment, kill_switch_id) DO NOTHING;
      IF FOUND THEN
        RETURN 'recorded';
      END IF;
      RETURN 'exists';
    END
    $fn$
    """)

    execute("REVOKE ALL ON FUNCTION #{@record} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@record} TO relay_app")
    execute("ALTER FUNCTION #{@record} OWNER TO relay_owner")
  end

  def down, do: :ok
end
