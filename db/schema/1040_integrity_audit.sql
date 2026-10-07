-- =====================================================================
-- 1040: integrity audit (strategic review of study v2.9 / design v3.3, and the 1,304-relationship audit register)
--   The register lists 136 relationships for review. Each was checked against this database; the disposition of
--   every one is in docs/database/INTEGRITY_AUDIT.md. This file adds what the check found missing.
--
--   A  The sale chain: a ticket, its booking, its passenger, its seats and its scans belong to one trip;     (C-03, F-001, F-002)
--      a ticket sells only its carrier's fare brands; tax jurisdictions form a tree                         (FK-0327, FK-0414)
--   B  Manifests list tickets of their own trip; a cargo leg rides a trip of its carrier                      (C-03)
--   C  A payment draws only on the payer's own wallet or the paying agency's                                  (C-03)
--   D  Tenant guards on the references that had none; vehicles follow ownership or an active lease            (F-003, F-004)
--   E  One company wallet per company and currency                                                           (H-02, F-006)
--   F  The seat hold has one record: the LOCKED row of ops.seat_segment                                       (C-01)
--   G  Inventories for governance tests: cross-schema dependencies and JSONB columns                          (H-07, M-02, F-011)
--
--   Rules that are structural (all columns NOT NULL, one parent) are composite foreign keys: they cannot be
--   switched off by a trigger setting and hold for COPY as for INSERT. Rules with an exception (a scan of a ticket
--   presented on the wrong trip is recorded on purpose; a leased vehicle belongs to another company; a shared
--   platform row has no company) are triggers, BEFORE INSERT OR UPDATE, row level, not deferrable.
-- =====================================================================

-- =====================================================================
-- A  The sale chain
-- =====================================================================
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'booking_id_trip_uq') THEN
    ALTER TABLE sales.booking ADD CONSTRAINT booking_id_trip_uq UNIQUE (id, trip_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'passenger_id_booking_uq') THEN
    ALTER TABLE sales.passenger ADD CONSTRAINT passenger_id_booking_uq UNIQUE (id, booking_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ticket_id_trip_uq') THEN
    ALTER TABLE sales.ticket ADD CONSTRAINT ticket_id_trip_uq UNIQUE (id, trip_id);
  END IF;
  -- a ticket travels on the trip of its booking
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ticket_booking_trip_fk') THEN
    ALTER TABLE sales.ticket ADD CONSTRAINT ticket_booking_trip_fk
      FOREIGN KEY (booking_id, trip_id) REFERENCES sales.booking (id, trip_id) NOT VALID;
  END IF;
  -- a ticket is issued to a passenger of its booking
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ticket_passenger_booking_fk') THEN
    ALTER TABLE sales.ticket ADD CONSTRAINT ticket_passenger_booking_fk
      FOREIGN KEY (passenger_id, booking_id) REFERENCES sales.passenger (id, booking_id) NOT VALID;
  END IF;
  -- a sold seat segment belongs to the trip of its ticket
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'seat_segment_ticket_trip_fk') THEN
    ALTER TABLE ops.seat_segment ADD CONSTRAINT seat_segment_ticket_trip_fk
      FOREIGN KEY (ticket_id, trip_id) REFERENCES sales.ticket (id, trip_id) NOT VALID;
  END IF;
END $$;

-- A scan records the trip it happened on. A ticket presented on another trip is recorded as WRONG_TRIP (the
-- evidence of a refused boarding); every other result must name the ticket's own trip.
CREATE OR REPLACE FUNCTION sales.tg_boarding_ticket_trip() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE t bigint;
BEGIN
  IF NEW.ticket_id IS NULL THEN RETURN NEW; END IF;
  SELECT trip_id INTO t FROM sales.ticket WHERE id = NEW.ticket_id;
  IF NEW.result = 'WRONG_TRIP' THEN
    IF t = NEW.trip_id THEN
      RAISE EXCEPTION 'SCAN_NOT_WRONG_TRIP: the ticket belongs to this trip' USING ERRCODE = 'P0001';
    END IF;
  ELSIF t IS DISTINCT FROM NEW.trip_id THEN
    RAISE EXCEPTION 'TICKET_OTHER_TRIP: a scan of a ticket of another trip is recorded as WRONG_TRIP' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS boarding_ticket_trip ON sales.boarding_event;
