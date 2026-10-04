-- =====================================================================
-- 1018: trucking, heavy transport and transit freight (study 10, phase 8) with the cargo data of phase 15
--       (appendix D.3)
--   Freight requests and bids, contracts that produce legs (ship.shipment_leg), containers, yard handovers,
--   port appointments and gate events, transit declarations on a corridor, customs escorts, freight documents,
--   weighbridge readings, detention and freight claims, and geofences.
-- =====================================================================

INSERT INTO ref.trip_type (code, name, module, is_system, sort) VALUES ('FREIGHT','Freight','freight',true,45)
ON CONFLICT (code) DO NOTHING;

CREATE TABLE IF NOT EXISTS net.geofence (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code        text NOT NULL UNIQUE,
  kind        text NOT NULL CHECK (kind IN ('PORT','BORDER','DEPOT','STATION','RESTRICTED','CITY')),
  station_id  bigint REFERENCES net.station(id),
  polygon     jsonb,
  center_lat  numeric(9,6),
  center_lng  numeric(9,6),
  radius_m    int CHECK (radius_m > 0),
  status      text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','RETIRED')),
  CHECK (polygon IS NOT NULL OR (center_lat IS NOT NULL AND center_lng IS NOT NULL AND radius_m IS NOT NULL))
);
COMMENT ON TABLE net.geofence IS 'Geofenced areas (ports, borders, depots, restricted zones) that raise arrival, departure and violation events';

-- ------------------------------ request, bid, contract (10.9) ------------------------------
CREATE TABLE IF NOT EXISTS frt.freight_request (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                    uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  shipper_party_id       bigint NOT NULL REFERENCES iam.party(id),
  shipper_company_id     bigint REFERENCES iam.company(id),
  origin_station_id      bigint REFERENCES net.station(id),
  origin_address_id      bigint REFERENCES ship.address(id),
  dest_station_id        bigint REFERENCES net.station(id),
  dest_address_id        bigint REFERENCES ship.address(id),
  cargo_category         text NOT NULL REFERENCES ref.cargo_category(code),
  cargo_description      text NOT NULL,
  hs_code                text,
  declared_weight_kg     numeric(10,1) NOT NULL CHECK (declared_weight_kg > 0),
  volume_m3              numeric(8,2),
  packages               int CHECK (packages > 0),
  container_count        smallint NOT NULL DEFAULT 0,
  un_number              text CHECK (un_number ~ '^UN[0-9]{4}$'),
  adr_class              text,
  temp_min_c             numeric(4,1),
  temp_max_c             numeric(4,1),
  required_trailer_type  text CHECK (required_trailer_type IN ('FLATBED','CURTAIN','REEFER','TANKER','CONTAINER_CHASSIS','LOWBED','TIPPER','BOX')),
  pickup_window          tstzrange NOT NULL,
  delivery_window        tstzrange,
  mode                   text NOT NULL CHECK (mode IN ('FIXED','BID','DIRECT')),
  target_price           bigint CHECK (target_price >= 0),
  currency               char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  status                 text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','OPEN','AWARDED','CONTRACTED','CANCELLED','EXPIRED')),
  created_at             timestamptz NOT NULL DEFAULT now(),
  CHECK (origin_station_id IS NOT NULL OR origin_address_id IS NOT NULL),
  CHECK (dest_station_id IS NOT NULL OR dest_address_id IS NOT NULL),
  CHECK (adr_class IS NULL OR un_number IS NOT NULL),
  CHECK (temp_min_c IS NULL OR temp_max_c IS NULL OR temp_min_c <= temp_max_c)
);
COMMENT ON TABLE frt.freight_request IS 'The shipper''s request with the cargo data of D.3 (category, description, weight, UN number and hazard class)';

