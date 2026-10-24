-- =====================================================================
-- Masslak - 1087: the boarding photo policy and its replacement (the sixth round, 11 October 2026: WP1 and WP4)
--
-- WP1: a rule says whether a boarding photo is REQUIRED, OPTIONAL or NOT_APPLICABLE for a traveller on a trip. Rules are
-- configuration, changed by the platform with four eyes (one person proposes, another approves, and a rule is retired by a
-- third person), with the legal basis and the date from which they apply. The most specific rule in force applies; when
-- none does, the photo is OPTIONAL (phase 1). Enforcement at booking and at boarding reads iam.photo_requirement.
--
-- WP4: a photo on file is changed only by the platform: a request carries the new photo and the evidence (a civil
-- registry extract that carries the photo, or an identity document), another platform person approves it, and the
-- change is audited. The person and the family head never change a photo on file (1086).
--
-- Nothing refers to iam.photo_rule or iam.photo_change_request, so they add no reference cycle (db/tools/
-- schema_dependencies.py). Writes go through the functions below; the application role reads the tables under the
-- platform policy.
-- =====================================================================

-- 1. the rules -----------------------------------------------------------
CREATE TABLE IF NOT EXISTS iam.photo_rule (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                 uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  market              char(2) REFERENCES ref.market (country_code),          -- where the trip departs; NULL: every market
  trip_scope          text CHECK (trip_scope IN ('DOMESTIC', 'INTERNATIONAL')),  -- NULL: any
  traveller_class     text CHECK (traveller_class IN ('SYRIAN_CITIZEN', 'FOREIGN', 'TRANSIT')),  -- NULL: any
  passenger_category  text,                                                   -- NULL: any category
  requirement         text NOT NULL CHECK (requirement IN ('REQUIRED', 'OPTIONAL', 'NOT_APPLICABLE')),
  effective_from      date NOT NULL,
  effective_to        date,
  legal_basis         text NOT NULL CHECK (length(legal_basis) BETWEEN 3 AND 500),
  status              text NOT NULL DEFAULT 'PROPOSED' CHECK (status IN ('PROPOSED', 'APPROVED', 'RETIRED')),
  proposed_by_user_id bigint NOT NULL REFERENCES iam.app_user (id),
  proposed_at         timestamptz NOT NULL DEFAULT now(),
  approved_by_user_id bigint REFERENCES iam.app_user (id),
  approved_at         timestamptz,
  retired_by_user_id  bigint REFERENCES iam.app_user (id),
  retired_at          timestamptz,
  CHECK (effective_to IS NULL OR effective_to > effective_from),
  CHECK (status = 'PROPOSED' OR status = 'RETIRED' OR approved_by_user_id IS NOT NULL),
  CHECK (approved_by_user_id IS NULL OR approved_by_user_id <> proposed_by_user_id),
  CHECK (status <> 'RETIRED' OR (retired_by_user_id IS NOT NULL AND (approved_by_user_id IS NULL OR retired_by_user_id <> approved_by_user_id)))
);
CREATE INDEX IF NOT EXISTS photo_rule_market_fkx ON iam.photo_rule (market);
CREATE INDEX IF NOT EXISTS photo_rule_proposed_by_user_id_fkx ON iam.photo_rule (proposed_by_user_id);
CREATE INDEX IF NOT EXISTS photo_rule_approved_by_user_id_fkx ON iam.photo_rule (approved_by_user_id);
CREATE INDEX IF NOT EXISTS photo_rule_retired_by_user_id_fkx ON iam.photo_rule (retired_by_user_id);
COMMENT ON TABLE iam.photo_rule IS 'When a boarding photo is required, by market, trip scope, traveller class and category; four eyes; the legal basis (1087)';

