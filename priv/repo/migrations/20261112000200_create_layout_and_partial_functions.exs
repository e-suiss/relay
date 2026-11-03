defmodule Relay.Repo.Migrations.CreateLayoutAndPartialFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"
  @kinds ["layout", "partial"]

  # TP-35
  # TP-36
  # TP-31
  # TP-48
  # OP-8
  def up do
    for kind <- @kinds do
      Enum.each(statements(kind), &execute/1)

      for signature <- signatures(kind) do
        execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
        execute("GRANT EXECUTE ON FUNCTION #{signature} TO relay_app")
        execute("ALTER FUNCTION #{signature} OWNER TO relay_owner")
      end
    end
  end

  def down do
    for kind <- Enum.reverse(@kinds),
        signature <- Enum.reverse(signatures(kind)),
        do: execute("DROP FUNCTION #{signature}")
  end

  defp signatures(kind) do
    [
      "relay_fn.#{kind}_create(uuid, uuid, text, uuid, text, jsonb, bytea, #{@actor})",
      "relay_fn.#{kind}_draft_put(uuid, text, uuid, text, jsonb, bigint, bytea, #{@actor})",
      "relay_fn.#{kind}_publish(text, uuid, bytea, jsonb, boolean, jsonb, bigint, bytea, #{@actor})",
      "relay_fn.#{kind}_rollback(text, uuid, bigint, bigint, bytea, #{@actor})",
      "relay_fn.#{kind}_archive(text, uuid, bigint, bytea, #{@actor})"
    ]
  end

  defp in_use("layout") do
    """
    EXISTS (SELECT 1 FROM relay.templates t
          JOIN relay.template_versions v ON v.tenant_id = t.tenant_id
            AND v.environment = t.environment AND v.id = t.live_version_id
          WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.state = 'active'
            AND v.layout_key = v_asset.key
            AND (v_asset.subtenant_id IS NULL OR t.subtenant_id = v_asset.subtenant_id))
    """
  end

  defp in_use("partial") do
    """
    EXISTS (SELECT 1 FROM relay.templates t
          JOIN relay.template_versions v ON v.tenant_id = t.tenant_id
            AND v.environment = t.environment AND v.id = t.live_version_id
          WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.state = 'active'
            AND v_asset.key = ANY (v.partial_keys)
            AND (v_asset.subtenant_id IS NULL OR t.subtenant_id = v_asset.subtenant_id))
    """
  end

  defp statements(kind) do
    table = kind <> "s"
    versions = kind <> "_versions"
    row = "relay.#{table}"
    version_row = "relay.#{versions}"
    checksum = "sha256(convert_to(p_content::text, 'UTF8'))"

    lookup = """
    SELECT * INTO v_asset FROM #{row} a
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.key = p_key
            AND a.subtenant_id IS NOT DISTINCT FROM p_subtenant_id
          FOR UPDATE;
    """

    [
      """
      CREATE FUNCTION relay_fn.#{kind}_create(p_id uuid, p_version_id uuid, p_key text,
        p_subtenant_id uuid, p_name text, p_content jsonb, p_record_digest bytea,
        p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, #{kind}_id uuid, version_id uuid, version bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_existing #{row};
      BEGIN
        IF relay_private.tenant_status() <> 'active' THEN
          RETURN QUERY SELECT 'tenant_inactive'::text, NULL::uuid, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        IF p_key IS NULL OR p_key !~ '^[a-z0-9]+(-[a-z0-9]+)*$' OR char_length(p_key) > 100 OR p_name IS NULL
          OR char_length(p_name) NOT BETWEEN 1 AND 200 OR p_content IS NULL
          OR jsonb_typeof(p_content) <> 'object' THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TP-48';
        END IF;
        IF p_subtenant_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM relay.subtenants s
          WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = p_subtenant_id
            AND s.state = 'active') THEN
          RETURN QUERY SELECT 'subtenant_not_found'::text, NULL::uuid, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['#{kind}', COALESCE(p_subtenant_id::text, ''),
          p_key]);
        SELECT * INTO v_existing FROM #{row} a
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.key = p_key
            AND a.subtenant_id IS NOT DISTINCT FROM p_subtenant_id;
        IF FOUND THEN
          RETURN QUERY SELECT 'key_conflict'::text, v_existing.id, NULL::uuid, v_existing.version;
          RETURN;
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        PERFORM relay_private.assert_new_id(p_version_id);
        INSERT INTO #{row} (tenant_id, environment, id, key, subtenant_id, owner, name, state,
          archived_at, live_version_id, live_version_no, version, created_at, updated_at)
        VALUES (v_tenant, v_env, p_id, p_key, p_subtenant_id,
          CASE WHEN p_subtenant_id IS NULL THEN 'tenant' ELSE 'subtenant' END, p_name, 'active',
          NULL, NULL, NULL, 1, now(), now());
        INSERT INTO #{version_row} (tenant_id, environment, id, #{kind}_id, state, version_no,
          checksum, content, findings, warnings_accepted, warnings_accepted_by_ref, diff,
          previous_version_no, drafted_by_ref, published_at, published_by_ref, archived_at,
          created_at, updated_at)
        VALUES (v_tenant, v_env, p_version_id, p_id, 'draft', NULL, #{checksum}, p_content, NULL,
          false, NULL, NULL, NULL, p_actor_ref, NULL, NULL, NULL, now(), now());
        PERFORM relay_private.audit_write(v_tenant, v_env::text, '#{kind}.created', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, '#{kind}', p_id::text, NULL,
          p_record_digest);
        RETURN QUERY SELECT 'created'::text, p_id, p_version_id, 1::bigint;
      END
      $fn$
      """,
      """
      CREATE FUNCTION relay_fn.#{kind}_draft_put(p_version_id uuid, p_key text,
        p_subtenant_id uuid, p_name text, p_content jsonb, p_expected_version bigint,
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text)
        RETURNS TABLE (result text, version_id uuid, version bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_asset #{row};
        v_draft #{version_row};
        v_checksum bytea;
        v_result text;
        v_id uuid;
        v_version bigint;
      BEGIN
        IF p_name IS NULL OR char_length(p_name) NOT BETWEEN 1 AND 200 OR p_content IS NULL
          OR jsonb_typeof(p_content) <> 'object' THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TP-48';
        END IF;
        #{lookup}
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        IF v_asset.state = 'archived' THEN
          RETURN QUERY SELECT 'archived'::text, NULL::uuid, v_asset.version;
          RETURN;
        END IF;
        IF p_expected_version IS NOT NULL AND p_expected_version <> v_asset.version THEN
          RETURN QUERY SELECT 'version_conflict'::text, NULL::uuid, v_asset.version;
          RETURN;
        END IF;
        v_checksum := #{checksum};
        SELECT * INTO v_draft FROM #{version_row} v
          WHERE v.tenant_id = v_tenant AND v.environment = v_env AND v.#{kind}_id = v_asset.id
            AND v.state = 'draft'
          FOR UPDATE;
        IF FOUND AND v_draft.checksum = v_checksum AND v_asset.name = p_name THEN
          RETURN QUERY SELECT 'unchanged'::text, v_draft.id, v_asset.version;
          RETURN;
        END IF;
        IF FOUND THEN
          UPDATE #{version_row} v SET checksum = v_checksum, content = p_content,
              drafted_by_ref = p_actor_ref, updated_at = now()
            WHERE v.tenant_id = v_tenant AND v.environment = v_env AND v.id = v_draft.id;
          v_result := 'replaced';
          v_id := v_draft.id;
        ELSE
          PERFORM relay_private.assert_new_id(p_version_id);
          INSERT INTO #{version_row} (tenant_id, environment, id, #{kind}_id, state, version_no,
            checksum, content, findings, warnings_accepted, warnings_accepted_by_ref, diff,
            previous_version_no, drafted_by_ref, published_at, published_by_ref, archived_at,
            created_at, updated_at)
          VALUES (v_tenant, v_env, p_version_id, v_asset.id, 'draft', NULL, v_checksum, p_content,
            NULL, false, NULL, NULL, NULL, p_actor_ref, NULL, NULL, NULL, now(), now());
          v_result := 'created';
          v_id := p_version_id;
        END IF;
        UPDATE #{row} a SET name = p_name, version = a.version + 1, updated_at = now()
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = v_asset.id
          RETURNING a.version INTO v_version;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, '#{kind}.drafted', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, '#{kind}', v_asset.id::text, NULL,
          p_record_digest);
        RETURN QUERY SELECT v_result, v_id, v_version;
      END
      $fn$
      """,
      """
      CREATE FUNCTION relay_fn.#{kind}_publish(p_key text, p_subtenant_id uuid, p_checksum bytea,
        p_findings jsonb, p_accept_warnings boolean, p_diff jsonb, p_expected_version bigint,
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text)
        RETURNS TABLE (result text, version_id uuid, version_no bigint, version bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_asset #{row};
        v_draft #{version_row};
        v_duplicate bigint;
        v_accepted boolean;
        v_no bigint;
        v_version bigint;
      BEGIN
        IF p_findings IS NULL OR jsonb_typeof(p_findings) <> 'array'
          OR EXISTS (SELECT 1 FROM jsonb_array_elements(p_findings) f
            WHERE jsonb_typeof(f) <> 'object' OR f ->> 'level' IS NULL
              OR f ->> 'level' NOT IN ('hard', 'warning'))
          OR (p_diff IS NOT NULL AND jsonb_typeof(p_diff) <> 'object')
          OR p_accept_warnings IS NULL OR p_actor_ref IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TP-32';
        END IF;
        #{lookup}
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::bigint, NULL::bigint;
          RETURN;
        END IF;
        IF v_asset.state = 'archived' THEN
          RETURN QUERY SELECT 'archived'::text, NULL::uuid, NULL::bigint, v_asset.version;
          RETURN;
        END IF;
        IF p_expected_version IS NOT NULL AND p_expected_version <> v_asset.version THEN
          RETURN QUERY SELECT 'version_conflict'::text, NULL::uuid, NULL::bigint, v_asset.version;
          RETURN;
        END IF;
        SELECT * INTO v_draft FROM #{version_row} v
          WHERE v.tenant_id = v_tenant AND v.environment = v_env AND v.#{kind}_id = v_asset.id
            AND v.state = 'draft'
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'no_draft'::text, NULL::uuid, NULL::bigint, v_asset.version;
          RETURN;
        END IF;
        IF p_checksum IS NOT NULL AND p_checksum <> v_draft.checksum THEN
          RETURN QUERY SELECT 'draft_changed'::text, v_draft.id, NULL::bigint, v_asset.version;
          RETURN;
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_findings) f WHERE f ->> 'level' = 'hard')
        THEN
          RETURN QUERY SELECT 'gate_failed'::text, v_draft.id, NULL::bigint, v_asset.version;
          RETURN;
        END IF;
        IF jsonb_array_length(p_findings) > 0 AND NOT p_accept_warnings THEN
          RETURN QUERY SELECT 'warnings_unaccepted'::text, v_draft.id, NULL::bigint,
            v_asset.version;
          RETURN;
        END IF;
        v_accepted := jsonb_array_length(p_findings) > 0 AND p_accept_warnings;
        SELECT v.version_no INTO v_duplicate FROM #{version_row} v
          WHERE v.tenant_id = v_tenant AND v.environment = v_env AND v.#{kind}_id = v_asset.id
            AND v.version_no IS NOT NULL AND v.checksum = v_draft.checksum;
        IF FOUND THEN
          RETURN QUERY SELECT 'duplicate'::text, v_draft.id, v_duplicate, v_asset.version;
          RETURN;
        END IF;
        SELECT COALESCE(max(v.version_no), 0) + 1 INTO v_no FROM #{version_row} v
          WHERE v.tenant_id = v_tenant AND v.environment = v_env AND v.#{kind}_id = v_asset.id;
        UPDATE #{version_row} v SET state = 'published', version_no = v_no,
            findings = p_findings, warnings_accepted = v_accepted,
            warnings_accepted_by_ref = CASE WHEN v_accepted THEN p_actor_ref END,
            diff = p_diff, previous_version_no = v_asset.live_version_no, published_at = now(),
            published_by_ref = p_actor_ref, updated_at = now()
          WHERE v.tenant_id = v_tenant AND v.environment = v_env AND v.id = v_draft.id;
        UPDATE #{row} a SET live_version_id = v_draft.id, live_version_no = v_no,
            version = a.version + 1, updated_at = now()
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = v_asset.id
          RETURNING a.version INTO v_version;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, '#{kind}.published',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, '#{kind}',
          v_asset.id::text,
          format('version %s checksum %s previous %s', v_no, encode(v_draft.checksum, 'hex'),
            COALESCE(v_asset.live_version_no::text, 'none')),
          p_record_digest);
        RETURN QUERY SELECT 'published'::text, v_draft.id, v_no, v_version;
      END
      $fn$
      """,
      """
      CREATE FUNCTION relay_fn.#{kind}_rollback(p_key text, p_subtenant_id uuid,
        p_version_no bigint, p_expected_version bigint, p_record_digest bytea, p_actor_kind text,
        p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, version_id uuid, version bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_asset #{row};
        v_target #{version_row};
        v_version bigint;
      BEGIN
        IF p_version_no IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TP-31';
        END IF;
        #{lookup}
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        IF v_asset.state = 'archived' THEN
          RETURN QUERY SELECT 'archived'::text, NULL::uuid, v_asset.version;
          RETURN;
        END IF;
        IF p_expected_version IS NOT NULL AND p_expected_version <> v_asset.version THEN
          RETURN QUERY SELECT 'version_conflict'::text, NULL::uuid, v_asset.version;
          RETURN;
        END IF;
        SELECT * INTO v_target FROM #{version_row} v
          WHERE v.tenant_id = v_tenant AND v.environment = v_env AND v.#{kind}_id = v_asset.id
            AND v.version_no = p_version_no;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'version_not_found'::text, NULL::uuid, v_asset.version;
          RETURN;
        END IF;
        IF v_target.state = 'archived' THEN
          RETURN QUERY SELECT 'version_archived'::text, v_target.id, v_asset.version;
          RETURN;
        END IF;
        IF v_asset.live_version_id = v_target.id THEN
          RETURN QUERY SELECT 'unchanged'::text, v_target.id, v_asset.version;
          RETURN;
        END IF;
        UPDATE #{row} a SET live_version_id = v_target.id, live_version_no = p_version_no,
            version = a.version + 1, updated_at = now()
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = v_asset.id
          RETURNING a.version INTO v_version;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, '#{kind}.rolled_back',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, '#{kind}',
          v_asset.id::text,
          format('version %s checksum %s previous %s', p_version_no,
            encode(v_target.checksum, 'hex'), COALESCE(v_asset.live_version_no::text, 'none')),
          p_record_digest);
        RETURN QUERY SELECT 'rolled_back'::text, v_target.id, v_version;
      END
      $fn$
      """,
      """
      CREATE FUNCTION relay_fn.#{kind}_archive(p_key text, p_subtenant_id uuid,
        p_expected_version bigint, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
        p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, version bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_asset #{row};
        v_version bigint;
      BEGIN
        #{lookup}
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
          RETURN;
        END IF;
        IF v_asset.state = 'archived' THEN
          RETURN QUERY SELECT 'already_archived'::text, v_asset.version;
          RETURN;
        END IF;
        IF p_expected_version IS NOT NULL AND p_expected_version <> v_asset.version THEN
          RETURN QUERY SELECT 'version_conflict'::text, v_asset.version;
          RETURN;
        END IF;
        IF #{in_use(kind)} THEN
          RETURN QUERY SELECT 'in_use'::text, v_asset.version;
          RETURN;
        END IF;
        UPDATE #{version_row} v SET state = 'archived', archived_at = now(), updated_at = now()
          WHERE v.tenant_id = v_tenant AND v.environment = v_env AND v.#{kind}_id = v_asset.id
            AND v.state = 'draft';
        UPDATE #{row} a SET state = 'archived', archived_at = now(), version = a.version + 1,
            updated_at = now()
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = v_asset.id
          RETURNING a.version INTO v_version;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, '#{kind}.archived', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, '#{kind}', v_asset.id::text, NULL,
          p_record_digest);
        RETURN QUERY SELECT 'archived'::text, v_version;
      END
      $fn$
      """
    ]
  end
end