CREATE TABLE IF NOT EXISTS frt.freight_bid (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  request_id          bigint NOT NULL REFERENCES frt.freight_request(id),
  carrier_company_id  bigint NOT NULL REFERENCES iam.company(id),
  truck_vehicle_id    bigint REFERENCES fleet.truck_unit(vehicle_id),
  price               bigint NOT NULL CHECK (price > 0),
  currency            char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  valid_until         timestamptz NOT NULL,
  status              text NOT NULL DEFAULT 'SUBMITTED' CHECK (status IN ('SUBMITTED','WITHDRAWN','ACCEPTED','REJECTED','EXPIRED')),
  created_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (request_id, carrier_company_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS freight_bid_one_accepted ON frt.freight_bid (request_id) WHERE status = 'ACCEPTED';

CREATE TABLE IF NOT EXISTS frt.freight_contract (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                 uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  request_id          bigint NOT NULL UNIQUE REFERENCES frt.freight_request(id),
  carrier_company_id  bigint NOT NULL REFERENCES iam.company(id),
  accepted_bid_id     bigint REFERENCES frt.freight_bid(id),
  terms               jsonb NOT NULL,
  price               bigint NOT NULL CHECK (price > 0),
  currency            char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  price_breakdown     jsonb,                                          -- price snapshot
  advance_pct         numeric(5,2) NOT NULL DEFAULT 0 CHECK (advance_pct BETWEEN 0 AND 100),
  status              text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','SIGNED','IN_PROGRESS','COMPLETED','CANCELLED','DISPUTED')),
  signed_at           timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE frt.freight_contract IS 'Contract from an awarded request; it produces one or more legs';

-- Legs of a freight contract are shipment legs (9.9 generalizes 10.9)
ALTER TABLE ship.shipment_leg ADD COLUMN IF NOT EXISTS contract_id bigint REFERENCES frt.freight_contract(id);
CREATE UNIQUE INDEX IF NOT EXISTS shipment_leg_contract_seq ON ship.shipment_leg (contract_id, seq) WHERE contract_id IS NOT NULL;
DO $$ BEGIN
  ALTER TABLE ship.shipment_leg ADD CONSTRAINT shipment_leg_owner_ck CHECK (shipment_id IS NOT NULL OR contract_id IS NOT NULL);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ------------------------------ containers and yard (10.9) ------------------------------
CREATE TABLE IF NOT EXISTS frt.container (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  container_no     text NOT NULL UNIQUE CHECK (container_no ~ '^[A-Z]{3}[UJZ][0-9]{7}$'),   -- ISO 6346
  size_type        text NOT NULL,                                     -- e.g. 22G1, 45G1, 22R1
  owner_party_id   bigint REFERENCES iam.party(id),
  tare_kg          int CHECK (tare_kg > 0),
  status           text NOT NULL DEFAULT 'EMPTY' CHECK (status IN ('EMPTY','LOADED','IN_TRANSIT','AT_PORT','RETURNED'))
);
CREATE TABLE IF NOT EXISTS frt.leg_container (
  leg_id           bigint NOT NULL REFERENCES ship.shipment_leg(id) ON DELETE CASCADE,
  container_id     bigint NOT NULL REFERENCES frt.container(id),
  seal_no          text,
  gross_weight_kg  int CHECK (gross_weight_kg > 0),
  PRIMARY KEY (leg_id, container_id)
);
COMMENT ON TABLE frt.leg_container IS 'Containers carried on a leg, with the seal and gross weight of that leg';

CREATE TABLE IF NOT EXISTS frt.handover_event (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  leg_id              bigint NOT NULL REFERENCES ship.shipment_leg(id),
  next_leg_id         bigint REFERENCES ship.shipment_leg(id),
  from_company_id     bigint NOT NULL REFERENCES iam.company(id),
  to_company_id       bigint NOT NULL REFERENCES iam.company(id),
  station_id          bigint REFERENCES net.station(id),
  seal_no             text,
  weight_kg           numeric(10,1),
  docs_checked        boolean NOT NULL DEFAULT false,
  from_signature_file_id bigint REFERENCES ref.file_object(id),
  to_signature_file_id   bigint REFERENCES ref.file_object(id),
  ts                  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE frt.handover_event IS 'Handover between carriers in the yard: seal, weight, documents and both signatures; append-only';

CREATE TABLE IF NOT EXISTS frt.port_appointment (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  port_station_id   bigint NOT NULL REFERENCES net.station(id),
  truck_vehicle_id  bigint NOT NULL REFERENCES fleet.truck_unit(vehicle_id),
  leg_id            bigint REFERENCES ship.shipment_leg(id),
  slot              tstzrange NOT NULL,
  status            text NOT NULL DEFAULT 'BOOKED' CHECK (status IN ('BOOKED','ARRIVED','COMPLETED','MISSED','CANCELLED'))
);
CREATE TABLE IF NOT EXISTS frt.gate_event (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  appointment_id    bigint REFERENCES frt.port_appointment(id),
  port_station_id   bigint NOT NULL REFERENCES net.station(id),
  truck_vehicle_id  bigint NOT NULL REFERENCES fleet.truck_unit(vehicle_id),
  direction         text NOT NULL CHECK (direction IN ('IN','OUT')),
  ts                timestamptz NOT NULL DEFAULT now()
);

-- ------------------------------ transit and compliance (10.9, D.3) ------------------------------
CREATE TABLE IF NOT EXISTS frt.transit_declaration (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  leg_id              bigint NOT NULL REFERENCES ship.shipment_leg(id),
  declaration_no      text NOT NULL UNIQUE,
  entry_station_id    bigint NOT NULL REFERENCES net.station(id),     -- border point
  exit_station_id     bigint NOT NULL REFERENCES net.station(id),
  corridor_id         bigint REFERENCES net.corridor(id),
  deadline            timestamptz NOT NULL,
  cargo_category      text NOT NULL REFERENCES ref.cargo_category(code),
  cargo_description   text NOT NULL,
  hs_code             text,
  declared_weight_kg  numeric(10,1) NOT NULL CHECK (declared_weight_kg > 0),
  packages            int CHECK (packages > 0),
  un_number           text CHECK (un_number ~ '^UN[0-9]{4}$'),
  adr_class           text,
  temp_min_c          numeric(4,1),
  temp_max_c          numeric(4,1),
  status              text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','IN_TRANSIT','DISCHARGED','OVERDUE','CANCELLED')),
  created_at          timestamptz NOT NULL DEFAULT now(),
  CHECK (entry_station_id <> exit_station_id),
  CHECK (adr_class IS NULL OR un_number IS NOT NULL)
);
COMMENT ON TABLE frt.transit_declaration IS 'Transit across the country on a corridor with a deadline; carries the D.3 cargo data for the authorities';

CREATE TABLE IF NOT EXISTS frt.escort_assignment (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  leg_id           bigint NOT NULL REFERENCES ship.shipment_leg(id),
  escort_party_id  bigint NOT NULL REFERENCES iam.party(id),
  period           tstzrange NOT NULL,
  status           text NOT NULL DEFAULT 'ASSIGNED' CHECK (status IN ('ASSIGNED','ACTIVE','COMPLETED','CANCELLED'))
);

CREATE TABLE IF NOT EXISTS frt.freight_document (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  contract_id  bigint REFERENCES frt.freight_contract(id),
  leg_id       bigint REFERENCES ship.shipment_leg(id),
  doc_type     text NOT NULL CHECK (doc_type IN ('CMR','BILL_OF_LADING','CUSTOMS','TRANSPORT_RECEIPT','COMMERCIAL_INVOICE','PACKING_LIST','PERMIT','OTHER')),
  doc_no       text NOT NULL,
  file_id      bigint REFERENCES ref.file_object(id),
  status       text NOT NULL DEFAULT 'UPLOADED' CHECK (status IN ('UPLOADED','VERIFIED','REJECTED')),
  verified_by  bigint REFERENCES iam.app_user(id),
  CHECK (contract_id IS NOT NULL OR leg_id IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS frt.weighbridge_reading (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  leg_id         bigint REFERENCES ship.shipment_leg(id),
  station_id     bigint NOT NULL REFERENCES net.station(id),
  vehicle_id     bigint NOT NULL REFERENCES fleet.vehicle(id),
  gross_kg       int NOT NULL CHECK (gross_kg > 0),
  declared_kg    int,
  alert          boolean NOT NULL DEFAULT false,                     -- difference beyond tolerance (10.7, D.3)
  ts             timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE frt.weighbridge_reading IS 'Weighbridge weight compared with the declared weight; a difference raises an alert (10.7, D.3)';

CREATE TABLE IF NOT EXISTS frt.detention_claim (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  contract_id    bigint NOT NULL REFERENCES frt.freight_contract(id),
  leg_id         bigint REFERENCES ship.shipment_leg(id),
  station_id     bigint REFERENCES net.station(id),
  waiting        tstzrange NOT NULL,
  free_minutes   int NOT NULL DEFAULT 120,
  rate_per_hour  bigint NOT NULL CHECK (rate_per_hour >= 0),
  amount         bigint NOT NULL DEFAULT 0,
  currency       char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  status         text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','APPROVED','REJECTED','PAID'))
);
CREATE TABLE IF NOT EXISTS frt.freight_claim (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  contract_id  bigint NOT NULL REFERENCES frt.freight_contract(id),
  leg_id       bigint REFERENCES ship.shipment_leg(id),
  claim_type   text NOT NULL CHECK (claim_type IN ('DAMAGE','LOSS','DELAY','SHORTAGE')),
  amount       bigint NOT NULL CHECK (amount >= 0),
  currency     char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  case_id      bigint REFERENCES crm.case(id),
  status       text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','UNDER_REVIEW','APPROVED','REJECTED','PAID')),
  created_at   timestamptz NOT NULL DEFAULT now()
);

-- ------------------------------ isolation and privileges ------------------------------
CREATE OR REPLACE FUNCTION frt.can_see_request(p_request_id bigint) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT sys.ctx_is_platform()
      OR EXISTS (SELECT 1 FROM frt.freight_request r WHERE r.id = p_request_id
                 AND (r.shipper_party_id = sys.ctx_party_id() OR r.shipper_company_id = sys.ctx_company_id()))
$$;
CREATE OR REPLACE FUNCTION frt.can_see_contract(p_contract_id bigint) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT sys.ctx_is_platform()
      OR EXISTS (SELECT 1 FROM frt.freight_contract c WHERE c.id = p_contract_id
                 AND (c.carrier_company_id = sys.ctx_company_id() OR frt.can_see_request(c.request_id)))
$$;
-- A leg is visible to its carrier, the shipment's parties and the freight contract's parties
CREATE OR REPLACE FUNCTION frt.can_see_leg(p_leg_id bigint) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT EXISTS (SELECT 1 FROM ship.shipment_leg l WHERE l.id = p_leg_id
                 AND (sys.tenant_visible(l.carrier_company_id) OR ship.can_see_shipment(l.shipment_id) OR frt.can_see_contract(l.contract_id)))
$$;
DO $$ BEGIN
  PERFORM sys.rls_catalog('net.geofence');
  -- open BID requests are visible to every carrier so they can bid
  PERFORM sys.rls('frt.freight_request', 'frt.can_see_request(id) OR (status = ''OPEN'' AND mode = ''BID'' AND sys.ctx_company_id() IS NOT NULL)',
    'sys.ctx_is_platform() OR shipper_party_id = sys.ctx_party_id() OR sys.tenant_visible(shipper_company_id)');
  PERFORM sys.rls('frt.freight_bid', 'sys.tenant_visible(carrier_company_id) OR frt.can_see_request(request_id)',
    'sys.tenant_visible(carrier_company_id) OR frt.can_see_request(request_id)');
  PERFORM sys.rls('frt.freight_contract', 'frt.can_see_contract(id)');
  PERFORM sys.rls('ship.shipment_leg', 'sys.tenant_visible(carrier_company_id) OR ship.can_see_shipment(shipment_id) OR frt.can_see_contract(contract_id)');
  PERFORM sys.rls(t, 'frt.can_see_leg(leg_id)') FROM unnest(ARRAY['frt.leg_container','frt.handover_event','frt.transit_declaration',
    'frt.escort_assignment']) t;
  PERFORM sys.rls('frt.port_appointment', 'sys.ctx_is_platform() OR frt.can_see_leg(leg_id)
    OR EXISTS (SELECT 1 FROM fleet.vehicle v WHERE v.id = port_appointment.truck_vehicle_id)');
  PERFORM sys.rls('frt.gate_event', 'sys.ctx_is_platform() OR EXISTS (SELECT 1 FROM fleet.vehicle v WHERE v.id = gate_event.truck_vehicle_id)');
  PERFORM sys.rls('frt.weighbridge_reading', 'sys.ctx_is_platform() OR frt.can_see_leg(leg_id)
    OR EXISTS (SELECT 1 FROM fleet.vehicle v WHERE v.id = weighbridge_reading.vehicle_id)');
  PERFORM sys.rls('frt.freight_document', 'frt.can_see_contract(contract_id) OR frt.can_see_leg(leg_id)');
  PERFORM sys.rls(t, 'frt.can_see_contract(contract_id)') FROM unnest(ARRAY['frt.detention_claim','frt.freight_claim']) t;
  PERFORM sys.rls('frt.container', 'true', 'sys.ctx_is_platform() OR sys.ctx_company_id() IS NOT NULL');
  PERFORM sys.grant_rw(ARRAY['net.geofence','frt.freight_request','frt.freight_bid','frt.freight_contract','frt.container',
    'frt.leg_container','frt.port_appointment','frt.transit_declaration','frt.escort_assignment','frt.freight_document',
    'frt.detention_claim','frt.freight_claim']);
  PERFORM sys.grant_append(ARRAY['frt.handover_event','frt.gate_event','frt.weighbridge_reading']);
END $$;
