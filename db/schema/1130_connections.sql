-- =====================================================================
-- 1130  Connections across carriers, and a booking changed to another trip (owner's request, October 2026)
-- =====================================================================
-- Where no trip runs from one city to another (Daraa to Aleppo), the platform offers a connection: a trip to a city on
-- the way (Damascus, Homs) and another trip from there, of the same carrier or another, leaving a while after the
-- first arrives. Both are booked together as one journey of kind CONNECTION; each trip stays a booking of its own
-- carrier, with that carrier's rules. The traveller accepts the risks first (sales.booking.risk_ack_at): each carrier
-- is responsible for its own trip only, and a late first trip does not hold the second.
-- The platform sets how long a change may take (journey.connections.min_minutes at the same station,
-- min_minutes_station_change between two stations of a city, max_minutes) and whether every trip after the first must
-- be changeable (journey.connections.require_flexible): booked with a fare that may be changed, or with a carrier that
-- changes it free when the first trip was late.
-- Each carrier decides (ops.carrier_connection_policy) whether its trips are offered in connections and what it does
-- when a traveller misses its trip: FREE_CHANGE (a free change to another of its trips when the first trip of the
-- connection arrived late), FARE_RULES (a change under the fare's rules, its fee), or NONE (the ticket is lost), and for
-- how many hours after the departure a change is accepted.
-- A booking changed to another trip of the same carrier between the same cities is a new booking paid with the old
-- one: the old is cancelled with its value back less the change fee, and the new paid from the same wallet in the
-- same transaction (sales.booking_change keeps both, the reason and the fee).

-- ------------------------------------------------------------------ the platform's settings
INSERT INTO sys.setting (key, value, scope, description) VALUES
  ('journey.connections.enabled', 'true'::jsonb, 'PLATFORM', 'Whether search offers connections across carriers where no direct trip runs (1130)'),
  ('journey.connections.min_minutes', '30'::jsonb, 'PLATFORM', 'Minutes at least between the arrival of one trip and the departure of the next at the same station (1130)'),
  ('journey.connections.min_minutes_station_change', '60'::jsonb, 'PLATFORM', 'Minutes at least when the next trip leaves from another station of the same city (1130)'),
  ('journey.connections.max_minutes', '240'::jsonb, 'PLATFORM', 'Minutes at most between two trips of a connection (1130)'),
  ('journey.connections.require_flexible', 'true'::jsonb, 'PLATFORM', 'Whether every trip after the first of a connection must be changeable: a changeable fare, or a carrier that changes it free after a late first trip (1130)')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION sales.setting_bool(p_key text, p_default boolean) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce((SELECT (value #>> '{}')::boolean FROM sys.setting WHERE key = p_key AND jsonb_typeof(value) = 'boolean'), p_default)
$$;

CREATE OR REPLACE FUNCTION sales.connection_settings() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT jsonb_build_object(
    'enabled', sales.setting_bool('journey.connections.enabled', true),
    'min_minutes', sales.setting_int('journey.connections.min_minutes', 30),
    'min_minutes_station_change', sales.setting_int('journey.connections.min_minutes_station_change', 60),
    'max_minutes', sales.setting_int('journey.connections.max_minutes', 240),
    'require_flexible', sales.setting_bool('journey.connections.require_flexible', true))
$$;

CREATE OR REPLACE FUNCTION sales.set_connection_settings(p_enabled boolean, p_min int, p_min_change int, p_max int, p_require_flexible boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: the connection settings are the platform''s' USING ERRCODE = 'P0001';
  END IF;
  IF p_enabled IS NULL OR p_require_flexible IS NULL OR p_min IS NULL OR p_min NOT BETWEEN 10 AND 240
     OR p_min_change IS NULL OR p_min_change NOT BETWEEN p_min AND 360 OR p_max IS NULL OR p_max NOT BETWEEN p_min_change AND 720 THEN
    RAISE EXCEPTION 'INVALID_SETTING: a change takes 10 to 240 minutes at the same station, at least as long between two stations (up to 360), and at most 720 minutes in all' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO sys.setting (key, value, scope, description, updated_by, updated_at) VALUES
    ('journey.connections.enabled', to_jsonb(p_enabled), 'PLATFORM', 'Whether search offers connections across carriers (1130)', sys.ctx_user_id(), now()),
    ('journey.connections.min_minutes', to_jsonb(p_min), 'PLATFORM', 'Minutes at least between two trips at the same station (1130)', sys.ctx_user_id(), now()),
    ('journey.connections.min_minutes_station_change', to_jsonb(p_min_change), 'PLATFORM', 'Minutes at least between two stations of a city (1130)', sys.ctx_user_id(), now()),
    ('journey.connections.max_minutes', to_jsonb(p_max), 'PLATFORM', 'Minutes at most between two trips of a connection (1130)', sys.ctx_user_id(), now()),
    ('journey.connections.require_flexible', to_jsonb(p_require_flexible), 'PLATFORM', 'Whether every trip after the first must be changeable (1130)', sys.ctx_user_id(), now())
  ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  RETURN sales.connection_settings();
END $$;

-- ------------------------------------------------------------------ each carrier's policy
CREATE TABLE IF NOT EXISTS ops.carrier_connection_policy (
  company_id            bigint PRIMARY KEY REFERENCES iam.company(id),
  offer_in_connections  boolean NOT NULL DEFAULT true,
  missed_connection     text NOT NULL DEFAULT 'FARE_RULES' CHECK (missed_connection IN ('FREE_CHANGE', 'FARE_RULES', 'NONE')),
  change_window_hours   smallint NOT NULL DEFAULT 24 CHECK (change_window_hours BETWEEN 1 AND 168),
  note                  text CHECK (note IS NULL OR length(note) <= 500),
  updated_by            bigint REFERENCES iam.app_user(id),
  updated_at            timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS carrier_connection_policy_updated_by_fkx ON ops.carrier_connection_policy (updated_by);
COMMENT ON TABLE ops.carrier_connection_policy IS 'A carrier''s policy for connections: whether its trips are offered in them, and what it does when a traveller misses its trip (1130)';
COMMENT ON COLUMN ops.carrier_connection_policy.missed_connection IS 'FREE_CHANGE: a free change after a late first trip; FARE_RULES: a change under the fare''s rules; NONE: the ticket is lost';
COMMENT ON COLUMN ops.carrier_connection_policy.change_window_hours IS 'How many hours after the departure of a missed trip a change is accepted';
SELECT sys.rls_split('ops.carrier_connection_policy', 'true', 'sys.tenant_visible(company_id)');
GRANT SELECT, INSERT, UPDATE ON ops.carrier_connection_policy TO masslak_app;
GRANT SELECT ON ops.carrier_connection_policy TO masslak_readonly, masslak_auditor;

-- a carrier's policy, or the defaults where it has set none; public, as the carrier's conditions are
CREATE OR REPLACE FUNCTION ops.connection_policy(p_company_id bigint) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce(
    (SELECT jsonb_build_object('offer_in_connections', p.offer_in_connections, 'missed_connection', p.missed_connection,
                               'change_window_hours', p.change_window_hours, 'note', p.note, 'set', true)
       FROM ops.carrier_connection_policy p WHERE p.company_id = p_company_id),
    jsonb_build_object('offer_in_connections', true, 'missed_connection', 'FARE_RULES', 'change_window_hours', 24, 'note', NULL, 'set', false))
$$;

-- ------------------------------------------------------------------ the bookings of a connection
ALTER TABLE sales.booking ADD COLUMN IF NOT EXISTS risk_ack_at timestamptz;
ALTER TABLE sales.booking ADD COLUMN IF NOT EXISTS changed_from_id bigint REFERENCES sales.booking(id);
CREATE INDEX IF NOT EXISTS booking_changed_from_id_fkx ON sales.booking (changed_from_id) WHERE changed_from_id IS NOT NULL;
COMMENT ON COLUMN sales.booking.risk_ack_at IS 'When the traveller accepted the risks of a connection across trips (1130)';
COMMENT ON COLUMN sales.booking.changed_from_id IS 'The booking this one replaced when the traveller changed to another trip (1130)';
ALTER TABLE sales.booking DROP CONSTRAINT IF EXISTS booking_journey_check;
ALTER TABLE sales.booking ADD CONSTRAINT booking_journey_check CHECK (
  (journey_uid IS NULL AND journey_kind IS NULL AND journey_leg IS NULL)
  OR (journey_uid IS NOT NULL AND journey_kind IS NOT NULL AND journey_leg IS NOT NULL
      AND journey_kind IN ('ONE_WAY', 'ROUND_TRIP', 'MULTI_CITY', 'CONNECTION') AND journey_leg BETWEEN 1 AND 6));
ALTER TABLE sales.booking DROP CONSTRAINT IF EXISTS booking_connection_ack_ck;
ALTER TABLE sales.booking ADD CONSTRAINT booking_connection_ack_ck CHECK (journey_kind IS DISTINCT FROM 'CONNECTION' OR risk_ack_at IS NOT NULL);

-- ------------------------------------------------------------------ a booking changed to another trip
CREATE TABLE IF NOT EXISTS sales.booking_change (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  from_booking_id  bigint NOT NULL REFERENCES sales.booking(id),
  to_booking_id    bigint NOT NULL REFERENCES sales.booking(id),
  reason           text NOT NULL CHECK (reason IN ('MISSED_CONNECTION', 'CUSTOMER')),
  missed           boolean NOT NULL,                  -- the old trip had left without the traveller
  inbound_late     boolean NOT NULL DEFAULT false,    -- the first trip of the connection arrived too late for it
  basis            text NOT NULL CHECK (basis IN ('FREE_CHANGE', 'FARE_RULES')),
  fee              bigint NOT NULL CHECK (fee >= 0),
  refunded         bigint NOT NULL CHECK (refunded >= 0),
  paid             bigint NOT NULL CHECK (paid >= 0),
  currency         char(3) NOT NULL REFERENCES ref.currency(code),
  created_by       bigint REFERENCES iam.app_user(id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT booking_change_once_uq UNIQUE (from_booking_id),
  CONSTRAINT booking_change_free_ck CHECK (basis <> 'FREE_CHANGE' OR fee = 0),
  CONSTRAINT booking_change_two_ck CHECK (from_booking_id <> to_booking_id)
);
CREATE INDEX IF NOT EXISTS booking_change_to_booking_id_fkx ON sales.booking_change (to_booking_id);
CREATE INDEX IF NOT EXISTS booking_change_created_by_fkx ON sales.booking_change (created_by);
COMMENT ON TABLE sales.booking_change IS 'A booking changed to another trip of the same carrier: the old and the new booking, why, on what basis and for what fee (1130)';
SELECT sys.rls_parent('sales.booking_change', 'from_booking_id', 'sales.booking');
GRANT SELECT, INSERT ON sales.booking_change TO masslak_app;
GRANT SELECT ON sales.booking_change TO masslak_readonly, masslak_auditor;

-- whether the traveller of a later trip of a connection missed it because the trip before arrived late
CREATE OR REPLACE FUNCTION sales.missed_connection(p_booking bigint) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  WITH o AS (
    SELECT b.id, b.journey_uid, b.journey_kind, b.journey_leg, b.booker_party_id, ts.sched_dep, ts.actual_dep
      FROM sales.booking b
      JOIN LATERAL (SELECT min(k.from_seq) AS f FROM sales.ticket k WHERE k.booking_id = b.id) k ON true
      JOIN ops.trip_stop ts ON ts.trip_id = b.trip_id AND ts.seq = k.f
     WHERE b.id = p_booking),
  i AS (
    SELECT pt.status AS trip_status, ts.sched_arr, ts.actual_arr
      FROM o JOIN sales.booking pb ON pb.journey_uid = o.journey_uid AND pb.journey_leg = o.journey_leg - 1
                                  AND pb.booker_party_id = o.booker_party_id AND pb.status <> 'EXPIRED'
      JOIN ops.trip pt ON pt.id = pb.trip_id
      JOIN LATERAL (SELECT max(k.to_seq) AS t FROM sales.ticket k WHERE k.booking_id = pb.id) k ON true
      JOIN ops.trip_stop ts ON ts.trip_id = pb.trip_id AND ts.seq = k.t
     WHERE NOT EXISTS (SELECT 1 FROM sales.booking_change c WHERE c.from_booking_id = pb.id)     -- the booking in force
     ORDER BY pb.id DESC LIMIT 1)
  SELECT jsonb_build_object(
    'connection', coalesce(o.journey_kind = 'CONNECTION' AND o.journey_leg > 1 AND i.trip_status IS NOT NULL, false),
    'outbound_departs_at', coalesce(o.actual_dep, o.sched_dep),
    'inbound_due_at', i.sched_arr, 'inbound_arrived_at', i.actual_arr, 'inbound_trip_status', i.trip_status,
    'inbound_late', coalesce(o.journey_kind = 'CONNECTION' AND (i.trip_status = 'CANCELLED'
        OR (i.actual_arr IS NOT NULL AND i.actual_arr > coalesce(o.actual_dep, o.sched_dep)
                                           - make_interval(mins => sales.setting_int('journey.connections.min_minutes', 30)))), false))
    FROM o LEFT JOIN i ON true
$$;

REVOKE ALL ON FUNCTION sales.setting_bool(text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION sales.connection_settings() FROM PUBLIC;
REVOKE ALL ON FUNCTION sales.set_connection_settings(boolean, int, int, int, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.connection_policy(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION sales.missed_connection(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sales.setting_bool(text, boolean) TO masslak_app;
GRANT EXECUTE ON FUNCTION sales.connection_settings() TO masslak_app;
GRANT EXECUTE ON FUNCTION sales.set_connection_settings(boolean, int, int, int, boolean) TO masslak_app;
GRANT EXECUTE ON FUNCTION ops.connection_policy(bigint) TO masslak_app;
GRANT EXECUTE ON FUNCTION sales.missed_connection(bigint) TO masslak_app;
COMMENT ON FUNCTION sales.setting_bool IS 'A platform setting read as a yes or no, with its default (1130)';
COMMENT ON FUNCTION sales.connection_settings IS 'The platform''s connection settings as they stand (1130)';
COMMENT ON FUNCTION sales.set_connection_settings IS 'The platform sets whether connections are offered, how long a change takes and whether later trips must be changeable (1130)';
COMMENT ON FUNCTION ops.connection_policy IS 'A carrier''s connection policy, or the defaults where it has set none (1130)';
COMMENT ON FUNCTION sales.missed_connection IS 'For a later trip of a connection: when the trip before arrived, and whether too late for this one (1130)';

-- ------------------------------------------------------------------ registration
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('ops.carrier_connection_policy', '1A', 'E08'), ('sales.booking_change', '1A', 'E11')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
SELECT sys.refresh_table_class();
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('ops.carrier_connection_policy', 'ops records', 'carriers'' connection policies (1130)'),
  ('sales.booking_change', 'sales records', 'bookings changed to another trip (1130)')
ON CONFLICT (table_name) DO NOTHING;
