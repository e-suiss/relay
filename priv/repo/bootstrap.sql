DO $$
DECLARE
  r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['relay_migrator', 'relay_owner', 'relay_app', 'relay_api', 'relay_worker',
                           'relay_queue', 'relay_maint', 'relay_archive', 'relay_report']
  LOOP
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = r) THEN
      EXECUTE format('CREATE ROLE %I', r);
    END IF;
  END LOOP;
END
$$;

ALTER ROLE relay_migrator LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEROLE NOCREATEDB NOREPLICATION INHERIT;
ALTER ROLE relay_owner NOLOGIN NOSUPERUSER NOBYPASSRLS NOCREATEROLE NOCREATEDB NOREPLICATION INHERIT;
ALTER ROLE relay_app NOLOGIN NOSUPERUSER NOBYPASSRLS NOCREATEROLE NOCREATEDB NOREPLICATION INHERIT;
ALTER ROLE relay_api LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEROLE NOCREATEDB NOREPLICATION INHERIT;
ALTER ROLE relay_worker LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEROLE NOCREATEDB NOREPLICATION INHERIT;
ALTER ROLE relay_queue LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEROLE NOCREATEDB NOREPLICATION INHERIT;
ALTER ROLE relay_maint LOGIN NOSUPERUSER BYPASSRLS NOCREATEROLE NOCREATEDB NOREPLICATION INHERIT;
ALTER ROLE relay_archive LOGIN NOSUPERUSER BYPASSRLS NOCREATEROLE NOCREATEDB NOREPLICATION INHERIT;
ALTER ROLE relay_report LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEROLE NOCREATEDB NOREPLICATION INHERIT;

GRANT relay_app TO relay_api WITH INHERIT TRUE;
GRANT relay_app TO relay_worker WITH INHERIT TRUE;
GRANT relay_migrator TO relay_maint WITH INHERIT FALSE, SET TRUE;
GRANT relay_migrator TO relay_archive WITH INHERIT FALSE, SET TRUE;
GRANT relay_owner TO relay_migrator WITH INHERIT FALSE, SET TRUE;

ALTER ROLE relay_api SET statement_timeout = '5s';
ALTER ROLE relay_api SET lock_timeout = '2s';
ALTER ROLE relay_api SET idle_in_transaction_session_timeout = '10s';
ALTER ROLE relay_api SET transaction_timeout = '10s';
ALTER ROLE relay_api SET search_path = relay, pg_catalog;

ALTER ROLE relay_worker SET statement_timeout = '30s';
ALTER ROLE relay_worker SET lock_timeout = '2s';
ALTER ROLE relay_worker SET idle_in_transaction_session_timeout = '10s';
ALTER ROLE relay_worker SET transaction_timeout = '60s';
ALTER ROLE relay_worker SET search_path = relay, pg_catalog;

ALTER ROLE relay_report SET statement_timeout = '5min';
ALTER ROLE relay_report SET lock_timeout = '2s';
ALTER ROLE relay_report SET idle_in_transaction_session_timeout = '60s';
ALTER ROLE relay_report SET transaction_timeout = '10min';
ALTER ROLE relay_report SET search_path = relay, pg_catalog;

ALTER ROLE relay_queue SET statement_timeout = '60s';
ALTER ROLE relay_queue SET lock_timeout = '2s';
ALTER ROLE relay_queue SET idle_in_transaction_session_timeout = '10s';
ALTER ROLE relay_queue SET transaction_timeout = '120s';
ALTER ROLE relay_queue SET search_path = relay_queue, pg_catalog;

ALTER ROLE relay_maint SET statement_timeout = '60s';
ALTER ROLE relay_maint SET lock_timeout = '2s';
ALTER ROLE relay_maint SET idle_in_transaction_session_timeout = '60s';
ALTER ROLE relay_maint SET transaction_timeout = '15min';
ALTER ROLE relay_maint SET search_path = relay, pg_catalog;

ALTER ROLE relay_archive SET statement_timeout = '15min';
ALTER ROLE relay_archive SET lock_timeout = '2s';
ALTER ROLE relay_archive SET idle_in_transaction_session_timeout = '60s';
ALTER ROLE relay_archive SET transaction_timeout = '60min';
ALTER ROLE relay_archive SET search_path = relay, pg_catalog;

ALTER ROLE relay_migrator SET statement_timeout = '0';
ALTER ROLE relay_migrator SET lock_timeout = '3s';
ALTER ROLE relay_migrator SET idle_in_transaction_session_timeout = '60s';
ALTER ROLE relay_migrator SET transaction_timeout = '0';
ALTER ROLE relay_migrator SET search_path = relay, pg_catalog;

REVOKE ALL ON SCHEMA public FROM PUBLIC;

DO $$
BEGIN
  EXECUTE format('GRANT CREATE ON DATABASE %I TO relay_migrator', current_database());
END
$$;

CREATE SCHEMA IF NOT EXISTS relay AUTHORIZATION relay_migrator;
CREATE SCHEMA IF NOT EXISTS relay_private AUTHORIZATION relay_migrator;
CREATE SCHEMA IF NOT EXISTS relay_fn AUTHORIZATION relay_owner;
CREATE SCHEMA IF NOT EXISTS relay_ops AUTHORIZATION relay_migrator;
ALTER SCHEMA relay_ops OWNER TO relay_migrator;

