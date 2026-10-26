-- =====================================================================
-- 1143: the trip reference names the trip number (owner's decision N43, October 2026)
--   The long reference of a trip (ops.trip.trip_no) was the carrier's code, the route, and the local time and day of
--   departure: "DCA-DAM-DRA-1330/24OCT26". It did not carry the number passengers read, and two numbers of the same
--   route and minute were told apart only by the minute. It is now the carrier's three-letter code, the trip's service
--   number (four digits, with its section letter), the route, then the local departure time and day:
--     DCA-1171-DAM-DRA-1330-24OCT26
--   * The database writes it when a trip is made without one (the API and regular trips leave it out), after the service
--     number is chosen, so the two never disagree. A reference given by hand is kept as given.
--   * It is the trip's identity, printed on tickets and manifests: a later change of time or vehicle (N42) never rewrites
--     it, and references already issued keep their old form.
-- =====================================================================

-- the reference of a new trip: code3, number, route, local time and day where it starts (called by the trigger below,
-- with its owner's rights; granted to no one)
CREATE OR REPLACE FUNCTION ops.trip_reference(p_company bigint, p_service_no integer, p_suffix text, p_route bigint,
                                              p_departure timestamptz) RETURNS text
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT upper(coalesce((SELECT cc.code3::text FROM net.carrier_code cc WHERE cc.company_id = p_company AND cc.status = 'ACTIVE'),
                        'XXX')
               || '-' || lpad(p_service_no::text, 4, '0') || coalesce(p_suffix, '')
               || '-' || r.code
               || '-' || to_char(p_departure AT TIME ZONE coalesce(ref.station_tz(r.origin_station_id), 'UTC'), 'HH24MI')
               || '-' || to_char(p_departure AT TIME ZONE coalesce(ref.station_tz(r.origin_station_id), 'UTC'), 'DDMONYY'))
    FROM net.route r WHERE r.id = p_route
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
  IF NEW.trip_no IS NULL THEN                        -- N43: the reference carries the number just chosen
    NEW.trip_no := ops.trip_reference(NEW.company_id, NEW.service_no, NEW.section_suffix::text, NEW.route_id,
                                      NEW.departure_at);
  END IF;
  RETURN NEW;
END $$;

REVOKE ALL ON FUNCTION ops.trip_reference(bigint, integer, text, bigint, timestamptz) FROM PUBLIC;
COMMENT ON FUNCTION ops.trip_reference IS 'The reference of a new trip: carrier code, service number, route, local departure time and day, "DCA-1171-DAM-DRA-1330-24OCT26" (1143, N43)';
COMMENT ON FUNCTION ops.tg_trip_number IS 'Gives a new trip its service date, service number, the trip number passengers read and, when none is given, its reference (1114, 1143)';
COMMENT ON COLUMN ops.trip.trip_no IS 'The trip''s reference, unchanged for its life: carrier code, service number, route, local departure time and day, "DCA-1171-DAM-DRA-1330-24OCT26" (1143); trips made before 1143 keep "DCA-DAM-DRA-1330/24OCT26"';
