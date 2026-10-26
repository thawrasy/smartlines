-- 1170: records are edited, and every edit is kept (owner's note, 25 October 2026: "some data cannot be edited at all
-- once saved"). Vehicles and crew could be added but not changed. They are now edited in place,
-- and the table itself keeps the history, field by field, with who changed it, when and why:
--   * sys.tg_edit_history: one trigger for every edited table, told by its arguments where the history goes, which
--     fields it keeps, and which of them are regulated (a reason is then required). The reason is given on the row in
--     change_reason, moved into the history and cleared, as in 1168; no session setting is trusted (1084).
--   * fleet.vehicle_change: a vehicle's plate, chassis, engine and serial numbers (regulated), and its type, make,
--     model, year, capacities, ownership and status.
--   * fleet.crew_change: a crew member's kind, licence class and status.
--   A person's names and identity document are not kept in such a history: an erasure request must be able to remove
--   them (1039), and an append-only copy would keep them. Their corrections stay in the activity log, which redacts them.
-- Licences keep their own rule (030): once saved, their number and dates change only through a change request approved
-- by two other people; a renewal is a new licence record.

CREATE OR REPLACE FUNCTION sys.tg_edit_history() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  hist text := TG_ARGV[0];                                   -- the history table
  fk text := TG_ARGV[1];                                     -- its column naming the edited row
  key text := TG_ARGV[2];                                    -- the edited row's key
  kept text[] := string_to_array(TG_ARGV[3], ',');           -- fields kept in the history
  regulated text[] := string_to_array(coalesce(TG_ARGV[4], ''), ',');   -- fields that need a reason
  code text := coalesce(TG_ARGV[5], 'RECORD');               -- the prefix of the error codes
  o jsonb := to_jsonb(OLD);
  n jsonb := to_jsonb(NEW);
  reason text := nullif(btrim(n ->> 'change_reason'), '');
  uid bigint := sys.ctx_user_id();
  f text;
BEGIN
  FOREACH f IN ARRAY regulated LOOP
    IF f <> '' AND o -> f IS DISTINCT FROM n -> f AND (reason IS NULL OR length(reason) < 3) THEN
      RAISE EXCEPTION '%_CHANGE_REASON: changing % needs its reason', code, f USING ERRCODE = 'P0001';
    END IF;
  END LOOP;
  FOREACH f IN ARRAY kept LOOP
    IF o -> f IS DISTINCT FROM n -> f THEN
      EXECUTE format('INSERT INTO %s (%I, changed_by, field, old_value, new_value, reason) VALUES ($1, $2, $3, $4, $5, $6)', hist, fk)
        USING (o ->> key)::bigint, uid, f, o ->> f, n ->> f, left(reason, 500);
    END IF;
  END LOOP;
  NEW := jsonb_populate_record(NEW, jsonb_build_object('change_reason', NULL));
  RETURN NEW;
END $$;
COMMENT ON FUNCTION sys.tg_edit_history() IS 'Keeps every edit of a row, field by field (1170): arguments are the history table, its column for the row, the row''s key, the kept fields, the regulated fields (a reason required) and the error prefix';

CREATE OR REPLACE FUNCTION sys.tg_history_append_only() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'HISTORY_APPEND_ONLY: the history of a record is never changed' USING ERRCODE = 'P0001';
END $$;

-- ------------------------------------------------------------------ vehicles
ALTER TABLE fleet.vehicle ADD COLUMN IF NOT EXISTS change_reason text CHECK (change_reason IS NULL);
COMMENT ON COLUMN fleet.vehicle.change_reason IS 'Given with an edit and moved into fleet.vehicle_change by the trigger; never kept on the row (1170)';

CREATE TABLE IF NOT EXISTS fleet.vehicle_change (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  vehicle_id  bigint NOT NULL REFERENCES fleet.vehicle(id),
  changed_at  timestamptz NOT NULL DEFAULT now(),
  changed_by  bigint REFERENCES iam.app_user(id),
  field       text NOT NULL CHECK (field ~ '^[a-z_]{2,40}$'),
  old_value   text,
  new_value   text,
  reason      text CHECK (reason IS NULL OR length(reason) <= 500)
);
COMMENT ON TABLE fleet.vehicle_change IS 'Every edit of a vehicle, field by field, with who, when and why (1170); never updated or deleted';
CREATE INDEX IF NOT EXISTS vehicle_change_vehicle ON fleet.vehicle_change (vehicle_id, changed_at);
CREATE INDEX IF NOT EXISTS vehicle_change_user ON fleet.vehicle_change (changed_by);

DROP TRIGGER IF EXISTS vehicle_edit_history ON fleet.vehicle;
CREATE TRIGGER vehicle_edit_history BEFORE UPDATE ON fleet.vehicle FOR EACH ROW EXECUTE FUNCTION sys.tg_edit_history(
  'fleet.vehicle_change', 'vehicle_id', 'id',
  'plate_no,plate_country,chassis_no,machine_no,serial_no,vehicle_type,vehicle_class,make,model,model_id,manufacture_year,seat_layout_id,passenger_seats,standing_capacity,cargo_capacity_kg,fuel_tank_l,ownership_type,status,block_reason',
  'plate_no,plate_country,chassis_no,machine_no,serial_no', 'VEHICLE');
DROP TRIGGER IF EXISTS vehicle_change_append_only ON fleet.vehicle_change;
CREATE TRIGGER vehicle_change_append_only BEFORE UPDATE OR DELETE ON fleet.vehicle_change
  FOR EACH ROW EXECUTE FUNCTION sys.tg_history_append_only();

-- ------------------------------------------------------------------ crew
ALTER TABLE fleet.crew_profile ADD COLUMN IF NOT EXISTS change_reason text CHECK (change_reason IS NULL);
COMMENT ON COLUMN fleet.crew_profile.change_reason IS 'Given with an edit and moved into fleet.crew_change by the trigger (1170)';

CREATE TABLE IF NOT EXISTS fleet.crew_change (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  party_id    bigint NOT NULL REFERENCES fleet.crew_profile(party_id),
  changed_at  timestamptz NOT NULL DEFAULT now(),
  changed_by  bigint REFERENCES iam.app_user(id),
  field       text NOT NULL CHECK (field ~ '^[a-z_]{2,40}$'),
  old_value   text,
  new_value   text,
  reason      text CHECK (reason IS NULL OR length(reason) <= 500)
);
COMMENT ON TABLE fleet.crew_change IS 'Every edit of a crew member''s profile, field by field (1170); never updated or deleted';
CREATE INDEX IF NOT EXISTS crew_change_party ON fleet.crew_change (party_id, changed_at);
CREATE INDEX IF NOT EXISTS crew_change_user ON fleet.crew_change (changed_by);

DROP TRIGGER IF EXISTS crew_edit_history ON fleet.crew_profile;
CREATE TRIGGER crew_edit_history BEFORE UPDATE ON fleet.crew_profile FOR EACH ROW EXECUTE FUNCTION sys.tg_edit_history(
  'fleet.crew_change', 'party_id', 'party_id', 'crew_type,license_class,status', '', 'CREW');
DROP TRIGGER IF EXISTS crew_change_append_only ON fleet.crew_change;
CREATE TRIGGER crew_change_append_only BEFORE UPDATE OR DELETE ON fleet.crew_change
  FOR EACH ROW EXECUTE FUNCTION sys.tg_history_append_only();

-- ------------------------------------------------------------------ licences: an approved change request is applied
-- A saved licence is locked (030): its number and dates change through a request reviewed and approved by two people
-- other than the one who asked (1054). Approving it now applies the new values to the licence, so the request is the
-- licence's history; before, an approved request changed nothing.
CREATE OR REPLACE FUNCTION fleet.tg_license_change_apply() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v jsonb := NEW.new_values;
BEGIN
  UPDATE fleet.license_record
     SET license_no = coalesce(nullif(btrim(v ->> 'license_no'), ''), license_no),
         issuer = coalesce(nullif(btrim(v ->> 'issuer'), ''), issuer),
         issue_date = coalesce((v ->> 'issue_date')::date, issue_date),
         expiry_date = coalesce((v ->> 'expiry_date')::date, expiry_date),
         last_change_request_id = NEW.id
   WHERE id = NEW.license_record_id;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS license_change_apply ON fleet.license_change_request;
CREATE TRIGGER license_change_apply AFTER UPDATE OF status ON fleet.license_change_request
  FOR EACH ROW WHEN (NEW.status = 'APPROVED' AND OLD.status IS DISTINCT FROM 'APPROVED')
  EXECUTE FUNCTION fleet.tg_license_change_apply();

-- the history follows the row it belongs to: whoever sees the vehicle, crew member or person sees its edits
SELECT sys.rls_parent('fleet.vehicle_change', 'vehicle_id', 'fleet.vehicle');
SELECT sys.rls_parent('fleet.crew_change', 'party_id', 'fleet.crew_profile', 'party_id');
GRANT SELECT, INSERT ON fleet.vehicle_change, fleet.crew_change TO masslak_app;
GRANT SELECT ON fleet.vehicle_change, fleet.crew_change TO masslak_readonly, masslak_auditor;
GRANT UPDATE (change_reason) ON fleet.vehicle, fleet.crew_profile TO masslak_app;

INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('fleet.vehicle_change', '1A', 'E06'), ('fleet.crew_change', '1A', 'E07')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
SELECT sys.refresh_table_class();
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('fleet.vehicle_change', 'fleet records', 'the history of every edit of a vehicle (1170)'),
  ('fleet.crew_change', 'fleet records', 'the history of every edit of a crew member''s profile (1170)')
ON CONFLICT (table_name) DO NOTHING;
