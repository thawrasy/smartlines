-- =====================================================================
-- 1049: the re-audit of design 3.8 (docs/database/DESIGN_AUDIT_T3_RECHECK.md)
--   A  T3-16: operational metrics read by the API's /api/metrics endpoint (Prometheus): outbox, deliveries, partitions,
--      scans, break-glass, jobs, WAL archiving, connections, locks, long transactions, deadlocks, vacuum, wraparound;
--      and a record of every run of the daily upkeep.
--   B  T3-05: scheduled reports with personal or money columns need the owner's consent and go by a short-lived link per
--      named account, never as an attachment; every download is counted and logged.
--   C  T3-11: positions carry the registered device that sent them; a revoked device or failed attestation rejects them,
--      and attestation can be made required by configuration (tracking.device_attestation, OFF until a regulator asks).
--   D  T3-12: resending a money or authority event to a partner needs a platform approval; payments, refunds, provider
--      notices and the ledger are reconciled daily, with an alert on any mismatch.
-- =====================================================================

-- =====================================================================
-- A  T3-16: metrics
-- =====================================================================
CREATE TABLE IF NOT EXISTS sys.job_run (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  job          text NOT NULL CHECK (job ~ '^[a-z_.]+$'),
  started_at   timestamptz NOT NULL DEFAULT now(),
  finished_at  timestamptz,
  ok           boolean,
  detail       jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS job_run_job_idx ON sys.job_run (job, started_at DESC);
COMMENT ON TABLE sys.job_run IS 'Every run of a scheduled job (daily upkeep), so monitoring can alert when one stops or fails (audit T3-16)';
SELECT sys.rls('sys.job_run', 'sys.ctx_is_platform()');
GRANT SELECT ON sys.job_run TO masslak_readonly, masslak_auditor;

-- The daily upkeep records its run and its result
DO $$
DECLARE def text;
BEGIN
  IF to_regprocedure('sys.run_maintenance_body()') IS NULL THEN
    def := pg_get_functiondef('sys.run_maintenance()'::regprocedure);
    def := replace(def, 'FUNCTION sys.run_maintenance()', 'FUNCTION sys.run_maintenance_body()');
    EXECUTE def;
  END IF;
END $$;
CREATE OR REPLACE FUNCTION sys.run_maintenance() RETURNS jsonb LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE rid bigint; out jsonb;
BEGIN
  INSERT INTO sys.job_run (job) VALUES ('maintenance') RETURNING id INTO rid;
  out := sys.run_maintenance_body();
  UPDATE sys.job_run SET finished_at = clock_timestamp(), detail = out,
         ok = coalesce((out ->> 'wallet_mismatches')::int, 0) = 0 AND coalesce((out -> 'orphans')::text, 'null') IN ('null', '0')
   WHERE id = rid;
  RETURN out;
END $$;
REVOKE ALL ON FUNCTION sys.run_maintenance_body() FROM PUBLIC;

-- name, labels and value of every operational metric; read by the API with the system scope
CREATE OR REPLACE FUNCTION sys.ops_metrics() RETURNS TABLE (metric text, labels jsonb, value double precision)
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  -- outbox and deliveries
  RETURN QUERY SELECT 'masslak_outbox_pending'::text, '{}'::jsonb, count(*)::float8 FROM sys.outbox_event WHERE status = 'PENDING';
  RETURN QUERY SELECT 'masslak_outbox_oldest_pending_seconds', '{}'::jsonb,
                      coalesce(extract(epoch FROM now() - min(created_at)), 0)::float8 FROM sys.outbox_event WHERE status = 'PENDING';
  RETURN QUERY SELECT 'masslak_outbox_dead', '{}'::jsonb, count(*)::float8 FROM sys.outbox_event WHERE status IN ('DEAD', 'FAILED');
  RETURN QUERY SELECT 'masslak_webhook_deliveries', jsonb_build_object('status', s.status), count(d.id)::float8
                 FROM (VALUES ('PENDING'), ('DELIVERED'), ('FAILED'), ('DEAD')) s(status)
                 LEFT JOIN sys.webhook_delivery d ON d.status = s.status GROUP BY s.status;
  -- partitions of positions: today and tomorrow must exist
  RETURN QUERY SELECT 'masslak_geo_partitions_missing', '{}'::jsonb,
                      (2 - count(*))::float8 FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
                WHERE i.inhparent = 'ops.geo_event'::regclass
                  AND c.relname IN ('geo_event_' || to_char(current_date, 'YYYYMMDD'), 'geo_event_' || to_char(current_date + 1, 'YYYYMMDD'));
  RETURN QUERY SELECT 'masslak_geo_rows_in_default_partition', '{}'::jsonb,
                      greatest(coalesce((SELECT c.reltuples FROM pg_class c WHERE c.oid = to_regclass('ops.geo_event_default')), 0), 0)::float8;
  -- files, break-glass, requirement changes
  RETURN QUERY SELECT 'masslak_files_pending_scan', '{}'::jsonb, count(*)::float8 FROM ref.file_object WHERE scan_status IN ('PENDING', 'SCANNING');
  RETURN QUERY SELECT 'masslak_files_oldest_pending_scan_seconds', '{}'::jsonb,
                      coalesce(extract(epoch FROM now() - min(created_at)), 0)::float8 FROM ref.file_object WHERE scan_status IN ('PENDING', 'SCANNING');
  RETURN QUERY SELECT 'masslak_break_glass_open', '{}'::jsonb, count(*)::float8 FROM sec.break_glass_log WHERE ended_at IS NULL AND expires_at > now();
  RETURN QUERY SELECT 'masslak_break_glass_unreviewed', '{}'::jsonb, count(*)::float8 FROM sec.break_glass_log
                WHERE ended_at IS NOT NULL AND reviewed_by IS NULL AND ended_at < now() - interval '24 hours';
  RETURN QUERY SELECT 'masslak_requirement_changes_open', '{}'::jsonb, count(*)::float8 FROM sys.requirement_change WHERE status = 'PROPOSED';
  -- jobs
  RETURN QUERY SELECT 'masslak_job_last_success_age_seconds', jsonb_build_object('job', j.job),
                      greatest(coalesce(extract(epoch FROM clock_timestamp() - max(j.finished_at) FILTER (WHERE j.ok)), 1e9), 0)::float8
                 FROM (SELECT 'maintenance'::text AS job) k LEFT JOIN sys.job_run j ON j.job = k.job GROUP BY j.job;
  RETURN QUERY SELECT 'masslak_wallet_mismatches', '{}'::jsonb,
                      coalesce((SELECT (detail ->> 'wallet_mismatches')::float8 FROM sys.job_run WHERE job = 'maintenance' AND finished_at IS NOT NULL
                                 ORDER BY id DESC LIMIT 1), 0);
  RETURN QUERY SELECT 'masslak_payment_mismatches', '{}'::jsonb,
                      coalesce((SELECT (detail ->> 'payment_mismatches')::float8 FROM sys.job_run WHERE job = 'maintenance' AND finished_at IS NOT NULL
                                 ORDER BY id DESC LIMIT 1), 0);
  RETURN QUERY SELECT 'masslak_delivery_retries_waiting', '{}'::jsonb,
                      count(*)::float8 FROM sys.delivery_retry_request WHERE status = 'PENDING';
  RETURN QUERY SELECT 'masslak_violations_awaiting_review', '{}'::jsonb,
                      count(*)::float8 FROM ops.route_violation WHERE evidence_trust = 'LOW' AND reviewed_by IS NULL AND status = 'OPEN';
  -- WAL archiving (point-in-time recovery)
  RETURN QUERY SELECT 'masslak_db_wal_archive_last_success_age_seconds', '{}'::jsonb,
                      coalesce(extract(epoch FROM now() - a.last_archived_time), -1)::float8 FROM pg_stat_archiver a;
  RETURN QUERY SELECT 'masslak_db_wal_archive_failed_total', '{}'::jsonb, a.failed_count::float8 FROM pg_stat_archiver a;
  RETURN QUERY SELECT 'masslak_db_archive_mode_on', '{}'::jsonb, (current_setting('archive_mode') <> 'off')::int::float8;
  -- server health
  RETURN QUERY SELECT 'masslak_db_connections', jsonb_build_object('state', coalesce(a.state, 'unknown')), count(*)::float8
                 FROM pg_stat_activity a WHERE a.backend_type = 'client backend' GROUP BY a.state;
  RETURN QUERY SELECT 'masslak_db_connections_max', '{}'::jsonb, current_setting('max_connections')::float8;
  RETURN QUERY SELECT 'masslak_db_lock_waiters', '{}'::jsonb, count(*)::float8 FROM pg_stat_activity WHERE wait_event_type = 'Lock';
  RETURN QUERY SELECT 'masslak_db_longest_transaction_seconds', '{}'::jsonb,
                      coalesce(max(extract(epoch FROM now() - xact_start)), 0)::float8 FROM pg_stat_activity
                WHERE backend_type = 'client backend' AND xact_start IS NOT NULL AND state <> 'idle';
  RETURN QUERY SELECT 'masslak_db_idle_in_transaction', '{}'::jsonb, count(*)::float8 FROM pg_stat_activity WHERE state = 'idle in transaction';
  RETURN QUERY SELECT 'masslak_db_deadlocks_total', '{}'::jsonb, deadlocks::float8 FROM pg_stat_database WHERE datname = current_database();
  RETURN QUERY SELECT 'masslak_db_commits_total', '{}'::jsonb, xact_commit::float8 FROM pg_stat_database WHERE datname = current_database();
  RETURN QUERY SELECT 'masslak_db_rollbacks_total', '{}'::jsonb, xact_rollback::float8 FROM pg_stat_database WHERE datname = current_database();
  RETURN QUERY SELECT 'masslak_db_temp_bytes_total', '{}'::jsonb, temp_bytes::float8 FROM pg_stat_database WHERE datname = current_database();
  RETURN QUERY SELECT 'masslak_db_cache_hit_ratio', '{}'::jsonb,
                      CASE WHEN blks_hit + blks_read = 0 THEN 1 ELSE blks_hit::float8 / (blks_hit + blks_read) END
                 FROM pg_stat_database WHERE datname = current_database();
  RETURN QUERY SELECT 'masslak_db_wal_bytes_total', '{}'::jsonb, pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0')::float8;
  RETURN QUERY SELECT 'masslak_db_size_bytes', '{}'::jsonb, pg_database_size(current_database())::float8;
  RETURN QUERY SELECT 'masslak_db_xid_age', '{}'::jsonb, age(datfrozenxid)::float8 FROM pg_database WHERE datname = current_database();
  RETURN QUERY SELECT 'masslak_db_replication_lag_seconds', jsonb_build_object('standby', coalesce(r.application_name, '')),
                      coalesce(extract(epoch FROM r.replay_lag), 0)::float8 FROM pg_stat_replication r;
  -- the ten tables with the most dead rows, and how long ago they were vacuumed
  RETURN QUERY SELECT 'masslak_db_dead_tuples', jsonb_build_object('table', t.schemaname || '.' || t.relname), t.n_dead_tup::float8
                 FROM (SELECT * FROM pg_stat_user_tables ORDER BY n_dead_tup DESC LIMIT 10) t;
  RETURN QUERY SELECT 'masslak_db_vacuum_age_seconds', jsonb_build_object('table', t.schemaname || '.' || t.relname),
                      coalesce(extract(epoch FROM now() - greatest(t.last_vacuum, t.last_autovacuum)), -1)::float8
                 FROM pg_stat_user_tables t
                WHERE t.schemaname || '.' || t.relname IN ('ops.seat_segment', 'sales.booking', 'sales.ticket', 'fin.ledger_entry',
                                                           'fin.wallet', 'sys.outbox_event', 'sys.webhook_delivery');
END $$;
REVOKE ALL ON FUNCTION sys.ops_metrics() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sys.ops_metrics() TO masslak_app, masslak_readonly;
COMMENT ON FUNCTION sys.ops_metrics IS 'Operational metrics for the monitoring scrape (/api/metrics, deploy/monitoring) (audit T3-16)';

INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('sys.job_run', '1A', 'E03')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
INSERT INTO gov.data_inventory (dataset, data_class, owner, purpose, legal_basis, retention_days, erasure_method, copies, backup_retention_days)
VALUES ('sys.job_run', 'INTERNAL', 'sys', 'Runs of scheduled jobs, for monitoring', 'Legitimate interest', 400, 'DELETE', '{backup}', 35)
ON CONFLICT (dataset) DO NOTHING;

-- =====================================================================
-- B  T3-05: sensitive scheduled reports go by short-lived link, with consent and a download log
-- =====================================================================
ALTER TABLE rpt.report_schedule
  ADD COLUMN IF NOT EXISTS sensitive boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS consent_by bigint REFERENCES iam.app_user(id),
  ADD COLUMN IF NOT EXISTS consent_at timestamptz;
CREATE INDEX IF NOT EXISTS report_schedule_consent_by_fkx ON rpt.report_schedule (consent_by);
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'rpt.report_schedule'::regclass AND conname = 'report_schedule_sensitive_consent') THEN
    ALTER TABLE rpt.report_schedule ADD CONSTRAINT report_schedule_sensitive_consent
      CHECK (NOT sensitive OR (consent_by IS NOT NULL AND consent_at IS NOT NULL));
  END IF;
