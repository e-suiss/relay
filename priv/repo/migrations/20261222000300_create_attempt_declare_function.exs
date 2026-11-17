defmodule Relay.Repo.Migrations.CreateAttemptDeclareFunction do
  use Ecto.Migration

  @functions [
    {"relay_fn.attempt_declare(uuid, bigint, boolean, text)", "relay_owner", ~w(relay_app)}
  ]

  # PC-4
  # OP-8
  def up do
    Enum.each(statements(), &execute/1)

    for {signature, owner, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
    end
  end

  def down, do: :ok

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_fn.attempt_declare(p_delivery_id uuid, p_attempt_no bigint,
        p_commercial boolean, p_iys_recipient_type text)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_attempt relay.delivery_attempts;
      BEGIN
        IF p_delivery_id IS NULL OR p_attempt_no IS NULL OR p_commercial IS NULL
          OR p_iys_recipient_type NOT IN ('BIREYSEL', 'TACIR')
          OR (p_iys_recipient_type IS NOT NULL AND NOT p_commercial) THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'PC-4';
        END IF;
        SELECT * INTO v_attempt FROM relay.delivery_attempts a
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.delivery_id = p_delivery_id
            AND a.attempt_no = p_attempt_no
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        UPDATE relay.delivery_attempts a
          SET commercial = p_commercial, iys_recipient_type = p_iys_recipient_type,
            updated_at = now()
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = v_attempt.id
            AND a.created_at = v_attempt.created_at;
        RETURN 'declared';
      END
      $fn$
      """
    ]
  end
end
