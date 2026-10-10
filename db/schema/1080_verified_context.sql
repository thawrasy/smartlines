-- =====================================================================
-- Masslak - 1080: a request context the application's login cannot forge (reviews of October 2026, finding C-01)
--
-- Row-level security reads who is acting (user, company, scope) from transaction settings that sys.set_context
-- writes at the start of every request. Until now anything the API's login could run could also write them: one
-- call to set_config('app.scope', 'PLATFORM', true), placed by SQL injection inside an otherwise legitimate
-- statement, showed every company's rows. Three changes close that path:
--   1. sys.set_context accepts a context from a login that is not a superuser only with a ticket: an HMAC of the
--      context and its time under a key the login cannot read (sys.context_key). The API signs each context it sets
--      (backend/app/security.py, context_ticket); the deployment writes the key from the same derivation
--      (db/create_login_roles.sql -v context_key, deploy/migrate.sh). A ticket older than five minutes is refused.
--   2. set_config is no longer executable by every role: a statement cannot change any setting through a function
--      call, so injected SQL can neither rewrite the context nor raise the transaction-local flags the ledger,
--      wallet and requirement guards read (fin.posting_entry, masslak.requirement_change, app.new.*). The functions
--      that set them legitimately run as their owner (SECURITY DEFINER) and keep the right.
--   3. The application role cannot create temporary objects, so nothing it creates can shadow a table that a
--      function owned by the platform reads.
-- What stays open, and why: a person who holds the login's password and can reach the database can still type
-- SET app.scope = ... as a statement of their own. PostgreSQL lets anyone set a custom setting that way, and only a
-- server extension can forbid it. That path needs the password and a connection from inside the platform's network:
-- the database accepts the login from the application's network only, over TLS, in the production profile (review
-- package 2). docs/operations/REVIEW_OCT_2026_RESPONSE.md records this.
-- =====================================================================