END $$;
COMMENT ON COLUMN rpt.report_schedule.sensitive IS 'The report holds personal or financial columns: sent as a short-lived link to named accounts only, never as an attachment (audit T3-05)';

CREATE TABLE IF NOT EXISTS rpt.report_delivery (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                  uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  schedule_id          bigint NOT NULL REFERENCES rpt.report_schedule(id),
  report_run_id        bigint NOT NULL REFERENCES rpt.report_run(id),
  recipient            text NOT NULL,
  recipient_user_id    bigint NOT NULL REFERENCES iam.app_user(id),
  file_id              bigint NOT NULL REFERENCES ref.file_object(id),
  file_name            text NOT NULL,
  token_hash           bytea NOT NULL UNIQUE,
  expires_at           timestamptz NOT NULL,
  first_downloaded_at  timestamptz,
  last_downloaded_at   timestamptz,
  download_count       int NOT NULL DEFAULT 0 CHECK (download_count >= 0),
  revoked_at           timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS report_delivery_schedule_id_fkx ON rpt.report_delivery (schedule_id);
CREATE INDEX IF NOT EXISTS report_delivery_report_run_id_fkx ON rpt.report_delivery (report_run_id);
CREATE INDEX IF NOT EXISTS report_delivery_recipient_user_id_fkx ON rpt.report_delivery (recipient_user_id);
CREATE INDEX IF NOT EXISTS report_delivery_file_id_fkx ON rpt.report_delivery (file_id);
COMMENT ON TABLE rpt.report_delivery IS 'One link per recipient of a sensitive scheduled report: only a hash of the token is kept; every download is counted and logged (audit T3-05)';
SELECT sys.rls('rpt.report_delivery', 'sys.ctx_is_platform()');      -- downloads go through the API, which checks the recipient
GRANT SELECT, INSERT, UPDATE ON rpt.report_delivery TO masslak_app;
GRANT SELECT ON rpt.report_delivery TO masslak_readonly, masslak_auditor;
DROP TRIGGER IF EXISTS forbid_delete ON rpt.report_delivery;
CREATE TRIGGER forbid_delete BEFORE DELETE ON rpt.report_delivery FOR EACH ROW EXECUTE FUNCTION sys.tg_forbid_mutation();

INSERT INTO sys.setting (key, value, description) VALUES
  ('reports.link_hours', '72', 'Hours a link to a sensitive scheduled report stays valid (audit T3-05)')
ON CONFLICT (key) DO NOTHING;
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('rpt.report_delivery', '1B', 'E38')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;

-- =====================================================================
-- C  T3-11: positions bound to the driver's registered device; device attestation prepared, switched by configuration
-- =====================================================================
ALTER TABLE ops.geo_event ADD COLUMN IF NOT EXISTS device_id bigint REFERENCES iam.device(id);
CREATE INDEX IF NOT EXISTS geo_event_device_id_fkx ON ops.geo_event (device_id) WHERE device_id IS NOT NULL;
COMMENT ON COLUMN ops.geo_event.device_id IS 'The registered installation that sent the position (from the mobile session); none from the web page (audit T3-11)';
ALTER TABLE iam.device ADD COLUMN IF NOT EXISTS attested_at timestamptz, ADD COLUMN IF NOT EXISTS attestation_provider text;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'iam.device'::regclass AND conname = 'device_attestation_provider_check') THEN
    ALTER TABLE iam.device ADD CONSTRAINT device_attestation_provider_check
      CHECK (attestation_provider IS NULL OR attestation_provider IN ('PLAY_INTEGRITY', 'APP_ATTEST', 'SIMULATED'));
  END IF;
