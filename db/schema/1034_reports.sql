-- =====================================================================
-- 1034: reports
--   The report catalog is code (backend/app/modules/reports): datasets name the columns a report may use and
--   every query runs under the caller's row-level security, so a report can never show rows its reader could
--   not open on screen. This file keeps what users add on top of the catalog:
--     report_definition  custom reports built from a dataset (columns, filters, grouping, totals, order)
--     report_run         who ran or exported which report, with what parameters, how many rows (append-only)
--     report_schedule    reports delivered by e-mail on a daily, weekly or monthly cycle
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS rpt;
COMMENT ON SCHEMA rpt IS 'Custom report definitions, the export log and report schedules';
GRANT USAGE ON SCHEMA rpt TO masslak_app, masslak_readonly, masslak_auditor;

CREATE TABLE IF NOT EXISTS rpt.report_definition (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid            uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  company_id     bigint REFERENCES iam.company(id),            -- NULL: a platform report
  owner_user_id  bigint NOT NULL REFERENCES iam.app_user(id),
  audience       text NOT NULL CHECK (audience IN ('PLATFORM','COMPANY')),
  name           text NOT NULL CHECK (length(name) BETWEEN 3 AND 120),
  description    text CHECK (description IS NULL OR length(description) <= 500),
  dataset        text NOT NULL CHECK (dataset ~ '^[a-z_]{3,40}$'),
  spec           jsonb NOT NULL CHECK (jsonb_typeof(spec) = 'object'),
  shared         boolean NOT NULL DEFAULT false,                -- visible to the rest of the company (or platform staff)
  status         text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','ARCHIVED')),
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CHECK ((audience = 'PLATFORM') = (company_id IS NULL))
);
COMMENT ON TABLE rpt.report_definition IS 'Custom report built from a whitelisted dataset; spec holds columns, filters, group_by, totals and sort by column key only';
COMMENT ON COLUMN rpt.report_definition.spec IS 'Column keys of the dataset, never SQL: {"columns":[],"filters":[],"group_by":[],"totals":[],"sort":[]}';
CREATE INDEX IF NOT EXISTS report_definition_company_fkx ON rpt.report_definition (company_id);
CREATE INDEX IF NOT EXISTS report_definition_owner_user_id_fkx ON rpt.report_definition (owner_user_id);

