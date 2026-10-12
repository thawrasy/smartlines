-- =====================================================================
-- Masslak - 1105: the counter check and the boarding pass (boarding stations, build step 3; docs/operations/BOARDING_STATIONS.md)
--
-- At a boarding station the passenger goes to the counter of the operating company that serves the trip; the counter
-- checks the ticket and the identity document and issues the boarding pass. brd.station_checkin records each check-in
-- with the station, the counter, the operating company, the staff member and whether the document was checked.
-- brd.station_checkin_ticket does the check, in this order, each refusal with its own code:
--   * the station takes boarding now (the platform's switch and the station's: STATION_NOT_BOARDING);
--   * the ticket is valid (TICKET_NOT_VALID, ALREADY_BOARDED), its boarding stop is at this station (WRONG_STATION) and
--     the trip has not left (TRIP_NOT_OPEN);
--   * the caller may issue it: the carrier's own staff for its trips, or an operating company holding the carrier's or
--     the platform's BOARDING_PASS right at this station (net.operator_may: NOT_GRANTED), at one of its own counters at
--     the station (COUNTER_NOT_YOURS);
--   * the check-in window, the station's own or else the platform's, is open (CHECKIN_NOT_OPEN, CHECKIN_CLOSED); with no
--     window set, the counter takes check-ins at any time before departure;
--   * the carrier has the references the platform requires on file (boarding.references.required: REFERENCES_MISSING),
--     the rule step 1 recorded and left to this step.
-- A second check-in of the same ticket returns the first boarding pass. The pass carries the bay of the boarding stop
-- (ops.trip_stop.gate_id) when one is assigned at issue; otherwise it shows none and the station screens show it later.
-- A check-in can be cancelled before boarding (a mistake at the counter), and the ticket checked in again.
-- Station staff with the BOARDING right record the boarding at the bay through the existing boarding path; at a boarding
-- station they board only tickets that were checked in (brd.station_may_board).
-- =====================================================================

CREATE SEQUENCE IF NOT EXISTS brd.boarding_pass_seq;

