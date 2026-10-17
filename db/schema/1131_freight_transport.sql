-- =====================================================================
-- 1131  Truck transport of goods and containers: inside Syria, from and to the port, across borders and in transit
--       (owner's request, October 2026; extends the freight base of 1018, phase 8)
-- =====================================================================
-- Route kinds: inside Syria (DOMESTIC), from the port into the country (PORT_IMPORT), from the country to the port
-- (PORT_EXPORT), out of the country by land (EXPORT), into the country by land (IMPORT), from the port out of the country
-- in transit (TRANSIT_PORT_OUT), from abroad to the port in transit (TRANSIT_IN_PORT), and across the country between two
-- borders (TRANSIT_LAND).
--
-- A container carried from the port belongs to the shipping line's bill of lading (frt.bill_of_lading): its number, the
-- shipping line, the customs release (فسح) number, how many containers the bill covers, and the freight forwarder's
-- house bills (frt.house_bill). Its containers (frt.bl_container) carry valid ISO 6346 numbers, no more than the bill
-- declares, with the empty-return depot and the shipping line's free time.
--
-- A consignment (frt.consignment) is what the platform transports and documents: the shipper (seller) and the consignee
-- (buyer), where it is loaded and delivered, the destination country, the border crossings or the port, the commercial
-- invoices it carries (frt.consignment_invoice), the export approval and its number, the customs declaration, the cargo
-- and, in containers, their numbers (frt.consignment_container). Trucks carry it in movements (frt.truck_movement), each
-- with the truck, the trailer and the driver as they were, the containers on it within the trailer's capacity, and the
-- price from the truck owner's rate card (frt.rate_card): the truck owner, company or person, sets its own prices.
--
-- The platform issues the documents (frt.transport_document): the consignment note (the platform's bill for the whole
-- consignment, inside or across borders) and, inside Syria, the truck consignment note (TCN) for one consignment or for
-- several in one statement, with every truck and trailer. A document is a frozen snapshot with its SHA-256 and a
-- verification code; it is never changed, only voided or replaced by a new version.
--
-- The truck owner invoices the transport (frt.transport_invoice): one invoice for the whole bill of lading and its
-- containers, one per container, or one for the consignment; a container is never invoiced twice.

-- ------------------------------------------------------------------ helpers
CREATE OR REPLACE FUNCTION frt.iso6346_ok(p_no text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE STRICT SET search_path = pg_catalog, pg_temp AS $$
-- ISO 6346: owner code (3 letters), category (U, J or Z), serial (6 digits) and the check digit
DECLARE
  v int[] := ARRAY[10,12,13,14,15,16,17,18,19,20,21,23,24,25,26,27,28,29,30,31,32,34,35,36,37,38];   -- A..Z, skipping multiples of 11
  s int := 0; c text; d int;
BEGIN
  IF p_no !~ '^[A-Z]{3}[UJZ][0-9]{7}$' THEN
    RETURN false;
  END IF;
  FOR i IN 1..10 LOOP
    c := substr(p_no, i, 1);
    d := CASE WHEN c ~ '[0-9]' THEN c::int ELSE v[ascii(c) - 64] END;
    s := s + d * (1 << (i - 1));
  END LOOP;
  RETURN (s % 11) % 10 = substr(p_no, 11, 1)::int;
END $$;
COMMENT ON FUNCTION frt.iso6346_ok IS 'A container number with a valid ISO 6346 check digit (1131)';

CREATE OR REPLACE FUNCTION frt.container_feet(p_size_type text) RETURNS smallint
LANGUAGE sql IMMUTABLE STRICT SET search_path = pg_catalog, pg_temp AS $$
  -- the first character of the ISO size and type code gives the length: 2 = 20 ft, 4 = 40 ft, L = 45 ft
  SELECT CASE upper(left(p_size_type, 1)) WHEN '2' THEN 20 WHEN '4' THEN 40 WHEN 'L' THEN 45 END::smallint
$$;
COMMENT ON FUNCTION frt.container_feet IS 'Length of a container in feet from its ISO size and type code (1131)';

-- numbers of documents (platform-wide) and invoices (per carrier), by year, never reused
CREATE TABLE IF NOT EXISTS frt.number_series (
  series      text NOT NULL,
  company_id  bigint NOT NULL DEFAULT 0,
  year        smallint NOT NULL,
  last_no     int NOT NULL DEFAULT 0 CHECK (last_no >= 0),
  PRIMARY KEY (series, company_id, year)
);
COMMENT ON TABLE frt.number_series IS 'The last number given in each series of freight documents and invoices, by year (1131)';

CREATE OR REPLACE FUNCTION frt.next_number(p_series text, p_company bigint DEFAULT 0) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE y smallint := extract(year FROM now() AT TIME ZONE 'Asia/Damascus')::smallint; n int;
BEGIN
  INSERT INTO frt.number_series (series, company_id, year, last_no) VALUES (p_series, coalesce(p_company, 0), y, 1)
  ON CONFLICT (series, company_id, year) DO UPDATE SET last_no = frt.number_series.last_no + 1
  RETURNING last_no INTO n;
  RETURN n;
END $$;

-- ------------------------------------------------------------------ shipping lines
CREATE TABLE IF NOT EXISTS frt.shipping_line (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code        text NOT NULL UNIQUE CHECK (code ~ '^[A-Z0-9]{2,6}$'),     -- SCAC or the line's usual code
  name        text NOT NULL CHECK (length(name) BETWEEN 2 AND 120),
  country     char(2) REFERENCES ref.country(code),
  status      text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','RETIRED'))
);
COMMENT ON TABLE frt.shipping_line IS 'Shipping lines that issue bills of lading for the containers trucks carry from and to the port (1131)';
INSERT INTO frt.shipping_line (code, name, country) VALUES
  ('MAEU', 'Maersk', 'DK'), ('MSCU', 'Mediterranean Shipping Company', 'CH'), ('CMDU', 'CMA CGM', 'FR'),
  ('HLCU', 'Hapag-Lloyd', 'DE'), ('COSU', 'COSCO Shipping', 'CN'), ('ONEY', 'Ocean Network Express', 'SG'),
  ('EGLV', 'Evergreen', 'TW'), ('YMLU', 'Yang Ming', 'TW'), ('ZIMU', 'ZIM', 'IL'), ('ARKU', 'Arkas', 'TR')
ON CONFLICT (code) DO NOTHING;

-- ------------------------------------------------------------------ bills of lading and their containers
CREATE TABLE IF NOT EXISTS frt.bill_of_lading (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                 uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  company_id          bigint NOT NULL REFERENCES iam.company(id),          -- who registered it (carrier, forwarder)
  shipping_line_id    bigint NOT NULL REFERENCES frt.shipping_line(id),
  bl_no               text NOT NULL CHECK (bl_no ~ '^[A-Z0-9][A-Z0-9/-]{3,34}$'),
  direction           text NOT NULL DEFAULT 'IMPORT' CHECK (direction IN ('IMPORT','EXPORT','TRANSIT')),
  vessel              text CHECK (vessel IS NULL OR length(vessel) <= 80),
  voyage              text CHECK (voyage IS NULL OR length(voyage) <= 30),
  port_of_loading     text CHECK (port_of_loading IS NULL OR port_of_loading ~ '^[A-Z]{2}[A-Z0-9]{3}$'),     -- UN/LOCODE
  port_of_discharge   text CHECK (port_of_discharge IS NULL OR port_of_discharge ~ '^[A-Z]{2}[A-Z0-9]{3}$'),
  port_station_id     bigint REFERENCES net.station(id),                    -- the Syrian port, where it is one
  consignee_name      text CHECK (consignee_name IS NULL OR length(consignee_name) <= 200),
  notify_name         text CHECK (notify_name IS NULL OR length(notify_name) <= 200),
  container_count     smallint NOT NULL CHECK (container_count BETWEEN 0 AND 999),   -- as the bill declares
  release_no          text CHECK (release_no IS NULL OR release_no ~ '^[A-Za-z0-9/ -]{2,40}$'),   -- customs release (فسح)
  release_date        date,
  cargo_description   text CHECK (cargo_description IS NULL OR length(cargo_description) <= 500),
  status              text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','RELEASED','COMPLETED','CANCELLED')),
  created_by          bigint REFERENCES iam.app_user(id),
  created_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT bill_of_lading_once_uq UNIQUE (company_id, shipping_line_id, bl_no),
  CONSTRAINT bill_of_lading_release_ck CHECK (status <> 'RELEASED' OR release_no IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS bill_of_lading_shipping_line_id_fkx ON frt.bill_of_lading (shipping_line_id);
CREATE INDEX IF NOT EXISTS bill_of_lading_port_station_id_fkx ON frt.bill_of_lading (port_station_id);
CREATE INDEX IF NOT EXISTS bill_of_lading_created_by_fkx ON frt.bill_of_lading (created_by);
COMMENT ON TABLE frt.bill_of_lading IS 'The shipping line''s bill of lading: its number, line, vessel, ports, how many containers it covers and the customs release number (1131)';
COMMENT ON COLUMN frt.bill_of_lading.release_no IS 'The customs release (فسح) that lets the containers leave the port';

CREATE TABLE IF NOT EXISTS frt.house_bill (
  id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  bl_id                 bigint NOT NULL REFERENCES frt.bill_of_lading(id),
  hbl_no                text NOT NULL CHECK (hbl_no ~ '^[A-Z0-9][A-Z0-9/-]{2,34}$'),
  forwarder_name        text NOT NULL CHECK (length(forwarder_name) BETWEEN 2 AND 200),
  forwarder_company_id  bigint REFERENCES iam.company(id),
  consignee_name        text CHECK (consignee_name IS NULL OR length(consignee_name) <= 200),
  created_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT house_bill_once_uq UNIQUE (bl_id, hbl_no),
  CONSTRAINT house_bill_of_bl_uq UNIQUE (id, bl_id)
);
CREATE INDEX IF NOT EXISTS house_bill_forwarder_company_id_fkx ON frt.house_bill (forwarder_company_id);
COMMENT ON TABLE frt.house_bill IS 'A freight forwarder''s house bill of lading (in-house BL) under a shipping line''s bill (1131)';

CREATE TABLE IF NOT EXISTS frt.bl_container (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  bl_id               bigint NOT NULL REFERENCES frt.bill_of_lading(id),
  house_bill_id       bigint,
  container_no        text NOT NULL CHECK (frt.iso6346_ok(container_no)),
  size_type           text NOT NULL CHECK (size_type ~ '^[24L][0-9A-Z][0-9A-Z]{2}$' AND frt.container_feet(size_type) IS NOT NULL),
  seal_no             text CHECK (seal_no IS NULL OR seal_no ~ '^[A-Za-z0-9-]{3,20}$'),
  gross_weight_kg     int CHECK (gross_weight_kg IS NULL OR gross_weight_kg BETWEEN 1 AND 40000),
  empty_return_depot  text CHECK (empty_return_depot IS NULL OR length(empty_return_depot) <= 120),
  free_time_until     date,                                               -- the shipping line's free days end
  status              text NOT NULL DEFAULT 'AT_PORT' CHECK (status IN ('AT_PORT','ON_TRUCK','DELIVERED','EMPTY_RETURNED','CANCELLED')),
  created_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT bl_container_once_uq UNIQUE (bl_id, container_no),
  CONSTRAINT bl_container_house_fk FOREIGN KEY (house_bill_id, bl_id) REFERENCES frt.house_bill (id, bl_id)
);
CREATE INDEX IF NOT EXISTS bl_container_house_bill_fkx ON frt.bl_container (house_bill_id, bl_id) WHERE house_bill_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS bl_container_no_idx ON frt.bl_container (container_no);
COMMENT ON TABLE frt.bl_container IS 'The containers of a bill of lading, never more than it declares, each under one of its house bills where there are any (1131)';

CREATE OR REPLACE FUNCTION frt.tg_bl_container_count() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE declared int; n int;
BEGIN
  SELECT container_count INTO declared FROM frt.bill_of_lading WHERE id = NEW.bl_id FOR UPDATE;
  SELECT count(*) INTO n FROM frt.bl_container WHERE bl_id = NEW.bl_id AND status <> 'CANCELLED';
  IF n > declared THEN
    RAISE EXCEPTION 'BL_CONTAINER_COUNT: the bill of lading declares % containers', declared USING ERRCODE = 'P0001';
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS bl_container_count ON frt.bl_container;
CREATE CONSTRAINT TRIGGER bl_container_count AFTER INSERT OR UPDATE OF status, bl_id ON frt.bl_container
  FOR EACH ROW EXECUTE FUNCTION frt.tg_bl_container_count();

CREATE OR REPLACE FUNCTION frt.tg_bill_count_floor() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.container_count < (SELECT count(*) FROM frt.bl_container WHERE bl_id = NEW.id AND status <> 'CANCELLED') THEN
    RAISE EXCEPTION 'BL_CONTAINER_COUNT: the bill already lists more containers than %', NEW.container_count USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS bill_count_floor ON frt.bill_of_lading;
CREATE TRIGGER bill_count_floor BEFORE UPDATE OF container_count ON frt.bill_of_lading
  FOR EACH ROW EXECUTE FUNCTION frt.tg_bill_count_floor();

-- ------------------------------------------------------------------ consignments
CREATE TABLE IF NOT EXISTS frt.consignment (
  id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                     uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  consignment_no          text NOT NULL UNIQUE,
  company_id              bigint NOT NULL REFERENCES iam.company(id),      -- who registered it: the carrier or the forwarder
  route_kind              text NOT NULL CHECK (route_kind IN ('DOMESTIC','PORT_IMPORT','PORT_EXPORT','EXPORT','IMPORT',
                                                              'TRANSIT_PORT_OUT','TRANSIT_IN_PORT','TRANSIT_LAND')),
  international           boolean GENERATED ALWAYS AS (route_kind NOT IN ('DOMESTIC','PORT_IMPORT','PORT_EXPORT')) STORED,
  load_type               text NOT NULL CHECK (load_type IN ('FCL','LCL','BREAK_BULK','BULK','LIQUID','VEHICLES')),
  -- the seller and the buyer as the documents name them
  shipper_party_id        bigint REFERENCES iam.party(id),
  shipper_name            text NOT NULL CHECK (length(shipper_name) BETWEEN 2 AND 200),
  shipper_address         text CHECK (shipper_address IS NULL OR length(shipper_address) <= 300),
  shipper_country         char(2) NOT NULL REFERENCES ref.country(code),
  shipper_tax_no          text CHECK (shipper_tax_no IS NULL OR length(shipper_tax_no) <= 40),
  consignee_party_id      bigint REFERENCES iam.party(id),
  consignee_name          text NOT NULL CHECK (length(consignee_name) BETWEEN 2 AND 200),
  consignee_address       text CHECK (consignee_address IS NULL OR length(consignee_address) <= 300),
  consignee_country       char(2) NOT NULL REFERENCES ref.country(code),
  consignee_tax_no        text CHECK (consignee_tax_no IS NULL OR length(consignee_tax_no) <= 40),
  notify_name             text CHECK (notify_name IS NULL OR length(notify_name) <= 200),
  -- where it is loaded and delivered
  origin_country          char(2) NOT NULL REFERENCES ref.country(code),
  origin_city_id          bigint REFERENCES ref.city(id),
  origin_station_id       bigint REFERENCES net.station(id),
  origin_address          text CHECK (origin_address IS NULL OR length(origin_address) <= 300),
  dest_country            char(2) NOT NULL REFERENCES ref.country(code),
  dest_city_id            bigint REFERENCES ref.city(id),
  dest_station_id         bigint REFERENCES net.station(id),
  dest_address            text CHECK (dest_address IS NULL OR length(dest_address) <= 300),
  port_station_id         bigint REFERENCES net.station(id),              -- the Syrian port of a port or transit kind
  exit_border_id          bigint REFERENCES brd.border_point(station_id),
  entry_border_id         bigint REFERENCES brd.border_point(station_id),
  arrival_port            text CHECK (arrival_port IS NULL OR arrival_port ~ '^[A-Z]{2}[A-Z0-9]{3}$'),   -- a port abroad (UN/LOCODE)
  -- papers of the goods
  bl_id                   bigint REFERENCES frt.bill_of_lading(id),
  house_bill_id           bigint,
  export_permit_no        text CHECK (export_permit_no IS NULL OR export_permit_no ~ '^[A-Za-z0-9/ -]{2,40}$'),
  export_permit_date      date,
  customs_declaration_no  text CHECK (customs_declaration_no IS NULL OR customs_declaration_no ~ '^[A-Za-z0-9/ -]{2,40}$'),
  release_no              text CHECK (release_no IS NULL OR release_no ~ '^[A-Za-z0-9/ -]{2,40}$'),
  tir_carnet_no           text CHECK (tir_carnet_no IS NULL OR tir_carnet_no ~ '^[A-Z]{0,3}[0-9]{6,10}$'),
  incoterm                text CHECK (incoterm IS NULL OR incoterm IN ('EXW','FCA','CPT','CIP','DAP','DPU','DDP','FAS','FOB','CFR','CIF')),
  freight_payer           text NOT NULL DEFAULT 'SHIPPER' CHECK (freight_payer IN ('SHIPPER','CONSIGNEE','THIRD_PARTY')),
  -- the goods
  cargo_category          text NOT NULL REFERENCES ref.cargo_category(code),
  cargo_description       text NOT NULL CHECK (length(cargo_description) BETWEEN 2 AND 500),
  hs_code                 text CHECK (hs_code IS NULL OR hs_code ~ '^[0-9]{4,10}$'),
  packages                int CHECK (packages IS NULL OR packages > 0),
  package_type            text CHECK (package_type IS NULL OR length(package_type) <= 40),
  gross_weight_kg         numeric(12,1) NOT NULL CHECK (gross_weight_kg > 0),
  net_weight_kg           numeric(12,1) CHECK (net_weight_kg IS NULL OR net_weight_kg > 0),
  volume_m3               numeric(10,2) CHECK (volume_m3 IS NULL OR volume_m3 > 0),
  un_number               text CHECK (un_number IS NULL OR un_number ~ '^UN[0-9]{4}$'),
  adr_class               text CHECK (adr_class IS NULL OR adr_class ~ '^[1-9](\.[1-6])?$'),
  temp_min_c              numeric(4,1),
  temp_max_c              numeric(4,1),
  declared_value          bigint CHECK (declared_value IS NULL OR declared_value >= 0),
  value_currency          char(3) REFERENCES ref.currency(code),
  status                  text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','CONFIRMED','IN_TRANSIT','DELIVERED','CLOSED','CANCELLED')),
  created_by              bigint REFERENCES iam.app_user(id),
  created_at              timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT consignment_house_fk FOREIGN KEY (house_bill_id, bl_id) REFERENCES frt.house_bill (id, bl_id),
  -- the countries follow the route
  CONSTRAINT consignment_countries_ck CHECK (CASE route_kind
      WHEN 'DOMESTIC' THEN origin_country = 'SY' AND dest_country = 'SY'
      WHEN 'PORT_IMPORT' THEN origin_country = 'SY' AND dest_country = 'SY'
      WHEN 'PORT_EXPORT' THEN origin_country = 'SY' AND dest_country = 'SY'
      WHEN 'EXPORT' THEN origin_country = 'SY' AND dest_country <> 'SY'
      WHEN 'IMPORT' THEN origin_country <> 'SY' AND dest_country = 'SY'
      WHEN 'TRANSIT_PORT_OUT' THEN origin_country = 'SY' AND dest_country <> 'SY'
      WHEN 'TRANSIT_IN_PORT' THEN origin_country <> 'SY' AND dest_country = 'SY'
      WHEN 'TRANSIT_LAND' THEN origin_country <> 'SY' AND dest_country <> 'SY' END),
  CONSTRAINT consignment_dangerous_ck CHECK (adr_class IS NULL OR un_number IS NOT NULL),
  CONSTRAINT consignment_temp_ck CHECK (temp_min_c IS NULL OR temp_max_c IS NULL OR temp_min_c <= temp_max_c),
  CONSTRAINT consignment_net_ck CHECK (net_weight_kg IS NULL OR net_weight_kg <= gross_weight_kg),
  CONSTRAINT consignment_value_ck CHECK (declared_value IS NULL OR value_currency IS NOT NULL),
  CONSTRAINT consignment_borders_ck CHECK (exit_border_id IS NULL OR entry_border_id IS NULL OR exit_border_id <> entry_border_id)
);
CREATE INDEX IF NOT EXISTS consignment_company_idx ON frt.consignment (company_id, created_at DESC);
CREATE INDEX IF NOT EXISTS consignment_bl_id_fkx ON frt.consignment (bl_id) WHERE bl_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS consignment_house_bill_fkx ON frt.consignment (house_bill_id, bl_id) WHERE house_bill_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS consignment_shipper_party_id_fkx ON frt.consignment (shipper_party_id) WHERE shipper_party_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS consignment_consignee_party_id_fkx ON frt.consignment (consignee_party_id) WHERE consignee_party_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS consignment_origin_city_id_fkx ON frt.consignment (origin_city_id);
CREATE INDEX IF NOT EXISTS consignment_origin_station_id_fkx ON frt.consignment (origin_station_id);
CREATE INDEX IF NOT EXISTS consignment_dest_city_id_fkx ON frt.consignment (dest_city_id);
CREATE INDEX IF NOT EXISTS consignment_dest_station_id_fkx ON frt.consignment (dest_station_id);
CREATE INDEX IF NOT EXISTS consignment_port_station_id_fkx ON frt.consignment (port_station_id);
CREATE INDEX IF NOT EXISTS consignment_exit_border_id_fkx ON frt.consignment (exit_border_id);
CREATE INDEX IF NOT EXISTS consignment_entry_border_id_fkx ON frt.consignment (entry_border_id);
CREATE INDEX IF NOT EXISTS consignment_created_by_fkx ON frt.consignment (created_by);
COMMENT ON TABLE frt.consignment IS 'Goods transported by truck and documented by the platform: seller, buyer, route, borders or port, papers and cargo (1131)';
COMMENT ON COLUMN frt.consignment.export_permit_no IS 'The export approval and its number, required to issue the documents of an export';

CREATE TABLE IF NOT EXISTS frt.consignment_invoice (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  consignment_id  bigint NOT NULL REFERENCES frt.consignment(id),
  invoice_no      text NOT NULL CHECK (invoice_no ~ '^[A-Za-z0-9/ -]{1,40}$'),
  invoice_date    date,
  amount          bigint CHECK (amount IS NULL OR amount >= 0),
  currency        char(3) REFERENCES ref.currency(code),
  CONSTRAINT consignment_invoice_once_uq UNIQUE (consignment_id, invoice_no),
  CONSTRAINT consignment_invoice_currency_ck CHECK (amount IS NULL OR currency IS NOT NULL)
);
COMMENT ON TABLE frt.consignment_invoice IS 'The commercial invoices a consignment carries, named on its documents (1131)';

CREATE TABLE IF NOT EXISTS frt.consignment_container (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  consignment_id   bigint NOT NULL REFERENCES frt.consignment(id),
  bl_container_id  bigint REFERENCES frt.bl_container(id),
  container_no     text NOT NULL CHECK (frt.iso6346_ok(container_no)),
  size_type        text NOT NULL CHECK (size_type ~ '^[24L][0-9A-Z][0-9A-Z]{2}$' AND frt.container_feet(size_type) IS NOT NULL),
  seal_no          text CHECK (seal_no IS NULL OR seal_no ~ '^[A-Za-z0-9-]{3,20}$'),
  gross_weight_kg  int CHECK (gross_weight_kg IS NULL OR gross_weight_kg BETWEEN 1 AND 40000),
  packages         int CHECK (packages IS NULL OR packages > 0),
  status           text NOT NULL DEFAULT 'PLANNED' CHECK (status IN ('PLANNED','ON_TRUCK','DELIVERED','CANCELLED')),
  CONSTRAINT consignment_container_once_uq UNIQUE (consignment_id, container_no),
  CONSTRAINT consignment_container_of_uq UNIQUE (id, consignment_id)
);
CREATE INDEX IF NOT EXISTS consignment_container_bl_container_id_fkx ON frt.consignment_container (bl_container_id) WHERE bl_container_id IS NOT NULL;
COMMENT ON TABLE frt.consignment_container IS 'The containers of a consignment, each the same container as on its bill of lading where it comes from one (1131)';

-- a container of the consignment's bill of lading keeps the bill's number, size and seal
CREATE OR REPLACE FUNCTION frt.tg_consignment_container_bl() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE b record; c_bl bigint;
BEGIN
  IF NEW.bl_container_id IS NULL THEN
    RETURN NEW;
  END IF;
  SELECT * INTO b FROM frt.bl_container WHERE id = NEW.bl_container_id;
  SELECT bl_id INTO c_bl FROM frt.consignment WHERE id = NEW.consignment_id;
  IF c_bl IS DISTINCT FROM b.bl_id OR b.container_no <> NEW.container_no OR b.status = 'CANCELLED' THEN
    RAISE EXCEPTION 'CONTAINER_NOT_ON_BL: container % is not on the consignment''s bill of lading', NEW.container_no USING ERRCODE = 'P0001';
  END IF;
  NEW.size_type := b.size_type;
  NEW.seal_no := coalesce(NEW.seal_no, b.seal_no);
  NEW.gross_weight_kg := coalesce(NEW.gross_weight_kg, b.gross_weight_kg);
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS consignment_container_bl ON frt.consignment_container;
CREATE TRIGGER consignment_container_bl BEFORE INSERT OR UPDATE OF bl_container_id, container_no ON frt.consignment_container
  FOR EACH ROW EXECUTE FUNCTION frt.tg_consignment_container_bl();

-- ------------------------------------------------------------------ the truck owner's prices
CREATE TABLE IF NOT EXISTS frt.rate_card (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                  uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  company_id           bigint NOT NULL REFERENCES iam.company(id),       -- the truck owner: a company or a person
  route_kind           text CHECK (route_kind IS NULL OR route_kind IN ('DOMESTIC','PORT_IMPORT','PORT_EXPORT','EXPORT','IMPORT',
                                                                         'TRANSIT_PORT_OUT','TRANSIT_IN_PORT','TRANSIT_LAND')),
  from_city_id         bigint REFERENCES ref.city(id),
  from_station_id      bigint REFERENCES net.station(id),                -- a port or a border
  to_city_id           bigint REFERENCES ref.city(id),
  to_station_id        bigint REFERENCES net.station(id),
  to_country           char(2) REFERENCES ref.country(code),
  unit                 text NOT NULL CHECK (unit IN ('CONTAINER_20','CONTAINER_40','CONTAINER_45','TRUCK','TON','BL')),
  price                bigint NOT NULL CHECK (price > 0),
  currency             char(3) NOT NULL REFERENCES ref.currency(code),
  includes_empty_return boolean NOT NULL DEFAULT false,
  free_waiting_hours   smallint NOT NULL DEFAULT 24 CHECK (free_waiting_hours BETWEEN 0 AND 240),
  waiting_per_day      bigint CHECK (waiting_per_day IS NULL OR waiting_per_day >= 0),
  note                 text CHECK (note IS NULL OR length(note) <= 300),
  valid                daterange NOT NULL DEFAULT daterange(current_date, NULL),
  status               text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','PAUSED','ARCHIVED')),
  lane                 text GENERATED ALWAYS AS (coalesce(route_kind, '*') || ':' || coalesce(from_city_id::text, 's' || from_station_id::text) || '>'
                                                 || coalesce(to_city_id::text, 's' || to_station_id::text, 'c' || to_country)) STORED,
  created_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT rate_card_from_ck CHECK (num_nonnulls(from_city_id, from_station_id) = 1),
  CONSTRAINT rate_card_to_ck CHECK (num_nonnulls(to_city_id, to_station_id, to_country) = 1),
  CONSTRAINT rate_card_one_price EXCLUDE USING gist (company_id WITH =, lane WITH =, unit WITH =, valid WITH &&) WHERE (status = 'ACTIVE')
);
CREATE INDEX IF NOT EXISTS rate_card_from_city_id_fkx ON frt.rate_card (from_city_id);
CREATE INDEX IF NOT EXISTS rate_card_from_station_id_fkx ON frt.rate_card (from_station_id);
CREATE INDEX IF NOT EXISTS rate_card_to_city_id_fkx ON frt.rate_card (to_city_id);
CREATE INDEX IF NOT EXISTS rate_card_to_station_id_fkx ON frt.rate_card (to_station_id);
COMMENT ON TABLE frt.rate_card IS 'The truck owner''s own prices by lane and unit (a 20, 40 or 45 ft container, a truck, a ton or a bill of lading); one active price per lane and unit at a time (1131)';

-- ------------------------------------------------------------------ trucks carrying a consignment
CREATE TABLE IF NOT EXISTS frt.truck_movement (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                 uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  consignment_id      bigint NOT NULL REFERENCES frt.consignment(id),
  carrier_company_id  bigint NOT NULL REFERENCES iam.company(id),       -- the truck owner
  truck_vehicle_id    bigint NOT NULL REFERENCES fleet.vehicle(id),
  trailer_id          bigint REFERENCES fleet.trailer(id),
  driver_party_id     bigint REFERENCES iam.party(id),
  -- as they were when the truck was assigned: the documents name these even if the records change later
  truck_plate         text NOT NULL,
  truck_plate_country char(2) NOT NULL DEFAULT 'SY' REFERENCES ref.country(code),
  trailer_plate       text,
  trailer_capacity_ft smallint CHECK (trailer_capacity_ft IS NULL OR trailer_capacity_ft IN (20, 40, 45)),
  driver_name         text CHECK (driver_name IS NULL OR length(driver_name) <= 120),
  driver_licence_no   text CHECK (driver_licence_no IS NULL OR length(driver_licence_no) <= 40),
  driver_nationality  char(2) REFERENCES ref.country(code),
  driver_mobile       text CHECK (driver_mobile IS NULL OR driver_mobile ~ '^\+?[0-9]{8,15}$'),
  rate_card_id        bigint REFERENCES frt.rate_card(id),
  price               bigint NOT NULL CHECK (price >= 0),
  currency            char(3) NOT NULL REFERENCES ref.currency(code),
  status              text NOT NULL DEFAULT 'ASSIGNED' CHECK (status IN ('ASSIGNED','LOADING','IN_TRANSIT','AT_BORDER','DELIVERED','CANCELLED')),
  loaded_at           timestamptz,
  delivered_at        timestamptz,
  pod_received_by     text CHECK (pod_received_by IS NULL OR length(pod_received_by) <= 120),   -- proof of delivery
  created_by          bigint REFERENCES iam.app_user(id),
  created_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT truck_movement_delivered_ck CHECK (status <> 'DELIVERED' OR (delivered_at IS NOT NULL AND pod_received_by IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS truck_movement_one_active ON frt.truck_movement (truck_vehicle_id)
  WHERE status IN ('ASSIGNED','LOADING','IN_TRANSIT','AT_BORDER');
CREATE UNIQUE INDEX IF NOT EXISTS truck_movement_trailer_active ON frt.truck_movement (trailer_id)
  WHERE trailer_id IS NOT NULL AND status IN ('ASSIGNED','LOADING','IN_TRANSIT','AT_BORDER');
CREATE INDEX IF NOT EXISTS truck_movement_consignment_idx ON frt.truck_movement (consignment_id);
CREATE INDEX IF NOT EXISTS truck_movement_carrier_idx ON frt.truck_movement (carrier_company_id, created_at DESC);
CREATE INDEX IF NOT EXISTS truck_movement_driver_party_id_fkx ON frt.truck_movement (driver_party_id) WHERE driver_party_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS truck_movement_rate_card_id_fkx ON frt.truck_movement (rate_card_id) WHERE rate_card_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS truck_movement_created_by_fkx ON frt.truck_movement (created_by);
COMMENT ON TABLE frt.truck_movement IS 'One truck (and its trailer and driver) carrying part or all of a consignment, at the truck owner''s price; a truck or trailer is on one active movement at a time (1131)';

-- the truck and the trailer belong to the truck owner
CREATE OR REPLACE FUNCTION frt.tg_movement_owner() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM fleet.vehicle v WHERE v.id = NEW.truck_vehicle_id AND v.company_id = NEW.carrier_company_id) THEN
    RAISE EXCEPTION 'TRUCK_NOT_OWNED: the truck is not the carrier''s' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.trailer_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM fleet.trailer t WHERE t.id = NEW.trailer_id AND t.company_id = NEW.carrier_company_id) THEN
    RAISE EXCEPTION 'TRAILER_NOT_OWNED: the trailer is not the carrier''s' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS movement_owner ON frt.truck_movement;
CREATE TRIGGER movement_owner BEFORE INSERT OR UPDATE OF truck_vehicle_id, trailer_id, carrier_company_id ON frt.truck_movement
  FOR EACH ROW EXECUTE FUNCTION frt.tg_movement_owner();

CREATE TABLE IF NOT EXISTS frt.movement_container (
  movement_id               bigint NOT NULL REFERENCES frt.truck_movement(id),
  consignment_container_id  bigint NOT NULL REFERENCES frt.consignment_container(id),
  PRIMARY KEY (movement_id, consignment_container_id)
);
CREATE INDEX IF NOT EXISTS movement_container_container_idx ON frt.movement_container (consignment_container_id);
COMMENT ON TABLE frt.movement_container IS 'The containers on a truck: of its consignment, within the trailer''s length, each on one active truck (1131)';

CREATE OR REPLACE FUNCTION frt.tg_movement_container() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE m record; cap smallint; feet int;
BEGIN
  SELECT * INTO m FROM frt.truck_movement WHERE id = NEW.movement_id FOR UPDATE;
  IF NOT EXISTS (SELECT 1 FROM frt.consignment_container c WHERE c.id = NEW.consignment_container_id
                   AND c.consignment_id = m.consignment_id AND c.status <> 'CANCELLED') THEN
    RAISE EXCEPTION 'CONTAINER_NOT_IN_CONSIGNMENT: the container is not of this consignment' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM frt.movement_container x JOIN frt.truck_movement o ON o.id = x.movement_id
              WHERE x.consignment_container_id = NEW.consignment_container_id AND x.movement_id <> NEW.movement_id
                AND o.status <> 'CANCELLED') THEN
    RAISE EXCEPTION 'CONTAINER_ON_ANOTHER_TRUCK: the container is already on another truck' USING ERRCODE = 'P0001';
  END IF;
  cap := m.trailer_capacity_ft;
  IF cap IS NOT NULL THEN
    SELECT sum(frt.container_feet(c.size_type)) INTO feet FROM frt.movement_container x
      JOIN frt.consignment_container c ON c.id = x.consignment_container_id WHERE x.movement_id = NEW.movement_id;
    -- a 40 ft trailer takes one 40 ft or two 20 ft containers; a 45 ft container needs a 45 ft trailer, which also takes the rest
    IF feet > cap OR (cap < 45 AND EXISTS (SELECT 1 FROM frt.movement_container x JOIN frt.consignment_container c
                                             ON c.id = x.consignment_container_id
                                           WHERE x.movement_id = NEW.movement_id AND frt.container_feet(c.size_type) = 45)) THEN
      RAISE EXCEPTION 'TRAILER_TOO_SHORT: % ft of containers on a % ft trailer', feet, cap USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS movement_container_rules ON frt.movement_container;
CREATE CONSTRAINT TRIGGER movement_container_rules AFTER INSERT ON frt.movement_container
  FOR EACH ROW EXECUTE FUNCTION frt.tg_movement_container();

CREATE TABLE IF NOT EXISTS frt.movement_event (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  movement_id  bigint NOT NULL REFERENCES frt.truck_movement(id),
  status       text NOT NULL,
  station_id   bigint REFERENCES net.station(id),                       -- the port gate, a border, the delivery point
  note         text CHECK (note IS NULL OR length(note) <= 300),
  user_id      bigint REFERENCES iam.app_user(id),
  at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS movement_event_movement_idx ON frt.movement_event (movement_id, at);
CREATE INDEX IF NOT EXISTS movement_event_station_id_fkx ON frt.movement_event (station_id);
CREATE INDEX IF NOT EXISTS movement_event_user_id_fkx ON frt.movement_event (user_id);
COMMENT ON TABLE frt.movement_event IS 'Each step of a truck movement, as it happened; never changed (1131)';

-- a movement moves forward only; its containers and its consignment follow it
CREATE OR REPLACE FUNCTION frt.set_movement_status(p_movement bigint, p_status text, p_station bigint DEFAULT NULL,
                                                   p_note text DEFAULT NULL, p_received_by text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE m record; allowed text[]; open_left int;
BEGIN
  SELECT * INTO m FROM frt.truck_movement WHERE id = p_movement FOR UPDATE;
  IF m.id IS NULL OR NOT (sys.ctx_is_platform() OR m.carrier_company_id = sys.ctx_company_id()) THEN
    RAISE EXCEPTION 'MOVEMENT_UNKNOWN: no such truck movement of yours' USING ERRCODE = 'P0001';
  END IF;
  allowed := CASE m.status
    WHEN 'ASSIGNED' THEN ARRAY['LOADING','CANCELLED']
    WHEN 'LOADING' THEN ARRAY['IN_TRANSIT','CANCELLED']
    WHEN 'IN_TRANSIT' THEN ARRAY['AT_BORDER','DELIVERED']
    WHEN 'AT_BORDER' THEN ARRAY['IN_TRANSIT','DELIVERED']
    ELSE ARRAY[]::text[] END;
  IF NOT p_status = ANY (allowed) THEN
    RAISE EXCEPTION 'MOVEMENT_STEP: a truck movement goes from % to % only', m.status, array_to_string(allowed, ', ') USING ERRCODE = 'P0001';
  END IF;
  IF p_status = 'DELIVERED' AND (p_received_by IS NULL OR length(btrim(p_received_by)) < 2) THEN
    RAISE EXCEPTION 'POD_REQUIRED: name who received the goods' USING ERRCODE = 'P0001';
  END IF;
  UPDATE frt.truck_movement SET status = p_status,
         loaded_at = CASE WHEN p_status = 'IN_TRANSIT' THEN coalesce(loaded_at, now()) ELSE loaded_at END,
         delivered_at = CASE WHEN p_status = 'DELIVERED' THEN now() ELSE delivered_at END,
         pod_received_by = CASE WHEN p_status = 'DELIVERED' THEN btrim(p_received_by) ELSE pod_received_by END
   WHERE id = p_movement;
  INSERT INTO frt.movement_event (movement_id, status, station_id, note, user_id)
  VALUES (p_movement, p_status, p_station, nullif(btrim(p_note), ''), sys.ctx_user_id());
  UPDATE frt.consignment_container c SET status = CASE p_status WHEN 'DELIVERED' THEN 'DELIVERED' WHEN 'CANCELLED' THEN 'PLANNED' ELSE 'ON_TRUCK' END
   WHERE c.id IN (SELECT consignment_container_id FROM frt.movement_container WHERE movement_id = p_movement)
     AND p_status IN ('IN_TRANSIT','DELIVERED','CANCELLED');
  UPDATE frt.bl_container b SET status = CASE p_status WHEN 'DELIVERED' THEN 'DELIVERED' WHEN 'CANCELLED' THEN 'AT_PORT' ELSE 'ON_TRUCK' END
   WHERE b.id IN (SELECT c.bl_container_id FROM frt.movement_container x JOIN frt.consignment_container c ON c.id = x.consignment_container_id
                   WHERE x.movement_id = p_movement)
     AND p_status IN ('IN_TRANSIT','DELIVERED','CANCELLED') AND b.status <> 'EMPTY_RETURNED';
  -- the consignment is on its way with its first truck, and delivered with its last
  SELECT count(*) INTO open_left FROM frt.truck_movement WHERE consignment_id = m.consignment_id AND status NOT IN ('DELIVERED','CANCELLED');
  UPDATE frt.consignment SET status = CASE
           WHEN open_left = 0 AND EXISTS (SELECT 1 FROM frt.truck_movement WHERE consignment_id = m.consignment_id AND status = 'DELIVERED')
             THEN 'DELIVERED'
           WHEN p_status IN ('IN_TRANSIT','AT_BORDER') THEN 'IN_TRANSIT' ELSE status END
   WHERE id = m.consignment_id AND status IN ('DRAFT','CONFIRMED','IN_TRANSIT');
  RETURN jsonb_build_object('movement', m.uid, 'status', p_status);
END $$;

-- ------------------------------------------------------------------ transport invoices
CREATE TABLE IF NOT EXISTS frt.transport_invoice (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                 uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  invoice_no          text NOT NULL UNIQUE,
  carrier_company_id  bigint NOT NULL REFERENCES iam.company(id),
  consignment_id      bigint NOT NULL REFERENCES frt.consignment(id),
  bl_id               bigint REFERENCES frt.bill_of_lading(id),
  basis               text NOT NULL CHECK (basis IN ('BL','CONTAINER','CONSIGNMENT')),
  bill_to_name        text NOT NULL CHECK (length(bill_to_name) BETWEEN 2 AND 200),
  bill_to_party_id    bigint REFERENCES iam.party(id),
  currency            char(3) NOT NULL REFERENCES ref.currency(code),
  total               bigint NOT NULL CHECK (total >= 0),
  status              text NOT NULL DEFAULT 'ISSUED' CHECK (status IN ('ISSUED','PAID','VOID')),
  void_reason         text CHECK (void_reason IS NULL OR length(void_reason) BETWEEN 3 AND 300),
  issued_by           bigint REFERENCES iam.app_user(id),
  issued_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT transport_invoice_void_ck CHECK (status <> 'VOID' OR void_reason IS NOT NULL),
  CONSTRAINT transport_invoice_bl_ck CHECK (basis <> 'BL' OR bl_id IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS transport_invoice_carrier_idx ON frt.transport_invoice (carrier_company_id, issued_at DESC);
CREATE INDEX IF NOT EXISTS transport_invoice_consignment_idx ON frt.transport_invoice (consignment_id);
CREATE INDEX IF NOT EXISTS transport_invoice_bl_id_fkx ON frt.transport_invoice (bl_id) WHERE bl_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS transport_invoice_bill_to_party_id_fkx ON frt.transport_invoice (bill_to_party_id) WHERE bill_to_party_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS transport_invoice_issued_by_fkx ON frt.transport_invoice (issued_by);
COMMENT ON TABLE frt.transport_invoice IS 'The truck owner''s invoice for the transport: the whole bill of lading and its containers, one container, or the consignment (1131)';

CREATE TABLE IF NOT EXISTS frt.transport_invoice_line (
  invoice_id                bigint NOT NULL REFERENCES frt.transport_invoice(id),
  line_no                   smallint NOT NULL CHECK (line_no >= 1),
  description               text NOT NULL CHECK (length(description) BETWEEN 2 AND 300),
  consignment_container_id  bigint REFERENCES frt.consignment_container(id),
  movement_id               bigint REFERENCES frt.truck_movement(id),
  amount                    bigint NOT NULL CHECK (amount >= 0),
  PRIMARY KEY (invoice_id, line_no)
);
CREATE INDEX IF NOT EXISTS transport_invoice_line_container_idx ON frt.transport_invoice_line (consignment_container_id) WHERE consignment_container_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS transport_invoice_line_movement_id_fkx ON frt.transport_invoice_line (movement_id) WHERE movement_id IS NOT NULL;
COMMENT ON TABLE frt.transport_invoice_line IS 'Lines of a transport invoice: a container or a truck movement each (1131)';

-- an issued invoice is never edited: it is paid or voided, with the reason
CREATE OR REPLACE FUNCTION frt.tg_invoice_frozen() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_TABLE_NAME = 'transport_invoice_line' THEN
    RAISE EXCEPTION 'INVOICE_FROZEN: the lines of an issued invoice do not change' USING ERRCODE = 'P0001';
  END IF;
  IF (NEW.invoice_no, NEW.carrier_company_id, NEW.consignment_id, NEW.basis, NEW.total, NEW.currency, NEW.bill_to_name)
     IS DISTINCT FROM (OLD.invoice_no, OLD.carrier_company_id, OLD.consignment_id, OLD.basis, OLD.total, OLD.currency, OLD.bill_to_name)
     OR NOT ((OLD.status = 'ISSUED' AND NEW.status IN ('ISSUED','PAID','VOID')) OR (OLD.status = NEW.status)) THEN
    RAISE EXCEPTION 'INVOICE_FROZEN: an issued invoice is paid or voided, never changed' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS invoice_frozen ON frt.transport_invoice;
CREATE TRIGGER invoice_frozen BEFORE UPDATE ON frt.transport_invoice FOR EACH ROW EXECUTE FUNCTION frt.tg_invoice_frozen();
DROP TRIGGER IF EXISTS invoice_line_frozen ON frt.transport_invoice_line;
CREATE TRIGGER invoice_line_frozen BEFORE UPDATE OR DELETE ON frt.transport_invoice_line FOR EACH ROW EXECUTE FUNCTION frt.tg_invoice_frozen();

-- what a container's share of its truck's price is: the price split between the containers on the truck
CREATE OR REPLACE FUNCTION frt.container_charges(p_consignment bigint, p_carrier bigint)
RETURNS TABLE (consignment_container_id bigint, container_no text, movement_id bigint, amount bigint, currency char(3))
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  WITH c AS (
    SELECT x.consignment_container_id, cc.container_no, m.id AS movement_id, m.price, m.currency,
           row_number() OVER (PARTITION BY m.id ORDER BY cc.container_no) AS k, count(*) OVER (PARTITION BY m.id) AS n
      FROM frt.truck_movement m JOIN frt.movement_container x ON x.movement_id = m.id
      JOIN frt.consignment_container cc ON cc.id = x.consignment_container_id
     WHERE m.consignment_id = p_consignment AND m.carrier_company_id = p_carrier AND m.status <> 'CANCELLED')
  SELECT consignment_container_id, container_no, movement_id,
         price / n + CASE WHEN k = n THEN price % n ELSE 0 END, currency     -- the last takes what does not divide
    FROM c
$$;

CREATE OR REPLACE FUNCTION frt.issue_transport_invoice(p_consignment bigint, p_basis text, p_container bigint DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  me bigint := sys.ctx_company_id(); c record; inv bigint; no int; code text; cur char(3); r record;
  descs text[] := '{}'; boxes bigint[] := '{}'; movs bigint[] := '{}'; amounts bigint[] := '{}';
BEGIN
  SELECT * INTO c FROM frt.consignment WHERE id = p_consignment FOR UPDATE;
  IF c.id IS NULL OR me IS NULL OR NOT EXISTS (SELECT 1 FROM frt.truck_movement WHERE consignment_id = c.id AND carrier_company_id = me
                                                 AND status <> 'CANCELLED') THEN
    RAISE EXCEPTION 'CONSIGNMENT_UNKNOWN: no consignment carried by your trucks' USING ERRCODE = 'P0001';
  END IF;
  IF p_basis IS NULL OR p_basis NOT IN ('BL','CONTAINER','CONSIGNMENT') THEN
    RAISE EXCEPTION 'INVOICE_BASIS: invoice the bill of lading, a container or the consignment' USING ERRCODE = 'P0001';
  END IF;
  IF p_basis = 'BL' AND c.bl_id IS NULL THEN
    RAISE EXCEPTION 'INVOICE_BASIS: the consignment has no bill of lading' USING ERRCODE = 'P0001';
  END IF;
  IF p_basis = 'CONTAINER' AND (p_container IS NULL OR NOT EXISTS (SELECT 1 FROM frt.consignment_container WHERE id = p_container AND consignment_id = c.id)) THEN
    RAISE EXCEPTION 'INVOICE_BASIS: name a container of the consignment' USING ERRCODE = 'P0001';
  END IF;
  -- the lines first: a truck each for loose cargo, a container each (its share of its truck's price) otherwise
  IF p_basis = 'CONSIGNMENT' AND c.load_type NOT IN ('FCL','LCL') THEN
    FOR r IN SELECT id, truck_plate, price, currency FROM frt.truck_movement
              WHERE consignment_id = c.id AND carrier_company_id = me AND status <> 'CANCELLED' ORDER BY id LOOP
      IF EXISTS (SELECT 1 FROM frt.transport_invoice_line l JOIN frt.transport_invoice i ON i.id = l.invoice_id
                  WHERE l.movement_id = r.id AND i.status <> 'VOID') THEN
        RAISE EXCEPTION 'ALREADY_INVOICED: the truck % is already invoiced', r.truck_plate USING ERRCODE = 'P0001';
      END IF;
      IF cur IS NOT NULL AND cur <> r.currency THEN
        RAISE EXCEPTION 'INVOICE_CURRENCY: the trucks are priced in different currencies' USING ERRCODE = 'P0001';
      END IF;
      cur := r.currency;
      descs := descs || ('Transport, truck ' || r.truck_plate); boxes := boxes || NULL::bigint; movs := movs || r.id; amounts := amounts || r.price;
    END LOOP;
  ELSE
    FOR r IN SELECT * FROM frt.container_charges(c.id, me) ch
              WHERE p_basis IN ('BL','CONSIGNMENT') OR ch.consignment_container_id = p_container ORDER BY ch.container_no LOOP
      IF EXISTS (SELECT 1 FROM frt.transport_invoice_line l JOIN frt.transport_invoice i ON i.id = l.invoice_id
                  WHERE l.consignment_container_id = r.consignment_container_id AND i.status <> 'VOID') THEN
        RAISE EXCEPTION 'ALREADY_INVOICED: container % is already invoiced', r.container_no USING ERRCODE = 'P0001';
      END IF;
      IF cur IS NOT NULL AND cur <> r.currency THEN
        RAISE EXCEPTION 'INVOICE_CURRENCY: the trucks are priced in different currencies' USING ERRCODE = 'P0001';
      END IF;
      cur := r.currency;
      descs := descs || ('Transport of container ' || r.container_no); boxes := boxes || r.consignment_container_id;
      movs := movs || r.movement_id; amounts := amounts || r.amount;
    END LOOP;
  END IF;
  IF cardinality(amounts) = 0 THEN
    RAISE EXCEPTION 'NOTHING_TO_INVOICE: no container or truck of yours to invoice' USING ERRCODE = 'P0001';
  END IF;
  SELECT coalesce(min(code3), 'FR' || me) INTO code FROM net.carrier_code WHERE company_id = me AND status = 'ACTIVE';
  no := frt.next_number('INVOICE', me);
  INSERT INTO frt.transport_invoice (invoice_no, carrier_company_id, consignment_id, bl_id, basis, bill_to_name, bill_to_party_id, currency, total, issued_by)
  VALUES (format('%s-TI-%s-%s', code, extract(year FROM now() AT TIME ZONE 'Asia/Damascus')::int, lpad(no::text, 6, '0')), me, c.id,
          CASE WHEN p_basis = 'BL' THEN c.bl_id END, p_basis,
          CASE c.freight_payer WHEN 'CONSIGNEE' THEN c.consignee_name ELSE c.shipper_name END,
          CASE c.freight_payer WHEN 'CONSIGNEE' THEN c.consignee_party_id ELSE c.shipper_party_id END,
          cur, (SELECT sum(a) FROM unnest(amounts) a), sys.ctx_user_id())
  RETURNING id INTO inv;
  INSERT INTO frt.transport_invoice_line (invoice_id, line_no, description, consignment_container_id, movement_id, amount)
  SELECT inv, k, descs[k], boxes[k], movs[k], amounts[k] FROM generate_subscripts(amounts, 1) k;
  RETURN (SELECT to_jsonb(i) - 'id' - 'carrier_company_id' - 'consignment_id' - 'bl_id' - 'bill_to_party_id' - 'issued_by'
            FROM frt.transport_invoice i WHERE i.id = inv)
         || jsonb_build_object('lines', (SELECT jsonb_agg(jsonb_build_object('line_no', l.line_no, 'description', l.description, 'amount', l.amount)
                                                           ORDER BY l.line_no) FROM frt.transport_invoice_line l WHERE l.invoice_id = inv));
END $$;

-- ------------------------------------------------------------------ the platform's documents
CREATE TABLE IF NOT EXISTS frt.transport_document (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  doc_type           text NOT NULL CHECK (doc_type IN ('CONSIGNMENT_NOTE','TCN')),
  doc_no             text NOT NULL UNIQUE,
  scope              text NOT NULL CHECK (scope IN ('SINGLE','CONSOLIDATED')),
  issuer_company_id  bigint NOT NULL REFERENCES iam.company(id),
  version            smallint NOT NULL DEFAULT 1 CHECK (version >= 1),
  supersedes_id      bigint UNIQUE REFERENCES frt.transport_document(id),
  snapshot           jsonb NOT NULL,
  sha256             bytea NOT NULL CHECK (length(sha256) = 32),
  verify_code        text NOT NULL UNIQUE CHECK (verify_code ~ '^[A-HJ-NP-Z2-9]{10}$'),
  status             text NOT NULL DEFAULT 'ISSUED' CHECK (status IN ('ISSUED','VOID','SUPERSEDED')),
  void_reason        text CHECK (void_reason IS NULL OR length(void_reason) BETWEEN 3 AND 300),
  issued_by          bigint REFERENCES iam.app_user(id),
  issued_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT transport_document_void_ck CHECK (status <> 'VOID' OR void_reason IS NOT NULL),
  CONSTRAINT transport_document_scope_ck CHECK (doc_type = 'TCN' OR scope = 'SINGLE')
);
CREATE INDEX IF NOT EXISTS transport_document_issuer_idx ON frt.transport_document (issuer_company_id, issued_at DESC);
CREATE INDEX IF NOT EXISTS transport_document_issued_by_fkx ON frt.transport_document (issued_by);
COMMENT ON TABLE frt.transport_document IS 'Documents the platform issues: the consignment note of a consignment and, inside Syria, the truck consignment note (TCN) of one or several consignments; a frozen snapshot with its SHA-256 and a verification code (1131)';

CREATE TABLE IF NOT EXISTS frt.document_consignment (
  document_id     bigint NOT NULL REFERENCES frt.transport_document(id),
  consignment_id  bigint NOT NULL REFERENCES frt.consignment(id),
  PRIMARY KEY (document_id, consignment_id)
);
CREATE INDEX IF NOT EXISTS document_consignment_consignment_idx ON frt.document_consignment (consignment_id);
CREATE TABLE IF NOT EXISTS frt.document_vehicle (
  document_id  bigint NOT NULL REFERENCES frt.transport_document(id),
  movement_id  bigint NOT NULL REFERENCES frt.truck_movement(id),
  PRIMARY KEY (document_id, movement_id)
);
CREATE INDEX IF NOT EXISTS document_vehicle_movement_idx ON frt.document_vehicle (movement_id);
COMMENT ON TABLE frt.document_consignment IS 'The consignments a document covers (1131)';
COMMENT ON TABLE frt.document_vehicle IS 'Every truck and trailer a document lists in its one statement (1131)';

CREATE OR REPLACE FUNCTION frt.tg_document_frozen() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (NEW.doc_type, NEW.doc_no, NEW.scope, NEW.issuer_company_id, NEW.version, NEW.snapshot, NEW.sha256, NEW.verify_code, NEW.issued_at)
     IS DISTINCT FROM (OLD.doc_type, OLD.doc_no, OLD.scope, OLD.issuer_company_id, OLD.version, OLD.snapshot, OLD.sha256, OLD.verify_code, OLD.issued_at)
     OR NOT (OLD.status = NEW.status OR (OLD.status = 'ISSUED' AND NEW.status IN ('VOID','SUPERSEDED'))) THEN
    RAISE EXCEPTION 'DOCUMENT_FROZEN: an issued document is voided or replaced by a new version, never changed' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS document_frozen ON frt.transport_document;
CREATE TRIGGER document_frozen BEFORE UPDATE ON frt.transport_document FOR EACH ROW EXECUTE FUNCTION frt.tg_document_frozen();

-- ------------------------------------------------------------------ who sees what
CREATE OR REPLACE FUNCTION frt.can_see_consignment(p_id bigint) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT sys.ctx_is_platform() OR EXISTS (
    SELECT 1 FROM frt.consignment c WHERE c.id = p_id
       AND (c.company_id = sys.ctx_company_id()
            OR (sys.ctx_party_id() IS NOT NULL AND sys.ctx_party_id() IN (c.shipper_party_id, c.consignee_party_id))
            OR EXISTS (SELECT 1 FROM frt.truck_movement m WHERE m.consignment_id = c.id AND m.carrier_company_id = sys.ctx_company_id())))
$$;
CREATE OR REPLACE FUNCTION frt.can_see_bill(p_id bigint) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT sys.ctx_is_platform()
      OR EXISTS (SELECT 1 FROM frt.bill_of_lading b WHERE b.id = p_id AND b.company_id = sys.ctx_company_id())
      OR EXISTS (SELECT 1 FROM frt.consignment c WHERE c.bl_id = p_id AND frt.can_see_consignment(c.id))
$$;
CREATE OR REPLACE FUNCTION frt.can_see_document(p_id bigint) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT sys.ctx_is_platform()
      OR EXISTS (SELECT 1 FROM frt.transport_document d WHERE d.id = p_id AND d.issuer_company_id = sys.ctx_company_id())
      OR EXISTS (SELECT 1 FROM frt.document_consignment x WHERE x.document_id = p_id AND frt.can_see_consignment(x.consignment_id))
$$;

-- one consignment as a document shows it
CREATE OR REPLACE FUNCTION frt.consignment_snapshot(p_id bigint) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT jsonb_build_object(
    'consignment_no', c.consignment_no, 'route_kind', c.route_kind, 'international', c.international, 'load_type', c.load_type,
    'shipper', jsonb_build_object('name', c.shipper_name, 'address', c.shipper_address, 'country', c.shipper_country, 'tax_no', c.shipper_tax_no),
    'consignee', jsonb_build_object('name', c.consignee_name, 'address', c.consignee_address, 'country', c.consignee_country, 'tax_no', c.consignee_tax_no),
    'notify', c.notify_name,
    'origin', jsonb_build_object('country', c.origin_country, 'city', oc.code, 'station', os.code, 'station_name', os.name, 'address', c.origin_address),
    'destination', jsonb_build_object('country', c.dest_country, 'city', dc.code, 'station', ds.code, 'station_name', ds.name, 'address', c.dest_address),
    'port', ps.code, 'port_name', ps.name, 'exit_border', xb.code, 'exit_border_name', xb.name, 'entry_border', eb.code,
    'entry_border_name', eb.name, 'arrival_port', c.arrival_port,
    'bill_of_lading', CASE WHEN b.id IS NOT NULL THEN jsonb_build_object('bl_no', b.bl_no, 'shipping_line', sl.code, 'shipping_line_name', sl.name,
                                                                         'container_count', b.container_count, 'release_no', b.release_no,
                                                                         'vessel', b.vessel, 'voyage', b.voyage) END,
    'house_bill', hb.hbl_no, 'forwarder', hb.forwarder_name,
    'export_permit', jsonb_build_object('no', c.export_permit_no, 'date', c.export_permit_date),
    'customs_declaration_no', c.customs_declaration_no, 'release_no', coalesce(c.release_no, b.release_no), 'tir_carnet_no', c.tir_carnet_no,
    'incoterm', c.incoterm, 'freight_payer', c.freight_payer,
    'invoices', coalesce((SELECT jsonb_agg(jsonb_build_object('no', i.invoice_no, 'date', i.invoice_date, 'amount', i.amount, 'currency', i.currency)
                                           ORDER BY i.invoice_no) FROM frt.consignment_invoice i WHERE i.consignment_id = c.id), '[]'),
    'cargo', jsonb_build_object('category', c.cargo_category, 'description', c.cargo_description, 'hs_code', c.hs_code, 'packages', c.packages,
                                'package_type', c.package_type, 'gross_weight_kg', c.gross_weight_kg, 'net_weight_kg', c.net_weight_kg,
                                'volume_m3', c.volume_m3, 'un_number', c.un_number, 'adr_class', c.adr_class,
                                'temp_min_c', c.temp_min_c, 'temp_max_c', c.temp_max_c,
                                'declared_value', c.declared_value, 'value_currency', c.value_currency),
    'containers', coalesce((SELECT jsonb_agg(jsonb_build_object('container_no', k.container_no, 'size_type', k.size_type, 'seal_no', k.seal_no,
                                                                'gross_weight_kg', k.gross_weight_kg, 'packages', k.packages,
                                                                'truck_plate', (SELECT m.truck_plate FROM frt.movement_container x
                                                                                  JOIN frt.truck_movement m ON m.id = x.movement_id
                                                                                 WHERE x.consignment_container_id = k.id AND m.status <> 'CANCELLED' LIMIT 1))
                                             ORDER BY k.container_no)
                              FROM frt.consignment_container k WHERE k.consignment_id = c.id AND k.status <> 'CANCELLED'), '[]'))
    FROM frt.consignment c
    LEFT JOIN ref.city oc ON oc.id = c.origin_city_id LEFT JOIN net.station os ON os.id = c.origin_station_id
    LEFT JOIN ref.city dc ON dc.id = c.dest_city_id LEFT JOIN net.station ds ON ds.id = c.dest_station_id
    LEFT JOIN net.station ps ON ps.id = c.port_station_id
    LEFT JOIN net.station xb ON xb.id = c.exit_border_id LEFT JOIN net.station eb ON eb.id = c.entry_border_id
    LEFT JOIN frt.bill_of_lading b ON b.id = c.bl_id LEFT JOIN frt.shipping_line sl ON sl.id = b.shipping_line_id
    LEFT JOIN frt.house_bill hb ON hb.id = c.house_bill_id
   WHERE c.id = p_id AND frt.can_see_consignment(c.id)
$$;

-- what a consignment still lacks before a document of this type can be issued
CREATE OR REPLACE FUNCTION frt.document_gaps(p_id bigint, p_type text) RETURNS text[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT array_remove(ARRAY[
    CASE WHEN c.status = 'CANCELLED' THEN 'CANCELLED' END,
    CASE WHEN p_type = 'TCN' AND c.international THEN 'TCN_DOMESTIC_ONLY' END,
    CASE WHEN c.origin_station_id IS NULL AND c.origin_address IS NULL AND c.origin_city_id IS NULL AND c.port_station_id IS NULL
         AND c.entry_border_id IS NULL THEN 'ORIGIN' END,
    CASE WHEN c.dest_station_id IS NULL AND c.dest_address IS NULL AND c.dest_city_id IS NULL AND c.port_station_id IS NULL
         AND c.exit_border_id IS NULL AND c.arrival_port IS NULL THEN 'DESTINATION' END,
    CASE WHEN c.route_kind IN ('PORT_IMPORT','PORT_EXPORT','TRANSIT_PORT_OUT','TRANSIT_IN_PORT') AND c.port_station_id IS NULL THEN 'PORT' END,
    CASE WHEN c.route_kind IN ('EXPORT','TRANSIT_PORT_OUT','TRANSIT_LAND') AND c.exit_border_id IS NULL THEN 'EXIT_BORDER' END,
    CASE WHEN c.route_kind IN ('IMPORT','TRANSIT_IN_PORT','TRANSIT_LAND') AND c.entry_border_id IS NULL THEN 'ENTRY_BORDER' END,
    CASE WHEN c.route_kind IN ('EXPORT','PORT_EXPORT') AND c.export_permit_no IS NULL THEN 'EXPORT_PERMIT' END,
    CASE WHEN c.international AND NOT EXISTS (SELECT 1 FROM frt.consignment_invoice i WHERE i.consignment_id = c.id) THEN 'INVOICES' END,
    CASE WHEN c.route_kind = 'PORT_IMPORT' AND c.bl_id IS NOT NULL
         AND coalesce(c.release_no, (SELECT b.release_no FROM frt.bill_of_lading b WHERE b.id = c.bl_id)) IS NULL THEN 'RELEASE' END,
    CASE WHEN c.load_type IN ('FCL','LCL') AND NOT EXISTS (SELECT 1 FROM frt.consignment_container k WHERE k.consignment_id = c.id
                                                             AND k.status <> 'CANCELLED') THEN 'CONTAINERS' END,
    CASE WHEN c.load_type IN ('FCL','LCL') AND EXISTS (SELECT 1 FROM frt.consignment_container k WHERE k.consignment_id = c.id AND k.status <> 'CANCELLED'
                                                         AND NOT EXISTS (SELECT 1 FROM frt.movement_container x JOIN frt.truck_movement m ON m.id = x.movement_id
                                                                          WHERE x.consignment_container_id = k.id AND m.status <> 'CANCELLED'))
         THEN 'CONTAINERS_WITHOUT_TRUCK' END,
    CASE WHEN NOT EXISTS (SELECT 1 FROM frt.truck_movement m WHERE m.consignment_id = c.id AND m.status <> 'CANCELLED') THEN 'TRUCKS' END,
    CASE WHEN c.adr_class IS NOT NULL AND EXISTS (SELECT 1 FROM frt.truck_movement m LEFT JOIN fleet.truck_unit u ON u.vehicle_id = m.truck_vehicle_id
                                                   WHERE m.consignment_id = c.id AND m.status <> 'CANCELLED' AND coalesce(u.hazmat_certified, false) = false)
         THEN 'HAZMAT_TRUCK' END
  ], NULL)
    FROM frt.consignment c WHERE c.id = p_id AND frt.can_see_consignment(c.id)
$$;

CREATE OR REPLACE FUNCTION frt.vehicle_snapshot(p_movement bigint) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT jsonb_build_object('consignment_no', c.consignment_no, 'carrier', cp.legal_name, 'truck_plate', m.truck_plate,
                            'truck_plate_country', m.truck_plate_country, 'trailer_plate', m.trailer_plate,
                            'trailer_capacity_ft', m.trailer_capacity_ft, 'driver_name', m.driver_name,
                            'driver_licence_no', m.driver_licence_no, 'driver_nationality', m.driver_nationality,
                            'containers', coalesce((SELECT jsonb_agg(k.container_no ORDER BY k.container_no) FROM frt.movement_container x
                                                      JOIN frt.consignment_container k ON k.id = x.consignment_container_id
                                                     WHERE x.movement_id = m.id), '[]'))
    FROM frt.truck_movement m JOIN frt.consignment c ON c.id = m.consignment_id JOIN iam.party cp ON cp.id = m.carrier_company_id
   WHERE m.id = p_movement
$$;

-- issues a consignment note (one consignment) or a TCN (one or several domestic consignments, every truck in one statement)
CREATE OR REPLACE FUNCTION frt.issue_document(p_type text, p_consignments bigint[], p_replaces bigint DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  me bigint := sys.ctx_company_id(); cid bigint; gaps text[]; snap jsonb; movs bigint[]; doc bigint; no int; ver smallint := 1;
  code text; old_id bigint; old_no text; old_ver smallint; old_issuer bigint; old_status text; old_type text;
  alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; rnd bytea := uuid_send(gen_random_uuid());
BEGIN
  IF p_type NOT IN ('CONSIGNMENT_NOTE','TCN') OR p_consignments IS NULL OR cardinality(p_consignments) = 0 THEN
    RAISE EXCEPTION 'DOCUMENT_TYPE: issue a consignment note or a TCN for consignments' USING ERRCODE = 'P0001';
  END IF;
  IF p_type = 'CONSIGNMENT_NOTE' AND cardinality(p_consignments) > 1 THEN
    RAISE EXCEPTION 'DOCUMENT_SCOPE: a consignment note covers one consignment; a TCN covers several' USING ERRCODE = 'P0001';
  END IF;
  IF cardinality(p_consignments) > 50 THEN
    RAISE EXCEPTION 'DOCUMENT_SCOPE: a TCN covers 50 consignments at most' USING ERRCODE = 'P0001';
  END IF;
  -- the issuer registered the consignments or carries them
  FOREACH cid IN ARRAY p_consignments LOOP
    PERFORM 1 FROM frt.consignment WHERE id = cid FOR UPDATE;
    IF me IS NULL OR NOT EXISTS (SELECT 1 FROM frt.consignment c WHERE c.id = cid
                                   AND (c.company_id = me OR EXISTS (SELECT 1 FROM frt.truck_movement m WHERE m.consignment_id = c.id
                                                                       AND m.carrier_company_id = me AND m.status <> 'CANCELLED'))) THEN
      RAISE EXCEPTION 'CONSIGNMENT_UNKNOWN: a consignment is not yours to document' USING ERRCODE = 'P0001';
    END IF;
    gaps := frt.document_gaps(cid, p_type);
    IF cardinality(gaps) > 0 THEN
      RAISE EXCEPTION 'DOCUMENT_INCOMPLETE: % lacks %', (SELECT consignment_no FROM frt.consignment WHERE id = cid), array_to_string(gaps, ', ')
        USING ERRCODE = 'P0001', DETAIL = array_to_string(gaps, ',');
    END IF;
  END LOOP;
  IF p_replaces IS NOT NULL THEN
    SELECT id, doc_no, version, issuer_company_id, status, doc_type INTO old_id, old_no, old_ver, old_issuer, old_status, old_type
      FROM frt.transport_document WHERE id = p_replaces FOR UPDATE;
    IF old_id IS NULL OR old_issuer <> me OR old_status <> 'ISSUED' OR old_type <> p_type THEN
      RAISE EXCEPTION 'DOCUMENT_UNKNOWN: only an issued document of yours of the same type is replaced' USING ERRCODE = 'P0001';
    END IF;
    ver := old_ver + 1;
    UPDATE frt.transport_document SET status = 'SUPERSEDED' WHERE id = old_id;
  END IF;
  SELECT array_agg(m.id ORDER BY m.consignment_id, m.id) INTO movs FROM frt.truck_movement m
   WHERE m.consignment_id = ANY (p_consignments) AND m.status <> 'CANCELLED';
  IF old_id IS NOT NULL THEN
    code := split_part(old_no, '/', 1) || '/' || ver;              -- a new version keeps the number, with its version
  ELSE
    no := frt.next_number(p_type);
    code := CASE p_type WHEN 'TCN' THEN 'TCN' ELSE 'MCN' END || '-' || extract(year FROM now() AT TIME ZONE 'Asia/Damascus')::int || '-' || lpad(no::text, 7, '0');
  END IF;
  snap := jsonb_build_object(
    'doc_type', p_type, 'doc_no', code, 'version', ver, 'issued_at', now(),
    'issuer', (SELECT jsonb_build_object('name', legal_name) FROM iam.party WHERE id = me),
    'consignments', (SELECT jsonb_agg(frt.consignment_snapshot(x) ORDER BY x) FROM unnest(p_consignments) x),
    'vehicles', (SELECT jsonb_agg(frt.vehicle_snapshot(x) ORDER BY ord) FROM unnest(movs) WITH ORDINALITY AS u(x, ord)),
    'totals', jsonb_build_object('consignments', cardinality(p_consignments), 'vehicles', cardinality(movs),
                                 'containers', (SELECT count(*) FROM frt.consignment_container k WHERE k.consignment_id = ANY (p_consignments)
                                                  AND k.status <> 'CANCELLED'),
                                 'gross_weight_kg', (SELECT sum(gross_weight_kg) FROM frt.consignment WHERE id = ANY (p_consignments))));
  INSERT INTO frt.transport_document (doc_type, doc_no, scope, issuer_company_id, version, supersedes_id, snapshot, sha256, verify_code, issued_by)
  VALUES (p_type, code, CASE WHEN cardinality(p_consignments) > 1 THEN 'CONSOLIDATED' ELSE 'SINGLE' END, me, ver, old_id, snap,
          sha256(convert_to(snap::text, 'UTF8')),
          (SELECT string_agg(substr(alphabet, get_byte(rnd, i) % 32 + 1, 1), '' ORDER BY i) FROM generate_series(0, 9) i), sys.ctx_user_id())
  RETURNING id INTO doc;
  INSERT INTO frt.document_consignment (document_id, consignment_id) SELECT doc, x FROM unnest(p_consignments) x;
  INSERT INTO frt.document_vehicle (document_id, movement_id) SELECT doc, x FROM unnest(movs) x;
  UPDATE frt.consignment SET status = 'CONFIRMED' WHERE id = ANY (p_consignments) AND status = 'DRAFT';
  RETURN (SELECT jsonb_build_object('uid', d.uid, 'doc_type', d.doc_type, 'doc_no', d.doc_no, 'scope', d.scope, 'version', d.version,
                                    'verify_code', d.verify_code, 'sha256', encode(d.sha256, 'hex'), 'issued_at', d.issued_at,
                                    'snapshot', d.snapshot) FROM frt.transport_document d WHERE d.id = doc);
END $$;

CREATE OR REPLACE FUNCTION frt.void_document(p_doc bigint, p_reason text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE d record;
BEGIN
  SELECT * INTO d FROM frt.transport_document WHERE id = p_doc FOR UPDATE;
  IF d.id IS NULL OR NOT (sys.ctx_is_platform() OR d.issuer_company_id = sys.ctx_company_id()) OR d.status <> 'ISSUED' THEN
    RAISE EXCEPTION 'DOCUMENT_UNKNOWN: only an issued document of yours is voided' USING ERRCODE = 'P0001';
  END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) < 3 THEN
    RAISE EXCEPTION 'REASON_REQUIRED: say why the document is voided' USING ERRCODE = 'P0001';
  END IF;
  UPDATE frt.transport_document SET status = 'VOID', void_reason = btrim(p_reason) WHERE id = d.id;
  RETURN jsonb_build_object('doc_no', d.doc_no, 'status', 'VOID');
END $$;

-- anyone holding a document checks it with its number and code: what the platform issued, and whether it still stands
CREATE OR REPLACE FUNCTION frt.verify_document(p_doc_no text, p_code text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT jsonb_build_object('doc_no', d.doc_no, 'doc_type', d.doc_type, 'scope', d.scope, 'version', d.version, 'status', d.status,
                            'issued_at', d.issued_at, 'issuer', p.legal_name, 'sha256', encode(d.sha256, 'hex'),
                            'replaced_by', (SELECT n.doc_no FROM frt.transport_document n WHERE n.supersedes_id = d.id),
                            'consignments', (SELECT jsonb_agg(x ->> 'consignment_no') FROM jsonb_array_elements(d.snapshot -> 'consignments') x),
                            'vehicles', (SELECT jsonb_agg(jsonb_build_object('truck_plate', x ->> 'truck_plate', 'trailer_plate', x ->> 'trailer_plate'))
                                           FROM jsonb_array_elements(d.snapshot -> 'vehicles') x),
                            'containers', (SELECT jsonb_agg(k ->> 'container_no') FROM jsonb_array_elements(d.snapshot -> 'consignments') x,
                                                  jsonb_array_elements(x -> 'containers') k))
    FROM frt.transport_document d JOIN iam.party p ON p.id = d.issuer_company_id
   WHERE d.doc_no = p_doc_no AND d.verify_code = upper(btrim(p_code))
$$;

-- a consignment number: MSL- year - serial
CREATE OR REPLACE FUNCTION frt.tg_consignment_no() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.consignment_no IS NULL OR NEW.consignment_no = '' THEN
    NEW.consignment_no := 'CS-' || extract(year FROM now() AT TIME ZONE 'Asia/Damascus')::int || '-' || lpad(frt.next_number('CONSIGNMENT')::text, 7, '0');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS consignment_no ON frt.consignment;
CREATE TRIGGER consignment_no BEFORE INSERT ON frt.consignment FOR EACH ROW EXECUTE FUNCTION frt.tg_consignment_no();
ALTER TABLE frt.consignment ALTER COLUMN consignment_no SET DEFAULT '';

-- the truck owner's price for a lane and unit on a day: the most specific active rate
CREATE OR REPLACE FUNCTION frt.find_rate(p_company bigint, p_unit text, p_route_kind text, p_from_city bigint, p_from_station bigint,
                                         p_to_city bigint, p_to_station bigint, p_to_country char(2), p_on date DEFAULT current_date)
RETURNS frt.rate_card LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT r.* FROM frt.rate_card r
   WHERE r.company_id = p_company AND r.unit = p_unit AND r.status = 'ACTIVE' AND r.valid @> p_on
     AND (r.route_kind IS NULL OR r.route_kind = p_route_kind)
     AND (r.from_city_id = p_from_city OR r.from_station_id = p_from_station)
     AND (r.to_city_id = p_to_city OR r.to_station_id = p_to_station OR r.to_country = p_to_country)
   ORDER BY (r.route_kind IS NOT NULL) DESC, (r.to_country IS NULL) DESC, r.id DESC
   LIMIT 1
$$;

SELECT sys.rls_catalog('frt.shipping_line');
SELECT sys.rls_split('frt.bill_of_lading', 'frt.can_see_bill(id)', 'sys.tenant_visible(company_id)');
SELECT sys.rls_split('frt.house_bill', 'frt.can_see_bill(bl_id)',
                     'EXISTS (SELECT 1 FROM frt.bill_of_lading b WHERE b.id = bl_id AND sys.tenant_visible(b.company_id))');
SELECT sys.rls_split('frt.bl_container', 'frt.can_see_bill(bl_id)',
                     'EXISTS (SELECT 1 FROM frt.bill_of_lading b WHERE b.id = bl_id AND sys.tenant_visible(b.company_id))');
SELECT sys.rls_split('frt.consignment', 'frt.can_see_consignment(id)', 'sys.tenant_visible(company_id)');
SELECT sys.rls_split('frt.consignment_invoice', 'frt.can_see_consignment(consignment_id)',
                     'EXISTS (SELECT 1 FROM frt.consignment c WHERE c.id = consignment_id AND sys.tenant_visible(c.company_id))');
-- containers are added by whoever registered the consignment or carries it
SELECT sys.rls_split('frt.consignment_container', 'frt.can_see_consignment(consignment_id)', 'frt.can_see_consignment(consignment_id)');
SELECT sys.rls_split('frt.rate_card', 'status = ''ACTIVE'' OR sys.tenant_visible(company_id)', 'sys.tenant_visible(company_id)');
SELECT sys.rls_split('frt.truck_movement', 'sys.tenant_visible(carrier_company_id) OR frt.can_see_consignment(consignment_id)',
                     'sys.tenant_visible(carrier_company_id)');
SELECT sys.rls_split('frt.movement_container',
                     'EXISTS (SELECT 1 FROM frt.truck_movement m WHERE m.id = movement_id AND (sys.tenant_visible(m.carrier_company_id) OR frt.can_see_consignment(m.consignment_id)))',
                     'EXISTS (SELECT 1 FROM frt.truck_movement m WHERE m.id = movement_id AND sys.tenant_visible(m.carrier_company_id))');
SELECT sys.rls_split('frt.movement_event',
                     'EXISTS (SELECT 1 FROM frt.truck_movement m WHERE m.id = movement_id AND (sys.tenant_visible(m.carrier_company_id) OR frt.can_see_consignment(m.consignment_id)))',
                     'false');
SELECT sys.rls_split('frt.transport_invoice',
                     'sys.tenant_visible(carrier_company_id) OR frt.can_see_consignment(consignment_id) OR bill_to_party_id = sys.ctx_party_id()',
                     'sys.tenant_visible(carrier_company_id)');
SELECT sys.rls_split('frt.transport_invoice_line',
                     'EXISTS (SELECT 1 FROM frt.transport_invoice i WHERE i.id = invoice_id)', 'false');
SELECT sys.rls_split('frt.transport_document', 'frt.can_see_document(id)', 'false');
SELECT sys.rls_split('frt.document_consignment', 'frt.can_see_document(document_id)', 'false');
SELECT sys.rls_split('frt.document_vehicle', 'frt.can_see_document(document_id)', 'false');
SELECT sys.rls_platform('frt.number_series');

GRANT SELECT ON frt.shipping_line TO masslak_app, masslak_readonly, masslak_auditor;
GRANT SELECT ON frt.number_series TO masslak_app;          -- the platform reads it; row security shows nothing to anyone else
GRANT SELECT, INSERT, UPDATE ON frt.bill_of_lading, frt.house_bill, frt.bl_container, frt.consignment, frt.consignment_invoice,
  frt.consignment_container, frt.rate_card, frt.truck_movement TO masslak_app;
GRANT SELECT, INSERT ON frt.movement_container TO masslak_app;
-- steps, invoices and documents are written by their functions only
GRANT SELECT ON frt.movement_event, frt.transport_invoice, frt.transport_invoice_line, frt.transport_document, frt.document_consignment,
  frt.document_vehicle TO masslak_app;
GRANT UPDATE (status, void_reason) ON frt.transport_invoice TO masslak_app;
GRANT SELECT ON frt.bill_of_lading, frt.house_bill, frt.bl_container, frt.consignment, frt.consignment_invoice, frt.consignment_container,
  frt.rate_card, frt.truck_movement, frt.movement_container, frt.movement_event, frt.transport_invoice, frt.transport_invoice_line,
  frt.transport_document, frt.document_consignment, frt.document_vehicle TO masslak_readonly, masslak_auditor;

-- the freight switch opens these tables, as it does the rest of the schema (1039)
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['frt.shipping_line','frt.number_series','frt.bill_of_lading','frt.house_bill','frt.bl_container','frt.consignment',
                           'frt.consignment_invoice','frt.consignment_container','frt.rate_card','frt.truck_movement','frt.movement_container',
                           'frt.movement_event','frt.transport_invoice','frt.transport_invoice_line','frt.transport_document',
                           'frt.document_consignment','frt.document_vehicle'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS module_gate ON %s', t);
    EXECUTE format('CREATE POLICY module_gate ON %s AS RESTRICTIVE FOR ALL USING (sys.ctx_is_platform() OR sys.feature_on(%L)) '
                   || 'WITH CHECK (sys.ctx_is_platform() OR sys.feature_on(%L))', t, '{freight}', '{freight}');
  END LOOP;
END $$;

REVOKE ALL ON FUNCTION frt.next_number(text, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION frt.set_movement_status(bigint, text, bigint, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION frt.container_charges(bigint, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION frt.issue_transport_invoice(bigint, text, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION frt.consignment_snapshot(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION frt.vehicle_snapshot(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION frt.document_gaps(bigint, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION frt.issue_document(text, bigint[], bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION frt.void_document(bigint, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION frt.verify_document(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION frt.find_rate(bigint, text, text, bigint, bigint, bigint, bigint, char, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION frt.can_see_consignment(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION frt.can_see_bill(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION frt.can_see_document(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION frt.iso6346_ok(text), frt.container_feet(text) TO masslak_app, masslak_readonly, masslak_auditor;
GRANT EXECUTE ON FUNCTION frt.set_movement_status(bigint, text, bigint, text, text), frt.issue_transport_invoice(bigint, text, bigint),
  frt.consignment_snapshot(bigint), frt.document_gaps(bigint, text), frt.issue_document(text, bigint[], bigint), frt.void_document(bigint, text), frt.verify_document(text, text),
  frt.find_rate(bigint, text, text, bigint, bigint, bigint, bigint, char, date), frt.can_see_consignment(bigint), frt.can_see_bill(bigint),
  frt.can_see_document(bigint) TO masslak_app;
GRANT EXECUTE ON FUNCTION frt.can_see_consignment(bigint), frt.can_see_bill(bigint), frt.can_see_document(bigint) TO masslak_readonly, masslak_auditor;
COMMENT ON FUNCTION frt.set_movement_status IS 'A truck movement goes forward one step; its containers, bill-of-lading containers and consignment follow (1131)';
COMMENT ON FUNCTION frt.issue_transport_invoice IS 'The truck owner invoices the whole bill of lading, one container or the consignment; no container is invoiced twice (1131)';
COMMENT ON FUNCTION frt.document_gaps IS 'What a consignment lacks before a consignment note or a TCN can be issued (1131)';
COMMENT ON FUNCTION frt.issue_document IS 'The platform issues a consignment note or a TCN: complete data checked, a frozen snapshot with its hash and code (1131)';
COMMENT ON FUNCTION frt.void_document IS 'An issued document voided, with the reason (1131)';
COMMENT ON FUNCTION frt.verify_document IS 'A document checked with its number and code: issued, voided or replaced (1131)';
COMMENT ON FUNCTION frt.find_rate IS 'The truck owner''s price for a lane and unit on a day (1131)';

-- ------------------------------------------------------------------ registration
INSERT INTO sys.json_contract (table_name, column_name, kind, version, spec, note) VALUES
  ('frt.transport_document', 'snapshot', 'SNAPSHOT', 1,
   '{"type": "object", "required": ["doc_type", "doc_no", "version", "issued_at", "issuer", "consignments", "vehicles", "totals"]}'::jsonb,
   'the document as issued: its consignments with seller, buyer, route, papers, cargo and containers, and every truck (1131)')
ON CONFLICT DO NOTHING;
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('frt.shipping_line', '8', 'E33'), ('frt.number_series', '8', 'E33'), ('frt.bill_of_lading', '8', 'E33'), ('frt.house_bill', '8', 'E33'),
  ('frt.bl_container', '8', 'E33'), ('frt.consignment', '8', 'E33'), ('frt.consignment_invoice', '8', 'E33'),
  ('frt.consignment_container', '8', 'E33'), ('frt.rate_card', '8', 'E33'), ('frt.truck_movement', '8', 'E33'),
  ('frt.movement_container', '8', 'E33'), ('frt.movement_event', '8', 'E33'), ('frt.transport_invoice', '8', 'E33'),
  ('frt.transport_invoice_line', '8', 'E33'), ('frt.transport_document', '8', 'E33'), ('frt.document_consignment', '8', 'E33'),
  ('frt.document_vehicle', '8', 'E33')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
SELECT sys.refresh_table_class();
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('frt.shipping_line', 'frt records', 'shipping lines (1131)'), ('frt.number_series', 'frt records', 'document and invoice numbers (1131)'),
  ('frt.bill_of_lading', 'frt records', 'bills of lading (1131)'), ('frt.house_bill', 'frt records', 'house bills (1131)'),
  ('frt.bl_container', 'frt records', 'containers of bills of lading (1131)'), ('frt.consignment', 'frt records', 'consignments (1131)'),
  ('frt.consignment_invoice', 'frt records', 'commercial invoices of consignments (1131)'),
  ('frt.consignment_container', 'frt records', 'containers of consignments (1131)'), ('frt.rate_card', 'frt records', 'truck owners'' prices (1131)'),
  ('frt.truck_movement', 'frt records', 'truck movements (1131)'), ('frt.movement_container', 'frt records', 'containers on trucks (1131)'),
  ('frt.movement_event', 'frt records', 'steps of truck movements (1131)'), ('frt.transport_invoice', 'frt records', 'transport invoices (1131)'),
  ('frt.transport_invoice_line', 'frt records', 'lines of transport invoices (1131)'),
  ('frt.transport_document', 'frt records', 'consignment notes and TCNs (1131)'),
  ('frt.document_consignment', 'frt records', 'consignments of documents (1131)'), ('frt.document_vehicle', 'frt records', 'trucks of documents (1131)')
ON CONFLICT (table_name) DO NOTHING;
