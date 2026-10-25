-- 1174: colours and axle arrangements are chosen from lists the platform keeps, never typed (owner's notes of 25 October
-- 2026: "colours must be defined in the system to avoid duplicates misspelt at entry, above all the basic car colours:
-- white, black, brown, beige, silver, grey..."; "axles must be defined in advance to avoid entry mistakes: 2, 3, 4 and
-- others, following the international systems").
--   * ref.vehicle_colour: the colours with their English and Arabic names and a swatch; the platform adds, renames and
--     retires them (a retired colour stays on the vehicles that have it and is not chosen again). Nothing is deleted.
--   * ref.axle_config: the wheel formulas of powered vehicles (4x2, 6x4, 8x4 ... wheel positions by driven positions,
--     the usual notation of makers and regulators) and the axle groups of trailers (single, tandem, tridem ... up to
--     eight), each with its number of axles.
--   * fleet.vehicle and fleet.trailer take a colour from the list (colour_code); the free colour text of 1173 (not yet
--     released) is moved onto the list where its name matches and dropped. fleet.truck_unit.axle_config and the new
--     fleet.trailer.axle_config point at the list; a trailer's number of axles follows its arrangement.
--   * Edits of both lists are kept field by field with who, when and why (the 1170 trigger); a name changes only with a
--     reason.

-- ------------------------------------------------------------------ colours
CREATE TABLE IF NOT EXISTS ref.vehicle_colour (
  id             bigint GENERATED ALWAYS AS IDENTITY UNIQUE,
  code           text PRIMARY KEY CHECK (code ~ '^[A-Z][A-Z0-9_]{1,29}$'),
  name_en        text NOT NULL CHECK (length(name_en) BETWEEN 2 AND 40),
  name_ar        text NOT NULL CHECK (length(name_ar) BETWEEN 2 AND 40),
  hex            text CHECK (hex IS NULL OR hex ~ '^#[0-9A-F]{6}$'),
  sort_order     smallint NOT NULL DEFAULT 100 CHECK (sort_order BETWEEN 0 AND 9999),
  status         text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'RETIRED')),
  change_reason  text CHECK (change_reason IS NULL),
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS vehicle_colour_name_en_uq ON ref.vehicle_colour (lower(name_en));
CREATE UNIQUE INDEX IF NOT EXISTS vehicle_colour_name_ar_uq ON ref.vehicle_colour (name_ar);
COMMENT ON TABLE ref.vehicle_colour IS 'Vehicle colours chosen from a list, never typed, so one colour is not entered under several spellings (1174)';
COMMENT ON COLUMN ref.vehicle_colour.hex IS 'The swatch shown next to the name; empty for two-tone';
COMMENT ON COLUMN ref.vehicle_colour.change_reason IS 'Given with an edit and moved into ref.vehicle_colour_change by the trigger (1174)';
DROP TRIGGER IF EXISTS vehicle_colour_updated ON ref.vehicle_colour;
CREATE TRIGGER vehicle_colour_updated BEFORE UPDATE ON ref.vehicle_colour FOR EACH ROW EXECUTE FUNCTION sys.tg_set_updated_at();