-- ------------------------------------------------------------------ 1. the key
CREATE TABLE IF NOT EXISTS sys.context_key (
  fingerprint text PRIMARY KEY CHECK (fingerprint ~ '^[0-9a-f]{16}$'),
  secret      bytea NOT NULL CHECK (length(secret) = 32),
  created_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE sys.context_key IS 'Keys that sign request contexts (1080): written by the deployment, read only by sys.set_context';
COMMENT ON COLUMN sys.context_key.fingerprint IS 'First 16 hex digits of the SHA-256 of the key; a ticket names the key it was made with';
ALTER TABLE sys.context_key ENABLE ROW LEVEL SECURITY;          -- no policy: no role but the owner reads a row
REVOKE ALL ON sys.context_key FROM PUBLIC, masslak_app, masslak_readonly, masslak_auditor;

-- A release before 1.49.0 sets its context without a ticket. Rolled back to such a release (deploy/update.sh
-- --rollback), the platform would refuse every request; a superuser can open a window in which a context without a
-- ticket is accepted again, until a time, with a reason (RUNBOOKS.md, section 30). The API's readiness check reports
-- "not ready" while it is open, so it is not forgotten.
CREATE TABLE IF NOT EXISTS sys.context_unsigned_window (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  allowed_until timestamptz NOT NULL,
  reason        text NOT NULL CHECK (length(reason) >= 10),
  opened_by     text NOT NULL DEFAULT session_user,
  opened_at     timestamptz NOT NULL DEFAULT now(),
  CHECK (allowed_until <= opened_at + interval '24 hours')
);
COMMENT ON TABLE sys.context_unsigned_window IS 'Rollback windows in which a context without a ticket is accepted (1080); written by a superuser only';
ALTER TABLE sys.context_unsigned_window ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON sys.context_unsigned_window FROM PUBLIC, masslak_app, masslak_readonly, masslak_auditor;

-- What the API's readiness check (/api/ready) compares: whether the database holds the key the API signs with, and
-- whether set_config and temporary objects are still withdrawn (a restore through pg_dump into a new database could
-- lose the second and third). It reveals nothing about the key.
CREATE OR REPLACE FUNCTION sys.context_status(p_fingerprint text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT jsonb_build_object(
    'key', EXISTS (SELECT 1 FROM sys.context_key WHERE fingerprint = p_fingerprint),
    'set_config_withdrawn', NOT has_function_privilege('masslak_app', 'pg_catalog.set_config(text,text,boolean)', 'EXECUTE'),
    'temporary_withdrawn', NOT has_database_privilege('masslak_app', current_database(), 'TEMPORARY'),
    'no_unsigned_window', NOT EXISTS (SELECT 1 FROM sys.context_unsigned_window WHERE allowed_until > now()))
$$;
COMMENT ON FUNCTION sys.context_status IS 'Readiness of the verified context: key installed, set_config and temporary objects withdrawn, no rollback window open (1080)';

-- Callers whose own login is a superuser (the deployment, migrations, maintenance, the tests' owner connection) set a
-- context without a ticket: they bypass row security anyway. Any other login needs one.
CREATE OR REPLACE FUNCTION sys.context_trusted_caller() RETURNS boolean
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce((SELECT r.rolsuper FROM pg_catalog.pg_roles r WHERE r.rolname = session_user), false)
$$;
COMMENT ON FUNCTION sys.context_trusted_caller IS 'True when the session''s login is a superuser: it may set a context without a ticket (1080)';

-- ------------------------------------------------------------------ 2. sys.set_context with its ticket
-- The old signature goes: kept beside the new one it would set a context with no ticket. Callers that pass the first
-- three to eight arguments reach the new function unchanged (the ticket arguments have defaults).
DROP FUNCTION IF EXISTS sys.set_context(bigint, bigint, text, bigint, uuid, inet, bigint, bigint);
CREATE FUNCTION sys.set_context(
  p_user_id       bigint,
  p_company_id    bigint,
  p_scope         text,      -- PLATFORM | COMPANY | AGENCY | PASSENGER | API | SYSTEM | AUTH
  p_api_client_id bigint DEFAULT NULL,
  p_request_id    uuid   DEFAULT NULL,
  p_ip            inet   DEFAULT NULL,
  p_session_id    bigint DEFAULT NULL,
  p_party_id      bigint DEFAULT NULL,
  p_issued_at     bigint DEFAULT NULL,   -- seconds since 1970, when the API made the ticket
  p_ticket        text   DEFAULT NULL    -- '<key fingerprint>.<hex HMAC-SHA256>' (backend/app/security.py)
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE k bytea; msg text; drift bigint;
BEGIN
  IF NOT sys.context_trusted_caller() THEN
    IF p_ticket IS NULL AND EXISTS (SELECT 1 FROM sys.context_unsigned_window WHERE allowed_until > now()) THEN
      NULL;                                    -- a release before 1.49.0, during a rollback window a superuser opened
    ELSIF p_ticket IS NULL OR p_issued_at IS NULL OR p_ticket !~ '^[0-9a-f]{16}\.[0-9a-f]{64}$' THEN
      RAISE EXCEPTION 'CONTEXT_TICKET_REQUIRED: this login sets a request context only with a ticket'
        USING ERRCODE = '42501';
    ELSE
      SELECT secret INTO k FROM sys.context_key WHERE fingerprint = split_part(p_ticket, '.', 1);
      IF k IS NULL THEN
        RAISE EXCEPTION 'CONTEXT_KEY_UNKNOWN: the ticket was made with a key this database does not hold (db/create_login_roles.sql)'
          USING ERRCODE = '42501';
      END IF;
      drift := abs(extract(epoch FROM clock_timestamp())::bigint - p_issued_at);
      IF drift > 300 THEN
        RAISE EXCEPTION 'CONTEXT_TICKET_STALE: the ticket is % s away from the database clock', drift USING ERRCODE = '42501';
      END IF;
      msg := concat('masslak-context-v1|', p_user_id::text, '|', p_company_id::text, '|', p_scope, '|', p_api_client_id::text, '|',
                    p_request_id::text, '|', p_session_id::text, '|', p_party_id::text, '|', p_issued_at::text);
      IF encode(public.hmac(convert_to(msg, 'UTF8'), k, 'sha256'), 'hex') <> split_part(p_ticket, '.', 2) THEN
        RAISE EXCEPTION 'CONTEXT_TICKET_INVALID: the ticket does not match the context' USING ERRCODE = '42501';
      END IF;
    END IF;
  END IF;
  PERFORM set_config('app.user_id',       coalesce(p_user_id::text, ''),       true);
  PERFORM set_config('app.company_id',    coalesce(p_company_id::text, ''),    true);
  PERFORM set_config('app.scope',         coalesce(p_scope, ''),               true);
  PERFORM set_config('app.api_client_id', coalesce(p_api_client_id::text, ''), true);
  PERFORM set_config('app.request_id',    coalesce(p_request_id::text, ''),    true);
  PERFORM set_config('app.ip',            coalesce(host(p_ip), ''),            true);
  PERFORM set_config('app.session_id',    coalesce(p_session_id::text, ''),    true);
  PERFORM set_config('app.party_id',      coalesce(p_party_id::text, ''),      true);
END $$;
COMMENT ON FUNCTION sys.set_context(bigint, bigint, text, bigint, uuid, inet, bigint, bigint, bigint, text) IS
  'Sets the request context for row security and auditing; a login that is not a superuser needs the API''s ticket (1080)';
GRANT EXECUTE ON FUNCTION sys.set_context(bigint, bigint, text, bigint, uuid, inet, bigint, bigint, bigint, text) TO PUBLIC;

-- ------------------------------------------------------------------ 3. set_config only for the platform's own functions
-- The trigger that lists rows created by the transaction (1039) ran with the caller's rights; it now runs as its owner
-- like the other functions that set transaction-local flags (fin.tg_ledger_entry_apply, fin.roll_up_balances,
-- sec.rate_take, sys.decide_requirement_change).
CREATE OR REPLACE FUNCTION sys.tg_remember_new_row() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE k text := 'app.new.' || TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME;
BEGIN
  PERFORM set_config(k, coalesce(nullif(current_setting(k, true), ''), '') || ',' || NEW.id::text, true);
  RETURN NEW;
END $$;

DO $$
BEGIN
  IF NOT (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) THEN
    RAISE EXCEPTION 'schema file 1080 must run as a superuser: it withdraws set_config from every role';
  END IF;
  REVOKE EXECUTE ON FUNCTION pg_catalog.set_config(text, text, boolean) FROM PUBLIC;
  -- temporary objects: none of the platform's roles needs them, and the application's could shadow tables
  EXECUTE format('REVOKE TEMPORARY ON DATABASE %I FROM PUBLIC', current_database());
END $$;

-- ------------------------------------------------------------------ registrations
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('sys.context_key', '1A', 'E42'), ('sys.context_unsigned_window', '1A', 'E42')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
INSERT INTO gov.data_inventory (dataset, data_class, owner, purpose, legal_basis, retention_days, erasure_method, copies, backup_retention_days)
VALUES ('sys.context_key', 'RESTRICTED', 'sys', 'Keys that sign request contexts; a replaced key is deleted a day later', 'Security of processing',
        30, 'DELETE', '{replica,backup}', 35),
       ('sys.context_unsigned_window', 'INTERNAL', 'sys', 'Rollback windows that accepted request contexts without a ticket, with who opened them and why',
        'Security of processing', 3650, 'KEEP_LEGAL', '{replica,backup,offsite}', 35)
ON CONFLICT (dataset) DO NOTHING;
SELECT sys.refresh_table_class();
