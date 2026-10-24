-- =====================================================================
-- Masslak - 1110: tickets sold at a station's counter under the carrier's BOOKING right, in the first release
-- (owner's decision, October 2026)
--
-- A carrier gives a station's operating company the BOOKING right at a station (net.station_operator_grant, 1098). Its
-- counter staff then sell that carrier's tickets for trips boarding at that station, for cash. The booking is the
-- carrier's like any other; the operating company is its booker, so it sees the bookings it sold, and the cash it takes
-- is owed on its own cash wallet, within its cash limit, and remitted to the platform like a carrier's counter cash
-- (1056). brd.station_sale records each sale with the station, the counter and the clerk, for the operating company and
-- the carrier. A cash sale cancelled at the same counter is refunded in cash from its drawer.
--
-- Station boarding (check-in, boarding, counter sales and departure boards) joins the first release: its tables move from
-- phase 7 to 1B. Nothing changes until the platform switches boarding stations on and a carrier grants a right.
-- =====================================================================

-- ------------------------------------------------------------------ the first release
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('net.station_boarding', '1B', 'E04'), ('net.station_gate', '1B', 'E04'), ('net.station_operator_grant', '1B', 'E04'),
  ('net.station_display', '1B', 'E04'), ('brd.station_checkin', '1B', 'E04')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;

-- ------------------------------------------------------------------ the sales channel
INSERT INTO sales.channel (code, channel_type) VALUES ('STATION', 'COUNTER') ON CONFLICT DO NOTHING;

-- ------------------------------------------------------------------ an operating company sees the bookings it sold at stations
-- (an agency still sees its bookings only in the agency portal)
DROP POLICY IF EXISTS booking_isolation ON sales.booking;
CREATE POLICY booking_isolation ON sales.booking
  USING (sys.tenant_visible(company_id) OR booker_party_id = sys.ctx_party_id()
         OR (agency_id IS NOT NULL AND sys.ctx_scope() = 'AGENCY' AND agency_id = sys.ctx_company_id())
         OR (family_id IS NOT NULL AND iam.is_family_head(family_id)) OR sales.travels_on(id)
         OR (sys.ctx_company_id() IS NOT NULL AND booker_party_id = sys.ctx_company_id()
             AND channel_id = (SELECT c.id FROM sales.channel c WHERE c.code = 'STATION')))
  WITH CHECK (sys.tenant_visible(company_id) OR booker_party_id = sys.ctx_party_id()
              OR (agency_id IS NOT NULL AND sys.ctx_scope() = 'AGENCY' AND agency_id = sys.ctx_company_id())
              OR (sys.ctx_company_id() IS NOT NULL AND booker_party_id = sys.ctx_company_id()
                  AND channel_id = (SELECT c.id FROM sales.channel c WHERE c.code = 'STATION')));

-- ------------------------------------------------------------------ may this counter sell this trip here?
CREATE OR REPLACE FUNCTION brd.station_may_sell(p_trip_id bigint, p_from_seq integer, p_station_id bigint) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT EXISTS (
    SELECT 1 FROM ops.trip t JOIN ops.trip_stop ts ON ts.trip_id = t.id AND ts.seq = p_from_seq
     WHERE t.id = p_trip_id AND t.status IN ('PUBLISHED', 'BOARDING') AND ts.station_id = p_station_id
       AND sys.ctx_company_id() IS DISTINCT FROM t.company_id                -- a carrier sells at its own counter (1056)
       AND brd.station_actor_may(t.company_id, p_station_id, 'BOOKING'))
$$;
REVOKE ALL ON FUNCTION brd.station_may_sell(bigint, integer, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION brd.station_may_sell(bigint, integer, bigint) TO masslak_app;
COMMENT ON FUNCTION brd.station_may_sell IS 'The calling operating company holds the carrier''s BOOKING right at this station, the station is on and the passenger boards there (1110)';

-- ------------------------------------------------------------------ each sale at a station counter
CREATE TABLE IF NOT EXISTS brd.station_sale (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  booking_id           bigint NOT NULL UNIQUE REFERENCES sales.booking(id),
  station_id           bigint NOT NULL REFERENCES net.station(id),
  counter_gate_id      bigint REFERENCES net.station_gate(id),
  operator_company_id  bigint NOT NULL REFERENCES iam.company(id),
  carrier_company_id   bigint NOT NULL REFERENCES iam.company(id),
  sold_by              bigint NOT NULL REFERENCES iam.app_user(id),
  total                bigint NOT NULL CHECK (total >= 0),
  currency             char(3) NOT NULL REFERENCES ref.currency(code),
  created_at           timestamptz NOT NULL DEFAULT now(),
  CHECK (operator_company_id <> carrier_company_id)
);
CREATE INDEX IF NOT EXISTS station_sale_station_id_fkx ON brd.station_sale (station_id, created_at);
CREATE INDEX IF NOT EXISTS station_sale_counter_gate_id_fkx ON brd.station_sale (counter_gate_id);
CREATE INDEX IF NOT EXISTS station_sale_operator_company_id_fkx ON brd.station_sale (operator_company_id, created_at);
CREATE INDEX IF NOT EXISTS station_sale_carrier_company_id_fkx ON brd.station_sale (carrier_company_id, created_at);
CREATE INDEX IF NOT EXISTS station_sale_sold_by_fkx ON brd.station_sale (sold_by);
COMMENT ON TABLE brd.station_sale IS 'A booking sold at a station counter under the carrier''s BOOKING right: station, counter, clerk; seen by the operating company and the carrier (1110)';
ALTER TABLE brd.station_sale ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS isolation ON brd.station_sale;
CREATE POLICY isolation ON brd.station_sale
  USING (sys.ctx_is_platform() OR sys.tenant_visible(operator_company_id) OR sys.tenant_visible(carrier_company_id))
  WITH CHECK (sys.ctx_is_platform() OR (sys.tenant_visible(operator_company_id) AND sold_by = sys.ctx_user_id()));
GRANT SELECT, INSERT ON brd.station_sale TO masslak_app;
GRANT SELECT ON brd.station_sale TO masslak_readonly;

-- a sale is recorded only for a booking its operating company booked at a station where it may sell
CREATE OR REPLACE FUNCTION brd.tg_station_sale() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE b record;
BEGIN
  SELECT bk.trip_id, bk.company_id, bk.booker_party_id, bk.total_amount, bk.currency, k.from_seq INTO b
    FROM sales.booking bk LEFT JOIN LATERAL (SELECT min(from_seq) AS from_seq FROM sales.ticket WHERE booking_id = bk.id) k ON true
   WHERE bk.id = NEW.booking_id;
  IF b.booker_party_id IS DISTINCT FROM NEW.operator_company_id OR b.company_id IS DISTINCT FROM NEW.carrier_company_id
     OR b.currency IS DISTINCT FROM NEW.currency OR b.total_amount IS DISTINCT FROM NEW.total THEN
    RAISE EXCEPTION 'STATION_SALE_MISMATCH: the sale does not match its booking' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM ops.trip_stop WHERE trip_id = b.trip_id AND seq = b.from_seq AND station_id = NEW.station_id) THEN
    RAISE EXCEPTION 'STATION_SALE_MISMATCH: the passengers do not board at this station' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.counter_gate_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM net.station_gate g WHERE g.id = NEW.counter_gate_id AND g.station_id = NEW.station_id
          AND g.gate_type = 'COUNTER' AND g.operator_company_id = NEW.operator_company_id) THEN
    RAISE EXCEPTION 'COUNTER_NOT_YOURS: the counter is not this company''s at this station' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS station_sale_check ON brd.station_sale;
