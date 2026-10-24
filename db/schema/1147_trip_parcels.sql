-- =====================================================================
-- 1147: parcels on scheduled trips (owner's decision N5, October 2026)
--   Parcels ride in the hold of a carrier's scheduled trips, as a service of the carriers that run them; this is not
--   the courier business, whose module (cargo) stays switched off. Its own switch, trip_parcels, opens it.
--   * The platform's policy (parcels.policy): which kinds of carrier may offer parcels, whether only scheduled trips
--     (those of a regular trip, ops.trip.template_id) take them, the shortest hand-over time a carrier may set, the
--     items no parcel may carry (from the laws in force), and who decides the cancellation and no-show fees: the
--     carrier now, the platform once a law regulates them ("PLATFORM": a carrier's new fees wait for its approval).
--     The platform may also stop one carrier's parcels, with a reason.
--   * Each carrier's choices (ship.parcel_carrier): how its parcels are booked - online and handed over at one of
--     its points, or at its counter only - how long before departure an online reservation must be handed over, and
--     its fees. Its weights and sizes are those of its tariffs (1078).
--   * Its drop-off points (ship.parcel_point): its stations and its offices, with address and opening hours.
--   * In phase one (N13) an online reservation takes the hold space without payment; the sender pays at the counter
--     when handing the parcel over. One not handed over by its time is released by the worker and its space freed.
-- =====================================================================

-- ------------------------------------------------------------------ the switch and the platform's policy
UPDATE sys.setting SET value = '{"trip_parcels": false}'::jsonb || value
 WHERE key = 'features' AND NOT (value ? 'trip_parcels');

INSERT INTO sys.setting (key, value, description) VALUES
  ('parcels.policy', jsonb_build_object(
      'carrier_types', jsonb_build_array('CARRIER', 'INDIVIDUAL_OPERATOR'),
      'scheduled_only', true,
      'min_handover_minutes', 60,
      'fee_policy', 'CARRIER',
      'prohibited', jsonb_build_array('WEAPONS', 'EXPLOSIVES', 'FLAMMABLE', 'DRUGS', 'CASH_AND_VALUABLES', 'LIVE_ANIMALS',
                                      'PERISHABLE_FOOD', 'HAZARDOUS_CHEMICALS')),
   'Parcels on trips: carriers allowed by type, scheduled trips only, shortest hand-over time, prohibited items, who decides the fees (1147)')
ON CONFLICT (key) DO NOTHING;

-- ------------------------------------------------------------------ each carrier's choices
CREATE TABLE IF NOT EXISTS ship.parcel_carrier (
  company_id          bigint PRIMARY KEY REFERENCES iam.company(id),
  booking_mode        text NOT NULL DEFAULT 'ONLINE_DROPOFF' CHECK (booking_mode IN ('ONLINE_DROPOFF','COUNTER_ONLY')),
  handover_minutes    integer NOT NULL DEFAULT 120 CHECK (handover_minutes BETWEEN 15 AND 2880),
  cancel_fee          bigint NOT NULL DEFAULT 0 CHECK (cancel_fee >= 0),
  no_show_fee         bigint NOT NULL DEFAULT 0 CHECK (no_show_fee >= 0),
  pending_fees        jsonb CHECK (pending_fees IS NULL OR jsonb_typeof(pending_fees) = 'object'),
  fees_decision       text,
  stopped             boolean NOT NULL DEFAULT false,
  stopped_reason      text,
  updated_by          bigint REFERENCES iam.app_user(id),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CHECK (NOT stopped OR length(btrim(stopped_reason)) >= 5)
);
CREATE INDEX IF NOT EXISTS parcel_carrier_updated_by_fkx ON ship.parcel_carrier (updated_by);
COMMENT ON TABLE ship.parcel_carrier IS
  'A carrier''s parcel choices: online with drop-off or counter only, the hand-over time before departure, its fees; stopped by the platform with a reason (N5, 1147)';
ALTER TABLE ship.parcel_carrier ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS readable ON ship.parcel_carrier;
CREATE POLICY readable ON ship.parcel_carrier FOR SELECT USING (true);
DROP POLICY IF EXISTS own_or_platform_writes ON ship.parcel_carrier;
CREATE POLICY own_or_platform_writes ON ship.parcel_carrier FOR INSERT WITH CHECK (sys.ctx_is_platform() OR sys.tenant_visible(company_id));
DROP POLICY IF EXISTS own_or_platform_updates ON ship.parcel_carrier;
CREATE POLICY own_or_platform_updates ON ship.parcel_carrier FOR UPDATE
  USING (sys.ctx_is_platform() OR sys.tenant_visible(company_id)) WITH CHECK (sys.ctx_is_platform() OR sys.tenant_visible(company_id));
GRANT SELECT, INSERT, UPDATE ON ship.parcel_carrier TO masslak_app;
GRANT SELECT ON ship.parcel_carrier TO masslak_readonly, masslak_auditor;

-- a carrier does not lift its own stop
CREATE OR REPLACE FUNCTION ship.tg_parcel_carrier_stop() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF sys.ctx_is_platform() THEN
    RETURN NEW;
  END IF;
  IF (TG_OP = 'INSERT' AND (NEW.stopped OR NEW.stopped_reason IS NOT NULL OR NEW.fees_decision IS NOT NULL))
     OR (TG_OP = 'UPDATE' AND (NEW.stopped IS DISTINCT FROM OLD.stopped OR NEW.stopped_reason IS DISTINCT FROM OLD.stopped_reason
                               OR NEW.fees_decision IS DISTINCT FROM OLD.fees_decision)) THEN
    RAISE EXCEPTION 'FORBIDDEN: only the platform stops or resumes a carrier''s parcels and decides its fees' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS b_parcel_carrier_stop ON ship.parcel_carrier;
CREATE TRIGGER b_parcel_carrier_stop BEFORE INSERT OR UPDATE ON ship.parcel_carrier
  FOR EACH ROW EXECUTE FUNCTION ship.tg_parcel_carrier_stop();

-- ------------------------------------------------------------------ drop-off points
CREATE TABLE IF NOT EXISTS ship.parcel_point (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid         uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  company_id  bigint NOT NULL REFERENCES iam.company(id),
  kind        text NOT NULL CHECK (kind IN ('STATION','OFFICE')),
  station_id  bigint REFERENCES net.station(id),
  name        text NOT NULL CHECK (length(btrim(name)) BETWEEN 2 AND 120),
  address     text NOT NULL CHECK (length(btrim(address)) BETWEEN 3 AND 300),
  hours       text NOT NULL CHECK (length(btrim(hours)) BETWEEN 2 AND 200),
  phone       text CHECK (phone IS NULL OR phone ~ '^\+?[0-9]{6,15}$'),
  status      text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','CLOSED')),
  created_by  bigint NOT NULL REFERENCES iam.app_user(id),
  created_at  timestamptz NOT NULL DEFAULT now(),
  CHECK ((kind = 'STATION') = (station_id IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS parcel_point_company_idx ON ship.parcel_point (company_id, status);
CREATE INDEX IF NOT EXISTS parcel_point_station_id_fkx ON ship.parcel_point (station_id);
CREATE INDEX IF NOT EXISTS parcel_point_created_by_fkx ON ship.parcel_point (created_by);
COMMENT ON TABLE ship.parcel_point IS 'Where a carrier receives parcels: its stations and offices, with address and opening hours (N5, 1147)';
SELECT sys.rls_split('ship.parcel_point', 'status = ''ACTIVE'' OR sys.tenant_visible(company_id)', 'sys.tenant_visible(company_id)');
GRANT SELECT, INSERT, UPDATE ON ship.parcel_point TO masslak_app;
GRANT SELECT ON ship.parcel_point TO masslak_readonly, masslak_auditor;

-- ------------------------------------------------------------------ hand-over and payment of a parcel
ALTER TABLE ship.shipment ADD COLUMN IF NOT EXISTS handover_by timestamptz;
ALTER TABLE ship.shipment ADD COLUMN IF NOT EXISTS drop_point_id bigint REFERENCES ship.parcel_point(id);
ALTER TABLE ship.shipment ADD COLUMN IF NOT EXISTS handed_over_at timestamptz;
ALTER TABLE ship.shipment ADD COLUMN IF NOT EXISTS handed_over_by bigint REFERENCES iam.app_user(id);
ALTER TABLE ship.shipment ADD COLUMN IF NOT EXISTS paid_at timestamptz;
ALTER TABLE ship.shipment ADD COLUMN IF NOT EXISTS pay_method text CHECK (pay_method IS NULL OR pay_method IN ('WALLET','CASH'));
ALTER TABLE ship.shipment ADD COLUMN IF NOT EXISTS sold_at_counter boolean NOT NULL DEFAULT false;
ALTER TABLE ship.shipment ADD COLUMN IF NOT EXISTS sender_name text CHECK (sender_name IS NULL OR length(btrim(sender_name)) BETWEEN 3 AND 120);
ALTER TABLE ship.shipment ADD COLUMN IF NOT EXISTS release_reason text CHECK (release_reason IS NULL OR release_reason IN ('NOT_HANDED_OVER','CANCELLED_BY_SENDER','CANCELLED_BY_CARRIER'));
CREATE INDEX IF NOT EXISTS shipment_drop_point_id_fkx ON ship.shipment (drop_point_id);
CREATE INDEX IF NOT EXISTS shipment_handed_over_by_fkx ON ship.shipment (handed_over_by);
CREATE INDEX IF NOT EXISTS shipment_awaiting_handover_idx ON ship.shipment (handover_by) WHERE status = 'EXPECTED';
COMMENT ON COLUMN ship.shipment.handover_by IS 'When an online parcel reservation must be handed over at the carrier''s point; released after (1147)';
COMMENT ON COLUMN ship.shipment.paid_at IS 'When the parcel was paid: online from the wallet, or in cash at the counter when handed over (1147)';

-- a parcel not handed over in time gives its hold space back
CREATE OR REPLACE FUNCTION ship.release_unhanded_parcels() RETURNS integer LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE n integer;
BEGIN
  WITH due AS (
    UPDATE ship.shipment SET status = 'CANCELLED', release_reason = 'NOT_HANDED_OVER', updated_at = now()
     WHERE status = 'EXPECTED' AND handover_by < now() AND paid_at IS NULL
    RETURNING id, tracking_no, company_id, shipper_party_id)
  , legs AS (
    UPDATE ship.shipment_leg l SET status = 'CANCELLED' FROM due WHERE l.shipment_id = due.id AND l.status <> 'CANCELLED')
  INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, company_id, payload)
  SELECT 'parcel.released', 'shipment', due.id, due.company_id,
         jsonb_build_object('tracking_no', due.tracking_no, 'reason', 'NOT_HANDED_OVER', 'shipper_party_id', due.shipper_party_id)
    FROM due;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION ship.release_unhanded_parcels() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ship.release_unhanded_parcels() TO masslak_app;
COMMENT ON FUNCTION ship.release_unhanded_parcels IS 'Online parcel reservations not handed over by their time are released and their hold freed (worker, 1147)';

-- ------------------------------------------------------------------ the counter's permission
INSERT INTO iam.permission (code, module, scope, description, is_sensitive) VALUES
  ('parcels.counter', 'ship', 'COMPANY', 'Sell parcels at the counter and receive the parcels booked online', false)
ON CONFLICT (code) DO NOTHING;
INSERT INTO iam.role_permission (role_id, permission_code)
SELECT r.id, 'parcels.counter' FROM iam.role r WHERE r.code IN ('CARRIER_OPERATIONS','CARRIER_COUNTER') AND r.company_id IS NULL
ON CONFLICT DO NOTHING;

-- ------------------------------------------------------------------ the database gate of the parcel tables
-- the shipping schema opens with the courier module (cargo, 1039); the tables parcels on trips use open with either switch,
-- and the courier's own tables (hubs, lockers, linehauls...) stay behind cargo alone
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['ship.parcel_tariff', 'ship.parcel_offer', 'ship.parcel_carrier', 'ship.parcel_point', 'ship.shipment',
                           'ship.parcel', 'ship.shipment_leg', 'ship.tracking_event', 'ship.trip_cargo_capacity', 'ship.service_product'] LOOP
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS module_gate ON %s', t);
    EXECUTE format('CREATE POLICY module_gate ON %s AS RESTRICTIVE FOR ALL USING (sys.ctx_is_platform() OR sys.feature_on(%L)) '
                   'WITH CHECK (sys.ctx_is_platform() OR sys.feature_on(%L))', t, '{cargo,trip_parcels}', '{cargo,trip_parcels}');
  END LOOP;
END $$;

-- ------------------------------------------------------------------ registrations
INSERT INTO sys.json_contract (table_name, column_name, kind, version, spec, note) VALUES
  ('ship.parcel_carrier', 'pending_fees', 'CONFIG', 1, '{"type": "object"}'::jsonb,
   'fees a carrier set while the platform regulates them, waiting for its decision (1147)')
ON CONFLICT DO NOTHING;
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('ship.parcel_carrier', '3', 'E28'), ('ship.parcel_point', '3', 'E28')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
SELECT sys.refresh_table_class();
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('ship.parcel_carrier', 'ship records', 'a carrier''s parcel choices and fees (1147)'),
  ('ship.parcel_point', 'ship records', 'where carriers receive parcels (1147)')
ON CONFLICT (table_name) DO NOTHING;
