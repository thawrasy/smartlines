-- =====================================================================
-- 1067: cargo stays within the capacity of the vehicle that carries it (external technical report of October 2026)
--   Hold capacity offered on a passenger trip (ship.trip_cargo_capacity) and truck loads (ship.load) had a maximum and a
--   CHECK that the used weight stays under it, but nothing kept the used weight up to date: placing shipments on a trip
--   or a load never counted, so the CHECK protected nothing. The maximum was also not tied to the vehicle.
--   Now:
--   * the used weight, volume and pieces are computed from what is placed: the parcels of every shipment leg that is
--     not cancelled, and confirmed capacity bookings. On a trip a leg occupies only the segments it rides, so a parcel
--     unloaded at a stop frees the hold for the next ones;
--   * placing, re-weighing or confirming anything that would exceed a maximum is refused (CARGO_CAPACITY), as is a leg
--     on a trip that offers no hold (CARGO_NOT_OFFERED); taking things off is always allowed;
--   * a maximum may not exceed the capacity registered for the vehicle (fleet.vehicle.cargo_capacity_kg; for a truck its
--     gross weight less its tare, or the payload of the trailer it pulls), nor be lowered under what is already loaded;
--     changing a trip's vehicle, or a vehicle's registered capacity, is held to the same limit (CARGO_OVER_VEHICLE);
--   * the capacity row is locked while a change is checked, so two clerks loading the same trip at once wait for each
--     other instead of both fitting into the last space.
--   The CHECKs on the used weight are replaced by these rules: a row loaded before this file may already be over its
--   maximum, which ship.cargo_overbooked() lists, and only taking cargo off it is then accepted.
-- =====================================================================

-- ------------------------------ what a shipment weighs and measures ------------------------------
CREATE OR REPLACE FUNCTION ship.shipment_size(p_shipment bigint, OUT weight_kg numeric, OUT volume_m3 numeric, OUT pieces int)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  -- parcels as weighed; before they are, the weight the shipment was billed on
  SELECT coalesce(sum(p.weight_kg), max(s.billable_weight_kg), 0),
         coalesce(sum(p.length_cm * p.width_cm * p.height_cm) / 1000000.0, 0),
         count(p.id)::int
    FROM ship.shipment s LEFT JOIN ship.parcel p ON p.shipment_id = s.id
   WHERE s.id = p_shipment
$$;
COMMENT ON FUNCTION ship.shipment_size IS 'Weight, volume and pieces of a shipment from its parcels (the billed weight until they are weighed) (1067)';

-- ------------------------------ what is loaded on a trip's hold and on a load ------------------------------
CREATE OR REPLACE FUNCTION ship.trip_cargo_usage(p_trip bigint, OUT weight_kg numeric, OUT volume_m3 numeric, OUT pieces int)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  WITH legs AS (
    SELECT coalesce(l.from_seq, 0) AS f, coalesce(l.to_seq, t.segments_count) AS e, z.weight_kg, z.volume_m3, z.pieces
      FROM ship.shipment_leg l JOIN ops.trip t ON t.id = l.trip_id
     CROSS JOIN LATERAL ship.shipment_size(l.shipment_id) z
     WHERE l.trip_id = p_trip AND l.status <> 'CANCELLED' AND l.shipment_id IS NOT NULL),
  per_segment AS (
    SELECT coalesce(sum(legs.weight_kg), 0) AS w, coalesce(sum(legs.volume_m3), 0) AS v, coalesce(sum(legs.pieces), 0) AS n
      FROM ops.trip t CROSS JOIN generate_series(0, t.segments_count - 1) g
      LEFT JOIN legs ON legs.f <= g AND g < legs.e
     WHERE t.id = p_trip
     GROUP BY g),
  booked AS (
    SELECT coalesce(sum(reserved_weight_kg), 0) AS w, coalesce(sum(reserved_volume_m3), 0) AS v
      FROM ship.capacity_booking WHERE trip_id = p_trip AND status = 'CONFIRMED')
  SELECT coalesce(max(per_segment.w), 0) + booked.w, coalesce(max(per_segment.v), 0) + booked.v,
         coalesce(max(per_segment.n), 0)::int
    FROM booked LEFT JOIN per_segment ON true
   GROUP BY booked.w, booked.v