-- ------------------------------------------------------------------ axle arrangements
CREATE TABLE IF NOT EXISTS ref.axle_config (
  id             bigint GENERATED ALWAYS AS IDENTITY UNIQUE,
  code           text PRIMARY KEY CHECK (length(code) BETWEEN 1 AND 30),
  kind           text NOT NULL CHECK (kind IN ('VEHICLE', 'TRAILER')),
  axles          smallint CHECK (axles BETWEEN 1 AND 8),
  driven_axles   smallint CHECK (driven_axles BETWEEN 1 AND 8),
  name_en        text NOT NULL CHECK (length(name_en) BETWEEN 2 AND 60),
  name_ar        text NOT NULL CHECK (length(name_ar) BETWEEN 2 AND 60),
  sort_order     smallint NOT NULL DEFAULT 100 CHECK (sort_order BETWEEN 0 AND 9999),
  status         text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'RETIRED')),
  source         text NOT NULL DEFAULT 'STANDARD' CHECK (source IN ('STANDARD', 'PLATFORM', 'LEGACY')),
  change_reason  text CHECK (change_reason IS NULL),
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  -- a formula names wheel positions by driven positions (4x2: two axles, one driven); a trailer group, its axles
  CONSTRAINT axle_config_shape_ck CHECK (
    source = 'LEGACY'
    OR (kind = 'VEHICLE' AND code ~ '^[0-9]{1,2}x[0-9]{1,2}$' AND axles IS NOT NULL AND driven_axles IS NOT NULL
        AND split_part(code, 'x', 1)::int = 2 * axles AND split_part(code, 'x', 2)::int = 2 * driven_axles
        AND driven_axles <= axles)
    OR (kind = 'TRAILER' AND code ~ '^T[1-8]$' AND axles = substr(code, 2)::int AND driven_axles IS NULL)),
  CONSTRAINT axle_config_legacy_ck CHECK (source <> 'LEGACY' OR status = 'RETIRED')
);
COMMENT ON TABLE ref.axle_config IS 'Axle arrangements chosen from a list (1174): wheel formulas of powered vehicles and axle groups of trailers';
COMMENT ON COLUMN ref.axle_config.code IS 'Wheel formula (4x2, 6x4, 8x4 ...: wheel positions by driven positions) or trailer group T1..T8';
COMMENT ON COLUMN ref.axle_config.source IS 'STANDARD from 1174, PLATFORM added later, LEGACY a value typed before the list (kept retired)';
COMMENT ON COLUMN ref.axle_config.change_reason IS 'Given with an edit and moved into ref.axle_config_change by the trigger (1174)';
DROP TRIGGER IF EXISTS axle_config_updated ON ref.axle_config;
CREATE TRIGGER axle_config_updated BEFORE UPDATE ON ref.axle_config FOR EACH ROW EXECUTE FUNCTION sys.tg_set_updated_at();

INSERT INTO ref.vehicle_colour (code, name_en, name_ar, hex, sort_order) VALUES
  ('WHITE', 'White', U&'\0623\0628\064A\0636', '#FFFFFF', 10),
  ('PEARL_WHITE', 'Pearl white', U&'\0623\0628\064A\0636 \0644\0624\0644\0624\064A', '#F2EFE6', 20),
  ('BLACK', 'Black', U&'\0623\0633\0648\062F', '#111111', 30),
  ('SILVER', 'Silver', U&'\0631\0635\0627\0635\064A', '#B8BCC2', 40),
  ('GREY', 'Grey', U&'\0631\0645\0627\062F\064A', '#80858C', 50),
  ('DARK_GREY', 'Dark grey', U&'\0631\0645\0627\062F\064A \063A\0627\0645\0642', '#4A4E54', 60),
  ('BEIGE', 'Beige', U&'\0628\064A\062C', '#D9C9A8', 70),
  ('CHAMPAGNE', 'Champagne', U&'\0634\0645\0628\0627\0646\064A\0627', '#E4D2A6', 80),
  ('BROWN', 'Brown', U&'\0628\0646\064A', '#6B4423', 90),
  ('BRONZE', 'Bronze', U&'\0628\0631\0648\0646\0632\064A', '#8C6A3F', 100),
  ('GOLD', 'Gold', U&'\0630\0647\0628\064A', '#C9A227', 110),
  ('YELLOW', 'Yellow', U&'\0623\0635\0641\0631', '#F2C200', 120),
  ('ORANGE', 'Orange', U&'\0628\0631\062A\0642\0627\0644\064A', '#E8730C', 130),
  ('RED', 'Red', U&'\0623\062D\0645\0631', '#C0161D', 140),
  ('MAROON', 'Maroon', U&'\062E\0645\0631\064A', '#6E1423', 150),
  ('PINK', 'Pink', U&'\0632\0647\0631\064A', '#E58BB0', 160),
  ('PURPLE', 'Purple', U&'\0628\0646\0641\0633\062C\064A', '#5B2A86', 170),
  ('BLUE', 'Blue', U&'\0623\0632\0631\0642', '#1F4FB8', 180),
  ('NAVY', 'Navy blue', U&'\0643\062D\0644\064A', '#1B2A4A', 190),
  ('SKY_BLUE', 'Sky blue', U&'\0633\0645\0627\0648\064A', '#7FB3E0', 200),
  ('TURQUOISE', 'Turquoise', U&'\0641\064A\0631\0648\0632\064A', '#1AA6A6', 210),
  ('GREEN', 'Green', U&'\0623\062E\0636\0631', '#2E7D32', 220),
  ('DARK_GREEN', 'Dark green', U&'\0623\062E\0636\0631 \063A\0627\0645\0642', '#1B4D2E', 230),
  ('OLIVE', 'Olive', U&'\0632\064A\062A\064A', '#6B6B2A', 240),
  ('TWO_TONE', 'Two-tone', U&'\0644\0648\0646\0627\0646', NULL, 250)
