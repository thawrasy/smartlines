-- =====================================================================
-- 1127  Corrected names of places and areas (owner's request, October 2026)
-- =====================================================================
-- The owner corrected English names as published in the United Nations file to the spellings accepted locally and
-- internationally: "Quamishli" is Qamishli, "Tadmor" is Palmyra, "Lattakia" Latakia, "Idleb" Idlib, and so on. A correction is a rule the platform keeps (ref.name_correction): a word, in English or
-- Arabic, replaced by another in the names of the areas and places under an area (a district, or the whole country)
-- or of one place,
-- so it holds for every place that carries the word and is applied again to every newer file loaded. Each place and
-- area keeps the name as published (published_en, published_ar), still found by search; the name shown (name_en,
-- name_ar) is the published one with the corrections applied. The cities of the network take their place's name.

ALTER TABLE ref.place ADD COLUMN IF NOT EXISTS published_en text;
ALTER TABLE ref.place ADD COLUMN IF NOT EXISTS published_ar text;
ALTER TABLE ref.admin_area ADD COLUMN IF NOT EXISTS published_en text;
ALTER TABLE ref.admin_area ADD COLUMN IF NOT EXISTS published_ar text;
COMMENT ON COLUMN ref.place.published_en IS 'The English name as the source published it; name_en is it with the platform''s corrections (1127)';
COMMENT ON COLUMN ref.place.published_ar IS 'The Arabic name as the source published it; name_ar is it with the platform''s corrections (1127)';
COMMENT ON COLUMN ref.admin_area.published_en IS 'The English name as the source published it; name_en is it with the platform''s corrections (1127)';
COMMENT ON COLUMN ref.admin_area.published_ar IS 'The Arabic name as the source published it; name_ar is it with the platform''s corrections (1127)';

CREATE TABLE IF NOT EXISTS ref.name_correction (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  lang        text NOT NULL CHECK (lang IN ('en', 'ar')),
  wrong       text NOT NULL CHECK (wrong ~ '^[[:alpha:]][[:alpha:] ''-]{0,58}[[:alpha:]]$'),
  correct     text NOT NULL CHECK (length(btrim(correct)) BETWEEN 1 AND 80 AND correct !~ '[\\$]'),
  scope_pcode text CHECK (scope_pcode ~ '^[A-Z]{2}([0-9]{2}){0,3}$' OR scope_pcode ~ '^[A-Z][0-9]{3,7}$'),   -- an area it holds under, or one place; the country by default
  reason      text NOT NULL CHECK (length(btrim(reason)) BETWEEN 3 AND 300),
  status      text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'REMOVED')),
  set_by      bigint REFERENCES iam.app_user(id),
  set_at      timestamptz NOT NULL DEFAULT now(),
  CHECK (wrong <> correct)
);
CREATE UNIQUE INDEX IF NOT EXISTS name_correction_uq ON ref.name_correction (lang, wrong, coalesce(scope_pcode, '')) WHERE status = 'ACTIVE';
CREATE INDEX IF NOT EXISTS name_correction_set_by_fkx ON ref.name_correction (set_by);
COMMENT ON TABLE ref.name_correction IS 'Words of the published names the platform writes otherwise, in the areas under a code (1127)';
SELECT sys.rls_catalog('ref.name_correction');
GRANT SELECT, INSERT, UPDATE ON ref.name_correction TO masslak_app;
GRANT SELECT ON ref.name_correction TO masslak_readonly, masslak_auditor;

-- a name with the corrections that hold where it is: whole words only, in the order they were set
CREATE OR REPLACE FUNCTION ref.corrected(p_name text, p_lang text, p_area text, p_place text DEFAULT NULL) RETURNS text
LANGUAGE plpgsql STABLE SET search_path = pg_catalog, pg_temp AS $$
DECLARE c record; v text := p_name;
BEGIN
  IF v IS NULL THEN RETURN NULL; END IF;
  FOR c IN SELECT wrong, correct FROM ref.name_correction
            WHERE status = 'ACTIVE' AND lang = p_lang
              AND (scope_pcode IS NULL OR scope_pcode = p_place
                   OR (scope_pcode ~ '^[A-Z]{2}' AND left(coalesce(p_area, ''), length(scope_pcode)) = scope_pcode))
            ORDER BY id LOOP
    v := regexp_replace(v, '(^|[^[:alpha:]])' || c.wrong || '(?=[^[:alpha:]]|$)', '\1' || c.correct, 'g');
  END LOOP;
  RETURN v;