CREATE TRIGGER station_sale_check BEFORE INSERT ON brd.station_sale FOR EACH ROW EXECUTE FUNCTION brd.tg_station_sale();

-- ------------------------------------------------------------------ the station's trips show whether the counter may sell
CREATE OR REPLACE FUNCTION brd.station_trips(p_station_id bigint) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  WITH horizon AS (
    SELECT ((date_trunc('day', now() AT TIME ZONE z) + interval '3 days') AT TIME ZONE z) AS until
      FROM (SELECT coalesce(ref.station_tz(p_station_id), 'UTC') AS z) tz)
  SELECT coalesce(jsonb_agg(x ORDER BY x ->> 'departs_at'), '[]'::jsonb) FROM (
    SELECT jsonb_build_object(
             'trip_uid', t.uid, 'trip_no', t.trip_no, 'carrier', cp.legal_name, 'status', t.status, 'stop_seq', ts.seq,
             'departs_at', coalesce(ts.sched_dep, t.departure_at),
             'bay', (SELECT g.code FROM net.station_gate g WHERE g.id = ts.gate_id),
             'may_check_in', brd.station_actor_may(t.company_id, p_station_id, 'BOARDING_PASS'),
             'may_board', brd.station_actor_may(t.company_id, p_station_id, 'BOARDING'),
             'may_sell', sys.ctx_company_id() IS DISTINCT FROM t.company_id AND brd.station_actor_may(t.company_id, p_station_id, 'BOOKING'),
             'tickets', (SELECT count(*) FROM sales.ticket k WHERE k.trip_id = t.id AND k.from_seq = ts.seq AND k.status IN ('ISSUED','BOARDED')),
             'checked_in', (SELECT count(*) FROM brd.station_checkin c WHERE c.trip_id = t.id AND c.station_id = p_station_id AND c.status = 'CHECKED_IN'),
             'boarded', (SELECT count(*) FROM sales.ticket k WHERE k.trip_id = t.id AND k.from_seq = ts.seq AND k.status = 'BOARDED')) AS x
      FROM ops.trip_stop ts JOIN ops.trip t ON t.id = ts.trip_id JOIN iam.party cp ON cp.id = t.company_id, horizon h
     WHERE ts.station_id = p_station_id AND t.status IN ('PUBLISHED','BOARDING')
       AND coalesce(ts.sched_dep, t.departure_at) >= now() - interval '2 hours'
       AND coalesce(ts.sched_dep, t.departure_at) < h.until
       AND (brd.station_actor_may(t.company_id, p_station_id, 'BOARDING_PASS') OR brd.station_actor_may(t.company_id, p_station_id, 'BOARDING')
            OR brd.station_actor_may(t.company_id, p_station_id, 'BOOKING'))
     LIMIT 300) y
$$;
REVOKE ALL ON FUNCTION brd.station_trips(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION brd.station_trips(bigint) TO masslak_app;
COMMENT ON FUNCTION brd.station_trips IS 'Trips leaving a station today, tomorrow and the day after (its time zone) that the caller may sell, check in or board, with their counts and bay (1105, 1109, 1110)';

-- ------------------------------------------------------------------ registration
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('brd.station_sale', '1B', 'E04')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
INSERT INTO sys.table_class (table_name, data_class, tenant_path, note) VALUES
  ('brd.station_sale', 'TENANT_PRIVATE', 'operator_company_id, carrier_company_id', 'tickets sold at station counters (1110)')
ON CONFLICT (table_name) DO UPDATE SET data_class = excluded.data_class, tenant_path = excluded.tenant_path, note = excluded.note;
INSERT INTO gov.dataset_member (table_name, dataset, note)
SELECT 'brd.station_sale', dataset, 'tickets sold at station counters (1110)' FROM gov.dataset_member WHERE table_name = 'brd.station_checkin'
ON CONFLICT (table_name) DO NOTHING;
