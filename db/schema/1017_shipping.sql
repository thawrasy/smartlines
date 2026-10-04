-- =====================================================================
-- 1017: integrated shipping and consignments (study 9: phase 3, 9.9 integrated system, 9.21 unified network,
--       9.25 partner integration)
--   Generalizations adopted from the study: shipment_leg covers cargo_assignment (a BUS_HOLD leg on a trip),
--   capacity_booking covers cargo_booking, tracking_event covers shipment_event, and webhook subscriptions are
--   sys.webhook_endpoint. A shipment is independent of any trip; its legs carry it across modes.
-- =====================================================================

-- ------------------------------ service catalog and zones (9.21) ------------------------------
CREATE TABLE IF NOT EXISTS ship.surcharge_definition (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code          text NOT NULL,
  name          text NOT NULL,
  trigger_rule  jsonb NOT NULL DEFAULT '{}',
  calc_method   text NOT NULL CHECK (calc_method IN ('FIXED','PCT','PER_KG','PER_PIECE')),
  value         numeric(12,4) NOT NULL CHECK (value >= 0),
  currency      char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  valid         daterange NOT NULL DEFAULT daterange(current_date, NULL),
  EXCLUDE USING gist (code WITH =, valid WITH &&)
);

CREATE TABLE IF NOT EXISTS ship.service_product (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code           text NOT NULL UNIQUE CHECK (code IN ('SAME_DAY','PRIORITY_AM','EXPRESS_1D','EXPRESS_2D','GROUND','ECONOMY','FREIGHT_LTL','FREIGHT_FTL')),
  name           text NOT NULL,
  cutoff_time    time,
  guaranteed     boolean NOT NULL DEFAULT false,
  max_weight_kg  numeric(9,2),
  max_dims_cm    int[],                                           -- {length, width, height}
  network_model  text NOT NULL DEFAULT 'NETWORK' CHECK (network_model IN ('NETWORK','MARKETPLACE')),
  status         text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','RETIRED'))
);

CREATE TABLE IF NOT EXISTS ship.service_option (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code                 text NOT NULL UNIQUE,                     -- WEEKEND, HOLD_AT_LOCATION, SIGNATURE_*, DECLARED_VALUE, COD, FRAGILE, COLD, DG, RETURN_LABEL
  name                 text NOT NULL,
  applicable_services  text[] NOT NULL DEFAULT '{}',
  surcharge_id         bigint REFERENCES ship.surcharge_definition(id)
);

CREATE TABLE IF NOT EXISTS ship.hub (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  station_id     bigint NOT NULL UNIQUE REFERENCES net.station(id),   -- subtype DEPOT
  company_id     bigint REFERENCES iam.company(id),                   -- empty: a platform network hub
  sort_capacity  int CHECK (sort_capacity > 0),                       -- pieces per hour
  hours          jsonb NOT NULL DEFAULT '{}',
  status         text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','SUSPENDED','CLOSED'))
);
COMMENT ON TABLE ship.hub IS 'Sorting hub on a depot station (9.9)';

CREATE TABLE IF NOT EXISTS ship.geo_zone (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  country_code      char(2) NOT NULL REFERENCES ref.country(code),
  governorate       text,
  city_id           bigint REFERENCES ref.city(id),
  district          text,
  polygon           jsonb,
  zone_class        text NOT NULL DEFAULT 'NORMAL' CHECK (zone_class IN ('NORMAL','EXTENDED','REMOTE')),
  servicing_hub_id  bigint REFERENCES ship.hub(id),
  delivery_days     smallint[] NOT NULL DEFAULT '{1,2,3,4,5,6}'
);
COMMENT ON TABLE ship.geo_zone IS 'Delivery zone served by a hub, with its class (remote areas carry a surcharge)';

CREATE TABLE IF NOT EXISTS ship.pricing_zone_chart (
  origin_zone_id  bigint NOT NULL REFERENCES ship.geo_zone(id),
  dest_zone_id    bigint NOT NULL REFERENCES ship.geo_zone(id),
  price_zone      text NOT NULL CHECK (price_zone IN ('Z1','Z2','Z3','Z4','Z5')),
  valid           daterange NOT NULL DEFAULT daterange(current_date, NULL),
  PRIMARY KEY (origin_zone_id, dest_zone_id, valid)
);

CREATE TABLE IF NOT EXISTS ship.transit_time_matrix (
  origin_zone_id    bigint NOT NULL REFERENCES ship.geo_zone(id),
  dest_zone_id      bigint NOT NULL REFERENCES ship.geo_zone(id),
  service_id        bigint NOT NULL REFERENCES ship.service_product(id),
  transit_days      smallint NOT NULL CHECK (transit_days >= 0),
  delivery_by_time  time,
  PRIMARY KEY (origin_zone_id, dest_zone_id, service_id)
);

CREATE TABLE IF NOT EXISTS ship.rate_table (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id  bigint REFERENCES iam.company(id),                    -- empty: the platform network rates
  service_id  bigint NOT NULL REFERENCES ship.service_product(id),
  currency    char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  valid       daterange NOT NULL,
  status      text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','PUBLISHED','RETIRED'))
);
CREATE TABLE IF NOT EXISTS ship.rate_table_entry (
  rate_table_id  bigint NOT NULL REFERENCES ship.rate_table(id) ON DELETE CASCADE,
  price_zone     text NOT NULL CHECK (price_zone IN ('Z1','Z2','Z3','Z4','Z5')),
  weight_break   numeric(9,2) NOT NULL CHECK (weight_break > 0),     -- up to this weight (kg)
  price          bigint NOT NULL CHECK (price >= 0),
  per_kg_over    bigint NOT NULL DEFAULT 0,
  min_charge     bigint NOT NULL DEFAULT 0,
  PRIMARY KEY (rate_table_id, price_zone, weight_break)
);
COMMENT ON TABLE ship.rate_table IS 'Published rate table per service: price by zone and weight break (9.21)';

CREATE TABLE IF NOT EXISTS ship.fuel_surcharge_index (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  period            daterange NOT NULL,
  diesel_price_ref  bigint NOT NULL,
  pct               numeric(5,2) NOT NULL CHECK (pct BETWEEN 0 AND 100),
  published_at      timestamptz NOT NULL DEFAULT now(),
  EXCLUDE USING gist (period WITH &&)
);

