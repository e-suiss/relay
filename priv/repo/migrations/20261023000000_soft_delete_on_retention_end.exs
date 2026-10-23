defmodule Relay.Repo.Migrations.SoftDeleteOnRetentionEnd do
  use Ecto.Migration

  # OP-16
  # OP-69 (4)
  def up do
    execute("SET LOCAL ROLE relay_owner")
    execute(function(true))
    execute("RESET ROLE")
  end

  def down do
    execute("SET LOCAL ROLE relay_owner")
    execute(function(false))
    execute("RESET ROLE")
  end

  defp function(soft_delete?) do
    """
    CREATE OR REPLACE FUNCTION relay_fn.subject_key_retire(p_subject_key_id uuid,
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
    #{if soft_delete?, do: soft_delete(), else: ""}
      PERFORM relay_private.audit_write(v_tenant, v_env, 'subject_key.retired', p_actor_kind,
        p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'subject_key',
        p_subject_key_id::text, v_key.retention_class, p_record_digest);
      RETURN 'retired';
    END
    $fn$
    """
  end

  defp soft_delete do
    """
      IF v_key.retention_class = 'recipient_profile' THEN
        UPDATE relay.recipients r SET state = 'deleted', deleted_at = now(),
            deleted_reason = 'retention_end', external_id_bidx = NULL,
            external_id_bidx_key_id = NULL, external_id_bidx_next = NULL, updated_at = now()
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = v_key.recipient_id
            AND r.state <> 'deleted';
      END IF;
    """
  end
end