CREATE TRIGGER boarding_ticket_trip BEFORE INSERT OR UPDATE OF ticket_id, trip_id, result ON sales.boarding_event
  FOR EACH ROW EXECUTE FUNCTION sales.tg_boarding_ticket_trip();

-- A fare brand is the platform's (no company) or the carrier's own; a ticket never sells another carrier's brand
CREATE OR REPLACE FUNCTION sales.tg_ticket_fare_brand() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.fare_brand_code IS NOT NULL AND EXISTS (
       SELECT 1 FROM pricing.fare_brand f JOIN sales.booking b ON b.id = NEW.booking_id
        WHERE f.code = NEW.fare_brand_code AND f.company_id IS NOT NULL AND f.company_id <> b.company_id) THEN
    RAISE EXCEPTION 'TENANT_MISMATCH: the fare brand belongs to another carrier' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS ticket_fare_brand ON sales.ticket;
CREATE TRIGGER ticket_fare_brand BEFORE INSERT OR UPDATE OF fare_brand_code, booking_id ON sales.ticket
  FOR EACH ROW EXECUTE FUNCTION sales.tg_ticket_fare_brand();

-- Tax jurisdictions form a tree: a parent is never the row itself or one of its descendants
CREATE OR REPLACE FUNCTION pricing.tg_jurisdiction_tree() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.parent_id IS NOT NULL AND EXISTS (
       WITH RECURSIVE up AS (SELECT id, parent_id FROM pricing.jurisdiction WHERE id = NEW.parent_id
                             UNION SELECT j.id, j.parent_id FROM pricing.jurisdiction j JOIN up ON j.id = up.parent_id)
       SELECT 1 FROM up WHERE id = NEW.id) THEN
    RAISE EXCEPTION 'JURISDICTION_CYCLE: a jurisdiction cannot sit under itself' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS jurisdiction_tree ON pricing.jurisdiction;
CREATE TRIGGER jurisdiction_tree BEFORE INSERT OR UPDATE OF parent_id ON pricing.jurisdiction
  FOR EACH ROW EXECUTE FUNCTION pricing.tg_jurisdiction_tree();

-- =====================================================================
-- B  Manifests and cargo legs
-- =====================================================================
CREATE OR REPLACE FUNCTION brd.tg_manifest_person_trip() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.ticket_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM brd.manifest m JOIN sales.ticket k ON k.trip_id = m.trip_id
        WHERE m.id = NEW.manifest_id AND k.id = NEW.ticket_id) THEN
    RAISE EXCEPTION 'MANIFEST_TICKET_OTHER_TRIP: a manifest lists only tickets of its own trip' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS manifest_person_trip ON brd.manifest_person;
CREATE TRIGGER manifest_person_trip BEFORE INSERT OR UPDATE OF manifest_id, ticket_id ON brd.manifest_person
  FOR EACH ROW EXECUTE FUNCTION brd.tg_manifest_person_trip();

CREATE OR REPLACE FUNCTION ship.tg_leg_trip_carrier() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.trip_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM ops.trip t WHERE t.id = NEW.trip_id AND t.company_id = NEW.carrier_company_id) THEN
    RAISE EXCEPTION 'LEG_TRIP_OTHER_CARRIER: a cargo leg rides a trip operated by its carrier' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS leg_trip_carrier ON ship.shipment_leg;
CREATE TRIGGER leg_trip_carrier BEFORE INSERT OR UPDATE OF trip_id, carrier_company_id ON ship.shipment_leg
  FOR EACH ROW EXECUTE FUNCTION ship.tg_leg_trip_carrier();

