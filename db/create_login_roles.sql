-- Login roles for the running system (run once per database server, after build.sh).
--   psql -v api_password=... -v audit_password=... -v context_key=... -f db/create_login_roles.sql
-- masslak_api   : the API connection, member of masslak_app (subject to row-level security)
-- masslak_audit : read-only connection for the security console, member of masslak_auditor
-- masslak_cdc   : the data warehouse's subscription (1062); signs in only when -v cdc_password=... is given
-- A deployment step: its grants are logged as a migration, not alerted as a manual change (audit.ddl_event, 1047)
SET masslak.migrating = on;
SELECT format('CREATE ROLE masslak_api LOGIN PASSWORD %L IN ROLE masslak_app', :'api_password')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'masslak_api') \gexec
SELECT format('ALTER ROLE masslak_api PASSWORD %L', :'api_password') \gexec
SELECT format('CREATE ROLE masslak_audit LOGIN PASSWORD %L IN ROLE masslak_auditor', :'audit_password')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'masslak_audit') \gexec
SELECT format('ALTER ROLE masslak_audit PASSWORD %L', :'audit_password') \gexec
-- The replication attribute is not inherited, so the warehouse signs in as masslak_cdc itself. pg_hba.conf lets it
-- open logical (per-database) replication connections only, never a physical stream of the whole cluster.
\if :{?cdc_password}
SELECT format('ALTER ROLE masslak_cdc LOGIN PASSWORD %L', :'cdc_password') \gexec
\endif
-- The key the API signs request contexts with (1080): the hex that `python -m app.tools.context_key` prints for the
-- API's MASSLAK_SIGNING_SECRET. deploy/migrate.sh passes it on every start, so a changed signing secret brings its key;
-- the key it replaces stays a day, for API processes still running with it, then goes.
\if :{?context_key}
INSERT INTO sys.context_key (fingerprint, secret)
SELECT left(encode(public.digest(decode(:'context_key', 'hex'), 'sha256'), 'hex'), 16), decode(:'context_key', 'hex')
ON CONFLICT (fingerprint) DO NOTHING;
DELETE FROM sys.context_key
 WHERE fingerprint <> left(encode(public.digest(decode(:'context_key', 'hex'), 'sha256'), 'hex'), 16)
   AND created_at < now() - interval '1 day';
\endif
-- Time limits of the running system's sessions (review of October 2026, stage A7). The application pool gives up on a
-- statement after 30 s (backend/app/db.py); the server now stops it too, so abandoned work does not keep running. A
-- request waits at most 5 s for a row or table lock (a migration waits the same at most, db/upgrade.sh), and a
-- transaction left open without a statement for 2 minutes is ended, releasing its locks. The longest outside call made
-- inside a transaction (file scan, mail) is 30 s. Reports on the replica set their own limit when they connect.
-- JIT compiles long analytical queries; the API's are short, and asyncpg would otherwise switch it off around its type
-- introspection with set_config, which no login but a superuser may call (1080, backend/app/db.py prepare_connection)
ALTER ROLE masslak_api SET jit = off;
ALTER ROLE masslak_audit SET jit = off;
ALTER ROLE masslak_api SET statement_timeout = '30s';
ALTER ROLE masslak_api SET lock_timeout = '5s';
ALTER ROLE masslak_api SET idle_in_transaction_session_timeout = '2min';
ALTER ROLE masslak_audit SET statement_timeout = '30s';
-- the security console's connections are capped here, whatever the number of API servers (CAPACITY_MODEL.md, section 10)
ALTER ROLE masslak_audit CONNECTION LIMIT 20;
ALTER ROLE masslak_audit SET lock_timeout = '5s';
ALTER ROLE masslak_audit SET idle_in_transaction_session_timeout = '2min';
-- The auditor reads user e-mails next to log rows
GRANT USAGE ON SCHEMA iam TO masslak_auditor;
GRANT SELECT (id, email) ON iam.app_user TO masslak_auditor;
