defmodule Relay.Repo.Migrations.AddSmsSenderRegistration do
  use Ecto.Migration

  @actor "text, text, text, text"

  @functions [
    {"relay_fn.sender_identity_register(uuid, text, jsonb, bytea, #{@actor})", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.provider_account_set_traffic(uuid, text, bytea, #{@actor})", "relay_owner",
     ~w(relay_app)}
  ]

  # CH-50
  # CH-53
  # C-25
  def up do
    execute(~S"""
    ALTER TABLE relay.sender_identities
      ADD COLUMN sms_type text
        CONSTRAINT sender_identities_sms_type_check
          CHECK (sms_type IN ('alphanumeric', 'short_code', 'long_number', 'toll_free',
            'ten_dlc')),
      ADD COLUMN registration jsonb NOT NULL DEFAULT '{}'
        CONSTRAINT sender_identities_registration_check
          CHECK (jsonb_typeof(registration) = 'object' AND pg_column_size(registration) <= 4096)
    """)

    execute(~S"""
    ALTER TABLE relay.provider_accounts
      ADD COLUMN traffic text NOT NULL DEFAULT 'standard'
        CONSTRAINT provider_accounts_traffic_check CHECK (traffic IN ('standard', 'security'))
    """)

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
      CREATE FUNCTION relay_fn.sender_identity_register(p_id uuid, p_sms_type text,
        p_registration jsonb, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
        p_on_behalf_of_ref text, p_access_record_ref text) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.sender_identities;
      BEGIN
        IF p_sms_type IS NULL OR p_registration IS NULL OR p_actor_ref IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'CH-50';
        END IF;
        SELECT * INTO v_row FROM relay.sender_identities i
          WHERE i.tenant_id = v_tenant AND i.environment = v_env AND i.id = p_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_row.channel::text <> 'sms' THEN
          RETURN 'not_sms';
        END IF;
        IF v_row.sms_type IS NOT DISTINCT FROM p_sms_type
          AND v_row.registration = p_registration THEN
          RETURN 'unchanged';
        END IF;
        UPDATE relay.sender_identities i SET sms_type = p_sms_type,
            registration = p_registration, version = i.version + 1, updated_at = now()
          WHERE i.tenant_id = v_tenant AND i.environment = v_env AND i.id = p_id;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'sender_identity.changed',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref,
          'sender_identity', p_id::text, 'updated', p_record_digest);
        RETURN 'updated';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.provider_account_set_traffic(p_id uuid, p_traffic text,
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_traffic text;
      BEGIN
        IF p_traffic IS NULL OR p_traffic NOT IN ('standard', 'security') OR p_actor_ref IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'CH-53';
        END IF;
        SELECT a.traffic INTO v_traffic FROM relay.provider_accounts a
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = p_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_traffic = p_traffic THEN
          RETURN 'unchanged';
        END IF;
        UPDATE relay.provider_accounts a SET traffic = p_traffic, version = a.version + 1,
            updated_at = now()
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = p_id;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'provider_account.changed',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref,
          'provider_account', p_id::text, 'updated', p_record_digest);
        RETURN 'updated';
      END
      $fn$
      """
    ]
  end
end
