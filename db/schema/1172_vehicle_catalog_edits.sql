-- 1172: the list of vehicle makes and models is edited, and an entry nothing has used is deleted (owner's request,
-- 25 October 2026: "can be edited later, added to or deleted, but no type that has any movement is deleted").
--   * A model has its Arabic name, body type and the years it was made; a model has trims (ref.vehicle_trim) with the
--     fuel and years of each, imported with the owner's file or added by hand.
--   * Makes, models and trims are edited in place, every edit kept field by field with who, when and why (the 1170
--     trigger, sys.tg_edit_history); a name is changed only with a reason.
--   * An entry is deleted only while nothing uses it: a model chosen by a vehicle or by a carrier's request, and a
--     make with models or requests, are not deleted; they are retired instead and stay in the records. A deleted entry
--     takes its trims and its edit history with it (the delete itself stays in the activity log).

-- ------------------------------------------------------------------ models: Arabic name, body, years
ALTER TABLE ref.vehicle_model ADD COLUMN IF NOT EXISTS name_ar text CHECK (name_ar IS NULL OR length(name_ar) BETWEEN 1 AND 80);
ALTER TABLE ref.vehicle_model ADD COLUMN IF NOT EXISTS body_type text CHECK (body_type IS NULL OR body_type IN
  ('SEDAN', 'HATCH', 'SUV', 'PICKUP', 'MPV', 'COUPE', 'VAN', 'COACH', 'MINIBUS', 'CITY_BUS', 'TRUCK', 'OTHER'));
ALTER TABLE ref.vehicle_model ADD COLUMN IF NOT EXISTS year_from smallint CHECK (year_from IS NULL OR year_from BETWEEN 1950 AND 2100);
ALTER TABLE ref.vehicle_model ADD COLUMN IF NOT EXISTS year_to smallint CHECK (year_to IS NULL OR year_to BETWEEN 1950 AND 2100);
ALTER TABLE ref.vehicle_model DROP CONSTRAINT IF EXISTS vehicle_model_years_ck;
ALTER TABLE ref.vehicle_model ADD CONSTRAINT vehicle_model_years_ck CHECK (year_to IS NULL OR year_from IS NULL OR year_to >= year_from);
ALTER TABLE ref.vehicle_model ADD COLUMN IF NOT EXISTS change_reason text CHECK (change_reason IS NULL);
ALTER TABLE ref.vehicle_make ADD COLUMN IF NOT EXISTS change_reason text CHECK (change_reason IS NULL);
COMMENT ON COLUMN ref.vehicle_model.name_ar IS 'The model''s name in Arabic letters (1172)';
COMMENT ON COLUMN ref.vehicle_model.body_type IS 'Sedan, hatchback, SUV, pickup, MPV, coupe, van, or the bus and truck kinds (1172)';
COMMENT ON COLUMN ref.vehicle_model.year_from IS 'First year of the model in the list (1172); 2020 for models made before and since';
COMMENT ON COLUMN ref.vehicle_model.year_to IS 'Last year the model was made; empty while it is still made (1172)';
COMMENT ON COLUMN ref.vehicle_model.change_reason IS 'Given with an edit and moved into ref.vehicle_model_change by the trigger (1172)';
COMMENT ON COLUMN ref.vehicle_make.change_reason IS 'Given with an edit and moved into ref.vehicle_make_change by the trigger (1172)';