-- 2. the requests that change a photo on file -----------------------------
CREATE TABLE IF NOT EXISTS iam.photo_change_request (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                  uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  party_id             bigint NOT NULL REFERENCES iam.party (id),
  requested_by_user_id bigint NOT NULL REFERENCES iam.app_user (id),
  reason               text NOT NULL CHECK (length(reason) BETWEEN 10 AND 500),
  evidence_kind        text NOT NULL CHECK (evidence_kind IN ('CIVIL_REGISTRY_EXTRACT', 'IDENTITY_DOCUMENT')),
  evidence_file_id     bigint REFERENCES ref.file_object (id),     -- NULL once the person is erased
  photo_file_id        bigint REFERENCES ref.file_object (id),     -- the new photo; NULL once applied or rejected
  status               text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'APPLIED', 'REJECTED')),
  decided_by_user_id   bigint REFERENCES iam.app_user (id),
  decided_at           timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now(),
  CHECK (status = 'PENDING' OR decided_by_user_id IS NOT NULL),
  CHECK (status <> 'APPLIED' OR decided_by_user_id <> requested_by_user_id)
);
CREATE INDEX IF NOT EXISTS photo_change_request_party_id_fkx ON iam.photo_change_request (party_id);
CREATE INDEX IF NOT EXISTS photo_change_request_requested_by_user_id_fkx ON iam.photo_change_request (requested_by_user_id);
CREATE INDEX IF NOT EXISTS photo_change_request_evidence_file_id_fkx ON iam.photo_change_request (evidence_file_id);
CREATE INDEX IF NOT EXISTS photo_change_request_photo_file_id_fkx ON iam.photo_change_request (photo_file_id);
CREATE INDEX IF NOT EXISTS photo_change_request_decided_by_user_id_fkx ON iam.photo_change_request (decided_by_user_id);
COMMENT ON TABLE iam.photo_change_request IS 'A platform request to change a boarding photo on file, with its evidence; applied by a second person (1087)';

-- 3. who may read them: the platform only (the functions below are the writers) -------------------------------
SELECT sys.rls_platform('iam.photo_rule');
SELECT sys.rls_platform('iam.photo_change_request');
GRANT SELECT ON iam.photo_rule, iam.photo_change_request TO masslak_app;

-- 4. the photo can now be taken by the platform (WP4); the earlier check does not allow it, so it is widened here -----
ALTER TABLE iam.party_photo DROP CONSTRAINT party_photo_taken_by_check;
ALTER TABLE iam.party_photo ADD CONSTRAINT party_photo_taken_by_check CHECK (taken_by IN ('SELF', 'HEAD_OF_FAMILY', 'PLATFORM'));

-- 5. a traveller turned away at the gate for want of a required photo (WP1) ---------------------------------------
ALTER TABLE sales.boarding_event DROP CONSTRAINT boarding_event_result_check;
ALTER TABLE sales.boarding_event ADD CONSTRAINT boarding_event_result_check CHECK (result = ANY (ARRAY[
  'OK'::text, 'DUPLICATE'::text, 'INVALID_QR'::text, 'WRONG_TRIP'::text, 'DOCS_REQUIRED'::text, 'WRONG_STOP'::text,
  'PHOTO_REQUIRED'::text]));

-- 6. the functions of the policy ------------------------------------------------------------------------------
-- the class of a traveller: a Syrian citizen by nationality; transit is set by the booking once WP7 provides it
CREATE OR REPLACE FUNCTION iam.traveller_class(p_nationality text, p_transit boolean DEFAULT false) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_transit THEN 'TRANSIT' WHEN p_nationality = 'SY' THEN 'SYRIAN_CITIZEN' ELSE 'FOREIGN' END
$$;
GRANT EXECUTE ON FUNCTION iam.traveller_class(text, boolean) TO masslak_app, masslak_readonly;

