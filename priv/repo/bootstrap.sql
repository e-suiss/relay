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
CREATE SCHEMA IF NOT EXISTS relay_ops AUTHORIZATION relay_maint;

REVOKE ALL ON SCHEMA relay, relay_private, relay_fn, relay_ops FROM PUBLIC;

GRANT USAGE ON SCHEMA relay TO relay_owner, relay_app, relay_maint, relay_archive, relay_report;
GRANT USAGE ON SCHEMA relay_private TO relay_owner, relay_app, relay_maint, relay_archive, relay_report;
GRANT USAGE ON SCHEMA relay_fn TO relay_app, relay_report;
GRANT CREATE ON SCHEMA relay_fn TO relay_migrator;
GRANT USAGE ON SCHEMA relay_ops TO relay_app;
GRANT CREATE ON SCHEMA relay_ops TO relay_migrator;

ALTER DEFAULT PRIVILEGES FOR ROLE relay_migrator, relay_owner, relay_maint REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
