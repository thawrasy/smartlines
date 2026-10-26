-- =====================================================================
-- 1161: codes that can be changed, with the change cascading down and the old codes kept (owner's request N39)
--   * Every area, place, city and station keeps its internal id; every link uses the id, so a new code breaks nothing.
--   * A code changes through a request: the platform previews every code it touches, then a second person approves
--     it; it takes effect on its date (at once when the date has come). Nobody writes a code directly.
--   * A governorate's new code is carried to the districts and sub-districts under it (SY14 -> SY20 makes SY1401 ->
--     SY2001), a city's to its stations (DAM -> DMS makes SY-DAM-C001 -> SY-DMS-C001). Communities and neighbourhoods
--     (C..., N...) are not prefixed by their area in the United Nations scheme, so they are re-coded one by one.
--   * A request is refused when any new code is taken, now or as an old code of something else.
--   * Old codes stay as aliases (net.code_history): search and later loads by an old code still find the thing, and
--     ref.code_on gives the code a thing had on a date. Recorded data (tickets, trip references, manifests, invoices)
--     keeps the code it was issued with.
--   * The requests and old codes live in net (which already leans on ref) because they point at stations as well as
--     areas, places and cities; the functions are in ref with the rest of the geography.
-- =====================================================================

CREATE TABLE IF NOT EXISTS net.code_change (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid             uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  entity_kind     text NOT NULL CHECK (entity_kind IN ('AREA', 'PLACE', 'CITY', 'STATION')),
  area_id         bigint REFERENCES ref.admin_area(id),
  place_id        bigint REFERENCES ref.place(id),
  city_id         bigint REFERENCES ref.city(id),
  station_id      bigint REFERENCES net.station(id),
  old_code        text NOT NULL,
  new_code        text NOT NULL,
  reason          text NOT NULL CHECK (length(btrim(reason)) BETWEEN 5 AND 500),
  source_document text CHECK (length(source_document) <= 300),
  effective_on    date NOT NULL,
  plan            jsonb NOT NULL CHECK (jsonb_typeof(plan) = 'array'),
  status          text NOT NULL DEFAULT 'PENDING'
                  CHECK (status IN ('PENDING', 'APPROVED', 'APPLYING', 'APPLIED', 'REJECTED', 'CANCELLED', 'FAILED')),
  requested_by    bigint NOT NULL REFERENCES iam.app_user(id),
  requested_at    timestamptz NOT NULL DEFAULT now(),
  decided_by      bigint REFERENCES iam.app_user(id),
  decided_at      timestamptz,
  decision_note   text CHECK (length(decision_note) <= 500),
  applied_at      timestamptz,
  failure         text CHECK (length(failure) <= 500),
  CHECK (num_nonnulls(area_id, place_id, city_id, station_id) = 1),
  CHECK (CASE entity_kind WHEN 'AREA' THEN area_id WHEN 'PLACE' THEN place_id WHEN 'CITY' THEN city_id ELSE station_id END IS NOT NULL),
  CHECK (old_code <> new_code),
  CHECK (decided_by IS NULL OR decided_by IS DISTINCT FROM requested_by),
  CHECK (status NOT IN ('APPROVED', 'APPLYING', 'APPLIED', 'REJECTED') OR decided_by IS NOT NULL),
  CHECK ((status = 'APPLIED') = (applied_at IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS code_change_area_id_fkx ON net.code_change (area_id);
CREATE INDEX IF NOT EXISTS code_change_place_id_fkx ON net.code_change (place_id);
CREATE INDEX IF NOT EXISTS code_change_city_id_fkx ON net.code_change (city_id);
CREATE INDEX IF NOT EXISTS code_change_station_id_fkx ON net.code_change (station_id);
CREATE INDEX IF NOT EXISTS code_change_requested_by_fkx ON net.code_change (requested_by);
CREATE INDEX IF NOT EXISTS code_change_decided_by_fkx ON net.code_change (decided_by);
CREATE INDEX IF NOT EXISTS code_change_due_idx ON net.code_change (effective_on) WHERE status = 'APPROVED';
COMMENT ON TABLE net.code_change IS 'Requests to change the code of an area, place, city or station: the codes they touch, a second person''s decision, the date they take effect (1161, N39)';
COMMENT ON COLUMN net.code_change.plan IS 'Every code the change touches, the thing itself and what it cascades to: [{kind, id, old, new, name}] (1161)';
COMMENT ON COLUMN net.code_change.decided_by IS 'The person who approved or rejected the change: never the one who asked for it (1161)';

CREATE TABLE IF NOT EXISTS net.code_history (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_kind     text NOT NULL CHECK (entity_kind IN ('AREA', 'PLACE', 'CITY', 'STATION')),
  area_id         bigint REFERENCES ref.admin_area(id),
  place_id        bigint REFERENCES ref.place(id),
  city_id         bigint REFERENCES ref.city(id),
  station_id      bigint REFERENCES net.station(id),
  code            text NOT NULL,
  valid_from      timestamptz,
  valid_to        timestamptz NOT NULL,
  change_id       bigint NOT NULL REFERENCES net.code_change(id),
  CHECK (num_nonnulls(area_id, place_id, city_id, station_id) = 1),
  CHECK (CASE entity_kind WHEN 'AREA' THEN area_id WHEN 'PLACE' THEN place_id WHEN 'CITY' THEN city_id ELSE station_id END IS NOT NULL),
  CHECK (valid_from IS NULL OR valid_from < valid_to)
);
CREATE INDEX IF NOT EXISTS code_history_area_id_fkx ON net.code_history (area_id);
CREATE INDEX IF NOT EXISTS code_history_place_id_fkx ON net.code_history (place_id);
CREATE INDEX IF NOT EXISTS code_history_city_id_fkx ON net.code_history (city_id);
CREATE INDEX IF NOT EXISTS code_history_station_id_fkx ON net.code_history (station_id);
CREATE INDEX IF NOT EXISTS code_history_change_id_fkx ON net.code_history (change_id);
CREATE INDEX IF NOT EXISTS code_history_code_idx ON net.code_history (entity_kind, code);
COMMENT ON TABLE net.code_history IS 'The codes a thing had before: kept as aliases, so an old code still finds it, and dated, so a report shows the code of its day (1161, N39)';

SELECT sys.rls('net.code_change', 'sys.ctx_is_platform()', 'sys.ctx_is_platform()');
SELECT sys.rls('net.code_history', 'true', 'sys.ctx_is_platform()');
GRANT SELECT ON net.code_change TO masslak_app, masslak_readonly;            -- written through the functions below only
GRANT SELECT ON net.code_history TO masslak_app, masslak_readonly;
DROP TRIGGER IF EXISTS zz_audit_capture ON net.code_change;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR UPDATE OR DELETE ON net.code_change
  FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();

-- ------------------------------------------------------------------ finding a thing by its code, old or new
CREATE OR REPLACE FUNCTION ref.code_entity(p_kind text, p_code text) RETURNS bigint
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce(
    CASE p_kind WHEN 'AREA' THEN (SELECT id FROM ref.admin_area WHERE pcode = p_code)
                WHEN 'PLACE' THEN (SELECT id FROM ref.place WHERE pcode = p_code)
                WHEN 'CITY' THEN (SELECT id FROM ref.city WHERE code = p_code)
                WHEN 'STATION' THEN (SELECT id FROM net.station WHERE code = p_code) END,
    (SELECT coalesce(h.area_id, h.place_id, h.city_id, h.station_id) FROM net.code_history h
      WHERE h.entity_kind = p_kind AND h.code = p_code ORDER BY h.valid_to DESC LIMIT 1))
$$;
COMMENT ON FUNCTION ref.code_entity IS 'The id of the area, place, city or station that has a code now or had it before (1161)';

CREATE OR REPLACE FUNCTION ref.entity_code(p_kind text, p_id bigint) RETURNS text
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT CASE p_kind WHEN 'AREA' THEN (SELECT pcode FROM ref.admin_area WHERE id = p_id)
                     WHEN 'PLACE' THEN (SELECT pcode FROM ref.place WHERE id = p_id)
                     WHEN 'CITY' THEN (SELECT code FROM ref.city WHERE id = p_id)
                     WHEN 'STATION' THEN (SELECT code FROM net.station WHERE id = p_id) END
$$;

-- the code in use for a code given: itself when current or unknown, the thing's current code when it is an old one
CREATE OR REPLACE FUNCTION ref.current_code(p_kind text, p_code text) RETURNS text
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce(ref.entity_code(p_kind, ref.code_entity(p_kind, p_code)), p_code)
$$;
COMMENT ON FUNCTION ref.current_code IS 'The current code of what an old code named; the code itself when it is current or unknown (1161)';

-- the code a thing had on a date
CREATE OR REPLACE FUNCTION ref.code_on(p_kind text, p_id bigint, p_at timestamptz) RETURNS text
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce(
    (SELECT h.code FROM net.code_history h
      WHERE h.entity_kind = p_kind AND coalesce(h.area_id, h.place_id, h.city_id, h.station_id) = p_id
        AND (h.valid_from IS NULL OR h.valid_from <= p_at) AND h.valid_to > p_at
      ORDER BY h.valid_to LIMIT 1),
    ref.entity_code(p_kind, p_id))
$$;
COMMENT ON FUNCTION ref.code_on IS 'The code an area, place, city or station had at a time: for reports by date (1161)';

-- the old codes every load of the United Nations file reads through (areas and places)
CREATE OR REPLACE FUNCTION ref.code_aliases(p_kind text) RETURNS TABLE (old_code text, current_code text)
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT DISTINCT ON (h.code) h.code, ref.entity_code(h.entity_kind, coalesce(h.area_id, h.place_id, h.city_id, h.station_id))
    FROM net.code_history h WHERE h.entity_kind = p_kind ORDER BY h.code, h.valid_to DESC
$$;
GRANT EXECUTE ON FUNCTION ref.code_entity(text, text), ref.entity_code(text, bigint), ref.current_code(text, text),
  ref.code_on(text, bigint, timestamptz), ref.code_aliases(text) TO masslak_app, masslak_readonly;

-- ------------------------------------------------------------------ what a change touches
-- {kind, id, old, new, items: [{kind, id, old, new, name}], conflicts: [{code, problem}]}; raises on a malformed code
CREATE OR REPLACE FUNCTION ref.code_plan(p_kind text, p_code text, p_new text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v_id bigint; v_old text; v_new text := upper(btrim(coalesce(p_new, ''))); v_items jsonb; v_conflicts jsonb;
  a ref.admin_area; s net.station; v_city text;
BEGIN
  IF p_kind NOT IN ('AREA', 'PLACE', 'CITY', 'STATION') THEN
    RAISE EXCEPTION 'CODE_KIND: % is not a kind of code', p_kind USING ERRCODE = 'P0001';
  END IF;
  v_id := CASE p_kind WHEN 'AREA' THEN (SELECT id FROM ref.admin_area WHERE pcode = p_code)
                      WHEN 'PLACE' THEN (SELECT id FROM ref.place WHERE pcode = p_code)
                      WHEN 'CITY' THEN (SELECT id FROM ref.city WHERE code = p_code)
                      ELSE (SELECT id FROM net.station WHERE code = p_code) END;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'CODE_UNKNOWN: no % has the code % now', lower(p_kind), p_code USING ERRCODE = 'P0001';
  END IF;
  v_old := p_code;
  IF v_new = v_old THEN
    RAISE EXCEPTION 'CODE_SAME: the new code is the code already in use' USING ERRCODE = 'P0001';
  END IF;

  IF p_kind = 'AREA' THEN
    SELECT * INTO a FROM ref.admin_area WHERE id = v_id;
    IF v_new !~ '^[A-Z]{2}([0-9]{2}){1,3}$' OR length(v_new) <> length(v_old) OR left(v_new, 2) <> left(v_old, 2) THEN
      RAISE EXCEPTION 'CODE_FORMAT: an area keeps its country and level: % characters starting %', length(v_old), left(v_old, 2)
        USING ERRCODE = 'P0001';
    END IF;
    IF a.parent_id IS NOT NULL AND left(v_new, length(v_new) - 2) <> (SELECT pcode FROM ref.admin_area WHERE id = a.parent_id) THEN
      RAISE EXCEPTION 'CODE_PARENT: the code of an area starts with the code of the area it lies in (%); change that one to move the prefix',
        (SELECT pcode FROM ref.admin_area WHERE id = a.parent_id) USING ERRCODE = 'P0001';
    END IF;
    SELECT jsonb_agg(jsonb_build_object('kind', 'AREA', 'id', x.id, 'old', x.pcode,
                                        'new', v_new || substr(x.pcode, length(v_old) + 1), 'name', x.name_en)
                     ORDER BY length(x.pcode), x.pcode)
      INTO v_items
      FROM ref.admin_area x WHERE x.country_code = a.country_code AND left(x.pcode, length(v_old)) = v_old;
  ELSIF p_kind = 'PLACE' THEN
    IF v_new !~ '^[A-Z][0-9]{3,7}$' OR left(v_new, 1) <> left(v_old, 1) THEN
      RAISE EXCEPTION 'CODE_FORMAT: a place keeps its letter (%) followed by 3 to 7 digits', left(v_old, 1) USING ERRCODE = 'P0001';
    END IF;
    SELECT jsonb_build_array(jsonb_build_object('kind', 'PLACE', 'id', id, 'old', pcode, 'new', v_new, 'name', name_en))
      INTO v_items FROM ref.place WHERE id = v_id;
  ELSIF p_kind = 'CITY' THEN
    IF v_new !~ '^[A-Z]{3}$' THEN
      RAISE EXCEPTION 'CODE_FORMAT: a city has three letters' USING ERRCODE = 'P0001';
    END IF;
    SELECT jsonb_build_array(jsonb_build_object('kind', 'CITY', 'id', c.id, 'old', c.code, 'new', v_new, 'name', c.name))
           || coalesce((SELECT jsonb_agg(jsonb_build_object('kind', 'STATION', 'id', s2.id, 'old', s2.code,
                                                            'new', split_part(s2.code, '-', 1) || '-' || v_new || '-' || split_part(s2.code, '-', 3),
                                                            'name', s2.name) ORDER BY s2.code)
                          FROM net.station s2 WHERE s2.city_id = c.id AND split_part(s2.code, '-', 2) = c.code), '[]'::jsonb)
      INTO v_items FROM ref.city c WHERE c.id = v_id;
  ELSE
    SELECT * INTO s FROM net.station WHERE id = v_id;
    SELECT code INTO v_city FROM ref.city WHERE id = s.city_id;
    IF v_new !~ '^[A-Z]{2}-[A-Z]{3}-[CPX][0-9]{3,4}$' OR split_part(v_new, '-', 1) <> s.country_code THEN
      RAISE EXCEPTION 'CODE_FORMAT: a station''s code is country-city-number, as %-%-C001', s.country_code, v_city USING ERRCODE = 'P0001';
    END IF;
    IF split_part(v_new, '-', 2) <> v_city THEN
      RAISE EXCEPTION 'CODE_CITY: the station is in % and its code carries that city''s code', v_city USING ERRCODE = 'P0001';
    END IF;
    v_items := jsonb_build_array(jsonb_build_object('kind', 'STATION', 'id', s.id, 'old', s.code, 'new', v_new, 'name', s.name));
  END IF;

  -- a new code taken now by something outside the change, or kept as the old code of something else
  SELECT coalesce(jsonb_agg(jsonb_build_object('code', i->>'new', 'problem', p.problem) ORDER BY i->>'new'), '[]'::jsonb)
    INTO v_conflicts
    FROM jsonb_array_elements(v_items) i
    CROSS JOIN LATERAL (
      SELECT 'IN_USE' AS problem
       WHERE coalesce(CASE i->>'kind' WHEN 'AREA' THEN (SELECT id FROM ref.admin_area WHERE pcode = i->>'new')
                                      WHEN 'PLACE' THEN (SELECT id FROM ref.place WHERE pcode = i->>'new')
                                      WHEN 'CITY' THEN (SELECT id FROM ref.city WHERE code = i->>'new')
                                      ELSE (SELECT id FROM net.station WHERE code = i->>'new') END, 0)
             NOT IN (SELECT 0 UNION ALL SELECT (o->>'id')::bigint FROM jsonb_array_elements(v_items) o WHERE o->>'kind' = i->>'kind')
      UNION ALL
      SELECT 'OLD_CODE_OF_ANOTHER' WHERE EXISTS (
        SELECT 1 FROM net.code_history h WHERE h.entity_kind = i->>'kind' AND h.code = i->>'new'
           AND coalesce(h.area_id, h.place_id, h.city_id, h.station_id) <> (i->>'id')::bigint)
      UNION ALL
      SELECT 'ANOTHER_CHANGE_WAITING' WHERE EXISTS (
        SELECT 1 FROM net.code_change c, jsonb_array_elements(c.plan) o
         WHERE c.status IN ('PENDING', 'APPROVED') AND o->>'kind' = i->>'kind' AND o->>'id' = i->>'id')) p;
  RETURN jsonb_build_object('kind', p_kind, 'id', v_id, 'old', v_old, 'new', v_new, 'items', v_items, 'conflicts', v_conflicts);
END $$;
REVOKE ALL ON FUNCTION ref.code_plan(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ref.code_plan(text, text, text) TO masslak_app;
COMMENT ON FUNCTION ref.code_plan IS 'The preview of a code change: every code it touches with its new value, and why any new code cannot be used (1161, N39)';

-- ------------------------------------------------------------------ asking, deciding, taking effect
CREATE OR REPLACE FUNCTION ref.request_code_change(p_kind text, p_code text, p_new text, p_reason text, p_source text,
                                                   p_effective date) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_plan jsonb; v_uid uuid; v_id bigint;
BEGIN
  IF NOT sys.ctx_is_platform() OR sys.ctx_user_id() IS NULL THEN
    RAISE EXCEPTION 'FORBIDDEN: the platform changes codes' USING ERRCODE = 'P0001';
  END IF;
  IF length(btrim(coalesce(p_reason, ''))) < 5 THEN
    RAISE EXCEPTION 'CODE_REASON: say why the code changes' USING ERRCODE = 'P0001';
  END IF;
  IF p_effective IS NULL OR p_effective < current_date THEN
    RAISE EXCEPTION 'CODE_DATE: a change takes effect today or later' USING ERRCODE = 'P0001';
  END IF;
  v_plan := ref.code_plan(p_kind, p_code, p_new);
  IF jsonb_array_length(v_plan->'conflicts') > 0 THEN
    RAISE EXCEPTION 'CODE_CONFLICT: % cannot be used (%)', v_plan->'conflicts'->0->>'code', v_plan->'conflicts'->0->>'problem'
      USING ERRCODE = 'P0001';
  END IF;
  v_id := (v_plan->>'id')::bigint;
  INSERT INTO net.code_change (entity_kind, area_id, place_id, city_id, station_id, old_code, new_code, reason, source_document,
                               effective_on, plan, requested_by)
  VALUES (p_kind, CASE WHEN p_kind = 'AREA' THEN v_id END, CASE WHEN p_kind = 'PLACE' THEN v_id END,
          CASE WHEN p_kind = 'CITY' THEN v_id END, CASE WHEN p_kind = 'STATION' THEN v_id END,
          v_plan->>'old', v_plan->>'new', btrim(p_reason), nullif(btrim(coalesce(p_source, '')), ''), p_effective,
          v_plan->'items', sys.ctx_user_id())
  RETURNING uid INTO v_uid;
  RETURN v_uid;
END $$;
REVOKE ALL ON FUNCTION ref.request_code_change(text, text, text, text, text, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ref.request_code_change(text, text, text, text, text, date) TO masslak_app;
COMMENT ON FUNCTION ref.request_code_change IS 'Asks for a code change, refused when a new code is taken; a second person decides it (1161, N39)';

-- the codes written, the old ones kept; the plan worked out again, so what was added since the request moves too
CREATE OR REPLACE FUNCTION ref.apply_code_change(p_change bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE c net.code_change; v_plan jsonb; v_old text;
BEGIN
  SELECT * INTO c FROM net.code_change WHERE id = p_change FOR UPDATE;
  IF NOT FOUND OR c.status <> 'APPROVED' THEN
    RAISE EXCEPTION 'CODE_NOT_APPROVED: the change is not approved and waiting' USING ERRCODE = 'P0001';
  END IF;
  v_old := ref.entity_code(c.entity_kind, coalesce(c.area_id, c.place_id, c.city_id, c.station_id));
  -- set aside while it is planned again, so it does not stand in its own way
  UPDATE net.code_change SET status = 'APPLYING' WHERE id = c.id;
  v_plan := ref.code_plan(c.entity_kind, v_old, c.new_code);
  IF v_old <> c.old_code OR jsonb_array_length(v_plan->'conflicts') > 0 THEN
    UPDATE net.code_change SET status = 'FAILED',
           failure = CASE WHEN v_old <> c.old_code THEN format('the code is now %s', v_old)
                          ELSE format('%s cannot be used (%s)', v_plan->'conflicts'->0->>'code', v_plan->'conflicts'->0->>'problem') END
     WHERE id = c.id;
    RETURN jsonb_build_object('status', 'FAILED');
  END IF;
  UPDATE net.code_change SET plan = v_plan->'items' WHERE id = c.id;
  -- the old codes, each from when it began
  INSERT INTO net.code_history (entity_kind, area_id, place_id, city_id, station_id, code, valid_from, valid_to, change_id)
  SELECT i->>'kind', CASE WHEN i->>'kind' = 'AREA' THEN (i->>'id')::bigint END, CASE WHEN i->>'kind' = 'PLACE' THEN (i->>'id')::bigint END,
         CASE WHEN i->>'kind' = 'CITY' THEN (i->>'id')::bigint END, CASE WHEN i->>'kind' = 'STATION' THEN (i->>'id')::bigint END,
         i->>'old',
         (SELECT max(h.valid_to) FROM net.code_history h
           WHERE h.entity_kind = i->>'kind' AND coalesce(h.area_id, h.place_id, h.city_id, h.station_id) = (i->>'id')::bigint),
         now(), c.id
    FROM jsonb_array_elements(v_plan->'items') i;
  UPDATE ref.admin_area x SET pcode = i->>'new' FROM jsonb_array_elements(v_plan->'items') i
   WHERE i->>'kind' = 'AREA' AND x.id = (i->>'id')::bigint;
  UPDATE ref.place x SET pcode = i->>'new' FROM jsonb_array_elements(v_plan->'items') i
   WHERE i->>'kind' = 'PLACE' AND x.id = (i->>'id')::bigint;
  UPDATE ref.city x SET code = i->>'new' FROM jsonb_array_elements(v_plan->'items') i
   WHERE i->>'kind' = 'CITY' AND x.id = (i->>'id')::bigint;
  UPDATE net.station x SET code = i->>'new' FROM jsonb_array_elements(v_plan->'items') i
   WHERE i->>'kind' = 'STATION' AND x.id = (i->>'id')::bigint;
  -- the corrections of published names (1127) follow the area or place they are scoped to
  UPDATE ref.name_correction n SET scope_pcode = i->>'new' FROM jsonb_array_elements(v_plan->'items') i
   WHERE i->>'kind' IN ('AREA', 'PLACE') AND n.scope_pcode = i->>'old';
  UPDATE net.code_change SET status = 'APPLIED', applied_at = now() WHERE id = c.id;
  RETURN jsonb_build_object('status', 'APPLIED', 'codes', jsonb_array_length(v_plan->'items'));
END $$;
REVOKE ALL ON FUNCTION ref.apply_code_change(bigint) FROM PUBLIC;
COMMENT ON FUNCTION ref.apply_code_change IS 'Writes the new codes of an approved change and keeps the old ones as aliases; FAILED when a code was taken meanwhile (1161)';

CREATE OR REPLACE FUNCTION ref.decide_code_change(p_uid uuid, p_approve boolean, p_note text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE c net.code_change;
BEGIN
  IF NOT sys.ctx_is_platform() OR sys.ctx_user_id() IS NULL THEN
    RAISE EXCEPTION 'FORBIDDEN: the platform decides code changes' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO c FROM net.code_change WHERE uid = p_uid FOR UPDATE;
  IF NOT FOUND OR c.status <> 'PENDING' THEN
    RAISE EXCEPTION 'CODE_NOT_PENDING: the change is not waiting for a decision' USING ERRCODE = 'P0001';
  END IF;
  IF c.requested_by = sys.ctx_user_id() THEN
    RAISE EXCEPTION 'FOUR_EYES: another person decides the change you asked for' USING ERRCODE = 'P0001';
  END IF;
  IF NOT p_approve AND length(btrim(coalesce(p_note, ''))) < 5 THEN
    RAISE EXCEPTION 'CODE_NOTE: say why the change is rejected' USING ERRCODE = 'P0001';
  END IF;
  UPDATE net.code_change SET status = CASE WHEN p_approve THEN 'APPROVED' ELSE 'REJECTED' END, decided_by = sys.ctx_user_id(),
         decided_at = now(), decision_note = nullif(btrim(coalesce(p_note, '')), '')
   WHERE id = c.id;
  IF p_approve AND c.effective_on <= current_date THEN
    RETURN ref.apply_code_change(c.id)->>'status';
  END IF;
  RETURN CASE WHEN p_approve THEN 'APPROVED' ELSE 'REJECTED' END;
END $$;
REVOKE ALL ON FUNCTION ref.decide_code_change(uuid, boolean, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ref.decide_code_change(uuid, boolean, text) TO masslak_app;
COMMENT ON FUNCTION ref.decide_code_change IS 'Another person approves a code change (applied at once when its date has come) or rejects it with a reason (1161, N39)';

CREATE OR REPLACE FUNCTION ref.cancel_code_change(p_uid uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE c net.code_change;
BEGIN
  SELECT * INTO c FROM net.code_change WHERE uid = p_uid FOR UPDATE;
  IF NOT FOUND OR NOT sys.ctx_is_platform() OR c.requested_by IS DISTINCT FROM sys.ctx_user_id() THEN
    RAISE EXCEPTION 'FORBIDDEN: who asked for a change withdraws it' USING ERRCODE = 'P0001';
  END IF;
  IF c.status NOT IN ('PENDING', 'APPROVED') THEN
    RAISE EXCEPTION 'CODE_CLOSED: the change has already been %', lower(c.status) USING ERRCODE = 'P0001';
  END IF;
  UPDATE net.code_change SET status = 'CANCELLED' WHERE id = c.id;
  RETURN 'CANCELLED';
END $$;
REVOKE ALL ON FUNCTION ref.cancel_code_change(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ref.cancel_code_change(uuid) TO masslak_app;
COMMENT ON FUNCTION ref.cancel_code_change IS 'Withdraws a code change not yet in effect; only who asked for it (1161)';

-- approved changes whose date has come, from the worker
CREATE OR REPLACE FUNCTION ref.apply_due_code_changes() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE r record; v_applied int := 0; v_failed int := 0;
BEGIN
  FOR r IN SELECT id FROM net.code_change WHERE status = 'APPROVED' AND effective_on <= current_date ORDER BY effective_on, id LOOP
    IF ref.apply_code_change(r.id)->>'status' = 'APPLIED' THEN v_applied := v_applied + 1; ELSE v_failed := v_failed + 1; END IF;
  END LOOP;
  RETURN jsonb_build_object('applied', v_applied, 'failed', v_failed);
END $$;
REVOKE ALL ON FUNCTION ref.apply_due_code_changes() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ref.apply_due_code_changes() TO masslak_app;
COMMENT ON FUNCTION ref.apply_due_code_changes IS 'Puts into effect the approved code changes whose date has come (1161)';

-- ------------------------------------------------------------------ nobody writes a code directly
-- a code is changed only by a change being applied; a new thing never takes a code another thing had before
CREATE OR REPLACE FUNCTION ref.tg_code_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_kind text := TG_ARGV[0]; v_new text := to_jsonb(NEW)->>TG_ARGV[1]; v_old text;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    v_old := to_jsonb(OLD)->>TG_ARGV[1];
    IF v_new IS NOT DISTINCT FROM v_old THEN
      RETURN NEW;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM net.code_change c, jsonb_array_elements(c.plan) i
                    WHERE c.status = 'APPLYING' AND i->>'kind' = v_kind AND (i->>'id')::bigint = NEW.id AND i->>'new' = v_new) THEN
      RAISE EXCEPTION 'CODE_CHANGE_REQUIRED: a code changes through a code change approved by a second person (% %)', lower(v_kind), v_old
        USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
  END IF;
  IF EXISTS (SELECT 1 FROM net.code_history h WHERE h.entity_kind = v_kind AND h.code = v_new) THEN
    RAISE EXCEPTION 'CODE_OLD: % was the code of another %; choose another', v_new, lower(v_kind) USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION ref.tg_code_guard() FROM PUBLIC;
DROP TRIGGER IF EXISTS admin_area_code_guard ON ref.admin_area;
CREATE TRIGGER admin_area_code_guard BEFORE INSERT OR UPDATE OF pcode ON ref.admin_area
  FOR EACH ROW EXECUTE FUNCTION ref.tg_code_guard('AREA', 'pcode');
DROP TRIGGER IF EXISTS place_code_guard ON ref.place;
CREATE TRIGGER place_code_guard BEFORE INSERT OR UPDATE OF pcode ON ref.place
  FOR EACH ROW EXECUTE FUNCTION ref.tg_code_guard('PLACE', 'pcode');
DROP TRIGGER IF EXISTS city_code_guard ON ref.city;
CREATE TRIGGER city_code_guard BEFORE INSERT OR UPDATE OF code ON ref.city
  FOR EACH ROW EXECUTE FUNCTION ref.tg_code_guard('CITY', 'code');
DROP TRIGGER IF EXISTS station_code_guard ON net.station;
CREATE TRIGGER station_code_guard BEFORE INSERT OR UPDATE OF code ON net.station
  FOR EACH ROW EXECUTE FUNCTION ref.tg_code_guard('STATION', 'code');

-- ------------------------------------------------------------------ registration
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('net.code_change', '1A', 'E04'), ('net.code_history', '1A', 'E04')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
SELECT sys.refresh_table_class();
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('net.code_change', 'net records', 'requests to change a code, with their decision (1161)'),
  ('net.code_history', 'net records', 'old codes kept as aliases, dated (1161)')
ON CONFLICT (table_name) DO NOTHING;
INSERT INTO sys.json_contract (table_name, column_name, kind, version, spec, note) VALUES
  ('net.code_change', 'plan', 'SHAPE', 1,
   '{"type": "array", "items": {"type": "object", "required": ["kind", "id", "old", "new"]}}'::jsonb,
   'every code a change touches, with its new value (1161)')
ON CONFLICT DO NOTHING;
SELECT sys.apply_json_contracts();