ON CONFLICT (code) DO NOTHING;

INSERT INTO ref.axle_config (code, kind, axles, driven_axles, name_en, name_ar, sort_order) VALUES
  ('4x2', 'VEHICLE', 2, 1, 'Two axles, one driven', U&'\0645\062D\0648\0631\0627\0646\060C \0645\062D\0648\0631 \062F\0627\0641\0639 \0648\0627\062D\062F', 10),
  ('4x4', 'VEHICLE', 2, 2, 'Two axles, both driven', U&'\0645\062D\0648\0631\0627\0646\060C \062F\0641\0639 \0631\0628\0627\0639\064A', 20),
  ('6x2', 'VEHICLE', 3, 1, 'Three axles, one driven', U&'\062B\0644\0627\062B\0629 \0645\062D\0627\0648\0631\060C \0645\062D\0648\0631 \062F\0627\0641\0639 \0648\0627\062D\062F', 30),
  ('6x4', 'VEHICLE', 3, 2, 'Three axles, two driven', U&'\062B\0644\0627\062B\0629 \0645\062D\0627\0648\0631\060C \0645\062D\0648\0631\0627\0646 \062F\0627\0641\0639\0627\0646', 40),
  ('6x6', 'VEHICLE', 3, 3, 'Three axles, all driven', U&'\062B\0644\0627\062B\0629 \0645\062D\0627\0648\0631\060C \0643\0644\0647\0627 \062F\0627\0641\0639\0629', 50),
  ('8x2', 'VEHICLE', 4, 1, 'Four axles, one driven', U&'\0623\0631\0628\0639\0629 \0645\062D\0627\0648\0631\060C \0645\062D\0648\0631 \062F\0627\0641\0639 \0648\0627\062D\062F', 60),
  ('8x4', 'VEHICLE', 4, 2, 'Four axles, two driven', U&'\0623\0631\0628\0639\0629 \0645\062D\0627\0648\0631\060C \0645\062D\0648\0631\0627\0646 \062F\0627\0641\0639\0627\0646', 70),
  ('8x6', 'VEHICLE', 4, 3, 'Four axles, three driven', U&'\0623\0631\0628\0639\0629 \0645\062D\0627\0648\0631\060C \062B\0644\0627\062B\0629 \062F\0627\0641\0639\0629', 80),
  ('8x8', 'VEHICLE', 4, 4, 'Four axles, all driven', U&'\0623\0631\0628\0639\0629 \0645\062D\0627\0648\0631\060C \0643\0644\0647\0627 \062F\0627\0641\0639\0629', 90),
  ('10x4', 'VEHICLE', 5, 2, 'Five axles, two driven', U&'\062E\0645\0633\0629 \0645\062D\0627\0648\0631\060C \0645\062D\0648\0631\0627\0646 \062F\0627\0641\0639\0627\0646', 100),
  ('10x6', 'VEHICLE', 5, 3, 'Five axles, three driven', U&'\062E\0645\0633\0629 \0645\062D\0627\0648\0631\060C \062B\0644\0627\062B\0629 \062F\0627\0641\0639\0629', 110),
  ('10x8', 'VEHICLE', 5, 4, 'Five axles, four driven', U&'\062E\0645\0633\0629 \0645\062D\0627\0648\0631\060C \0623\0631\0628\0639\0629 \062F\0627\0641\0639\0629', 120),
  ('T1', 'TRAILER', 1, NULL, 'Single axle', U&'\0645\062D\0648\0631 \0648\0627\062D\062F', 510),
  ('T2', 'TRAILER', 2, NULL, 'Tandem, two axles', U&'\0645\062D\0648\0631\0627\0646 (\062A\0631\0627\062F\0641\064A)', 520),
  ('T3', 'TRAILER', 3, NULL, 'Tridem, three axles', U&'\062B\0644\0627\062B\0629 \0645\062D\0627\0648\0631', 530),
  ('T4', 'TRAILER', 4, NULL, 'Four axles', U&'\0623\0631\0628\0639\0629 \0645\062D\0627\0648\0631', 540),
  ('T5', 'TRAILER', 5, NULL, 'Five axles', U&'\062E\0645\0633\0629 \0645\062D\0627\0648\0631', 550),
  ('T6', 'TRAILER', 6, NULL, 'Six axles', U&'\0633\062A\0629 \0645\062D\0627\0648\0631', 560),
  ('T7', 'TRAILER', 7, NULL, 'Seven axles', U&'\0633\0628\0639\0629 \0645\062D\0627\0648\0631', 570),
  ('T8', 'TRAILER', 8, NULL, 'Eight axles', U&'\062B\0645\0627\0646\064A\0629 \0645\062D\0627\0648\0631', 580)
