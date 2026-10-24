-- =====================================================================
-- 1123  Charter: buses, minibuses and whole trips hired from carriers (owner's request, October 2026)
-- =====================================================================
-- Besides seats on the scheduled trips, a tourism company may hire from a carrier:
--   * a vehicle apart from the trips (a coach, a minibus, a van) for a day, a route or a tour (kind VEHICLE);
--   * a scheduled trip, all its seats or a block of them (kind WHOLE_TRIP).
-- A carrier decides what it hires out and on what terms: it publishes offers (sales.charter_offer), each with the kind of
-- vehicle, who may ask (tourism companies, travellers by special request, or both), how it prices (a day, a kilometre, a
-- trip, a seat, or on request), the notice it needs, what it refunds when the customer cancels, and its own policy in
-- words. The customer asks under an offer (sales.charter_request); the carrier answers with a price valid for a while,
-- or declines; the customer accepts and pays at once from its wallet (an agency from its own), and the request is
-- confirmed. The money waits in the platform's escrow until the carrier marks the service done, when it goes to the
-- carrier less the platform's commission (charter.commission_bp, none unless the platform sets one). A carrier that
-- cancels refunds in full; a customer that cancels is refunded as the offer says. A confirmed whole-trip request takes
-- its seats off sale (ops.seat_segment BLOCKED, sales.charter_seat) until it is cancelled.

-- ------------------------------------------------------------------ what a carrier hires out
CREATE TABLE IF NOT EXISTS sales.charter_offer (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  company_id         bigint NOT NULL REFERENCES iam.company(id),
  kind               text NOT NULL CHECK (kind IN ('VEHICLE', 'WHOLE_TRIP')),
  title              text NOT NULL CHECK (length(btrim(title)) BETWEEN 3 AND 80),
  vehicle_type       text CHECK (vehicle_type IN ('COACH', 'MINIBUS', 'VAN', 'CITY_BUS')),
  seats              smallint CHECK (seats BETWEEN 1 AND 99),             -- a vehicle's passenger seats
  vehicles           smallint NOT NULL DEFAULT 1 CHECK (vehicles BETWEEN 1 AND 500),
  partial_seats      boolean NOT NULL DEFAULT true,                       -- a whole trip: a block of its seats too
  min_seats          smallint CHECK (min_seats BETWEEN 1 AND 99),         -- the smallest block
  audience           text[] NOT NULL CHECK (cardinality(audience) BETWEEN 1 AND 2 AND audience <@ ARRAY['AGENCY', 'PASSENGER']),
  price_basis        text NOT NULL CHECK (price_basis IN ('PER_DAY', 'PER_KM', 'PER_TRIP', 'PER_SEAT', 'ON_REQUEST')),
  price              bigint CHECK (price > 0),                            -- minor units; none when priced on request
  currency           char(3) NOT NULL REFERENCES ref.currency(code),
  notice_hours       smallint NOT NULL DEFAULT 48 CHECK (notice_hours BETWEEN 0 AND 2160),
  cancel_before_hours smallint NOT NULL DEFAULT 48 CHECK (cancel_before_hours BETWEEN 0 AND 2160),
  cancel_refund_pct  smallint NOT NULL DEFAULT 100 CHECK (cancel_refund_pct BETWEEN 0 AND 100),
  with_driver        boolean NOT NULL DEFAULT true,
  base_city_id       bigint REFERENCES ref.city(id),
  policy             text NOT NULL CHECK (length(btrim(policy)) BETWEEN 10 AND 2000),
  status             text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'PAUSED', 'ARCHIVED')),
  created_by         bigint REFERENCES iam.app_user(id),
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT charter_offer_price_ck CHECK ((price_basis = 'ON_REQUEST') = (price IS NULL)),
  CONSTRAINT charter_offer_vehicle_ck CHECK (kind <> 'VEHICLE' OR (vehicle_type IS NOT NULL AND seats IS NOT NULL
                                                                 AND price_basis <> 'PER_SEAT')),
  CONSTRAINT charter_offer_trip_ck CHECK (kind <> 'WHOLE_TRIP' OR (vehicle_type IS NULL AND seats IS NULL
                                                                  AND price_basis NOT IN ('PER_DAY', 'PER_KM')
                                                                  AND (NOT partial_seats OR min_seats IS NOT NULL)))
);
CREATE INDEX IF NOT EXISTS charter_offer_company_id_fkx ON sales.charter_offer (company_id, status);
CREATE INDEX IF NOT EXISTS charter_offer_base_city_id_fkx ON sales.charter_offer (base_city_id);
CREATE INDEX IF NOT EXISTS charter_offer_created_by_fkx ON sales.charter_offer (created_by);
CREATE INDEX IF NOT EXISTS charter_offer_currency_fkx ON sales.charter_offer (currency);
DROP TRIGGER IF EXISTS charter_offer_updated ON sales.charter_offer;
CREATE TRIGGER charter_offer_updated BEFORE UPDATE ON sales.charter_offer FOR EACH ROW EXECUTE FUNCTION sys.tg_set_updated_at();
COMMENT ON TABLE sales.charter_offer IS
  'What a carrier hires out: a vehicle apart from the trips, or its scheduled trips whole or in blocks; who may ask, how it prices, its notice, refunds and policy (1123)';
