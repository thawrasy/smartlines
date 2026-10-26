-- =====================================================================
-- Masslak - 1101: SOS and incident reports from the apps (a gap found by the review of the use cases, October 2026)
--
-- sec.sos_event and ops.incident existed, with screens for the carrier and the platform to read and close them, but no
-- app could write either. Two functions now do it, each checking who the caller is on the trip:
--   * sec.raise_sos: the driver assigned to the trip, or a passenger holding a ticket on it (as booker or traveller),
--     raises an SOS while the trip is under way (boarding, departed, or published and leaving within two hours).
--     A second press by the same person while their SOS is open returns the same SOS. The carrier's owners and the
--     platform's security staff are told at once (outbox event sos.raised).
--   * ops.report_incident: the driver assigned to the trip reports an incident on its vehicle. An open SOS of the
--     driver on the trip is linked to it. A SEVERE incident takes the vehicle out of service at once
--     (fleet.vehicle_service_status), as the table's design said; the carrier's owners are told, and the platform
--     too when the incident is severe or someone is injured (outbox event incident.reported).
-- A vehicle in an out-of-service or impound period can no longer be given to a trip that departs within the period
-- (the rule the design of fleet.vehicle_service_status stated, now checked).
-- =====================================================================

ALTER TABLE ops.incident ADD COLUMN IF NOT EXISTS description text;
DO $$ BEGIN
  ALTER TABLE ops.incident ADD CONSTRAINT incident_description_len CHECK (description IS NULL OR length(description) <= 2000);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
COMMENT ON COLUMN ops.incident.description IS 'What happened, in the reporter''s words (1101)';

-- The caller's relation to a trip: DRIVER (assigned crew), PASSENGER (booker or traveller of a live ticket), or NULL
CREATE OR REPLACE FUNCTION ops.trip_relation(p_trip_id bigint, p_user_id bigint) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT CASE
    WHEN EXISTS (SELECT 1 FROM ops.crew_assignment ca JOIN iam.app_user u ON u.party_id = ca.party_id
                  WHERE ca.trip_id = p_trip_id AND u.id = p_user_id AND ca.status <> 'RELEASED') THEN 'DRIVER'
    WHEN EXISTS (SELECT 1 FROM sales.ticket k JOIN sales.booking b ON b.id = k.booking_id
                   LEFT JOIN sales.passenger p ON p.id = k.passenger_id
                  WHERE k.trip_id = p_trip_id AND k.status <> 'CANCELLED'
                    AND (b.booker_user_id = p_user_id
                         OR (SELECT u.party_id FROM iam.app_user u WHERE u.id = p_user_id) IN (b.booker_party_id, p.party_id))) THEN 'PASSENGER'
  END
$$;
REVOKE ALL ON FUNCTION ops.trip_relation(bigint, bigint) FROM PUBLIC;
COMMENT ON FUNCTION ops.trip_relation IS 'Whether a user drives a trip or travels on it (booker or traveller of a live ticket); used by SOS and incidents (1101)';