END $$;
INSERT INTO sys.compliance_requirement (code, domain, applies_to, level, authority, description) VALUES
  ('tracking.device_attestation', 'TRACKING', 'ALL', 'OFF', NULL,
   'Positions count as evidence only from a registered device that passed platform attestation (Play Integrity, App Attest)')
ON CONFLICT (code) DO NOTHING;

-- The trust grade adds the device checks to the checks of 1048
CREATE OR REPLACE FUNCTION ops.tg_geo_event_trust() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  prev record; flags text[] := '{}'; km float8; hrs float8; att text;
  acc_low real := coalesce((SELECT value::real FROM sys.setting WHERE key = 'tracking.max_accuracy_m'), 50);
  acc_bad real := coalesce((SELECT value::real FROM sys.setting WHERE key = 'tracking.reject_accuracy_m'), 500);
  vmax float8 := coalesce((SELECT value::float8 FROM sys.setting WHERE key = 'tracking.max_speed_kmh'), 200);
  late int := coalesce((SELECT value::int FROM sys.setting WHERE key = 'tracking.late_minutes'), 10);
BEGIN
  NEW.received_at := now();
  -- a position the device resends (same event id) is dropped quietly: the insert returns no row
  IF NEW.event_id IS NOT NULL AND EXISTS (SELECT 1 FROM ops.geo_event g WHERE g.event_id = NEW.event_id AND g.ts > NEW.ts - interval '8 days'
                                            AND g.ts < NEW.ts + interval '8 days') THEN
    RETURN NULL;
  END IF;
  IF NEW.is_mock THEN flags := array_append(flags, 'MOCK_LOCATION'); END IF;
  IF NEW.device_ts IS NOT NULL AND NEW.device_ts > NEW.received_at + interval '2 minutes' THEN flags := array_append(flags, 'FUTURE_TIME'); END IF;
  IF NEW.accuracy_m IS NOT NULL AND NEW.accuracy_m > acc_bad THEN flags := array_append(flags, 'NO_FIX'); END IF;
  IF NEW.accuracy_m IS NULL OR NEW.accuracy_m > acc_low THEN flags := array_append(flags, 'INACCURATE'); END IF;
  IF NEW.provider = 'NETWORK' THEN flags := array_append(flags, 'NETWORK_ONLY'); END IF;
  IF NEW.device_ts IS NOT NULL AND NEW.device_ts < NEW.received_at - make_interval(mins => late) THEN flags := array_append(flags, 'LATE'); END IF;
  -- the device: unknown, revoked, failed attestation, or (when required) not attested
  IF NEW.device_id IS NULL THEN
    IF sys.requirement_enforced('tracking.device_attestation', current_date) THEN flags := array_append(flags, 'NO_DEVICE'); END IF;
  ELSE
    SELECT CASE WHEN d.revoked_at IS NOT NULL THEN 'REVOKED' ELSE d.attestation_state END INTO att FROM iam.device d WHERE d.id = NEW.device_id;
    IF att IN ('REVOKED', 'FAILED') THEN
      flags := array_append(flags, 'DEVICE_' || att);
    ELSIF att <> 'PASSED' AND sys.requirement_enforced('tracking.device_attestation', current_date) THEN
      flags := array_append(flags, 'NOT_ATTESTED');
    END IF;
  END IF;
  IF NEW.vehicle_id IS NOT NULL THEN
    SELECT g.ts, g.lat, g.lng, g.seq INTO prev FROM ops.geo_event g
     WHERE g.vehicle_id = NEW.vehicle_id AND g.ts <= NEW.ts AND g.ts > NEW.ts - interval '1 day' AND g.trust <> 'REJECTED'
     ORDER BY g.ts DESC LIMIT 1;
    IF FOUND THEN
      IF NEW.seq IS NOT NULL AND prev.seq IS NOT NULL AND NEW.seq <= prev.seq THEN flags := array_append(flags, 'OUT_OF_ORDER'); END IF;
      km := 2 * 6371 * asin(sqrt(power(sin(radians(NEW.lat - prev.lat) / 2), 2)
                                 + cos(radians(prev.lat)) * cos(radians(NEW.lat)) * power(sin(radians(NEW.lng - prev.lng) / 2), 2)));
      hrs := greatest(extract(epoch FROM NEW.ts - prev.ts) / 3600.0, 1.0 / 3600);
      IF km > 0.2 AND km / hrs > vmax THEN flags := array_append(flags, 'IMPOSSIBLE_SPEED'); END IF;
    END IF;
  END IF;
  NEW.trust_flags := flags;
  NEW.trust := CASE WHEN flags && ARRAY['MOCK_LOCATION','FUTURE_TIME','NO_FIX','DEVICE_REVOKED','DEVICE_FAILED'] THEN 'REJECTED'
                    WHEN cardinality(flags) > 0 THEN 'LOW' ELSE 'HIGH' END;
  RETURN NEW;