$$;
COMMENT ON FUNCTION ship.trip_cargo_usage IS 'Hold use of a trip: the busiest segment of its non-cancelled legs, plus confirmed capacity bookings (1067)';

CREATE OR REPLACE FUNCTION ship.load_usage(p_load bigint, OUT weight_kg numeric, OUT volume_m3 numeric, OUT pieces int)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce((SELECT sum(z.weight_kg) FROM ship.shipment_leg l CROSS JOIN LATERAL ship.shipment_size(l.shipment_id) z
                    WHERE l.load_id = p_load AND l.status <> 'CANCELLED' AND l.shipment_id IS NOT NULL), 0)
       + coalesce((SELECT sum(reserved_weight_kg) FROM ship.capacity_booking WHERE load_id = p_load AND status = 'CONFIRMED'), 0),
         coalesce((SELECT sum(z.volume_m3) FROM ship.shipment_leg l CROSS JOIN LATERAL ship.shipment_size(l.shipment_id) z
                    WHERE l.load_id = p_load AND l.status <> 'CANCELLED' AND l.shipment_id IS NOT NULL), 0)
       + coalesce((SELECT sum(reserved_volume_m3) FROM ship.capacity_booking WHERE load_id = p_load AND status = 'CONFIRMED'), 0),
         coalesce((SELECT sum(z.pieces) FROM ship.shipment_leg l CROSS JOIN LATERAL ship.shipment_size(l.shipment_id) z
                    WHERE l.load_id = p_load AND l.status <> 'CANCELLED' AND l.shipment_id IS NOT NULL), 0)::int
$$;
COMMENT ON FUNCTION ship.load_usage IS 'Use of a truck or hold load: its non-cancelled legs plus confirmed capacity bookings (1067)';