END $$;
GRANT EXECUTE ON FUNCTION ref.corrected(text, text, text, text) TO masslak_app;
COMMENT ON FUNCTION ref.corrected IS 'A published name with the platform''s corrections for the area it is in, or for the place itself (1127)';

-- whatever writes a name writes the published one: the name shown follows from it
CREATE OR REPLACE FUNCTION ref.tg_place_name() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_area text; v_place text;
BEGIN
  IF TG_OP = 'INSERT' OR NEW.published_en IS NULL OR NEW.name_en IS DISTINCT FROM OLD.name_en THEN
    NEW.published_en := NEW.name_en;
  END IF;
  IF TG_OP = 'INSERT' OR NEW.published_ar IS NULL OR NEW.name_ar IS DISTINCT FROM OLD.name_ar THEN
    NEW.published_ar := NEW.name_ar;
  END IF;
  IF TG_TABLE_NAME = 'place' THEN
    v_area := (SELECT pcode FROM ref.admin_area WHERE id = (to_jsonb(NEW) ->> 'area_id')::bigint);
    v_place := NEW.pcode;
  ELSE
    v_area := NEW.pcode;
  END IF;
  NEW.name_en := ref.corrected(NEW.published_en, 'en', v_area, v_place);
  NEW.name_ar := ref.corrected(NEW.published_ar, 'ar', v_area, v_place);
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS place_name ON ref.place;
CREATE TRIGGER place_name BEFORE INSERT OR UPDATE ON ref.place FOR EACH ROW EXECUTE FUNCTION ref.tg_place_name();
DROP TRIGGER IF EXISTS admin_area_name ON ref.admin_area;
CREATE TRIGGER admin_area_name BEFORE INSERT OR UPDATE ON ref.admin_area FOR EACH ROW EXECUTE FUNCTION ref.tg_place_name();

-- the corrections applied again (after a rule changes, and after each load): names recomputed from the published ones,
-- and the cities of the network named as their places
CREATE OR REPLACE FUNCTION ref.apply_name_corrections() RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE n int; m int;
BEGIN
  -- writing the published name back as the name recomputes it (the trigger reads a changed name as the published one)
  UPDATE ref.admin_area a SET name_en = a.published_en, name_ar = a.published_ar
   WHERE (a.name_en, a.name_ar) IS DISTINCT FROM (ref.corrected(a.published_en, 'en', a.pcode), ref.corrected(a.published_ar, 'ar', a.pcode));
  GET DIAGNOSTICS n = ROW_COUNT;
  UPDATE ref.place p SET name_en = p.published_en, name_ar = p.published_ar
    FROM ref.admin_area a
   WHERE a.id = p.area_id
     AND (p.name_en, p.name_ar) IS DISTINCT FROM (ref.corrected(p.published_en, 'en', a.pcode, p.pcode), ref.corrected(p.published_ar, 'ar', a.pcode, p.pcode));
  GET DIAGNOSTICS m = ROW_COUNT;
  UPDATE ref.city c SET name = p.name_en FROM ref.place p WHERE p.id = c.place_id AND c.name IS DISTINCT FROM p.name_en
     AND p.published_en IS DISTINCT FROM p.name_en;
  RETURN n + m;
END $$;
REVOKE ALL ON FUNCTION ref.apply_name_corrections() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ref.apply_name_corrections() TO masslak_app;