CREATE TABLE IF NOT EXISTS rpt.report_run (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  report_code    text CHECK (report_code IS NULL OR report_code ~ '^[a-z0-9_.]{3,60}$'),
  definition_id  bigint REFERENCES rpt.report_definition(id),
  user_id        bigint REFERENCES iam.app_user(id),
  api_client_id  bigint REFERENCES iam.api_client(id),
  company_id     bigint REFERENCES iam.company(id),
  portal         text NOT NULL,
  params         jsonb NOT NULL DEFAULT '{}',
  format         text NOT NULL CHECK (format IN ('PREVIEW','JSON','CSV','TXT','XLSX','PDF')),
  row_count      integer NOT NULL CHECK (row_count >= 0),
  sha256         bytea,                                         -- digest of the exported file, to prove what was handed out
  duration_ms    integer NOT NULL CHECK (duration_ms >= 0),
  created_at     timestamptz NOT NULL DEFAULT now(),
  CHECK (num_nonnulls(report_code, definition_id) = 1),
  CHECK (num_nonnulls(user_id, api_client_id) >= 1)
);
COMMENT ON TABLE rpt.report_run IS 'Every report preview and export: who, which report, parameters, rows and file digest (append-only)';
CREATE INDEX IF NOT EXISTS report_run_definition_id_fkx ON rpt.report_run (definition_id);
CREATE INDEX IF NOT EXISTS report_run_user_id_fkx ON rpt.report_run (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS report_run_api_client_id_fkx ON rpt.report_run (api_client_id);
CREATE INDEX IF NOT EXISTS report_run_company_id_fkx ON rpt.report_run (company_id, created_at DESC);

CREATE TABLE IF NOT EXISTS rpt.report_schedule (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid            uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  report_code    text CHECK (report_code IS NULL OR report_code ~ '^[a-z0-9_.]{3,60}$'),
  definition_id  bigint REFERENCES rpt.report_definition(id) ON DELETE CASCADE,
  owner_user_id  bigint NOT NULL REFERENCES iam.app_user(id),
  company_id     bigint REFERENCES iam.company(id),
  portal         text NOT NULL,
  frequency      text NOT NULL CHECK (frequency IN ('DAILY','WEEKLY','MONTHLY')),
  format         text NOT NULL CHECK (format IN ('CSV','TXT','XLSX','PDF')),
  locale         text NOT NULL DEFAULT 'ar' REFERENCES ref.locale(code),
  recipients     text[] NOT NULL CHECK (cardinality(recipients) BETWEEN 1 AND 10),
  params         jsonb NOT NULL DEFAULT '{}',
  next_run_at    timestamptz NOT NULL,
  last_run_at    timestamptz,
  active         boolean NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now(),
  CHECK (num_nonnulls(report_code, definition_id) = 1)
);
COMMENT ON TABLE rpt.report_schedule IS 'Report delivered by e-mail on a cycle; the outbox worker runs it with the owner''s rights';
CREATE INDEX IF NOT EXISTS report_schedule_definition_id_fkx ON rpt.report_schedule (definition_id);
CREATE INDEX IF NOT EXISTS report_schedule_owner_user_id_fkx ON rpt.report_schedule (owner_user_id);
CREATE INDEX IF NOT EXISTS report_schedule_company_id_fkx ON rpt.report_schedule (company_id);
CREATE INDEX IF NOT EXISTS report_schedule_due ON rpt.report_schedule (next_run_at) WHERE active;

-- Row-level security: platform staff see platform reports; company staff see their company's shared reports
-- and their own. The export log is visible to the platform and, for its own rows, to the company.
SELECT sys.rls('rpt.report_definition',
  'sys.ctx_is_platform() OR (company_id = sys.ctx_company_id() AND (shared OR owner_user_id = sys.ctx_user_id()))',
  '(sys.ctx_is_platform() AND company_id IS NULL) OR (company_id = sys.ctx_company_id() AND owner_user_id = sys.ctx_user_id())');
SELECT sys.rls('rpt.report_run', 'sys.ctx_is_platform() OR company_id = sys.ctx_company_id()',
  'sys.ctx_is_platform() OR company_id = sys.ctx_company_id()');
SELECT sys.rls('rpt.report_schedule',
  '(sys.ctx_is_platform() AND company_id IS NULL) OR (company_id = sys.ctx_company_id() AND owner_user_id = sys.ctx_user_id())');
SELECT sys.grant_rw(ARRAY['rpt.report_definition','rpt.report_schedule']);
SELECT sys.grant_append(ARRAY['rpt.report_run']);
SELECT sys.track_updates('rpt.report_definition');

-- Report permissions: building and sharing custom reports, and scheduled delivery
INSERT INTO iam.permission (code, module, scope, description, is_sensitive) VALUES
  ('report.custom', 'reports', 'BOTH', 'Build, save and share custom reports from the report datasets', false),
  ('report.schedule', 'reports', 'BOTH', 'Schedule reports for delivery by e-mail', false)
ON CONFLICT (code) DO NOTHING;
INSERT INTO iam.role_permission (role_id, permission_code)
SELECT r.id, p.code FROM iam.role r
  JOIN (VALUES ('PLATFORM_ADMIN','report.platform'), ('PLATFORM_ADMIN','report.custom'), ('PLATFORM_ADMIN','report.schedule'),
               ('PLATFORM_FINANCE','report.platform'), ('PLATFORM_FINANCE','report.custom'), ('PLATFORM_FINANCE','report.schedule'),
               ('PLATFORM_SECURITY','report.platform'), ('PLATFORM_SUPPORT','report.platform'), ('PLATFORM_MARKETING','report.platform'),
               ('REGULATOR','report.platform'),
               ('CARRIER_ACCOUNTANT','report.company'), ('CARRIER_ACCOUNTANT','report.custom'), ('CARRIER_ACCOUNTANT','report.schedule'),
               ('CARRIER_OPERATIONS','report.company'), ('CARRIER_OPERATIONS','report.custom'),
               ('AGENCY_ACCOUNTANT','report.company'), ('AGENCY_ACCOUNTANT','report.custom'), ('AGENCY_ACCOUNTANT','report.schedule'))
       AS g(role_code, perm) ON g.role_code = r.code AND r.company_id IS NULL
  JOIN iam.permission p ON p.code = g.perm
ON CONFLICT DO NOTHING;

INSERT INTO sys.schema_migration (version, description)
SELECT '1.17.0', 'Reports: custom report definitions, export log and schedules'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.17.0');