ON CONFLICT (code) DO NOTHING;


-- ------------------------------------------------------------------ edit history of both lists
CREATE TABLE IF NOT EXISTS ref.vehicle_colour_change (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  colour_id    bigint NOT NULL REFERENCES ref.vehicle_colour(id),
  changed_at   timestamptz NOT NULL DEFAULT now(),
  changed_by   bigint REFERENCES iam.app_user(id),
  field        text NOT NULL CHECK (field ~ '^[a-z_]{2,40}$'),
  old_value    text,
  new_value    text,
  reason       text CHECK (reason IS NULL OR length(reason) <= 500)
);
CREATE TABLE IF NOT EXISTS ref.axle_config_change (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  axle_id      bigint NOT NULL REFERENCES ref.axle_config(id),
  changed_at   timestamptz NOT NULL DEFAULT now(),
  changed_by   bigint REFERENCES iam.app_user(id),
  field        text NOT NULL CHECK (field ~ '^[a-z_]{2,40}$'),
  old_value    text,
  new_value    text,
  reason       text CHECK (reason IS NULL OR length(reason) <= 500)
);
COMMENT ON TABLE ref.vehicle_colour_change IS 'Every edit of a colour in the list, field by field, with who, when and why (1174); never changed';
COMMENT ON TABLE ref.axle_config_change IS 'Every edit of an axle arrangement in the list, field by field, with who, when and why (1174); never changed';
CREATE INDEX IF NOT EXISTS vehicle_colour_change_code ON ref.vehicle_colour_change (colour_id, changed_at);
CREATE INDEX IF NOT EXISTS vehicle_colour_change_user ON ref.vehicle_colour_change (changed_by);
CREATE INDEX IF NOT EXISTS axle_config_change_code ON ref.axle_config_change (axle_id, changed_at);
CREATE INDEX IF NOT EXISTS axle_config_change_user ON ref.axle_config_change (changed_by);
DROP TRIGGER IF EXISTS vehicle_colour_edit_history ON ref.vehicle_colour;
CREATE TRIGGER vehicle_colour_edit_history BEFORE UPDATE ON ref.vehicle_colour FOR EACH ROW EXECUTE FUNCTION sys.tg_edit_history(
  'ref.vehicle_colour_change', 'colour_id', 'id', 'name_en,name_ar,hex,sort_order,status', 'name_en,name_ar', 'COLOUR');
