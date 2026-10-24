-- =====================================================================
-- Masslak - 1114: the trip number passengers read, as airlines do (owner's decision, October 2026)
-- A trip is known to passengers by a short number: the carrier's trip designator and a service number, "QD 214". It is
-- what tickets, passes and the station screens print. The same departure (route and time) keeps its number every day,
-- and a carrier never gives one number to two trips of the same day, so a vehicle that runs several trips in a day runs
-- them under different numbers. The long number (trip_no, "QDS-DAM-ALP-1400/19OCT26") stays the trip's unique reference.
--   * The designator is the carrier's two-character code (net.carrier_code.code2, set by the platform when it defines
--     the company) or, without one, its three-letter code (study 4.16 a).
--   * The number is the service number of the trip or of its template (net.service_number, study 4.16 b). A trip made
--     by hand takes the number the same route had at the same local time on the nearest other day (within 60 days), or
--     else the lowest free number of the extra block (5000 to 9999) that is not one of the carrier's service numbers.
--   * service_date is the trip's day where it starts (its first station's time zone). The number is unique for a carrier
--     on a service date among trips not cancelled; the code is kept as printed, should the designator change later.
--   * A service number serves one template at a time on the same days, so two departures of a day never share it.
-- =====================================================================

ALTER TABLE ops.trip ADD COLUMN IF NOT EXISTS service_date date;
ALTER TABLE ops.trip ADD COLUMN IF NOT EXISTS service_no integer CHECK (service_no BETWEEN 1 AND 9999);
ALTER TABLE ops.trip ADD COLUMN IF NOT EXISTS trip_code text CHECK (trip_code ~ '^[A-Z0-9]{2,3} [0-9]{1,4}[A-Z]?$');
COMMENT ON COLUMN ops.trip.service_date IS 'The trip''s day where it starts, in its first station''s time zone (1114)';
COMMENT ON COLUMN ops.trip.service_no IS 'The service number of the trip, the same for the same departure every day, unique for the carrier on a service date (1114)';
COMMENT ON COLUMN ops.trip.trip_code IS 'The trip number passengers read: the carrier''s designator and the service number, "QD 214", as printed on tickets and screens; trip_no is the trip''s reference (1114)';

-- whether a number is free for a carrier on a day (trips not cancelled; the trip itself aside)
CREATE OR REPLACE FUNCTION ops.trip_number_free(p_company bigint, p_day date, p_no integer, p_suffix text, p_trip bigint)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT NOT EXISTS (SELECT 1 FROM ops.trip t
                      WHERE t.company_id = p_company AND t.service_date = p_day AND t.service_no = p_no
                        AND coalesce(t.section_suffix::text, '') = coalesce(p_suffix, '') AND t.status <> 'CANCELLED'
                        AND t.id IS DISTINCT FROM p_trip)
$$;

-- the number of a trip that has no service number: the one of the same route at the same local time on the nearest
-- other day, else the lowest free number of the extra block that is not one of the carrier's service numbers that day
CREATE OR REPLACE FUNCTION ops.pick_service_no(p_company bigint, p_route bigint, p_departure timestamptz, p_day date,
                                               p_suffix text, p_trip bigint) RETURNS integer
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_tz text; v_no integer;
BEGIN
  v_tz := coalesce(ref.station_tz((SELECT r.origin_station_id FROM net.route r WHERE r.id = p_route)), 'UTC');
  SELECT t.service_no INTO v_no FROM ops.trip t
   WHERE t.company_id = p_company AND t.route_id = p_route AND t.service_no IS NOT NULL AND t.status <> 'CANCELLED'
     AND t.service_date BETWEEN p_day - 60 AND p_day + 60 AND t.service_date <> p_day
     AND (t.departure_at AT TIME ZONE v_tz)::time = (p_departure AT TIME ZONE v_tz)::time
     AND ops.trip_number_free(p_company, p_day, t.service_no, p_suffix, p_trip)
   ORDER BY abs(t.service_date - p_day), t.service_date DESC LIMIT 1;
  IF v_no IS NOT NULL THEN
    RETURN v_no;
  END IF;
  SELECT n INTO v_no FROM generate_series(5000, 9999) n
   WHERE ops.trip_number_free(p_company, p_day, n, p_suffix, p_trip)
     AND NOT EXISTS (SELECT 1 FROM net.service_number s WHERE s.company_id = p_company AND s.number = n AND s.valid @> p_day)
   ORDER BY n LIMIT 1;
  RETURN v_no;
END $$;

-- the carrier's designator: its two-character code, else its three-letter code
CREATE OR REPLACE FUNCTION ops.trip_designator(p_company bigint) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT btrim(coalesce(cc.code2, cc.code3)) FROM net.carrier_code cc WHERE cc.company_id = p_company AND cc.status = 'ACTIVE'
$$;

