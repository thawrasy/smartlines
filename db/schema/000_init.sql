-- =====================================================================
-- Masslak — Phase 1 database
-- 000: extensions, schemas, roles and helper functions
-- Source: study v2.4, section 29.1 (rules for the PostgreSQL production schema)
--   amounts are BIGINT in minor currency units, timestamps are TIMESTAMPTZ (UTC),
--   JSONB for flexible fields, internal BIGINT key + public UUID,
--   explicit foreign keys, time partitioning for large tables, field-level encryption.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;    -- gen_random_uuid, digest
CREATE EXTENSION IF NOT EXISTS citext;      -- case-insensitive email addresses
CREATE EXTENSION IF NOT EXISTS btree_gist;  -- exclusion constraints (no overlapping vehicle, crew or lease periods)
CREATE EXTENSION IF NOT EXISTS pg_trgm;     -- text search on stations and cities

-- ---------------------------------------------------------------------
-- Schemas: one schema per module, each with its own privileges
-- ---------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS sys;      -- settings, outbox, webhooks, helper functions
CREATE SCHEMA IF NOT EXISTS ref;      -- reference data: countries, currencies, cities, locales, files
CREATE SCHEMA IF NOT EXISTS iam;      -- identity, parties, users, permissions and API clients
CREATE SCHEMA IF NOT EXISTS net;      -- network: stations, routes, carrier codes
CREATE SCHEMA IF NOT EXISTS fleet;    -- vehicles, seats, crew, licenses and insurance
CREATE SCHEMA IF NOT EXISTS pricing;  -- fares, brands, taxes, commissions, campaigns and loyalty
CREATE SCHEMA IF NOT EXISTS ops;      -- trips, inventory, operations, tracking and incidents
CREATE SCHEMA IF NOT EXISTS sales;    -- bookings, passengers, tickets and boarding
CREATE SCHEMA IF NOT EXISTS fin;      -- wallets, ledger, payments, price allocation and settlement
CREATE SCHEMA IF NOT EXISTS acct;     -- simplified accounting, e-invoicing and tax profiles
CREATE SCHEMA IF NOT EXISTS crm;      -- complaints, ratings, notifications and the AI assistant
CREATE SCHEMA IF NOT EXISTS gov;      -- governance: policy authority matrix, obligations, data protection
CREATE SCHEMA IF NOT EXISTS sec;      -- security: IP rules, risk, keys, security & compliance hub
CREATE SCHEMA IF NOT EXISTS audit;    -- login and activity logs (append-only)

-- ---------------------------------------------------------------------
-- Roles — least privilege (16.17: database accounts with minimal privileges)
--   masslak_owner   : schema owner, migrations only (never used by the application)
--   masslak_app     : the application; subject to RLS, cannot modify or delete log records
--   masslak_readonly: reporting and read access
--   masslak_auditor : read access to audit and security logs only
-- ---------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'masslak_owner')    THEN CREATE ROLE masslak_owner NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'masslak_app')      THEN CREATE ROLE masslak_app NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'masslak_readonly') THEN CREATE ROLE masslak_readonly NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'masslak_auditor')  THEN CREATE ROLE masslak_auditor NOLOGIN; END IF;
END $$;

-- ---------------------------------------------------------------------
-- Request context: set by the application at the start of every transaction via sys.set_context()
-- and used by RLS policies and audit logs
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sys.set_context(
  p_user_id       bigint,
  p_company_id    bigint,
  p_scope         text,      -- PLATFORM | COMPANY | AGENCY | PASSENGER | API | SYSTEM
  p_api_client_id bigint DEFAULT NULL,
  p_request_id    uuid   DEFAULT NULL,
  p_ip            inet   DEFAULT NULL,
  p_session_id    bigint DEFAULT NULL,
  p_party_id      bigint DEFAULT NULL
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('app.user_id',       coalesce(p_user_id::text, ''),       true);
  PERFORM set_config('app.company_id',    coalesce(p_company_id::text, ''),    true);
  PERFORM set_config('app.scope',         coalesce(p_scope, ''),               true);
  PERFORM set_config('app.api_client_id', coalesce(p_api_client_id::text, ''), true);
  PERFORM set_config('app.request_id',    coalesce(p_request_id::text, ''),    true);
  PERFORM set_config('app.ip',            coalesce(host(p_ip), ''),            true);
  PERFORM set_config('app.session_id',    coalesce(p_session_id::text, ''),    true);
  PERFORM set_config('app.party_id',      coalesce(p_party_id::text, ''),      true);
END $$;

CREATE OR REPLACE FUNCTION sys.ctx_bigint(p_key text) RETURNS bigint
LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting(p_key, true), '')::bigint $$;

