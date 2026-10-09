-- =====================================================================
-- 1069: how far the signed audit archive lags behind the logs (third-party follow-up of October 2026)
-- =====================================================================
-- The hourly export to storage with object lock was written in the runbook only and nothing noticed when it did not
-- run. For each audit log, masslak_audit_unarchived_seconds is the age of its oldest row that no recorded archive
-- covers yet (audit.archive_checkpoint, written by app.tools.audit_export record after a sync). It grows when the
-- export, the sync or the record stops, and also on a server where archiving was never set up, so the alert
-- AuditArchiveBehind catches both. Each value is one index lookup per log.

CREATE OR REPLACE FUNCTION audit.archive_metrics() RETURNS TABLE (metric text, labels jsonb, value float8)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  t record;
  first_ts timestamptz;
  covered bigint;
BEGIN
  FOR t IN SELECT * FROM (VALUES ('audit.activity_log', 'ts'), ('audit.row_change', 'ts'), ('audit.data_access_log', 'ts'),
                                 ('audit.auth_event', 'ts'), ('audit.ddl_event', 'occurred_at'),
                                 ('audit.log_seal', 'created_at')) v(tbl, col) LOOP
    covered := coalesce((SELECT max(c.through_id) FROM audit.archive_checkpoint c WHERE c.table_name = t.tbl), 0);
    EXECUTE format('SELECT %I FROM %s WHERE id > $1 ORDER BY id LIMIT 1', t.col, t.tbl) INTO first_ts USING covered;
    metric := 'masslak_audit_unarchived_seconds';
    labels := jsonb_build_object('table', t.tbl);
    value := greatest(coalesce(extract(epoch FROM now() - first_ts), 0), 0);
    RETURN NEXT;
  END LOOP;
  -- seconds since the last recorded archive, -1 when none was ever recorded
  metric := 'masslak_audit_archive_recorded_age_seconds';
  labels := '{}'::jsonb;
  value := coalesce(extract(epoch FROM now() - (SELECT max(c.recorded_at) FROM audit.archive_checkpoint c)), -1);
  RETURN NEXT;
END $$;
COMMENT ON FUNCTION audit.archive_metrics() IS 'Archive lag per audit log for the metrics endpoint (1069): age of the oldest row no recorded archive covers';
REVOKE EXECUTE ON FUNCTION audit.archive_metrics() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION audit.archive_metrics() TO masslak_app, masslak_readonly;
