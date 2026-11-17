defmodule Relay.Repo.Migrations.AddTransientRecipients do
  use Ecto.Migration

  @signature "relay_fn.recipient_transient_set(uuid)"

  # E-108
  # INV-22
  # OP-57
  def up do
    execute("""
    ALTER TABLE relay.recipients ADD COLUMN transient boolean NOT NULL DEFAULT false
    """)

    execute(~S"""
    ALTER TABLE relay.recipients ADD CONSTRAINT recipients_transient_check
      CHECK (NOT transient OR kind = 'subscriber') NOT VALID
    """)

    execute(transient_set())
    execute("REVOKE ALL ON FUNCTION #{@signature} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@signature} TO relay_app")
    execute("ALTER FUNCTION #{@signature} OWNER TO relay_owner")
  end

  def down, do: :ok

  defp transient_set do
    ~S"""
    CREATE FUNCTION relay_fn.recipient_transient_set(p_recipient_id uuid)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_recipient relay.recipients;
    BEGIN
      IF p_recipient_id IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'E-108';
      END IF;
      SELECT * INTO v_recipient FROM relay.recipients r
        WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_recipient_id
          AND r.kind = 'subscriber'
        FOR NO KEY UPDATE;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      IF v_recipient.transient THEN
        RETURN 'unchanged';
      END IF;
      UPDATE relay.recipients r SET transient = true
        WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_recipient_id;
      RETURN 'set';
    END
    $fn$
    """
  end
end
