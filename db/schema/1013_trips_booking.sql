-- =====================================================================
-- 1013: trips, booking, boarding and tracking additions
--   Seat locks (audit copy, 4.5), cancellation policies and waiting lists (4.5), entry rules and ticket travel
--   documents (11.9), boarding additions, NFC inspections (7.6 e), tracking state and driver notices (7.8),
--   and the station gates, displays and trip delays of phase 7 (4.10).
-- =====================================================================

-- ------------------------------ inventory (4.5) ------------------------------
CREATE TABLE IF NOT EXISTS ops.seat_lock (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  trip_id      bigint NOT NULL REFERENCES ops.trip(id),
  seat_no      text NOT NULL,
  from_seq     smallint NOT NULL,
  to_seq       smallint NOT NULL,
  user_id      bigint REFERENCES iam.app_user(id),
  session_ref  text NOT NULL,
  expires_at   timestamptz NOT NULL,
  released_at  timestamptz,
  outcome      text CHECK (outcome IN ('BOOKED','EXPIRED','RELEASED')),
  created_at   timestamptz NOT NULL DEFAULT now(),
  CHECK (to_seq > from_seq)
);
CREATE INDEX IF NOT EXISTS seat_lock_trip_idx ON ops.seat_lock (trip_id, seat_no);
COMMENT ON TABLE ops.seat_lock IS 'Database copy of seat locks for audit; the live lock is held in memory (4.5)';

CREATE TABLE IF NOT EXISTS pricing.cancellation_policy (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id  bigint REFERENCES iam.company(id),                     -- empty: platform default
  code        text NOT NULL,
  name        text NOT NULL,
  rules       jsonb NOT NULL,                                        -- [{hours_before, refund_pct, fee}]
  version     int NOT NULL DEFAULT 1,
  valid       daterange NOT NULL DEFAULT daterange(current_date, NULL),
  status      text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('DRAFT','ACTIVE','RETIRED')),
  approved_by bigint REFERENCES iam.app_user(id),
  UNIQUE NULLS NOT DISTINCT (company_id, code, version)
);
COMMENT ON TABLE pricing.cancellation_policy IS 'Refund percentages by time before departure; refund requests keep a snapshot of it';