CREATE TABLE IF NOT EXISTS ship.cargo_rate_card (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id     bigint NOT NULL REFERENCES iam.company(id),
  route_id       bigint REFERENCES net.route(id),                    -- the segment
  service_id     bigint REFERENCES ship.service_product(id),
  weight_from_kg numeric(9,2) NOT NULL DEFAULT 0,
  weight_to_kg   numeric(9,2) NOT NULL,
  volume_to_m3   numeric(8,3),
  price          bigint NOT NULL CHECK (price >= 0),
  currency       char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  valid          daterange NOT NULL,
  CHECK (weight_to_kg > weight_from_kg)
);
COMMENT ON TABLE ship.cargo_rate_card IS 'A bus carrier''s rates for parcels in the luggage hold (9.4); feeds the pricing engine';

CREATE TABLE IF NOT EXISTS ship.prohibited_item (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code         text NOT NULL UNIQUE,
  name         text NOT NULL,
  hs_prefix    text,
  rule         text NOT NULL CHECK (rule IN ('PROHIBITED','RESTRICTED','NEEDS_PERMIT')),
  country_code char(2) REFERENCES ref.country(code)
);

-- ------------------------------ accounts and addresses ------------------------------
CREATE TABLE IF NOT EXISTS ship.address (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  party_id          bigint REFERENCES iam.party(id),
  geo_zone_id       bigint REFERENCES ship.geo_zone(id),
  lat               numeric(9,6),
  lng               numeric(9,6),
  address_text      text NOT NULL,
  landmark          text,
  short_code        text UNIQUE,                                      -- short address code
  verified          boolean NOT NULL DEFAULT false,
  last_delivered_at timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE ship.address IS 'Structured address with a short code, for areas without formal addresses (9.21)';

CREATE TABLE IF NOT EXISTS ship.pricing_agreement (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id           bigint REFERENCES iam.company(id),
  discounts            jsonb NOT NULL DEFAULT '{}',                    -- service x zone
  earned_tiers         jsonb NOT NULL DEFAULT '[]',
  min_charge_override  bigint,
  valid                daterange NOT NULL,
  status               text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('DRAFT','ACTIVE','ENDED'))
);

CREATE TABLE IF NOT EXISTS ship.shipper_account (
  id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  account_no            text NOT NULL UNIQUE,
  party_id              bigint NOT NULL REFERENCES iam.party(id),
  company_id            bigint REFERENCES iam.company(id),            -- the network or courier that holds the account
  account_type          text NOT NULL CHECK (account_type IN ('CASUAL','PREPAID','CREDIT')),
  credit_limit          bigint CHECK (credit_limit >= 0),
  billing_cycle         text CHECK (billing_cycle IN ('WEEKLY','MONTHLY')),
  wallet_id             bigint REFERENCES fin.wallet(id),
  pricing_agreement_id  bigint REFERENCES ship.pricing_agreement(id),
  status                text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('PENDING','ACTIVE','ON_HOLD','CLOSED')),
  created_at            timestamptz NOT NULL DEFAULT now(),
  CHECK (account_type <> 'CREDIT' OR credit_limit IS NOT NULL)
);
ALTER TABLE ship.pricing_agreement ADD COLUMN IF NOT EXISTS account_id bigint REFERENCES ship.shipper_account(id);

-- ------------------------------ access points and lockers (9.21) ------------------------------
CREATE TABLE IF NOT EXISTS ship.access_point (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  station_id        bigint NOT NULL UNIQUE REFERENCES net.station(id),
  partner_party_id  bigint REFERENCES iam.party(id),
  point_type        text NOT NULL CHECK (point_type IN ('ACCESS_POINT','LOCKER','DROP_BOX')),
  capacity          int CHECK (capacity > 0),
  hours             jsonb NOT NULL DEFAULT '{}',
  services          text[] NOT NULL DEFAULT '{DROP_OFF,PICK_UP}',
  hold_days         smallint NOT NULL DEFAULT 5 CHECK (hold_days BETWEEN 1 AND 30),
  commission_bp     int NOT NULL DEFAULT 0 CHECK (commission_bp BETWEEN 0 AND 10000),
  status            text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','SUSPENDED','CLOSED'))
);

