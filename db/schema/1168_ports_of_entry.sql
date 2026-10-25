-- 1168: border crossings and airports (owner's note N45). The owner's approved workbook lists the land crossings and the
-- airports, each tied to the United Nations administrative geography (P-codes) and, where one exists, to a place.
--   * net.port_of_entry: one row per crossing or airport under a fixed code (LND-<country>-<nn> for land crossings,
--     AIR-<IATA or short name> for airports). The code never changes; the names in Arabic and English, the crossing on
--     the other side, the area and place, the position and the operating status are edited by the platform.
--   * net.port_of_entry_change: every change of a port, field by field, with who made it, when and why; the owner's file
--     loaded again counts as a change too (by the file). A port edited by hand is not overwritten by a later file.
--   * The position is the linked United Nations location's, not the gate's own: it is replaced by the surveyed one when
--     the platform records it. A port without a known place (Al-Tanf) is tied to its sub-district only.

ALTER TABLE ref.geo_source DROP CONSTRAINT IF EXISTS geo_source_dataset_kind_check;
ALTER TABLE ref.geo_source DROP CONSTRAINT IF EXISTS geo_source_content_check;
ALTER TABLE ref.geo_source ADD CONSTRAINT geo_source_dataset_kind_check CHECK (content IN ('PLACES', 'BOUNDARIES', 'ROADS', 'PORTS'));

CREATE TABLE IF NOT EXISTS net.port_of_entry (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code                 text NOT NULL UNIQUE CHECK (code ~ '^(LND-[A-Z]{2}-[0-9]{2}|AIR-[A-Z]{3})$'),
  kind                 text NOT NULL CHECK (kind IN ('LAND_BORDER', 'INTL_AIRPORT', 'LOCAL_AIRPORT')),
  name_ar              text NOT NULL CHECK (length(name_ar) BETWEEN 2 AND 200),
  name_en              text NOT NULL CHECK (length(name_en) BETWEEN 2 AND 200),
  counterpart_name_ar  text CHECK (counterpart_name_ar IS NULL OR length(counterpart_name_ar) BETWEEN 2 AND 200),
  counterpart_name_en  text CHECK (counterpart_name_en IS NULL OR length(counterpart_name_en) BETWEEN 2 AND 200),
  counterpart_country  character(2) REFERENCES ref.country(code),
  iata_code            character(3) UNIQUE CHECK (iata_code IS NULL OR iata_code ~ '^[A-Z]{3}$'),
  area_id              bigint NOT NULL REFERENCES ref.admin_area(id),
  place_id             bigint REFERENCES ref.place(id),
  lat                  numeric(9,6) CHECK (lat IS NULL OR lat BETWEEN 32 AND 37.5),
  lng                  numeric(9,6) CHECK (lng IS NULL OR lng BETWEEN 35.5 AND 42.5),
  position_source      text NOT NULL DEFAULT 'UN_LOCATION' CHECK (position_source IN ('UN_LOCATION', 'SURVEY', 'NONE')),
  match_quality        text NOT NULL CHECK (match_quality IN ('EXACT', 'TOWN', 'NEAREST', 'AREA', 'SURVEYED')),
  status               text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'RESTRICTED', 'CLOSED')),
  status_confirmed     boolean NOT NULL DEFAULT false,
  station_id           bigint REFERENCES net.station(id),
  review_note          text CHECK (review_note IS NULL OR length(review_note) <= 2000),
  source_id            bigint REFERENCES ref.geo_source(id),
  edited_by_hand       boolean NOT NULL DEFAULT false,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CHECK ((lat IS NULL) = (lng IS NULL)),
  CHECK ((lat IS NULL) = (position_source = 'NONE')),
  CHECK (kind = 'LAND_BORDER' OR counterpart_country IS NULL),
  CHECK (kind <> 'LAND_BORDER' OR counterpart_country IS NOT NULL),
  CHECK ((code LIKE 'LND-%') = (kind = 'LAND_BORDER')),
  CHECK (kind = 'LAND_BORDER' OR substr(code, 1, 4) = 'AIR-')
);
COMMENT ON TABLE net.port_of_entry IS 'Border crossings and airports under a fixed code, tied to the administrative geography (owner''s note N45, 1168)';
COMMENT ON COLUMN net.port_of_entry.code IS 'Fixed: LND-<ISO country>-<nn> for a land crossing, AIR-<IATA or short name> for an airport';
COMMENT ON COLUMN net.port_of_entry.lat IS 'The linked United Nations location''s position until a surveyed one replaces it (position_source)';
COMMENT ON COLUMN net.port_of_entry.status_confirmed IS 'The operating status is confirmed by an official source; the owner''s file leaves it unconfirmed';
COMMENT ON COLUMN net.port_of_entry.edited_by_hand IS 'Edited by the platform after a file loaded it: a later file does not overwrite it';
CREATE INDEX IF NOT EXISTS port_of_entry_area ON net.port_of_entry (area_id);
CREATE INDEX IF NOT EXISTS port_of_entry_place ON net.port_of_entry (place_id);
CREATE INDEX IF NOT EXISTS port_of_entry_station ON net.port_of_entry (station_id);
CREATE INDEX IF NOT EXISTS port_of_entry_source ON net.port_of_entry (source_id);
CREATE INDEX IF NOT EXISTS port_of_entry_country ON net.port_of_entry (counterpart_country);