CREATE OR REPLACE FUNCTION sec.raise_sos(p_trip_id bigint, p_lat numeric DEFAULT NULL, p_lng numeric DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v_user bigint := sys.ctx_user_id();
  v_trip record;
  v_role text;
  v_id bigint;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'SOS_NOT_ON_TRIP: an SOS needs a signed-in user' USING ERRCODE = 'P0001';
  END IF;
  IF (p_lat IS NULL) <> (p_lng IS NULL) OR p_lat NOT BETWEEN -90 AND 90 OR p_lng NOT BETWEEN -180 AND 180 THEN
    RAISE EXCEPTION 'SOS_BAD_POSITION: give both coordinates, or neither' USING ERRCODE = 'P0001';
  END IF;
  SELECT t.id, t.company_id, t.trip_no, t.status, t.departure_at, t.arrival_at, v.plate_no INTO v_trip
    FROM ops.trip t LEFT JOIN fleet.vehicle v ON v.id = t.vehicle_id WHERE t.id = p_trip_id;
  v_role := ops.trip_relation(p_trip_id, v_user);
  IF v_trip.id IS NULL OR v_role IS NULL THEN
    RAISE EXCEPTION 'SOS_NOT_ON_TRIP: only the trip''s driver or a passenger on it may raise an SOS' USING ERRCODE = 'P0001';
  END IF;
  IF NOT (v_trip.status IN ('BOARDING','DEPARTED')
          OR (v_trip.status = 'PUBLISHED' AND v_trip.departure_at < now() + interval '2 hours' AND v_trip.arrival_at > now())) THEN
    RAISE EXCEPTION 'SOS_TRIP_NOT_ACTIVE: the trip is not under way' USING ERRCODE = 'P0001';
  END IF;
  SELECT id INTO v_id FROM sec.sos_event
   WHERE trip_id = p_trip_id AND triggered_by = v_user AND status IN ('OPEN','ACKNOWLEDGED') ORDER BY id DESC LIMIT 1;
  IF v_id IS NOT NULL THEN
    IF p_lat IS NOT NULL THEN
      UPDATE sec.sos_event SET lat = p_lat, lng = p_lng WHERE id = v_id;
    END IF;
    RETURN jsonb_build_object('sos_id', v_id, 'repeated', true, 'role', v_role);
  END IF;
  INSERT INTO sec.sos_event (trip_id, triggered_by, lat, lng, notified)
  VALUES (p_trip_id, v_user, p_lat, p_lng, '["CARRIER","PLATFORM"]'::jsonb) RETURNING id INTO v_id;
  INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, company_id, payload)
  VALUES ('sos.raised', 'sos', v_id, v_trip.company_id,
          jsonb_build_object('sos_id', v_id, 'trip_no', v_trip.trip_no, 'plate_no', coalesce(v_trip.plate_no, '-'), 'role', v_role,
                             'where', coalesce(round(p_lat, 5)::text || ', ' || round(p_lng, 5)::text, '-')));
  RETURN jsonb_build_object('sos_id', v_id, 'repeated', false, 'role', v_role);
