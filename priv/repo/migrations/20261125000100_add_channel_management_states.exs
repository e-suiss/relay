defmodule Relay.Repo.Migrations.AddChannelManagementStates do
  use Ecto.Migration

  @actor "text, text, text, text"

  @functions [
    {"relay_fn.provider_account_archive(uuid, bytea, #{@actor})", "relay_owner", ~w(relay_app)},
    {"relay_fn.sender_identity_archive(uuid, bytea, #{@actor})", "relay_owner", ~w(relay_app)},
    {"relay_fn.channel_identity_retire(uuid, bytea, #{@actor})", "relay_owner", ~w(relay_app)}
  ]

  # C-25
  # C-26
  # C-45
  # TN-21
  # TN-26
  # OP-73
  def up do
    execute("ALTER TABLE relay.provider_accounts DROP CONSTRAINT provider_accounts_state_check")

    execute("""
    ALTER TABLE relay.provider_accounts ADD CONSTRAINT provider_accounts_state_check
      CHECK (state IN ('active', 'disabled', 'archived'))
    """)

    execute("ALTER TABLE relay.sender_identities ADD COLUMN archived_at timestamptz")

    Enum.each(statements(), &execute/1)

    for {signature, owner, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      if owner == "relay_owner", do: execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
    end
  end

  def down do
    for {signature, _owner, _grantees} <- Enum.reverse(@functions),
        do: execute("DROP FUNCTION #{signature}")

    execute("ALTER TABLE relay.sender_identities DROP COLUMN archived_at")
    execute("ALTER TABLE relay.provider_accounts DROP CONSTRAINT provider_accounts_state_check")

    execute("""
    ALTER TABLE relay.provider_accounts ADD CONSTRAINT provider_accounts_state_check
      CHECK (state IN ('active', 'disabled'))
    """)
  end

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_fn.provider_account_archive(p_id uuid, p_record_digest bytea,
        p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, version bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.provider_accounts;
      BEGIN
        IF p_actor_ref IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'C-45';
        END IF;
        SELECT * INTO v_row FROM relay.provider_accounts a
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = p_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
          RETURN;
        END IF;
        IF v_row.state = 'archived' THEN
          RETURN QUERY SELECT 'already_archived'::text, v_row.version;
          RETURN;
        END IF;
        UPDATE relay.provider_accounts a SET state = 'archived', version = a.version + 1,
            updated_at = now()
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = p_id;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'provider_account.archived',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref,
          'provider_account', p_id::text, NULL, p_record_digest);
        RETURN QUERY SELECT 'archived'::text, v_row.version + 1;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.sender_identity_archive(p_id uuid, p_record_digest bytea,
        p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, version bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.sender_identities;
      BEGIN
        IF p_actor_ref IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'C-25';
        END IF;
        SELECT * INTO v_row FROM relay.sender_identities i
          WHERE i.tenant_id = v_tenant AND i.environment = v_env AND i.id = p_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
          RETURN;
        END IF;
        IF v_row.archived_at IS NOT NULL THEN
          RETURN QUERY SELECT 'already_archived'::text, v_row.version;
          RETURN;
        END IF;
        UPDATE relay.sender_identities i SET archived_at = now(), version = i.version + 1,
            updated_at = now()
          WHERE i.tenant_id = v_tenant AND i.environment = v_env AND i.id = p_id;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'sender_identity.archived',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref,
          'sender_identity', p_id::text, NULL, p_record_digest);
        RETURN QUERY SELECT 'archived'::text, v_row.version + 1;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.channel_identity_retire(p_id uuid, p_record_digest bytea,
        p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, version bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.channel_identities;
      BEGIN
        IF p_actor_ref IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'C-26';
        END IF;
        SELECT * INTO v_row FROM relay.channel_identities c
          WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
          RETURN;
        END IF;
        IF v_row.state = 'retired' THEN
          RETURN QUERY SELECT 'already_retired'::text, v_row.version;
          RETURN;
        END IF;
        UPDATE relay.channel_identities c SET state = 'retired', version = c.version + 1,
            updated_at = now()
          WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_id;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'channel_identity.retired',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref,
          'channel_identity', p_id::text, NULL, p_record_digest);
        RETURN QUERY SELECT 'retired'::text, v_row.version + 1;
      END
      $fn$
      """
    ]
  end
end