CREATE TABLE IF NOT EXISTS sales.waitlist_entry (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  trip_id      bigint NOT NULL REFERENCES ops.trip(id),
  party_id     bigint NOT NULL REFERENCES iam.party(id),
  from_seq     smallint NOT NULL,
  to_seq       smallint NOT NULL,
  seats        smallint NOT NULL DEFAULT 1 CHECK (seats BETWEEN 1 AND 9),
  status       text NOT NULL DEFAULT 'WAITING' CHECK (status IN ('WAITING','OFFERED','BOOKED','EXPIRED','CANCELLED')),
  offered_at   timestamptz,
  offer_expires_at timestamptz,
  booking_id   bigint REFERENCES sales.booking(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  CHECK (to_seq > from_seq)
);
CREATE UNIQUE INDEX IF NOT EXISTS waitlist_one_per_party ON sales.waitlist_entry (trip_id, party_id) WHERE status IN ('WAITING','OFFERED');

-- ------------------------------ travel documents (11.9, D.1.4) ------------------------------
CREATE TABLE IF NOT EXISTS sales.entry_rule (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  country_code       char(2) NOT NULL REFERENCES ref.country(code),   -- destination or transit country
  country_role       text NOT NULL DEFAULT 'DESTINATION' CHECK (country_role IN ('DESTINATION','TRANSIT')),
  nationality        char(2) REFERENCES ref.country(code),            -- empty: any nationality
  doc_required       text[] NOT NULL DEFAULT '{PASSPORT}',
  security_approval  boolean NOT NULL DEFAULT false,
  passport_min_days  int NOT NULL DEFAULT 180 CHECK (passport_min_days >= 0),
  enforcement        text NOT NULL DEFAULT 'BLOCK' CHECK (enforcement IN ('BLOCK','ALLOW_PENDING')),
  label              text NOT NULL,
  version            int NOT NULL DEFAULT 1,
  status             text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','ACTIVE','RETIRED')),
  created_by         bigint REFERENCES iam.app_user(id),
  approved_by        bigint REFERENCES iam.app_user(id),
  created_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE NULLS NOT DISTINCT (country_code, country_role, nationality, version),
  CHECK (approved_by IS NULL OR approved_by <> created_by)
);
COMMENT ON TABLE sales.entry_rule IS 'Data-driven document rules per destination or transit country and nationality, four-eyes approved (11.9)';

CREATE TABLE IF NOT EXISTS sales.ticket_doc (
  ticket_id             bigint PRIMARY KEY REFERENCES sales.ticket(id),
  entry_rule_id         bigint REFERENCES sales.entry_rule(id),
  dest_country          char(2) NOT NULL REFERENCES ref.country(code),
  passport_expiry       date,
  visa_type             text,
  visa_no_enc           bytea,
  visa_country          char(2) REFERENCES ref.country(code),
  visa_valid            daterange,
  visa_entries          text CHECK (visa_entries IN ('SINGLE','DOUBLE','MULTIPLE')),
  residence_no_enc      bytea,
  residence_country     char(2) REFERENCES ref.country(code),
  residence_expiry      date,
  security_no_enc       bytea,
  security_authority    text,
  security_expiry       date,
  transit_visa_no_enc   bytea,
  transit_permit_no     text,
  transit_permit_valid  daterange,
  enc_key_id            int REFERENCES sec.key_registry(id),
  status                text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','VERIFIED','REJECTED')),
  issues                jsonb NOT NULL DEFAULT '[]',
  verified_by           bigint REFERENCES iam.app_user(id),
  verified_at           timestamptz,
  source                text NOT NULL DEFAULT 'PASSENGER' CHECK (source IN ('PASSENGER','AGENT','CARRIER','GOV_API')),
  CHECK ((visa_no_enc IS NULL AND residence_no_enc IS NULL AND security_no_enc IS NULL AND transit_visa_no_enc IS NULL)
         OR enc_key_id IS NOT NULL)
);
COMMENT ON TABLE sales.ticket_doc IS 'Travel documents of one international ticket; numbers are encrypted (11.9, D.1.4)';

-- ------------------------------ boarding (7.6 e) ------------------------------
ALTER TABLE sales.boarding_event ADD COLUMN IF NOT EXISTS companions smallint NOT NULL DEFAULT 0;
ALTER TABLE sales.boarding_event ADD COLUMN IF NOT EXISTS offline_token text;
ALTER TABLE sales.boarding_event ADD COLUMN IF NOT EXISTS geo_match boolean;
ALTER TABLE sales.boarding_event ADD COLUMN IF NOT EXISTS vehicle_tag_id bigint REFERENCES fleet.vehicle_qr_tag(id);
ALTER TABLE sales.boarding_event ADD COLUMN IF NOT EXISTS validator_id bigint REFERENCES fleet.boarding_validator(id);
ALTER TABLE sales.boarding_event ADD COLUMN IF NOT EXISTS nfc_card_id bigint REFERENCES sales.nfc_card(id);
ALTER TABLE sales.boarding_event DROP CONSTRAINT IF EXISTS boarding_event_method_check;
ALTER TABLE sales.boarding_event ADD CONSTRAINT boarding_event_method_check
  CHECK (method IN ('AGENT_SCAN','SELF_SCAN','VALIDATOR_QR','VALIDATOR_NFC','MANUAL','OFFLINE_SCAN','CASH'));
-- Shuttle boardings by card or cash have no ticket; every other boarding still needs one
ALTER TABLE sales.boarding_event ALTER COLUMN ticket_id DROP NOT NULL;
DO $$ BEGIN
  ALTER TABLE sales.boarding_event ADD CONSTRAINT boarding_event_ticket_ck
    CHECK (ticket_id IS NOT NULL OR method IN ('CASH','VALIDATOR_NFC','SELF_SCAN'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS sales.inspection_check (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id          bigint NOT NULL REFERENCES iam.company(id),
  inspector_party_id  bigint NOT NULL REFERENCES iam.party(id),
  vehicle_id          bigint REFERENCES fleet.vehicle(id),
  trip_id             bigint REFERENCES ops.trip(id),
  boarding_event_id   bigint REFERENCES sales.boarding_event(id),
  result              text NOT NULL CHECK (result IN ('PAID','UNPAID','MISMATCH')),
  fee_charged         bigint NOT NULL DEFAULT 0 CHECK (fee_charged >= 0),
  currency            char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  lat                 numeric(9,6),
  lng                 numeric(9,6),
  ts                  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE sales.inspection_check IS 'Random fare inspection on board; append-only';

-- ------------------------------ tracking (7.8, phase 7) ------------------------------
CREATE TABLE IF NOT EXISTS ops.tracking_state (
  trip_id         bigint PRIMARY KEY REFERENCES ops.trip(id),
  driver_user_id  bigint REFERENCES iam.app_user(id),
  last_ping_at    timestamptz,
  status          text NOT NULL DEFAULT 'OFF' CHECK (status IN ('ON','OFF')),
  off_reason      text,
  level           text NOT NULL DEFAULT 'NORMAL' CHECK (level IN ('STRICT','NORMAL')),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE ops.tracking_state IS 'Current tracking status of a trip; positions themselves are in ops.geo_event (trip_position in 7.8)';

CREATE TABLE IF NOT EXISTS ops.driver_notice (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id     bigint NOT NULL REFERENCES iam.app_user(id),
  trip_id     bigint REFERENCES ops.trip(id),
  body        text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  ack_at      timestamptz
);
CREATE INDEX IF NOT EXISTS driver_notice_user_idx ON ops.driver_notice (user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS ops.trip_delay (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  trip_id      bigint NOT NULL REFERENCES ops.trip(id),
  stop_seq     smallint,
  delay_min    int NOT NULL,
  cause        text NOT NULL CHECK (cause IN ('TRAFFIC','WEATHER','BORDER','TECHNICAL','OPERATIONAL','OTHER')),
  source       text NOT NULL CHECK (source IN ('TRACKING','DRIVER','CARRIER','STATION')),
  reported_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS trip_delay_trip_idx ON ops.trip_delay (trip_id, reported_at);
COMMENT ON TABLE ops.trip_delay IS 'Delay estimates per stop that feed station displays and passenger notifications (phase 7)';

CREATE TABLE IF NOT EXISTS net.station_gate (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  station_id  bigint NOT NULL REFERENCES net.station(id),
  code        text NOT NULL,
  gate_type   text NOT NULL DEFAULT 'PLATFORM' CHECK (gate_type IN ('PLATFORM','BAY','GATE','COUNTER')),
  status      text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','CLOSED')),
  UNIQUE (station_id, code)
);
ALTER TABLE ops.trip_stop ADD COLUMN IF NOT EXISTS gate_id bigint REFERENCES net.station_gate(id);

CREATE TABLE IF NOT EXISTS net.station_display (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  station_id     bigint NOT NULL REFERENCES net.station(id),
  gate_id        bigint REFERENCES net.station_gate(id),
  device_serial  text NOT NULL UNIQUE,
  kind           text NOT NULL CHECK (kind IN ('DEPARTURES','ARRIVALS','GATE')),
  last_seen_at   timestamptz,
  status         text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','OFFLINE','RETIRED'))
);
COMMENT ON TABLE net.station_display IS 'Departure and arrival boards in stations (phase 7)';

-- ------------------------------ isolation and privileges ------------------------------
DO $$ BEGIN
  PERFORM sys.rls_trip(t) FROM unnest(ARRAY['ops.tracking_state','ops.trip_delay']) t;
  PERFORM sys.rls_trip('ops.seat_lock', 'sys.is_me(user_id)');
  PERFORM sys.rls_split('pricing.cancellation_policy', 'true',
    'CASE WHEN company_id IS NULL THEN sys.ctx_is_platform() ELSE sys.tenant_visible(company_id) END');
  PERFORM sys.rls_trip('sales.waitlist_entry', 'party_id = sys.ctx_party_id()');
  PERFORM sys.rls_catalog('sales.entry_rule');
  -- documents follow the booking: its carrier, or the passenger who booked
  PERFORM sys.rls('sales.ticket_doc', 'EXISTS (SELECT 1 FROM sales.ticket t JOIN sales.booking b ON b.id = t.booking_id
    WHERE t.id = ticket_id AND (sys.tenant_visible(b.company_id) OR b.booker_party_id = sys.ctx_party_id()))');
  PERFORM sys.rls_tenant('sales.inspection_check');
  PERFORM sys.rls('ops.driver_notice', 'sys.ctx_is_platform() OR sys.is_me(user_id)
    OR EXISTS (SELECT 1 FROM ops.trip x WHERE x.id = trip_id AND sys.tenant_visible(x.company_id))');
  PERFORM sys.rls_catalog(t) FROM unnest(ARRAY['net.station_gate','net.station_display']) t;
  PERFORM sys.grant_rw(ARRAY['ops.seat_lock','pricing.cancellation_policy','sales.waitlist_entry','sales.entry_rule',
    'sales.ticket_doc','ops.tracking_state','ops.driver_notice','net.station_gate','net.station_display']);
  PERFORM sys.grant_append(ARRAY['sales.inspection_check','ops.trip_delay']);
END $$;