-- =====================================================================
-- C  Payments draw on the payer's own wallet
-- =====================================================================
-- Anyone may pay for a booking through a gateway (a parent for a child, an agency for a client), so the payer is
-- not tied to the booker. A wallet, however, is money: it must be the payer's own, or the paying agency's.
CREATE OR REPLACE FUNCTION fin.tg_payment_wallet_owner() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.wallet_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM fin.wallet w WHERE w.id = NEW.wallet_id
          AND (w.owner_party_id = NEW.payer_party_id OR (NEW.agency_company_id IS NOT NULL AND w.company_id = NEW.agency_company_id))) THEN
    RAISE EXCEPTION 'WALLET_NOT_PAYERS: a payment draws only on the payer''s own wallet' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS payment_wallet_owner ON fin.payment;
CREATE TRIGGER payment_wallet_owner BEFORE INSERT OR UPDATE OF wallet_id, payer_party_id, agency_company_id ON fin.payment
  FOR EACH ROW EXECUTE FUNCTION fin.tg_payment_wallet_owner();

-- =====================================================================
-- D  Tenant guards
-- =====================================================================
-- Not every company column means the same thing. A service partner (ptn.partner) is a company of its own: a
-- fuel station's sale names the carrier that pays in company_id and the station in partner_id, so references to a
-- partner are deliberately not tied to the row's company.
--
-- sys.tg_same_company (1039) gains an optional third argument: the key column of the parent (crew profiles are
-- keyed by party_id). A parent row without a company is a shared platform row and may be referenced by anyone.
CREATE OR REPLACE FUNCTION sys.tg_same_company() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE fk_col text := TG_ARGV[0]; parent text := TG_ARGV[1]; key_col text := coalesce(TG_ARGV[2], 'id');
        ref bigint; mine bigint; theirs bigint;
BEGIN
  ref := (to_jsonb(NEW) ->> fk_col)::bigint;
  mine := (to_jsonb(NEW) ->> 'company_id')::bigint;
  IF ref IS NULL OR mine IS NULL THEN RETURN NEW; END IF;
  EXECUTE format('SELECT company_id FROM %s WHERE %I = $1', parent, key_col) INTO theirs USING ref;
  IF theirs IS NOT NULL AND theirs <> mine THEN
    RAISE EXCEPTION 'TENANT_MISMATCH: %.% points to a row of another company (% -> %)', TG_TABLE_NAME, fk_col, parent, ref
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;

-- A vehicle may serve the company that owns it or a company that holds an active lease on it (fleet.vehicle_lease).
-- A plain same-company rule, or a composite key, would refuse every leased vehicle.
CREATE OR REPLACE FUNCTION fleet.vehicle_usable_by(p_vehicle bigint, p_company bigint) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM fleet.vehicle v WHERE v.id = p_vehicle AND v.company_id = p_company)
      OR EXISTS (SELECT 1 FROM fleet.vehicle_lease l WHERE l.vehicle_id = p_vehicle AND l.lessee_company_id = p_company
                    AND l.status = 'ACTIVE')
$$;
COMMENT ON FUNCTION fleet.vehicle_usable_by IS 'The vehicle is owned by the company or leased to it (integrity audit 1040)';

CREATE OR REPLACE FUNCTION fleet.tg_vehicle_of_company() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE fk_col text := TG_ARGV[0]; ref bigint; mine bigint;
BEGIN
  ref := (to_jsonb(NEW) ->> fk_col)::bigint;
  mine := (to_jsonb(NEW) ->> 'company_id')::bigint;
  IF ref IS NULL OR mine IS NULL THEN RETURN NEW; END IF;
  IF NOT fleet.vehicle_usable_by(ref, mine) THEN
    RAISE EXCEPTION 'VEHICLE_NOT_OWNED_OR_LEASED: %.% names a vehicle of another company', TG_TABLE_NAME, fk_col USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;

