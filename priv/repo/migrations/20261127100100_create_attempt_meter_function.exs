defmodule Relay.Repo.Migrations.CreateAttemptMeterFunction do
  use Ecto.Migration

  @functions [
    {"relay_fn.attempt_meter(uuid, bigint, text, bigint)", "relay_owner", ~w(relay_app)}
  ]

  # OP-38
  def up do
    Enum.each(statements(), &execute/1)

    for {signature, owner, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
    end
  end

  def down do
    for {signature, _owner, _grantees} <- Enum.reverse(@functions),
        do: execute("DROP FUNCTION #{signature}")
  end

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_fn.attempt_meter(p_delivery_id uuid, p_attempt_no bigint,
        p_destination_country text, p_sms_segments bigint)
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
        IF p_delivery_id IS NULL OR p_attempt_no IS NULL
          OR p_destination_country !~ '^[A-Z]{2}$' OR p_sms_segments < 1 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-38';
        END IF;
        SELECT * INTO v_attempt FROM relay.delivery_attempts a
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.delivery_id = p_delivery_id
            AND a.attempt_no = p_attempt_no
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        UPDATE relay.delivery_attempts a
          SET destination_country = p_destination_country, sms_segments = p_sms_segments,
            updated_at = now()
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = v_attempt.id
            AND a.created_at = v_attempt.created_at;
        RETURN 'metered';
      END
      $fn$
      """
    ]
  end
end
