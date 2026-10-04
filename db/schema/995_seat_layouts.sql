-- =====================================================================
-- 995: seat layouts that match the real vehicle (rows, seats per row, aisle, doors, WC, decks)
--   * fleet.seat_layout.grid holds one grid per deck, a string per row (codes in backend/app/modules/fleet/layout.py).
--     fleet.seat_layout_seat holds every passenger seat with its number, label, row and column.
--   * Layouts are immutable versions: a change is a new layout assigned to the vehicle. A vehicle's passenger seat
--     count always equals its layout's seat count.
--   * A trip keeps a snapshot of its vehicle's seat map (ops.trip.seat_map) taken when it is created, so seat numbers
--     sold on a trip never move when the vehicle's layout changes later.
-- =====================================================================
ALTER TABLE fleet.seat_layout ADD COLUMN IF NOT EXISTS uid uuid NOT NULL DEFAULT gen_random_uuid();
ALTER TABLE fleet.seat_layout ADD COLUMN IF NOT EXISTS grid jsonb;
ALTER TABLE fleet.seat_layout ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'ACTIVE';
ALTER TABLE fleet.seat_layout ADD COLUMN IF NOT EXISTS created_by bigint REFERENCES iam.app_user(id);
CREATE UNIQUE INDEX IF NOT EXISTS seat_layout_uid_uq ON fleet.seat_layout (uid);
CREATE UNIQUE INDEX IF NOT EXISTS seat_layout_name_uq ON fleet.seat_layout (company_id, name) WHERE status = 'ACTIVE';
DO $$ BEGIN
  ALTER TABLE fleet.seat_layout ADD CONSTRAINT seat_layout_status_ck CHECK (status IN ('ACTIVE','ARCHIVED'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE fleet.seat_layout ADD CONSTRAINT seat_layout_grid_ck
    CHECK (grid IS NULL OR (jsonb_typeof(grid) = 'array' AND jsonb_array_length(grid) BETWEEN 1 AND 2));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
COMMENT ON COLUMN fleet.seat_layout.grid IS 'One array of row strings per deck: S seat, H accessible seat, _ aisle, D door, C WC, R stairs, X empty';

-- Layouts belong to a carrier (or are shared templates when company_id is empty)
ALTER TABLE fleet.seat_layout ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS seat_layout_read ON fleet.seat_layout;
DROP POLICY IF EXISTS seat_layout_write ON fleet.seat_layout;
CREATE POLICY seat_layout_read  ON fleet.seat_layout FOR SELECT USING (company_id IS NULL OR sys.tenant_visible(company_id));
CREATE POLICY seat_layout_write ON fleet.seat_layout FOR ALL
  USING (sys.tenant_visible(company_id)) WITH CHECK (sys.tenant_visible(company_id));
ALTER TABLE fleet.seat_layout_seat ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS seat_layout_seat_via_layout ON fleet.seat_layout_seat;
CREATE POLICY seat_layout_seat_via_layout ON fleet.seat_layout_seat
  USING (EXISTS (SELECT 1 FROM fleet.seat_layout l WHERE l.id = layout_id));   -- inherits the layout policy
-- Layout seats are written once with their layout and never edited
REVOKE UPDATE ON fleet.seat_layout_seat FROM masslak_app;

-- A vehicle with a layout carries exactly the layout's seats
CREATE OR REPLACE FUNCTION fleet.tg_vehicle_layout_seats() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE n smallint;
BEGIN
  IF NEW.seat_layout_id IS NOT NULL THEN
    SELECT total_seats INTO n FROM fleet.seat_layout WHERE id = NEW.seat_layout_id;
    IF n IS DISTINCT FROM NEW.passenger_seats THEN
      RAISE EXCEPTION 'SEAT_COUNT_MISMATCH: vehicle has % passenger seats, layout has %', NEW.passenger_seats, n
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS vehicle_layout_seats ON fleet.vehicle;
CREATE TRIGGER vehicle_layout_seats BEFORE INSERT OR UPDATE OF seat_layout_id, passenger_seats ON fleet.vehicle
  FOR EACH ROW EXECUTE FUNCTION fleet.tg_vehicle_layout_seats();

-- Seat map snapshot on the trip
ALTER TABLE ops.trip ADD COLUMN IF NOT EXISTS seat_map jsonb;
COMMENT ON COLUMN ops.trip.seat_map IS 'Snapshot of the vehicle seat layout when the trip was created: {layout, decks, seats:[{n,label,deck,row,col,cabin}]}';
DO $$ BEGIN
  ALTER TABLE ops.trip ADD CONSTRAINT trip_seat_map_ck
    CHECK (seat_map IS NULL OR jsonb_array_length(seat_map -> 'seats') = seats_total);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

INSERT INTO sys.schema_migration (version, description)
SELECT '1.5.0', 'Seat layouts matching the real vehicle, seat map snapshot on trips'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.5.0');