DO $$
DECLARE r record;
BEGIN
  -- references to a vehicle
  FOR r IN SELECT * FROM (VALUES
    ('ops.trip','vehicle_id'), ('ops.trip_template','default_vehicle_id'), ('ops.incident','vehicle_id'),
    ('sales.inspection_check','vehicle_id'), ('ptn.fuel_card','vehicle_id'), ('ptn.fuel_session','vehicle_id'),
    ('ptn.partner_sale','vehicle_id'), ('ship.load','vehicle_id'), ('ship.courier_route','vehicle_id')
  ) AS t(tbl, col) LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', left('vehicle_of_company_' || r.col, 63), r.tbl);
    EXECUTE format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE OF %I, company_id ON %s FOR EACH ROW EXECUTE FUNCTION fleet.tg_vehicle_of_company(%L)',
                   left('vehicle_of_company_' || r.col, 63), r.col, r.tbl, r.col);
  END LOOP;

  -- references to a row of the same company (parent key in the third column when it is not id)
  FOR r IN SELECT * FROM (VALUES
    ('iam.document','owner_incident_id','ops.incident',NULL), ('iam.document','owner_license_id','fleet.license_record',NULL),
    ('fleet.license_record','subject_trailer_id','fleet.trailer',NULL),
    ('fleet.driving_hours_log','party_id','fleet.crew_profile','party_id'),
    ('fleet.truck_combination','driver_party_id','fleet.crew_profile','party_id'),
    ('sales.subscription','family_offer_id','pricing.family_offer',NULL), ('sales.subscription','wallet_id','fin.wallet',NULL),
    ('sales.inspection_check','trip_id','ops.trip',NULL),
    ('bill.carrier_invoice','einvoice_document_id','acct.einvoice_document',NULL),
    ('acct.sales_invoice','source_booking_id','sales.booking',NULL), ('acct.sales_invoice','source_shipment_id','ship.shipment',NULL),
    ('acct.sales_invoice','source_subscription_id','sales.subscription',NULL),
    ('acct.einvoice_document','source_booking_id','sales.booking',NULL), ('acct.einvoice_document','source_shipment_id','ship.shipment',NULL),
    ('acct.einvoice_document','source_subscription_id','sales.subscription',NULL),
    ('crm.ai_conversation','escalated_case_id','crm."case"',NULL), ('crm.call','ai_conversation_id','crm.ai_conversation',NULL),
    ('ptn.fuel_card','driver_party_id','fleet.crew_profile','party_id'),
    ('ptn.fuel_session','driver_party_id','fleet.crew_profile','party_id'), ('ptn.fuel_session','fuel_card_id','ptn.fuel_card',NULL),
    ('ptn.fuel_session','trip_id','ops.trip',NULL), ('ptn.partner_sale','session_id','ptn.fuel_session',NULL),
    ('ptn.partner_sale','trip_id','ops.trip',NULL),
    ('ship.load','trip_id','ops.trip',NULL), ('ship.load','truck_combination_id','fleet.truck_combination',NULL),
    ('rail.coach_layout','seat_layout_id','fleet.seat_layout',NULL), ('rpt.report_run','api_client_id','iam.api_client',NULL)
  ) AS t(tbl, col, parent, key_col) LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', left('same_company_' || r.col, 63), r.tbl);
    IF r.key_col IS NULL THEN
      EXECUTE format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE OF %I, company_id ON %s FOR EACH ROW EXECUTE FUNCTION sys.tg_same_company(%L, %L)',
                     left('same_company_' || r.col, 63), r.col, r.tbl, r.col, r.parent);
    ELSE
      EXECUTE format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE OF %I, company_id ON %s FOR EACH ROW EXECUTE FUNCTION sys.tg_same_company(%L, %L, %L)',
                     left('same_company_' || r.col, 63), r.col, r.tbl, r.col, r.parent, r.key_col);
    END IF;
  END LOOP;
END $$;

-- =====================================================================
-- E  One company wallet per company and currency
-- =====================================================================
-- The COMPANY wallet is the carrier's account with the platform: one per currency. Other wallets a company may hold
-- (cash collection per cashier, expense, deposit) can be several and are keyed by their owner party.
CREATE UNIQUE INDEX IF NOT EXISTS wallet_company_currency_uq ON fin.wallet (company_id, currency)
  WHERE wallet_type = 'COMPANY';
COMMENT ON INDEX fin.wallet_company_currency_uq IS 'One COMPANY wallet per company and currency (integrity audit H-02)';