CREATE TABLE IF NOT EXISTS brd.station_checkin (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                  uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  pass_no              text NOT NULL UNIQUE,
  ticket_id            bigint NOT NULL REFERENCES sales.ticket(id),
  trip_id              bigint NOT NULL REFERENCES ops.trip(id),
  stop_seq             smallint NOT NULL,
  station_id           bigint NOT NULL REFERENCES net.station(id),
  counter_gate_id      bigint REFERENCES net.station_gate(id),
  bay_gate_id          bigint REFERENCES net.station_gate(id),
  operator_company_id  bigint REFERENCES iam.company(id),      -- empty when the carrier's own staff checked the passenger in
  carrier_company_id   bigint NOT NULL REFERENCES iam.company(id),
  checked_by_user_id   bigint NOT NULL REFERENCES iam.app_user(id),
  document_checked     boolean NOT NULL,
  status               text NOT NULL DEFAULT 'CHECKED_IN' CHECK (status IN ('CHECKED_IN', 'CANCELLED')),
  created_at           timestamptz NOT NULL DEFAULT now(),
  cancelled_at         timestamptz,
  cancelled_by_user_id bigint REFERENCES iam.app_user(id),
  cancel_reason        text CHECK (cancel_reason IS NULL OR length(cancel_reason) BETWEEN 3 AND 300),
  CHECK ((status = 'CANCELLED') = (cancelled_at IS NOT NULL)),
  CHECK (operator_company_id IS NULL OR counter_gate_id IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS station_checkin_ticket_uq ON brd.station_checkin (ticket_id) WHERE status = 'CHECKED_IN';
CREATE INDEX IF NOT EXISTS station_checkin_trip_id_fkx ON brd.station_checkin (trip_id);
CREATE INDEX IF NOT EXISTS station_checkin_station_id_fkx ON brd.station_checkin (station_id, created_at);
CREATE INDEX IF NOT EXISTS station_checkin_counter_gate_id_fkx ON brd.station_checkin (counter_gate_id);
CREATE INDEX IF NOT EXISTS station_checkin_bay_gate_id_fkx ON brd.station_checkin (bay_gate_id);
CREATE INDEX IF NOT EXISTS station_checkin_operator_company_id_fkx ON brd.station_checkin (operator_company_id);
CREATE INDEX IF NOT EXISTS station_checkin_carrier_company_id_fkx ON brd.station_checkin (carrier_company_id);
CREATE INDEX IF NOT EXISTS station_checkin_checked_by_user_id_fkx ON brd.station_checkin (checked_by_user_id);
CREATE INDEX IF NOT EXISTS station_checkin_cancelled_by_user_id_fkx ON brd.station_checkin (cancelled_by_user_id);
COMMENT ON TABLE brd.station_checkin IS 'Counter check-ins and their boarding passes at boarding stations: station, counter, operating company, staff member (1105)';
SELECT sys.rls('brd.station_checkin', 'sys.tenant_visible(carrier_company_id) OR sys.tenant_visible(operator_company_id)');
GRANT SELECT ON brd.station_checkin TO masslak_app;          -- written by the functions below only
GRANT SELECT ON brd.station_checkin TO masslak_readonly;

-- the bay of a trip's stop, as the boarding pass prints it
CREATE OR REPLACE FUNCTION brd.boarding_pass(p_checkin_id bigint) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT jsonb_build_object(
           'pass_no', c.pass_no, 'status', c.status, 'checked_in_at', c.created_at, 'document_checked', c.document_checked,
           'ticket_no', k.ticket_no, 'ticket_status', k.status, 'seat_no', k.seat_no,
           'passenger', btrim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')),
           'trip_no', t.trip_no, 'carrier', cp.legal_name,
           'from_station', sa.name, 'from_code', sa.code, 'to_station', sb.name, 'to_code', sb.code,
           'departs_at', coalesce(a.sched_dep, t.departure_at),
           'bay', (SELECT g.code FROM net.station_gate g WHERE g.id = coalesce(a.gate_id, c.bay_gate_id)),
           'counter', (SELECT g.code FROM net.station_gate g WHERE g.id = c.counter_gate_id))
    FROM brd.station_checkin c JOIN sales.ticket k ON k.id = c.ticket_id JOIN sales.passenger p ON p.id = k.passenger_id
    JOIN ops.trip t ON t.id = c.trip_id JOIN iam.party cp ON cp.id = t.company_id
    JOIN ops.trip_stop a ON a.trip_id = k.trip_id AND a.seq = k.from_seq JOIN net.station sa ON sa.id = a.station_id
    JOIN ops.trip_stop z ON z.trip_id = k.trip_id AND z.seq = k.to_seq JOIN net.station sb ON sb.id = z.station_id
   WHERE c.id = p_checkin_id
     AND (sys.tenant_visible(c.carrier_company_id) OR sys.tenant_visible(c.operator_company_id))   -- the caller's own passes only
$$;
REVOKE ALL ON FUNCTION brd.boarding_pass(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION brd.boarding_pass(bigint) TO masslak_app;   -- the routes read only passes the caller's row security shows
COMMENT ON FUNCTION brd.boarding_pass IS 'What the boarding pass prints: passenger, seat, trip, stations, departure, the bay when assigned, the counter (1105)';

-- who may act for a trip at a station: the carrier itself, or an operating company holding the right there
CREATE OR REPLACE FUNCTION brd.station_actor_may(p_trip_company_id bigint, p_station_id bigint, p_right text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT sys.ctx_company_id() IS NOT NULL AND net.boarding_station_on(p_station_id)
     AND (sys.ctx_company_id() = p_trip_company_id OR net.operator_may(sys.ctx_company_id(), p_trip_company_id, p_station_id, p_right))
$$;
REVOKE ALL ON FUNCTION brd.station_actor_may(bigint, bigint, text) FROM PUBLIC;

CREATE OR REPLACE FUNCTION brd.station_checkin_ticket(p_ticket_uid uuid, p_station_id bigint, p_counter_code text,
                                                      p_document_checked boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v_company bigint := sys.ctx_company_id();
  v_user bigint := sys.ctx_user_id();
  v_k record;
  v_counter bigint;
  v_opens integer;
  v_closes integer;
  v_missing text[];
  v_id bigint;
BEGIN
  IF v_user IS NULL OR v_company IS NULL THEN
    RAISE EXCEPTION 'NOT_GRANTED: a check-in is made by a signed-in member of a company' USING ERRCODE = 'P0001';
  END IF;
  IF NOT net.boarding_station_on(p_station_id) THEN
    RAISE EXCEPTION 'STATION_NOT_BOARDING: this station does not take boarding now' USING ERRCODE = 'P0001';
  END IF;
  SELECT k.id, k.status, k.trip_id, k.from_seq, t.company_id, t.status AS trip_status, t.departure_at,
         a.station_id, a.sched_dep, a.gate_id
    INTO v_k
    FROM sales.ticket k JOIN ops.trip t ON t.id = k.trip_id
    JOIN ops.trip_stop a ON a.trip_id = k.trip_id AND a.seq = k.from_seq
   WHERE k.uid = p_ticket_uid FOR UPDATE OF k;
  IF v_k.id IS NULL THEN
    RAISE EXCEPTION 'TICKET_NOT_VALID: no such ticket' USING ERRCODE = 'P0001';
  END IF;
  IF NOT brd.station_actor_may(v_k.company_id, p_station_id, 'BOARDING_PASS') THEN
    RAISE EXCEPTION 'NOT_GRANTED: the carrier has not given this company the boarding pass right at this station' USING ERRCODE = 'P0001';
  END IF;
  SELECT id INTO v_id FROM brd.station_checkin WHERE ticket_id = v_k.id AND status = 'CHECKED_IN';
  IF v_id IS NOT NULL THEN                                 -- checked in already: the same boarding pass again
    RETURN brd.boarding_pass(v_id) || jsonb_build_object('repeated', true);
  END IF;
  IF v_k.status = 'BOARDED' THEN
    RAISE EXCEPTION 'ALREADY_BOARDED: the passenger has boarded' USING ERRCODE = 'P0001';
  END IF;
  IF v_k.status <> 'ISSUED' THEN
    RAISE EXCEPTION 'TICKET_NOT_VALID: the ticket is %', v_k.status USING ERRCODE = 'P0001';
  END IF;
  IF v_k.station_id IS DISTINCT FROM p_station_id THEN
    RAISE EXCEPTION 'WRONG_STATION: the passenger boards at another station' USING ERRCODE = 'P0001';
  END IF;
  IF v_k.trip_status NOT IN ('PUBLISHED', 'BOARDING') OR coalesce(v_k.sched_dep, v_k.departure_at) < now() THEN
    RAISE EXCEPTION 'TRIP_NOT_OPEN: the trip has left or does not run' USING ERRCODE = 'P0001';
  END IF;
  IF v_company <> v_k.company_id THEN                      -- an operating company works at one of its own counters
    SELECT g.id INTO v_counter FROM net.station_gate g
     WHERE g.station_id = p_station_id AND g.code = p_counter_code AND g.gate_type = 'COUNTER'
       AND g.operator_company_id = v_company AND g.status = 'ACTIVE';
    IF v_counter IS NULL THEN
      RAISE EXCEPTION 'COUNTER_NOT_YOURS: % is not an open counter of this company at the station', coalesce(p_counter_code, '(none)') USING ERRCODE = 'P0001';
    END IF;
  ELSIF p_counter_code IS NOT NULL THEN
    SELECT g.id INTO v_counter FROM net.station_gate g
     WHERE g.station_id = p_station_id AND g.code = p_counter_code AND g.gate_type = 'COUNTER' AND g.status = 'ACTIVE';
  END IF;
  SELECT coalesce(b.checkin_opens_minutes, (SELECT (value #>> '{}')::integer FROM sys.setting WHERE key = 'boarding.checkin.opens_minutes'
                                                                                 AND jsonb_typeof(value) = 'number')),
         coalesce(b.checkin_closes_minutes, (SELECT (value #>> '{}')::integer FROM sys.setting WHERE key = 'boarding.checkin.closes_minutes'
                                                                                  AND jsonb_typeof(value) = 'number'))
    INTO v_opens, v_closes
    FROM (SELECT 1) x LEFT JOIN net.station_boarding b ON b.station_id = p_station_id;
  IF v_opens IS NOT NULL AND now() < coalesce(v_k.sched_dep, v_k.departure_at) - make_interval(mins => v_opens) THEN
    RAISE EXCEPTION 'CHECKIN_NOT_OPEN: the check-in opens % minutes before departure', v_opens USING ERRCODE = 'P0001';
  END IF;
  IF v_closes IS NOT NULL AND now() > coalesce(v_k.sched_dep, v_k.departure_at) - make_interval(mins => v_closes) THEN
    RAISE EXCEPTION 'CHECKIN_CLOSED: the check-in closed % minutes before departure', v_closes USING ERRCODE = 'P0001';
  END IF;
  v_missing := net.operation_references_missing(v_k.company_id);
  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION 'REFERENCES_MISSING: the carrier has not recorded %', array_to_string(v_missing, ', ') USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO brd.station_checkin (pass_no, ticket_id, trip_id, stop_seq, station_id, counter_gate_id, bay_gate_id,
                                   operator_company_id, carrier_company_id, checked_by_user_id, document_checked)
  VALUES ((SELECT code FROM net.station WHERE id = p_station_id) || '-' || lpad(nextval('brd.boarding_pass_seq')::text, 8, '0'),
          v_k.id, v_k.trip_id, v_k.from_seq, p_station_id, v_counter, v_k.gate_id,
          CASE WHEN v_company <> v_k.company_id THEN v_company END, v_k.company_id, v_user, coalesce(p_document_checked, false))
  RETURNING id INTO v_id;
  RETURN brd.boarding_pass(v_id) || jsonb_build_object('repeated', false);
END $$;
REVOKE ALL ON FUNCTION brd.station_checkin_ticket(uuid, bigint, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION brd.station_checkin_ticket(uuid, bigint, text, boolean) TO masslak_app;
COMMENT ON FUNCTION brd.station_checkin_ticket IS
  'The counter check: station on, ticket valid at this station, right and counter, check-in window, required references; issues the boarding pass (1105)';

CREATE OR REPLACE FUNCTION brd.cancel_station_checkin(p_pass_no text, p_reason text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_c record;
BEGIN
  SELECT c.id, c.status, c.station_id, c.carrier_company_id, k.status AS ticket_status INTO v_c
    FROM brd.station_checkin c JOIN sales.ticket k ON k.id = c.ticket_id WHERE c.pass_no = p_pass_no FOR UPDATE OF c;
  IF v_c.id IS NULL OR NOT brd.station_actor_may(v_c.carrier_company_id, v_c.station_id, 'BOARDING_PASS') THEN
    RAISE EXCEPTION 'NOT_FOUND: no such boarding pass for this company' USING ERRCODE = 'P0001';
  END IF;
  IF v_c.status <> 'CHECKED_IN' THEN
    RAISE EXCEPTION 'CHECKIN_CANCELLED: the boarding pass was cancelled already' USING ERRCODE = 'P0001';
  END IF;
  IF v_c.ticket_status = 'BOARDED' THEN
    RAISE EXCEPTION 'ALREADY_BOARDED: the passenger has boarded' USING ERRCODE = 'P0001';
  END IF;
  UPDATE brd.station_checkin SET status = 'CANCELLED', cancelled_at = now(), cancelled_by_user_id = sys.ctx_user_id(),
         cancel_reason = btrim(p_reason)
   WHERE id = v_c.id;
  RETURN brd.boarding_pass(v_c.id);
END $$;
REVOKE ALL ON FUNCTION brd.cancel_station_checkin(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION brd.cancel_station_checkin(text, text) TO masslak_app;
COMMENT ON FUNCTION brd.cancel_station_checkin IS 'Cancels a check-in made by mistake, before boarding; the ticket can be checked in again (1105)';

-- station staff record a boarding at the bay: the BOARDING right at the station, and a check-in for the ticket
CREATE OR REPLACE FUNCTION brd.station_may_board(p_ticket_uid uuid, p_station_id bigint) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT CASE
    WHEN k.id IS NULL THEN 'INVALID_QR'
    WHEN NOT net.boarding_station_on(p_station_id) THEN 'STATION_NOT_BOARDING'
    WHEN NOT brd.station_actor_may(t.company_id, p_station_id, 'BOARDING') THEN 'NOT_GRANTED'
    WHEN NOT EXISTS (SELECT 1 FROM brd.station_checkin c WHERE c.ticket_id = k.id AND c.status = 'CHECKED_IN'
                                                           AND c.station_id = p_station_id) THEN 'CHECKIN_REQUIRED'
    ELSE 'OK' END
    FROM (SELECT 1) x LEFT JOIN sales.ticket k ON k.uid = p_ticket_uid LEFT JOIN ops.trip t ON t.id = k.trip_id
$$;
REVOKE ALL ON FUNCTION brd.station_may_board(uuid, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION brd.station_may_board(uuid, bigint) TO masslak_app;
COMMENT ON FUNCTION brd.station_may_board IS 'Whether station staff may board a ticket at the bay: station on, the BOARDING right, a check-in at this station (1105)';

-- the project phase, the data class and the lifecycle: with the stations (phase 7), the carrier's or the operator's records
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('brd.station_checkin', '7', 'E04')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
INSERT INTO sys.table_class (table_name, data_class, tenant_path, note) VALUES
  ('brd.station_checkin', 'TENANT_PRIVATE', 'carrier company or operating company', 'counter check-ins and boarding passes at boarding stations (1105)')
ON CONFLICT (table_name) DO UPDATE SET data_class = excluded.data_class, tenant_path = excluded.tenant_path, note = excluded.note;
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('brd.station_checkin', 'brd records', 'the check-ins and boarding passes of boarding stations (1105)')
ON CONFLICT (table_name) DO NOTHING;

-- a ticket typed at the counter: its number and its booking reference, both, so a number alone opens nothing
CREATE OR REPLACE FUNCTION brd.ticket_uid(p_ticket_no text, p_booking_ref text) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT k.uid FROM sales.ticket k JOIN sales.booking b ON b.id = k.booking_id
   WHERE k.ticket_no = upper(btrim(p_ticket_no)) AND b.booking_ref = upper(btrim(p_booking_ref))
$$;
REVOKE ALL ON FUNCTION brd.ticket_uid(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION brd.ticket_uid(text, text) TO masslak_app;
COMMENT ON FUNCTION brd.ticket_uid IS 'The ticket a counter types in: its number with its booking reference (1105)';

-- the trips a station's counter serves in the hours ahead: those of carriers that gave the caller a right at the station
CREATE OR REPLACE FUNCTION brd.station_trips(p_station_id bigint) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce(jsonb_agg(x ORDER BY x ->> 'departs_at'), '[]'::jsonb) FROM (
    SELECT jsonb_build_object(
             'trip_uid', t.uid, 'trip_no', t.trip_no, 'carrier', cp.legal_name, 'status', t.status, 'stop_seq', ts.seq,
             'departs_at', coalesce(ts.sched_dep, t.departure_at),
             'bay', (SELECT g.code FROM net.station_gate g WHERE g.id = ts.gate_id),
             'may_check_in', brd.station_actor_may(t.company_id, p_station_id, 'BOARDING_PASS'),
             'may_board', brd.station_actor_may(t.company_id, p_station_id, 'BOARDING'),
             'tickets', (SELECT count(*) FROM sales.ticket k WHERE k.trip_id = t.id AND k.from_seq = ts.seq AND k.status IN ('ISSUED','BOARDED')),
             'checked_in', (SELECT count(*) FROM brd.station_checkin c WHERE c.trip_id = t.id AND c.station_id = p_station_id AND c.status = 'CHECKED_IN'),
             'boarded', (SELECT count(*) FROM sales.ticket k WHERE k.trip_id = t.id AND k.from_seq = ts.seq AND k.status = 'BOARDED')) AS x
      FROM ops.trip_stop ts JOIN ops.trip t ON t.id = ts.trip_id JOIN iam.party cp ON cp.id = t.company_id
     WHERE ts.station_id = p_station_id AND t.status IN ('PUBLISHED','BOARDING')
       AND coalesce(ts.sched_dep, t.departure_at) BETWEEN now() - interval '2 hours' AND now() + interval '2 days'
       AND (brd.station_actor_may(t.company_id, p_station_id, 'BOARDING_PASS') OR brd.station_actor_may(t.company_id, p_station_id, 'BOARDING'))
     LIMIT 300) y
$$;
REVOKE ALL ON FUNCTION brd.station_trips(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION brd.station_trips(bigint) TO masslak_app;
COMMENT ON FUNCTION brd.station_trips IS 'Trips leaving a station in the next two days for which the caller may check in or board, with their counts and bay (1105)';
