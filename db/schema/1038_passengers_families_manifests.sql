-- =====================================================================
-- 1038: passenger categories, family accounts, carrier-issued manifests and isolation between companies
--   (study 2.8: sections 4.19, 4.20, 11.10 and 16.26)
--
--   Passenger categories: every carrier sets the age bands of its adults, children and infants (a platform default
--   applies until it does), the fare of each category (a share of the adult fare, a fixed fare or free) and its own
--   family offers. Booking takes the category from the date of birth on the travel date.
--
--   Families: a passenger registers the members of their family with their full details. The head pays for them
--   from their wallet or from a family trips account, buys trips and passes for all of them at family offer prices,
--   approves the account a member opens on another device (invite code plus approval), and limits each member to
--   times and routes. Every charge to the family is logged for the limits.
--
--   Manifests: the carrier issues the manifest of every trip, domestic or international, as a signed versioned
--   snapshot. Routing rules approved by the platform (four eyes) decide which authorities receive it and how; with
--   no rule the manifest stays issued and printable, ready for later integration.
--
--   Isolation: containers, open freight loads, rate tables, hubs, schedules and routing rules of one company are no
--   longer visible to other companies.
-- =====================================================================

-- ------------------------------ passenger categories ------------------------------
CREATE TABLE IF NOT EXISTS pricing.passenger_age_band (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id     bigint REFERENCES iam.company(id),                      -- empty: the platform default
  category       text NOT NULL CHECK (category IN ('ADULT','CHILD','INFANT')),
  min_age        smallint NOT NULL CHECK (min_age BETWEEN 0 AND 120),    -- completed years on the travel date
  max_age        smallint CHECK (max_age > min_age AND max_age <= 121),  -- exclusive; empty: no upper limit
  seat_required  boolean NOT NULL DEFAULT true,                          -- false: travels on an adult's lap
  needs_adult    boolean NOT NULL DEFAULT false,                         -- cannot travel without an adult on the booking
  max_per_adult  smallint CHECK (max_per_adult BETWEEN 1 AND 9),         -- e.g. one lap infant per adult
  status         text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('DRAFT','ACTIVE','RETIRED')),
  created_by     bigint REFERENCES iam.app_user(id),
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CHECK (category <> 'ADULT' OR (seat_required AND NOT needs_adult)),
  EXCLUDE USING gist (coalesce(company_id, 0) WITH =, int4range(min_age, coalesce(max_age, 121)) WITH &&) WHERE (status = 'ACTIVE')
);
CREATE UNIQUE INDEX IF NOT EXISTS passenger_age_band_active ON pricing.passenger_age_band (coalesce(company_id, 0), category)
  WHERE status = 'ACTIVE';
CREATE INDEX IF NOT EXISTS passenger_age_band_company_id_fkx ON pricing.passenger_age_band (company_id);
CREATE INDEX IF NOT EXISTS passenger_age_band_created_by_fkx ON pricing.passenger_age_band (created_by);
COMMENT ON TABLE pricing.passenger_age_band IS 'Age bands of adults, children and infants set by each carrier; the platform row applies until a carrier sets its own (4.19)';

CREATE TABLE IF NOT EXISTS pricing.category_fare_rule (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id  bigint REFERENCES iam.company(id),                         -- empty: the platform default
  category    text NOT NULL CHECK (category IN ('CHILD','INFANT')),      -- adults pay the trip fare
  route_id    bigint REFERENCES net.route(id),                           -- empty: every route of the carrier
  method      text NOT NULL CHECK (method IN ('PCT_OF_ADULT','FIXED','FREE')),
  value       numeric(12,2) NOT NULL DEFAULT 0,
  currency    char(3) REFERENCES ref.currency(code),
  valid       daterange NOT NULL DEFAULT daterange(current_date, NULL),
  status      text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('DRAFT','ACTIVE','RETIRED')),
  created_by  bigint REFERENCES iam.app_user(id),
  created_at  timestamptz NOT NULL DEFAULT now(),
  CHECK (method <> 'PCT_OF_ADULT' OR value BETWEEN 0 AND 100),
  CHECK (method <> 'FIXED' OR (value >= 0 AND currency IS NOT NULL)),
  CHECK (company_id IS NOT NULL OR route_id IS NULL)
);
CREATE INDEX IF NOT EXISTS category_fare_rule_lookup ON pricing.category_fare_rule (company_id, category) WHERE status = 'ACTIVE';
CREATE INDEX IF NOT EXISTS category_fare_rule_route_id_fkx ON pricing.category_fare_rule (route_id);
CREATE INDEX IF NOT EXISTS category_fare_rule_currency_fkx ON pricing.category_fare_rule (currency);
CREATE INDEX IF NOT EXISTS category_fare_rule_created_by_fkx ON pricing.category_fare_rule (created_by);
COMMENT ON TABLE pricing.category_fare_rule IS 'Fare of children and infants: a share of the adult fare, a fixed fare or free; route rows win over carrier rows, carrier rows over the platform default (4.19)';

