-- 1178: a government body's own systems look a vehicle up by its movement code (N47, N48).
--
-- A body that links its applications calls the integration API v1 with a client of kind AUTHORITY tied to it, and the
-- scope roadside:scan. Each lookup is a roadside check like an officer's scan, recorded in fleet.field_check_log with
-- the body beside it, but made by the client rather than by a person's account: the row names the API client and the
-- body's own reference for its officer (its badge or system id), and is closed when made, as single lookups were
-- before 1169. Exactly one of the officer's account and the API client is named.

ALTER TABLE fleet.field_check_log
  ALTER COLUMN inspector_user_id DROP NOT NULL,
  ADD COLUMN IF NOT EXISTS api_client_id bigint REFERENCES iam.api_client(id),
  ADD COLUMN IF NOT EXISTS officer_ref text CHECK (officer_ref IS NULL OR length(officer_ref) BETWEEN 1 AND 60);
ALTER TABLE fleet.field_check_log DROP CONSTRAINT IF EXISTS field_check_log_who;
ALTER TABLE fleet.field_check_log ADD CONSTRAINT field_check_log_who
  CHECK (num_nonnulls(inspector_user_id, api_client_id) = 1);
CREATE INDEX IF NOT EXISTS field_check_log_api_client_id_fkx ON fleet.field_check_log (api_client_id);
COMMENT ON COLUMN fleet.field_check_log.api_client_id IS
  'The API client of a government body that made the lookup, when a body''s system made it instead of an officer''s account (1178)';
COMMENT ON COLUMN fleet.field_check_log.officer_ref IS
  'The body''s own reference for the officer behind an API lookup (badge or system id), as the body sent it (1178)';

-- what the scan found, and who made it, is never changed
CREATE OR REPLACE FUNCTION fleet.tg_field_check_log() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'FIELD_CHECK_KEPT: a roadside check is never deleted' USING ERRCODE = 'P0001';
  END IF;
  IF OLD.status = 'CLOSED' THEN
    RAISE EXCEPTION 'FIELD_CHECK_CLOSED: a closed roadside check is never changed' USING ERRCODE = 'P0001';
  END IF;
  IF (NEW.uid, NEW.inspector_user_id, NEW.api_client_id, NEW.officer_ref, NEW.vehicle_id, NEW.method, NEW.result, NEW.lat,
      NEW.lng, NEW.created_at, NEW.tag_id, NEW.movement_kind, NEW.movement_ref, NEW.trip_id, NEW.warnings)
     IS DISTINCT FROM (OLD.uid, OLD.inspector_user_id, OLD.api_client_id, OLD.officer_ref, OLD.vehicle_id, OLD.method, OLD.result,
      OLD.lat, OLD.lng, OLD.created_at, OLD.tag_id, OLD.movement_kind, OLD.movement_ref, OLD.trip_id, OLD.warnings) THEN
    RAISE EXCEPTION 'FIELD_CHECK_FIXED: what the scan found is never changed' USING ERRCODE = 'P0001';
  END IF;
  IF OLD.sample_mode <> 'NONE' AND (NEW.sample_mode <> OLD.sample_mode
     OR jsonb_array_length(NEW.sample) <> jsonb_array_length(OLD.sample)
     OR (SELECT array_agg(e ->> 'ticket' ORDER BY e ->> 'ticket') FROM jsonb_array_elements(NEW.sample) e)
        IS DISTINCT FROM (SELECT array_agg(e ->> 'ticket' ORDER BY e ->> 'ticket') FROM jsonb_array_elements(OLD.sample) e)) THEN
    RAISE EXCEPTION 'FIELD_CHECK_SAMPLE_FIXED: the people drawn for a check are not changed' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.status = 'CLOSED' THEN
    IF NEW.outcome IS NULL THEN
      RAISE EXCEPTION 'FIELD_CHECK_OUTCOME: a check closes with its outcome' USING ERRCODE = 'P0001';
    END IF;
    NEW.closed_at := now();
  END IF;
  RETURN NEW;
END $$;