END $$;
REVOKE ALL ON FUNCTION sec.raise_sos(bigint, numeric, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sec.raise_sos(bigint, numeric, numeric) TO masslak_app;
COMMENT ON FUNCTION sec.raise_sos IS 'The trip''s driver or a passenger on it raises an SOS; a repeat while open returns the same one; the carrier and the platform are told (1101)';

CREATE OR REPLACE FUNCTION ops.report_incident(p_trip_id bigint, p_type text, p_severity text, p_injuries boolean,
                                               p_description text DEFAULT NULL, p_lat numeric DEFAULT NULL, p_lng numeric DEFAULT NULL,
                                               p_occurred_at timestamptz DEFAULT NULL, p_police_report_no text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v_user bigint := sys.ctx_user_id();
  v_party bigint;
  v_trip record;
  v_id bigint;
  v_sos bigint;
  v_out boolean := false;
BEGIN
  SELECT t.id, t.company_id, t.trip_no, t.vehicle_id, t.departure_at, v.plate_no INTO v_trip
    FROM ops.trip t LEFT JOIN fleet.vehicle v ON v.id = t.vehicle_id WHERE t.id = p_trip_id;
  IF v_trip.id IS NULL OR v_user IS NULL OR ops.trip_relation(p_trip_id, v_user) IS DISTINCT FROM 'DRIVER' THEN
    RAISE EXCEPTION 'INCIDENT_NOT_DRIVER: only the driver assigned to the trip reports an incident from the app' USING ERRCODE = 'P0001';
  END IF;
  IF p_occurred_at IS NOT NULL AND (p_occurred_at > now() + interval '5 minutes' OR p_occurred_at < v_trip.departure_at - interval '1 day') THEN
    RAISE EXCEPTION 'INCIDENT_BAD_TIME: the time of the incident is outside the trip' USING ERRCODE = 'P0001';
  END IF;
  SELECT party_id INTO v_party FROM iam.app_user WHERE id = v_user;
  INSERT INTO ops.incident (company_id, vehicle_id, trip_id, driver_party_id, type, severity, injuries, lat, lng, occurred_at,
                            police_report_no, reported_via, reported_by, description)
  VALUES (v_trip.company_id, v_trip.vehicle_id, p_trip_id, v_party, p_type, p_severity, coalesce(p_injuries, false), p_lat, p_lng,
          coalesce(p_occurred_at, now()), nullif(btrim(p_police_report_no), ''), 'DRIVER_APP', v_user, nullif(btrim(p_description), ''))
  RETURNING id INTO v_id;
  UPDATE sec.sos_event SET incident_id = v_id
   WHERE id = (SELECT max(id) FROM sec.sos_event WHERE trip_id = p_trip_id AND triggered_by = v_user
                AND status IN ('OPEN','ACKNOWLEDGED') AND incident_id IS NULL)
  RETURNING id INTO v_sos;
  -- a severe incident takes the vehicle out of service at once, unless a period is already open
  IF p_severity = 'SEVERE' AND v_trip.vehicle_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM fleet.vehicle_service_status s WHERE s.vehicle_id = v_trip.vehicle_id AND s.period @> now()) THEN
    INSERT INTO fleet.vehicle_service_status (company_id, vehicle_id, status, reason, incident_id)
    VALUES (v_trip.company_id, v_trip.vehicle_id, 'OUT_OF_SERVICE', 'Severe incident on trip ' || v_trip.trip_no, v_id);
    v_out := true;
  END IF;
  INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, company_id, payload)
  VALUES ('incident.reported', 'incident', v_id, v_trip.company_id,
          jsonb_build_object('incident_id', v_id, 'trip_no', v_trip.trip_no, 'plate_no', coalesce(v_trip.plate_no, '-'),
                             'incident_type', p_type, 'severity', p_severity, 'injuries', coalesce(p_injuries, false),
                             'out_of_service', v_out, 'platform', p_severity = 'SEVERE' OR coalesce(p_injuries, false)));
  RETURN jsonb_build_object('incident_id', v_id, 'sos_id', v_sos, 'vehicle_out_of_service', v_out);
END $$;
REVOKE ALL ON FUNCTION ops.report_incident(bigint, text, text, boolean, text, numeric, numeric, timestamptz, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.report_incident(bigint, text, text, boolean, text, numeric, numeric, timestamptz, text) TO masslak_app;
COMMENT ON FUNCTION ops.report_incident IS
  'The trip''s driver reports an incident; links the driver''s open SOS; a severe one takes the vehicle out of service; the carrier (and the platform when severe or injured) is told (1101)';

-- A vehicle in an out-of-service or impound period is not given to a trip departing within it
CREATE OR REPLACE FUNCTION ops.tg_trip_vehicle_in_service() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.vehicle_id IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.vehicle_id IS DISTINCT FROM OLD.vehicle_id)
     AND EXISTS (SELECT 1 FROM fleet.vehicle_service_status s
                  WHERE s.vehicle_id = NEW.vehicle_id AND s.status <> 'ACTIVE' AND s.period @> NEW.departure_at) THEN
    RAISE EXCEPTION 'VEHICLE_OUT_OF_SERVICE: the vehicle is out of service or impounded at the departure time' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
-- named to fire before the other checks of the row, so the reason given is this one
DROP TRIGGER IF EXISTS a_trip_vehicle_in_service ON ops.trip;
CREATE TRIGGER a_trip_vehicle_in_service BEFORE INSERT OR UPDATE OF vehicle_id ON ops.trip
  FOR EACH ROW EXECUTE FUNCTION ops.tg_trip_vehicle_in_service();
COMMENT ON FUNCTION ops.tg_trip_vehicle_in_service IS 'Refuses a vehicle that is out of service or impounded at the trip''s departure (1101)';