-- ------------------------------ the shipment (9.4, 9.9, 9.21) ------------------------------
CREATE TABLE IF NOT EXISTS ship.shipment (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                    uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  tracking_no            text NOT NULL UNIQUE,                       -- with a mod-11 check digit (4.16 b)
  master_tracking_no     text,                                       -- multi-piece shipments
  company_id             bigint NOT NULL REFERENCES iam.company(id), -- the network or carrier that accepted it
  shipper_party_id       bigint NOT NULL REFERENCES iam.party(id),
  shipper_account_id     bigint REFERENCES ship.shipper_account(id),
  merchant_ref           text,
  service_id             bigint NOT NULL REFERENCES ship.service_product(id),
  shipper_type           text NOT NULL DEFAULT 'INDIVIDUAL' CHECK (shipper_type IN ('INDIVIDUAL','MERCHANT','COURIER','PARTNER')),
  origin_station_id      bigint REFERENCES net.station(id),
  dest_station_id        bigint REFERENCES net.station(id),
  origin_address_id      bigint REFERENCES ship.address(id),
  dest_address_id        bigint REFERENCES ship.address(id),
  payer_type             text NOT NULL DEFAULT 'SENDER' CHECK (payer_type IN ('SENDER','RECIPIENT','THIRD_PARTY')),
  payer_account_id       bigint REFERENCES ship.shipper_account(id),
  declared_value         bigint NOT NULL DEFAULT 0 CHECK (declared_value >= 0),
  cod_amount             bigint NOT NULL DEFAULT 0 CHECK (cod_amount >= 0),
  currency               char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  billable_weight_kg     numeric(9,2),
  dim_weight_kg          numeric(9,2),
  cargo_category         text REFERENCES ref.cargo_category(code),
  routing_code           text,
  committed_delivery_at  timestamptz,
  signature_level        text NOT NULL DEFAULT 'NONE' CHECK (signature_level IN ('NONE','OTP','SIGNATURE','ID_CHECK')),
  price_breakdown        jsonb,                                      -- price snapshot (price_snapshot_id in 9.4)
  current_leg_seq        smallint,
  eta                    timestamptz,
  status                 text NOT NULL DEFAULT 'CREATED' CHECK (status IN
                           ('EXPECTED','CREATED','PICKED_UP','IN_NETWORK','OUT_FOR_DELIVERY','DELIVERED','EXCEPTION','RETURNED','CANCELLED')),
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  CHECK (origin_station_id IS NOT NULL OR origin_address_id IS NOT NULL),
  CHECK (dest_station_id IS NOT NULL OR dest_address_id IS NOT NULL),
  CHECK (payer_type = 'SENDER' OR payer_account_id IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS shipment_company_idx ON ship.shipment (company_id, status, created_at);
CREATE INDEX IF NOT EXISTS shipment_shipper_idx ON ship.shipment (shipper_party_id, created_at);
COMMENT ON TABLE ship.shipment IS 'A consignment from sender to receiver, independent of the vehicles that carry it (9.4, 9.9)';

CREATE TABLE IF NOT EXISTS ship.shipment_party (
  shipment_id  bigint NOT NULL REFERENCES ship.shipment(id) ON DELETE CASCADE,
  role         text NOT NULL CHECK (role IN ('SENDER','RECEIVER','THIRD_PARTY')),
  party_id     bigint REFERENCES iam.party(id),
  name         text NOT NULL,
  id_type      text,
  id_no_enc    bytea,
  id_no_bidx   bytea,
  enc_key_id   int REFERENCES sec.key_registry(id),
  mobile       text NOT NULL,
  address_id   bigint REFERENCES ship.address(id),
  PRIMARY KEY (shipment_id, role),
  CHECK (id_no_enc IS NULL OR enc_key_id IS NOT NULL)
);
COMMENT ON TABLE ship.shipment_party IS 'Sender and receiver data required for security screening; identity numbers are encrypted';

CREATE TABLE IF NOT EXISTS ship.shipment_option (
  shipment_id  bigint NOT NULL REFERENCES ship.shipment(id) ON DELETE CASCADE,
  option_id    bigint NOT NULL REFERENCES ship.service_option(id),
  value        jsonb,
  PRIMARY KEY (shipment_id, option_id)
);

CREATE TABLE IF NOT EXISTS ship.parcel (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  shipment_id    bigint NOT NULL REFERENCES ship.shipment(id) ON DELETE CASCADE,
  piece_no       smallint NOT NULL CHECK (piece_no >= 1),
  label_no       text NOT NULL UNIQUE,                               -- QR label
  weight_kg      numeric(9,2) NOT NULL CHECK (weight_kg > 0),
  length_cm      numeric(7,1),
  width_cm       numeric(7,1),
  height_cm      numeric(7,1),
  content_desc   text NOT NULL,
  hs_code        text,
  fragile        boolean NOT NULL DEFAULT false,
  UNIQUE (shipment_id, piece_no)
);

-- ------------------------------ handling units and loads (9.9) ------------------------------
CREATE TABLE IF NOT EXISTS ship.handling_unit (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id      bigint NOT NULL REFERENCES iam.company(id),
  unit_type       text NOT NULL CHECK (unit_type IN ('BAG','CAGE','PALLET','CONTAINER')),
  parent_unit_id  bigint REFERENCES ship.handling_unit(id),
  label_no        text NOT NULL UNIQUE,
  seal_no         text,
  current_station_id bigint REFERENCES net.station(id),
  status          text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','CLOSED','IN_TRANSIT','ARRIVED','OPENED')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  CHECK (parent_unit_id IS NULL OR parent_unit_id <> id)
);
COMMENT ON TABLE ship.handling_unit IS 'Bag, cage, pallet or container; units nest, and a unit''s scan is inherited by its contents';

CREATE TABLE IF NOT EXISTS ship.handling_unit_item (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  unit_id     bigint NOT NULL REFERENCES ship.handling_unit(id),
  shipment_id bigint REFERENCES ship.shipment(id),
  parcel_id   bigint REFERENCES ship.parcel(id),
  added_at    timestamptz NOT NULL DEFAULT now(),
  removed_at  timestamptz,
  CHECK ((shipment_id IS NULL) <> (parcel_id IS NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS hu_item_parcel_once ON ship.handling_unit_item (parcel_id) WHERE removed_at IS NULL AND parcel_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS ship.load (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  company_id         bigint NOT NULL REFERENCES iam.company(id),
  trip_id            bigint UNIQUE REFERENCES ops.trip(id),           -- a FREIGHT trip numbered from block 3000
  vehicle_id         bigint REFERENCES fleet.vehicle(id),
  truck_combination_id bigint REFERENCES fleet.truck_combination(id),
  load_type          text NOT NULL CHECK (load_type IN ('FTL','LTL','BUS_HOLD')),
  origin_hub_id      bigint REFERENCES ship.hub(id),
  dest_hub_id        bigint REFERENCES ship.hub(id),
  max_weight_kg      numeric(10,2) NOT NULL CHECK (max_weight_kg > 0),
  max_volume_m3      numeric(8,2),
  pallet_positions   smallint,
  used_weight_kg     numeric(10,2) NOT NULL DEFAULT 0,
  used_volume_m3     numeric(8,2) NOT NULL DEFAULT 0,
  seal_no            text,
  status             text NOT NULL DEFAULT 'PLANNED' CHECK (status IN ('PLANNED','LOADING','SEALED','IN_TRANSIT','ARRIVED','CLOSED')),
  created_at         timestamptz NOT NULL DEFAULT now(),
  CHECK (used_weight_kg <= max_weight_kg),
  CHECK (vehicle_id IS NOT NULL OR truck_combination_id IS NOT NULL)
);
COMMENT ON TABLE ship.load IS 'Truck or hold load with capacity by weight, volume and pallet positions; no booking once full (9.9)';

CREATE TABLE IF NOT EXISTS ship.load_stop (
  load_id     bigint NOT NULL REFERENCES ship.load(id) ON DELETE CASCADE,
  seq         smallint NOT NULL CHECK (seq >= 1),
  station_id  bigint NOT NULL REFERENCES net.station(id),
  planned_at  timestamptz,
  actual_at   timestamptz,
  PRIMARY KEY (load_id, seq)
);

CREATE TABLE IF NOT EXISTS ship.load_plan (
  load_id           bigint NOT NULL REFERENCES ship.load(id) ON DELETE CASCADE,
  handling_unit_id  bigint NOT NULL REFERENCES ship.handling_unit(id),
  stop_seq          smallint NOT NULL,                               -- unloaded at this stop
  position          text,
  PRIMARY KEY (load_id, handling_unit_id)
);

CREATE TABLE IF NOT EXISTS ship.trip_cargo_capacity (
  trip_id        bigint PRIMARY KEY REFERENCES ops.trip(id),
  max_weight_kg  numeric(9,2) NOT NULL CHECK (max_weight_kg >= 0),
  max_volume_m3  numeric(7,2),
  max_items      int,
  used_weight_kg numeric(9,2) NOT NULL DEFAULT 0,
  used_volume_m3 numeric(7,2) NOT NULL DEFAULT 0,
  used_items     int NOT NULL DEFAULT 0,
  CHECK (used_weight_kg <= max_weight_kg)
);
COMMENT ON TABLE ship.trip_cargo_capacity IS 'Hold capacity of a passenger trip offered to parcels (9.4)';

-- ------------------------------ courier operations (9.9) ------------------------------
CREATE TABLE IF NOT EXISTS ship.courier_route (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id      bigint NOT NULL REFERENCES iam.company(id),
  hub_id          bigint REFERENCES ship.hub(id),
  courier_user_id bigint NOT NULL REFERENCES iam.app_user(id),
  vehicle_id      bigint REFERENCES fleet.vehicle(id),
  route_date      date NOT NULL,
  status          text NOT NULL DEFAULT 'PLANNED' CHECK (status IN ('PLANNED','IN_PROGRESS','COMPLETED','CANCELLED'))
);

CREATE TABLE IF NOT EXISTS ship.pickup_request (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id      bigint NOT NULL REFERENCES iam.company(id),
  shipper_party_id bigint NOT NULL REFERENCES iam.party(id),
  address_id      bigint NOT NULL REFERENCES ship.address(id),
  pickup_window   tstzrange NOT NULL,
  pieces          int NOT NULL DEFAULT 1 CHECK (pieces > 0),
  courier_route_id bigint REFERENCES ship.courier_route(id),
  status          text NOT NULL DEFAULT 'REQUESTED' CHECK (status IN ('REQUESTED','ASSIGNED','PICKED_UP','FAILED','CANCELLED')),
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ship.courier_assignment (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  courier_route_id  bigint NOT NULL REFERENCES ship.courier_route(id) ON DELETE CASCADE,
  stop_seq          smallint NOT NULL,
  kind              text NOT NULL CHECK (kind IN ('PICKUP','DELIVERY')),
  shipment_id       bigint REFERENCES ship.shipment(id),
  pickup_request_id bigint REFERENCES ship.pickup_request(id),
  eta               timestamptz,
  status            text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','DONE','FAILED','SKIPPED')),
  UNIQUE (courier_route_id, stop_seq),
  CHECK ((kind = 'DELIVERY' AND shipment_id IS NOT NULL) OR (kind = 'PICKUP' AND pickup_request_id IS NOT NULL))
);

CREATE TABLE IF NOT EXISTS ship.routing_rule (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id       bigint REFERENCES iam.company(id),
  service_id       bigint NOT NULL REFERENCES ship.service_product(id),
  origin_zone_id   bigint REFERENCES ship.geo_zone(id),
  dest_zone_id     bigint REFERENCES ship.geo_zone(id),
  preferred_modes  text[] NOT NULL,
  cutoff_time      time,
  transit_days     smallint,
  priority         int NOT NULL DEFAULT 100
);

CREATE TABLE IF NOT EXISTS ship.linehaul_schedule (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  origin_hub_id      bigint NOT NULL REFERENCES ship.hub(id),
  dest_hub_id        bigint NOT NULL REFERENCES ship.hub(id),
  departure_time     time NOT NULL,
  arrival_time       time NOT NULL,
  days               smallint[] NOT NULL DEFAULT '{1,2,3,4,5,6}',
  mode               text NOT NULL CHECK (mode IN ('BUS_HOLD','TRUCK')),
  carrier_company_id bigint NOT NULL REFERENCES iam.company(id),
  capacity_kg        numeric(10,2),
  status             text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','SUSPENDED','RETIRED')),
  CHECK (origin_hub_id <> dest_hub_id)
);

CREATE TABLE IF NOT EXISTS ship.sort_window (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  hub_id      bigint NOT NULL REFERENCES ship.hub(id),
  direction   text NOT NULL CHECK (direction IN ('OUTBOUND','INBOUND')),
  starts_at   time NOT NULL,
  ends_at     time NOT NULL,
  cutoff      time NOT NULL
);

-- ------------------------------ legs, capacity and tracking (9.9) ------------------------------
CREATE TABLE IF NOT EXISTS ship.shipment_leg (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  shipment_id         bigint REFERENCES ship.shipment(id),            -- empty for a freight leg without a parcel shipment
  seq                 smallint NOT NULL CHECK (seq >= 1),
  mode                text NOT NULL CHECK (mode IN ('BUS_HOLD','TRUCK_FTL','TRUCK_LTL','COURIER','LAST_MILE','INTL')),
  carrier_company_id  bigint NOT NULL REFERENCES iam.company(id),
  trip_id             bigint REFERENCES ops.trip(id),
  load_id             bigint REFERENCES ship.load(id),
  courier_route_id    bigint REFERENCES ship.courier_route(id),
  from_station_id     bigint REFERENCES net.station(id),
  to_station_id       bigint REFERENCES net.station(id),
  from_seq            smallint,                                       -- BUS_HOLD: segment of the trip
  to_seq              smallint,
  price               bigint CHECK (price >= 0),
  currency            char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  status              text NOT NULL DEFAULT 'PLANNED' CHECK (status IN ('PLANNED','BOOKED','IN_TRANSIT','HANDED_OVER','COMPLETED','CANCELLED')),
  created_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (shipment_id, seq),
  CHECK (num_nonnulls(trip_id, load_id, courier_route_id) <= 1),
  CHECK (to_seq IS NULL OR to_seq > from_seq)
);
COMMENT ON TABLE ship.shipment_leg IS 'One leg per mode and carrier; generalizes cargo_assignment (9.4) and the freight leg (10.9)';

CREATE TABLE IF NOT EXISTS ship.capacity_booking (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  load_id           bigint REFERENCES ship.load(id),
  trip_id           bigint REFERENCES ops.trip(id),
  route_id          bigint REFERENCES net.route(id),                  -- standing allotment on a route
  seller_company_id bigint NOT NULL REFERENCES iam.company(id),
  buyer_company_id  bigint NOT NULL REFERENCES iam.company(id),
  reserved_weight_kg numeric(10,2) NOT NULL CHECK (reserved_weight_kg > 0),
  reserved_volume_m3 numeric(8,2),
  positions         smallint,
  rate              bigint NOT NULL CHECK (rate >= 0),
  currency          char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  status            text NOT NULL DEFAULT 'REQUESTED' CHECK (status IN ('REQUESTED','CONFIRMED','USED','RELEASED','CANCELLED')),
  created_at        timestamptz NOT NULL DEFAULT now(),
  CHECK (num_nonnulls(load_id, trip_id, route_id) = 1),
  CHECK (seller_company_id <> buyer_company_id)
);
COMMENT ON TABLE ship.capacity_booking IS 'B2B capacity bought on a load, trip or route by a courier company; generalizes cargo_booking';

CREATE TABLE IF NOT EXISTS ship.tracking_event (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  shipment_id   bigint REFERENCES ship.shipment(id),
  unit_id       bigint REFERENCES ship.handling_unit(id),
  load_id       bigint REFERENCES ship.load(id),
  leg_id        bigint REFERENCES ship.shipment_leg(id),
  milestone     text NOT NULL CHECK (milestone IN ('CREATED','PICKED_UP','RECEIVED_AT_HUB','SORTED','LOADED','DEPARTED','ARRIVED',
                  'UNLOADED','HANDED_OVER','OUT_FOR_DELIVERY','DELIVERY_ATTEMPTED','DELIVERED','HELD','CUSTOMS','EXCEPTION','RETURNED')),
  reason_code   text,
  station_id    bigint REFERENCES net.station(id),
  actor_user_id bigint REFERENCES iam.app_user(id),
  device_id     bigint REFERENCES iam.device(id),
  lat           numeric(9,6),
  lng           numeric(9,6),
  ts            timestamptz NOT NULL DEFAULT now(),
  CHECK (num_nonnulls(shipment_id, unit_id, load_id) >= 1)
);
CREATE INDEX IF NOT EXISTS tracking_event_shipment_idx ON ship.tracking_event (shipment_id, ts);
COMMENT ON TABLE ship.tracking_event IS 'Scans and milestones of a shipment, unit or load; append-only (generalizes shipment_event)';

CREATE TABLE IF NOT EXISTS ship.custody_transfer (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  shipment_id       bigint REFERENCES ship.shipment(id),
  unit_id           bigint REFERENCES ship.handling_unit(id),
  from_party_id     bigint NOT NULL REFERENCES iam.party(id),
  to_party_id       bigint NOT NULL REFERENCES iam.party(id),
  method            text NOT NULL CHECK (method IN ('SCAN','SIGNATURE','OTP','SEAL_CHECK')),
  signature_file_id bigint REFERENCES ref.file_object(id),
  ts                timestamptz NOT NULL DEFAULT now(),
  CHECK ((shipment_id IS NULL) <> (unit_id IS NULL)),
  CHECK (from_party_id <> to_party_id)
);
COMMENT ON TABLE ship.custody_transfer IS 'Chain of custody between carriers, couriers and points; append-only';

-- ------------------------------ delivery (9.4, 9.21) ------------------------------
CREATE TABLE IF NOT EXISTS ship.delivery_attempt (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  shipment_id     bigint NOT NULL REFERENCES ship.shipment(id),
  attempt_no      smallint NOT NULL CHECK (attempt_no >= 1),
  courier_user_id bigint REFERENCES iam.app_user(id),
  result          text NOT NULL CHECK (result IN ('DELIVERED','FAILED')),
  reason_code     text,
  responsible     text CHECK (responsible IN ('CUSTOMER','NETWORK')),
  lat             numeric(9,6),
  lng             numeric(9,6),
  ts              timestamptz NOT NULL DEFAULT now(),
  UNIQUE (shipment_id, attempt_no),
  CHECK (result = 'DELIVERED' OR responsible IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS ship.delivery_proof (
  shipment_id     bigint PRIMARY KEY REFERENCES ship.shipment(id),
  attempt_id      bigint REFERENCES ship.delivery_attempt(id),
  method          text NOT NULL CHECK (method IN ('OTP','SIGNATURE','ID','LOCKER_PIN','PHOTO')),
  evidence_file_id bigint REFERENCES ref.file_object(id),
  delivered_to    text NOT NULL,
  ts              timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ship.locker_compartment (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  access_point_id  bigint NOT NULL REFERENCES ship.access_point(id),
  code             text NOT NULL,
  size             text NOT NULL CHECK (size IN ('S','M','L','XL')),
  shipment_id      bigint REFERENCES ship.shipment(id),
  pin_hash         bytea,
  expires_at       timestamptz,
  status           text NOT NULL DEFAULT 'FREE' CHECK (status IN ('FREE','OCCUPIED','RESERVED','OUT_OF_ORDER')),
  UNIQUE (access_point_id, code),
  CHECK (status <> 'OCCUPIED' OR shipment_id IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS ship.delivery_preference (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  shipment_id   bigint REFERENCES ship.shipment(id),
  party_id      bigint REFERENCES iam.party(id),                      -- standing preference of a recipient
  pref_type     text NOT NULL CHECK (pref_type IN ('INSTRUCTION','RESCHEDULE','REDIRECT','HOLD','VACATION','NEIGHBOR','PREPAY_COD')),
  value         jsonb NOT NULL,
  requested_by  bigint REFERENCES iam.app_user(id),
  fee           bigint NOT NULL DEFAULT 0,
  status        text NOT NULL DEFAULT 'REQUESTED' CHECK (status IN ('REQUESTED','APPLIED','REJECTED','EXPIRED')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  CHECK ((shipment_id IS NULL) <> (party_id IS NULL))
);

CREATE TABLE IF NOT EXISTS ship.cod_collection (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  shipment_id    bigint NOT NULL UNIQUE REFERENCES ship.shipment(id),
  amount         bigint NOT NULL CHECK (amount > 0),
  currency       char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  collected_at   timestamptz,
  collected_by   bigint REFERENCES iam.app_user(id),
  ledger_txn_id  bigint REFERENCES fin.ledger_txn(id),
  status         text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','COLLECTED','REMITTED','PAID_OUT','FAILED'))
);
COMMENT ON TABLE ship.cod_collection IS 'Cash on delivery, passed through the ledger to the merchant';

CREATE TABLE IF NOT EXISTS ship.weight_audit (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  parcel_id        bigint NOT NULL REFERENCES ship.parcel(id),
  measured_weight_kg numeric(9,2) NOT NULL,
  measured_dims_cm int[],
  photo_file_id    bigint REFERENCES ref.file_object(id),
  device_id        bigint REFERENCES iam.device(id),
  delta_kg         numeric(9,2) NOT NULL,
  adjustment_amount bigint,
  dispute_status   text NOT NULL DEFAULT 'NONE' CHECK (dispute_status IN ('NONE','OPEN','ACCEPTED','REJECTED')),
  ts               timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ship.guarantee_claim (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  shipment_id        bigint NOT NULL UNIQUE REFERENCES ship.shipment(id),
  committed_at       timestamptz NOT NULL,
  delivered_at       timestamptz,
  eligible           boolean,
  exclusion_reason   text,
  refund_amount      bigint CHECK (refund_amount >= 0),
  ledger_txn_id      bigint REFERENCES fin.ledger_txn(id),
  chargeback_leg_id  bigint REFERENCES ship.shipment_leg(id),          -- the leg whose carrier bears the cost
  status             text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','APPROVED','REJECTED','PAID'))
);

CREATE TABLE IF NOT EXISTS ship.return_authorization (
  id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  original_shipment_id  bigint NOT NULL REFERENCES ship.shipment(id),
  merchant_account_id   bigint REFERENCES ship.shipper_account(id),
  reason                text NOT NULL,
  return_shipment_id    bigint UNIQUE REFERENCES ship.shipment(id),
  status                text NOT NULL DEFAULT 'REQUESTED' CHECK (status IN ('REQUESTED','APPROVED','IN_TRANSIT','RECEIVED','REJECTED')),
  created_at            timestamptz NOT NULL DEFAULT now(),
  CHECK (return_shipment_id IS NULL OR return_shipment_id <> original_shipment_id)
);

CREATE TABLE IF NOT EXISTS ship.cargo_claim (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  shipment_id   bigint NOT NULL REFERENCES ship.shipment(id),
  claim_type    text NOT NULL CHECK (claim_type IN ('DAMAGE','LOSS','DELAY','SHORTAGE')),
  amount        bigint NOT NULL CHECK (amount >= 0),
  currency      char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  liable_leg_id bigint REFERENCES ship.shipment_leg(id),
  case_id       bigint REFERENCES crm.case(id),
  status        text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','UNDER_REVIEW','APPROVED','REJECTED','PAID')),
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ship.carrier_scorecard (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  carrier_company_id  bigint REFERENCES iam.company(id),
  access_point_id     bigint REFERENCES ship.access_point(id),
  period              daterange NOT NULL,
  otd_pct             numeric(5,2),          -- on-time delivery
  fadr_pct            numeric(5,2),          -- first-attempt delivery rate
  scan_pct            numeric(5,2),          -- scan compliance
  damage_pct          numeric(5,2),
  loss_pct            numeric(5,2),
  score               numeric(5,2),
  CHECK ((carrier_company_id IS NULL) <> (access_point_id IS NULL)),
  UNIQUE NULLS NOT DISTINCT (carrier_company_id, access_point_id, period)
);

-- ------------------------------ partner integration (9.25) ------------------------------
CREATE TABLE IF NOT EXISTS ship.integration_partner (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  party_id      bigint NOT NULL UNIQUE REFERENCES iam.party(id),
  api_client_id bigint REFERENCES iam.api_client(id),
  partner_type  text NOT NULL CHECK (partner_type IN ('GLOBAL_CARRIER','LOCAL_COURIER','MERCHANT','CARRIER','ACCESS_POINT')),
  name          text NOT NULL,
  protocol      text NOT NULL DEFAULT 'REST' CHECK (protocol IN ('REST','EDI','SFTP')),
  status        text NOT NULL DEFAULT 'SANDBOX' CHECK (status IN ('SANDBOX','ACTIVE','SUSPENDED','ENDED'))
);
COMMENT ON TABLE ship.integration_partner IS 'Global and local partners connected by configuration, not custom development (9.25)';

CREATE TABLE IF NOT EXISTS ship.partner_contract (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  partner_id    bigint NOT NULL REFERENCES ship.integration_partner(id),
  roles         text[] NOT NULL CHECK (roles <@ ARRAY['INBOUND_AGENT','OUTBOUND_AGENT','CUSTOMS_ON_BEHALF','VALUE_ADDED','CAPACITY']),
  services      text[] NOT NULL DEFAULT '{}',
  territory     text[] NOT NULL DEFAULT '{SY}',
  exclusive     boolean NOT NULL DEFAULT false,
  sla           jsonb NOT NULL DEFAULT '{}',
  fees          jsonb NOT NULL DEFAULT '{}',
  liability_cap bigint,
  currency      char(3) NOT NULL DEFAULT 'USD' REFERENCES ref.currency(code),
  valid         daterange NOT NULL,
  status        text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','ACTIVE','ENDED'))
);

CREATE TABLE IF NOT EXISTS ship.shipment_reference (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  shipment_id        bigint NOT NULL REFERENCES ship.shipment(id) ON DELETE CASCADE,
  parcel_id          bigint REFERENCES ship.parcel(id),
  ref_type           text NOT NULL CHECK (ref_type IN ('PARTNER_TRACKING','COURIER_TRACKING','MAWB','HAWB','MERCHANT_ORDER','CUSTOMS_DECL','PARTNER_PIECE')),
  issuer_party_id    bigint NOT NULL REFERENCES iam.party(id),
  value              text NOT NULL,
  normalized_value   text NOT NULL,
  pushed_to_issuer_at timestamptz,
  UNIQUE (issuer_party_id, ref_type, normalized_value)
);
CREATE INDEX IF NOT EXISTS shipment_reference_value_idx ON ship.shipment_reference (normalized_value);

CREATE TABLE IF NOT EXISTS ship.partner_status_map (
  partner_id       bigint NOT NULL REFERENCES ship.integration_partner(id),
  direction        text NOT NULL CHECK (direction IN ('IN','OUT')),
  external_code    text NOT NULL,
  external_reason  text NOT NULL DEFAULT '',
  milestone        text NOT NULL,
  reason_code      text,
  version          int NOT NULL DEFAULT 1,
  PRIMARY KEY (partner_id, direction, external_code, external_reason, version)
);

CREATE TABLE IF NOT EXISTS ship.partner_pre_alert (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  partner_id          bigint NOT NULL REFERENCES ship.integration_partner(id),
  manifest_no         text NOT NULL,
  flight_or_trip_ref  text,
  expected_at         timestamptz,
  item_count          int NOT NULL CHECK (item_count >= 0),
  status              text NOT NULL DEFAULT 'RECEIVED' CHECK (status IN ('RECEIVED','PROCESSED','PARTIAL','CLOSED')),
  UNIQUE (partner_id, manifest_no)
);
COMMENT ON TABLE ship.partner_pre_alert IS 'Incoming manifest that creates shipments with status EXPECTED';

CREATE TABLE IF NOT EXISTS ship.partner_command (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  partner_id       bigint NOT NULL REFERENCES ship.integration_partner(id),
  shipment_id      bigint NOT NULL REFERENCES ship.shipment(id),
  command_type     text NOT NULL CHECK (command_type IN ('UPDATE_ADDRESS','HOLD','REDIRECT','CANCEL','RESCHEDULE','RTS','POD_REQUEST')),
  payload_file_id  bigint REFERENCES ref.file_object(id),
  idempotency_key  text NOT NULL,
  status           text NOT NULL DEFAULT 'RECEIVED' CHECK (status IN ('RECEIVED','APPLIED','REJECTED')),
  applied_at       timestamptz,
  UNIQUE (partner_id, idempotency_key)
);

CREATE TABLE IF NOT EXISTS ship.integration_message (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  partner_id       bigint NOT NULL REFERENCES ship.integration_partner(id),
  direction        text NOT NULL CHECK (direction IN ('IN','OUT')),
  message_type     text NOT NULL,
  shipment_id      bigint REFERENCES ship.shipment(id),
  sequence_no      bigint,
  idempotency_key  text NOT NULL,
  payload_file_id  bigint REFERENCES ref.file_object(id),
  status           text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','SENT','PROCESSED','FAILED','DEAD_LETTER')),
  attempts         int NOT NULL DEFAULT 0,
  next_retry_at    timestamptz,
  error_code       text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (partner_id, direction, idempotency_key)
);
COMMENT ON TABLE ship.integration_message IS 'Outbox, inbox and dead-letter queue of partner messages';

CREATE TABLE IF NOT EXISTS ship.partner_reconciliation (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  partner_id          bigint NOT NULL REFERENCES ship.integration_partner(id),
  recon_date          date NOT NULL,
  matched             int NOT NULL DEFAULT 0,
  missing_in_platform int NOT NULL DEFAULT 0,
  missing_in_partner  int NOT NULL DEFAULT 0,
  amount_diff         bigint NOT NULL DEFAULT 0,
  status              text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','MATCHED','DISCREPANCY','RESOLVED')),
  UNIQUE (partner_id, recon_date)
);

CREATE TABLE IF NOT EXISTS ship.partner_settlement (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  partner_id           bigint NOT NULL REFERENCES ship.integration_partner(id),
  period               daterange NOT NULL,
  service_fees         bigint NOT NULL DEFAULT 0,
  collected_on_behalf  bigint NOT NULL DEFAULT 0,
  claims               bigint NOT NULL DEFAULT 0,
  net_amount           bigint NOT NULL DEFAULT 0,
  currency             char(3) NOT NULL DEFAULT 'USD' REFERENCES ref.currency(code),
  fx_rate              numeric(18,8),
  ledger_txn_id        bigint REFERENCES fin.ledger_txn(id),
  status               text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','APPROVED','PAID')),
  EXCLUDE USING gist (partner_id WITH =, period WITH &&)
);

-- ------------------------------ isolation and privileges ------------------------------
-- A carrier sees a shipment it accepted or one of whose legs it carries; the shipper sees its own.
-- SECURITY DEFINER keeps the lookup out of the leg policy (no recursion between the two tables).
CREATE OR REPLACE FUNCTION ship.can_see_shipment(p_shipment_id bigint) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT sys.ctx_is_platform()
      OR EXISTS (SELECT 1 FROM ship.shipment s WHERE s.id = p_shipment_id
                 AND (s.company_id = sys.ctx_company_id() OR s.shipper_party_id = sys.ctx_party_id()))
      OR EXISTS (SELECT 1 FROM ship.shipment_leg l WHERE l.shipment_id = p_shipment_id AND l.carrier_company_id = sys.ctx_company_id())
$$;
CREATE OR REPLACE FUNCTION ship.is_partner_user(p_partner_id bigint) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT sys.ctx_is_platform()
      OR EXISTS (SELECT 1 FROM ship.integration_partner p WHERE p.id = p_partner_id AND p.api_client_id = sys.ctx_api_client_id())
$$;
DO $$ BEGIN
  PERFORM sys.rls_catalog(t) FROM unnest(ARRAY['ship.surcharge_definition','ship.service_product','ship.service_option',
    'ship.geo_zone','ship.pricing_zone_chart','ship.transit_time_matrix','ship.fuel_surcharge_index','ship.prohibited_item',
    'ship.access_point','ship.locker_compartment','ship.sort_window']) t;
  PERFORM sys.rls_split(t, 'true', 'CASE WHEN company_id IS NULL THEN sys.ctx_is_platform() ELSE sys.tenant_visible(company_id) END')
    FROM unnest(ARRAY['ship.hub','ship.rate_table','ship.routing_rule']) t;
  PERFORM sys.rls_parent('ship.rate_table_entry', 'rate_table_id', 'ship.rate_table');
  PERFORM sys.rls_split('ship.cargo_rate_card', 'true', 'sys.tenant_visible(company_id)');
  PERFORM sys.rls_split('ship.linehaul_schedule', 'true', 'sys.tenant_visible(carrier_company_id)');
  -- addresses are read by their owner or through a shipment or pickup the reader can see; companies may create them
  PERFORM sys.rls('ship.address', 'sys.ctx_is_platform() OR party_id = sys.ctx_party_id()
    OR EXISTS (SELECT 1 FROM ship.shipment s WHERE address.id IN (s.origin_address_id, s.dest_address_id))
    OR EXISTS (SELECT 1 FROM ship.pickup_request r WHERE r.address_id = address.id)',
    'sys.ctx_is_platform() OR party_id = sys.ctx_party_id() OR sys.ctx_company_id() IS NOT NULL');
  PERFORM sys.rls('ship.shipper_account', 'sys.tenant_visible(company_id) OR party_id = sys.ctx_party_id()');
  PERFORM sys.rls('ship.pricing_agreement', 'sys.tenant_visible(company_id)');
  PERFORM sys.rls('ship.shipment', 'ship.can_see_shipment(id)', 'sys.tenant_visible(company_id) OR shipper_party_id = sys.ctx_party_id()');
  PERFORM sys.rls(t, 'ship.can_see_shipment(shipment_id)') FROM unnest(ARRAY['ship.shipment_party','ship.shipment_option','ship.parcel',
    'ship.delivery_attempt','ship.delivery_proof','ship.cod_collection','ship.guarantee_claim','ship.cargo_claim','ship.shipment_reference']) t;
  PERFORM sys.rls('ship.shipment_leg', 'sys.tenant_visible(carrier_company_id) OR ship.can_see_shipment(shipment_id)');
  PERFORM sys.rls('ship.delivery_preference', 'party_id = sys.ctx_party_id() OR ship.can_see_shipment(shipment_id)');
  PERFORM sys.rls('ship.return_authorization', 'ship.can_see_shipment(original_shipment_id)');
  PERFORM sys.rls('ship.weight_audit', 'EXISTS (SELECT 1 FROM ship.parcel p WHERE p.id = parcel_id)');
  PERFORM sys.rls_tenant(t) FROM unnest(ARRAY['ship.handling_unit','ship.load','ship.courier_route','ship.pickup_request']) t;
  PERFORM sys.rls_parent('ship.handling_unit_item', 'unit_id', 'ship.handling_unit');
  PERFORM sys.rls_parent(t, 'load_id', 'ship.load') FROM unnest(ARRAY['ship.load_stop','ship.load_plan']) t;
  PERFORM sys.rls_trip('ship.trip_cargo_capacity');
  PERFORM sys.rls_parent('ship.courier_assignment', 'courier_route_id', 'ship.courier_route');
  PERFORM sys.rls('ship.capacity_booking', 'sys.tenant_visible(seller_company_id) OR sys.tenant_visible(buyer_company_id)');
  PERFORM sys.rls('ship.tracking_event', 'ship.can_see_shipment(shipment_id)
    OR EXISTS (SELECT 1 FROM ship.handling_unit u WHERE u.id = unit_id)
    OR EXISTS (SELECT 1 FROM ship.load l WHERE l.id = load_id)');
  PERFORM sys.rls('ship.custody_transfer', 'ship.can_see_shipment(shipment_id) OR EXISTS (SELECT 1 FROM ship.handling_unit u WHERE u.id = unit_id)');
  PERFORM sys.rls('ship.carrier_scorecard', 'sys.ctx_is_platform() OR carrier_company_id = sys.ctx_company_id()', 'sys.ctx_is_platform()');
  PERFORM sys.rls_platform('ship.integration_partner');
  PERFORM sys.rls(t, 'ship.is_partner_user(partner_id)') FROM unnest(ARRAY['ship.partner_contract','ship.partner_status_map',
    'ship.partner_pre_alert','ship.partner_command','ship.integration_message','ship.partner_reconciliation','ship.partner_settlement']) t;
  PERFORM sys.grant_rw(ARRAY['ship.surcharge_definition','ship.service_product','ship.service_option','ship.hub','ship.geo_zone',
    'ship.pricing_zone_chart','ship.transit_time_matrix','ship.rate_table','ship.rate_table_entry','ship.fuel_surcharge_index',
    'ship.cargo_rate_card','ship.prohibited_item','ship.address','ship.pricing_agreement','ship.shipper_account','ship.access_point',
    'ship.shipment','ship.shipment_party','ship.shipment_option','ship.parcel','ship.handling_unit','ship.handling_unit_item',
    'ship.load','ship.load_stop','ship.load_plan','ship.trip_cargo_capacity','ship.courier_route','ship.pickup_request',
    'ship.courier_assignment','ship.routing_rule','ship.linehaul_schedule','ship.sort_window','ship.shipment_leg',
    'ship.capacity_booking','ship.delivery_proof','ship.locker_compartment','ship.delivery_preference','ship.cod_collection',
    'ship.weight_audit','ship.guarantee_claim','ship.return_authorization','ship.cargo_claim','ship.carrier_scorecard',
    'ship.integration_partner','ship.partner_contract','ship.shipment_reference','ship.partner_status_map','ship.partner_pre_alert',
    'ship.partner_command','ship.integration_message','ship.partner_reconciliation','ship.partner_settlement']);
  PERFORM sys.grant_append(ARRAY['ship.tracking_event','ship.custody_transfer','ship.delivery_attempt']);
  PERFORM sys.track_updates('ship.shipment');
END $$;
