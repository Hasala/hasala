\set ON_ERROR_STOP on

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'hasala_migrate') THEN
    CREATE ROLE hasala_migrate LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'hasala_runtime') THEN
    CREATE ROLE hasala_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION
      CONNECTION LIMIT 30;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'hasala_backup') THEN
    CREATE ROLE hasala_backup LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION
      CONNECTION LIMIT 4;
  END IF;
END $$;

ALTER ROLE hasala_backup CONNECTION LIMIT 4;

GRANT pg_read_all_data TO hasala_backup;
ALTER ROLE hasala_backup  SET default_transaction_read_only = on;
ALTER ROLE hasala_runtime SET statement_timeout = '15s';
ALTER ROLE hasala_runtime SET lock_timeout = '5s';
ALTER ROLE hasala_runtime SET idle_in_transaction_session_timeout = '30s';
ALTER ROLE hasala_migrate SET lock_timeout = '30s';
ALTER ROLE hasala_migrate SET statement_timeout = 0;

SELECT 'CREATE DATABASE hasala OWNER hasala_migrate TEMPLATE template0 ENCODING ''UTF8'' '
       'LOCALE ''C'' LOCALE_PROVIDER builtin BUILTIN_LOCALE ''C.UTF-8'''
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'hasala') \gexec

REVOKE ALL     ON DATABASE hasala    FROM PUBLIC;
REVOKE CONNECT ON DATABASE postgres  FROM PUBLIC;
REVOKE CONNECT ON DATABASE template1 FROM PUBLIC;
GRANT  CONNECT ON DATABASE hasala TO hasala_runtime, hasala_backup;

\connect hasala
ALTER SCHEMA public OWNER TO hasala_migrate;
REVOKE ALL   ON SCHEMA public FROM PUBLIC;
GRANT  USAGE ON SCHEMA public TO hasala_runtime, hasala_backup;
