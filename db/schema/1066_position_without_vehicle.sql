-- =====================================================================
-- 1066: a position without a vehicle is graded again (found by the launch gate 4 rehearsal, 9 October 2026)
--   1063 passed the previous position's fields to ops.position_flags whether or not a previous position had been
--   looked up. For a position with no vehicle the lookup is skipped, PL/pgSQL refuses to read the record it never
--   assigned ("record prev is not assigned yet"), and the insert failed. Positions with a vehicle were not affected.
--   The previous position is now held in plain variables that start empty.
-- =====================================================================

CREATE OR REPLACE FUNCTION ops.tg_geo_event_trust() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE prev_ts timestamptz; prev_lat numeric; prev_lng numeric; prev_seq bigint;
BEGIN
  NEW.received_at := now();
  -- a position the device resends (same event id) is dropped quietly: the insert returns no row
  IF NEW.event_id IS NOT NULL AND EXISTS (SELECT 1 FROM ops.geo_event g WHERE g.event_id = NEW.event_id AND g.ts > NEW.ts - interval '8 days'
                                            AND g.ts < NEW.ts + interval '8 days') THEN
    RETURN NULL;
  END IF;
  IF NEW.vehicle_id IS NOT NULL THEN
    SELECT g.ts, g.lat, g.lng, g.seq INTO prev_ts, prev_lat, prev_lng, prev_seq FROM ops.geo_event g
     WHERE g.vehicle_id = NEW.vehicle_id AND g.ts <= NEW.ts AND g.ts > NEW.ts - interval '1 day' AND g.trust <> 'REJECTED'
     ORDER BY g.ts DESC LIMIT 1;
  END IF;
  NEW.trust_flags := ops.position_flags(NEW.ts, NEW.received_at, NEW.lat, NEW.lng, NEW.accuracy_m, NEW.provider, NEW.is_mock,
                                        NEW.device_ts, NEW.seq, NEW.device_id, prev_ts, prev_lat, prev_lng, prev_seq);
  NEW.trust := ops.position_trust(NEW.trust_flags);
  RETURN NEW;
END $$;

INSERT INTO sys.schema_migration (version, description)
SELECT '1.45.0', 'A position without a vehicle is graded again (regression of 1063, found by the launch gate 4 rehearsal)'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.45.0');