-- everyone reads the published offers; a carrier writes its own
SELECT sys.rls_split('sales.charter_offer', 'status = ''ACTIVE'' OR sys.tenant_visible(company_id)', 'sys.tenant_visible(company_id)');
GRANT SELECT, INSERT, UPDATE ON sales.charter_offer TO masslak_app;
GRANT SELECT ON sales.charter_offer TO masslak_readonly, masslak_auditor;

-- ------------------------------------------------------------------ a customer's request, its price and its payment
CREATE TABLE IF NOT EXISTS sales.charter_request (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  ref                text NOT NULL UNIQUE CHECK (ref ~ '^CH[0-9A-Z]{8}$'),
  offer_id           bigint NOT NULL REFERENCES sales.charter_offer(id),
  company_id         bigint NOT NULL REFERENCES iam.company(id),          -- the carrier
  requester_party_id bigint NOT NULL REFERENCES iam.party(id),            -- the tourism company, or the traveller
  requester_user_id  bigint REFERENCES iam.app_user(id),
  requester_kind     text NOT NULL CHECK (requester_kind IN ('AGENCY', 'PASSENGER')),
  agency_id          bigint REFERENCES iam.company(id),                   -- the tourism company, when one asked
  contact_name       text NOT NULL CHECK (length(btrim(contact_name)) BETWEEN 2 AND 120),   -- who the carrier deals with
  contact_mobile     text NOT NULL CHECK (contact_mobile ~ '^\+?[0-9]{8,15}$'),
  kind               text NOT NULL CHECK (kind IN ('VEHICLE', 'WHOLE_TRIP')),
  -- the offer's terms when the request was made: what the customer asked under, whatever the carrier changes later
  terms              jsonb NOT NULL,
  -- a vehicle apart from the trips
  from_city_id       bigint REFERENCES ref.city(id),
  to_city_id         bigint REFERENCES ref.city(id),
  starts_at          timestamptz,
  ends_at            timestamptz,
  passengers         smallint CHECK (passengers BETWEEN 1 AND 999),
  vehicles           smallint CHECK (vehicles BETWEEN 1 AND 50),
  itinerary          text CHECK (length(itinerary) <= 1000),
  -- a scheduled trip, whole or a block of its seats
  trip_id            bigint REFERENCES ops.trip(id),
  from_seq           smallint CHECK (from_seq >= 0),
  to_seq             smallint,
  seats              smallint CHECK (seats BETWEEN 1 AND 99),
  whole              boolean,
  note               text CHECK (length(note) <= 500),
  status             text NOT NULL DEFAULT 'REQUESTED'
                     CHECK (status IN ('REQUESTED', 'QUOTED', 'CONFIRMED', 'COMPLETED', 'DECLINED', 'WITHDRAWN', 'EXPIRED', 'CANCELLED')),
  -- the carrier's price
  price              bigint CHECK (price > 0),
  currency           char(3) REFERENCES ref.currency(code),
  valid_until        timestamptz,
  quote_note         text CHECK (length(quote_note) <= 500),
  quoted_by          bigint REFERENCES iam.app_user(id),
  quoted_at          timestamptz,
  vehicle_id         bigint REFERENCES fleet.vehicle(id),                 -- the vehicle the carrier names, when it does
  -- the money: paid into escrow, released to the carrier when done, refunded on a cancellation
  paid_txn_id        bigint REFERENCES fin.ledger_txn(id),
  paid_at            timestamptz,
  released_txn_id    bigint REFERENCES fin.ledger_txn(id),
  refund_txn_id      bigint REFERENCES fin.ledger_txn(id),
  refunded_amount    bigint CHECK (refunded_amount >= 0),
  closed_by          bigint REFERENCES iam.app_user(id),
  closed_at          timestamptz,
  closed_reason      text CHECK (length(closed_reason) <= 300),
  idempotency_key    text NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 80),
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT charter_request_key_uq UNIQUE (requester_party_id, idempotency_key),
  CONSTRAINT charter_request_agency_ck CHECK ((requester_kind = 'AGENCY') = (agency_id IS NOT NULL)
                                             AND (agency_id IS NULL OR agency_id = requester_party_id)),
  -- every condition names its columns NOT NULL: a NULL would let the check pass
  CONSTRAINT charter_request_vehicle_ck CHECK (kind <> 'VEHICLE' OR (
    from_city_id IS NOT NULL AND to_city_id IS NOT NULL AND starts_at IS NOT NULL AND ends_at IS NOT NULL AND ends_at > starts_at
    AND passengers IS NOT NULL AND vehicles IS NOT NULL AND trip_id IS NULL AND seats IS NULL)),
  CONSTRAINT charter_request_trip_ck CHECK (kind <> 'WHOLE_TRIP' OR (
    trip_id IS NOT NULL AND from_seq IS NOT NULL AND to_seq IS NOT NULL AND to_seq > from_seq AND seats IS NOT NULL
    AND whole IS NOT NULL AND from_city_id IS NULL AND starts_at IS NULL)),
  CONSTRAINT charter_request_quote_ck CHECK (status NOT IN ('QUOTED', 'CONFIRMED', 'COMPLETED') OR (
    price IS NOT NULL AND currency IS NOT NULL AND valid_until IS NOT NULL AND quoted_at IS NOT NULL)),
  CONSTRAINT charter_request_paid_ck CHECK (status NOT IN ('CONFIRMED', 'COMPLETED') OR (paid_txn_id IS NOT NULL AND paid_at IS NOT NULL)),
  CONSTRAINT charter_request_released_ck CHECK (status <> 'COMPLETED' OR released_txn_id IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS charter_request_offer_id_fkx ON sales.charter_request (offer_id);
CREATE INDEX IF NOT EXISTS charter_request_company_id_fkx ON sales.charter_request (company_id, status);
CREATE INDEX IF NOT EXISTS charter_request_requester_party_id_fkx ON sales.charter_request (requester_party_id, created_at DESC);
CREATE INDEX IF NOT EXISTS charter_request_requester_user_id_fkx ON sales.charter_request (requester_user_id);
CREATE INDEX IF NOT EXISTS charter_request_agency_id_fkx ON sales.charter_request (agency_id);
CREATE INDEX IF NOT EXISTS charter_request_from_city_id_fkx ON sales.charter_request (from_city_id);
CREATE INDEX IF NOT EXISTS charter_request_to_city_id_fkx ON sales.charter_request (to_city_id);
CREATE INDEX IF NOT EXISTS charter_request_trip_id_fkx ON sales.charter_request (trip_id);
CREATE INDEX IF NOT EXISTS charter_request_currency_fkx ON sales.charter_request (currency);
CREATE INDEX IF NOT EXISTS charter_request_quoted_by_fkx ON sales.charter_request (quoted_by);
CREATE INDEX IF NOT EXISTS charter_request_vehicle_id_fkx ON sales.charter_request (vehicle_id);
CREATE INDEX IF NOT EXISTS charter_request_closed_by_fkx ON sales.charter_request (closed_by);
CREATE INDEX IF NOT EXISTS charter_request_paid_txn_id_fkx ON sales.charter_request (paid_txn_id);
CREATE INDEX IF NOT EXISTS charter_request_released_txn_id_fkx ON sales.charter_request (released_txn_id);
CREATE INDEX IF NOT EXISTS charter_request_refund_txn_id_fkx ON sales.charter_request (refund_txn_id);
DROP TRIGGER IF EXISTS charter_request_updated ON sales.charter_request;
CREATE TRIGGER charter_request_updated BEFORE UPDATE ON sales.charter_request FOR EACH ROW EXECUTE FUNCTION sys.tg_set_updated_at();
COMMENT ON TABLE sales.charter_request IS
  'A customer''s request to hire a vehicle or a trip under a carrier''s offer: the carrier''s price, the payment held in escrow, the service done or cancelled (1123)';
-- the two parties of the deal see the request: the carrier, and the tourism company's staff or the traveller who asked
SELECT sys.rls('sales.charter_request',
  'sys.tenant_visible(company_id) OR sys.tenant_visible(agency_id) OR requester_party_id = sys.ctx_party_id()');
GRANT SELECT, INSERT, UPDATE ON sales.charter_request TO masslak_app;
GRANT SELECT ON sales.charter_request TO masslak_readonly, masslak_auditor;

INSERT INTO sys.json_contract (table_name, column_name, kind, version, spec, note) VALUES
  ('sales.charter_request', 'terms', 'SNAPSHOT', 1,
   '{"type": "object", "required": ["title", "price_basis", "currency", "cancel_before_hours", "cancel_refund_pct", "policy"]}'::jsonb,
   'the offer''s terms when the request was made: title, pricing, refunds and the carrier''s policy (1123)')
ON CONFLICT DO NOTHING;
SELECT sys.apply_json_contracts();

-- ------------------------------------------------------------------ the seats a confirmed whole-trip request holds
CREATE TABLE IF NOT EXISTS sales.charter_seat (
  request_id   bigint NOT NULL REFERENCES sales.charter_request(id),
  trip_id      bigint NOT NULL REFERENCES ops.trip(id),
  seat_no      smallint NOT NULL,
  from_seq     smallint NOT NULL CHECK (from_seq >= 0),
  to_seq       smallint NOT NULL,
  released_at  timestamptz,
  PRIMARY KEY (request_id, seat_no),
  CHECK (to_seq > from_seq)
);
CREATE INDEX IF NOT EXISTS charter_seat_trip_id_fkx ON sales.charter_seat (trip_id, seat_no);
COMMENT ON TABLE sales.charter_seat IS 'The seats of a scheduled trip a confirmed whole-trip request took off sale (BLOCKED on ops.seat_segment) until released (1123)';
SELECT sys.rls_parent('sales.charter_seat', 'request_id', 'sales.charter_request');
GRANT SELECT, INSERT, UPDATE ON sales.charter_seat TO masslak_app;
GRANT SELECT ON sales.charter_seat TO masslak_readonly, masslak_auditor;

-- a blocked seat belongs to a request: the seats a request blocked are released by it alone
CREATE OR REPLACE FUNCTION sales.charter_block_seats(p_request bigint) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE r sales.charter_request; v_free smallint[]; v_take smallint[]; v_total int; n int;
BEGIN
  SELECT * INTO r FROM sales.charter_request WHERE id = p_request FOR UPDATE;
  IF NOT FOUND OR r.kind <> 'WHOLE_TRIP' THEN
    RAISE EXCEPTION 'CHARTER_UNKNOWN: no whole-trip request %', p_request USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM sales.charter_seat WHERE request_id = p_request AND released_at IS NULL) THEN
    RETURN (SELECT count(*) FROM sales.charter_seat WHERE request_id = p_request AND released_at IS NULL);
  END IF;
  -- the seats free on every segment of the request, locked in one order (seat, then segment) before they change
  PERFORM 1 FROM ops.seat_segment s WHERE s.trip_id = r.trip_id AND s.seg >= r.from_seq AND s.seg < r.to_seq
    ORDER BY s.seat_no, s.seg FOR UPDATE;
  SELECT array_agg(seat_no ORDER BY seat_no), count(DISTINCT seat_no) INTO v_free, v_total FROM (
    SELECT s.seat_no FROM ops.seat_segment s WHERE s.trip_id = r.trip_id AND s.seg >= r.from_seq AND s.seg < r.to_seq
     GROUP BY s.seat_no
    HAVING count(*) = r.to_seq - r.from_seq
       AND bool_and(s.status = 'AVAILABLE' OR (s.status = 'LOCKED' AND s.lock_expires_at < now()))) f;
  IF r.whole AND EXISTS (SELECT 1 FROM ops.seat_segment s WHERE s.trip_id = r.trip_id AND s.seg >= r.from_seq AND s.seg < r.to_seq
                           AND NOT (s.status = 'AVAILABLE' OR (s.status = 'LOCKED' AND s.lock_expires_at < now()))) THEN
    RAISE EXCEPTION 'WHOLE_TRIP_TAKEN: seats of this trip are already sold; ask for a block instead' USING ERRCODE = 'P0001';
  END IF;
  IF coalesce(cardinality(v_free), 0) < r.seats THEN
    RAISE EXCEPTION 'NOT_ENOUGH_SEATS: % seats left of the % asked', coalesce(cardinality(v_free), 0), r.seats USING ERRCODE = 'P0001';
  END IF;
  v_take := v_free[1:r.seats];
  UPDATE ops.seat_segment s SET status = 'BLOCKED', lock_token = NULL, lock_user_id = NULL, lock_expires_at = NULL
   WHERE s.trip_id = r.trip_id AND s.seat_no = ANY(v_take) AND s.seg >= r.from_seq AND s.seg < r.to_seq;
  GET DIAGNOSTICS n = ROW_COUNT;
  INSERT INTO sales.charter_seat (request_id, trip_id, seat_no, from_seq, to_seq)
  SELECT p_request, r.trip_id, x, r.from_seq, r.to_seq FROM unnest(v_take) x;
  RETURN cardinality(v_take);