END $$;

-- People who review violations built on low-trust positions
INSERT INTO iam.permission (code, module, scope, description, is_sensitive) VALUES
  ('violation.review', 'compliance', 'PLATFORM', 'Review route violations whose evidence is graded low-trust before they count (audit T3-11)', true),
  ('events.replay_approve', 'integration', 'PLATFORM', 'Approve resending a money or authority event to a partner (audit T3-12)', true)
ON CONFLICT (code) DO NOTHING;
INSERT INTO iam.role_permission (role_id, permission_code)
SELECT r.id, p.code FROM iam.role r, (VALUES ('violation.review', 'PLATFORM_ADMIN'), ('violation.review', 'REGULATOR'),
                                            ('events.replay_approve', 'PLATFORM_ADMIN'), ('events.replay_approve', 'PLATFORM_FINANCE')) p(code, role)
 WHERE r.code = p.role
ON CONFLICT DO NOTHING;

-- =====================================================================
-- D  T3-12: resending a money or authority event needs a platform approval; payments reconcile daily
-- =====================================================================
CREATE TABLE IF NOT EXISTS sys.delivery_retry_request (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid             uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  delivery_id     bigint NOT NULL REFERENCES sys.webhook_delivery(id),
  event_type      text NOT NULL,
  api_client_id   bigint REFERENCES iam.api_client(id),
  requested_by    bigint REFERENCES iam.app_user(id),
  reason          text NOT NULL CHECK (length(btrim(reason)) >= 5),
  status          text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','APPROVED','REJECTED')),
  decided_by      bigint REFERENCES iam.app_user(id),
  decided_at      timestamptz,
  decision_note   text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  CHECK (num_nonnulls(api_client_id, requested_by) >= 1),
  CHECK ((status = 'PENDING') = (decided_at IS NULL)),
  CHECK (decided_by IS NULL OR decided_by IS DISTINCT FROM requested_by)
);
CREATE INDEX IF NOT EXISTS delivery_retry_request_delivery_id_fkx ON sys.delivery_retry_request (delivery_id);
CREATE INDEX IF NOT EXISTS delivery_retry_request_api_client_id_fkx ON sys.delivery_retry_request (api_client_id);
CREATE INDEX IF NOT EXISTS delivery_retry_request_requested_by_fkx ON sys.delivery_retry_request (requested_by);
CREATE INDEX IF NOT EXISTS delivery_retry_request_decided_by_fkx ON sys.delivery_retry_request (decided_by);
CREATE UNIQUE INDEX IF NOT EXISTS delivery_retry_request_one_open ON sys.delivery_retry_request (delivery_id) WHERE status = 'PENDING';
COMMENT ON TABLE sys.delivery_retry_request IS 'A request to resend a money or authority event to a partner: applied only after a platform approval (audit T3-12)';
SELECT sys.rls('sys.delivery_retry_request', 'sys.ctx_is_platform()');
GRANT SELECT, INSERT, UPDATE ON sys.delivery_retry_request TO masslak_app;
GRANT SELECT ON sys.delivery_retry_request TO masslak_readonly, masslak_auditor;
DROP TRIGGER IF EXISTS forbid_delete ON sys.delivery_retry_request;
CREATE TRIGGER forbid_delete BEFORE DELETE ON sys.delivery_retry_request FOR EACH ROW EXECUTE FUNCTION sys.tg_forbid_mutation();

