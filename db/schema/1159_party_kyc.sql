-- =====================================================================
-- 1159: know your customer for every party (owner's request N14)
--   * The KYC form (1118) gets a kind: CARRIER, AGENCY, STATION (a station operating company), DRIVER and PASSENGER.
--     Each kind has its own versions and one version in force. A company's file follows the form of its kind:
--     agencies and station operating companies fill their own forms, and carriers keep theirs.
--   * Drivers and passengers fill a shorter form about themselves (iam.person_kyc). One platform reviewer decides it,
--     never the person who entered it. An approved file makes the person VERIFIED (iam.party.verification_status) until
--     it is due for review again.
--   * What a verified person unlocks is a platform setting (kyc.persons). Nothing is locked at launch: a passenger
--     redeems points and a driver drives without a file until the platform turns these on.
-- =====================================================================

-- ------------------------------------------------------------------ the kind of a form
ALTER TABLE iam.kyc_form ADD COLUMN IF NOT EXISTS subject_kind text NOT NULL DEFAULT 'CARRIER';
ALTER TABLE iam.kyc_form DROP CONSTRAINT IF EXISTS kyc_form_subject_kind_check;
ALTER TABLE iam.kyc_form ADD CONSTRAINT kyc_form_subject_kind_check
  CHECK (subject_kind IN ('CARRIER', 'AGENCY', 'STATION', 'DRIVER', 'PASSENGER'));
-- a person's form asks for no company documents
ALTER TABLE iam.kyc_form DROP CONSTRAINT IF EXISTS kyc_form_person_documents_check;
ALTER TABLE iam.kyc_form ADD CONSTRAINT kyc_form_person_documents_check
  CHECK (subject_kind NOT IN ('DRIVER', 'PASSENGER') OR coalesce(jsonb_array_length(definition -> 'documents'), 0) = 0);
DROP INDEX IF EXISTS iam.kyc_form_one_active;
CREATE UNIQUE INDEX IF NOT EXISTS kyc_form_one_active_per_kind ON iam.kyc_form (subject_kind) WHERE status = 'ACTIVE';
CREATE UNIQUE INDEX IF NOT EXISTS kyc_form_one_draft_per_kind ON iam.kyc_form (subject_kind) WHERE status = 'DRAFT';
COMMENT ON COLUMN iam.kyc_form.subject_kind IS 'Who fills the form: a carrier, an agency, a station operating company, a driver or a passenger; one version in force for each (1159, N14)';

-- the kind of form a company fills
CREATE OR REPLACE FUNCTION iam.kyc_kind_of_company(p_company bigint) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT CASE company_type WHEN 'AGENCY' THEN 'AGENCY' WHEN 'STATION_OPERATOR' THEN 'STATION' ELSE 'CARRIER' END
    FROM iam.company WHERE id = p_company
$$;

-- the platform saves the draft of the next version of a kind's form (one draft for each kind)
CREATE OR REPLACE FUNCTION iam.save_kyc_form(p_definition jsonb, p_note text, p_kind text) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_problem text; v_version integer;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: the platform makes the KYC form' USING ERRCODE = 'P0001';
  END IF;
  IF p_kind IS NULL OR p_kind NOT IN ('CARRIER', 'AGENCY', 'STATION', 'DRIVER', 'PASSENGER') THEN
    RAISE EXCEPTION 'KYC_FORM_INVALID: no form is for %', coalesce(p_kind, 'null') USING ERRCODE = 'P0001';
  END IF;
  v_problem := iam.kyc_form_problem(p_definition);
  IF v_problem IS NULL AND p_kind IN ('DRIVER', 'PASSENGER') AND coalesce(jsonb_array_length(p_definition -> 'documents'), 0) > 0 THEN
    v_problem := 'a person''s form asks for no company documents';
  END IF;
  IF v_problem IS NOT NULL THEN
    RAISE EXCEPTION 'KYC_FORM_INVALID: %', v_problem USING ERRCODE = 'P0001';
  END IF;
  SELECT version INTO v_version FROM iam.kyc_form WHERE status = 'DRAFT' AND subject_kind = p_kind FOR UPDATE;
  IF v_version IS NULL THEN
    INSERT INTO iam.kyc_form (version, subject_kind, definition, note, created_by)
    VALUES ((SELECT coalesce(max(version), 0) + 1 FROM iam.kyc_form), p_kind, p_definition, nullif(btrim(p_note), ''), sys.ctx_user_id())
    RETURNING version INTO v_version;
  ELSE
    UPDATE iam.kyc_form SET definition = p_definition, note = nullif(btrim(p_note), ''), created_by = sys.ctx_user_id(), created_at = now()
     WHERE version = v_version;
  END IF;
  RETURN v_version;
END $$;

-- the form of 1118 is the carriers'
CREATE OR REPLACE FUNCTION iam.save_kyc_form(p_definition jsonb, p_note text) RETURNS integer
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT iam.save_kyc_form(p_definition, p_note, 'CARRIER')
$$;

-- a draft is put in force for its kind: only that kind's version in force is retired
CREATE OR REPLACE FUNCTION iam.activate_kyc_form(p_version integer) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_kind text;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: the platform activates the KYC form' USING ERRCODE = 'P0001';
  END IF;
  SELECT subject_kind INTO v_kind FROM iam.kyc_form WHERE version = p_version AND status = 'DRAFT';
  IF v_kind IS NULL THEN
    RAISE EXCEPTION 'NOT_FOUND: no draft version % of the form', p_version USING ERRCODE = 'P0001';
  END IF;
  UPDATE iam.kyc_form SET status = 'RETIRED' WHERE status = 'ACTIVE' AND subject_kind = v_kind;
  UPDATE iam.kyc_form SET status = 'ACTIVE', activated_by = sys.ctx_user_id(), activated_at = now() WHERE version = p_version;
  RETURN p_version;
END $$;

-- a company's open file follows the form of its kind
CREATE OR REPLACE FUNCTION iam.open_company_kyc(p_company bigint) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_uid uuid; v_form bigint; v_answers jsonb;
BEGIN
  IF NOT iam.kyc_may_touch(p_company) THEN
    RAISE EXCEPTION 'FORBIDDEN: a company opens its own KYC file' USING ERRCODE = 'P0001';
  END IF;
  PERFORM 1 FROM iam.company WHERE id = p_company FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'NOT_FOUND: no such company' USING ERRCODE = 'P0001';
  END IF;
  SELECT uid INTO v_uid FROM iam.company_kyc WHERE company_id = p_company AND status IN ('DRAFT', 'SUBMITTED', 'RETURNED');
  IF v_uid IS NOT NULL THEN
    RETURN v_uid;
  END IF;
  SELECT id INTO v_form FROM iam.kyc_form WHERE status = 'ACTIVE' AND subject_kind = iam.kyc_kind_of_company(p_company);
  IF v_form IS NULL THEN
    RAISE EXCEPTION 'KYC_NO_FORM: the platform has no KYC form in force for this kind of company' USING ERRCODE = 'P0001';
  END IF;
  SELECT answers INTO v_answers FROM iam.company_kyc WHERE company_id = p_company AND status = 'APPROVED';
  IF v_answers IS NULL THEN
    SELECT jsonb_strip_nulls(jsonb_build_object('legal_name', p.legal_name, 'registration_country', p.country_code,
             'cr_no', c.cr_no, 'transport_license_no', c.transport_license_no, 'regulator_code', c.regulator_code,
             'tax_residency', p.country_code))
      INTO v_answers FROM iam.company c JOIN iam.party p ON p.id = c.id WHERE c.id = p_company;
  END IF;
  INSERT INTO iam.company_kyc (company_id, version, form_id, answers, created_by, updated_by)
  VALUES (p_company, (SELECT coalesce(max(version), 0) + 1 FROM iam.company_kyc WHERE company_id = p_company), v_form,
          coalesce(v_answers, '{}'::jsonb), sys.ctx_user_id(), sys.ctx_user_id())
  RETURNING uid INTO v_uid;
  RETURN v_uid;
END $$;

-- ------------------------------------------------------------------ the settings: kyc.persons
CREATE OR REPLACE FUNCTION iam.kyc_setting_problem(p_key text, p_value jsonb) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE e jsonb; v_problem text; k text;
BEGIN
  IF p_key = 'kyc.review_stages' THEN
    IF jsonb_typeof(p_value) IS DISTINCT FROM 'array' OR jsonb_array_length(p_value) NOT BETWEEN 1 AND 6 THEN
      RETURN 'the review stages are a list of one to six stages';
    END IF;
    FOR e IN SELECT x FROM jsonb_array_elements(p_value) x LOOP
      IF jsonb_typeof(e) IS DISTINCT FROM 'object' OR NOT coalesce(e ->> 'by' IN ('COMPLIANCE', 'FINANCE', 'TAX', 'AUTHORITY'), false)
         OR EXISTS (SELECT 1 FROM jsonb_object_keys(e) ek WHERE ek NOT IN ('by', 'authority'))
         OR (e ->> 'by' <> 'AUTHORITY' AND e ? 'authority') THEN
        RETURN 'each stage is {"by": "COMPLIANCE"}, {"by": "FINANCE"}, {"by": "TAX"} or {"by": "AUTHORITY", "authority": "<code>"}';
      END IF;
      IF e ->> 'by' = 'AUTHORITY' AND NOT EXISTS (SELECT 1 FROM sec.authority_profile a WHERE a.code = e ->> 'authority') THEN
        RETURN format('no authority has the code %s', coalesce(e ->> 'authority', 'null'));
      END IF;
    END LOOP;
    IF (SELECT count(DISTINCT x) FROM jsonb_array_elements(p_value) x) <> jsonb_array_length(p_value) THEN
      RETURN 'a stage is named once';
    END IF;
  ELSIF p_key = 'kyc.risk_rules' THEN
    IF jsonb_typeof(p_value) IS DISTINCT FROM 'array' OR jsonb_array_length(p_value) > 100 THEN
      RETURN 'the risk rules are a list of up to 100 rules';
    END IF;
    FOR e IN SELECT x FROM jsonb_array_elements(p_value) x LOOP
      v_problem := iam.kyc_rule_problem(e, false);
      IF v_problem IS NOT NULL THEN
        RETURN v_problem;
      END IF;
    END LOOP;
    IF (SELECT count(DISTINCT x ->> 'code') FROM jsonb_array_elements(p_value) x) <> jsonb_array_length(p_value) THEN
      RETURN 'each rule has its own code';
    END IF;
  ELSIF p_key = 'kyc.risk_levels' THEN
    IF jsonb_typeof(p_value) IS DISTINCT FROM 'object'
       OR (SELECT array_agg(k2 ORDER BY k2) FROM jsonb_object_keys(p_value) k2) IS DISTINCT FROM ARRAY['HIGH', 'MEDIUM']
       OR NOT ((p_value ->> 'MEDIUM') ~ '^[0-9]{1,4}$' AND (p_value ->> 'HIGH') ~ '^[0-9]{1,4}$')
       OR NOT ((p_value ->> 'MEDIUM')::int BETWEEN 1 AND 999 AND (p_value ->> 'HIGH')::int > (p_value ->> 'MEDIUM')::int
               AND (p_value ->> 'HIGH')::int <= 1000) THEN
      RETURN 'the levels are {"MEDIUM": n, "HIGH": m} with 0 < n < m <= 1000';
    END IF;
  ELSIF p_key = 'kyc.review_months' THEN
    IF jsonb_typeof(p_value) IS DISTINCT FROM 'object'
       OR (SELECT array_agg(k2 ORDER BY k2) FROM jsonb_object_keys(p_value) k2) IS DISTINCT FROM ARRAY['HIGH', 'LOW', 'MEDIUM']
       OR EXISTS (SELECT 1 FROM jsonb_each(p_value) m WHERE (m.value #>> '{}') !~ '^[0-9]{1,2}$')
       OR EXISTS (SELECT 1 FROM jsonb_each(p_value) m WHERE (m.value #>> '{}')::int NOT BETWEEN 1 AND 60) THEN
      RETURN 'the months are {"LOW": n, "MEDIUM": n, "HIGH": n}, each 1 to 60';
    END IF;
  ELSIF p_key = 'kyc.ubo_threshold_pct' THEN
    IF NOT coalesce(jsonb_typeof(p_value) = 'number' AND (p_value #>> '{}') ~ '^[0-9]{1,2}$' AND (p_value #>> '{}')::int BETWEEN 5 AND 50, false) THEN
      RETURN 'the threshold is 5 to 50 percent';
    END IF;
  ELSIF p_key IN ('kyc.documents_on_submit', 'kyc.distinct_reviewers') THEN
    IF jsonb_typeof(p_value) IS DISTINCT FROM 'boolean' THEN
      RETURN format('%s is true or false', p_key);
    END IF;
  ELSIF p_key = 'kyc.required_before' THEN
    IF jsonb_typeof(p_value) IS DISTINCT FROM 'array'
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(p_value) x WHERE NOT coalesce(x #>> '{}' IN ('PUBLISH_TRIPS', 'PAYOUTS'), false))
       OR (SELECT count(DISTINCT x) FROM jsonb_array_elements(p_value) x) <> jsonb_array_length(p_value) THEN
      RETURN 'kyc.required_before is a list of PUBLISH_TRIPS, PAYOUTS, each once';
    END IF;
  ELSIF p_key = 'kyc.persons' THEN
    IF jsonb_typeof(p_value) IS DISTINCT FROM 'object'
       OR (SELECT array_agg(k2 ORDER BY k2) FROM jsonb_object_keys(p_value) k2) IS DISTINCT FROM ARRAY['required_before', 'review_months']
       OR jsonb_typeof(p_value -> 'required_before') IS DISTINCT FROM 'object'
       OR jsonb_typeof(p_value -> 'review_months') IS DISTINCT FROM 'object' THEN
      RETURN 'kyc.persons is {"required_before": {"PASSENGER": [...], "DRIVER": [...]}, "review_months": {"PASSENGER": n, "DRIVER": n}}';
    END IF;
    IF (SELECT array_agg(k2 ORDER BY k2) FROM jsonb_object_keys(p_value -> 'required_before') k2) IS DISTINCT FROM ARRAY['DRIVER', 'PASSENGER']
       OR (SELECT array_agg(k2 ORDER BY k2) FROM jsonb_object_keys(p_value -> 'review_months') k2) IS DISTINCT FROM ARRAY['DRIVER', 'PASSENGER'] THEN
      RETURN 'kyc.persons names PASSENGER and DRIVER in each part';
    END IF;
    FOR k, e IN SELECT * FROM jsonb_each(p_value -> 'required_before') LOOP
      IF jsonb_typeof(e) IS DISTINCT FROM 'array'
         OR EXISTS (SELECT 1 FROM jsonb_array_elements(e) x
                     WHERE NOT coalesce(x #>> '{}' = ANY (CASE k WHEN 'PASSENGER' THEN ARRAY['LOYALTY_REDEEM'] ELSE ARRAY['DRIVE'] END), false))
         OR (SELECT count(DISTINCT x) FROM jsonb_array_elements(e) x) <> jsonb_array_length(e) THEN
        RETURN 'a passenger may need a file before LOYALTY_REDEEM, a driver before DRIVE, each once';
      END IF;
    END LOOP;
    IF EXISTS (SELECT 1 FROM jsonb_each(p_value -> 'review_months') m
                WHERE (m.value #>> '{}') !~ '^[0-9]{1,3}$' OR (m.value #>> '{}')::int NOT BETWEEN 6 AND 120) THEN
      RETURN 'the review months of a person''s file are 6 to 120';
    END IF;
  ELSE
    RETURN format('%s is not a setting of KYC', p_key);
  END IF;
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION iam.kyc_setting(p_key text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce((SELECT s.value FROM sys.setting s WHERE s.key = p_key AND iam.kyc_setting_problem(p_key, s.value) IS NULL),
                  CASE p_key WHEN 'kyc.review_stages' THEN '[{"by":"COMPLIANCE"},{"by":"FINANCE"}]'::jsonb
                             WHEN 'kyc.risk_rules' THEN '[]'::jsonb
                             WHEN 'kyc.risk_levels' THEN '{"MEDIUM": 25, "HIGH": 50}'::jsonb
                             WHEN 'kyc.review_months' THEN '{"LOW": 36, "MEDIUM": 24, "HIGH": 12}'::jsonb
                             WHEN 'kyc.ubo_threshold_pct' THEN '25'::jsonb
                             WHEN 'kyc.documents_on_submit' THEN 'true'::jsonb
                             WHEN 'kyc.required_before' THEN '[]'::jsonb
                             WHEN 'kyc.distinct_reviewers' THEN 'true'::jsonb
                             WHEN 'kyc.persons' THEN '{"required_before": {"PASSENGER": [], "DRIVER": []}, "review_months": {"PASSENGER": 60, "DRIVER": 24}}'::jsonb END)
$$;

INSERT INTO sys.setting (key, value, scope, description) VALUES
  ('kyc.persons', '{"required_before": {"PASSENGER": [], "DRIVER": []}, "review_months": {"PASSENGER": 60, "DRIVER": 24}}'::jsonb, 'PLATFORM',
   'KYC of drivers and passengers (N14, 1159): what a person may do only once verified (PASSENGER: LOYALTY_REDEEM; DRIVER: DRIVE), nothing at launch; after how many months an approved file is reviewed again')
ON CONFLICT (key) DO NOTHING;

-- ------------------------------------------------------------------ a person's file
CREATE TABLE IF NOT EXISTS iam.person_kyc (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid             uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  party_id        bigint NOT NULL REFERENCES iam.party(id),
  subject_kind    text NOT NULL CHECK (subject_kind IN ('DRIVER', 'PASSENGER')),
  version         smallint NOT NULL CHECK (version >= 1),
  form_id         bigint NOT NULL REFERENCES iam.kyc_form(id),
  answers         jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(answers) = 'object'),
  completeness    smallint NOT NULL DEFAULT 0 CHECK (completeness BETWEEN 0 AND 100),
  status          text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT', 'SUBMITTED', 'RETURNED', 'APPROVED', 'REJECTED', 'SUPERSEDED')),
  return_note     text CHECK (length(return_note) <= 2000),
  return_fields   text[] NOT NULL DEFAULT '{}',
  decision_note   text CHECK (length(decision_note) <= 2000),
  submitted_by    bigint REFERENCES iam.app_user(id),
  submitted_at    timestamptz,
  decided_by      bigint REFERENCES iam.app_user(id),
  decided_at      timestamptz,
  approved_at     timestamptz,
  review_due      date,
  created_by      bigint REFERENCES iam.app_user(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_by      bigint REFERENCES iam.app_user(id),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (party_id, subject_kind, version),
  CHECK ((status IN ('APPROVED', 'SUPERSEDED')) = (approved_at IS NOT NULL)),
  CHECK (status NOT IN ('SUBMITTED', 'APPROVED', 'REJECTED', 'SUPERSEDED') OR submitted_at IS NOT NULL),
  CHECK (status NOT IN ('APPROVED', 'REJECTED', 'RETURNED') OR decided_by IS NOT NULL),
  CHECK (decided_by IS NULL OR decided_by IS DISTINCT FROM submitted_by)
);
CREATE UNIQUE INDEX IF NOT EXISTS person_kyc_one_open ON iam.person_kyc (party_id, subject_kind) WHERE status IN ('DRAFT', 'SUBMITTED', 'RETURNED');
CREATE UNIQUE INDEX IF NOT EXISTS person_kyc_one_approved ON iam.person_kyc (party_id, subject_kind) WHERE status = 'APPROVED';
CREATE INDEX IF NOT EXISTS person_kyc_form_id_fkx ON iam.person_kyc (form_id);
CREATE INDEX IF NOT EXISTS person_kyc_submitted_by_fkx ON iam.person_kyc (submitted_by);
CREATE INDEX IF NOT EXISTS person_kyc_decided_by_fkx ON iam.person_kyc (decided_by);
CREATE INDEX IF NOT EXISTS person_kyc_created_by_fkx ON iam.person_kyc (created_by);
CREATE INDEX IF NOT EXISTS person_kyc_updated_by_fkx ON iam.person_kyc (updated_by);
CREATE INDEX IF NOT EXISTS person_kyc_waiting_idx ON iam.person_kyc (submitted_at) WHERE status = 'SUBMITTED';
COMMENT ON TABLE iam.person_kyc IS 'A driver''s or passenger''s KYC file in versions: the answers to the form of their kind, one reviewer''s decision and when it is reviewed again; one open and one approved at a time (1159, N14)';
COMMENT ON COLUMN iam.person_kyc.answers IS 'The answers by field key; a sensitive value is kept as {"$enc", "$k", "$last4"}, encrypted by the application (1159)';
COMMENT ON COLUMN iam.person_kyc.decided_by IS 'The platform reviewer who decided the file: never the person who submitted it (1159)';
SELECT sys.rls('iam.person_kyc', 'sys.ctx_is_platform() OR party_id = sys.ctx_party_id()');
GRANT SELECT ON iam.person_kyc TO masslak_app, masslak_readonly;              -- written through the functions below only
DROP TRIGGER IF EXISTS person_kyc_updated ON iam.person_kyc;
CREATE TRIGGER person_kyc_updated BEFORE UPDATE ON iam.person_kyc FOR EACH ROW EXECUTE FUNCTION sys.tg_set_updated_at();
DROP TRIGGER IF EXISTS zz_audit_capture ON iam.person_kyc;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR UPDATE OR DELETE ON iam.person_kyc
  FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();

CREATE OR REPLACE FUNCTION iam.person_kyc_may_touch(p_party bigint) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT sys.ctx_is_platform() OR sys.ctx_party_id() = p_party
$$;

-- the person's open file of a kind, or a new version from the approved answers
CREATE OR REPLACE FUNCTION iam.open_person_kyc(p_party bigint, p_kind text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_uid uuid; v_form bigint; v_answers jsonb;
BEGIN
  IF NOT iam.person_kyc_may_touch(p_party) THEN
    RAISE EXCEPTION 'FORBIDDEN: a person opens their own KYC file' USING ERRCODE = 'P0001';
  END IF;
  IF p_kind NOT IN ('DRIVER', 'PASSENGER') THEN
    RAISE EXCEPTION 'NOT_FOUND: no person''s file is for %', p_kind USING ERRCODE = 'P0001';
  END IF;
  PERFORM 1 FROM iam.party WHERE id = p_party FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'NOT_FOUND: no such person' USING ERRCODE = 'P0001';
  END IF;
  SELECT uid INTO v_uid FROM iam.person_kyc WHERE party_id = p_party AND subject_kind = p_kind AND status IN ('DRAFT', 'SUBMITTED', 'RETURNED');
  IF v_uid IS NOT NULL THEN
    RETURN v_uid;
  END IF;
  SELECT id INTO v_form FROM iam.kyc_form WHERE status = 'ACTIVE' AND subject_kind = p_kind;
  IF v_form IS NULL THEN
    RAISE EXCEPTION 'KYC_NO_FORM: the platform has no KYC form in force for this kind of person' USING ERRCODE = 'P0001';
  END IF;
  SELECT answers INTO v_answers FROM iam.person_kyc WHERE party_id = p_party AND subject_kind = p_kind AND status = 'APPROVED';
  IF v_answers IS NULL THEN
    SELECT jsonb_strip_nulls(jsonb_build_object('nationality', p.nationality, 'birth_date', p.birth_date::text, 'mother_name', p.mother_name))
      INTO v_answers FROM iam.party p WHERE p.id = p_party;
  END IF;
  INSERT INTO iam.person_kyc (party_id, subject_kind, version, form_id, answers, created_by, updated_by)
  VALUES (p_party, p_kind, (SELECT coalesce(max(version), 0) + 1 FROM iam.person_kyc WHERE party_id = p_party AND subject_kind = p_kind),
          v_form, coalesce(v_answers, '{}'::jsonb), sys.ctx_user_id(), sys.ctx_user_id())
  RETURNING uid INTO v_uid;
  RETURN v_uid;
END $$;

CREATE OR REPLACE FUNCTION iam.save_person_kyc(p_uid uuid, p_answers jsonb, p_completeness smallint) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE k iam.person_kyc;
BEGIN
  SELECT * INTO k FROM iam.person_kyc WHERE uid = p_uid FOR UPDATE;
  IF k.id IS NULL OR NOT iam.person_kyc_may_touch(k.party_id) THEN
    RAISE EXCEPTION 'NOT_FOUND: no such KYC file' USING ERRCODE = 'P0001';
  END IF;
  IF k.status NOT IN ('DRAFT', 'RETURNED') THEN
    RAISE EXCEPTION 'KYC_LOCKED: the file is %; it is filled while it is a draft or returned', lower(k.status) USING ERRCODE = 'P0001';
  END IF;
  UPDATE iam.person_kyc SET answers = p_answers, completeness = p_completeness, updated_by = sys.ctx_user_id() WHERE id = k.id;
END $$;

-- what a person's file still lacks: the fields of its form (a person's form asks for no documents)
CREATE OR REPLACE FUNCTION iam.person_kyc_missing(p_uid uuid) RETURNS text[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT iam.kyc_missing(f.definition - 'documents', k.answers, NULL)
    FROM iam.person_kyc k JOIN iam.kyc_form f ON f.id = k.form_id
   WHERE k.uid = p_uid AND iam.person_kyc_may_touch(k.party_id)
$$;

CREATE OR REPLACE FUNCTION iam.submit_person_kyc(p_uid uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE k iam.person_kyc; v_missing text[];
BEGIN
  SELECT * INTO k FROM iam.person_kyc WHERE uid = p_uid FOR UPDATE;
  IF k.id IS NULL OR NOT iam.person_kyc_may_touch(k.party_id) THEN
    RAISE EXCEPTION 'NOT_FOUND: no such KYC file' USING ERRCODE = 'P0001';
  END IF;
  IF k.status NOT IN ('DRAFT', 'RETURNED') THEN
    RAISE EXCEPTION 'KYC_LOCKED: the file is already %', lower(k.status) USING ERRCODE = 'P0001';
  END IF;
  v_missing := iam.person_kyc_missing(p_uid);
  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION 'KYC_INCOMPLETE: % item(s) missing: %', cardinality(v_missing), array_to_string(v_missing[1:10], ', ')
      USING ERRCODE = 'P0001';
  END IF;
  UPDATE iam.person_kyc
     SET status = 'SUBMITTED', completeness = 100, return_note = NULL, return_fields = '{}', decided_by = NULL, decided_at = NULL,
         decision_note = NULL, submitted_by = sys.ctx_user_id(), submitted_at = now()
   WHERE id = k.id;
  -- a person not yet verified is now waiting for it
  UPDATE iam.party SET verification_status = 'PENDING' WHERE id = k.party_id AND verification_status IN ('UNVERIFIED', 'REJECTED');
  RETURN jsonb_build_object('status', 'SUBMITTED');
END $$;

-- one platform reviewer decides: approved, returned for correction, or rejected
CREATE OR REPLACE FUNCTION iam.decide_person_kyc(p_uid uuid, p_decision text, p_note text, p_fields text[]) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE k iam.person_kyc; v_months int; v_due date;
BEGIN
  IF NOT (sys.ctx_is_platform() AND iam.ctx_has_permission('kyc.review.compliance')) THEN
    RAISE EXCEPTION 'FORBIDDEN: a compliance reviewer decides a person''s KYC file' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO k FROM iam.person_kyc WHERE uid = p_uid FOR UPDATE;
  IF k.id IS NULL THEN
    RAISE EXCEPTION 'NOT_FOUND: no such KYC file' USING ERRCODE = 'P0001';
  END IF;
  IF k.status <> 'SUBMITTED' THEN
    RAISE EXCEPTION 'KYC_NOT_IN_REVIEW: the file is %', lower(k.status) USING ERRCODE = 'P0001';
  END IF;
  IF k.submitted_by = sys.ctx_user_id() OR (SELECT party_id FROM iam.app_user WHERE id = sys.ctx_user_id()) = k.party_id THEN
    RAISE EXCEPTION 'SECOND_PERSON_REQUIRED: the file is decided by someone other than who entered it' USING ERRCODE = 'P0001';
  END IF;
  IF p_decision NOT IN ('APPROVE', 'RETURN', 'REJECT') THEN
    RAISE EXCEPTION 'KYC_INVALID: the decision is APPROVE, RETURN or REJECT' USING ERRCODE = 'P0001';
  END IF;
  IF p_decision IN ('RETURN', 'REJECT') AND length(btrim(coalesce(p_note, ''))) < 3 THEN
    RAISE EXCEPTION 'REASON_REQUIRED: a returned or rejected file says why' USING ERRCODE = 'P0001';
  END IF;
  IF p_decision = 'APPROVE' THEN
    v_months := coalesce((iam.kyc_setting('kyc.persons') -> 'review_months' ->> k.subject_kind)::int, 24);
    v_due := (now() + make_interval(months => v_months))::date;
    UPDATE iam.person_kyc SET status = 'SUPERSEDED' WHERE party_id = k.party_id AND subject_kind = k.subject_kind AND status = 'APPROVED';
    UPDATE iam.person_kyc SET status = 'APPROVED', approved_at = now(), review_due = v_due, decided_by = sys.ctx_user_id(),
                              decided_at = now(), decision_note = nullif(btrim(p_note), '')
     WHERE id = k.id;
    UPDATE iam.party SET verification_status = 'VERIFIED' WHERE id = k.party_id;
  ELSIF p_decision = 'RETURN' THEN
    UPDATE iam.person_kyc SET status = 'RETURNED', return_note = btrim(p_note), return_fields = coalesce(p_fields, '{}'),
                              decided_by = sys.ctx_user_id(), decided_at = now()
     WHERE id = k.id;
  ELSE
    UPDATE iam.person_kyc SET status = 'REJECTED', decision_note = btrim(p_note), decided_by = sys.ctx_user_id(), decided_at = now()
     WHERE id = k.id;
  END IF;
  -- a person whose earlier file is still approved stays verified; otherwise they wait or are refused
  IF p_decision <> 'APPROVE' AND NOT EXISTS (SELECT 1 FROM iam.person_kyc WHERE party_id = k.party_id AND status = 'APPROVED') THEN
    UPDATE iam.party SET verification_status = CASE p_decision WHEN 'REJECT' THEN 'REJECTED' ELSE 'UNVERIFIED' END
     WHERE id = k.party_id AND verification_status <> 'VERIFIED';
  END IF;
  RETURN jsonb_build_object('status', CASE p_decision WHEN 'APPROVE' THEN 'APPROVED' WHEN 'RETURN' THEN 'RETURNED' ELSE 'REJECTED' END,
                            'review_due', v_due);
END $$;

-- ------------------------------------------------------------------ what a person may do only once verified
CREATE OR REPLACE FUNCTION iam.person_verified(p_party bigint, p_kind text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM iam.person_kyc k WHERE k.party_id = p_party AND k.subject_kind = p_kind AND k.status = 'APPROVED'
                    AND (k.review_due IS NULL OR k.review_due >= current_date))
$$;

CREATE OR REPLACE FUNCTION iam.person_kyc_gate(p_party bigint, p_kind text, p_action text) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF coalesce(iam.kyc_setting('kyc.persons') -> 'required_before' -> p_kind ? p_action, false) AND NOT iam.person_verified(p_party, p_kind) THEN
    RAISE EXCEPTION 'KYC_REQUIRED: % needs an approved KYC file first', lower(replace(p_action, '_', ' ')) USING ERRCODE = 'P0001';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pricing.tg_points_kyc_gate() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.txn_type = 'REDEEM' THEN
    PERFORM iam.person_kyc_gate((SELECT a.party_id FROM pricing.points_account a WHERE a.id = NEW.account_id), 'PASSENGER', 'LOYALTY_REDEEM');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS b_points_kyc_gate ON pricing.points_ledger;
CREATE TRIGGER b_points_kyc_gate BEFORE INSERT ON pricing.points_ledger FOR EACH ROW EXECUTE FUNCTION pricing.tg_points_kyc_gate();

CREATE OR REPLACE FUNCTION ops.tg_crew_kyc_gate() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM fleet.crew_profile cp WHERE cp.party_id = NEW.party_id AND cp.crew_type = 'DRIVER') THEN
    PERFORM iam.person_kyc_gate(NEW.party_id, 'DRIVER', 'DRIVE');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS crew_kyc_gate ON ops.crew_assignment;
CREATE TRIGGER crew_kyc_gate BEFORE INSERT OR UPDATE OF party_id ON ops.crew_assignment FOR EACH ROW EXECUTE FUNCTION ops.tg_crew_kyc_gate();

-- ------------------------------------------------------------------ the first forms of the new kinds
INSERT INTO iam.kyc_form (version, subject_kind, definition, status, note, activated_at)
SELECT (SELECT coalesce(max(version), 0) + 1 FROM iam.kyc_form), 'AGENCY', $kyc${"sections": [{"key": "identity", "fields": [{"key": "legal_name", "type": "text", "required": true, "max": 160}, {"key": "trade_name", "type": "text", "max": 160}, {"key": "legal_form", "type": "select", "options": "legal_form", "required": true}, {"key": "registration_country", "type": "country", "required": true}, {"key": "cr_no", "type": "text", "required": true, "max": 60}, {"key": "incorporation_date", "type": "date", "required": true}, {"key": "agency_license_no", "type": "text", "required": true, "max": 60}, {"key": "license_issuer", "type": "text", "required": true, "max": 120}, {"key": "license_expiry_date", "type": "date", "required": true}, {"key": "iata_accredited", "type": "yesno", "details": true}, {"key": "website", "type": "url", "max": 200}]}, {"key": "contacts", "fields": [{"key": "hq_governorate", "type": "text", "required": true, "max": 60}, {"key": "hq_city", "type": "text", "required": true, "max": 60}, {"key": "hq_address", "type": "textarea", "required": true, "max": 400}, {"key": "company_phone", "type": "phone", "required": true}, {"key": "company_email", "type": "email", "required": true}, {"key": "contacts", "type": "table", "required": true, "min_rows": 1, "columns": [{"key": "role", "type": "select", "options": "contact_role", "required": true}, {"key": "name", "type": "text", "required": true}, {"key": "title", "type": "text"}, {"key": "phone", "type": "phone", "required": true}, {"key": "email", "type": "email", "required": true}]}]}, {"key": "ownership", "fields": [{"key": "ubos", "type": "table", "required": true, "min_rows": 1, "hint": true, "columns": [{"key": "name", "type": "text", "required": true}, {"key": "nationality", "type": "country", "required": true}, {"key": "birth_date", "type": "date", "required": true}, {"key": "residence_country", "type": "country", "required": true}, {"key": "id_type", "type": "select", "options": "id_type", "required": true}, {"key": "id_number", "type": "text", "required": true, "sensitive": true}, {"key": "control_type", "type": "select", "options": "control_type", "required": true}, {"key": "ownership_pct", "type": "percent"}, {"key": "pep", "type": "bool"}]}, {"key": "signatories", "type": "table", "required": true, "min_rows": 1, "columns": [{"key": "name", "type": "text", "required": true}, {"key": "position", "type": "text"}, {"key": "id_type", "type": "select", "options": "id_type", "required": true}, {"key": "id_number", "type": "text", "required": true, "sensitive": true}, {"key": "authority", "type": "select", "options": "sign_authority", "required": true}]}]}, {"key": "screening", "fields": [{"key": "pep_any", "type": "yesno", "required": true, "details_required": true, "details": true}, {"key": "sanctions_listed", "type": "yesno", "required": true, "details_required": true, "details": true}, {"key": "criminal_record", "type": "yesno", "required": true, "details_required": true, "details": true}, {"key": "litigation", "type": "yesno", "required": true, "details_required": true, "details": true}, {"key": "aml_policy", "type": "yesno", "required": true}, {"key": "cash_handling_controls", "type": "yesno", "required": true, "details": true}]}, {"key": "financial", "fields": [{"key": "revenue_last_year", "type": "money", "required": true}, {"key": "ticket_sales_monthly", "type": "money", "required": true}, {"key": "cash_share_pct", "type": "percent", "required": true}, {"key": "source_of_funds", "type": "select", "options": "funds_source", "required": true}, {"key": "bank_accounts", "type": "table", "required": true, "min_rows": 1, "columns": [{"key": "bank", "type": "text", "required": true}, {"key": "branch", "type": "text"}, {"key": "holder", "type": "text", "required": true}, {"key": "iban", "type": "text", "required": true, "sensitive": true}, {"key": "currency", "type": "select", "options": "currency", "required": true}]}]}, {"key": "tax", "fields": [{"key": "tax_id", "type": "text", "required": true, "max": 40}, {"key": "tax_office", "type": "text", "required": true, "max": 120}, {"key": "tax_regime", "type": "select", "options": "tax_regime", "required": true}, {"key": "tax_clearance", "type": "yesno", "required": true, "details": true}]}, {"key": "agency_operations", "fields": [{"key": "agency_services", "type": "multi", "options": "agency_service", "required": true}, {"key": "sales_channels", "type": "multi", "options": "sales_channel", "required": true}, {"key": "branches", "type": "table", "required": true, "min_rows": 1, "columns": [{"key": "city", "type": "text", "required": true}, {"key": "address", "type": "text", "required": true}, {"key": "staff", "type": "number", "min": 0, "max": 10000}, {"key": "phone", "type": "phone"}]}, {"key": "sub_agents", "type": "yesno", "required": true, "details": true}]}, {"key": "consents", "fields": [{"key": "consent_processing", "type": "bool", "required": true, "accept": true}, {"key": "consent_screening", "type": "bool", "required": true, "accept": true}, {"key": "commit_updates", "type": "bool", "required": true, "accept": true}, {"key": "declarant_name", "type": "text", "required": true, "max": 120}, {"key": "declarant_position", "type": "text", "required": true, "max": 120}, {"key": "attestation", "type": "bool", "required": true, "accept": true}]}], "option_sets": {"legal_form": ["SOLE_PROPRIETORSHIP", "GENERAL_PARTNERSHIP", "LIMITED_PARTNERSHIP", "LLC", "JSC_PRIVATE", "JSC_PUBLIC", "HOLDING", "COOPERATIVE", "PUBLIC_ENTITY", "FOREIGN_BRANCH", "OTHER"], "contact_role": ["GENERAL_MANAGER", "COMPLIANCE", "FINANCE", "OPERATIONS", "TECHNICAL"], "id_type": ["NATIONAL_ID", "PASSPORT", "RESIDENCE", "CR"], "control_type": ["OWNERSHIP", "VOTING", "OTHER_MEANS", "SENIOR_MANAGER"], "sign_authority": ["SOLE", "JOINT"], "currency": ["SYP", "USD", "EUR", "TRY", "JOD", "LBP", "AED"], "funds_source": ["OPERATING_REVENUE", "OWNERS_CAPITAL", "BANK_FINANCING", "INVESTORS", "GRANTS", "OTHER"], "tax_regime": ["REAL_PROFITS", "LUMP_SUM", "SIMPLIFIED", "EXEMPT", "OTHER"], "sales_channel": ["COUNTER", "PHONE", "AGENTS", "WEBSITE", "APP", "SOCIAL", "OTHER_PLATFORM"], "agency_service": ["TICKETS", "GROUP_TOURS", "CHARTER", "PILGRIMAGE", "VISAS", "PARCELS", "OTHER"]}, "documents": [{"type": "CR", "required": true}, {"type": "AGENCY_LICENSE", "required": true}, {"type": "TAX_CERT", "required": true}, {"type": "ID_DOCUMENT", "required": true}, {"type": "BANK_LETTER", "required": false}, {"type": "POA", "required": false}]}$kyc$::jsonb, 'ACTIVE',
       'The first version of the agency form (1159)', now()
WHERE NOT EXISTS (SELECT 1 FROM iam.kyc_form WHERE subject_kind = 'AGENCY');

INSERT INTO iam.kyc_form (version, subject_kind, definition, status, note, activated_at)
SELECT (SELECT coalesce(max(version), 0) + 1 FROM iam.kyc_form), 'STATION', $kyc${"sections": [{"key": "identity", "fields": [{"key": "legal_name", "type": "text", "required": true, "max": 160}, {"key": "trade_name", "type": "text", "max": 160}, {"key": "legal_form", "type": "select", "options": "legal_form", "required": true}, {"key": "registration_country", "type": "country", "required": true}, {"key": "cr_no", "type": "text", "required": true, "max": 60}, {"key": "incorporation_date", "type": "date", "required": true}, {"key": "station_ownership", "type": "select", "options": "station_ownership", "required": true}, {"key": "operating_permit_no", "type": "text", "required": true, "max": 60}, {"key": "permit_issuer", "type": "text", "required": true, "max": 120}, {"key": "permit_expiry_date", "type": "date", "required": true}]}, {"key": "contacts", "fields": [{"key": "hq_governorate", "type": "text", "required": true, "max": 60}, {"key": "hq_city", "type": "text", "required": true, "max": 60}, {"key": "hq_address", "type": "textarea", "required": true, "max": 400}, {"key": "company_phone", "type": "phone", "required": true}, {"key": "company_email", "type": "email", "required": true}, {"key": "contacts", "type": "table", "required": true, "min_rows": 1, "columns": [{"key": "role", "type": "select", "options": "contact_role", "required": true}, {"key": "name", "type": "text", "required": true}, {"key": "title", "type": "text"}, {"key": "phone", "type": "phone", "required": true}, {"key": "email", "type": "email", "required": true}]}]}, {"key": "ownership", "fields": [{"key": "ubos", "type": "table", "required": true, "min_rows": 1, "hint": true, "columns": [{"key": "name", "type": "text", "required": true}, {"key": "nationality", "type": "country", "required": true}, {"key": "birth_date", "type": "date", "required": true}, {"key": "residence_country", "type": "country", "required": true}, {"key": "id_type", "type": "select", "options": "id_type", "required": true}, {"key": "id_number", "type": "text", "required": true, "sensitive": true}, {"key": "control_type", "type": "select", "options": "control_type", "required": true}, {"key": "ownership_pct", "type": "percent"}, {"key": "pep", "type": "bool"}]}, {"key": "signatories", "type": "table", "required": true, "min_rows": 1, "columns": [{"key": "name", "type": "text", "required": true}, {"key": "position", "type": "text"}, {"key": "id_type", "type": "select", "options": "id_type", "required": true}, {"key": "id_number", "type": "text", "required": true, "sensitive": true}, {"key": "authority", "type": "select", "options": "sign_authority", "required": true}]}]}, {"key": "screening", "fields": [{"key": "pep_any", "type": "yesno", "required": true, "details_required": true, "details": true}, {"key": "sanctions_listed", "type": "yesno", "required": true, "details_required": true, "details": true}, {"key": "criminal_record", "type": "yesno", "required": true, "details_required": true, "details": true}, {"key": "litigation", "type": "yesno", "required": true, "details_required": true, "details": true}, {"key": "aml_policy", "type": "yesno", "required": true}, {"key": "cash_handling_controls", "type": "yesno", "required": true, "details": true}]}, {"key": "station_site", "fields": [{"key": "station_name", "type": "text", "required": true, "max": 160}, {"key": "site_address", "type": "textarea", "required": true, "max": 400}, {"key": "bays_count", "type": "number", "required": true, "min": 0, "max": 500}, {"key": "counters_count", "type": "number", "required": true, "min": 0, "max": 500}, {"key": "daily_departures", "type": "number", "required": true, "min": 0, "max": 100000}, {"key": "carriers_served", "type": "number", "min": 0, "max": 10000}, {"key": "station_facilities", "type": "multi", "options": "station_facility", "required": true}, {"key": "opening_hours", "type": "text", "max": 120}, {"key": "security_staff", "type": "yesno", "required": true, "details": true}]}, {"key": "financial", "fields": [{"key": "revenue_last_year", "type": "money", "required": true}, {"key": "station_fees", "type": "multi", "options": "station_fee"}, {"key": "source_of_funds", "type": "select", "options": "funds_source", "required": true}, {"key": "bank_accounts", "type": "table", "required": true, "min_rows": 1, "columns": [{"key": "bank", "type": "text", "required": true}, {"key": "branch", "type": "text"}, {"key": "holder", "type": "text", "required": true}, {"key": "iban", "type": "text", "required": true, "sensitive": true}, {"key": "currency", "type": "select", "options": "currency", "required": true}]}]}, {"key": "tax", "fields": [{"key": "tax_id", "type": "text", "required": true, "max": 40}, {"key": "tax_office", "type": "text", "required": true, "max": 120}, {"key": "tax_regime", "type": "select", "options": "tax_regime", "required": true}, {"key": "tax_clearance", "type": "yesno", "required": true, "details": true}]}, {"key": "consents", "fields": [{"key": "consent_processing", "type": "bool", "required": true, "accept": true}, {"key": "consent_screening", "type": "bool", "required": true, "accept": true}, {"key": "commit_updates", "type": "bool", "required": true, "accept": true}, {"key": "declarant_name", "type": "text", "required": true, "max": 120}, {"key": "declarant_position", "type": "text", "required": true, "max": 120}, {"key": "attestation", "type": "bool", "required": true, "accept": true}]}], "option_sets": {"legal_form": ["SOLE_PROPRIETORSHIP", "GENERAL_PARTNERSHIP", "LIMITED_PARTNERSHIP", "LLC", "JSC_PRIVATE", "JSC_PUBLIC", "HOLDING", "COOPERATIVE", "PUBLIC_ENTITY", "FOREIGN_BRANCH", "OTHER"], "contact_role": ["GENERAL_MANAGER", "COMPLIANCE", "FINANCE", "OPERATIONS", "TECHNICAL"], "id_type": ["NATIONAL_ID", "PASSPORT", "RESIDENCE", "CR"], "control_type": ["OWNERSHIP", "VOTING", "OTHER_MEANS", "SENIOR_MANAGER"], "sign_authority": ["SOLE", "JOINT"], "currency": ["SYP", "USD", "EUR", "TRY", "JOD", "LBP", "AED"], "funds_source": ["OPERATING_REVENUE", "OWNERS_CAPITAL", "BANK_FINANCING", "INVESTORS", "GRANTS", "OTHER"], "tax_regime": ["REAL_PROFITS", "LUMP_SUM", "SIMPLIFIED", "EXEMPT", "OTHER"], "station_ownership": ["PUBLIC", "PRIVATE", "PUBLIC_PRIVATE", "MUNICIPAL"], "station_facility": ["WAITING_HALL", "TOILETS", "PRAYER_ROOM", "CAFE", "PARKING", "ACCESSIBLE", "CCTV", "LUGGAGE_STORE"], "station_fee": ["BAY_FEE", "DEPARTURE_FEE", "COUNTER_RENT", "PARKING", "OTHER"]}, "documents": [{"type": "CR", "required": true}, {"type": "TAX_CERT", "required": true}, {"type": "ID_DOCUMENT", "required": true}, {"type": "BANK_LETTER", "required": false}, {"type": "OTHER", "required": false}]}$kyc$::jsonb, 'ACTIVE',
       'The first version of the station form (1159)', now()
WHERE NOT EXISTS (SELECT 1 FROM iam.kyc_form WHERE subject_kind = 'STATION');

INSERT INTO iam.kyc_form (version, subject_kind, definition, status, note, activated_at)
SELECT (SELECT coalesce(max(version), 0) + 1 FROM iam.kyc_form), 'DRIVER', $kyc${"sections": [{"key": "person_identity", "fields": [{"key": "nationality", "type": "country", "required": true}, {"key": "id_type", "type": "select", "options": "person_id_type", "required": true}, {"key": "id_number", "type": "text", "required": true, "sensitive": true}, {"key": "id_expiry", "type": "date"}, {"key": "birth_date", "type": "date", "required": true}, {"key": "birth_place", "type": "text", "max": 120}, {"key": "mother_name", "type": "text", "max": 60}]}, {"key": "residence", "fields": [{"key": "residence_governorate", "type": "text", "required": true, "max": 60}, {"key": "residence_city", "type": "text", "required": true, "max": 60}, {"key": "residence_address", "type": "textarea", "required": true, "max": 400}, {"key": "emergency_name", "type": "text", "required": true, "max": 120}, {"key": "emergency_phone", "type": "phone", "required": true}]}, {"key": "driving_record", "fields": [{"key": "years_driving", "type": "number", "required": true, "min": 0, "max": 70}, {"key": "licence_classes", "type": "multi", "options": "licence_class", "required": true}, {"key": "previous_employers", "type": "textarea", "max": 1000}, {"key": "cross_border_experience", "type": "yesno", "details": true}, {"key": "traffic_violations", "type": "yesno", "required": true, "details_required": true, "details": true}, {"key": "serious_accidents", "type": "yesno", "required": true, "details_required": true, "details": true}]}, {"key": "person_screening", "fields": [{"key": "criminal_record", "type": "yesno", "required": true, "details_required": true, "details": true}, {"key": "medical_conditions", "type": "yesno", "required": true, "details_required": true, "details": true}, {"key": "pep_any", "type": "yesno", "required": true, "details_required": true, "details": true}]}, {"key": "person_consents", "fields": [{"key": "consent_processing", "type": "bool", "required": true, "accept": true}, {"key": "consent_screening", "type": "bool", "required": true, "accept": true}, {"key": "attestation", "type": "bool", "required": true, "accept": true}]}], "option_sets": {"person_id_type": ["NATIONAL_ID", "PASSPORT", "RESIDENCE"], "licence_class": ["B", "C", "C1", "D", "D1", "E"]}}$kyc$::jsonb, 'ACTIVE',
       'The first version of the driver form (1159)', now()
WHERE NOT EXISTS (SELECT 1 FROM iam.kyc_form WHERE subject_kind = 'DRIVER');

INSERT INTO iam.kyc_form (version, subject_kind, definition, status, note, activated_at)
SELECT (SELECT coalesce(max(version), 0) + 1 FROM iam.kyc_form), 'PASSENGER', $kyc${"sections": [{"key": "person_identity", "fields": [{"key": "nationality", "type": "country", "required": true}, {"key": "id_type", "type": "select", "options": "person_id_type", "required": true}, {"key": "id_number", "type": "text", "required": true, "sensitive": true}, {"key": "id_expiry", "type": "date"}, {"key": "birth_date", "type": "date", "required": true}, {"key": "birth_place", "type": "text", "max": 120}, {"key": "mother_name", "type": "text", "max": 60}]}, {"key": "residence", "fields": [{"key": "residence_governorate", "type": "text", "required": true, "max": 60}, {"key": "residence_city", "type": "text", "required": true, "max": 60}, {"key": "residence_address", "type": "textarea", "required": true, "max": 400}, {"key": "occupation", "type": "text", "max": 120}, {"key": "source_of_funds", "type": "select", "options": "person_funds"}]}, {"key": "person_screening", "fields": [{"key": "pep_any", "type": "yesno", "required": true, "details_required": true, "details": true}]}, {"key": "person_consents", "fields": [{"key": "consent_processing", "type": "bool", "required": true, "accept": true}, {"key": "attestation", "type": "bool", "required": true, "accept": true}]}], "option_sets": {"person_id_type": ["NATIONAL_ID", "PASSPORT", "RESIDENCE"], "person_funds": ["SALARY", "BUSINESS", "FAMILY", "PENSION", "STUDENT", "OTHER"]}}$kyc$::jsonb, 'ACTIVE',
       'The first version of the passenger form (1159)', now()
WHERE NOT EXISTS (SELECT 1 FROM iam.kyc_form WHERE subject_kind = 'PASSENGER');

-- ------------------------------------------------------------------ grants
REVOKE ALL ON FUNCTION iam.kyc_kind_of_company(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.save_kyc_form(jsonb, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.save_kyc_form(jsonb, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.activate_kyc_form(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.open_company_kyc(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.kyc_setting_problem(text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.kyc_setting(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.person_kyc_may_touch(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.open_person_kyc(bigint, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.save_person_kyc(uuid, jsonb, smallint) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.person_kyc_missing(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.submit_person_kyc(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.decide_person_kyc(uuid, text, text, text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.person_verified(bigint, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.person_kyc_gate(bigint, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pricing.tg_points_kyc_gate() FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.tg_crew_kyc_gate() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION iam.kyc_kind_of_company(bigint), iam.save_kyc_form(jsonb, text, text), iam.save_kyc_form(jsonb, text),
  iam.activate_kyc_form(integer), iam.open_company_kyc(bigint), iam.kyc_setting_problem(text, jsonb), iam.kyc_setting(text),
  iam.open_person_kyc(bigint, text), iam.save_person_kyc(uuid, jsonb, smallint), iam.person_kyc_missing(uuid),
  iam.submit_person_kyc(uuid), iam.decide_person_kyc(uuid, text, text, text[]), iam.person_verified(bigint, text)
  TO masslak_app;
COMMENT ON FUNCTION iam.kyc_kind_of_company IS 'The KYC form a company fills: an agency''s, a station operating company''s, or a carrier''s (1159, N14)';
COMMENT ON FUNCTION iam.save_kyc_form(jsonb, text, text) IS 'The platform saves the draft of the next version of a kind''s KYC form, checked; one draft for each kind (1159)';
COMMENT ON FUNCTION iam.save_kyc_form(jsonb, text) IS 'The carriers'' KYC form draft, as before 1159';
COMMENT ON FUNCTION iam.person_kyc_may_touch IS 'Whether the caller works on a person''s KYC file: the person or the platform (1159)';
COMMENT ON FUNCTION iam.open_person_kyc IS 'A driver''s or passenger''s open KYC file, or a new version from the approved answers or what the platform knows (1159)';
COMMENT ON FUNCTION iam.save_person_kyc IS 'The answers of a person''s KYC file, while it is a draft or returned (1159)';
COMMENT ON FUNCTION iam.person_kyc_missing IS 'What a person''s KYC file still lacks (1159)';
COMMENT ON FUNCTION iam.submit_person_kyc IS 'A complete person''s KYC file goes for review; the person waits for verification (1159)';
COMMENT ON FUNCTION iam.decide_person_kyc IS 'A compliance reviewer, not the person who entered it, approves, returns or rejects a person''s KYC file; approval verifies the person (1159)';
COMMENT ON FUNCTION iam.person_verified IS 'Whether a person holds an approved KYC file of a kind that is not yet due for review (1159)';
COMMENT ON FUNCTION iam.person_kyc_gate IS 'Refuses what kyc.persons allows only once verified (1159)';
COMMENT ON FUNCTION pricing.tg_points_kyc_gate IS 'While kyc.persons asks for it, a passenger redeems points only once verified (1159)';
COMMENT ON FUNCTION ops.tg_crew_kyc_gate IS 'While kyc.persons asks for it, a driver is put on a trip only once verified (1159)';

-- the owner of a station operating company fills its file (permissions of the station portal, 1099)
UPDATE iam.permission SET description = 'Fill and submit the company''s KYC file (carriers, agencies and station operating companies)'
 WHERE code = 'company.kyc';
INSERT INTO iam.role_permission (role_id, permission_code)
SELECT r.id, 'company.kyc' FROM iam.role r WHERE r.code IN ('AGENCY_ADMIN', 'STATION_ADMIN') AND r.company_id IS NULL
ON CONFLICT DO NOTHING;

-- ------------------------------------------------------------------ registration
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('iam.person_kyc', '1A', 'E01')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
SELECT sys.refresh_table_class();
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('iam.person_kyc', 'iam personal records', 'drivers'' and passengers'' KYC files (1159)')
ON CONFLICT (table_name) DO NOTHING;
-- the proposals of the registries (1156) are empty until someone proposes a change: an empty value passes their shape
UPDATE sys.json_contract SET spec = '{"type": ["object", "null"]}'::jsonb
 WHERE table_name IN ('ref.bank', 'ref.insurer') AND column_name = 'pending_changes' AND spec = '{"type": "object"}'::jsonb;
INSERT INTO sys.json_contract (table_name, column_name, kind, version, spec, note) VALUES
  ('iam.person_kyc', 'answers', 'PAYLOAD', 1, NULL,
   'the answers by field key, the shape of the form version the file follows; sensitive values encrypted (1159)')
ON CONFLICT DO NOTHING;
SELECT sys.apply_json_contracts();
