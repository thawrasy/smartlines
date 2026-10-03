-- Login roles for the running system (run once per database server, after build.sh).
--   psql -v api_password=... -v audit_password=... -f db/create_login_roles.sql
-- masslak_api   : the API connection, member of masslak_app (subject to row-level security)
-- masslak_audit : read-only connection for the security console, member of masslak_auditor
SELECT format('CREATE ROLE masslak_api LOGIN PASSWORD %L IN ROLE masslak_app', :'api_password')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'masslak_api') \gexec
SELECT format('ALTER ROLE masslak_api PASSWORD %L', :'api_password') \gexec
SELECT format('CREATE ROLE masslak_audit LOGIN PASSWORD %L IN ROLE masslak_auditor', :'audit_password')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'masslak_audit') \gexec
SELECT format('ALTER ROLE masslak_audit PASSWORD %L', :'audit_password') \gexec
-- The auditor reads user e-mails next to log rows
GRANT USAGE ON SCHEMA iam TO masslak_auditor;
GRANT SELECT (id, email) ON iam.app_user TO masslak_auditor;
