-- 1132: the money of a connection's missed tickets is held until the carrier's change window ends (owner's decision,
-- October 2026). Until now, completing a trip released its escrow and closed the tickets not travelled as no-show, so a
-- traveller who missed a later trip of a connection could no longer change it once the carrier closed that trip,
-- often on arrival (docs/design/CONNECTIONS.md, "A limit to know").
--
-- Now, when a trip is completed, a booking of a connection whose travellers all missed it, and that could still be
-- changed under its carrier's policy, is held: its tickets stay issued, its escrow stays held and the booking stays
-- confirmed until the change window ends (the trip's departure plus the carrier's hours). The traveller changes it in
-- that time as before. When the window ends, the worker releases the escrow to the carrier, closes the tickets as
-- no-show and completes the booking. A change ends the hold at once.

CREATE TABLE IF NOT EXISTS sales.connection_hold (
  booking_id   bigint PRIMARY KEY REFERENCES sales.booking(id),
  trip_id      bigint NOT NULL REFERENCES ops.trip(id),
  basis        text NOT NULL CHECK (basis IN ('FREE_CHANGE', 'FARE_RULES')),   -- the carrier's policy when the hold began
  hold_until   timestamptz NOT NULL,                                          -- departure plus the change window
  amount       bigint NOT NULL CHECK (amount >= 0),                           -- the fares kept in escrow
  currency     char(3) NOT NULL REFERENCES ref.currency(code),
  status       text NOT NULL DEFAULT 'HELD' CHECK (status IN ('HELD', 'RELEASED', 'CHANGED')),
  created_at   timestamptz NOT NULL DEFAULT now(),
  closed_at    timestamptz,
  CONSTRAINT connection_hold_closed_ck CHECK ((status = 'HELD') = (closed_at IS NULL))
);
CREATE INDEX IF NOT EXISTS connection_hold_trip_id_fkx ON sales.connection_hold (trip_id);
CREATE INDEX IF NOT EXISTS connection_hold_due_idx ON sales.connection_hold (hold_until) WHERE status = 'HELD';
COMMENT ON TABLE sales.connection_hold IS 'A connection''s booking whose travellers missed the trip, kept open with its escrow held until the carrier''s change window ends (1132)';

-- a hold only ends: released when the window closes, or changed by the traveller
CREATE OR REPLACE FUNCTION sales.tg_connection_hold_step() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF (NEW.booking_id, NEW.trip_id, NEW.basis, NEW.hold_until, NEW.amount, NEW.currency, NEW.created_at)
     IS DISTINCT FROM (OLD.booking_id, OLD.trip_id, OLD.basis, OLD.hold_until, OLD.amount, OLD.currency, OLD.created_at)
     OR NOT (OLD.status = NEW.status OR (OLD.status = 'HELD' AND NEW.status IN ('RELEASED', 'CHANGED'))) THEN
    RAISE EXCEPTION 'HOLD_FROZEN: a held connection is released or changed, never rewritten' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS connection_hold_step ON sales.connection_hold;
CREATE TRIGGER connection_hold_step BEFORE UPDATE ON sales.connection_hold FOR EACH ROW EXECUTE FUNCTION sales.tg_connection_hold_step();

SELECT sys.rls_parent('sales.connection_hold', 'booking_id', 'sales.booking');
GRANT SELECT, INSERT ON sales.connection_hold TO masslak_app;
GRANT UPDATE (status, closed_at) ON sales.connection_hold TO masslak_app;
GRANT SELECT ON sales.connection_hold TO masslak_readonly, masslak_auditor;

-- the bookings of a trip being completed that are held, with when each hold ends; the caller is completing the trip
CREATE OR REPLACE FUNCTION sales.hold_missed_connections(p_trip bigint) RETURNS bigint[]
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE pol jsonb; ids bigint[];
BEGIN
  SELECT ops.connection_policy(t.company_id) INTO pol FROM ops.trip t WHERE t.id = p_trip;
  IF pol IS NULL OR pol ->> 'missed_connection' = 'NONE' THEN
    RETURN '{}';
  END IF;
  WITH cand AS (
    SELECT b.id, b.currency,
           min(coalesce(s.actual_dep, s.sched_dep)) + make_interval(hours => (pol ->> 'change_window_hours')::int) AS until,
           sum(k.total_amount) AS fares,
           bool_and(k.status = 'ISSUED') AS all_missed,
           bool_and(coalesce((k.rules_snapshot ->> 'changeable')::boolean, false)) AS changeable
      FROM sales.booking b
      JOIN sales.ticket k ON k.booking_id = b.id AND k.status <> 'CANCELLED'
      JOIN ops.trip_stop s ON s.trip_id = k.trip_id AND s.seq = k.from_seq
     WHERE b.trip_id = p_trip AND b.status = 'CONFIRMED' AND b.journey_kind = 'CONNECTION'
       -- only a booking its traveller may change: paid from their own wallet, not for an agency, a charter or a family
       AND b.pay_method = 'WALLET' AND b.agency_id IS NULL AND b.charter_request_id IS NULL
       AND coalesce(b.funding_source, 'OWN') = 'OWN'
     GROUP BY b.id, b.currency)
  INSERT INTO sales.connection_hold (booking_id, trip_id, basis, hold_until, amount, currency)
  SELECT c.id, p_trip, pol ->> 'missed_connection', c.until, c.fares, c.currency
    FROM cand c
   WHERE c.all_missed AND c.until > now()
     -- under the fare's rules only a changeable fare can still be changed; a free change needs no such fare
     AND (pol ->> 'missed_connection' = 'FREE_CHANGE' OR c.changeable)
  ON CONFLICT (booking_id) DO NOTHING;
  SELECT coalesce(array_agg(booking_id), '{}') INTO ids FROM sales.connection_hold WHERE trip_id = p_trip AND status = 'HELD';
  RETURN ids;
END $$;
REVOKE ALL ON FUNCTION sales.hold_missed_connections(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sales.hold_missed_connections(bigint) TO masslak_app;
COMMENT ON FUNCTION sales.hold_missed_connections IS 'When a trip is completed: its connection bookings missed by all their travellers and still changeable are held until the change window ends (1132)';

-- ------------------------------------------------------------------ registration
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('sales.connection_hold', '1A', 'E11')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
SELECT sys.refresh_table_class();
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('sales.connection_hold', 'sales records', 'connection bookings held until the change window ends (1132)')
ON CONFLICT (table_name) DO NOTHING;