REVOKE ALL ON SCHEMA relay, relay_private, relay_fn, relay_ops FROM PUBLIC;

GRANT USAGE ON SCHEMA relay TO relay_owner, relay_app, relay_maint, relay_archive, relay_report;
GRANT USAGE ON SCHEMA relay_private TO relay_owner, relay_app, relay_maint, relay_archive, relay_report;
GRANT USAGE ON SCHEMA relay_fn TO relay_app, relay_report;
GRANT USAGE, CREATE ON SCHEMA relay_fn TO relay_migrator;
GRANT USAGE ON SCHEMA relay_ops TO relay_app, relay_maint;

ALTER DEFAULT PRIVILEGES FOR ROLE relay_migrator, relay_owner, relay_maint REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

DO $$
DECLARE
  v_execute constant jsonb := '{
    "relay_ops.access_event_receipt_mark": ["relay_worker"],
    "relay_ops.access_event_receipt_read": ["relay_worker"],
    "relay_ops.access_event_receipt_record": ["relay_api", "relay_worker"],
    "relay_ops.access_event_receipts_deferred": ["relay_worker"],
    "relay_ops.access_link_store": ["relay_api", "relay_worker"],
    "relay_ops.api_client_generation": ["relay_api", "relay_worker"],
    "relay_ops.api_client_resolve": ["relay_api", "relay_worker"],
    "relay_ops.audit_checkpoint_publication_record": ["relay_worker"],
    "relay_ops.audit_checkpoint_record": ["relay_worker"],
    "relay_ops.audit_leaves_append": ["relay_worker"],
    "relay_ops.audit_pending": ["relay_worker"],
    "relay_ops.dead_letter_auto_replay_scopes": ["relay_worker"],
    "relay_ops.drr_take": ["relay_worker"],
    "relay_ops.drr_weights_refresh": ["relay_worker"],
    "relay_ops.kill_switch_scopes": ["relay_worker"],
    "relay_ops.kill_switch_snapshot": ["relay_api", "relay_worker"],
    "relay_ops.lane_capacity": ["relay_api", "relay_worker"],
    "relay_ops.load_shed_record": ["relay_worker"],
    "relay_ops.load_shed_state": ["relay_app"],
    "relay_ops.operator_ensure": ["relay_app"],
    "relay_ops.operator_get": ["relay_app"],
    "relay_ops.operator_roles": ["relay_app"],
    "relay_ops.operator_session_resolve": ["relay_app"],
    "relay_ops.operator_session_revoke": ["relay_app"],
    "relay_ops.operator_session_step_up": ["relay_app"],
    "relay_ops.operator_set_status": ["relay_app"],
    "relay_ops.operator_sign_in": ["relay_app"],
    "relay_ops.orphan_check": [],
    "relay_ops.outbox_pending_scopes": ["relay_worker"],
    "relay_ops.partition_due_for_archive": [],
    "relay_ops.partition_horizon": ["relay_worker"],
    "relay_ops.partition_policy_set": ["relay_app"],
    "relay_ops.receipt_keys_due": ["relay_worker"],
    "relay_ops.reference_check": [],
    "relay_ops.retention_due": ["relay_worker"],
    "relay_ops.singleton_acquire": ["relay_worker"],
    "relay_ops.singleton_save": ["relay_worker"],
    "relay_ops.support_delegation_active": ["relay_app"],
    "relay_ops.tenant_create": ["relay_app"],
    "relay_ops.tenant_lookup": ["relay_app"],
    "relay_ops.tenant_overview": ["relay_app"],
    "relay_ops.tenant_suspensions_due": ["relay_app"],
    "relay_ops.waitpoint_due_scopes": ["relay_worker"]
  }';
  v_function regprocedure;
  v_name text;
  v_grantees text[];
  v_grantee text;
BEGIN
  FOR v_function, v_name IN
    SELECT p.oid::regprocedure, n.nspname || '.' || p.proname
    FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'relay_ops'
  LOOP
    IF (SELECT p.proowner FROM pg_catalog.pg_proc p WHERE p.oid = v_function) <> 'relay_maint'::regrole THEN
      EXECUTE format('ALTER FUNCTION %s OWNER TO relay_maint', v_function);
    END IF;

    v_grantees := ARRAY(SELECT pg_catalog.jsonb_array_elements_text(coalesce(v_execute -> v_name, '[]')));

    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', v_function);

    FOR v_grantee IN
      SELECT DISTINCT pg_catalog.pg_get_userbyid(a.grantee)::text
      FROM pg_catalog.pg_proc p, pg_catalog.aclexplode(p.proacl) a
      WHERE p.oid = v_function AND a.grantee <> 0 AND a.grantee <> p.proowner
    LOOP
      IF NOT v_grantee = ANY (v_grantees) THEN
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM %I', v_function, v_grantee);
      END IF;
    END LOOP;

    FOREACH v_grantee IN ARRAY v_grantees
    LOOP
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I', v_function, v_grantee);
    END LOOP;
  END LOOP;
END
$$;
