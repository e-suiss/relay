defmodule Relay.Repo.Migrations.AddAgentAccessSub do
  use Ecto.Migration

  @signature "relay_fn.agent_bind_sub(uuid, bytea[], bytea, bytea)"

  # E-106
  # AG-75
  # E-29
  # OP-57
  def up do
    execute("ALTER TABLE relay.agents ADD COLUMN access_sub_ct bytea")
    execute("ALTER TABLE relay.agents ADD COLUMN access_sub_bidx bytea")

    execute(~S"""
    ALTER TABLE relay.agents ADD CONSTRAINT agents_access_sub_bidx_check
      CHECK (octet_length(access_sub_bidx) = 32) NOT VALID
    """)

    execute(~S"""
    ALTER TABLE relay.agents ADD CONSTRAINT agents_access_sub_ct_check
      CHECK (access_sub_bidx IS NULL OR access_sub_ct IS NOT NULL) NOT VALID
    """)

    execute(bind_sub())
    execute("REVOKE ALL ON FUNCTION #{@signature} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@signature} TO relay_app")
    execute("ALTER FUNCTION #{@signature} OWNER TO relay_owner")
    execute(agents_erase())
  end

  def down, do: :ok

  defp bind_sub do
    ~S"""
    CREATE FUNCTION relay_fn.agent_bind_sub(p_id uuid, p_party_bidxs bytea[], p_sub_bidx bytea,
      p_sub_ct bytea)
      RETURNS TABLE (result text, agent_id uuid)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_agent relay.agents;
      v_id uuid;
    BEGIN
      IF p_sub_bidx IS NULL OR octet_length(p_sub_bidx) <> 32 OR p_sub_ct IS NULL
        OR (p_id IS NULL) = (p_party_bidxs IS NULL) THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'E-106';
      END IF;
      v_id := p_id;
      IF v_id IS NULL THEN
        SELECT r.id INTO v_id FROM relay.recipients r
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.kind = 'agent'
            AND (r.external_id_bidx = ANY (p_party_bidxs)
              OR r.external_id_bidx_next = ANY (p_party_bidxs))
          LIMIT 1;
      END IF;
      SELECT * INTO v_agent FROM relay.agents a
        WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = v_id
        FOR NO KEY UPDATE;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, NULL::uuid;
        RETURN;
      END IF;
      IF v_agent.state = 'deleted' THEN
        RETURN QUERY SELECT 'deleted'::text, v_agent.id;
        RETURN;
      END IF;
      IF v_agent.access_sub_bidx IS NOT NULL THEN
        RETURN QUERY SELECT CASE WHEN v_agent.access_sub_bidx = p_sub_bidx
          THEN 'unchanged' ELSE 'sub_conflict' END, v_agent.id;
        RETURN;
      END IF;
      IF EXISTS (SELECT 1 FROM relay.agents a
        WHERE a.tenant_id = v_tenant AND a.environment = v_env
          AND a.access_sub_bidx = p_sub_bidx) THEN
        RETURN QUERY SELECT 'sub_conflict'::text, v_agent.id;
        RETURN;
      END IF;
      UPDATE relay.agents a SET access_sub_bidx = p_sub_bidx, access_sub_ct = p_sub_ct,
          updated_at = now()
        WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = v_agent.id;
      RETURN QUERY SELECT 'bound'::text, v_agent.id;
    END
    $fn$
    """
  end

  defp agents_erase do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_private.agents_erase() RETURNS trigger
      LANGUAGE plpgsql
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
    AS $fn$
    BEGIN
      UPDATE relay.agents a SET access_sub_bidx = NULL
        WHERE a.tenant_id = NEW.tenant_id AND a.environment = NEW.environment AND a.id = NEW.id
          AND a.access_sub_bidx IS NOT NULL;
      UPDATE relay.agents a SET state = 'deleted', suspended_at = NULL, deleted_at = now(),
          version = a.version + 1, updated_at = now()
        WHERE a.tenant_id = NEW.tenant_id AND a.environment = NEW.environment AND a.id = NEW.id
          AND a.state <> 'deleted';
      RETURN NULL;
    END
    $fn$
    """
  end
end