CREATE TABLE IF NOT EXISTS pricing.family_offer (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid             uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  company_id      bigint NOT NULL REFERENCES iam.company(id),            -- funded by the carrier that offers it
  code            text NOT NULL CHECK (code ~ '^[A-Z0-9_-]{2,30}$'),
  name            text NOT NULL,
  applies_to      text NOT NULL DEFAULT 'TICKETS' CHECK (applies_to IN ('TICKETS','PASSES','BOTH')),
  min_members     smallint NOT NULL DEFAULT 3 CHECK (min_members BETWEEN 2 AND 12),
  min_adults      smallint NOT NULL DEFAULT 1 CHECK (min_adults BETWEEN 0 AND 12),
  min_minors      smallint NOT NULL DEFAULT 1 CHECK (min_minors BETWEEN 0 AND 12),   -- children and infants
  discount_type   text NOT NULL CHECK (discount_type IN ('PCT','FIXED_PER_MEMBER')),
  discount_value  numeric(12,2) NOT NULL CHECK (discount_value > 0),
  max_discount    bigint CHECK (max_discount > 0),                         -- per booking or purchase, minor units
  route_id        bigint REFERENCES net.route(id),
  valid           daterange NOT NULL DEFAULT daterange(current_date, NULL),
  status          text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','ACTIVE','SUSPENDED','RETIRED')),
  created_by      bigint REFERENCES iam.app_user(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  CHECK (discount_type <> 'PCT' OR discount_value <= 50),
  CHECK (min_adults + min_minors <= min_members),
  UNIQUE (company_id, code)
);
CREATE INDEX IF NOT EXISTS family_offer_route_id_fkx ON pricing.family_offer (route_id);
CREATE INDEX IF NOT EXISTS family_offer_created_by_fkx ON pricing.family_offer (created_by);
COMMENT ON TABLE pricing.family_offer IS 'Carrier offer for a family travelling or subscribing together; applies when enough registered members of one family are on the booking (4.19 d)';

-- ------------------------------ family accounts ------------------------------
ALTER TABLE fin.wallet DROP CONSTRAINT IF EXISTS wallet_wallet_type_check;
ALTER TABLE fin.wallet ADD CONSTRAINT wallet_wallet_type_check CHECK (wallet_type IN ('USER','COMPANY','PLATFORM','ESCROW','COMMISSION',
  'TAX','SPONSOR','GATEWAY_CLEARING','BANK_CLEARING','CASH_COLLECT','DEPOSIT','EXPENSE','FAMILY'));

CREATE TABLE IF NOT EXISTS iam.family (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid              uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  head_party_id    bigint NOT NULL UNIQUE REFERENCES iam.party(id),       -- one family per head
  name             text NOT NULL CHECK (length(name) BETWEEN 2 AND 80),
  trips_wallet_id  bigint REFERENCES fin.wallet(id),                      -- the family trips account (wallet type FAMILY)
  status           text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','CLOSED')),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS family_trips_wallet_id_fkx ON iam.family (trips_wallet_id);
COMMENT ON TABLE iam.family IS 'A passenger''s family: the head pays for, books for and controls its members (4.20)';

CREATE TABLE IF NOT EXISTS iam.family_member (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid               uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  family_id         bigint NOT NULL REFERENCES iam.family(id) ON DELETE CASCADE,
  party_id          bigint NOT NULL REFERENCES iam.party(id),            -- the member's person record; their own once linked
  relation          text NOT NULL CHECK (relation IN ('SELF','SPOUSE','SON','DAUGHTER','FATHER','MOTHER','BROTHER','SISTER',
                                                       'GRANDCHILD','GRANDPARENT','OTHER')),
  first_name        text NOT NULL,
  father_name       text,
  grandfather_name  text,
  last_name         text NOT NULL,
  nationality       char(2) NOT NULL DEFAULT 'SY' REFERENCES ref.country(code),
  birth_date        date NOT NULL CHECK (birth_date > DATE '1900-01-01'),
  gender            text CHECK (gender IN ('M','F')),
  id_type           text CHECK (id_type IN ('NATIONAL_ID','PASSPORT','RESIDENCE','LAISSEZ_PASSER','TRAVEL_DOCUMENT','OTHER')),
  id_no_enc         bytea,
  id_no_bidx        bytea,
  id_no_last4       text,
  passport_expiry   date,
  enc_key_id        int REFERENCES sec.key_registry(id),
  mobile            text CHECK (mobile ~ '^\+?[0-9]{8,15}$'),
  account_status    text NOT NULL DEFAULT 'NONE' CHECK (account_status IN ('NONE','INVITED','PENDING','LINKED','REVOKED')),
  linked_user_id    bigint REFERENCES iam.app_user(id),
  funding           text NOT NULL DEFAULT 'HEAD_WALLET' CHECK (funding IN ('OWN','HEAD_WALLET','FAMILY_ACCOUNT')),
  per_trip_limit    bigint CHECK (per_trip_limit > 0),                   -- minor units, on purchases the member makes
  daily_limit       bigint CHECK (daily_limit > 0),
  monthly_limit     bigint CHECK (monthly_limit > 0),
  status            text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','REMOVED')),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CHECK ((id_no_enc IS NULL) OR (id_no_bidx IS NOT NULL AND enc_key_id IS NOT NULL AND id_type IS NOT NULL)),
  CHECK ((account_status = 'LINKED') = (linked_user_id IS NOT NULL)),
  UNIQUE (family_id, party_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS family_member_one_self ON iam.family_member (family_id) WHERE relation = 'SELF';
CREATE INDEX IF NOT EXISTS family_member_party_id_fkx ON iam.family_member (party_id);
CREATE INDEX IF NOT EXISTS family_member_linked_user_id_fkx ON iam.family_member (linked_user_id);
CREATE INDEX IF NOT EXISTS family_member_enc_key_id_fkx ON iam.family_member (enc_key_id);
CREATE INDEX IF NOT EXISTS family_member_nationality_fkx ON iam.family_member (nationality);
COMMENT ON TABLE iam.family_member IS 'A member of a family with full identity details (document number encrypted); funding and limits apply to purchases the member makes on their own device (4.20)';

CREATE TABLE IF NOT EXISTS iam.family_link_request (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                 uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  family_id           bigint NOT NULL REFERENCES iam.family(id) ON DELETE CASCADE,
  member_id           bigint NOT NULL REFERENCES iam.family_member(id) ON DELETE CASCADE,
  invite_code_hash    bytea NOT NULL,                                     -- HMAC of the six-digit code shown to the head
  requester_user_id   bigint REFERENCES iam.app_user(id),                 -- the member's own account on their device
  requester_party_id  bigint REFERENCES iam.party(id),
  device_label        text CHECK (length(device_label) <= 120),
  device_hash         bytea,                                              -- hashed device identifier, never the raw value
  ip                  inet,
  funding             text CHECK (funding IN ('OWN','HEAD_WALLET','FAMILY_ACCOUNT')),   -- what the head approves
  attempts            smallint NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 10),
  status              text NOT NULL DEFAULT 'INVITED' CHECK (status IN ('INVITED','PENDING','APPROVED','REJECTED','EXPIRED','CANCELLED')),
  expires_at          timestamptz NOT NULL,
  submitted_at        timestamptz,
  decided_at          timestamptz,
  decided_by          bigint REFERENCES iam.app_user(id),
  created_at          timestamptz NOT NULL DEFAULT now(),
  CHECK (status NOT IN ('PENDING','APPROVED') OR requester_user_id IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS family_link_request_open ON iam.family_link_request (member_id) WHERE status IN ('INVITED','PENDING');
CREATE INDEX IF NOT EXISTS family_link_request_family_id_fkx ON iam.family_link_request (family_id);
CREATE INDEX IF NOT EXISTS family_link_request_requester_user_id_fkx ON iam.family_link_request (requester_user_id);
CREATE INDEX IF NOT EXISTS family_link_request_requester_party_id_fkx ON iam.family_link_request (requester_party_id);
CREATE INDEX IF NOT EXISTS family_link_request_decided_by_fkx ON iam.family_link_request (decided_by);
COMMENT ON TABLE iam.family_link_request IS 'Linking a member''s own account opened on another device: the member enters the head''s code, the head approves the account and its funding (4.20 c)';

CREATE TABLE IF NOT EXISTS iam.family_travel_rule (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid           uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  member_id     bigint NOT NULL REFERENCES iam.family_member(id) ON DELETE CASCADE,
  rule_type     text NOT NULL CHECK (rule_type IN ('TIME_WINDOW','ROUTE','LINE')),
  days          smallint[] CHECK (days <@ ARRAY[1,2,3,4,5,6,7]::smallint[] AND cardinality(days) BETWEEN 1 AND 7),  -- ISO weekdays
  start_time    time,
  end_time      time,
  from_city_id  bigint REFERENCES ref.city(id),
  to_city_id    bigint REFERENCES ref.city(id),
  both_ways     boolean NOT NULL DEFAULT true,
  line_id       bigint REFERENCES net.line(id),
  active        boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CHECK (rule_type <> 'TIME_WINDOW' OR (start_time IS NOT NULL AND end_time IS NOT NULL AND start_time < end_time)),
  CHECK (rule_type <> 'ROUTE' OR (from_city_id IS NOT NULL AND to_city_id IS NOT NULL AND from_city_id <> to_city_id)),
  CHECK (rule_type <> 'LINE' OR line_id IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS family_travel_rule_member_id_fkx ON iam.family_travel_rule (member_id);
CREATE INDEX IF NOT EXISTS family_travel_rule_from_city_id_fkx ON iam.family_travel_rule (from_city_id);
CREATE INDEX IF NOT EXISTS family_travel_rule_to_city_id_fkx ON iam.family_travel_rule (to_city_id);
CREATE INDEX IF NOT EXISTS family_travel_rule_line_id_fkx ON iam.family_travel_rule (line_id);
COMMENT ON TABLE iam.family_travel_rule IS 'When and where a member may travel on the family''s money: time windows by weekday, city-to-city routes, shuttle lines; no rule of a type means no limit of that type (4.20 d)';

CREATE TABLE IF NOT EXISTS iam.family_spend (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  family_id      bigint NOT NULL REFERENCES iam.family(id),
  member_id      bigint NOT NULL REFERENCES iam.family_member(id),
  source         text NOT NULL CHECK (source IN ('HEAD_WALLET','FAMILY_ACCOUNT')),
  amount         bigint NOT NULL CHECK (amount > 0),
  currency       char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  ref_type       text NOT NULL CHECK (ref_type IN ('booking','subscription','ride','refund')),
  ref_id         bigint NOT NULL,
  initiated_by   bigint REFERENCES iam.app_user(id),
  ledger_txn_id  bigint REFERENCES fin.ledger_txn(id),
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS family_spend_member_day ON iam.family_spend (member_id, created_at);
CREATE INDEX IF NOT EXISTS family_spend_family_id_fkx ON iam.family_spend (family_id);
CREATE INDEX IF NOT EXISTS family_spend_currency_fkx ON iam.family_spend (currency);
CREATE INDEX IF NOT EXISTS family_spend_initiated_by_fkx ON iam.family_spend (initiated_by);
CREATE INDEX IF NOT EXISTS family_spend_ledger_txn_id_fkx ON iam.family_spend (ledger_txn_id);
COMMENT ON TABLE iam.family_spend IS 'Every charge to the head''s wallet or the family trips account on behalf of a member; limits are checked against it; append-only';
COMMENT ON COLUMN iam.family_spend.ref_id IS 'Polymorphic: id of the booking, subscription or ride named by ref_type';

-- Who is the caller to a family: SECURITY DEFINER so the policies below do not recurse into each other
CREATE OR REPLACE FUNCTION iam.is_family_head(p_family_id bigint) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT EXISTS (SELECT 1 FROM iam.family f WHERE f.id = p_family_id AND f.head_party_id = sys.ctx_party_id())
$$;
CREATE OR REPLACE FUNCTION iam.is_head_of_party(p_party_id bigint) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT EXISTS (SELECT 1 FROM iam.family_member m JOIN iam.family f ON f.id = m.family_id
                  WHERE m.party_id = p_party_id AND m.status = 'ACTIVE' AND f.head_party_id = sys.ctx_party_id())
$$;
CREATE OR REPLACE FUNCTION iam.is_member_of(p_family_id bigint) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT EXISTS (SELECT 1 FROM iam.family_member m WHERE m.family_id = p_family_id AND m.status = 'ACTIVE'
                    AND m.account_status = 'LINKED' AND m.party_id = sys.ctx_party_id())
$$;

-- Bookings, passengers and passes carry the family they were bought for
ALTER TABLE sales.booking ADD COLUMN IF NOT EXISTS family_id bigint REFERENCES iam.family(id);
ALTER TABLE sales.booking ADD COLUMN IF NOT EXISTS funded_by_party_id bigint REFERENCES iam.party(id);
ALTER TABLE sales.booking ADD COLUMN IF NOT EXISTS funding_source text CHECK (funding_source IN ('OWN','HEAD_WALLET','FAMILY_ACCOUNT'));
CREATE INDEX IF NOT EXISTS booking_family_id_fkx ON sales.booking (family_id);
CREATE INDEX IF NOT EXISTS booking_funded_by_party_id_fkx ON sales.booking (funded_by_party_id);
COMMENT ON COLUMN sales.booking.family_id IS 'Family the booking was made for or paid by; its head sees the booking';
COMMENT ON COLUMN sales.booking.funded_by_party_id IS 'Whose wallet paid when it was not the booker''s own: the family head';

ALTER TABLE sales.passenger ADD COLUMN IF NOT EXISTS family_member_id bigint REFERENCES iam.family_member(id);
ALTER TABLE sales.passenger ADD COLUMN IF NOT EXISTS accompanied_by_passenger_id bigint REFERENCES sales.passenger(id);
CREATE INDEX IF NOT EXISTS passenger_family_member_id_fkx ON sales.passenger (family_member_id);
CREATE INDEX IF NOT EXISTS passenger_accompanied_by_passenger_id_fkx ON sales.passenger (accompanied_by_passenger_id);
COMMENT ON COLUMN sales.passenger.accompanied_by_passenger_id IS 'The adult on whose lap an infant without a seat travels';

ALTER TABLE sales.subscription ADD COLUMN IF NOT EXISTS family_id bigint REFERENCES iam.family(id);
ALTER TABLE sales.subscription ADD COLUMN IF NOT EXISTS purchased_by_party_id bigint REFERENCES iam.party(id);
ALTER TABLE sales.subscription ADD COLUMN IF NOT EXISTS family_offer_id bigint REFERENCES pricing.family_offer(id);
CREATE INDEX IF NOT EXISTS subscription_family_id_fkx ON sales.subscription (family_id);
CREATE INDEX IF NOT EXISTS subscription_purchased_by_party_id_fkx ON sales.subscription (purchased_by_party_id);
CREATE INDEX IF NOT EXISTS subscription_family_offer_id_fkx ON sales.subscription (family_offer_id);

-- A passenger sees a booking they travel on, and the family head sees what the family bought
CREATE OR REPLACE FUNCTION sales.travels_on(p_booking_id bigint) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT sys.ctx_party_id() IS NOT NULL
     AND EXISTS (SELECT 1 FROM sales.passenger p WHERE p.booking_id = p_booking_id AND p.party_id = sys.ctx_party_id())
$$;
DROP POLICY IF EXISTS booking_isolation ON sales.booking;
CREATE POLICY booking_isolation ON sales.booking
  USING (sys.tenant_visible(company_id) OR booker_party_id = sys.ctx_party_id()
         OR (agency_id IS NOT NULL AND sys.ctx_scope() = 'AGENCY' AND agency_id = sys.ctx_company_id())
         OR (family_id IS NOT NULL AND iam.is_family_head(family_id))
         OR sales.travels_on(id))
  WITH CHECK (sys.tenant_visible(company_id) OR booker_party_id = sys.ctx_party_id()
         OR (agency_id IS NOT NULL AND sys.ctx_scope() = 'AGENCY' AND agency_id = sys.ctx_company_id()));

SELECT sys.rls('sales.subscription', 'sys.ctx_is_platform() OR sys.tenant_visible(company_id) OR party_id = sys.ctx_party_id()'
  || ' OR (family_id IS NOT NULL AND iam.is_family_head(family_id))');

-- ------------------------------ carrier-issued manifests ------------------------------
ALTER TABLE brd.manifest ALTER COLUMN border_point_id DROP NOT NULL;
ALTER TABLE brd.manifest ADD COLUMN IF NOT EXISTS scope text NOT NULL DEFAULT 'INTERNATIONAL' CHECK (scope IN ('DOMESTIC','INTERNATIONAL'));
ALTER TABLE brd.manifest ADD COLUMN IF NOT EXISTS issued_by bigint REFERENCES iam.app_user(id);
ALTER TABLE brd.manifest ADD COLUMN IF NOT EXISTS issued_at timestamptz;
ALTER TABLE brd.manifest ADD COLUMN IF NOT EXISTS payload_sha256 bytea;
ALTER TABLE brd.manifest ADD COLUMN IF NOT EXISTS persons_count int CHECK (persons_count >= 0);
ALTER TABLE brd.manifest ADD COLUMN IF NOT EXISTS supersedes_id bigint REFERENCES brd.manifest(id);
ALTER TABLE brd.manifest DROP CONSTRAINT IF EXISTS manifest_status_check;
ALTER TABLE brd.manifest ADD CONSTRAINT manifest_status_check
  CHECK (status IN ('DRAFT','ISSUED','CLOSED','SUBMITTED','ACKNOWLEDGED','REJECTED','SUPERSEDED','CANCELLED'));
ALTER TABLE brd.manifest DROP CONSTRAINT IF EXISTS manifest_manifest_type_check;
ALTER TABLE brd.manifest ADD CONSTRAINT manifest_manifest_type_check
  CHECK (manifest_type IN ('PRE_DEPARTURE','PRE_ARRIVAL','FINAL','AMENDMENT','CANCELLATION'));
ALTER TABLE brd.manifest DROP CONSTRAINT IF EXISTS manifest_scope_border;
ALTER TABLE brd.manifest ADD CONSTRAINT manifest_scope_border CHECK (scope = 'DOMESTIC' OR border_point_id IS NOT NULL);
ALTER TABLE brd.manifest DROP CONSTRAINT IF EXISTS manifest_issued;
ALTER TABLE brd.manifest ADD CONSTRAINT manifest_issued CHECK (status <> 'ISSUED' OR (issued_at IS NOT NULL AND payload_sha256 IS NOT NULL AND issued_by IS NOT NULL));
CREATE UNIQUE INDEX IF NOT EXISTS manifest_domestic_version ON brd.manifest (trip_id, version) WHERE border_point_id IS NULL;
CREATE INDEX IF NOT EXISTS manifest_issued_by_fkx ON brd.manifest (issued_by);
CREATE INDEX IF NOT EXISTS manifest_supersedes_id_fkx ON brd.manifest (supersedes_id);
COMMENT ON COLUMN brd.manifest.scope IS 'DOMESTIC: a trip inside one country (no border point); INTERNATIONAL: one manifest per border point crossed (11.10)';
COMMENT ON COLUMN brd.manifest.payload_sha256 IS 'SHA-256 of the canonical snapshot at issue; any later change needs a new version';

-- Persons of a domestic manifest may travel on the national ID only, or with no document at all (children)
ALTER TABLE brd.manifest_person ALTER COLUMN doc_type DROP NOT NULL;
ALTER TABLE brd.manifest_person ALTER COLUMN doc_no_enc DROP NOT NULL;
ALTER TABLE brd.manifest_person ALTER COLUMN doc_no_bidx DROP NOT NULL;
ALTER TABLE brd.manifest_person ALTER COLUMN enc_key_id DROP NOT NULL;
ALTER TABLE brd.manifest_person ALTER COLUMN issuing_country DROP NOT NULL;
ALTER TABLE brd.manifest_person ALTER COLUMN birth_date DROP NOT NULL;
ALTER TABLE brd.manifest_person DROP CONSTRAINT IF EXISTS manifest_person_doc_type_check;
ALTER TABLE brd.manifest_person ADD CONSTRAINT manifest_person_doc_type_check
  CHECK (doc_type IN ('PASSPORT','NATIONAL_ID','RESIDENCE','TRAVEL_DOCUMENT','LAISSEZ_PASSER','OTHER'));
ALTER TABLE brd.manifest_person ADD COLUMN IF NOT EXISTS full_name text;
ALTER TABLE brd.manifest_person ADD COLUMN IF NOT EXISTS age_category text CHECK (age_category IN ('ADULT','CHILD','INFANT'));
ALTER TABLE brd.manifest_person ADD COLUMN IF NOT EXISTS doc_last4 text;
ALTER TABLE brd.manifest_person ADD COLUMN IF NOT EXISTS seat_label text;
ALTER TABLE brd.manifest_person DROP CONSTRAINT IF EXISTS manifest_person_doc_complete;
ALTER TABLE brd.manifest_person ADD CONSTRAINT manifest_person_doc_complete
  CHECK (doc_no_enc IS NULL OR (doc_no_bidx IS NOT NULL AND enc_key_id IS NOT NULL AND doc_type IS NOT NULL));

CREATE OR REPLACE FUNCTION brd.tg_person_documents() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.person_role = 'PASSENGER' AND EXISTS (SELECT 1 FROM brd.manifest m WHERE m.id = NEW.manifest_id AND m.scope = 'INTERNATIONAL')
     AND (NEW.doc_type IS NULL OR NEW.doc_no_enc IS NULL OR NEW.issuing_country IS NULL OR NEW.birth_date IS NULL) THEN
    RAISE EXCEPTION 'MANIFEST_DOC_REQUIRED: a passenger of an international manifest needs a document and a date of birth'
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS person_documents ON brd.manifest_person;
CREATE TRIGGER person_documents BEFORE INSERT OR UPDATE ON brd.manifest_person FOR EACH ROW EXECUTE FUNCTION brd.tg_person_documents();

CREATE TABLE IF NOT EXISTS brd.manifest_route (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid              uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  authority_id     bigint NOT NULL REFERENCES sec.authority_profile(id),
  scope            text NOT NULL CHECK (scope IN ('DOMESTIC','INTERNATIONAL','ALL')),
  content_type     text NOT NULL DEFAULT 'ALL' CHECK (content_type IN ('PASSENGER','CARGO','ALL')),
  manifest_types   text[] NOT NULL DEFAULT '{PRE_DEPARTURE,FINAL,AMENDMENT,CANCELLATION}',
  country_code     char(2) REFERENCES ref.country(code),          -- trips touching this country
  border_point_id  bigint REFERENCES brd.border_point(station_id),
  city_id          bigint REFERENCES ref.city(id),                -- trips departing from or arriving at this city
  company_id       bigint REFERENCES iam.company(id),             -- one carrier only
  channel          text NOT NULL CHECK (channel IN ('API_PUSH','API_PULL','PORTAL','EMAIL','MANUAL')),
  format           text NOT NULL DEFAULT 'JSON' CHECK (format IN ('JSON','XML','CSV','PAXLST')),
  include_documents boolean NOT NULL DEFAULT false,                -- full document numbers, by legal basis only
  legal_basis      text NOT NULL CHECK (length(legal_basis) BETWEEN 5 AND 300),
  status           text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','ACTIVE','SUSPENDED','RETIRED')),
  created_by       bigint REFERENCES iam.app_user(id),
  approved_by      bigint REFERENCES iam.app_user(id),
  approved_at      timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CHECK (manifest_types <@ ARRAY['PRE_DEPARTURE','PRE_ARRIVAL','FINAL','AMENDMENT','CANCELLATION']::text[] AND cardinality(manifest_types) > 0),
  CHECK (status <> 'ACTIVE' OR approved_by IS NOT NULL),
  CHECK (approved_by IS NULL OR approved_by IS DISTINCT FROM created_by)
);
CREATE INDEX IF NOT EXISTS manifest_route_authority_id_fkx ON brd.manifest_route (authority_id);
CREATE INDEX IF NOT EXISTS manifest_route_country_code_fkx ON brd.manifest_route (country_code);
CREATE INDEX IF NOT EXISTS manifest_route_border_point_id_fkx ON brd.manifest_route (border_point_id);
CREATE INDEX IF NOT EXISTS manifest_route_city_id_fkx ON brd.manifest_route (city_id);
CREATE INDEX IF NOT EXISTS manifest_route_company_id_fkx ON brd.manifest_route (company_id);
CREATE INDEX IF NOT EXISTS manifest_route_created_by_fkx ON brd.manifest_route (created_by);
CREATE INDEX IF NOT EXISTS manifest_route_approved_by_fkx ON brd.manifest_route (approved_by);
COMMENT ON TABLE brd.manifest_route IS 'Which authority receives which manifests and how; activated only by a second platform officer; empty filters match every trip (11.10)';

CREATE TABLE IF NOT EXISTS brd.manifest_delivery (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid              uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  manifest_id      bigint NOT NULL REFERENCES brd.manifest(id),
  route_id         bigint NOT NULL REFERENCES brd.manifest_route(id),
  authority_id     bigint NOT NULL REFERENCES sec.authority_profile(id),
  channel          text NOT NULL CHECK (channel IN ('API_PUSH','API_PULL','PORTAL','EMAIL','MANUAL')),
  status           text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','AVAILABLE','SENT','ACKNOWLEDGED','REJECTED','FAILED','MANUAL')),
  attempts         smallint NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  next_attempt_at  timestamptz NOT NULL DEFAULT now(),
  ack_ref          text,
  reject_reason    text,
  last_error       text,
  sent_at          timestamptz,
  acknowledged_at  timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (manifest_id, authority_id)
);
CREATE INDEX IF NOT EXISTS manifest_delivery_due ON brd.manifest_delivery (next_attempt_at) WHERE status = 'PENDING';
CREATE INDEX IF NOT EXISTS manifest_delivery_route_id_fkx ON brd.manifest_delivery (route_id);
CREATE INDEX IF NOT EXISTS manifest_delivery_authority_id_fkx ON brd.manifest_delivery (authority_id, created_at DESC);
COMMENT ON TABLE brd.manifest_delivery IS 'One delivery of a manifest version to one authority: pushed, offered for pull, or handled by hand; the carrier sees its status (11.10)';

-- ------------------------------ isolation between companies, carriers and shippers ------------------------------
-- Containers: the owner, whoever carries them on a leg they see, and the platform
SELECT sys.rls('frt.container', 'sys.ctx_is_platform() OR owner_party_id = sys.ctx_party_id() OR owner_party_id = sys.ctx_company_id()'
  || ' OR EXISTS (SELECT 1 FROM frt.leg_container lc WHERE lc.container_id = container.id AND frt.can_see_leg(lc.leg_id))');

-- Open loads: the shipper and the platform read the request; carriers see the market through frt.open_loads(),
-- which gives the load without the shipper's identity, addresses or contacts
CREATE OR REPLACE FUNCTION frt.carries_request(p_request_id bigint) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT sys.ctx_company_id() IS NOT NULL
     AND EXISTS (SELECT 1 FROM frt.freight_contract c WHERE c.request_id = p_request_id AND c.carrier_company_id = sys.ctx_company_id()
                    AND c.status <> 'CANCELLED')
$$;
SELECT sys.rls('frt.freight_request', 'frt.can_see_request(id) OR frt.carries_request(id)');

CREATE OR REPLACE FUNCTION frt.open_loads() RETURNS TABLE (
  id bigint, uid uuid, cargo_category text, cargo_description text, declared_weight_kg numeric, packages int,
  required_trailer_type text, pickup_from timestamptz, pickup_to timestamptz, target_price bigint, currency char(3),
  status text, created_at timestamptz, origin text, destination text, origin_code text, destination_code text, bids bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT r.id, r.uid, r.cargo_category, r.cargo_description, r.declared_weight_kg, r.packages, r.required_trailer_type,
         lower(r.pickup_window), upper(r.pickup_window), r.target_price, r.currency, r.status, r.created_at,
         os.name, ds.name, os.code, ds.code,
         (SELECT count(*) FROM frt.freight_bid b WHERE b.request_id = r.id AND b.status = 'SUBMITTED')
    FROM frt.freight_request r
    LEFT JOIN net.station os ON os.id = r.origin_station_id LEFT JOIN net.station ds ON ds.id = r.dest_station_id
   WHERE r.status = 'OPEN' AND r.mode = 'BID'
     AND r.shipper_company_id IS DISTINCT FROM sys.ctx_company_id()
     AND EXISTS (SELECT 1 FROM iam.company co WHERE co.id = sys.ctx_company_id() AND co.approval_status = 'APPROVED'
                    AND co.company_type IN ('CARRIER','INDIVIDUAL_OPERATOR','FOREIGN_CARRIER'))
$$;
COMMENT ON FUNCTION frt.open_loads IS 'The freight market seen by an approved carrier: open loads without the shipper''s identity, addresses or contacts (16.26)';

-- Commercial data of a company: its own staff and the platform; customers (no company) still read published prices
SELECT sys.rls_split('ship.cargo_rate_card', 'company_id IS NULL OR sys.tenant_visible(company_id) OR sys.ctx_company_id() IS NULL',
  'sys.tenant_visible(company_id)');
SELECT sys.rls_split('ship.rate_table', 'company_id IS NULL OR sys.tenant_visible(company_id) OR sys.ctx_company_id() IS NULL',
  'CASE WHEN company_id IS NULL THEN sys.ctx_is_platform() ELSE sys.tenant_visible(company_id) END');
SELECT sys.rls_split('ship.hub', 'company_id IS NULL OR sys.tenant_visible(company_id) OR sys.ctx_company_id() IS NULL',
  'CASE WHEN company_id IS NULL THEN sys.ctx_is_platform() ELSE sys.tenant_visible(company_id) END');
SELECT sys.rls_split('ship.routing_rule', 'company_id IS NULL OR sys.tenant_visible(company_id)',
  'CASE WHEN company_id IS NULL THEN sys.ctx_is_platform() ELSE sys.tenant_visible(company_id) END');
SELECT sys.rls_split('ship.linehaul_schedule', 'sys.tenant_visible(carrier_company_id) OR sys.ctx_company_id() IS NULL',
  'sys.tenant_visible(carrier_company_id)');

SELECT sys.rls_split('rent.rental_fleet', 'sys.tenant_visible(company_id) OR sys.ctx_company_id() IS NULL', 'sys.tenant_visible(company_id)');
SELECT sys.rls_split('rent.rental_rate', 'sys.tenant_visible(company_id) OR sys.ctx_company_id() IS NULL', 'sys.tenant_visible(company_id)');
SELECT sys.rls_split('pricing.award_seat_rule', 'sys.tenant_visible(company_id) OR sys.ctx_company_id() IS NULL', 'sys.tenant_visible(company_id)');

-- Sessions: the sign-in path (no user yet), the user's own sessions, a company's own staff and the platform; never another company's
SELECT sys.rls('iam.user_session', 'sys.ctx_is_platform() OR sys.ctx_user_id() IS NULL OR user_id = sys.ctx_user_id()'
  || ' OR (company_id IS NOT NULL AND sys.tenant_visible(company_id))');

-- ------------------------------ policies and privileges of the new tables ------------------------------
DO $$ BEGIN
  PERFORM sys.rls_split('pricing.passenger_age_band', 'true',
    'CASE WHEN company_id IS NULL THEN sys.ctx_is_platform() ELSE sys.tenant_visible(company_id) END');
  PERFORM sys.rls_split('pricing.category_fare_rule', 'true',
    'CASE WHEN company_id IS NULL THEN sys.ctx_is_platform() ELSE sys.tenant_visible(company_id) END');
  PERFORM sys.rls_split('pricing.family_offer', 'status = ''ACTIVE'' OR sys.tenant_visible(company_id)', 'sys.tenant_visible(company_id)');
  PERFORM sys.rls_split('iam.family', 'sys.ctx_is_platform() OR head_party_id = sys.ctx_party_id() OR iam.is_member_of(id)',
    'sys.ctx_is_platform() OR head_party_id = sys.ctx_party_id()');
  PERFORM sys.rls_split('iam.family_member',
    'sys.ctx_is_platform() OR iam.is_family_head(family_id) OR (party_id = sys.ctx_party_id() AND account_status = ''LINKED'')',
    'sys.ctx_is_platform() OR iam.is_family_head(family_id)');
  PERFORM sys.rls('iam.family_link_request',
    'sys.ctx_is_platform() OR iam.is_family_head(family_id) OR requester_party_id = sys.ctx_party_id()');
  PERFORM sys.rls_split('iam.family_travel_rule',
    'EXISTS (SELECT 1 FROM iam.family_member m WHERE m.id = family_travel_rule.member_id)',
    'sys.ctx_is_platform() OR EXISTS (SELECT 1 FROM iam.family_member m WHERE m.id = family_travel_rule.member_id AND iam.is_family_head(m.family_id))');
  PERFORM sys.rls('iam.family_spend', 'sys.ctx_is_platform() OR iam.is_family_head(family_id)'
    || ' OR EXISTS (SELECT 1 FROM iam.family_member m WHERE m.id = family_spend.member_id AND m.party_id = sys.ctx_party_id())');
  PERFORM sys.rls_platform('brd.manifest_route');
  PERFORM sys.rls_parent('brd.manifest_delivery', 'manifest_id', 'brd.manifest');
  PERFORM sys.grant_rw(ARRAY['pricing.passenger_age_band','pricing.category_fare_rule','pricing.family_offer','iam.family',
    'iam.family_member','iam.family_link_request','iam.family_travel_rule','brd.manifest_route','brd.manifest_delivery']);
  PERFORM sys.grant_append(ARRAY['iam.family_spend']);
  PERFORM sys.track_updates(t) FROM unnest(ARRAY['pricing.passenger_age_band','iam.family','iam.family_member']) t;
END $$;
GRANT SELECT ON brd.manifest_route, brd.manifest_delivery TO masslak_auditor;
REVOKE ALL ON FUNCTION frt.open_loads() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION frt.open_loads() TO masslak_app;

-- Changes to categories, offers, families and manifest routes are evidence (who changed a price, a limit, a route)
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['pricing.passenger_age_band','pricing.category_fare_rule','pricing.family_offer','iam.family',
                           'iam.family_member','iam.family_link_request','iam.family_travel_rule','brd.manifest_route']
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS zz_audit_capture ON %s', t);
    EXECUTE format('CREATE TRIGGER zz_audit_capture AFTER INSERT OR UPDATE OR DELETE ON %s FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change()', t);
  END LOOP;
END $$;

-- ------------------------------ platform defaults, permissions and switches ------------------------------
INSERT INTO pricing.passenger_age_band (company_id, category, min_age, max_age, seat_required, needs_adult, max_per_adult)
SELECT NULL, x.c, x.lo, x.hi, x.seat, x.adult, x.per FROM (VALUES
  ('INFANT', 0, 2, false, true, 1), ('CHILD', 2, 12, true, true, NULL), ('ADULT', 12, NULL, true, false, NULL)
) AS x(c, lo, hi, seat, adult, per)
WHERE NOT EXISTS (SELECT 1 FROM pricing.passenger_age_band b WHERE b.company_id IS NULL AND b.category = x.c AND b.status = 'ACTIVE');

INSERT INTO pricing.category_fare_rule (company_id, category, method, value)
SELECT NULL, x.c, 'PCT_OF_ADULT', x.v FROM (VALUES ('CHILD', 75), ('INFANT', 10)) AS x(c, v)
WHERE NOT EXISTS (SELECT 1 FROM pricing.category_fare_rule r WHERE r.company_id IS NULL AND r.category = x.c AND r.status = 'ACTIVE');

INSERT INTO iam.permission (code, module, scope, description, is_sensitive) VALUES
  ('fares.categories','pricing','BOTH','Passenger age bands, child and infant fares, and family offers',false),
  ('manifest.issue','brd','COMPANY','Issue, amend and cancel the manifests of the company''s trips',true),
  ('manifest.routes','brd','PLATFORM','Decide which authorities receive manifests and approve the routes (four eyes)',true)
ON CONFLICT (code) DO NOTHING;
INSERT INTO iam.role_permission (role_id, permission_code)
SELECT r.id, x.p FROM iam.role r JOIN (VALUES
  ('PLATFORM_ADMIN','fares.categories'),('PLATFORM_ADMIN','manifest.routes'),('PLATFORM_SECURITY','manifest.routes'),
  ('CARRIER_OPERATIONS','manifest.issue'),('CARRIER_OPERATIONS','fares.categories'),('CARRIER_ACCOUNTANT','fares.categories')
) AS x(r, p) ON x.r = r.code AND r.company_id IS NULL
ON CONFLICT DO NOTHING;

UPDATE sys.setting SET value = value || '{"passenger_categories": true, "family_accounts": true, "trip_manifests": true}'::jsonb
 WHERE key = 'features' AND NOT (value ? 'passenger_categories' AND value ? 'family_accounts' AND value ? 'trip_manifests');

INSERT INTO sys.schema_migration (version, description)
SELECT '1.21.0', 'Passenger categories and family accounts, carrier-issued manifests with authority routing, isolation of commercial data'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.21.0');