-- Independent reconciliation of payments, refunds, provider notices and the ledger
CREATE OR REPLACE FUNCTION fin.reconcile_payments() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, pg_temp AS $$
  SELECT jsonb_build_object(
    'refunded_amount_mismatch', (SELECT count(*) FROM fin.payment p
        WHERE p.refunded_amount <> coalesce((SELECT sum(r.amount) FROM fin.payment_refund r WHERE r.payment_id = p.id AND r.status = 'SUCCESS'), 0)),
    'refund_without_ledger', (SELECT count(*) FROM fin.payment_refund WHERE status = 'SUCCESS' AND ledger_txn_id IS NULL),
    'payment_without_ledger', (SELECT count(*) FROM fin.payment WHERE status IN ('SUCCESS', 'REFUNDED') AND ledger_txn_id IS NULL),
    'ledger_currency_mismatch', (SELECT count(*) FROM fin.payment p JOIN fin.ledger_txn t ON t.id = p.ledger_txn_id WHERE t.currency <> p.currency),
    'notice_not_applied', (SELECT count(*) FROM fin.payment_notification n
        WHERE n.signature_valid AND n.payment_id IS NOT NULL AND n.processed_at IS NULL AND n.received_at < now() - interval '1 hour'),
    'at', now())
$$;
COMMENT ON FUNCTION fin.reconcile_payments IS 'Payments, refunds, provider notices and ledger agree; run daily by the upkeep, a non-zero count raises an alert (audit T3-12)';

