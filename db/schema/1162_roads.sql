-- =====================================================================
-- 1162: the roads guide (owner's request N38): Syria's numbered roads and the places along them
--   * A road (net.road) has a number (M5, P01, S101), a class (international, main, secondary), its names, the
--     regional number (M45) and its length. Its points (net.road_point) are places of the United Nations geography in
--     order, with the distance from the point before and from the start.
--   * The platform loads the owner's workbook; every point must be a known place whose governorate, district and
--     sub-district match the file, and the order must run without gaps. A file with any mistake loads nothing.
--   * A junction is a place on two roads or more; it is worked out, not entered.
--   * A road starts as the owner's file (OWNER_FILE). It is raised to CARRIER_CONFIRMED or AUTHORITY_APPROVED on a
--     document, asked by one person of the platform and approved by another; every step is kept. A later load does not
--     overwrite a road raised above the owner's file.
--   * Carriers propose corrections (a point's place, a distance, a remark); the platform accepts or rejects them, and
--     an accepted correction of a place or a distance is applied to the point.
-- =====================================================================

ALTER TABLE ref.geo_source DROP CONSTRAINT IF EXISTS geo_source_publisher_check;
ALTER TABLE ref.geo_source ADD CONSTRAINT geo_source_publisher_check CHECK (publisher IN ('OCHA', 'FIELD', 'PLATFORM', 'OWNER'));
ALTER TABLE ref.geo_source DROP CONSTRAINT IF EXISTS geo_source_dataset_kind_check;
ALTER TABLE ref.geo_source ADD CONSTRAINT geo_source_dataset_kind_check CHECK (content IN ('PLACES', 'BOUNDARIES', 'ROADS'));

CREATE TABLE IF NOT EXISTS net.road (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                 uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  code                text NOT NULL UNIQUE CHECK (code ~ '^[A-Z]{1,2}[0-9]{1,3}[A-Z]?$'),
  road_class          text NOT NULL CHECK (road_class IN ('INTERNATIONAL', 'MAIN', 'SECONDARY', 'URBAN')),
  name_ar             text NOT NULL CHECK (length(btrim(name_ar)) BETWEEN 2 AND 200),
  name_en             text NOT NULL CHECK (length(btrim(name_en)) BETWEEN 2 AND 200),
  regional_number     text CHECK (length(regional_number) <= 20),
  length_km           numeric(8,1) CHECK (length_km >= 0),
  note                text CHECK (length(note) <= 2000),
  verification_status text NOT NULL DEFAULT 'OWNER_FILE' CHECK (verification_status IN ('OWNER_FILE', 'CARRIER_CONFIRMED', 'AUTHORITY_APPROVED')),
  source_id           bigint REFERENCES ref.geo_source(id),
  status              text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'RETIRED')),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS road_source_id_fkx ON net.road (source_id);
COMMENT ON TABLE net.road IS 'A numbered road of the roads guide: class, names, regional number, length, how far it is verified (1162, N38)';
COMMENT ON COLUMN net.road.verification_status IS 'OWNER_FILE until a document raises it to CARRIER_CONFIRMED or AUTHORITY_APPROVED (1162)';

CREATE TABLE IF NOT EXISTS net.road_point (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  road_id          bigint NOT NULL REFERENCES net.road(id),
  seq              smallint NOT NULL CHECK (seq >= 1),
  place_id         bigint NOT NULL REFERENCES ref.place(id),
  lat              numeric(9,6) NOT NULL CHECK (lat BETWEEN -90 AND 90),
  lng              numeric(9,6) NOT NULL CHECK (lng BETWEEN -180 AND 180),
  km_from_previous numeric(7,1) NOT NULL DEFAULT 0 CHECK (km_from_previous >= 0),
  km_cumulative    numeric(8,1) NOT NULL DEFAULT 0 CHECK (km_cumulative >= 0),
  is_border        boolean NOT NULL DEFAULT false,
  note             text CHECK (length(note) <= 1000),
  UNIQUE (road_id, seq),
  CHECK (seq > 1 OR km_from_previous = 0)
);
CREATE INDEX IF NOT EXISTS road_point_place_id_fkx ON net.road_point (place_id);
COMMENT ON TABLE net.road_point IS 'The places along a road in order, with the distance from the point before and from the start (1162, N38)';
COMMENT ON COLUMN net.road_point.km_from_previous IS 'Distance from the point before, as the file gives it (an estimate until verified) (1162)';

CREATE TABLE IF NOT EXISTS net.road_verification (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid             uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  road_id         bigint NOT NULL REFERENCES net.road(id),
  from_status     text NOT NULL,
  to_status       text NOT NULL CHECK (to_status IN ('OWNER_FILE', 'CARRIER_CONFIRMED', 'AUTHORITY_APPROVED')),
  document_ref    text NOT NULL CHECK (length(btrim(document_ref)) BETWEEN 3 AND 300),
  note            text CHECK (length(note) <= 1000),
  status          text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED')),
  requested_by    bigint NOT NULL REFERENCES iam.app_user(id),
  requested_at    timestamptz NOT NULL DEFAULT now(),
  decided_by      bigint REFERENCES iam.app_user(id),
  decided_at      timestamptz,
  decision_note   text CHECK (length(decision_note) <= 500),
  CHECK (from_status <> to_status),
  CHECK (decided_by IS NULL OR decided_by IS DISTINCT FROM requested_by),
  CHECK ((status = 'PENDING') = (decided_by IS NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS road_verification_one_open ON net.road_verification (road_id) WHERE status = 'PENDING';
CREATE INDEX IF NOT EXISTS road_verification_requested_by_fkx ON net.road_verification (requested_by);
CREATE INDEX IF NOT EXISTS road_verification_decided_by_fkx ON net.road_verification (decided_by);
COMMENT ON TABLE net.road_verification IS 'Each step of a road''s verification, on a document, asked by one person of the platform and decided by another (1162, N38)';

CREATE TABLE IF NOT EXISTS net.road_correction (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid             uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  road_id         bigint NOT NULL REFERENCES net.road(id),
  point_id        bigint REFERENCES net.road_point(id),
  kind            text NOT NULL CHECK (kind IN ('PLACE', 'DISTANCE', 'REMARK')),
  place_id        bigint REFERENCES ref.place(id),
  km_from_previous numeric(7,1) CHECK (km_from_previous >= 0),
  remark          text NOT NULL CHECK (length(btrim(remark)) BETWEEN 5 AND 1000),
  company_id      bigint REFERENCES iam.company(id),
  status          text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'ACCEPTED', 'REJECTED')),
  proposed_by     bigint NOT NULL REFERENCES iam.app_user(id),
  proposed_at     timestamptz NOT NULL DEFAULT now(),
  reviewed_by     bigint REFERENCES iam.app_user(id),
  reviewed_at     timestamptz,
  review_note     text CHECK (length(review_note) <= 500),
  CHECK (kind <> 'PLACE' OR (point_id IS NOT NULL AND place_id IS NOT NULL)),
  CHECK (kind <> 'DISTANCE' OR (point_id IS NOT NULL AND km_from_previous IS NOT NULL)),
  CHECK (reviewed_by IS NULL OR reviewed_by IS DISTINCT FROM proposed_by),
  CHECK ((status = 'PENDING') = (reviewed_by IS NULL))
);
CREATE INDEX IF NOT EXISTS road_correction_road_id_fkx ON net.road_correction (road_id);
CREATE INDEX IF NOT EXISTS road_correction_point_id_fkx ON net.road_correction (point_id);
CREATE INDEX IF NOT EXISTS road_correction_place_id_fkx ON net.road_correction (place_id);
CREATE INDEX IF NOT EXISTS road_correction_company_id_fkx ON net.road_correction (company_id);
CREATE INDEX IF NOT EXISTS road_correction_proposed_by_fkx ON net.road_correction (proposed_by);
CREATE INDEX IF NOT EXISTS road_correction_reviewed_by_fkx ON net.road_correction (reviewed_by);
COMMENT ON TABLE net.road_correction IS 'A correction of the roads guide proposed by a carrier or the platform, reviewed by another person (1162, N38)';

DROP TRIGGER IF EXISTS road_updated ON net.road;
CREATE TRIGGER road_updated BEFORE UPDATE ON net.road FOR EACH ROW EXECUTE FUNCTION sys.tg_set_updated_at();
DROP TRIGGER IF EXISTS zz_audit_capture ON net.road;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR UPDATE OR DELETE ON net.road FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();
DROP TRIGGER IF EXISTS zz_audit_capture ON net.road_point;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR UPDATE OR DELETE ON net.road_point FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();

SELECT sys.rls('net.road', 'true', 'sys.ctx_is_platform()');
SELECT sys.rls('net.road_point', 'true', 'sys.ctx_is_platform()');
SELECT sys.rls('net.road_verification', 'sys.ctx_is_platform()', 'sys.ctx_is_platform()');
SELECT sys.rls('net.road_correction', 'sys.ctx_is_platform() OR sys.tenant_visible(company_id)', 'sys.ctx_is_platform() OR sys.tenant_visible(company_id)');
GRANT SELECT, INSERT, UPDATE ON net.road, net.road_point TO masslak_app;
GRANT SELECT ON net.road_verification, net.road_correction TO masslak_app;     -- written through the functions below
GRANT SELECT ON net.road, net.road_point TO masslak_readonly;

-- ------------------------------------------------------------------ junctions, worked out
CREATE OR REPLACE VIEW net.road_junction AS
  SELECT p.place_id, pl.pcode, pl.name_en, pl.name_ar, count(DISTINCT p.road_id) AS roads,
         array_agg(DISTINCT r.code ORDER BY r.code) AS road_codes
    FROM net.road_point p JOIN net.road r ON r.id = p.road_id AND r.status = 'ACTIVE' JOIN ref.place pl ON pl.id = p.place_id
   GROUP BY p.place_id, pl.pcode, pl.name_en, pl.name_ar
  HAVING count(DISTINCT p.road_id) > 1;
COMMENT ON VIEW net.road_junction IS 'The places on two roads or more: the junctions of the roads guide (1162)';
GRANT SELECT ON net.road_junction TO masslak_app, masslak_readonly;

-- a newer file with fewer points for a road: the points past its last are removed (the platform only)
CREATE OR REPLACE FUNCTION net.trim_road(p_road bigint, p_points int) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE n int;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: the platform loads the roads guide' USING ERRCODE = 'P0001';
  END IF;
  DELETE FROM net.road_point WHERE road_id = p_road AND seq > p_points;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION net.trim_road(bigint, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION net.trim_road(bigint, int) TO masslak_app;

-- ------------------------------------------------------------------ verification, four eyes
CREATE OR REPLACE FUNCTION net.request_road_verification(p_road text, p_to text, p_document text, p_note text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE r net.road; v uuid;
BEGIN
  IF NOT sys.ctx_is_platform() OR sys.ctx_user_id() IS NULL THEN
    RAISE EXCEPTION 'FORBIDDEN: the platform verifies roads' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO r FROM net.road WHERE code = p_road;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ROAD_UNKNOWN: no road %', p_road USING ERRCODE = 'P0001';
  END IF;
  IF r.verification_status = p_to THEN
    RAISE EXCEPTION 'ROAD_SAME: the road is already %', p_to USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM net.road_verification WHERE road_id = r.id AND status = 'PENDING') THEN
    RAISE EXCEPTION 'ROAD_WAITING: a verification of this road is waiting for a decision' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO net.road_verification (road_id, from_status, to_status, document_ref, note, requested_by)
  VALUES (r.id, r.verification_status, p_to, btrim(coalesce(p_document, '')), nullif(btrim(coalesce(p_note, '')), ''), sys.ctx_user_id())
  RETURNING uid INTO v;
  RETURN v;
END $$;
REVOKE ALL ON FUNCTION net.request_road_verification(text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION net.request_road_verification(text, text, text, text) TO masslak_app;
COMMENT ON FUNCTION net.request_road_verification IS 'Asks to raise (or lower) how far a road is verified, on a document; another person decides (1162, N38)';

CREATE OR REPLACE FUNCTION net.decide_road_verification(p_uid uuid, p_approve boolean, p_note text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v net.road_verification;
BEGIN
  IF NOT sys.ctx_is_platform() OR sys.ctx_user_id() IS NULL THEN
    RAISE EXCEPTION 'FORBIDDEN: the platform verifies roads' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v FROM net.road_verification WHERE uid = p_uid FOR UPDATE;
  IF NOT FOUND OR v.status <> 'PENDING' THEN
    RAISE EXCEPTION 'ROAD_NOT_PENDING: the verification is not waiting for a decision' USING ERRCODE = 'P0001';
  END IF;
  IF v.requested_by = sys.ctx_user_id() THEN
    RAISE EXCEPTION 'FOUR_EYES: another person decides the verification you asked for' USING ERRCODE = 'P0001';
  END IF;
  IF NOT p_approve AND length(btrim(coalesce(p_note, ''))) < 5 THEN
    RAISE EXCEPTION 'ROAD_NOTE: say why the verification is rejected' USING ERRCODE = 'P0001';
  END IF;
  UPDATE net.road_verification SET status = CASE WHEN p_approve THEN 'APPROVED' ELSE 'REJECTED' END, decided_by = sys.ctx_user_id(),
         decided_at = now(), decision_note = nullif(btrim(coalesce(p_note, '')), '')
   WHERE id = v.id;
  IF p_approve THEN
    UPDATE net.road SET verification_status = v.to_status WHERE id = v.road_id;
  END IF;
  RETURN CASE WHEN p_approve THEN 'APPROVED' ELSE 'REJECTED' END;
END $$;
REVOKE ALL ON FUNCTION net.decide_road_verification(uuid, boolean, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION net.decide_road_verification(uuid, boolean, text) TO masslak_app;
COMMENT ON FUNCTION net.decide_road_verification IS 'Another person of the platform approves the verification step (the road takes it) or rejects it with a reason (1162)';

-- ------------------------------------------------------------------ corrections
CREATE OR REPLACE FUNCTION net.propose_road_correction(p_road text, p_seq int, p_kind text, p_place text, p_km numeric, p_remark text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE r net.road; v_point bigint; v_place bigint; v uuid;
BEGIN
  IF sys.ctx_user_id() IS NULL OR NOT (sys.ctx_is_platform() OR sys.ctx_company_id() IS NOT NULL) THEN
    RAISE EXCEPTION 'FORBIDDEN: carriers and the platform propose corrections of the roads guide' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO r FROM net.road WHERE code = p_road AND status = 'ACTIVE';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ROAD_UNKNOWN: no road %', p_road USING ERRCODE = 'P0001';
  END IF;
  IF p_seq IS NOT NULL THEN
    SELECT id INTO v_point FROM net.road_point WHERE road_id = r.id AND seq = p_seq;
    IF v_point IS NULL THEN
      RAISE EXCEPTION 'ROAD_POINT_UNKNOWN: road % has no point %', p_road, p_seq USING ERRCODE = 'P0001';
    END IF;
  END IF;
  IF p_kind = 'PLACE' THEN
    v_place := ref.code_entity('PLACE', p_place);
    IF v_place IS NULL OR NOT EXISTS (SELECT 1 FROM ref.place WHERE id = v_place AND status = 'ACTIVE') THEN
      RAISE EXCEPTION 'PLACE_UNKNOWN: no active place %', p_place USING ERRCODE = 'P0001';
    END IF;
  END IF;
  IF p_kind IN ('PLACE', 'DISTANCE') AND v_point IS NULL THEN
    RAISE EXCEPTION 'ROAD_POINT_REQUIRED: say which point of the road is corrected' USING ERRCODE = 'P0001';
  END IF;
  IF p_kind = 'DISTANCE' AND (p_km IS NULL OR p_seq = 1) THEN
    RAISE EXCEPTION 'ROAD_DISTANCE: give the distance from the point before (not for the first point)' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO net.road_correction (road_id, point_id, kind, place_id, km_from_previous, remark, company_id, proposed_by)
  VALUES (r.id, v_point, p_kind, v_place, CASE WHEN p_kind = 'DISTANCE' THEN p_km END, btrim(coalesce(p_remark, '')),
          CASE WHEN NOT sys.ctx_is_platform() THEN sys.ctx_company_id() END, sys.ctx_user_id())
  RETURNING uid INTO v;
  RETURN v;
END $$;
REVOKE ALL ON FUNCTION net.propose_road_correction(text, int, text, text, numeric, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION net.propose_road_correction(text, int, text, text, numeric, text) TO masslak_app;
COMMENT ON FUNCTION net.propose_road_correction IS 'A carrier or the platform proposes a correction of a road: a point''s place, a distance, or a remark (1162, N38)';

-- the distances from the start of a road, after a point moved or a distance changed
CREATE OR REPLACE FUNCTION net.road_recount(p_road bigint) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  UPDATE net.road_point p SET km_cumulative = s.km
    FROM (SELECT id, sum(km_from_previous) OVER (ORDER BY seq) AS km FROM net.road_point WHERE road_id = p_road) s
   WHERE p.id = s.id AND p.km_cumulative IS DISTINCT FROM s.km;
  UPDATE net.road r SET length_km = (SELECT max(km_cumulative) FROM net.road_point WHERE road_id = p_road) WHERE r.id = p_road;
$$;
REVOKE ALL ON FUNCTION net.road_recount(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION net.road_recount(bigint) TO masslak_app;          -- idempotent: the running totals of one road

CREATE OR REPLACE FUNCTION net.review_road_correction(p_uid uuid, p_accept boolean, p_note text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE c net.road_correction; p ref.place;
BEGIN
  IF NOT sys.ctx_is_platform() OR sys.ctx_user_id() IS NULL THEN
    RAISE EXCEPTION 'FORBIDDEN: the platform reviews corrections of the roads guide' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO c FROM net.road_correction WHERE uid = p_uid FOR UPDATE;
  IF NOT FOUND OR c.status <> 'PENDING' THEN
    RAISE EXCEPTION 'CORRECTION_NOT_PENDING: the correction is not waiting for review' USING ERRCODE = 'P0001';
  END IF;
  IF c.proposed_by = sys.ctx_user_id() THEN
    RAISE EXCEPTION 'FOUR_EYES: another person reviews the correction you proposed' USING ERRCODE = 'P0001';
  END IF;
  IF NOT p_accept AND length(btrim(coalesce(p_note, ''))) < 5 THEN
    RAISE EXCEPTION 'CORRECTION_NOTE: say why the correction is rejected' USING ERRCODE = 'P0001';
  END IF;
  UPDATE net.road_correction SET status = CASE WHEN p_accept THEN 'ACCEPTED' ELSE 'REJECTED' END, reviewed_by = sys.ctx_user_id(),
         reviewed_at = now(), review_note = nullif(btrim(coalesce(p_note, '')), '')
   WHERE id = c.id;
  IF p_accept AND c.kind = 'PLACE' THEN
    SELECT * INTO p FROM ref.place WHERE id = c.place_id;
    UPDATE net.road_point SET place_id = p.id, lat = p.lat, lng = p.lng WHERE id = c.point_id;
  ELSIF p_accept AND c.kind = 'DISTANCE' THEN
    UPDATE net.road_point SET km_from_previous = c.km_from_previous WHERE id = c.point_id;
    PERFORM net.road_recount(c.road_id);
  END IF;
  RETURN CASE WHEN p_accept THEN 'ACCEPTED' ELSE 'REJECTED' END;
END $$;
REVOKE ALL ON FUNCTION net.review_road_correction(uuid, boolean, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION net.review_road_correction(uuid, boolean, text) TO masslak_app;
COMMENT ON FUNCTION net.review_road_correction IS 'Another person accepts a correction (a place or a distance is applied to the point) or rejects it with a reason (1162, N38)';

-- ------------------------------------------------------------------ registration
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('net.road', '1A', 'E04'), ('net.road_point', '1A', 'E04'), ('net.road_verification', '1A', 'E04'), ('net.road_correction', '1A', 'E04')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
SELECT sys.refresh_table_class();
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('net.road', 'net records', 'numbered roads of the roads guide (1162)'),
  ('net.road_point', 'net records', 'places along the roads, in order (1162)'),
  ('net.road_verification', 'net records', 'verification steps of the roads, four eyes (1162)'),
  ('net.road_correction', 'net records', 'corrections of the roads guide proposed by carriers and the platform (1162)')
ON CONFLICT (table_name) DO NOTHING;