DROP TRIGGER IF EXISTS axle_config_edit_history ON ref.axle_config;
CREATE TRIGGER axle_config_edit_history BEFORE UPDATE ON ref.axle_config FOR EACH ROW EXECUTE FUNCTION sys.tg_edit_history(
  'ref.axle_config_change', 'axle_id', 'id', 'name_en,name_ar,sort_order,status', 'name_en,name_ar', 'AXLE');
DROP TRIGGER IF EXISTS vehicle_colour_change_append_only ON ref.vehicle_colour_change;
CREATE TRIGGER vehicle_colour_change_append_only BEFORE UPDATE OR DELETE ON ref.vehicle_colour_change
  FOR EACH ROW EXECUTE FUNCTION sys.tg_history_append_only();
DROP TRIGGER IF EXISTS axle_config_change_append_only ON ref.axle_config_change;
CREATE TRIGGER axle_config_change_append_only BEFORE UPDATE OR DELETE ON ref.axle_config_change
  FOR EACH ROW EXECUTE FUNCTION sys.tg_history_append_only();
-- the code is the key every vehicle points at; it is not changed (a wrong entry is retired and a right one added)
CREATE OR REPLACE FUNCTION ref.tg_list_code_fixed() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.code IS DISTINCT FROM OLD.code THEN
    RAISE EXCEPTION 'CODE_FIXED: the code of a list entry is not changed; retire it and add another' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
COMMENT ON FUNCTION ref.tg_list_code_fixed() IS 'The code of a colour or an axle arrangement never changes (1174)';
DROP TRIGGER IF EXISTS vehicle_colour_code_fixed ON ref.vehicle_colour;
CREATE TRIGGER vehicle_colour_code_fixed BEFORE UPDATE ON ref.vehicle_colour FOR EACH ROW EXECUTE FUNCTION ref.tg_list_code_fixed();
DROP TRIGGER IF EXISTS axle_config_code_fixed ON ref.axle_config;
CREATE TRIGGER axle_config_code_fixed BEFORE UPDATE ON ref.axle_config FOR EACH ROW EXECUTE FUNCTION ref.tg_list_code_fixed();

-- ------------------------------------------------------------------ trucks: the axle arrangement from the list
-- a value typed before the list is kept as a retired entry, so nothing on a truck is lost
INSERT INTO ref.axle_config (code, kind, name_en, name_ar, status, source, sort_order)
SELECT DISTINCT tu.axle_config, 'VEHICLE', left(tu.axle_config, 60), left(tu.axle_config, 60), 'RETIRED', 'LEGACY', 9000
  FROM fleet.truck_unit tu
 WHERE NOT EXISTS (SELECT 1 FROM ref.axle_config a WHERE a.code = tu.axle_config)
   AND NOT EXISTS (SELECT 1 FROM ref.axle_config a WHERE a.code = lower(replace(btrim(tu.axle_config), ' ', '')))
   AND length(tu.axle_config) BETWEEN 2 AND 30
ON CONFLICT (code) DO NOTHING;
UPDATE fleet.truck_unit tu SET axle_config = lower(replace(btrim(tu.axle_config), ' ', ''))
 WHERE NOT EXISTS (SELECT 1 FROM ref.axle_config a WHERE a.code = tu.axle_config)
   AND EXISTS (SELECT 1 FROM ref.axle_config a WHERE a.code = lower(replace(btrim(tu.axle_config), ' ', '')));
ALTER TABLE fleet.truck_unit DROP CONSTRAINT IF EXISTS truck_unit_axle_config_fkey;
ALTER TABLE fleet.truck_unit ADD CONSTRAINT truck_unit_axle_config_fkey FOREIGN KEY (axle_config) REFERENCES ref.axle_config(code);
CREATE INDEX IF NOT EXISTS truck_unit_axle_config_fkx ON fleet.truck_unit (axle_config);
COMMENT ON COLUMN fleet.truck_unit.axle_config IS 'Wheel formula from ref.axle_config (1174), e.g. 4x2, 6x4';