-- The upkeep runs it and raises an alert on any mismatch
CREATE OR REPLACE FUNCTION sys.run_maintenance() RETURNS jsonb LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE rid bigint; out jsonb; pay jsonb; bad bigint;
BEGIN
  INSERT INTO sys.job_run (job) VALUES ('maintenance') RETURNING id INTO rid;
  out := sys.run_maintenance_body();
  pay := fin.reconcile_payments();
  SELECT coalesce(sum(value::bigint), 0) INTO bad FROM jsonb_each_text(pay - 'at');
  IF bad > 0 THEN
    INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, payload)
    VALUES ('integrity.payments_mismatch', 'job_run', rid, pay);
  END IF;
  out := out || jsonb_build_object('payments', pay, 'payment_mismatches', bad);
  UPDATE sys.job_run SET finished_at = clock_timestamp(), detail = out,
         ok = coalesce((out ->> 'wallet_mismatches')::int, 0) = 0 AND bad = 0
              AND coalesce((out -> 'orphans')::text, 'null') IN ('null', '0')
   WHERE id = rid;
  RETURN out;
END $$;

INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('sys.delivery_retry_request', '1B', 'E03')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;

INSERT INTO sys.json_contract (table_name, column_name, kind, version, note) VALUES
  ('sys.job_run', 'detail', 'PAYLOAD', 1, 'The result a scheduled job returned')
ON CONFLICT DO NOTHING;
SELECT sys.apply_json_contracts();

INSERT INTO sys.schema_migration (version, description)
SELECT '1.31.0', 'Re-audit of design 3.8: operational metrics and job runs, sensitive report links, device-bound positions, approved resends of money events, payment reconciliation'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.31.0');

SELECT sys.refresh_table_class();
