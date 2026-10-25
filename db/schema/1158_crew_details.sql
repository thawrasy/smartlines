-- =====================================================================
-- 1158: driver and crew details (owner's request N3)
--   * A driver, host or assistant is entered with their name in parts (1149) and a national number. The number is
--     encrypted on the person, with a blind index and the last four characters.
--   * Each one carries licences: driving (with its class), the transport authority's licence and the traffic
--     department's permit. Each licence has its number, issuer, dates and pictures of its two faces.
--   * Which licences a crew member must hold is a platform setting (crew.licences). Whether a crew member is refused on
--     a trip when a required licence is missing, or has run out, are two more switches, both off at launch. The screens
--     warn in any case.
-- =====================================================================

-- the traffic department's permit, and the class written on a driving licence
ALTER TABLE fleet.license_record DROP CONSTRAINT IF EXISTS license_record_license_type_check;
ALTER TABLE fleet.license_record ADD CONSTRAINT license_record_license_type_check CHECK (license_type IN (
  'TRANSPORT', 'INSPECTION', 'INSURANCE', 'DRIVING', 'MEDICAL', 'CR', 'STATION', 'HEAVY_DRIVING', 'CROSS_BORDER', 'HAZMAT', 'TAXI',
  'ROUTE_PERMIT', 'SCHOOL_TRANSPORT', 'CRIMINAL_RECORD', 'FIRST_AID', 'TRACKING_DEVICE', 'TRAFFIC', 'OTHER'));
ALTER TABLE fleet.license_record ADD COLUMN IF NOT EXISTS license_class text;
ALTER TABLE fleet.license_record DROP CONSTRAINT IF EXISTS license_record_class_ck;
ALTER TABLE fleet.license_record ADD CONSTRAINT license_record_class_ck
  CHECK (license_class IS NULL OR license_class ~ '^[A-Z0-9][A-Z0-9 +-]{0,15}$');
ALTER TABLE fleet.license_record ADD COLUMN IF NOT EXISTS uid uuid NOT NULL DEFAULT gen_random_uuid();
CREATE UNIQUE INDEX IF NOT EXISTS license_record_uid_uq ON fleet.license_record (uid);
ALTER TABLE fleet.license_record ADD COLUMN IF NOT EXISTS back_document_id bigint REFERENCES iam.document(id);
CREATE INDEX IF NOT EXISTS license_record_back_document_id_fkx ON fleet.license_record (back_document_id);
COMMENT ON COLUMN fleet.license_record.license_class IS 'The class written on a driving licence (for example B, C, D, E) (1158, N3)';
COMMENT ON COLUMN fleet.license_record.document_id IS 'The picture of the licence''s front face (or the only one)';
COMMENT ON COLUMN fleet.license_record.back_document_id IS 'The picture of the licence''s back face (1158, N3)';

INSERT INTO sys.setting (key, value, description) VALUES
  ('crew.licences', jsonb_build_object(
     'required', jsonb_build_object('DRIVER', jsonb_build_array('DRIVING'), 'HOST', jsonb_build_array(), 'ASSISTANT', jsonb_build_array()),
     'refuse_missing', false, 'refuse_expired', false),
   'Licences each crew kind must hold (N3, 1158): which ones are required; whether a crew member missing one, or whose required licence has run out, is refused on a trip (both off at launch: the screens warn)')
ON CONFLICT (key) DO NOTHING;

-- what stands between a crew member and a trip on a given day
CREATE OR REPLACE FUNCTION fleet.crew_licence_problems(p_party bigint, p_on date) RETURNS text[]
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce(array_agg(problem ORDER BY problem), '{}')
    FROM (
      SELECT CASE
               WHEN NOT EXISTS (SELECT 1 FROM fleet.license_record l WHERE l.subject_type = 'DRIVER' AND l.subject_id = cp.party_id
                                   AND l.license_type = req.t AND l.status <> 'SUSPENDED') THEN 'MISSING:' || req.t
               WHEN NOT EXISTS (SELECT 1 FROM fleet.license_record l WHERE l.subject_type = 'DRIVER' AND l.subject_id = cp.party_id
                                   AND l.license_type = req.t AND l.status <> 'SUSPENDED' AND l.expiry_date >= p_on) THEN 'EXPIRED:' || req.t
             END AS problem
        FROM fleet.crew_profile cp
        CROSS JOIN LATERAL jsonb_array_elements_text(
          coalesce((SELECT value -> 'required' -> cp.crew_type FROM sys.setting WHERE key = 'crew.licences'), '[]')) AS req(t)
       WHERE cp.party_id = p_party) x
   WHERE problem IS NOT NULL
$$;
COMMENT ON FUNCTION fleet.crew_licence_problems IS 'Required licences a crew member lacks (MISSING:type) or that have run out by the date (EXPIRED:type) (1158, N3)';

-- refusing a crew member on a trip follows the two switches
CREATE OR REPLACE FUNCTION ops.tg_crew_licences() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_conf jsonb; v_problems text[]; v_day date;
BEGIN
  SELECT value INTO v_conf FROM sys.setting WHERE key = 'crew.licences';
  IF v_conf IS NULL OR NOT (coalesce((v_conf ->> 'refuse_missing')::boolean, false) OR coalesce((v_conf ->> 'refuse_expired')::boolean, false)) THEN
    RETURN NEW;
  END IF;
  SELECT (t.departure_at AT TIME ZONE 'UTC')::date INTO v_day FROM ops.trip t WHERE t.id = NEW.trip_id;
  v_problems := ARRAY(SELECT p FROM unnest(fleet.crew_licence_problems(NEW.party_id, coalesce(v_day, current_date))) p
                       WHERE (p LIKE 'MISSING:%' AND (v_conf ->> 'refuse_missing')::boolean)
                          OR (p LIKE 'EXPIRED:%' AND (v_conf ->> 'refuse_expired')::boolean));
  IF cardinality(v_problems) > 0 THEN
    RAISE EXCEPTION 'CREW_LICENCE: %', array_to_string(v_problems, ', ') USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS crew_licences ON ops.crew_assignment;
CREATE TRIGGER crew_licences BEFORE INSERT OR UPDATE OF party_id, trip_id ON ops.crew_assignment
  FOR EACH ROW EXECUTE FUNCTION ops.tg_crew_licences();