-- ------------------------------------------------------------------ trims
CREATE TABLE IF NOT EXISTS ref.vehicle_trim (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid            uuid NOT NULL DEFAULT gen_random_uuid(),
  model_id       bigint NOT NULL REFERENCES ref.vehicle_model(id) ON DELETE CASCADE,
  name           text NOT NULL CHECK (length(name) BETWEEN 1 AND 80),
  name_ar        text CHECK (name_ar IS NULL OR length(name_ar) BETWEEN 1 AND 80),
  fuel           text NOT NULL DEFAULT 'PETROL' CHECK (fuel IN ('PETROL', 'DIESEL', 'HYBRID', 'PLUG_IN_HYBRID', 'ELECTRIC', 'RANGE_EXTENDER', 'GAS')),
  year_from      smallint CHECK (year_from IS NULL OR year_from BETWEEN 1950 AND 2100),
  year_to        smallint CHECK (year_to IS NULL OR year_to BETWEEN 1950 AND 2100),
  status         text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'RETIRED')),
  source         text NOT NULL DEFAULT 'MANUAL' CHECK (source IN ('MANUAL', 'IMPORT')),
  entered_by     bigint NOT NULL REFERENCES iam.app_user(id),
  change_reason  text CHECK (change_reason IS NULL),
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT vehicle_trim_years_ck CHECK (year_to IS NULL OR year_from IS NULL OR year_to >= year_from)
);
CREATE UNIQUE INDEX IF NOT EXISTS vehicle_trim_uid_uq ON ref.vehicle_trim (uid);
CREATE UNIQUE INDEX IF NOT EXISTS vehicle_trim_name_uq ON ref.vehicle_trim (model_id, lower(name), fuel);
CREATE INDEX IF NOT EXISTS vehicle_trim_entered_by_fkx ON ref.vehicle_trim (entered_by);
COMMENT ON TABLE ref.vehicle_trim IS 'Trims of a vehicle model with their fuel and years (1172): part of the model, which a second person reviewed';
COMMENT ON COLUMN ref.vehicle_trim.change_reason IS 'Given with an edit and moved into ref.vehicle_trim_change by the trigger (1172)';
DROP TRIGGER IF EXISTS vehicle_trim_updated ON ref.vehicle_trim;
CREATE TRIGGER vehicle_trim_updated BEFORE UPDATE ON ref.vehicle_trim FOR EACH ROW EXECUTE FUNCTION sys.tg_set_updated_at();

-- ------------------------------------------------------------------ edit history
CREATE TABLE IF NOT EXISTS ref.vehicle_make_change (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  make_id     bigint NOT NULL REFERENCES ref.vehicle_make(id) ON DELETE CASCADE,
  changed_at  timestamptz NOT NULL DEFAULT now(),
  changed_by  bigint REFERENCES iam.app_user(id),
  field       text NOT NULL CHECK (field ~ '^[a-z_]{2,40}$'),
  old_value   text,
  new_value   text,
  reason      text CHECK (reason IS NULL OR length(reason) <= 500)
);
CREATE TABLE IF NOT EXISTS ref.vehicle_model_change (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  model_id    bigint NOT NULL REFERENCES ref.vehicle_model(id) ON DELETE CASCADE,
  changed_at  timestamptz NOT NULL DEFAULT now(),
  changed_by  bigint REFERENCES iam.app_user(id),
  field       text NOT NULL CHECK (field ~ '^[a-z_]{2,40}$'),
  old_value   text,
  new_value   text,
  reason      text CHECK (reason IS NULL OR length(reason) <= 500)
);
CREATE TABLE IF NOT EXISTS ref.vehicle_trim_change (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  trim_id     bigint NOT NULL REFERENCES ref.vehicle_trim(id) ON DELETE CASCADE,
  changed_at  timestamptz NOT NULL DEFAULT now(),
  changed_by  bigint REFERENCES iam.app_user(id),
  field       text NOT NULL CHECK (field ~ '^[a-z_]{2,40}$'),
  old_value   text,
  new_value   text,
  reason      text CHECK (reason IS NULL OR length(reason) <= 500)
);
COMMENT ON TABLE ref.vehicle_make_change IS 'Every edit of a vehicle make, field by field, with who, when and why (1172); goes only with its make';
COMMENT ON TABLE ref.vehicle_model_change IS 'Every edit of a vehicle model, field by field, with who, when and why (1172); goes only with its model';
COMMENT ON TABLE ref.vehicle_trim_change IS 'Every edit of a vehicle trim, field by field, with who, when and why (1172); goes only with its trim';
CREATE INDEX IF NOT EXISTS vehicle_make_change_make ON ref.vehicle_make_change (make_id, changed_at);
CREATE INDEX IF NOT EXISTS vehicle_make_change_user ON ref.vehicle_make_change (changed_by);
CREATE INDEX IF NOT EXISTS vehicle_model_change_model ON ref.vehicle_model_change (model_id, changed_at);
CREATE INDEX IF NOT EXISTS vehicle_model_change_user ON ref.vehicle_model_change (changed_by);
CREATE INDEX IF NOT EXISTS vehicle_trim_change_trim ON ref.vehicle_trim_change (trim_id, changed_at);
CREATE INDEX IF NOT EXISTS vehicle_trim_change_user ON ref.vehicle_trim_change (changed_by);