CREATE OR REPLACE FUNCTION ops.tg_trip_number() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_designator text;
BEGIN
  IF NEW.service_date IS NULL THEN
    NEW.service_date := (NEW.departure_at AT TIME ZONE coalesce(ref.station_tz(
                          (SELECT r.origin_station_id FROM net.route r WHERE r.id = NEW.route_id)), 'UTC'))::date;
  END IF;
  IF NEW.service_no IS NULL THEN
    NEW.service_number_id := coalesce(NEW.service_number_id,
                                      (SELECT tt.service_number_id FROM ops.trip_template tt WHERE tt.id = NEW.template_id));
    IF NEW.service_number_id IS NOT NULL THEN       -- a service number is used as it is: a clash that day is refused
      NEW.service_no := (SELECT s.number FROM net.service_number s WHERE s.id = NEW.service_number_id);
    ELSE                                            -- one carrier picks one number at a time
      PERFORM pg_advisory_xact_lock(hashtextextended('ops.trip service_no ' || NEW.company_id, 0));
      NEW.service_no := ops.pick_service_no(NEW.company_id, NEW.route_id, NEW.departure_at, NEW.service_date,
                                            NEW.section_suffix::text, NULL);
    END IF;
  END IF;
  IF NEW.trip_code IS NULL AND NEW.service_no IS NOT NULL THEN
    v_designator := ops.trip_designator(NEW.company_id);
    IF v_designator IS NOT NULL THEN
      NEW.trip_code := v_designator || ' ' || NEW.service_no || coalesce(NEW.section_suffix::text, '');
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS a_trip_number ON ops.trip;
CREATE TRIGGER a_trip_number BEFORE INSERT ON ops.trip FOR EACH ROW EXECUTE FUNCTION ops.tg_trip_number();

-- the trips there are: their day, and a number free that day (a template's number first, as above)
DO $$
DECLARE r record; v_no integer;
BEGIN
  FOR r IN SELECT t.id, t.company_id, t.route_id, t.departure_at, t.section_suffix::text AS suffix, t.status,
                  coalesce(t.service_number_id, tt.service_number_id) AS service_number_id,
                  (t.departure_at AT TIME ZONE coalesce(ref.station_tz(rt.origin_station_id), 'UTC'))::date AS day
             FROM ops.trip t JOIN net.route rt ON rt.id = t.route_id LEFT JOIN ops.trip_template tt ON tt.id = t.template_id
            WHERE t.service_no IS NULL
            ORDER BY t.departure_at, t.id LOOP
    UPDATE ops.trip SET service_date = r.day WHERE id = r.id;
    v_no := (SELECT s.number FROM net.service_number s WHERE s.id = r.service_number_id);
    IF v_no IS NULL OR (r.status <> 'CANCELLED' AND NOT ops.trip_number_free(r.company_id, r.day, v_no, r.suffix, r.id)) THEN
      v_no := ops.pick_service_no(r.company_id, r.route_id, r.departure_at, r.day, r.suffix, r.id);
    END IF;
    UPDATE ops.trip SET service_no = v_no,
                        trip_code = (SELECT d || ' ' || v_no || coalesce(r.suffix, '') FROM ops.trip_designator(r.company_id) d
                                      WHERE d IS NOT NULL AND v_no IS NOT NULL)
     WHERE id = r.id;
  END LOOP;
END $$;
ALTER TABLE ops.trip ALTER COLUMN service_date SET NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS trip_number_day_uq ON ops.trip (company_id, service_date, service_no, (coalesce(section_suffix::text, '')))
  WHERE status <> 'CANCELLED';
CREATE INDEX IF NOT EXISTS trip_route_day_idx ON ops.trip (company_id, route_id, service_date);

-- a service number serves one template at a time on the same days
CREATE OR REPLACE FUNCTION ops.tg_template_service_number() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.service_number_id IS NOT NULL AND NEW.status <> 'RETIRED' AND EXISTS (
       SELECT 1 FROM ops.trip_template o
        WHERE o.service_number_id = NEW.service_number_id AND o.id <> NEW.id AND o.status <> 'RETIRED'
          AND o.active && NEW.active AND o.days_of_week && NEW.days_of_week) THEN
    RAISE EXCEPTION 'SERVICE_NUMBER_TAKEN: another template runs under this service number on the same days' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS template_service_number ON ops.trip_template;
CREATE TRIGGER template_service_number BEFORE INSERT OR UPDATE OF service_number_id, status, active, days_of_week ON ops.trip_template
  FOR EACH ROW EXECUTE FUNCTION ops.tg_template_service_number();

REVOKE ALL ON FUNCTION ops.trip_number_free(bigint, date, integer, text, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.pick_service_no(bigint, bigint, timestamptz, date, text, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.trip_designator(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.trip_designator(bigint) TO masslak_app;
COMMENT ON FUNCTION ops.trip_number_free IS 'Whether a service number is free for a carrier on a service date (1114)';
COMMENT ON FUNCTION ops.pick_service_no IS 'The number of a trip without a service number: the same route''s at the same local time on the nearest other day, else the lowest free of the extra block (1114)';
COMMENT ON FUNCTION ops.trip_designator IS 'The carrier''s trip designator: its two-character code, else its three-letter code (1114)';
COMMENT ON FUNCTION ops.tg_trip_number IS 'Gives a new trip its service date, service number and the trip number passengers read (1114)';
COMMENT ON FUNCTION ops.tg_template_service_number IS 'A service number serves one template at a time on the same days (1114)';