-- the market (the country the trip departs from) and the scope (domestic when every stop is in the country)
CREATE OR REPLACE FUNCTION ops.trip_photo_scope(p_trip_id bigint) RETURNS TABLE (market char(2), trip_scope text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT (SELECT n.country_code FROM ops.trip_stop s JOIN net.station n ON n.id = s.station_id
           WHERE s.trip_id = p_trip_id ORDER BY s.seq LIMIT 1),
         CASE WHEN bool_and(n.country_code = 'SY') THEN 'DOMESTIC' ELSE 'INTERNATIONAL' END
    FROM ops.trip_stop s JOIN net.station n ON n.id = s.station_id WHERE s.trip_id = p_trip_id
$$;
REVOKE ALL ON FUNCTION ops.trip_photo_scope(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.trip_photo_scope(bigint) TO masslak_app, masslak_readonly;

-- the requirement in force: the most specific approved rule that is in force on the day; OPTIONAL when none is
CREATE OR REPLACE FUNCTION iam.photo_requirement(p_market char, p_trip_scope text, p_traveller_class text,
                                                  p_category text, p_on date DEFAULT current_date) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce((
    SELECT r.requirement FROM iam.photo_rule r
     WHERE r.status = 'APPROVED'
       AND (r.market IS NULL OR r.market = p_market)
       AND (r.trip_scope IS NULL OR r.trip_scope = p_trip_scope)
       AND (r.traveller_class IS NULL OR r.traveller_class = p_traveller_class)
       AND (r.passenger_category IS NULL OR r.passenger_category = p_category)
       AND r.effective_from <= p_on AND (r.effective_to IS NULL OR r.effective_to > p_on)
     ORDER BY ((r.market IS NOT NULL)::int + (r.trip_scope IS NOT NULL)::int
               + (r.traveller_class IS NOT NULL)::int + (r.passenger_category IS NOT NULL)::int) DESC,
              r.effective_from DESC, r.id DESC
     LIMIT 1), 'OPTIONAL')
$$;
REVOKE ALL ON FUNCTION iam.photo_requirement(char, text, text, text, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION iam.photo_requirement(char, text, text, text, date) TO masslak_app, masslak_readonly;

CREATE OR REPLACE FUNCTION iam.propose_photo_rule(p_market char, p_trip_scope text, p_traveller_class text, p_category text,
    p_requirement text, p_effective_from date, p_legal_basis text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_uid uuid;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: photo rules are a platform task' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO iam.photo_rule (market, trip_scope, traveller_class, passenger_category, requirement, effective_from,
                              legal_basis, proposed_by_user_id)
  VALUES (p_market, p_trip_scope, p_traveller_class, p_category, p_requirement, p_effective_from, p_legal_basis,
          sys.ctx_user_id())
  RETURNING uid INTO v_uid;
  RETURN v_uid;
END $$;

CREATE OR REPLACE FUNCTION iam.approve_photo_rule(p_uid uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: photo rules are a platform task' USING ERRCODE = 'P0001';
  END IF;
  UPDATE iam.photo_rule SET status = 'APPROVED', approved_by_user_id = sys.ctx_user_id(), approved_at = now()
   WHERE uid = p_uid AND status = 'PROPOSED';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'NOT_PROPOSED: the rule is not waiting for approval' USING ERRCODE = 'P0001';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION iam.retire_photo_rule(p_uid uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: photo rules are a platform task' USING ERRCODE = 'P0001';
  END IF;
  UPDATE iam.photo_rule SET status = 'RETIRED', retired_by_user_id = sys.ctx_user_id(), retired_at = now()
   WHERE uid = p_uid AND status IN ('PROPOSED', 'APPROVED');
  IF NOT FOUND THEN
    RAISE EXCEPTION 'NOT_RETIRABLE: the rule is already retired' USING ERRCODE = 'P0001';
  END IF;
END $$;

-- WP4: a request to change the photo on file -----------------------------------------------------------------
CREATE OR REPLACE FUNCTION iam.request_photo_change(p_party_id bigint, p_reason text, p_evidence_kind text,
    p_evidence_file_id bigint, p_photo_file_id bigint) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_uid uuid;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: a photo change is a platform task' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO iam.photo_change_request (party_id, requested_by_user_id, reason, evidence_kind, evidence_file_id, photo_file_id)
  VALUES (p_party_id, sys.ctx_user_id(), p_reason, p_evidence_kind, p_evidence_file_id, p_photo_file_id)
  RETURNING uid INTO v_uid;
  RETURN v_uid;
END $$;

-- applied by a second person: the photo on file is replaced, the earlier file goes, the request is closed
CREATE OR REPLACE FUNCTION iam.apply_photo_change(p_uid uuid) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE r iam.photo_change_request; v_old bigint;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: a photo change is a platform task' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO r FROM iam.photo_change_request WHERE uid = p_uid AND status = 'PENDING' FOR UPDATE;
  IF NOT FOUND OR r.photo_file_id IS NULL THEN
    RAISE EXCEPTION 'NOT_PENDING: the request is not waiting for a decision' USING ERRCODE = 'P0001';
  END IF;
  IF r.requested_by_user_id = sys.ctx_user_id() THEN
    RAISE EXCEPTION 'FOUR_EYES: a second person applies the change' USING ERRCODE = 'P0001';
  END IF;
  SELECT pp.file_id INTO v_old FROM iam.party_photo pp WHERE pp.party_id = r.party_id FOR UPDATE;
  IF v_old IS NULL THEN
    INSERT INTO iam.party_photo (party_id, file_id, taken_by, taken_by_user_id)
    VALUES (r.party_id, r.photo_file_id, 'PLATFORM', sys.ctx_user_id());
  ELSE
    UPDATE iam.party_photo SET file_id = r.photo_file_id, taken_by = 'PLATFORM', taken_by_user_id = sys.ctx_user_id(),
                               taken_at = now()
     WHERE party_id = r.party_id;
    DELETE FROM ref.file_object WHERE id = v_old;
  END IF;
  UPDATE iam.photo_change_request SET status = 'APPLIED', decided_by_user_id = sys.ctx_user_id(), decided_at = now(),
                                      photo_file_id = NULL
   WHERE id = r.id;
  RETURN r.party_id;
END $$;

-- a request turned down: the new photo goes, the evidence stays with the request until the person is erased
CREATE OR REPLACE FUNCTION iam.reject_photo_change(p_uid uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE r iam.photo_change_request;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: a photo change is a platform task' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO r FROM iam.photo_change_request WHERE uid = p_uid AND status = 'PENDING' FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'NOT_PENDING: the request is not waiting for a decision' USING ERRCODE = 'P0001';
  END IF;
  UPDATE iam.photo_change_request SET status = 'REJECTED', decided_by_user_id = sys.ctx_user_id(), decided_at = now(),
                                      photo_file_id = NULL
   WHERE id = r.id;
  IF r.photo_file_id IS NOT NULL THEN
    DELETE FROM ref.file_object WHERE id = r.photo_file_id;
  END IF;
END $$;

REVOKE ALL ON FUNCTION iam.propose_photo_rule(char, text, text, text, text, date, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.approve_photo_rule(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.retire_photo_rule(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.request_photo_change(bigint, text, text, bigint, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.apply_photo_change(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.reject_photo_change(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION iam.propose_photo_rule(char, text, text, text, text, date, text) TO masslak_app;
GRANT EXECUTE ON FUNCTION iam.approve_photo_rule(uuid) TO masslak_app;
GRANT EXECUTE ON FUNCTION iam.retire_photo_rule(uuid) TO masslak_app;
GRANT EXECUTE ON FUNCTION iam.request_photo_change(bigint, text, text, bigint, bigint) TO masslak_app;
GRANT EXECUTE ON FUNCTION iam.apply_photo_change(uuid) TO masslak_app;
GRANT EXECUTE ON FUNCTION iam.reject_photo_change(uuid) TO masslak_app;

-- 7. erasure (1086) also removes the evidence and the candidate photos of the person's requests ------------------
CREATE OR REPLACE FUNCTION gov.erase_party_photo(p_party_id bigint) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_file bigint; v_extra bigint[];
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: erasure is a platform task' USING ERRCODE = 'P0001';
  END IF;
  DELETE FROM iam.party_photo WHERE party_id = p_party_id RETURNING file_id INTO v_file;
  SELECT array_agg(f) INTO v_extra FROM (
    SELECT evidence_file_id AS f FROM iam.photo_change_request WHERE party_id = p_party_id AND evidence_file_id IS NOT NULL
    UNION
    SELECT photo_file_id FROM iam.photo_change_request WHERE party_id = p_party_id AND photo_file_id IS NOT NULL) s;
  UPDATE iam.photo_change_request SET evidence_file_id = NULL, photo_file_id = NULL WHERE party_id = p_party_id;
  IF v_file IS NOT NULL THEN
    DELETE FROM ref.file_object WHERE id = v_file;
  END IF;
  IF v_extra IS NOT NULL THEN
    DELETE FROM ref.file_object WHERE id = ANY (v_extra);
  END IF;
  RETURN v_file IS NOT NULL OR v_extra IS NOT NULL;
END $$;

-- 8. the lifecycle of the two tables (1079): the rules are configuration, the requests are personal records ------
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('iam.photo_rule', '1A', 'E01'), ('iam.photo_change_request', '1A', 'E01');
INSERT INTO sys.table_class (table_name, data_class, tenant_path, note) VALUES
  ('iam.photo_rule', 'PLATFORM_CONFIDENTIAL', NULL, 'boarding photo rules (1087)'),
  ('iam.photo_change_request', 'USER_PRIVATE', 'parent iam.party', 'requests to change a boarding photo, with their evidence (1087)')
ON CONFLICT (table_name) DO UPDATE SET data_class = excluded.data_class, tenant_path = excluded.tenant_path, note = excluded.note;
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('iam.photo_rule', 'gov records', 'the rules that require a boarding photo, with their legal basis (1087)'),
  ('iam.photo_change_request', 'iam.party', 'a request to change a boarding photo is erased with the person (1087)');
