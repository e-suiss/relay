defmodule Relay.Repo.Migrations.CreateAuditFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"

  @functions [
    {"relay_private.merkle_root(bytea[])", "relay_migrator", ~w(relay_owner relay_maint)},
    {"relay_private.singleton_leader(text, bigint)", "relay_migrator", ~w(relay_maint)},
    {"relay_fn.audit_append(uuid, text, #{@actor}, text, text, text, bytea, uuid, bytea)",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.audit_query(timestamp with time zone, timestamp with time zone, text, uuid, integer, bytea, #{@actor})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.audit_inclusion_proof(uuid)", "relay_owner", ~w(relay_app relay_report)},
    {"relay_ops.audit_pending(xid8, integer)", "relay_maint", ~w(relay_worker)},
    {"relay_ops.audit_leaves_append(text, bigint, uuid[], bytea[], bigint)", "relay_maint",
     ~w(relay_worker)},
    {"relay_ops.audit_checkpoint_record(uuid, text, bigint, bytea, text, text, boolean, bigint)",
     "relay_maint", ~w(relay_worker)},
    {"relay_ops.audit_checkpoint_publication_record(uuid, text, text, text)", "relay_maint",
     ~w(relay_worker)}
  ]

  # TN-46
  # TN-50
  # OP-63
  # OP-67
  def up do
    Enum.each(statements(), &execute/1)

    for {signature, owner, grantees} <- @functions do
      execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
    end
  end

  def down do
    for {signature, _owner, _grantees} <- Enum.reverse(@functions),
        do: execute("DROP FUNCTION #{signature}")
  end

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_private.merkle_root(p_hashes bytea[]) RETURNS bytea
      LANGUAGE plpgsql IMMUTABLE
      SET search_path = pg_catalog, pg_temp
      AS $fn$
      DECLARE
        v_level bytea[] := p_hashes;
        v_next bytea[];
        v_n integer;
        i integer;
      BEGIN
        v_n := COALESCE(cardinality(v_level), 0);
        IF v_n = 0 THEN
          RETURN sha256(''::bytea);
        END IF;
        WHILE v_n > 1 LOOP
          v_next := ARRAY[]::bytea[];
          i := 1;
          WHILE i <= v_n LOOP
            IF i < v_n THEN
              v_next := array_append(v_next, sha256('\x01'::bytea || v_level[i] || v_level[i + 1]));
            ELSE
              v_next := array_append(v_next, v_level[i]);
            END IF;
            i := i + 2;
          END LOOP;
          v_level := v_next;
          v_n := cardinality(v_level);
        END LOOP;
        RETURN v_level[1];
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.singleton_leader(p_name text, p_fencing_token bigint)
        RETURNS boolean
      LANGUAGE plpgsql VOLATILE
      SET search_path = pg_catalog, pg_temp
      AS $fn$
      BEGIN
        PERFORM 1 FROM relay.singleton_tasks t
          WHERE t.name = p_name AND t.fencing_token = p_fencing_token AND t.lease_until > now()
          FOR SHARE;
        RETURN FOUND;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.audit_append(p_id uuid, p_action text, p_actor_kind text,
        p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text, p_target_type text,
        p_target_id text, p_reason text, p_details_ct bytea, p_details_key_id uuid,
        p_record_digest bytea) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      BEGIN
        PERFORM relay_private.assert_new_id(p_id);
        IF p_action IS NULL OR p_actor_kind IS NULL OR p_actor_ref IS NULL
          OR p_on_behalf_of_ref IS NULL OR p_record_digest IS NULL
          OR (p_details_ct IS NULL) <> (p_details_key_id IS NULL) THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-48';
        END IF;
        INSERT INTO relay.audit_log (tenant_id, environment, id, created_at, action, actor_kind,
          actor_ref, on_behalf_of_ref, access_record_ref, target_type, target_id, reason, details_ct,
          details_key_id, record_digest)
        VALUES (relay_private.ctx_tenant_id(), relay_private.ctx_environment(), p_id, now(), p_action,
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, p_target_type,
          p_target_id, p_reason, p_details_ct, p_details_key_id, p_record_digest);
        RETURN 'appended';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.audit_query(p_from timestamptz, p_to timestamptz, p_action text,
        p_after_id uuid, p_limit integer, p_record_digest bytea, p_actor_kind text,
        p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS SETOF relay.audit_log
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_read uuid;
        v_after_at timestamptz;
      BEGIN
        IF p_from IS NULL OR p_to IS NULL OR p_from > p_to
          OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 1000 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-50';
        END IF;
        IF p_after_id IS NOT NULL THEN
          SELECT a.created_at INTO v_after_at FROM relay.audit_log a
            WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = p_after_id;
          IF NOT FOUND THEN
            RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-50';
          END IF;
        END IF;
        v_read := relay_private.audit_write(v_tenant, v_env, 'audit_log.read', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'audit_log', NULL, NULL,
          p_record_digest);
        RETURN QUERY
          SELECT a.* FROM relay.audit_log a
          WHERE a.tenant_id = v_tenant AND a.environment = v_env
            AND a.created_at >= p_from AND a.created_at < p_to
            AND (p_action IS NULL OR a.action = p_action)
            AND (p_after_id IS NULL OR (a.created_at, a.id) > (v_after_at, p_after_id))
            AND a.id <> v_read
          ORDER BY a.created_at, a.id
          LIMIT p_limit;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.audit_inclusion_proof(p_audit_id uuid)
        RETURNS TABLE (log_origin text, leaf_index bigint, tree_size bigint, proof bytea[])
      LANGUAGE plpgsql STABLE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_origin text;
        v_index bigint;
        v_size bigint;
        v_leaves bytea[];
        v_proof bytea[] := ARRAY[]::bytea[];
        v_lo bigint := 0;
        v_hi bigint;
        v_k bigint;
      BEGIN
        IF NOT EXISTS (SELECT 1 FROM relay.audit_log a
          WHERE a.tenant_id = relay_private.ctx_tenant_id()
            AND a.environment = relay_private.ctx_environment()
            AND a.id = p_audit_id) THEN
          RETURN;
        END IF;
        SELECT l.log_origin, l.leaf_index INTO v_origin, v_index
          FROM relay.audit_leaves l WHERE l.audit_id = p_audit_id;
        IF NOT FOUND THEN
          RETURN;
        END IF;
        SELECT max(c.tree_size) INTO v_size FROM relay.audit_checkpoints c
          WHERE c.log_origin = v_origin AND c.tree_size > v_index;
        IF v_size IS NULL THEN
          RETURN;
        END IF;
        SELECT array_agg(l.leaf_hash::bytea ORDER BY l.leaf_index) INTO v_leaves
          FROM relay.audit_leaves l
          WHERE l.log_origin = v_origin AND l.leaf_index < v_size;
        IF cardinality(v_leaves) <> v_size THEN
          RAISE EXCEPTION 'invariant_violation' USING HINT = 'OP-63';
        END IF;
        v_hi := v_size;
        WHILE v_hi - v_lo > 1 LOOP
          v_k := 1;
          WHILE v_k * 2 < v_hi - v_lo LOOP
            v_k := v_k * 2;
          END LOOP;
          IF v_index < v_lo + v_k THEN
            v_proof := array_prepend(
              relay_private.merkle_root(v_leaves[(v_lo + v_k + 1)::integer : v_hi::integer]), v_proof);
            v_hi := v_lo + v_k;
          ELSE
            v_proof := array_prepend(
              relay_private.merkle_root(v_leaves[(v_lo + 1)::integer : (v_lo + v_k)::integer]), v_proof);
            v_lo := v_lo + v_k;
          END IF;
        END LOOP;
        RETURN QUERY SELECT v_origin, v_index, v_size, v_proof;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.audit_pending(p_prev_xmin xid8, p_limit integer)
        RETURNS TABLE (tenant_id uuid, environment text, audit_id uuid, created_at timestamptz,
          txid xid8, record_digest bytea, upper_xmin xid8)
      LANGUAGE plpgsql STABLE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_upper xid8 := pg_snapshot_xmin(pg_current_snapshot());
      BEGIN
        IF p_prev_xmin IS NULL OR p_limit IS NULL OR p_limit < 1 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-63';
        END IF;
        RETURN QUERY
          SELECT a.tenant_id, a.environment::text, a.id, a.created_at, a.txid,
            a.record_digest::bytea, v_upper
          FROM relay.audit_log a
          WHERE a.txid >= p_prev_xmin AND a.txid < v_upper
            AND NOT EXISTS (SELECT 1 FROM relay.audit_leaves l WHERE l.audit_id = a.id)
          ORDER BY a.txid, a.created_at, a.id
          LIMIT p_limit;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.audit_leaves_append(p_log_origin text, p_first_index bigint,
        p_audit_ids uuid[], p_leaf_hashes bytea[], p_fencing_token bigint) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_next bigint;
        v_count integer := COALESCE(cardinality(p_audit_ids), 0);
        v_inserted integer;
      BEGIN
        IF p_log_origin IS NULL OR p_first_index IS NULL OR v_count = 0
          OR v_count <> COALESCE(cardinality(p_leaf_hashes), 0) THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-63';
        END IF;
        IF NOT relay_private.singleton_leader('audit_checkpoint', p_fencing_token) THEN
          RETURN 'not_leader';
        END IF;
        PERFORM pg_advisory_xact_lock(hashtextextended('audit_leaves|' || p_log_origin, 0));
        SELECT COALESCE(max(l.leaf_index) + 1, 0) INTO v_next
          FROM relay.audit_leaves l WHERE l.log_origin = p_log_origin;
        IF p_first_index <> v_next THEN
          RETURN 'index_gap';
        END IF;
        INSERT INTO relay.audit_leaves (log_origin, leaf_index, audit_tenant_id, audit_environment,
          audit_id, audit_created_at, leaf_hash, integrated_at)
        SELECT p_log_origin, p_first_index + x.ord - 1, a.tenant_id, a.environment, a.id,
          a.created_at, x.leaf_hash, now()
        FROM unnest(p_audit_ids, p_leaf_hashes) WITH ORDINALITY AS x(audit_id, leaf_hash, ord)
        JOIN relay.audit_log a ON a.id = x.audit_id
        ORDER BY x.ord;
        GET DIAGNOSTICS v_inserted = ROW_COUNT;
        IF v_inserted <> v_count THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-63';
        END IF;
        RETURN 'appended';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.audit_checkpoint_record(p_id uuid, p_log_origin text,
        p_tree_size bigint, p_root_hash bytea, p_signed_note text, p_key_ref text,
        p_is_heartbeat boolean, p_fencing_token bigint) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_max bigint;
        v_leaves bigint;
      BEGIN
        IF p_log_origin IS NULL OR p_tree_size IS NULL OR p_tree_size < 0 OR p_root_hash IS NULL
          OR p_signed_note IS NULL OR p_key_ref IS NULL OR p_is_heartbeat IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-63';
        END IF;
        IF NOT relay_private.singleton_leader('audit_checkpoint', p_fencing_token) THEN
          RETURN 'not_leader';
        END IF;
        IF EXISTS (SELECT 1 FROM relay.audit_checkpoints c WHERE c.id = p_id) THEN
          RETURN 'duplicate';
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        PERFORM pg_advisory_xact_lock(hashtextextended('audit_checkpoints|' || p_log_origin, 0));
        SELECT max(c.tree_size) INTO v_max FROM relay.audit_checkpoints c
          WHERE c.log_origin = p_log_origin;
        IF v_max IS NOT NULL AND p_tree_size < v_max THEN
          RETURN 'stale';
        END IF;
        IF NOT p_is_heartbeat AND EXISTS (SELECT 1 FROM relay.audit_checkpoints c
          WHERE c.log_origin = p_log_origin AND c.tree_size = p_tree_size AND NOT c.is_heartbeat) THEN
          RETURN 'duplicate';
        END IF;
        SELECT count(*) INTO v_leaves FROM relay.audit_leaves l WHERE l.log_origin = p_log_origin;
        IF p_tree_size > v_leaves THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-63';
        END IF;
        INSERT INTO relay.audit_checkpoints (id, log_origin, tree_size, root_hash, signed_note,
          key_ref, is_heartbeat, created_at)
        VALUES (p_id, p_log_origin, p_tree_size, p_root_hash, p_signed_note, p_key_ref,
          p_is_heartbeat, now());
        RETURN 'recorded';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.audit_checkpoint_publication_record(p_checkpoint_id uuid,
        p_target text, p_status text, p_detail text) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      BEGIN
        IF p_checkpoint_id IS NULL OR p_target IS NULL
          OR p_status IS NULL OR p_status NOT IN ('published', 'failed') THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-63';
        END IF;
        INSERT INTO relay.audit_checkpoint_publications (checkpoint_id, target, status, detail,
          created_at)
        VALUES (p_checkpoint_id, p_target, p_status, p_detail, clock_timestamp());
        RETURN 'recorded';
      END
      $fn$
      """
    ]
  end
end