-- ------------------------------------------------------------------ vehicles and trailers: colour from the list
ALTER TABLE fleet.vehicle ADD COLUMN IF NOT EXISTS colour_code text REFERENCES ref.vehicle_colour(code);
ALTER TABLE fleet.trailer ADD COLUMN IF NOT EXISTS colour_code text REFERENCES ref.vehicle_colour(code);
ALTER TABLE fleet.trailer ADD COLUMN IF NOT EXISTS axle_config text REFERENCES ref.axle_config(code);
CREATE INDEX IF NOT EXISTS vehicle_colour_code_fkx ON fleet.vehicle (colour_code);
CREATE INDEX IF NOT EXISTS trailer_colour_code_fkx ON fleet.trailer (colour_code);
CREATE INDEX IF NOT EXISTS trailer_axle_config_fkx ON fleet.trailer (axle_config);
COMMENT ON COLUMN fleet.vehicle.colour_code IS 'The vehicle''s colour from ref.vehicle_colour (1174)';
COMMENT ON COLUMN fleet.trailer.colour_code IS 'The trailer''s colour from ref.vehicle_colour (1174)';
COMMENT ON COLUMN fleet.trailer.axle_config IS 'Axle group from ref.axle_config (1174); the trailer''s number of axles follows it';
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'fleet' AND table_name = 'vehicle' AND column_name = 'colour') THEN
    EXECUTE $q$
      UPDATE fleet.vehicle v SET colour_code = c.code
        FROM ref.vehicle_colour c
       WHERE v.colour_code IS NULL AND v.colour IS NOT NULL
         AND (lower(btrim(v.colour)) IN (lower(c.name_en), lower(c.code), lower(replace(c.name_en, ' ', '')))
              OR btrim(v.colour) = c.name_ar)$q$;
    ALTER TABLE fleet.vehicle DROP COLUMN colour;
  END IF;
END $$;
UPDATE fleet.trailer SET axle_config = 'T' || axles WHERE axle_config IS NULL AND axles IS NOT NULL;

-- what is chosen must be on the list and still in use; a trailer's axles follow its arrangement
CREATE OR REPLACE FUNCTION fleet.tg_list_choices() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE j jsonb := to_jsonb(NEW); o jsonb := CASE WHEN TG_OP = 'UPDATE' THEN to_jsonb(OLD) ELSE '{}'::jsonb END;
        a record; want text := CASE WHEN TG_TABLE_NAME = 'trailer' THEN 'TRAILER' ELSE 'VEHICLE' END;
BEGIN
  IF j ? 'colour_code' AND j ->> 'colour_code' IS NOT NULL AND (j ->> 'colour_code') IS DISTINCT FROM (o ->> 'colour_code')
     AND EXISTS (SELECT 1 FROM ref.vehicle_colour WHERE code = j ->> 'colour_code' AND status <> 'ACTIVE') THEN
    RAISE EXCEPTION 'COLOUR_RETIRED: this colour is no longer offered; choose another from the list' USING ERRCODE = 'P0001';
  END IF;
  IF j ? 'axle_config' AND j ->> 'axle_config' IS NOT NULL AND (j ->> 'axle_config') IS DISTINCT FROM (o ->> 'axle_config') THEN
    SELECT kind, axles, status INTO a FROM ref.axle_config WHERE code = j ->> 'axle_config';
    IF FOUND AND a.kind <> want THEN
      RAISE EXCEPTION 'AXLE_KIND: % is not an arrangement for a %', j ->> 'axle_config', lower(want) USING ERRCODE = 'P0001';
    END IF;
    IF FOUND AND a.status <> 'ACTIVE' THEN
      RAISE EXCEPTION 'AXLE_RETIRED: this axle arrangement is no longer offered; choose another from the list' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  IF TG_TABLE_NAME = 'trailer' THEN                          -- nested: NEW of a vehicle has no axle_config
    IF NEW.axle_config IS NOT NULL THEN
      NEW.axles := (SELECT axles FROM ref.axle_config WHERE code = NEW.axle_config);
    END IF;
  END IF;
  RETURN NEW;