CREATE OR REPLACE FUNCTION ref.set_name_correction(p_lang text, p_wrong text, p_correct text, p_scope text, p_reason text) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: the platform corrects the names of places' USING ERRCODE = 'P0001';
  END IF;
  IF p_scope IS NOT NULL AND NOT EXISTS (SELECT 1 FROM ref.admin_area WHERE pcode = p_scope)
     AND NOT EXISTS (SELECT 1 FROM ref.place WHERE pcode = p_scope) AND p_scope !~ '^[A-Z]{2}$' THEN
    RAISE EXCEPTION 'PLACE_AREA: no area %', p_scope USING ERRCODE = 'P0001';
  END IF;
  UPDATE ref.name_correction SET status = 'REMOVED'
   WHERE status = 'ACTIVE' AND lang = p_lang AND wrong = btrim(p_wrong) AND scope_pcode IS NOT DISTINCT FROM p_scope;
  INSERT INTO ref.name_correction (lang, wrong, correct, scope_pcode, reason, set_by)
  VALUES (p_lang, btrim(p_wrong), btrim(p_correct), p_scope, btrim(p_reason), sys.ctx_user_id());
  RETURN ref.apply_name_corrections();
END $$;
REVOKE ALL ON FUNCTION ref.set_name_correction(text, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ref.set_name_correction(text, text, text, text, text) TO masslak_app;
COMMENT ON FUNCTION ref.set_name_correction IS 'Sets a correction of a word in the names under an area and applies it; platform only (1127)';

CREATE OR REPLACE FUNCTION ref.remove_name_correction(p_id bigint) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: the platform corrects the names of places' USING ERRCODE = 'P0001';
  END IF;
  UPDATE ref.name_correction SET status = 'REMOVED' WHERE id = p_id AND status = 'ACTIVE';
  RETURN ref.apply_name_corrections();
END $$;
REVOKE ALL ON FUNCTION ref.remove_name_correction(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ref.remove_name_correction(bigint) TO masslak_app;

-- a place's way up also gives its name as published, when the platform corrected it
CREATE OR REPLACE FUNCTION ref.place_path(p_place bigint) RETURNS jsonb
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT jsonb_build_object(
           'pcode', p.pcode, 'kind', p.kind, 'name_en', p.name_en, 'name_ar', p.name_ar, 'lat', p.lat, 'lng', p.lng,
           'published_en', CASE WHEN p.published_en IS DISTINCT FROM p.name_en THEN p.published_en END,
           'published_ar', CASE WHEN p.published_ar IS DISTINCT FROM p.name_ar THEN p.published_ar END,
           'city', CASE WHEN c.id IS NOT NULL THEN jsonb_build_object('pcode', c.pcode, 'name_en', c.name_en, 'name_ar', c.name_ar) END,
           'sub_district', jsonb_build_object('pcode', a3.pcode, 'name_en', a3.name_en, 'name_ar', a3.name_ar),
           'district', jsonb_build_object('pcode', a2.pcode, 'name_en', a2.name_en, 'name_ar', a2.name_ar),
           'governorate', jsonb_build_object('pcode', a1.pcode, 'name_en', a1.name_en, 'name_ar', a1.name_ar),
           'served', (SELECT k.code FROM ref.city k WHERE k.place_id = p.id))
    FROM ref.place p
    LEFT JOIN ref.place c ON c.id = p.parent_place_id
    JOIN ref.admin_area a3 ON a3.id = p.area_id
    JOIN ref.admin_area a2 ON a2.id = a3.parent_id
    JOIN ref.admin_area a1 ON a1.id = a2.parent_id
   WHERE p.id = p_place
$$;

-- the names as published, for what is already loaded
UPDATE ref.admin_area SET published_en = name_en, published_ar = name_ar WHERE published_en IS NULL;
UPDATE ref.place SET published_en = name_en, published_ar = name_ar WHERE published_en IS NULL;

-- the owner's corrections: the English spellings accepted locally and internationally. Each holds in the area of the
-- place it names (a district or a governorate), or the whole country for the governorates' names. Palmyra is the city
-- of Tadmor alone (C2889): its district and sub-district keep the name Tadmor, and "Bab Tadmor", a neighbourhood of
-- Homs named after the gate, keeps its name.
INSERT INTO ref.name_correction (lang, wrong, correct, scope_pcode, reason)
SELECT v.lang, v.wrong, v.correct, v.scope, v.reason FROM (VALUES
  ('en', 'Quamishli', 'Qamishli', 'SY0802', 'Owner''s request: the spelling accepted locally and internationally'),
  ('en', 'Tadmor', 'Palmyra', 'C2889', 'Owner''s request: the spelling accepted locally and internationally'),
  ('en', 'Lattakia', 'Latakia', NULL, 'Owner''s request: the spelling accepted locally and internationally'),
  ('en', 'Idleb', 'Idlib', NULL, 'Owner''s request: the spelling accepted locally and internationally'),
  ('en', 'Al-Hasakeh', 'Al-Hasakah', NULL, 'Owner''s request: the spelling accepted locally and internationally'),
  ('en', 'Deir-ez-Zor', 'Deir ez-Zor', NULL, 'Owner''s request: the spelling accepted locally and internationally'),
  ('en', 'Tartous', 'Tartus', NULL, 'Owner''s request: the spelling accepted locally and internationally'),
  ('en', 'Ar-Raqqa', 'Raqqa', NULL, 'Owner''s request: the spelling accepted locally and internationally'),
  ('en', 'Dar''a', 'Daraa', NULL, 'Owner''s request: the spelling accepted locally and internationally'),
  ('en', 'As-Sweida', 'As-Suwayda', NULL, 'Owner''s request: the spelling accepted locally and internationally'),
  ('en', 'Menbij', 'Manbij', 'SY0205', 'Owner''s request: the spelling accepted locally and internationally'),
  ('en', 'A''zaz', 'Azaz', 'SY0204', 'Owner''s request: the spelling accepted locally and internationally'),
  ('en', 'Jisr-Ash-Shugur', 'Jisr al-Shughur', 'SY0704', 'Owner''s request: the spelling accepted locally and internationally'),
  ('en', 'Al Ma''ra', 'Maarat al-Numan', 'SY0702', 'Owner''s request: the spelling accepted locally and internationally'),
  ('en', 'Ma''arrat An Nu''man', 'Maarat al-Numan', 'SY0702', 'Owner''s request: the spelling accepted locally and internationally'),
  ('en', 'Khan Shaykun', 'Khan Shaykhun', 'SY0702', 'Owner''s request: the spelling accepted locally and internationally'),
  ('en', 'Ras Al Ain', 'Ras al-Ayn', 'SY0804', 'Owner''s request: the spelling accepted locally and internationally'),
  ('en', 'Tell Abiad', 'Tell Abyad', 'SY1102', 'Owner''s request: the spelling accepted locally and internationally'),
  ('en', 'Duma', 'Douma', 'SY0302', 'Owner''s request: the spelling accepted locally and internationally'),
  ('en', 'Az-Zabdani', 'Zabadani', 'SY0307', 'Owner''s request: the spelling accepted locally and internationally'),
  ('en', 'Ma''loula', 'Maaloula', 'SY0303', 'Owner''s request: the spelling accepted locally and internationally'),
  ('en', 'Sidnaya', 'Saydnaya', 'SY0304', 'Owner''s request: the spelling accepted locally and internationally'),
  ('en', 'Busra Esh-Sham', 'Bosra', 'SY12', 'Owner''s request: the spelling accepted locally and internationally'),
  ('en', 'As-Salamiyeh', 'Salamiyah', 'SY0503', 'Owner''s request: the spelling accepted locally and internationally')
) AS v(lang, wrong, correct, scope, reason)
 WHERE NOT EXISTS (SELECT 1 FROM ref.name_correction c WHERE c.lang = v.lang AND c.wrong = v.wrong AND c.status = 'ACTIVE');
SELECT ref.apply_name_corrections();

INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('ref.name_correction', '1A', 'E03')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
SELECT sys.refresh_table_class();
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('ref.name_correction', 'ref catalog', 'corrections of the published names of places and areas (1127)')
ON CONFLICT (table_name) DO NOTHING;