-- =====================================================================
-- F  The seat hold has one record
-- =====================================================================
-- ops.seat_lock was described in 1013 as a copy of an in-memory lock. There is no in-memory lock: a hold is the
-- LOCKED row of ops.seat_segment, taken by one atomic UPDATE (study 16.28). The table stays as an audit trail only.
COMMENT ON TABLE ops.seat_lock IS 'Audit trail of seat holds. Never read to decide availability: the hold itself is the LOCKED row of ops.seat_segment (study 16.28)';

-- The polymorphic pairs that 1039 backed with typed foreign keys still said "integrity is kept by the service";
-- their comments now say what holds them (H-01: 14 of the 25 pairs are database-enforced)
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT c.oid::regclass::text AS tbl, a.attname AS col
             FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
            WHERE col_description(a.attrelid, a.attnum) LIKE 'Polymorphic:%integrity is kept by the service that writes it'
              AND EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgrelid = c.oid AND t.tgname LIKE '%typed_ref%'
                             AND pg_get_triggerdef(t.oid) LIKE '%' || quote_literal(a.attname) || '%') LOOP
    EXECUTE format('COMMENT ON COLUMN %s.%I IS %L', r.tbl, r.col,
      replace(col_description(r.tbl::regclass, (SELECT attnum FROM pg_attribute WHERE attrelid = r.tbl::regclass AND attname = r.col)),
              'integrity is kept by the service that writes it',
              'each allowed type is also a real foreign-key column, set by a trigger (sys.typed_reference, 1039)'));
  END LOOP;
END $$;

-- =====================================================================
-- G  Inventories for governance tests
-- =====================================================================
-- Cross-schema foreign-key edges. db/tests checks that no schema pair becomes mutually dependent unless it is in the
-- reviewed baseline there, so a new two-way dependency needs a conscious decision.
CREATE OR REPLACE VIEW sys.v_schema_dependency AS
SELECT DISTINCT cn.nspname AS from_schema, pn.nspname AS to_schema
  FROM pg_constraint c
  JOIN pg_class cc ON cc.oid = c.conrelid JOIN pg_namespace cn ON cn.oid = cc.relnamespace
  JOIN pg_class pc ON pc.oid = c.confrelid JOIN pg_namespace pn ON pn.oid = pc.relnamespace
 WHERE c.contype = 'f' AND cn.nspname <> pn.nspname;
COMMENT ON VIEW sys.v_schema_dependency IS 'Cross-schema foreign-key edges (integrity audit H-07)';

-- JSONB columns. db/tests checks that none is used by a security policy, a foreign key or an index expression:
-- what is filtered on, joined on, secured on or computed with money is a typed column (STANDARDS.md).
CREATE OR REPLACE VIEW sys.v_jsonb_inventory AS
SELECT n.nspname || '.' || c.relname AS table_name, a.attname AS column_name, col_description(a.attrelid, a.attnum) AS purpose
  FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE a.atttypid = 'jsonb'::regtype AND a.attnum > 0 AND NOT a.attisdropped
   AND c.relkind IN ('r','p') AND NOT c.relispartition AND n.nspname NOT IN ('pg_catalog','information_schema');
COMMENT ON VIEW sys.v_jsonb_inventory IS 'Every JSONB column (integrity audit M-02)';
GRANT SELECT ON sys.v_schema_dependency, sys.v_jsonb_inventory TO masslak_auditor;

INSERT INTO sys.schema_migration (version, description)
SELECT '1.22.0', 'Integrity audit: sale chain composite keys, manifest and cargo trip rules, wallet ownership, tenant guards, company wallet uniqueness, governance inventories'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.22.0');

-- Composite keys added NOT VALID are validated now; existing rows that break one are reported, not hidden
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT conrelid::regclass::text AS t, conname FROM pg_constraint
            WHERE NOT convalidated AND conname IN ('ticket_booking_trip_fk','ticket_passenger_booking_fk','seat_segment_ticket_trip_fk') LOOP
    BEGIN
      EXECUTE format('ALTER TABLE %s VALIDATE CONSTRAINT %I', r.t, r.conname);
    EXCEPTION WHEN foreign_key_violation THEN
      RAISE WARNING 'EXISTING_ROWS_BREAK_RULE: % on %: new rows are checked, existing ones need review', r.conname, r.t;
    END;
  END LOOP;
END $$;