CREATE TABLE IF NOT EXISTS net.port_of_entry_change (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  port_id     bigint NOT NULL REFERENCES net.port_of_entry(id),
  changed_at  timestamptz NOT NULL DEFAULT now(),
  changed_by  bigint REFERENCES iam.app_user(id),
  by_file     bigint REFERENCES ref.geo_source(id),
  field       text NOT NULL CHECK (field ~ '^[a-z_]{2,40}$'),
  old_value   text,
  new_value   text,
  reason      text CHECK (reason IS NULL OR length(reason) <= 500),
  CHECK (by_file IS NOT NULL OR (changed_by IS NOT NULL AND reason IS NOT NULL))
);
COMMENT ON TABLE net.port_of_entry_change IS 'Every change of a border crossing or airport, field by field, with who, when and why (1168); never updated or deleted';
CREATE INDEX IF NOT EXISTS port_of_entry_change_port ON net.port_of_entry_change (port_id, changed_at);
CREATE INDEX IF NOT EXISTS port_of_entry_change_user ON net.port_of_entry_change (changed_by);
CREATE INDEX IF NOT EXISTS port_of_entry_change_file ON net.port_of_entry_change (by_file);

-- The history is written by the table itself: the caller gives its reason, or the file being loaded, for the rest of the
-- transaction through net.port_change_note (the application role cannot call set_config itself, 1080); a hand edit
-- needs a reason, a file load names the file.
CREATE OR REPLACE FUNCTION net.port_change_note(p_reason text, p_file bigint DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  PERFORM set_config('app.port_change_reason', coalesce(left(p_reason, 500), ''), true);
  PERFORM set_config('app.port_change_file', coalesce(p_file::text, ''), true);
END $$;
COMMENT ON FUNCTION net.port_change_note(text, bigint) IS 'The reason, or the loading file, the next changes of ports record in their history, for this transaction (1168)';
REVOKE ALL ON FUNCTION net.port_change_note(text, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION net.port_change_note(text, bigint) TO masslak_app;
CREATE OR REPLACE FUNCTION net.tg_port_of_entry_history() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  reason text := nullif(current_setting('app.port_change_reason', true), '');
  file bigint := nullif(current_setting('app.port_change_file', true), '')::bigint;
  uid bigint := sys.ctx_user_id();
  f text;
  o jsonb := to_jsonb(OLD);
  n jsonb := to_jsonb(NEW);
  changed int := 0;
BEGIN
  IF NEW.code IS DISTINCT FROM OLD.code OR NEW.kind IS DISTINCT FROM OLD.kind THEN
    RAISE EXCEPTION 'PORT_CODE_FIXED: a port''s code and kind never change; retire it and add another' USING ERRCODE = 'P0001';
  END IF;
  FOREACH f IN ARRAY ARRAY['name_ar','name_en','counterpart_name_ar','counterpart_name_en','counterpart_country','iata_code',
                           'area_id','place_id','lat','lng','position_source','match_quality','status','status_confirmed',
                           'station_id','review_note'] LOOP
    IF o -> f IS DISTINCT FROM n -> f THEN
      changed := changed + 1;
    END IF;
  END LOOP;
  IF changed > 0 AND file IS NULL THEN
    IF reason IS NULL OR length(reason) < 3 THEN
      RAISE EXCEPTION 'PORT_CHANGE_REASON: a change to a port needs its reason' USING ERRCODE = 'P0001';
    END IF;
    NEW.edited_by_hand := true;
  END IF;
  FOREACH f IN ARRAY ARRAY['name_ar','name_en','counterpart_name_ar','counterpart_name_en','counterpart_country','iata_code',
                           'area_id','place_id','lat','lng','position_source','match_quality','status','status_confirmed',
                           'station_id','review_note'] LOOP
    IF o -> f IS DISTINCT FROM n -> f THEN
      INSERT INTO net.port_of_entry_change (port_id, changed_by, by_file, field, old_value, new_value, reason)
      VALUES (OLD.id, uid, file, f, o ->> f, n ->> f, left(reason, 500));
    END IF;
  END LOOP;
  NEW.updated_at := now();
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS port_of_entry_history ON net.port_of_entry;
CREATE TRIGGER port_of_entry_history BEFORE UPDATE ON net.port_of_entry
  FOR EACH ROW EXECUTE FUNCTION net.tg_port_of_entry_history();

CREATE OR REPLACE FUNCTION net.tg_port_change_append_only() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'PORT_HISTORY_APPEND_ONLY: the history of a port is never changed' USING ERRCODE = 'P0001';
END $$;
DROP TRIGGER IF EXISTS port_of_entry_change_append_only ON net.port_of_entry_change;
CREATE TRIGGER port_of_entry_change_append_only BEFORE UPDATE OR DELETE ON net.port_of_entry_change
  FOR EACH ROW EXECUTE FUNCTION net.tg_port_change_append_only();

-- reference data everyone reads (pickers, the public site); the platform writes
SELECT sys.rls('net.port_of_entry', 'true', 'sys.ctx_is_platform()');
SELECT sys.rls('net.port_of_entry_change', 'sys.ctx_is_platform()', 'sys.ctx_is_platform()');
GRANT SELECT, INSERT, UPDATE ON net.port_of_entry TO masslak_app;
GRANT SELECT, INSERT ON net.port_of_entry_change TO masslak_app;
GRANT SELECT ON net.port_of_entry, net.port_of_entry_change TO masslak_readonly, masslak_auditor;
DROP TRIGGER IF EXISTS zz_audit_capture ON net.port_of_entry;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR UPDATE OR DELETE ON net.port_of_entry FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();

INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('net.port_of_entry', '1A', 'E04'), ('net.port_of_entry_change', '1A', 'E04')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
SELECT sys.refresh_table_class();
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('net.port_of_entry', 'net records', 'border crossings and airports from the owner''s approved file (1168)'),
  ('net.port_of_entry_change', 'net records', 'the history of every change to a crossing or airport (1168)')
ON CONFLICT (table_name) DO NOTHING;