DROP TRIGGER IF EXISTS vehicle_make_edit_history ON ref.vehicle_make;
CREATE TRIGGER vehicle_make_edit_history BEFORE UPDATE ON ref.vehicle_make FOR EACH ROW EXECUTE FUNCTION sys.tg_edit_history(
  'ref.vehicle_make_change', 'make_id', 'id', 'name_en,name_ar,country_code,status', 'name_en,name_ar', 'MAKE');
DROP TRIGGER IF EXISTS vehicle_model_edit_history ON ref.vehicle_model;
CREATE TRIGGER vehicle_model_edit_history BEFORE UPDATE ON ref.vehicle_model FOR EACH ROW EXECUTE FUNCTION sys.tg_edit_history(
  'ref.vehicle_model_change', 'model_id', 'id',
  'name,name_ar,vehicle_class,vehicle_type,body_type,seats_from,seats_to,weight_class,year_from,year_to,production,confidence,notes,status',
  'name', 'MODEL');
DROP TRIGGER IF EXISTS vehicle_trim_edit_history ON ref.vehicle_trim;
CREATE TRIGGER vehicle_trim_edit_history BEFORE UPDATE ON ref.vehicle_trim FOR EACH ROW EXECUTE FUNCTION sys.tg_edit_history(
  'ref.vehicle_trim_change', 'trim_id', 'id', 'name,name_ar,fuel,year_from,year_to,status', '', 'TRIM');

-- the history is never changed; it goes only when the entry it belongs to is deleted (the parent row is gone by then)
CREATE OR REPLACE FUNCTION ref.tg_catalog_history_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE parent text := TG_ARGV[0]; col text := TG_ARGV[1]; still boolean;
BEGIN
  IF TG_OP = 'DELETE' THEN
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM %s WHERE id = $1)', parent) INTO still USING (to_jsonb(OLD) ->> col)::bigint;
    IF NOT still THEN
      RETURN OLD;
    END IF;
  END IF;
  RAISE EXCEPTION 'HISTORY_APPEND_ONLY: the history of a record is never changed' USING ERRCODE = 'P0001';
END $$;
COMMENT ON FUNCTION ref.tg_catalog_history_guard() IS 'History of a vehicle make, model or trim: never updated; deleted only with its entry (1172)';
DROP TRIGGER IF EXISTS vehicle_make_change_guard ON ref.vehicle_make_change;
CREATE TRIGGER vehicle_make_change_guard BEFORE UPDATE OR DELETE ON ref.vehicle_make_change
  FOR EACH ROW EXECUTE FUNCTION ref.tg_catalog_history_guard('ref.vehicle_make', 'make_id');
DROP TRIGGER IF EXISTS vehicle_model_change_guard ON ref.vehicle_model_change;
CREATE TRIGGER vehicle_model_change_guard BEFORE UPDATE OR DELETE ON ref.vehicle_model_change
  FOR EACH ROW EXECUTE FUNCTION ref.tg_catalog_history_guard('ref.vehicle_model', 'model_id');
DROP TRIGGER IF EXISTS vehicle_trim_change_guard ON ref.vehicle_trim_change;
CREATE TRIGGER vehicle_trim_change_guard BEFORE UPDATE OR DELETE ON ref.vehicle_trim_change
  FOR EACH ROW EXECUTE FUNCTION ref.tg_catalog_history_guard('ref.vehicle_trim', 'trim_id');

