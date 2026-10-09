-- =====================================================================
-- 1073: only a signed provider notice takes its event id (review of release 1.47.0, R-18)
-- =====================================================================
-- Every notice a provider endpoint receives is kept, signed or not, for the security review. Its event id was unique
-- over all of them, and the row was written before the signature was judged: anyone who knew or guessed a coming
-- event id could post it first with a bad signature, and the provider's real notice was then taken for a replay and
-- never settled the payment. The event id is now unique among signed notices only; unsigned ones are kept as they
-- come and can never stand in for a signed one.
ALTER TABLE fin.payment_notification DROP CONSTRAINT IF EXISTS payment_notification_provider_id_event_id_key;
DROP INDEX IF EXISTS fin.payment_notification_event_uq;
CREATE UNIQUE INDEX payment_notification_event_uq ON fin.payment_notification (provider_id, event_id) WHERE signature_valid;
COMMENT ON INDEX fin.payment_notification_event_uq IS
  'A provider event settles once: unique among signed notices only, so an unsigned copy cannot take the id first (1073, R-18)';
CREATE INDEX IF NOT EXISTS payment_notification_unsigned_idx ON fin.payment_notification (received_at)
  WHERE NOT signature_valid;
COMMENT ON INDEX fin.payment_notification_unsigned_idx IS 'Unsigned notices by arrival, for the security review and the alert (1073)';

-- How many unsigned notices arrived in the last hour, per provider: a burst is someone probing the endpoint
CREATE OR REPLACE FUNCTION fin.unsigned_notices(p_since interval DEFAULT interval '1 hour')
RETURNS TABLE (provider_code text, notices bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT p.code, count(*) FROM fin.payment_notification n JOIN fin.payment_provider p ON p.id = n.provider_id
   WHERE NOT n.signature_valid AND n.received_at > now() - p_since
   GROUP BY p.code
$$;
COMMENT ON FUNCTION fin.unsigned_notices(interval) IS 'Unsigned provider notices per provider over a recent window (1073, R-18)';
REVOKE EXECUTE ON FUNCTION fin.unsigned_notices(interval) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fin.unsigned_notices(interval) TO masslak_app;

INSERT INTO sys.schema_migration (version, description)
SELECT '1.48.0', 'Review of release 1.47.0: signed notices own their event id, and the fixes of packages A to H'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.48.0');