END $$;
REVOKE ALL ON FUNCTION sales.charter_block_seats(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sales.charter_block_seats(bigint) TO masslak_app;
COMMENT ON FUNCTION sales.charter_block_seats IS 'Takes a confirmed whole-trip request''s seats off sale: all of them, or the first free ones of a block (1123)';

CREATE OR REPLACE FUNCTION sales.charter_release_seats(p_request bigint) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE n int;
BEGIN
  UPDATE ops.seat_segment s SET status = 'AVAILABLE'
    FROM sales.charter_seat c
   WHERE c.request_id = p_request AND c.released_at IS NULL AND s.trip_id = c.trip_id AND s.seat_no = c.seat_no
     AND s.seg >= c.from_seq AND s.seg < c.to_seq AND s.status = 'BLOCKED';
  UPDATE sales.charter_seat SET released_at = now() WHERE request_id = p_request AND released_at IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION sales.charter_release_seats(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sales.charter_release_seats(bigint) TO masslak_app;
COMMENT ON FUNCTION sales.charter_release_seats IS 'Puts back on sale the seats a cancelled whole-trip request held (1123)';

-- the money of a charter (paid into escrow, released, refunded) names the request it belongs to
UPDATE sys.polymorphic_reference SET targets = targets || '{"charter_request": "sales.charter_request"}'::jsonb
 WHERE table_name = 'fin.ledger_txn' AND NOT targets ? 'charter_request';

-- ------------------------------------------------------------------ the platform's share
INSERT INTO sys.setting (key, value, description) VALUES
  ('charter.commission_bp', '0'::jsonb, 'The platform''s commission on a charter, in basis points of its price, taken when the carrier is paid (1123)')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION sales.set_charter_commission(p_bp int) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: the charter commission is a platform setting' USING ERRCODE = 'P0001';
  END IF;
  IF p_bp IS NULL OR p_bp NOT BETWEEN 0 AND 3000 THEN
    RAISE EXCEPTION 'INVALID_SETTING: the commission is 0 to 3000 basis points (30%%)' USING ERRCODE = 'P0001';
  END IF;
  UPDATE sys.setting SET value = to_jsonb(p_bp), updated_by = sys.ctx_user_id(), updated_at = now() WHERE key = 'charter.commission_bp';
  RETURN p_bp;
END $$;
REVOKE ALL ON FUNCTION sales.set_charter_commission(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sales.set_charter_commission(int) TO masslak_app;
COMMENT ON FUNCTION sales.set_charter_commission IS 'Sets the platform''s commission on charters; platform only (1123)';

-- ------------------------------------------------------------------ the carrier's permission
INSERT INTO iam.permission (code, module, scope, description, is_sensitive) VALUES
  ('charter.manage', 'sales', 'COMPANY', 'Publish the company''s charter offers (vehicles and whole trips), price the requests, name the vehicle and mark the service done or cancel it', false)
ON CONFLICT (code) DO NOTHING;
INSERT INTO iam.role_permission (role_id, permission_code)
SELECT r.id, 'charter.manage' FROM iam.role r WHERE r.code = 'CARRIER_OPERATIONS' AND r.company_id IS NULL
ON CONFLICT DO NOTHING;

-- ------------------------------------------------------------------ registration
DROP TRIGGER IF EXISTS zz_audit_capture ON sales.charter_offer;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR UPDATE OR DELETE ON sales.charter_offer
  FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();
DROP TRIGGER IF EXISTS zz_audit_capture ON sales.charter_request;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR UPDATE OR DELETE ON sales.charter_request
  FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('sales.charter_offer', '1B', 'E11'), ('sales.charter_request', '1B', 'E11'), ('sales.charter_seat', '1B', 'E11')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
SELECT sys.refresh_table_class();
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('sales.charter_offer', 'sales records', 'what carriers hire out and on what terms (1123)'),
  ('sales.charter_request', 'sales records', 'requests to hire a vehicle or a trip, their prices and payments (1123)'),
  ('sales.charter_seat', 'sales records', 'the seats a confirmed whole-trip request holds (1123)')
ON CONFLICT (table_name) DO NOTHING;