-- ------------------------------ what the vehicle may carry ------------------------------
CREATE OR REPLACE FUNCTION ship.vehicle_payload(p_vehicle bigint, p_combination bigint, OUT weight_kg numeric, OUT volume_m3 numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  -- a coupled truck carries what its trailer is registered for; otherwise the vehicle's registered cargo capacity,
  -- or for a truck its gross vehicle weight less its tare
  SELECT CASE WHEN p_combination IS NOT NULL THEN
                (SELECT coalesce(tr.payload_kg, tu.gvw_kg - tu.tare_kg) FROM fleet.truck_combination c
                   JOIN fleet.truck_unit tu ON tu.vehicle_id = c.truck_vehicle_id
                   LEFT JOIN fleet.trailer tr ON tr.id = c.trailer_id WHERE c.id = p_combination)
              ELSE (SELECT coalesce(nullif(v.cargo_capacity_kg, 0), tu.gvw_kg - tu.tare_kg, 0) FROM fleet.vehicle v
                      LEFT JOIN fleet.truck_unit tu ON tu.vehicle_id = v.id WHERE v.id = p_vehicle) END,
         CASE WHEN p_combination IS NOT NULL THEN
                (SELECT tr.volume_m3 FROM fleet.truck_combination c LEFT JOIN fleet.trailer tr ON tr.id = c.trailer_id
                  WHERE c.id = p_combination) END
$$;
COMMENT ON FUNCTION ship.vehicle_payload IS 'Registered cargo capacity of a vehicle, or of a truck and its trailer (1067)';
REVOKE ALL ON FUNCTION ship.shipment_size(bigint), ship.trip_cargo_usage(bigint), ship.load_usage(bigint),
  ship.vehicle_payload(bigint, bigint) FROM PUBLIC;

-- ------------------------------ the limits and the used figures on the capacity rows ------------------------------
CREATE OR REPLACE FUNCTION ship.tg_trip_cargo_capacity() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE u record; limit_kg numeric; lowered boolean;
BEGIN
  IF current_setting('masslak.cargo_backfill', true) IS DISTINCT FROM 'on'
     AND (TG_OP = 'INSERT' OR NEW.max_weight_kg IS DISTINCT FROM OLD.max_weight_kg) THEN
    SELECT coalesce(v.weight_kg, 0) INTO limit_kg FROM ops.trip t
      LEFT JOIN LATERAL ship.vehicle_payload(t.vehicle_id, NULL) v ON true WHERE t.id = NEW.trip_id;
    IF (SELECT vehicle_id FROM ops.trip WHERE id = NEW.trip_id) IS NOT NULL AND NEW.max_weight_kg > limit_kg THEN
      RAISE EXCEPTION 'CARGO_OVER_VEHICLE: the hold offered (% kg) exceeds the % kg the trip''s vehicle is registered to carry',
        NEW.max_weight_kg, limit_kg USING ERRCODE = 'P0001';
    END IF;
  END IF;
  SELECT * INTO u FROM ship.trip_cargo_usage(NEW.trip_id);
  lowered := TG_OP = 'INSERT' OR NEW.max_weight_kg < OLD.max_weight_kg
             OR coalesce(NEW.max_volume_m3, 'infinity') < coalesce(OLD.max_volume_m3, 'infinity')
             OR coalesce(NEW.max_items, 2147483647) < coalesce(OLD.max_items, 2147483647);
  IF lowered AND current_setting('masslak.cargo_backfill', true) IS DISTINCT FROM 'on'
     AND (u.weight_kg > NEW.max_weight_kg OR u.volume_m3 > coalesce(NEW.max_volume_m3, 'infinity')
          OR u.pieces > coalesce(NEW.max_items, 2147483647)) THEN
    RAISE EXCEPTION 'CARGO_CAPACITY: the hold cannot be set under what is already loaded (% kg)', u.weight_kg USING ERRCODE = 'P0001';
  END IF;
  NEW.used_weight_kg := u.weight_kg; NEW.used_volume_m3 := u.volume_m3; NEW.used_items := u.pieces;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trip_cargo_capacity_rules ON ship.trip_cargo_capacity;
CREATE TRIGGER trip_cargo_capacity_rules BEFORE INSERT OR UPDATE ON ship.trip_cargo_capacity
  FOR EACH ROW EXECUTE FUNCTION ship.tg_trip_cargo_capacity();

CREATE OR REPLACE FUNCTION ship.tg_load_capacity() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE u record; lim record; lowered boolean;
BEGIN
  IF current_setting('masslak.cargo_backfill', true) IS DISTINCT FROM 'on'
     AND (TG_OP = 'INSERT' OR NEW.max_weight_kg IS DISTINCT FROM OLD.max_weight_kg
          OR NEW.max_volume_m3 IS DISTINCT FROM OLD.max_volume_m3 OR NEW.vehicle_id IS DISTINCT FROM OLD.vehicle_id
          OR NEW.truck_combination_id IS DISTINCT FROM OLD.truck_combination_id) THEN
    SELECT * INTO lim FROM ship.vehicle_payload(NEW.vehicle_id, NEW.truck_combination_id);
    IF NEW.max_weight_kg > coalesce(lim.weight_kg, 0) THEN
      RAISE EXCEPTION 'CARGO_OVER_VEHICLE: the load (% kg) exceeds the % kg its vehicle is registered to carry',
        NEW.max_weight_kg, coalesce(lim.weight_kg, 0) USING ERRCODE = 'P0001';
    END IF;
    IF lim.volume_m3 IS NOT NULL AND NEW.max_volume_m3 > lim.volume_m3 THEN
      RAISE EXCEPTION 'CARGO_OVER_VEHICLE: the load (% m3) exceeds the % m3 of its trailer', NEW.max_volume_m3, lim.volume_m3
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  IF TG_OP = 'INSERT' THEN
    NEW.used_weight_kg := 0; NEW.used_volume_m3 := 0;        -- nothing can be on a load that does not exist yet
    RETURN NEW;
  END IF;
  SELECT * INTO u FROM ship.load_usage(NEW.id);
  lowered := NEW.max_weight_kg < OLD.max_weight_kg
             OR coalesce(NEW.max_volume_m3, 'infinity') < coalesce(OLD.max_volume_m3, 'infinity');
  IF lowered AND current_setting('masslak.cargo_backfill', true) IS DISTINCT FROM 'on'
     AND (u.weight_kg > NEW.max_weight_kg OR u.volume_m3 > coalesce(NEW.max_volume_m3, 'infinity')) THEN
    RAISE EXCEPTION 'CARGO_CAPACITY: the load cannot be set under what is already on it (% kg)', u.weight_kg USING ERRCODE = 'P0001';
  END IF;
  NEW.used_weight_kg := u.weight_kg; NEW.used_volume_m3 := u.volume_m3;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS load_capacity_rules ON ship.load;
CREATE TRIGGER load_capacity_rules BEFORE INSERT OR UPDATE ON ship.load
  FOR EACH ROW EXECUTE FUNCTION ship.tg_load_capacity();

-- the used figures now come from the contents (above), which a row loaded before this file may already exceed
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT conrelid::regclass AS t, conname FROM pg_constraint
            WHERE conrelid IN ('ship.trip_cargo_capacity'::regclass, 'ship.load'::regclass) AND contype = 'c'
              AND pg_get_constraintdef(oid) LIKE '%used_weight_kg <= max_weight_kg%' LOOP
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', r.t, r.conname);
  END LOOP;
END $$;

-- ------------------------------ every change to what is loaded is checked ------------------------------
-- p_adding: the change may add cargo (a refusal is possible); taking cargo off only refreshes the figures
CREATE OR REPLACE FUNCTION ship.cargo_recheck_trip(p_trip bigint, p_adding boolean) RETURNS void LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE cap ship.trip_cargo_capacity; u record;
BEGIN
  IF p_trip IS NULL THEN RETURN; END IF;
  -- the row lock makes concurrent loaders of one trip wait for each other; the use is read after it, so it counts theirs
  SELECT * INTO cap FROM ship.trip_cargo_capacity WHERE trip_id = p_trip FOR UPDATE;
  IF NOT FOUND THEN
    IF p_adding THEN
      RAISE EXCEPTION 'CARGO_NOT_OFFERED: the trip offers no hold capacity for parcels' USING ERRCODE = 'P0001';
    END IF;
    RETURN;
  END IF;
  SELECT * INTO u FROM ship.trip_cargo_usage(p_trip);
  IF p_adding AND ((u.weight_kg > cap.max_weight_kg AND u.weight_kg > cap.used_weight_kg)
                   OR (u.volume_m3 > coalesce(cap.max_volume_m3, 'infinity') AND u.volume_m3 > cap.used_volume_m3)
                   OR (u.pieces > coalesce(cap.max_items, 2147483647) AND u.pieces > cap.used_items)) THEN
    RAISE EXCEPTION 'CARGO_CAPACITY: the hold would carry % kg, % m3 and % pieces; it takes % kg', round(u.weight_kg, 1),
      round(u.volume_m3, 2), u.pieces, cap.max_weight_kg USING ERRCODE = 'P0001';
  END IF;
  UPDATE ship.trip_cargo_capacity SET used_weight_kg = u.weight_kg WHERE trip_id = p_trip;   -- the trigger sets all three
END $$;

CREATE OR REPLACE FUNCTION ship.cargo_recheck_load(p_load bigint, p_adding boolean) RETURNS void LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE cap ship.load; u record;
BEGIN
  IF p_load IS NULL THEN RETURN; END IF;
  SELECT * INTO cap FROM ship.load WHERE id = p_load FOR UPDATE;
  IF NOT FOUND THEN RETURN; END IF;
  SELECT * INTO u FROM ship.load_usage(p_load);
  IF p_adding AND ((u.weight_kg > cap.max_weight_kg AND u.weight_kg > cap.used_weight_kg)
                   OR (u.volume_m3 > coalesce(cap.max_volume_m3, 'infinity') AND u.volume_m3 > cap.used_volume_m3)) THEN
    RAISE EXCEPTION 'CARGO_CAPACITY: the load would carry % kg and % m3; it takes % kg', round(u.weight_kg, 1),
      round(u.volume_m3, 2), cap.max_weight_kg USING ERRCODE = 'P0001';
  END IF;
  UPDATE ship.load SET used_weight_kg = u.weight_kg WHERE id = p_load;
END $$;
REVOKE ALL ON FUNCTION ship.cargo_recheck_trip(bigint, boolean), ship.cargo_recheck_load(bigint, boolean) FROM PUBLIC;

CREATE OR REPLACE FUNCTION ship.tg_leg_cargo() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF TG_OP <> 'INSERT' THEN                                   -- where the leg was: only freed, never refused
    IF TG_OP = 'DELETE' OR OLD.trip_id IS DISTINCT FROM NEW.trip_id THEN PERFORM ship.cargo_recheck_trip(OLD.trip_id, false); END IF;
    IF TG_OP = 'DELETE' OR OLD.load_id IS DISTINCT FROM NEW.load_id THEN PERFORM ship.cargo_recheck_load(OLD.load_id, false); END IF;
  END IF;
  IF TG_OP <> 'DELETE' THEN
    PERFORM ship.cargo_recheck_trip(NEW.trip_id, NEW.status <> 'CANCELLED');
    PERFORM ship.cargo_recheck_load(NEW.load_id, NEW.status <> 'CANCELLED');
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS leg_cargo_capacity ON ship.shipment_leg;
CREATE TRIGGER leg_cargo_capacity AFTER INSERT OR DELETE OR UPDATE OF trip_id, load_id, from_seq, to_seq, status, shipment_id
  ON ship.shipment_leg FOR EACH ROW EXECUTE FUNCTION ship.tg_leg_cargo();

-- re-weighing a parcel, or the billed weight of a shipment not weighed yet, counts on every vehicle it rides
CREATE OR REPLACE FUNCTION ship.tg_shipment_size_cargo() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE s bigint; r record;
BEGIN
  IF TG_TABLE_NAME = 'shipment' THEN s := NEW.id;            -- one branch per table: each reads only its own columns
  ELSIF TG_OP = 'DELETE' THEN s := OLD.shipment_id;
  ELSE s := NEW.shipment_id;
  END IF;
  FOR r IN SELECT DISTINCT trip_id, load_id FROM ship.shipment_leg
            WHERE shipment_id = s AND status <> 'CANCELLED' AND (trip_id IS NOT NULL OR load_id IS NOT NULL) LOOP
    PERFORM ship.cargo_recheck_trip(r.trip_id, TG_OP <> 'DELETE');
    PERFORM ship.cargo_recheck_load(r.load_id, TG_OP <> 'DELETE');
  END LOOP;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS parcel_cargo_capacity ON ship.parcel;
CREATE TRIGGER parcel_cargo_capacity AFTER INSERT OR DELETE OR UPDATE OF weight_kg, length_cm, width_cm, height_cm
  ON ship.parcel FOR EACH ROW EXECUTE FUNCTION ship.tg_shipment_size_cargo();
DROP TRIGGER IF EXISTS shipment_cargo_capacity ON ship.shipment;
CREATE TRIGGER shipment_cargo_capacity AFTER UPDATE OF billable_weight_kg ON ship.shipment
  FOR EACH ROW EXECUTE FUNCTION ship.tg_shipment_size_cargo();

CREATE OR REPLACE FUNCTION ship.tg_capacity_booking_cargo() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  -- where the booking was: only freed (on the same trip or load the check below sees the change whole)
  IF TG_OP = 'DELETE' OR (TG_OP = 'UPDATE' AND OLD.trip_id IS DISTINCT FROM NEW.trip_id) THEN
    PERFORM ship.cargo_recheck_trip(OLD.trip_id, false);
  END IF;
  IF TG_OP = 'DELETE' OR (TG_OP = 'UPDATE' AND OLD.load_id IS DISTINCT FROM NEW.load_id) THEN
    PERFORM ship.cargo_recheck_load(OLD.load_id, false);
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.status <> 'CONFIRMED' THEN     -- released or cancelled on the same trip or load
    PERFORM ship.cargo_recheck_trip(NEW.trip_id, false);
    PERFORM ship.cargo_recheck_load(NEW.load_id, false);
  END IF;
  IF TG_OP <> 'DELETE' AND NEW.status = 'CONFIRMED' THEN
    PERFORM ship.cargo_recheck_trip(NEW.trip_id, true);
    PERFORM ship.cargo_recheck_load(NEW.load_id, true);
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS capacity_booking_cargo ON ship.capacity_booking;
CREATE TRIGGER capacity_booking_cargo AFTER INSERT OR DELETE OR UPDATE OF status, reserved_weight_kg, reserved_volume_m3, trip_id, load_id
  ON ship.capacity_booking FOR EACH ROW EXECUTE FUNCTION ship.tg_capacity_booking_cargo();

-- a trip's vehicle, or a vehicle's registered capacity, cannot change under the hold already offered
CREATE OR REPLACE FUNCTION ship.tg_vehicle_cargo_limit() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE r record;
BEGIN
  FOR r IN SELECT c.trip_id, c.max_weight_kg, v.weight_kg AS limit_kg
             FROM ship.trip_cargo_capacity c JOIN ops.trip t ON t.id = c.trip_id
            CROSS JOIN LATERAL ship.vehicle_payload(t.vehicle_id, NULL) v
            WHERE t.vehicle_id IS NOT NULL AND t.status NOT IN ('COMPLETED', 'CANCELLED')
              AND CASE TG_TABLE_NAME WHEN 'trip' THEN t.id = NEW.id ELSE t.vehicle_id = NEW.id END
              AND c.max_weight_kg > coalesce(v.weight_kg, 0) LOOP
    RAISE EXCEPTION 'CARGO_OVER_VEHICLE: trip % offers % kg of hold, more than the % kg its vehicle is registered to carry',
      r.trip_id, r.max_weight_kg, coalesce(r.limit_kg, 0) USING ERRCODE = 'P0001';
  END LOOP;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trip_vehicle_cargo_limit ON ops.trip;
CREATE TRIGGER trip_vehicle_cargo_limit AFTER UPDATE OF vehicle_id ON ops.trip
  FOR EACH ROW WHEN (NEW.vehicle_id IS DISTINCT FROM OLD.vehicle_id) EXECUTE FUNCTION ship.tg_vehicle_cargo_limit();
DROP TRIGGER IF EXISTS vehicle_cargo_limit ON fleet.vehicle;
CREATE TRIGGER vehicle_cargo_limit AFTER UPDATE OF cargo_capacity_kg ON fleet.vehicle
  FOR EACH ROW WHEN (NEW.cargo_capacity_kg < OLD.cargo_capacity_kg) EXECUTE FUNCTION ship.tg_vehicle_cargo_limit();

-- ------------------------------ rows loaded before this file ------------------------------
CREATE OR REPLACE FUNCTION ship.cargo_overbooked()
  RETURNS TABLE (kind text, id bigint, used_weight_kg numeric, max_weight_kg numeric, used_volume_m3 numeric, max_volume_m3 numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT 'TRIP', trip_id, used_weight_kg, max_weight_kg, used_volume_m3, max_volume_m3 FROM ship.trip_cargo_capacity
   WHERE used_weight_kg > max_weight_kg OR used_volume_m3 > coalesce(max_volume_m3, 'infinity')
      OR used_items > coalesce(max_items, 2147483647)
  UNION ALL
  SELECT 'LOAD', id, used_weight_kg, max_weight_kg, used_volume_m3, max_volume_m3 FROM ship.load
   WHERE used_weight_kg > max_weight_kg OR used_volume_m3 > coalesce(max_volume_m3, 'infinity')
$$;
COMMENT ON FUNCTION ship.cargo_overbooked IS 'Trip holds and loads carrying more than their maximum, which only data from before 1067 can do';
REVOKE ALL ON FUNCTION ship.cargo_overbooked() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ship.cargo_overbooked() TO masslak_readonly;

-- the used figures of existing rows, from their contents (limits are not re-judged here: ship.cargo_overbooked() lists
-- what is over, and from now on only taking cargo off such a row is accepted)
DO $$
DECLARE n bigint;
BEGIN
  PERFORM set_config('masslak.cargo_backfill', 'on', true);
  UPDATE ship.trip_cargo_capacity SET used_weight_kg = used_weight_kg;
  UPDATE ship.load SET used_weight_kg = used_weight_kg;
  PERFORM set_config('masslak.cargo_backfill', 'off', true);
  SELECT count(*) INTO n FROM ship.cargo_overbooked();
  IF n > 0 THEN
    RAISE WARNING '% trip holds or loads already carry more than their maximum: SELECT * FROM ship.cargo_overbooked()', n;
  END IF;
END $$;

INSERT INTO sys.schema_migration (version, description)
SELECT '1.46.0', 'Cargo stays within the capacity of the vehicle that carries it (external technical report)'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.46.0');