CREATE OR REPLACE FUNCTION sys.ctx_user_id()       RETURNS bigint LANGUAGE sql STABLE AS $$ SELECT sys.ctx_bigint('app.user_id') $$;
CREATE OR REPLACE FUNCTION sys.ctx_company_id()    RETURNS bigint LANGUAGE sql STABLE AS $$ SELECT sys.ctx_bigint('app.company_id') $$;
CREATE OR REPLACE FUNCTION sys.ctx_api_client_id() RETURNS bigint LANGUAGE sql STABLE AS $$ SELECT sys.ctx_bigint('app.api_client_id') $$;
CREATE OR REPLACE FUNCTION sys.ctx_party_id()      RETURNS bigint LANGUAGE sql STABLE AS $$ SELECT sys.ctx_bigint('app.party_id') $$;
CREATE OR REPLACE FUNCTION sys.ctx_session_id()    RETURNS bigint LANGUAGE sql STABLE AS $$ SELECT sys.ctx_bigint('app.session_id') $$;
CREATE OR REPLACE FUNCTION sys.ctx_scope()         RETURNS text   LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('app.scope', true), '') $$;
CREATE OR REPLACE FUNCTION sys.ctx_request_id()    RETURNS uuid   LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('app.request_id', true), '')::uuid $$;
CREATE OR REPLACE FUNCTION sys.ctx_ip()            RETURNS inet   LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('app.ip', true), '')::inet $$;
CREATE OR REPLACE FUNCTION sys.ctx_is_platform()   RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT coalesce(sys.ctx_scope() IN ('PLATFORM','SYSTEM'), false) $$;

-- Tenant isolation: a company row is visible to platform staff or to users of that same company
CREATE OR REPLACE FUNCTION sys.tenant_visible(p_company_id bigint) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT sys.ctx_is_platform() OR (p_company_id IS NOT NULL AND p_company_id = sys.ctx_company_id())
$$;

-- ---------------------------------------------------------------------
-- Generic trigger functions
-- ---------------------------------------------------------------------
-- Maintain updated_at automatically
CREATE OR REPLACE FUNCTION sys.tg_set_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

-- Block updates and deletes (append-only tables: ledger, logs, finalized invoices...)
CREATE OR REPLACE FUNCTION sys.tg_forbid_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'IMMUTABLE_RECORD: % on %.% is not allowed', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME
    USING ERRCODE = 'P0001';
END $$;

-- Mod 11 check digit (tracking and document numbers, 4.16 b)
CREATE OR REPLACE FUNCTION sys.mod11_check_digit(p_digits text) RETURNS int
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE s int := 0; w int := 2; i int; r int;
BEGIN
  FOR i IN REVERSE length(p_digits)..1 LOOP
    s := s + (substr(p_digits, i, 1))::int * w;
    w := CASE WHEN w = 7 THEN 2 ELSE w + 1 END;
  END LOOP;
  r := 11 - (s % 11);
  RETURN CASE WHEN r = 11 THEN 0 WHEN r = 10 THEN 1 ELSE r END;
END $$;

COMMENT ON FUNCTION sys.set_context IS 'Sets the request context (user, company, scope, API client, request id, IP) for RLS policies and auditing';
COMMENT ON FUNCTION sys.tg_forbid_mutation IS 'Blocks UPDATE and DELETE on append-only tables';
