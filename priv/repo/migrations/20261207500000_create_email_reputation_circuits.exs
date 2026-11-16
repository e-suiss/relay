defmodule Relay.Repo.Migrations.CreateEmailReputationCircuits do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"
  @actor "text, text, text, text"
  @functions [
    "relay_fn.email_reputation_transition(text, text, jsonb)",
    "relay_fn.email_reputation_close(text, text, bytea, #{@actor})"
  ]

  # CH-41
  # CH-87
  # TN-12
  # TN-13
  def up do
    execute(~S"""
    CREATE TABLE relay.email_reputation_circuits (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      domain text NOT NULL
        CONSTRAINT email_reputation_circuits_domain_check
          CHECK (char_length(domain) BETWEEN 1 AND 253 AND domain = lower(domain)),
      state text NOT NULL
        CONSTRAINT email_reputation_circuits_state_check
          CHECK (state IN ('ok', 'warning', 'stopped')),
      rates jsonb
        CONSTRAINT email_reputation_circuits_rates_check
          CHECK (rates IS NULL OR (jsonb_typeof(rates) = 'object'
            AND pg_column_size(rates) <= 2048)),
      warned_at timestamptz,
      stopped_at timestamptz,
      closed_at timestamptz,
      version bigint NOT NULL CONSTRAINT email_reputation_circuits_version_check CHECK (version >= 1),
      created_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      CONSTRAINT email_reputation_circuits_pkey PRIMARY KEY (tenant_id, environment, domain),
      CONSTRAINT email_reputation_circuits_stopped_check
        CHECK (state <> 'stopped' OR stopped_at IS NOT NULL)
    )
    """)

    execute("""
    CREATE TRIGGER email_reputation_circuits_no_delete BEFORE DELETE ON relay.email_reputation_circuits
      FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    execute("ALTER TABLE relay.email_reputation_circuits ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE relay.email_reputation_circuits FORCE ROW LEVEL SECURITY")

    execute(
      "CREATE POLICY email_reputation_circuits_scope ON relay.email_reputation_circuits USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})"
    )

    execute("GRANT SELECT, INSERT, UPDATE ON relay.email_reputation_circuits TO relay_owner")

    execute(
      "GRANT SELECT ON relay.email_reputation_circuits TO relay_app, relay_maint, relay_archive, relay_report"
    )

    Enum.each(statements(), &execute/1)

    for signature <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      execute("GRANT EXECUTE ON FUNCTION #{signature} TO relay_app")
      execute("ALTER FUNCTION #{signature} OWNER TO relay_owner")
    end
  end

  def down, do: :ok

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_fn.email_reputation_transition(p_domain text, p_state text,
        p_rates jsonb)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.email_reputation_circuits;
      BEGIN
        IF p_domain IS NULL OR p_state IS NULL OR p_state NOT IN ('ok', 'warning', 'stopped') THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'CH-87';
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['email_reputation', p_domain]);
        SELECT * INTO v_row FROM relay.email_reputation_circuits c
          WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.domain = p_domain
          FOR UPDATE;
        IF NOT FOUND THEN
          IF p_state = 'ok' THEN
            RETURN 'unchanged';
          END IF;
          INSERT INTO relay.email_reputation_circuits (tenant_id, environment, domain, state,
            rates, warned_at, stopped_at, closed_at, version, created_at, updated_at)
          VALUES (v_tenant, v_env, p_domain, p_state, p_rates,
            CASE WHEN p_state = 'warning' THEN now() END,
            CASE WHEN p_state = 'stopped' THEN now() END, NULL, 1, now(), now());
        ELSIF v_row.state = p_state OR v_row.state = 'stopped' THEN
          RETURN 'unchanged';
        ELSE
          UPDATE relay.email_reputation_circuits c SET state = p_state, rates = p_rates,
              warned_at = CASE WHEN p_state = 'warning' THEN now() ELSE c.warned_at END,
              stopped_at = CASE WHEN p_state = 'stopped' THEN now() ELSE c.stopped_at END,
              version = c.version + 1, updated_at = now()
            WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.domain = p_domain;
        END IF;
        IF p_state IN ('warning', 'stopped') THEN
          PERFORM relay_fn.outbox_append(uuidv7(), 'email_reputation.' || p_state,
            'email_reputation:' || p_domain,
            jsonb_build_object('domain', p_domain, 'rates', p_rates), NULL);
        END IF;
        RETURN 'changed';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.email_reputation_close(p_domain text, p_reason text,
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
        v_row relay.email_reputation_circuits;
      BEGIN
        IF p_domain IS NULL OR p_reason IS NULL OR p_record_digest IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'CH-87';
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['email_reputation', p_domain]);
        SELECT * INTO v_row FROM relay.email_reputation_circuits c
          WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.domain = p_domain
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_row.state <> 'stopped' THEN
          RETURN 'not_stopped';
        END IF;
        UPDATE relay.email_reputation_circuits c SET state = 'ok', closed_at = now(),
            version = c.version + 1, updated_at = now()
          WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.domain = p_domain;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'email_reputation.closed',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref,
          'email_reputation', p_domain, p_reason, p_record_digest);
        PERFORM relay_fn.outbox_append(uuidv7(), 'email_reputation.resumed',
          'email_reputation:' || p_domain, jsonb_build_object('domain', p_domain), NULL);
        RETURN 'closed';
      END
      $fn$
      """
    ]
  end
end