-- ------------------------------------------------------------------ nothing used is deleted
-- The foreign keys from vehicles and requests already refuse it; this says why, in words the screens show.
CREATE OR REPLACE FUNCTION ref.tg_catalog_delete() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF TG_TABLE_NAME = 'vehicle_model' THEN
    IF EXISTS (SELECT 1 FROM fleet.vehicle WHERE model_id = OLD.id)
       OR EXISTS (SELECT 1 FROM fleet.vehicle_model_request WHERE model_id = OLD.id) THEN
      RAISE EXCEPTION 'MODEL_IN_USE: vehicles or requests use this model; retire it instead' USING ERRCODE = 'P0001';
    END IF;
  ELSIF TG_TABLE_NAME = 'vehicle_make' THEN
    IF EXISTS (SELECT 1 FROM ref.vehicle_model WHERE make_id = OLD.id) THEN
      RAISE EXCEPTION 'MAKE_HAS_MODELS: delete or move its models first, or retire the make' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM fleet.vehicle_model_request WHERE make_id = OLD.id) THEN
      RAISE EXCEPTION 'MAKE_IN_USE: carriers'' requests name this make; retire it instead' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN OLD;
END $$;
COMMENT ON FUNCTION ref.tg_catalog_delete() IS 'A make or model is deleted only while no vehicle, request or model uses it (1172)';
DROP TRIGGER IF EXISTS vehicle_model_delete ON ref.vehicle_model;
CREATE TRIGGER vehicle_model_delete BEFORE DELETE ON ref.vehicle_model FOR EACH ROW EXECUTE FUNCTION ref.tg_catalog_delete();
DROP TRIGGER IF EXISTS vehicle_make_delete ON ref.vehicle_make;
CREATE TRIGGER vehicle_make_delete BEFORE DELETE ON ref.vehicle_make FOR EACH ROW EXECUTE FUNCTION ref.tg_catalog_delete();

-- ------------------------------------------------------------------ grants, isolation, registers
SELECT sys.rls('ref.vehicle_trim', 'true', 'sys.ctx_is_platform()');
SELECT sys.rls_parent('ref.vehicle_make_change', 'make_id', 'ref.vehicle_make');
SELECT sys.rls_parent('ref.vehicle_model_change', 'model_id', 'ref.vehicle_model');
SELECT sys.rls_parent('ref.vehicle_trim_change', 'trim_id', 'ref.vehicle_trim');
GRANT SELECT, INSERT, UPDATE ON ref.vehicle_trim TO masslak_app;
GRANT SELECT, INSERT ON ref.vehicle_make_change, ref.vehicle_model_change, ref.vehicle_trim_change TO masslak_app;
GRANT SELECT ON ref.vehicle_trim, ref.vehicle_make_change, ref.vehicle_model_change, ref.vehicle_trim_change TO masslak_readonly, masslak_auditor;
INSERT INTO sys.app_delete_grant (table_name, reason) VALUES
  ('ref.vehicle_make', 'a vehicle make entered by mistake, with no models or requests, is deleted (1172)'),
  ('ref.vehicle_model', 'a vehicle model no vehicle or request has used is deleted (1172)'),
  ('ref.vehicle_trim', 'a trim of a vehicle model is deleted from the list (1172)')
ON CONFLICT (table_name) DO NOTHING;
SELECT sys.enforce_app_delete_grants();

INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('ref.vehicle_trim', '1A', 'E01'), ('ref.vehicle_make_change', '1A', 'E01'),
  ('ref.vehicle_model_change', '1A', 'E01'), ('ref.vehicle_trim_change', '1A', 'E01')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
SELECT sys.refresh_table_class();
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('ref.vehicle_trim', 'ref catalog', 'trims of vehicle models (1172)'),
  ('ref.vehicle_make_change', 'fleet records', 'the history of every edit of a vehicle make (1172)'),
  ('ref.vehicle_model_change', 'fleet records', 'the history of every edit of a vehicle model (1172)'),
  ('ref.vehicle_trim_change', 'fleet records', 'the history of every edit of a vehicle trim (1172)')
ON CONFLICT (table_name) DO NOTHING;