END $$;
COMMENT ON FUNCTION fleet.tg_list_choices() IS 'A colour or an axle arrangement is chosen from its list, active and of the right kind; a trailer''s axles follow its arrangement (1174)';
DROP TRIGGER IF EXISTS vehicle_a_list_choices ON fleet.vehicle;
CREATE TRIGGER vehicle_a_list_choices BEFORE INSERT OR UPDATE OF colour_code ON fleet.vehicle FOR EACH ROW EXECUTE FUNCTION fleet.tg_list_choices();
DROP TRIGGER IF EXISTS trailer_a_list_choices ON fleet.trailer;
CREATE TRIGGER trailer_a_list_choices BEFORE INSERT OR UPDATE OF colour_code, axle_config, axles ON fleet.trailer FOR EACH ROW EXECUTE FUNCTION fleet.tg_list_choices();
DROP TRIGGER IF EXISTS truck_unit_a_list_choices ON fleet.truck_unit;
CREATE TRIGGER truck_unit_a_list_choices BEFORE INSERT OR UPDATE OF axle_config ON fleet.truck_unit FOR EACH ROW EXECUTE FUNCTION fleet.tg_list_choices();

-- the edit histories keep the new fields
DROP TRIGGER IF EXISTS vehicle_edit_history ON fleet.vehicle;
CREATE TRIGGER vehicle_edit_history BEFORE UPDATE ON fleet.vehicle FOR EACH ROW EXECUTE FUNCTION sys.tg_edit_history(
  'fleet.vehicle_change', 'vehicle_id', 'id',
  'plate_no,plate_country,chassis_no,machine_no,serial_no,vehicle_type,vehicle_class,make,model,model_id,manufacture_year,seat_layout_id,passenger_seats,standing_capacity,cargo_capacity_kg,fuel_tank_l,ownership_type,status,block_reason,fleet_use,colour_code,fuel_type,trim_id',
  'plate_no,plate_country,chassis_no,machine_no,serial_no', 'VEHICLE');
DROP TRIGGER IF EXISTS trailer_edit_history ON fleet.trailer;
CREATE TRIGGER trailer_edit_history BEFORE UPDATE ON fleet.trailer FOR EACH ROW EXECUTE FUNCTION sys.tg_edit_history(
  'fleet.trailer_change', 'trailer_id', 'id',
  'plate_no,plate_country,chassis_no,trailer_type,payload_kg,volume_m3,length_m,axles,axle_config,colour_code,container_capacity,ownership_type,status,make,manufacture_year',
  'plate_no,plate_country,chassis_no', 'TRAILER');

-- ------------------------------------------------------------------ grants, isolation, registers
SELECT sys.rls('ref.vehicle_colour', 'true', 'sys.ctx_is_platform()');
SELECT sys.rls('ref.axle_config', 'true', 'sys.ctx_is_platform()');
SELECT sys.rls('ref.vehicle_colour_change', 'true', 'sys.ctx_is_platform()');
SELECT sys.rls('ref.axle_config_change', 'true', 'sys.ctx_is_platform()');
GRANT SELECT, INSERT, UPDATE ON ref.vehicle_colour, ref.axle_config TO masslak_app;
GRANT SELECT, INSERT ON ref.vehicle_colour_change, ref.axle_config_change TO masslak_app;
GRANT SELECT ON ref.vehicle_colour, ref.axle_config, ref.vehicle_colour_change, ref.axle_config_change TO masslak_readonly, masslak_auditor;

INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('ref.vehicle_colour', '1A', 'E01'), ('ref.axle_config', '1A', 'E01'),
  ('ref.vehicle_colour_change', '1A', 'E01'), ('ref.axle_config_change', '1A', 'E01')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
SELECT sys.refresh_table_class();
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('ref.vehicle_colour', 'ref catalog', 'vehicle colours chosen from a list (1174)'),
  ('ref.axle_config', 'ref catalog', 'axle arrangements of vehicles and trailers (1174)'),
  ('ref.vehicle_colour_change', 'fleet records', 'the history of every edit of a colour (1174)'),
  ('ref.axle_config_change', 'fleet records', 'the history of every edit of an axle arrangement (1174)')
ON CONFLICT (table_name) DO NOTHING;
