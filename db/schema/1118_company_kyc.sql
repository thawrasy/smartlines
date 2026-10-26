-- =====================================================================
-- Masslak - 1118: know your customer (KYC) for the companies on the platform (owner's request, October 2026)
--   * When the platform establishes a company it opens its KYC file: who the company is, who owns and controls it, its
--     licences, finances and taxes, how it operates today (trips direct and with stops, passengers, routes and ticket
--     prices, stations, fleet with models and ages, staff and agents), what it expects on the platform, and its
--     declarations and consents. The content follows the international standards compliance, tax and finance officers
--     and transport regulators ask for: FATF Recommendations 10 and 24 (customer due diligence, beneficial ownership,
--     politically exposed persons, sanctions screening, source of funds and wealth), the OECD Common Reporting Standard
--     entity status, and the licensing, fleet and insurance facts a transport authority asks for.
--   * The form is data, not code: a versioned definition (iam.kyc_form) of sections, fields, option sets and the
--     documents asked for. The platform adds or changes fields in a new version and activates it, so a new rule from a
--     regulator needs no new release. Its labels for the built-in fields live in the interface's locale files; a field
--     the platform adds carries its own labels in English and Arabic. The database checks every version.
--   * A company's file (iam.company_kyc) holds the answers. The company fills it in its portal, or platform staff
--     capture it from paper; values marked sensitive (identity document and account numbers) are encrypted by the
--     application before they are stored. Once complete, with the documents asked for uploaded, it is submitted and
--     passes the review stages of the settings in order: compliance, finance, tax, or a government authority whose
--     members decide (sec.authority_member, 1117). One person decides one stage; a stage approves, returns the file to
--     the company with what to correct, or rejects it. Each decision is kept (iam.kyc_decision).
--   * Risk is scored from the answers by rules that are settings (kyc.risk_rules): each rule adds points, and may set a
--     minimum level; a sanctions match makes the file prohibited, which cannot be approved. The compliance stage may set
--     another level with its reason. An approved file is reviewed again after the months its level sets; an update is a
--     new version of the file, the approved one staying in force until the new one is approved.
--   * The platform may require an approved file before a company publishes trips or withdraws money
--     (kyc.required_before); off by default.
-- =====================================================================

-- ------------------------------------------------------------------ the settings
INSERT INTO sys.setting (key, value, scope, description) VALUES
  ('kyc.review_stages', '[{"by":"COMPLIANCE"},{"by":"FINANCE"}]'::jsonb, 'PLATFORM',
   'Who reviews a company''s KYC file, in order: COMPLIANCE, FINANCE, TAX, or a government authority by its code, {"by":"AUTHORITY","authority":"MOT"} (1118)'),
  ('kyc.risk_rules', $rules$[
     {"code": "SANCTIONS", "field": "sanctions_listed", "op": "yes", "points": 100, "level": "PROHIBITED"},
     {"code": "SANCTIONED_DEALINGS", "field": "sanctioned_dealings", "op": "yes", "points": 40, "level": "HIGH"},
     {"code": "PEP", "field": "pep_any", "op": "yes", "points": 30, "level": "HIGH"},
     {"code": "PEP_OWNER", "field": "ubos", "op": "any_row", "where": {"column": "pep", "op": "yes"}, "points": 30, "level": "HIGH"},
     {"code": "CRIMINAL_RECORD", "field": "criminal_record", "op": "yes", "points": 40, "level": "HIGH"},
     {"code": "BEARER_SHARES", "field": "bearer_shares", "op": "yes", "points": 25},
     {"code": "OWNERSHIP_LAYERS", "field": "ownership_layers", "op": "gte", "value": 2, "points": 15},
     {"code": "FOREIGN_OWNER", "field": "ubos", "op": "any_row", "where": {"column": "residence_country", "op": "not_in", "value": ["SY"]}, "points": 10},
     {"code": "CASH_HEAVY", "field": "cash_share_pct", "op": "gte", "value": 80, "points": 15},
     {"code": "NO_AML_POLICY", "field": "aml_policy", "op": "no", "points": 5},
     {"code": "NO_CASH_CONTROLS", "field": "cash_handling_controls", "op": "no", "points": 10},
     {"code": "LITIGATION", "field": "litigation", "op": "yes", "points": 10},
     {"code": "PENALTIES", "field": "penalties", "op": "yes", "points": 10},
     {"code": "ADVERSE_MEDIA", "field": "adverse_media", "op": "yes", "points": 20},
     {"code": "LICENCE_SUSPENDED", "field": "license_suspended", "op": "yes", "points": 15},
     {"code": "INTERNATIONAL", "field": "service_types", "op": "has", "value": "INTERNATIONAL", "points": 10},
     {"code": "YOUNG_COMPANY", "field": "incorporation_date", "op": "younger_than_months", "value": 12, "points": 10},
     {"code": "NO_TAX_CLEARANCE", "field": "tax_clearance", "op": "no", "points": 10},
     {"code": "OLD_FLEET", "field": "fleet_avg_age", "op": "gte", "value": 20, "points": 5}
   ]$rules$::jsonb, 'PLATFORM',
   'How a KYC file''s risk is scored: each rule that matches the answers adds its points and may set a minimum level (MEDIUM, HIGH, PROHIBITED) (1118)'),
  ('kyc.risk_levels', '{"MEDIUM": 25, "HIGH": 50}'::jsonb, 'PLATFORM',
   'The scores from which a KYC file is of medium and of high risk (1118)'),
  ('kyc.review_months', '{"LOW": 36, "MEDIUM": 24, "HIGH": 12}'::jsonb, 'PLATFORM',
   'After how many months an approved KYC file is reviewed again, by its risk level (1118)'),
  ('kyc.ubo_threshold_pct', '25'::jsonb, 'PLATFORM',
   'The share of ownership or control from which a natural person is a beneficial owner, 5 to 50 (1118)'),
  ('kyc.documents_on_submit', 'true'::jsonb, 'PLATFORM',
   'Whether the documents the form asks for must be uploaded before a KYC file is submitted (1118)'),
  ('kyc.required_before', '[]'::jsonb, 'PLATFORM',
   'What a company may do only with an approved KYC file: PUBLISH_TRIPS, PAYOUTS (1118)'),
  ('kyc.distinct_reviewers', 'true'::jsonb, 'PLATFORM',
   'Whether each review stage of a KYC file is decided by a different person (1118)')
ON CONFLICT (key) DO NOTHING;

-- the document types the form may ask for (the application's documents page knows the same list)
CREATE OR REPLACE FUNCTION iam.kyc_document_types() RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT ARRAY['CR', 'ARTICLES', 'TRANSPORT_LICENSE', 'TAX_CERT', 'ID_DOCUMENT', 'BANK_LETTER', 'INSURANCE_POLICY', 'POA',
               'OWNERSHIP_CHART', 'CHAMBER_CERT', 'FINANCIAL_STATEMENTS', 'TAX_CLEARANCE', 'VEHICLE_REG', 'AGENCY_LICENSE', 'OTHER']
$$;

-- a label the platform gives a field, a section or an option it adds: English and Arabic
CREATE OR REPLACE FUNCTION iam.kyc_label_ok(p jsonb) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT CASE WHEN jsonb_typeof(p) = 'object'
              THEN coalesce(jsonb_typeof(p -> 'en') = 'string' AND length(btrim(p ->> 'en')) BETWEEN 1 AND 300
                            AND jsonb_typeof(p -> 'ar') = 'string' AND length(btrim(p ->> 'ar')) BETWEEN 1 AND 300
                            AND NOT EXISTS (SELECT 1 FROM jsonb_object_keys(p) k WHERE k NOT IN ('en', 'ar')), false)
              ELSE false END
$$;

-- what is wrong with one field (or one column of a table), or NULL
CREATE OR REPLACE FUNCTION iam.kyc_field_problem(f jsonb, p_sets jsonb, p_in_table boolean) RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_key text := f ->> 'key'; v_type text := f ->> 'type'; k text;
BEGIN
  IF jsonb_typeof(f) IS DISTINCT FROM 'object' OR coalesce(v_key, '') !~ '^[a-z][a-z0-9_]{1,40}$' THEN
    RETURN 'each field has a key of 2 to 41 characters (a-z, 0-9, _)';
  END IF;
  FOR k IN SELECT jsonb_object_keys(f) LOOP
    IF k NOT IN ('key', 'type', 'required', 'sensitive', 'options', 'min', 'max', 'min_rows', 'columns', 'details',
                 'details_required', 'hint', 'accept', 'label', 'help') THEN
      RETURN format('field %s: %s is not a property of a field', v_key, k);
    END IF;
  END LOOP;
  IF NOT coalesce(v_type = ANY (CASE WHEN p_in_table
       THEN ARRAY['text', 'email', 'phone', 'number', 'decimal', 'percent', 'money', 'date', 'time', 'select', 'bool', 'country', 'station']
       ELSE ARRAY['text', 'textarea', 'email', 'phone', 'url', 'number', 'decimal', 'percent', 'money', 'date', 'time', 'select',
                  'multi', 'yesno', 'bool', 'country', 'station', 'table'] END), false) THEN
    RETURN format('field %s: %s is not a type of %s', v_key, coalesce(v_type, 'null'), CASE WHEN p_in_table THEN 'column' ELSE 'field' END);
  END IF;
  FOR k IN SELECT x FROM unnest(ARRAY['required', 'sensitive', 'details', 'details_required', 'hint', 'accept']) x LOOP
    IF f ? k AND jsonb_typeof(f -> k) <> 'boolean' THEN
      RETURN format('field %s: %s is true or false', v_key, k);
    END IF;
  END LOOP;
  IF (f ->> 'sensitive')::boolean AND v_type <> 'text' THEN
    RETURN format('field %s: only a text field is kept encrypted', v_key);
  END IF;
  IF v_type IN ('select', 'multi') <> (f ? 'options') THEN
    RETURN format('field %s: a choice names its option set, and only a choice does', v_key);
  END IF;
  IF f ? 'options' AND (jsonb_typeof(f -> 'options') <> 'string' OR NOT p_sets ? (f ->> 'options')) THEN
    RETURN format('field %s: no option set is called %s', v_key, f ->> 'options');
  END IF;
  IF (f ? 'details' OR f ? 'details_required') AND v_type <> 'yesno' THEN
    RETURN format('field %s: only a yes-or-no question asks for details', v_key);
  END IF;
  IF f ? 'accept' AND v_type <> 'bool' THEN
    RETURN format('field %s: only a box to tick is accepted', v_key);
  END IF;
  IF (f ? 'min' AND jsonb_typeof(f -> 'min') <> 'number') OR (f ? 'max' AND jsonb_typeof(f -> 'max') <> 'number')
     OR (f ? 'min' AND f ? 'max' AND (f ->> 'min')::numeric > (f ->> 'max')::numeric) THEN
    RETURN format('field %s: min and max are numbers, min not above max', v_key);
  END IF;
  IF f ? 'min_rows' AND (v_type <> 'table' OR jsonb_typeof(f -> 'min_rows') <> 'number' OR (f ->> 'min_rows') !~ '^[0-9]{1,2}$') THEN
    RETURN format('field %s: min_rows is a number of rows of a table', v_key);
  END IF;
  IF (v_type = 'table') <> (f ? 'columns') THEN
    RETURN format('field %s: a table has columns, and only a table does', v_key);
  END IF;
  IF f ? 'label' AND NOT iam.kyc_label_ok(f -> 'label') THEN
    RETURN format('field %s: its label is {"en": "...", "ar": "..."}', v_key);
  END IF;
  IF f ? 'help' AND NOT iam.kyc_label_ok(f -> 'help') THEN
    RETURN format('field %s: its help is {"en": "...", "ar": "..."}', v_key);
  END IF;
  RETURN NULL;
END $$;

-- what is wrong with a definition of the form, or NULL when it is valid
CREATE OR REPLACE FUNCTION iam.kyc_form_problem(p jsonb) RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog, pg_temp AS $$
DECLARE s jsonb; f jsonb; col jsonb; d jsonb; k text; val jsonb; v_problem text;
        v_sections text[] := '{}'; v_keys text[] := '{}'; v_cols text[]; v_docs text[] := '{}'; v_sets jsonb;
BEGIN
  IF jsonb_typeof(p) IS DISTINCT FROM 'object' OR jsonb_typeof(p -> 'sections') IS DISTINCT FROM 'array'
     OR jsonb_array_length(p -> 'sections') NOT BETWEEN 1 AND 40 THEN
    RETURN 'the form is {"sections": [...], "option_sets": {...}, "documents": [...]} with 1 to 40 sections';
  END IF;
  FOR k IN SELECT jsonb_object_keys(p) LOOP
    IF k NOT IN ('sections', 'option_sets', 'documents') THEN
      RETURN format('%s is not a part of the form', k);
    END IF;
  END LOOP;
  v_sets := coalesce(p -> 'option_sets', '{}'::jsonb);
  IF jsonb_typeof(v_sets) <> 'object' THEN
    RETURN 'option_sets is an object of lists';
  END IF;
  FOR k, val IN SELECT * FROM jsonb_each(v_sets) LOOP
    IF k !~ '^[a-z][a-z0-9_]{1,40}$' OR jsonb_typeof(val) <> 'array' OR jsonb_array_length(val) NOT BETWEEN 1 AND 200 THEN
      RETURN format('option set %s is a list of 1 to 200 values', k);
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(val) o
                WHERE NOT coalesce((jsonb_typeof(o) = 'string' AND (o #>> '{}') ~ '^[A-Z0-9][A-Z0-9_]{0,39}$')
                                   OR (jsonb_typeof(o) = 'object' AND (o ->> 'value') ~ '^[A-Z0-9][A-Z0-9_]{0,39}$'
                                       AND iam.kyc_label_ok(o -> 'label')
                                       AND NOT EXISTS (SELECT 1 FROM jsonb_object_keys(o) ok WHERE ok NOT IN ('value', 'label'))), false))
       OR (SELECT count(DISTINCT coalesce(o ->> 'value', o #>> '{}')) FROM jsonb_array_elements(val) o) <> jsonb_array_length(val) THEN
      RETURN format('option set %s: each value is a code (A-Z, 0-9, _) given once, with its label in English and Arabic when the platform adds it', k);
    END IF;
  END LOOP;
  FOR s IN SELECT x FROM jsonb_array_elements(p -> 'sections') x LOOP
    IF jsonb_typeof(s) IS DISTINCT FROM 'object' OR coalesce(s ->> 'key', '') !~ '^[a-z][a-z0-9_]{1,40}$'
       OR EXISTS (SELECT 1 FROM jsonb_object_keys(s) sk WHERE sk NOT IN ('key', 'fields', 'label')) THEN
      RETURN 'each section is {"key": "...", "fields": [...]}, with a label when the platform adds it';
    END IF;
    IF (s ->> 'key') = ANY (v_sections) THEN
      RETURN format('section %s appears twice', s ->> 'key');
    END IF;
    v_sections := v_sections || (s ->> 'key');
    IF s ? 'label' AND NOT iam.kyc_label_ok(s -> 'label') THEN
      RETURN format('section %s: its label is {"en": "...", "ar": "..."}', s ->> 'key');
    END IF;
    IF jsonb_typeof(s -> 'fields') IS DISTINCT FROM 'array' OR jsonb_array_length(s -> 'fields') NOT BETWEEN 1 AND 100 THEN
      RETURN format('section %s has a list of 1 to 100 fields', s ->> 'key');
    END IF;
    FOR f IN SELECT x FROM jsonb_array_elements(s -> 'fields') x LOOP
      v_problem := iam.kyc_field_problem(f, v_sets, false);
      IF v_problem IS NOT NULL THEN
        RETURN v_problem;
      END IF;
      IF (f ->> 'key') = ANY (v_keys) THEN
        RETURN format('field %s appears twice', f ->> 'key');
      END IF;
      v_keys := v_keys || (f ->> 'key');
      IF f ->> 'type' = 'table' THEN
        IF jsonb_typeof(f -> 'columns') <> 'array' OR jsonb_array_length(f -> 'columns') NOT BETWEEN 1 AND 20 THEN
          RETURN format('table %s has 1 to 20 columns', f ->> 'key');
        END IF;
        v_cols := '{}';
        FOR col IN SELECT x FROM jsonb_array_elements(f -> 'columns') x LOOP
          v_problem := iam.kyc_field_problem(col, v_sets, true);
          IF v_problem IS NOT NULL THEN
            RETURN format('table %s: %s', f ->> 'key', v_problem);
          END IF;
          IF (col ->> 'key') = ANY (v_cols) THEN
            RETURN format('table %s: column %s appears twice', f ->> 'key', col ->> 'key');
          END IF;
          v_cols := v_cols || (col ->> 'key');
        END LOOP;
      END IF;
    END LOOP;
  END LOOP;
  IF p ? 'documents' THEN
    IF jsonb_typeof(p -> 'documents') <> 'array' THEN
      RETURN 'documents is a list of {"type": "...", "required": true or false}';
    END IF;
    FOR d IN SELECT x FROM jsonb_array_elements(p -> 'documents') x LOOP
      IF jsonb_typeof(d) <> 'object' OR NOT coalesce((d ->> 'type') = ANY (iam.kyc_document_types()), false)
         OR jsonb_typeof(d -> 'required') IS DISTINCT FROM 'boolean'
         OR EXISTS (SELECT 1 FROM jsonb_object_keys(d) dk WHERE dk NOT IN ('type', 'required')) THEN
        RETURN format('each document is {"type": one of %s, "required": true or false}', array_to_string(iam.kyc_document_types(), ', '));
      END IF;
      IF (d ->> 'type') = ANY (v_docs) THEN
        RETURN format('document %s is asked twice', d ->> 'type');
      END IF;
      v_docs := v_docs || (d ->> 'type');
    END LOOP;
  END IF;
  RETURN NULL;
END $$;

-- ------------------------------------------------------------------ the form, in versions
CREATE TABLE IF NOT EXISTS iam.kyc_form (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  version       integer NOT NULL UNIQUE CHECK (version >= 1),
  definition    jsonb NOT NULL CHECK (iam.kyc_form_problem(definition) IS NULL),
  status        text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT', 'ACTIVE', 'RETIRED')),
  note          text CHECK (length(note) <= 500),
  created_by    bigint REFERENCES iam.app_user(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  activated_by  bigint REFERENCES iam.app_user(id),
  activated_at  timestamptz,
  CHECK ((status = 'DRAFT') = (activated_at IS NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS kyc_form_one_active ON iam.kyc_form ((true)) WHERE status = 'ACTIVE';
CREATE INDEX IF NOT EXISTS kyc_form_created_by_fkx ON iam.kyc_form (created_by);
CREATE INDEX IF NOT EXISTS kyc_form_activated_by_fkx ON iam.kyc_form (activated_by);
COMMENT ON TABLE iam.kyc_form IS 'The KYC form in versions: its sections, fields, option sets and documents; one version is active, a new one is checked and activated by the platform (1118)';
SELECT sys.rls_catalog('iam.kyc_form');
GRANT SELECT ON iam.kyc_form TO masslak_app, masslak_readonly;              -- written through the functions below only

-- a version in force is never changed: the platform makes a new one
CREATE OR REPLACE FUNCTION iam.tg_kyc_form_frozen() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'DRAFT' THEN
      RAISE EXCEPTION 'KYC_FORM_FROZEN: a version that was in force is kept' USING ERRCODE = 'P0001';
    END IF;
    RETURN OLD;
  END IF;
  IF OLD.status <> 'DRAFT' AND (NEW.definition IS DISTINCT FROM OLD.definition OR NEW.version <> OLD.version) THEN
    RAISE EXCEPTION 'KYC_FORM_FROZEN: a version that was in force is not changed; make a new version' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS kyc_form_frozen ON iam.kyc_form;
CREATE TRIGGER kyc_form_frozen BEFORE UPDATE OR DELETE ON iam.kyc_form FOR EACH ROW EXECUTE FUNCTION iam.tg_kyc_form_frozen();

-- the first version: the complete form compliance, tax, finance and the transport regulators ask for
INSERT INTO iam.kyc_form (version, definition, status, note, activated_at)
SELECT 1, $kyc$
{"sections": [
  {"key": "identity", "fields": [
    {"key": "legal_name", "type": "text", "required": true, "max": 160},
    {"key": "trade_name", "type": "text", "max": 160},
    {"key": "legal_form", "type": "select", "options": "legal_form", "required": true},
    {"key": "registration_country", "type": "country", "required": true},
    {"key": "cr_no", "type": "text", "required": true, "max": 60},
    {"key": "cr_issue_date", "type": "date"},
    {"key": "cr_expiry_date", "type": "date"},
    {"key": "cr_authority", "type": "text", "max": 120},
    {"key": "incorporation_date", "type": "date", "required": true},
    {"key": "chamber_no", "type": "text", "max": 60},
    {"key": "lei", "type": "text", "max": 20},
    {"key": "paid_capital", "type": "money"},
    {"key": "business_activity", "type": "textarea", "required": true, "max": 1000},
    {"key": "group_member", "type": "yesno", "details_required": true, "details": true},
    {"key": "website", "type": "url", "max": 200}
  ]},
  {"key": "licensing", "fields": [
    {"key": "transport_license_no", "type": "text", "required": true, "max": 60},
    {"key": "license_issuer", "type": "text", "required": true, "max": 120},
    {"key": "license_issue_date", "type": "date"},
    {"key": "license_expiry_date", "type": "date", "required": true},
    {"key": "license_scope", "type": "multi", "options": "license_scope", "required": true},
    {"key": "route_permits", "type": "yesno", "required": true, "details": true},
    {"key": "license_suspended", "type": "yesno", "details_required": true, "required": true, "details": true},
    {"key": "regulator_code", "type": "text", "max": 40}
  ]},
  {"key": "contacts", "fields": [
    {"key": "hq_governorate", "type": "text", "required": true, "max": 60},
    {"key": "hq_city", "type": "text", "required": true, "max": 60},
    {"key": "hq_address", "type": "textarea", "required": true, "max": 400},
    {"key": "postal_code", "type": "text", "max": 20},
    {"key": "operating_address_differs", "type": "yesno", "details_required": true, "details": true},
    {"key": "company_phone", "type": "phone", "required": true},
    {"key": "company_email", "type": "email", "required": true},
    {"key": "contacts", "type": "table", "required": true, "min_rows": 2, "hint": true, "columns": [
      {"key": "role", "type": "select", "options": "contact_role", "required": true},
      {"key": "name", "type": "text", "required": true},
      {"key": "title", "type": "text"},
      {"key": "phone", "type": "phone", "required": true},
      {"key": "email", "type": "email", "required": true}
    ]}
  ]},
  {"key": "ownership", "fields": [
    {"key": "shareholders", "type": "table", "required": true, "min_rows": 1, "columns": [
      {"key": "holder_type", "type": "select", "options": "holder_type", "required": true},
      {"key": "name", "type": "text", "required": true},
      {"key": "nationality", "type": "country", "required": true},
      {"key": "id_type", "type": "select", "options": "id_type", "required": true},
      {"key": "id_number", "type": "text", "required": true, "sensitive": true},
      {"key": "ownership_pct", "type": "percent", "required": true},
      {"key": "voting_pct", "type": "percent"},
      {"key": "pep", "type": "bool"}
    ]},
    {"key": "ubos", "type": "table", "required": true, "min_rows": 1, "hint": true, "columns": [
      {"key": "name", "type": "text", "required": true},
      {"key": "nationality", "type": "country", "required": true},
      {"key": "birth_date", "type": "date", "required": true},
      {"key": "residence_country", "type": "country", "required": true},
      {"key": "id_type", "type": "select", "options": "id_type", "required": true},
      {"key": "id_number", "type": "text", "required": true, "sensitive": true},
      {"key": "id_expiry", "type": "date"},
      {"key": "control_type", "type": "select", "options": "control_type", "required": true},
      {"key": "ownership_pct", "type": "percent"},
      {"key": "pep", "type": "bool"},
      {"key": "pep_role", "type": "text"}
    ]},
    {"key": "ownership_layers", "type": "number", "required": true, "min": 0, "max": 10, "hint": true},
    {"key": "bearer_shares", "type": "yesno", "required": true, "details_required": true, "details": true},
    {"key": "directors", "type": "table", "required": true, "min_rows": 1, "columns": [
      {"key": "name", "type": "text", "required": true},
      {"key": "position", "type": "text", "required": true},
      {"key": "nationality", "type": "country", "required": true},
      {"key": "id_type", "type": "select", "options": "id_type", "required": true},
      {"key": "id_number", "type": "text", "required": true, "sensitive": true},
      {"key": "appointed", "type": "date"},
      {"key": "pep", "type": "bool"}
    ]},
    {"key": "signatories", "type": "table", "required": true, "min_rows": 1, "columns": [
      {"key": "name", "type": "text", "required": true},
      {"key": "position", "type": "text"},
      {"key": "id_type", "type": "select", "options": "id_type", "required": true},
      {"key": "id_number", "type": "text", "required": true, "sensitive": true},
      {"key": "authority", "type": "select", "options": "sign_authority", "required": true},
      {"key": "limit", "type": "money"}
    ]}
  ]},
  {"key": "screening", "fields": [
    {"key": "pep_any", "type": "yesno", "required": true, "details_required": true, "details": true},
    {"key": "sanctions_listed", "type": "yesno", "required": true, "details_required": true, "details": true},
    {"key": "sanctioned_dealings", "type": "yesno", "required": true, "details_required": true, "details": true},
    {"key": "criminal_record", "type": "yesno", "required": true, "details_required": true, "details": true},
    {"key": "litigation", "type": "yesno", "required": true, "details_required": true, "details": true},
    {"key": "penalties", "type": "yesno", "required": true, "details_required": true, "details": true},
    {"key": "adverse_media", "type": "yesno", "details": true},
    {"key": "aml_policy", "type": "yesno", "required": true},
    {"key": "cash_handling_controls", "type": "yesno", "required": true, "details": true}
  ]},
  {"key": "financial", "fields": [
    {"key": "fiscal_year_end", "type": "number", "min": 1, "max": 12},
    {"key": "revenue_last_year", "type": "money", "required": true},
    {"key": "ticket_sales_monthly", "type": "money", "required": true},
    {"key": "cash_share_pct", "type": "percent", "required": true},
    {"key": "payment_methods", "type": "multi", "options": "payment_method", "required": true},
    {"key": "source_of_funds", "type": "select", "options": "funds_source", "required": true},
    {"key": "source_of_funds_details", "type": "textarea", "max": 1000},
    {"key": "source_of_wealth", "type": "textarea", "max": 1000, "hint": true},
    {"key": "bank_accounts", "type": "table", "required": true, "min_rows": 1, "columns": [
      {"key": "bank", "type": "text", "required": true},
      {"key": "branch", "type": "text"},
      {"key": "holder", "type": "text", "required": true},
      {"key": "iban", "type": "text", "required": true, "sensitive": true},
      {"key": "currency", "type": "select", "options": "currency", "required": true},
      {"key": "purpose", "type": "select", "options": "account_purpose"}
    ]},
    {"key": "audited_accounts", "type": "yesno", "details_required": true, "details": true},
    {"key": "settlement_cycle", "type": "select", "options": "settlement_cycle", "required": true},
    {"key": "passenger_insurance", "type": "yesno", "required": true, "details_required": true, "details": true}
  ]},
  {"key": "tax", "fields": [
    {"key": "tax_id", "type": "text", "required": true, "max": 40},
    {"key": "tax_office", "type": "text", "required": true, "max": 120},
    {"key": "tax_regime", "type": "select", "options": "tax_regime", "required": true},
    {"key": "tax_residency", "type": "country", "required": true},
    {"key": "indirect_tax_registered", "type": "yesno", "required": true, "details_required": true, "details": true},
    {"key": "prices_include_tax", "type": "yesno", "required": true},
    {"key": "stamp_duty", "type": "yesno"},
    {"key": "withholding", "type": "yesno", "details": true},
    {"key": "invoicing_today", "type": "select", "options": "invoicing", "required": true},
    {"key": "einvoice_mandate", "type": "yesno", "required": true},
    {"key": "crs_status", "type": "select", "options": "crs_status"},
    {"key": "tax_clearance", "type": "yesno", "required": true, "details_required": true, "details": true},
    {"key": "tax_disputes", "type": "yesno", "details": true}
  ]},
  {"key": "operations", "fields": [
    {"key": "operating_since", "type": "number", "required": true, "min": 1900, "max": 2100},
    {"key": "service_types", "type": "multi", "options": "service_type", "required": true},
    {"key": "trips_direct_week", "type": "number", "required": true, "min": 0, "max": 100000},
    {"key": "trips_indirect_week", "type": "number", "required": true, "min": 0, "max": 100000},
    {"key": "passengers_month", "type": "number", "required": true, "min": 0, "max": 100000000},
    {"key": "parcels_month", "type": "number", "min": 0, "max": 100000000},
    {"key": "routes", "type": "table", "required": true, "min_rows": 1, "columns": [
      {"key": "origin", "type": "station", "required": true},
      {"key": "destination", "type": "station", "required": true},
      {"key": "via", "type": "text"},
      {"key": "trips_day", "type": "number", "min": 0, "max": 500},
      {"key": "first_departure", "type": "time"},
      {"key": "last_departure", "type": "time"},
      {"key": "price", "type": "money", "required": true},
      {"key": "occupancy_pct", "type": "percent"},
      {"key": "permit_no", "type": "text"}
    ]},
    {"key": "stations_used", "type": "table", "required": true, "min_rows": 1, "columns": [
      {"key": "station", "type": "station", "required": true},
      {"key": "facility", "type": "select", "options": "facility", "required": true},
      {"key": "bays", "type": "text"},
      {"key": "staff", "type": "number", "min": 0, "max": 10000}
    ]},
    {"key": "sales_channels", "type": "multi", "options": "sales_channel", "required": true},
    {"key": "current_system", "type": "select", "options": "current_system", "required": true},
    {"key": "current_process", "type": "textarea", "required": true, "max": 2000},
    {"key": "refund_policy", "type": "textarea", "max": 2000},
    {"key": "peak_seasons", "type": "text", "max": 200}
  ]},
  {"key": "fleet", "fields": [
    {"key": "vehicles_total", "type": "number", "required": true, "min": 0, "max": 100000},
    {"key": "fleet", "type": "table", "required": true, "min_rows": 1, "columns": [
      {"key": "vtype", "type": "select", "options": "vehicle_type", "required": true},
      {"key": "make", "type": "text", "required": true},
      {"key": "model", "type": "text", "required": true},
      {"key": "count", "type": "number", "required": true, "min": 1, "max": 100000},
      {"key": "seats", "type": "number", "min": 1, "max": 120},
      {"key": "avg_year", "type": "number", "min": 1950, "max": 2100},
      {"key": "fuel", "type": "select", "options": "fuel"},
      {"key": "ownership", "type": "select", "options": "vehicle_ownership"},
      {"key": "ac", "type": "bool"},
      {"key": "accessible", "type": "bool"}
    ]},
    {"key": "fleet_avg_age", "type": "decimal", "required": true, "min": 0, "max": 80},
    {"key": "oldest_vehicle_year", "type": "number", "min": 1950, "max": 2100},
    {"key": "technical_inspection", "type": "yesno", "required": true, "details": true},
    {"key": "maintenance", "type": "select", "options": "maintenance"},
    {"key": "gps_tracking", "type": "yesno", "details": true},
    {"key": "cctv", "type": "yesno"},
    {"key": "vehicle_insurance", "type": "yesno", "required": true, "details": true}
  ]},
  {"key": "people", "fields": [
    {"key": "employees_total", "type": "number", "required": true, "min": 0, "max": 1000000},
    {"key": "staff", "type": "table", "columns": [
      {"key": "function", "type": "select", "options": "staff_function", "required": true},
      {"key": "count", "type": "number", "required": true, "min": 0, "max": 1000000}
    ]},
    {"key": "drivers_licensed", "type": "number", "required": true, "min": 0, "max": 1000000},
    {"key": "driver_training", "type": "yesno", "details": true},
    {"key": "social_insurance", "type": "yesno", "required": true, "details": true},
    {"key": "agents_total", "type": "number", "required": true, "min": 0, "max": 100000},
    {"key": "agents", "type": "table", "columns": [
      {"key": "name", "type": "text", "required": true},
      {"key": "city", "type": "text", "required": true},
      {"key": "commission_pct", "type": "percent"},
      {"key": "monthly_sales", "type": "money"},
      {"key": "contract", "type": "bool"}
    ]}
  ]},
  {"key": "projections", "fields": [
    {"key": "expected_trips_week_6m", "type": "number", "required": true, "min": 0, "max": 100000},
    {"key": "expected_trips_week_12m", "type": "number", "required": true, "min": 0, "max": 100000},
    {"key": "expected_passengers_month_6m", "type": "number", "required": true, "min": 0, "max": 100000000},
    {"key": "expected_passengers_month_12m", "type": "number", "required": true, "min": 0, "max": 100000000},
    {"key": "expected_online_share_pct", "type": "percent"},
    {"key": "expected_new_routes", "type": "textarea", "max": 1000},
    {"key": "expected_fleet_growth", "type": "number", "min": 0, "max": 100000},
    {"key": "go_live_date", "type": "date"}
  ]},
  {"key": "expectations", "fields": [
    {"key": "objectives", "type": "multi", "options": "objective", "required": true},
    {"key": "top_features", "type": "textarea", "max": 1000},
    {"key": "integrations", "type": "textarea", "max": 1000},
    {"key": "users_to_train", "type": "number", "min": 0, "max": 10000},
    {"key": "support_needs", "type": "textarea", "max": 1000},
    {"key": "concerns", "type": "textarea", "max": 1000},
    {"key": "referral", "type": "select", "options": "referral"}
  ]},
  {"key": "consents", "fields": [
    {"key": "consent_processing", "type": "bool", "required": true, "accept": true},
    {"key": "consent_screening", "type": "bool", "required": true, "accept": true},
    {"key": "consent_authorities", "type": "bool", "required": true, "accept": true},
    {"key": "commit_updates", "type": "bool", "required": true, "accept": true},
    {"key": "declarant_name", "type": "text", "required": true, "max": 120},
    {"key": "declarant_position", "type": "text", "required": true, "max": 120},
    {"key": "attestation", "type": "bool", "required": true, "accept": true}
  ]}
], "option_sets": {
  "legal_form": ["SOLE_PROPRIETORSHIP", "GENERAL_PARTNERSHIP", "LIMITED_PARTNERSHIP", "LLC", "JSC_PRIVATE", "JSC_PUBLIC", "HOLDING", "COOPERATIVE", "PUBLIC_ENTITY", "FOREIGN_BRANCH", "OTHER"],
  "license_scope": ["INTERCITY", "INTERNATIONAL", "URBAN", "TOURISM", "SCHOOL", "PARCELS", "CARGO"],
  "contact_role": ["GENERAL_MANAGER", "COMPLIANCE", "FINANCE", "OPERATIONS", "TECHNICAL"],
  "holder_type": ["PERSON", "COMPANY"],
  "id_type": ["NATIONAL_ID", "PASSPORT", "RESIDENCE", "CR"],
  "control_type": ["OWNERSHIP", "VOTING", "OTHER_MEANS", "SENIOR_MANAGER"],
  "sign_authority": ["SOLE", "JOINT"],
  "payment_method": ["CASH", "BANK_TRANSFER", "CARD", "MOBILE_WALLET", "AGENT_CREDIT", "OTHER"],
  "funds_source": ["OPERATING_REVENUE", "OWNERS_CAPITAL", "BANK_FINANCING", "INVESTORS", "GRANTS", "OTHER"],
  "currency": ["SYP", "USD", "EUR", "TRY", "JOD", "LBP", "AED"],
  "account_purpose": ["SETTLEMENT", "OPERATIONS", "BOTH"],
  "settlement_cycle": ["DAILY", "WEEKLY", "MONTHLY"],
  "tax_regime": ["REAL_PROFITS", "LUMP_SUM", "SIMPLIFIED", "EXEMPT", "OTHER"],
  "invoicing": ["NONE", "PAPER", "OWN_SYSTEM", "PROVIDER"],
  "crs_status": ["ACTIVE_NFE", "PASSIVE_NFE", "FINANCIAL_INSTITUTION", "NOT_KNOWN"],
  "service_type": ["INTERCITY_DIRECT", "INTERCITY_INDIRECT", "INTERNATIONAL", "SHUTTLE", "SCHOOL", "TOURISM", "PARCELS", "CARGO"],
  "facility": ["COUNTER", "OFFICE", "BAY_ONLY", "AGENT"],
  "sales_channel": ["COUNTER", "PHONE", "AGENTS", "WEBSITE", "APP", "SOCIAL", "OTHER_PLATFORM"],
  "current_system": ["PAPER", "SPREADSHEET", "OWN_SOFTWARE", "THIRD_PARTY"],
  "vehicle_type": ["COACH", "MIDIBUS", "MINIBUS", "VAN", "TRUCK"],
  "fuel": ["DIESEL", "PETROL", "CNG", "HYBRID", "ELECTRIC"],
  "vehicle_ownership": ["OWNED", "LEASED", "PARTNER"],
  "maintenance": ["IN_HOUSE", "CONTRACTED", "MIXED"],
  "staff_function": ["DRIVERS", "ASSISTANTS", "COUNTER", "MAINTENANCE", "ADMIN", "OTHER"],
  "objective": ["ONLINE_SALES", "SEAT_CONTROL", "CASH_CONTROL", "AGENTS", "REPORTS", "EINVOICE", "TRACKING", "REGULATORY", "PARCELS"],
  "referral": ["SALES_TEAM", "ANOTHER_CARRIER", "AUTHORITY", "MEDIA", "OTHER"]
}, "documents": [
  {"type": "CR", "required": true},
  {"type": "ARTICLES", "required": true},
  {"type": "TRANSPORT_LICENSE", "required": true},
  {"type": "TAX_CERT", "required": true},
  {"type": "ID_DOCUMENT", "required": true},
  {"type": "BANK_LETTER", "required": true},
  {"type": "INSURANCE_POLICY", "required": true},
  {"type": "POA", "required": false},
  {"type": "OWNERSHIP_CHART", "required": false},
  {"type": "CHAMBER_CERT", "required": false},
  {"type": "FINANCIAL_STATEMENTS", "required": false},
  {"type": "TAX_CLEARANCE", "required": false},
  {"type": "VEHICLE_REG", "required": false}
]}
$kyc$::jsonb, 'ACTIVE', 'The first version of the form (1118)', now()
WHERE NOT EXISTS (SELECT 1 FROM iam.kyc_form);

-- ------------------------------------------------------------------ settings: checked, with defaults
CREATE OR REPLACE FUNCTION iam.kyc_rule_problem(r jsonb, p_nested boolean) RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_op text := r ->> 'op'; v_ops text[] := ARRAY['yes', 'no', 'eq', 'ne', 'in', 'not_in', 'gte', 'lte', 'has', 'younger_than_months'];
BEGIN
  IF jsonb_typeof(r) IS DISTINCT FROM 'object' THEN
    RETURN 'each rule is an object';
  END IF;
  IF p_nested THEN
    IF coalesce(r ->> 'column', '') !~ '^[a-z][a-z0-9_]{1,40}$'
       OR EXISTS (SELECT 1 FROM jsonb_object_keys(r) k WHERE k NOT IN ('column', 'op', 'value')) THEN
      RETURN 'the condition on a row is {"column": "...", "op": "...", "value": ...}';
    END IF;
  ELSE
    IF coalesce(r ->> 'code', '') !~ '^[A-Z][A-Z0-9_]{1,40}$' OR coalesce(r ->> 'field', '') !~ '^[a-z][a-z0-9_]{1,40}$'
       OR EXISTS (SELECT 1 FROM jsonb_object_keys(r) k WHERE k NOT IN ('code', 'field', 'op', 'value', 'where', 'points', 'level')) THEN
      RETURN 'each rule is {"code": "A_CODE", "field": "a_field", "op": "...", "value": ..., "points": 0-100, "level": "MEDIUM|HIGH|PROHIBITED"}';
    END IF;
    IF r ? 'points' AND NOT (jsonb_typeof(r -> 'points') = 'number' AND (r ->> 'points') ~ '^[0-9]{1,3}$' AND (r ->> 'points')::int <= 100) THEN
      RETURN format('rule %s: points are 0 to 100', r ->> 'code');
    END IF;
    IF r ? 'level' AND NOT coalesce(r ->> 'level' IN ('MEDIUM', 'HIGH', 'PROHIBITED'), false) THEN
      RETURN format('rule %s: the level is MEDIUM, HIGH or PROHIBITED', r ->> 'code');
    END IF;
    IF v_op = 'any_row' THEN
      IF NOT r ? 'where' OR r ? 'value' THEN
        RETURN format('rule %s: any_row tests the rows of a table with "where"', r ->> 'code');
      END IF;
      RETURN iam.kyc_rule_problem(r -> 'where', true);
    ELSIF r ? 'where' THEN
      RETURN format('rule %s: only any_row has "where"', r ->> 'code');
    END IF;
  END IF;
  IF NOT coalesce(v_op = ANY (v_ops), false) THEN
    RETURN format('%s is not a test; the tests are %s, and any_row for a table', coalesce(v_op, 'null'), array_to_string(v_ops, ', '));
  END IF;
  IF v_op IN ('yes', 'no') AND r ? 'value' THEN
    RETURN format('%s takes no value', v_op);
  END IF;
  IF v_op IN ('gte', 'lte') AND jsonb_typeof(r -> 'value') IS DISTINCT FROM 'number' THEN
    RETURN format('%s compares with a number', v_op);
  END IF;
  IF v_op IN ('in', 'not_in') AND jsonb_typeof(r -> 'value') IS DISTINCT FROM 'array' THEN
    RETURN format('%s takes a list', v_op);
  END IF;
  IF v_op IN ('eq', 'ne', 'has') AND NOT r ? 'value' THEN
    RETURN format('%s takes a value', v_op);
  END IF;
  IF v_op = 'younger_than_months' AND NOT (jsonb_typeof(r -> 'value') = 'number' AND (r ->> 'value') ~ '^[0-9]{1,3}$'
                                           AND (r ->> 'value')::int BETWEEN 1 AND 600) THEN
    RETURN 'younger_than_months takes 1 to 600 months';
  END IF;
  RETURN NULL;
END $$;

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
  ELSE
    RETURN format('%s is not a setting of KYC', p_key);
  END IF;
  RETURN NULL;
END $$;

-- the value in force: the stored one when it is valid, else the default
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
                             WHEN 'kyc.distinct_reviewers' THEN 'true'::jsonb END)
$$;

CREATE OR REPLACE FUNCTION iam.set_kyc_setting(p_key text, p_value jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_problem text;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: the settings of KYC are the platform''s' USING ERRCODE = 'P0001';
  END IF;
  v_problem := iam.kyc_setting_problem(p_key, p_value);
  IF v_problem IS NOT NULL THEN
    RAISE EXCEPTION 'INVALID_SETTING: %', v_problem USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO sys.setting (key, value, scope, description, updated_by, updated_at)
  VALUES (p_key, p_value, 'PLATFORM', 'Setting of KYC (1118)', sys.ctx_user_id(), now())
  ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  RETURN p_value;
END $$;

-- the platform makes a new version of the form, and activates one
CREATE OR REPLACE FUNCTION iam.save_kyc_form(p_definition jsonb, p_note text) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_problem text; v_version integer;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: the platform makes the KYC form' USING ERRCODE = 'P0001';
  END IF;
  v_problem := iam.kyc_form_problem(p_definition);
  IF v_problem IS NOT NULL THEN
    RAISE EXCEPTION 'KYC_FORM_INVALID: %', v_problem USING ERRCODE = 'P0001';
  END IF;
  -- one draft at a time: saving again replaces it
  SELECT version INTO v_version FROM iam.kyc_form WHERE status = 'DRAFT' FOR UPDATE;
  IF v_version IS NULL THEN
    INSERT INTO iam.kyc_form (version, definition, note, created_by)
    VALUES ((SELECT coalesce(max(version), 0) + 1 FROM iam.kyc_form), p_definition, nullif(btrim(p_note), ''), sys.ctx_user_id())
    RETURNING version INTO v_version;
  ELSE
    UPDATE iam.kyc_form SET definition = p_definition, note = nullif(btrim(p_note), ''), created_by = sys.ctx_user_id(), created_at = now()
     WHERE version = v_version;
  END IF;
  RETURN v_version;
END $$;

CREATE OR REPLACE FUNCTION iam.activate_kyc_form(p_version integer) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: the platform activates the KYC form' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM iam.kyc_form WHERE version = p_version AND status = 'DRAFT') THEN
    RAISE EXCEPTION 'NOT_FOUND: no draft version % of the form', p_version USING ERRCODE = 'P0001';
  END IF;
  UPDATE iam.kyc_form SET status = 'RETIRED' WHERE status = 'ACTIVE';
  UPDATE iam.kyc_form SET status = 'ACTIVE', activated_by = sys.ctx_user_id(), activated_at = now() WHERE version = p_version;
  RETURN p_version;
END $$;

-- ------------------------------------------------------------------ a company's KYC file
CREATE TABLE IF NOT EXISTS iam.company_kyc (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                    uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  company_id             bigint NOT NULL REFERENCES iam.company(id),
  version                smallint NOT NULL CHECK (version >= 1),
  form_id                bigint NOT NULL REFERENCES iam.kyc_form(id),
  answers                jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(answers) = 'object'),
  completeness           smallint NOT NULL DEFAULT 0 CHECK (completeness BETWEEN 0 AND 100),
  status                 text NOT NULL DEFAULT 'DRAFT'
                           CHECK (status IN ('DRAFT', 'SUBMITTED', 'RETURNED', 'APPROVED', 'REJECTED', 'SUPERSEDED')),
  round                  smallint NOT NULL DEFAULT 0 CHECK (round >= 0),
  review_stages          jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(review_stages) = 'array'),
  step                   smallint NOT NULL DEFAULT 0 CHECK (step >= 0),
  risk_score             integer CHECK (risk_score >= 0),
  risk_level             text CHECK (risk_level IN ('LOW', 'MEDIUM', 'HIGH', 'PROHIBITED')),
  risk_factors           jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(risk_factors) = 'array'),
  risk_override          text CHECK (risk_override IN ('LOW', 'MEDIUM', 'HIGH', 'PROHIBITED')),
  risk_override_reason   text CHECK (length(risk_override_reason) <= 500),
  return_note            text CHECK (length(return_note) <= 2000),
  return_fields          text[] NOT NULL DEFAULT '{}',
  submitted_by           bigint REFERENCES iam.app_user(id),
  submitted_at           timestamptz,
  decided_at             timestamptz,
  approved_at            timestamptz,
  review_due             date,
  created_by             bigint REFERENCES iam.app_user(id),
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_by             bigint REFERENCES iam.app_user(id),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  UNIQUE (company_id, version),
  CHECK ((status IN ('APPROVED', 'SUPERSEDED')) = (approved_at IS NOT NULL)),
  CHECK (status NOT IN ('SUBMITTED', 'APPROVED', 'REJECTED', 'SUPERSEDED') OR (submitted_at IS NOT NULL AND risk_level IS NOT NULL)),
  CHECK (risk_override IS NULL OR risk_override_reason IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS company_kyc_one_open ON iam.company_kyc (company_id) WHERE status IN ('DRAFT', 'SUBMITTED', 'RETURNED');
CREATE UNIQUE INDEX IF NOT EXISTS company_kyc_one_approved ON iam.company_kyc (company_id) WHERE status = 'APPROVED';
CREATE INDEX IF NOT EXISTS company_kyc_form_id_fkx ON iam.company_kyc (form_id);
CREATE INDEX IF NOT EXISTS company_kyc_submitted_by_fkx ON iam.company_kyc (submitted_by);
CREATE INDEX IF NOT EXISTS company_kyc_created_by_fkx ON iam.company_kyc (created_by);
CREATE INDEX IF NOT EXISTS company_kyc_updated_by_fkx ON iam.company_kyc (updated_by);
CREATE INDEX IF NOT EXISTS company_kyc_waiting_idx ON iam.company_kyc (submitted_at) WHERE status = 'SUBMITTED';
CREATE INDEX IF NOT EXISTS company_kyc_review_due_idx ON iam.company_kyc (review_due) WHERE status = 'APPROVED';
COMMENT ON TABLE iam.company_kyc IS 'A company''s KYC file in versions: the answers to the form, the review stages it passes, its risk and when it is reviewed again; one open and one approved at a time (1118)';
COMMENT ON COLUMN iam.company_kyc.answers IS 'The answers by field key; a sensitive value is kept as {"$enc", "$k", "$last4"}, encrypted by the application (1118)';
COMMENT ON COLUMN iam.company_kyc.review_stages IS 'The review stages in force when the file was submitted (1118)';
COMMENT ON COLUMN iam.company_kyc.risk_factors IS 'The risk rules the answers matched when the file was submitted: code, points, level (1118)';
COMMENT ON COLUMN iam.company_kyc.return_fields IS 'The fields a reviewer asked the company to correct (1118)';
SELECT sys.rls_tenant('iam.company_kyc');
GRANT SELECT ON iam.company_kyc TO masslak_app, masslak_readonly;            -- written through the functions below only
DROP TRIGGER IF EXISTS company_kyc_updated ON iam.company_kyc;
CREATE TRIGGER company_kyc_updated BEFORE UPDATE ON iam.company_kyc FOR EACH ROW EXECUTE FUNCTION sys.tg_set_updated_at();
DROP TRIGGER IF EXISTS zz_audit_capture ON iam.company_kyc;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR UPDATE OR DELETE ON iam.company_kyc
  FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();

CREATE TABLE IF NOT EXISTS iam.kyc_decision (
  kyc_id          bigint NOT NULL REFERENCES iam.company_kyc(id),
  round           smallint NOT NULL CHECK (round >= 1),
  step            smallint NOT NULL CHECK (step >= 1),
  stage           jsonb NOT NULL CHECK (jsonb_typeof(stage) = 'object'),
  decision        text NOT NULL CHECK (decision IN ('APPROVE', 'RETURN', 'REJECT')),
  note            text CHECK (length(note) <= 2000),
  fields          text[] NOT NULL DEFAULT '{}',
  risk_override   text CHECK (risk_override IN ('LOW', 'MEDIUM', 'HIGH', 'PROHIBITED')),
  decided_by      bigint NOT NULL REFERENCES iam.app_user(id),
  authority_id    bigint REFERENCES sec.authority_profile(id),
  decided_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (kyc_id, round, step)
);
CREATE INDEX IF NOT EXISTS kyc_decision_decided_by_fkx ON iam.kyc_decision (decided_by);
CREATE INDEX IF NOT EXISTS kyc_decision_authority_id_fkx ON iam.kyc_decision (authority_id);
COMMENT ON TABLE iam.kyc_decision IS 'Each review stage''s decision on a KYC file: approved, returned with what to correct, or rejected; who decided and when; never changed (1118)';
DROP TRIGGER IF EXISTS kyc_decision_immutable ON iam.kyc_decision;
CREATE TRIGGER kyc_decision_immutable BEFORE UPDATE OR DELETE ON iam.kyc_decision
  FOR EACH ROW EXECUTE FUNCTION sys.tg_forbid_mutation();
SELECT sys.rls_parent('iam.kyc_decision', 'kyc_id', 'iam.company_kyc');
GRANT SELECT ON iam.kyc_decision TO masslak_app, masslak_readonly;

-- ------------------------------------------------------------------ completeness and risk
-- whether a value answers a field
CREATE OR REPLACE FUNCTION iam.kyc_filled(f jsonb, v jsonb) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce(CASE
    WHEN f ->> 'type' = 'multi' THEN jsonb_typeof(v) = 'array' AND jsonb_array_length(v) > 0
    WHEN f ->> 'type' = 'yesno' THEN jsonb_typeof(v -> 'value') = 'boolean'
    WHEN f ->> 'type' = 'bool' THEN CASE WHEN coalesce((f ->> 'accept')::boolean, false) THEN v = 'true'::jsonb ELSE jsonb_typeof(v) = 'boolean' END
    WHEN f ->> 'type' IN ('number', 'decimal', 'percent', 'money') THEN jsonb_typeof(v) = 'number'
    ELSE (jsonb_typeof(v) = 'string' AND length(btrim(v #>> '{}')) > 0) OR (jsonb_typeof(v) = 'object' AND v ? '$enc')
  END, false)
$$;

-- what the file still lacks: required fields, the rows and columns of required tables, the details a yes asks for,
-- and the documents asked for (by "doc:<type>")
CREATE OR REPLACE FUNCTION iam.kyc_missing(p_definition jsonb, p_answers jsonb, p_company bigint) RETURNS text[]
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE f jsonb; col jsonb; v jsonb; i integer; d jsonb; v_out text[] := '{}';
BEGIN
  FOR f IN SELECT x FROM jsonb_array_elements(p_definition -> 'sections') s, jsonb_array_elements(s -> 'fields') x LOOP
    v := p_answers -> (f ->> 'key');
    IF f ->> 'type' = 'table' THEN
      IF coalesce((f ->> 'required')::boolean, false)
         AND coalesce(CASE WHEN jsonb_typeof(v) = 'array' THEN jsonb_array_length(v) END, 0) < greatest(coalesce((f ->> 'min_rows')::int, 1), 1) THEN
        v_out := v_out || (f ->> 'key');
      END IF;
      IF jsonb_typeof(v) = 'array' THEN
        FOR i IN 0 .. jsonb_array_length(v) - 1 LOOP
          FOR col IN SELECT x FROM jsonb_array_elements(f -> 'columns') x WHERE coalesce((x ->> 'required')::boolean, false) LOOP
            IF NOT iam.kyc_filled(col, v -> i -> (col ->> 'key')) THEN
              v_out := v_out || format('%s.%s.%s', f ->> 'key', i, col ->> 'key');
            END IF;
          END LOOP;
        END LOOP;
      END IF;
    ELSE
      IF coalesce((f ->> 'required')::boolean, false) AND NOT iam.kyc_filled(f, v) THEN
        v_out := v_out || (f ->> 'key');
      END IF;
      IF f ->> 'type' = 'yesno' AND coalesce((f ->> 'details_required')::boolean, false) AND (v -> 'value') = 'true'::jsonb
         AND length(btrim(coalesce(v ->> 'details', ''))) = 0 THEN
        v_out := v_out || ((f ->> 'key') || '.details');
      END IF;
    END IF;
  END LOOP;
  IF iam.kyc_setting('kyc.documents_on_submit') = 'true'::jsonb THEN
    FOR d IN SELECT x FROM jsonb_array_elements(coalesce(p_definition -> 'documents', '[]'::jsonb)) x
              WHERE coalesce((x ->> 'required')::boolean, false) LOOP
      IF NOT EXISTS (SELECT 1 FROM iam.document doc
                      WHERE doc.company_id = p_company AND doc.doc_type = d ->> 'type' AND doc.status IN ('PENDING', 'APPROVED')
                        AND (doc.expiry_date IS NULL OR doc.expiry_date >= (now() AT TIME ZONE ref.company_tz(p_company))::date)) THEN
        v_out := v_out || ('doc:' || (d ->> 'type'));
      END IF;
    END LOOP;
  END IF;
  RETURN v_out;
END $$;

-- whether a value passes one test of a risk rule
CREATE OR REPLACE FUNCTION iam.kyc_rule_hit(v jsonb, p_op text, p_arg jsonb) RETURNS boolean
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce(CASE p_op
    WHEN 'yes' THEN (jsonb_typeof(v) = 'object' AND (v -> 'value') = 'true'::jsonb) OR v = 'true'::jsonb
    WHEN 'no' THEN (jsonb_typeof(v) = 'object' AND (v -> 'value') = 'false'::jsonb) OR v = 'false'::jsonb
    WHEN 'eq' THEN v = p_arg
    WHEN 'ne' THEN v IS NOT NULL AND v <> p_arg
    WHEN 'in' THEN v IS NOT NULL AND p_arg @> jsonb_build_array(v)
    WHEN 'not_in' THEN v IS NOT NULL AND jsonb_typeof(v) = 'string' AND NOT p_arg @> jsonb_build_array(v)
    WHEN 'gte' THEN jsonb_typeof(v) = 'number' AND (v #>> '{}')::numeric >= (p_arg #>> '{}')::numeric
    WHEN 'lte' THEN jsonb_typeof(v) = 'number' AND (v #>> '{}')::numeric <= (p_arg #>> '{}')::numeric
    WHEN 'has' THEN jsonb_typeof(v) = 'array' AND v @> jsonb_build_array(p_arg)
    WHEN 'younger_than_months' THEN jsonb_typeof(v) = 'string' AND (v #>> '{}') ~ '^\d{4}-\d{2}-\d{2}$'
                                   AND (v #>> '{}')::date > current_date - make_interval(months => (p_arg #>> '{}')::int)
  END, false)
$$;

-- the risk of a set of answers by the rules in force: score, level and the rules matched
CREATE OR REPLACE FUNCTION iam.kyc_risk(p_answers jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE r jsonb; v jsonb; v_hit boolean; v_score integer := 0; v_force integer := 0; v_factors jsonb := '[]'::jsonb;
        v_levels jsonb := iam.kyc_setting('kyc.risk_levels');
BEGIN
  FOR r IN SELECT x FROM jsonb_array_elements(iam.kyc_setting('kyc.risk_rules')) x LOOP
    v := p_answers -> (r ->> 'field');
    IF r ->> 'op' = 'any_row' THEN
      v_hit := jsonb_typeof(v) = 'array'
               AND EXISTS (SELECT 1 FROM jsonb_array_elements(v) rw
                            WHERE iam.kyc_rule_hit(rw -> (r #>> '{where,column}'), r #>> '{where,op}', r #> '{where,value}'));
    ELSE
      v_hit := iam.kyc_rule_hit(v, r ->> 'op', r -> 'value');
    END IF;
    IF coalesce(v_hit, false) THEN
      v_score := v_score + coalesce((r ->> 'points')::int, 0);
      v_force := greatest(v_force, CASE r ->> 'level' WHEN 'MEDIUM' THEN 1 WHEN 'HIGH' THEN 2 WHEN 'PROHIBITED' THEN 3 ELSE 0 END);
      v_factors := v_factors || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
                     'code', r ->> 'code', 'points', coalesce((r ->> 'points')::int, 0), 'level', r ->> 'level')));
    END IF;
  END LOOP;
  RETURN jsonb_build_object('score', v_score, 'factors', v_factors, 'level',
    CASE greatest(v_force, CASE WHEN v_score >= (v_levels ->> 'HIGH')::int THEN 2 WHEN v_score >= (v_levels ->> 'MEDIUM')::int THEN 1 ELSE 0 END)
      WHEN 3 THEN 'PROHIBITED' WHEN 2 THEN 'HIGH' WHEN 1 THEN 'MEDIUM' ELSE 'LOW' END);
END $$;

-- ------------------------------------------------------------------ the file's life
CREATE OR REPLACE FUNCTION iam.kyc_may_touch(p_company bigint) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT sys.ctx_is_platform() OR sys.ctx_company_id() = p_company
$$;

-- the company's open file: the one being filled or reviewed, or a new version, which starts from the approved
-- answers, or for a first file from what the platform knows of the company
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
  SELECT id INTO v_form FROM iam.kyc_form WHERE status = 'ACTIVE';
  IF v_form IS NULL THEN
    RAISE EXCEPTION 'KYC_NO_FORM: the platform has no KYC form in force' USING ERRCODE = 'P0001';
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

-- the answers as they are filled, by the company or by platform staff from paper (checked and encrypted by the
-- application); the file is filled while it is a draft or returned
CREATE OR REPLACE FUNCTION iam.save_company_kyc(p_uid uuid, p_answers jsonb, p_completeness smallint) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE k iam.company_kyc;
BEGIN
  SELECT * INTO k FROM iam.company_kyc WHERE uid = p_uid FOR UPDATE;
  IF k.id IS NULL OR NOT iam.kyc_may_touch(k.company_id) THEN
    RAISE EXCEPTION 'NOT_FOUND: no such KYC file' USING ERRCODE = 'P0001';
  END IF;
  IF k.status NOT IN ('DRAFT', 'RETURNED') THEN
    RAISE EXCEPTION 'KYC_LOCKED: the file is %; it is filled while it is a draft or returned', lower(k.status) USING ERRCODE = 'P0001';
  END IF;
  IF jsonb_typeof(p_answers) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'KYC_INVALID: the answers are an object' USING ERRCODE = 'P0001';
  END IF;
  UPDATE iam.company_kyc SET answers = p_answers, completeness = greatest(0, least(100, coalesce(p_completeness, 0))),
         updated_by = sys.ctx_user_id()
   WHERE id = k.id;
END $$;

-- the file is sent for review once nothing is missing: its risk is scored and the review stages in force kept with it
CREATE OR REPLACE FUNCTION iam.submit_company_kyc(p_uid uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE k iam.company_kyc; v_missing text[]; v_risk jsonb; v_stages jsonb := iam.kyc_setting('kyc.review_stages');
BEGIN
  SELECT * INTO k FROM iam.company_kyc WHERE uid = p_uid FOR UPDATE;
  IF k.id IS NULL OR NOT iam.kyc_may_touch(k.company_id) THEN
    RAISE EXCEPTION 'NOT_FOUND: no such KYC file' USING ERRCODE = 'P0001';
  END IF;
  IF k.status NOT IN ('DRAFT', 'RETURNED') THEN
    RAISE EXCEPTION 'KYC_LOCKED: the file is already %', lower(k.status) USING ERRCODE = 'P0001';
  END IF;
  v_missing := iam.kyc_missing((SELECT definition FROM iam.kyc_form WHERE id = k.form_id), k.answers, k.company_id);
  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION 'KYC_INCOMPLETE: % item(s) missing: %', cardinality(v_missing), array_to_string(v_missing[1:10], ', ')
      USING ERRCODE = 'P0001';
  END IF;
  v_risk := iam.kyc_risk(k.answers);
  UPDATE iam.company_kyc
     SET status = 'SUBMITTED', round = k.round + 1, step = 0, review_stages = v_stages, completeness = 100,
         risk_score = (v_risk ->> 'score')::int, risk_level = v_risk ->> 'level', risk_factors = v_risk -> 'factors',
         risk_override = NULL, risk_override_reason = NULL, return_note = NULL, return_fields = '{}',
         submitted_by = sys.ctx_user_id(), submitted_at = now()
   WHERE id = k.id;
  RETURN jsonb_build_object('status', 'SUBMITTED', 'waiting_for', v_stages -> 0);
END $$;

-- whether the caller holds a permission through a platform role
CREATE OR REPLACE FUNCTION iam.ctx_has_permission(p_code text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM iam.user_role ur JOIN iam.role_permission rp ON rp.role_id = ur.role_id
                  WHERE ur.user_id = sys.ctx_user_id() AND rp.permission_code = p_code
                    AND (ur.valid_to IS NULL OR ur.valid_to > now()))
$$;

-- the authority of a stage, when the caller is one of its members
CREATE OR REPLACE FUNCTION iam.kyc_stage_authority(p_stage jsonb) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT a.id FROM sec.authority_profile a JOIN sec.authority_member m ON m.authority_id = a.id
   WHERE p_stage ->> 'by' = 'AUTHORITY' AND a.code = p_stage ->> 'authority' AND m.user_id = sys.ctx_user_id()
$$;

-- whether the caller decides a stage: the platform's reviewers hold the stage's permission and are no authority's
-- members; an authority's members decide its stages only
CREATE OR REPLACE FUNCTION iam.may_decide_kyc_stage(p_stage jsonb) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT CASE WHEN p_stage ->> 'by' IN ('COMPLIANCE', 'FINANCE', 'TAX')
              THEN sys.ctx_is_platform() AND iam.ctx_has_permission('kyc.review.' || lower(p_stage ->> 'by'))
                   AND NOT EXISTS (SELECT 1 FROM sec.authority_member m WHERE m.user_id = sys.ctx_user_id())
              WHEN p_stage ->> 'by' = 'AUTHORITY' THEN iam.kyc_stage_authority(p_stage) IS NOT NULL
              ELSE false END
$$;

-- one stage's decision: APPROVE (the last approval approves the file), RETURN (to the company, with what to correct)
-- or REJECT; the compliance stage may set another risk level, with its reason
CREATE OR REPLACE FUNCTION iam.decide_company_kyc(p_uid uuid, p_decision text, p_note text, p_fields text[], p_risk_level text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE k iam.company_kyc; v_stage jsonb; v_step smallint; v_level text; v_months integer; v_due date;
BEGIN
  SELECT * INTO k FROM iam.company_kyc WHERE uid = p_uid FOR UPDATE;
  IF k.id IS NULL THEN
    RAISE EXCEPTION 'NOT_FOUND: no such KYC file' USING ERRCODE = 'P0001';
  END IF;
  IF k.status <> 'SUBMITTED' THEN
    RAISE EXCEPTION 'KYC_NOT_IN_REVIEW: the file is %', lower(k.status) USING ERRCODE = 'P0001';
  END IF;
  IF NOT coalesce(p_decision IN ('APPROVE', 'RETURN', 'REJECT'), false) THEN
    RAISE EXCEPTION 'KYC_INVALID: the decision is APPROVE, RETURN or REJECT' USING ERRCODE = 'P0001';
  END IF;
  v_step := k.step + 1;
  v_stage := k.review_stages -> (v_step - 1);
  IF NOT iam.may_decide_kyc_stage(v_stage) THEN
    RAISE EXCEPTION 'NOT_YOUR_STAGE: the file waits for %', CASE v_stage ->> 'by' WHEN 'AUTHORITY' THEN 'the authority ' || (v_stage ->> 'authority')
                                                                                 ELSE lower(v_stage ->> 'by') END
      USING ERRCODE = 'P0001';
  END IF;
  IF iam.kyc_setting('kyc.distinct_reviewers') = 'true'::jsonb
     AND (k.submitted_by = sys.ctx_user_id()
          OR EXISTS (SELECT 1 FROM iam.kyc_decision d WHERE d.kyc_id = k.id AND d.round = k.round AND d.decided_by = sys.ctx_user_id())) THEN
    RAISE EXCEPTION 'SECOND_PERSON_REQUIRED: one person decides one stage of a file, and not the one who submitted it' USING ERRCODE = 'P0001';
  END IF;
  IF p_decision <> 'APPROVE' AND length(btrim(coalesce(p_note, ''))) < 3 THEN
    RAISE EXCEPTION 'REASON_REQUIRED: a return or a rejection says why' USING ERRCODE = 'P0001';
  END IF;
  IF p_risk_level IS NOT NULL THEN
    IF v_stage ->> 'by' <> 'COMPLIANCE' OR NOT coalesce(p_risk_level IN ('LOW', 'MEDIUM', 'HIGH', 'PROHIBITED'), false) THEN
      RAISE EXCEPTION 'KYC_INVALID: the compliance stage sets the risk level: LOW, MEDIUM, HIGH or PROHIBITED' USING ERRCODE = 'P0001';
    END IF;
    IF length(btrim(coalesce(p_note, ''))) < 3 THEN
      RAISE EXCEPTION 'REASON_REQUIRED: another risk level says why' USING ERRCODE = 'P0001';
    END IF;
    UPDATE iam.company_kyc SET risk_override = p_risk_level, risk_override_reason = btrim(p_note) WHERE id = k.id;
    k.risk_override := p_risk_level;
  END IF;
  v_level := coalesce(k.risk_override, k.risk_level);
  IF p_decision = 'APPROVE' AND v_level = 'PROHIBITED' THEN
    RAISE EXCEPTION 'KYC_PROHIBITED: a file of prohibited risk is not approved' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO iam.kyc_decision (kyc_id, round, step, stage, decision, note, fields, risk_override, decided_by, authority_id)
  VALUES (k.id, k.round, v_step, v_stage, p_decision, nullif(btrim(p_note), ''), coalesce(p_fields, '{}'), p_risk_level,
          sys.ctx_user_id(), iam.kyc_stage_authority(v_stage));
  IF p_decision = 'RETURN' THEN
    UPDATE iam.company_kyc SET status = 'RETURNED', step = 0, return_note = btrim(p_note), return_fields = coalesce(p_fields, '{}')
     WHERE id = k.id;
    RETURN jsonb_build_object('status', 'RETURNED');
  END IF;
  IF p_decision = 'REJECT' THEN
    UPDATE iam.company_kyc SET status = 'REJECTED', step = v_step, decided_at = now() WHERE id = k.id;
    RETURN jsonb_build_object('status', 'REJECTED');
  END IF;
  IF v_step < jsonb_array_length(k.review_stages) THEN
    UPDATE iam.company_kyc SET step = v_step WHERE id = k.id;
    RETURN jsonb_build_object('status', 'SUBMITTED', 'step', v_step, 'next', k.review_stages -> v_step);
  END IF;
  v_months := (iam.kyc_setting('kyc.review_months') ->> v_level)::int;
  v_due := ((now() AT TIME ZONE ref.company_tz(k.company_id))::date + make_interval(months => v_months))::date;
  UPDATE iam.company_kyc SET status = 'SUPERSEDED' WHERE company_id = k.company_id AND status = 'APPROVED';
  UPDATE iam.company_kyc SET status = 'APPROVED', step = v_step, decided_at = now(), approved_at = now(), review_due = v_due
   WHERE id = k.id;
  RETURN jsonb_build_object('status', 'APPROVED', 'risk_level', v_level, 'review_due', v_due);
END $$;

-- ------------------------------------------------------------------ what a company may do only with an approved file
CREATE OR REPLACE FUNCTION iam.kyc_gate(p_company bigint, p_action text) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF iam.kyc_setting('kyc.required_before') ? p_action
     AND NOT EXISTS (SELECT 1 FROM iam.company_kyc k WHERE k.company_id = p_company AND k.status = 'APPROVED') THEN
    RAISE EXCEPTION 'KYC_REQUIRED: the company''s KYC file must be approved first' USING ERRCODE = 'P0001';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION ops.tg_trip_kyc_gate() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.status = 'PUBLISHED' AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'PUBLISHED') THEN
    PERFORM iam.kyc_gate(NEW.company_id, 'PUBLISH_TRIPS');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS b_trip_kyc_gate ON ops.trip;
CREATE TRIGGER b_trip_kyc_gate BEFORE INSERT OR UPDATE OF status ON ops.trip FOR EACH ROW EXECUTE FUNCTION ops.tg_trip_kyc_gate();

CREATE OR REPLACE FUNCTION fin.tg_withdrawal_kyc_gate() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.company_id IS NOT NULL THEN
    PERFORM iam.kyc_gate(NEW.company_id, 'PAYOUTS');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS b_withdrawal_kyc_gate ON fin.withdrawal_request;
CREATE TRIGGER b_withdrawal_kyc_gate BEFORE INSERT ON fin.withdrawal_request FOR EACH ROW EXECUTE FUNCTION fin.tg_withdrawal_kyc_gate();

-- every company already on the platform gets its first file to fill
INSERT INTO iam.company_kyc (company_id, version, form_id, answers)
SELECT c.id, 1, f.id, jsonb_strip_nulls(jsonb_build_object('legal_name', p.legal_name, 'registration_country', p.country_code,
         'cr_no', c.cr_no, 'transport_license_no', c.transport_license_no, 'regulator_code', c.regulator_code, 'tax_residency', p.country_code))
  FROM iam.company c JOIN iam.party p ON p.id = c.id CROSS JOIN iam.kyc_form f
 WHERE f.status = 'ACTIVE' AND NOT EXISTS (SELECT 1 FROM iam.company_kyc k WHERE k.company_id = c.id);

-- ------------------------------------------------------------------ grants
REVOKE ALL ON FUNCTION iam.kyc_setting_problem(text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.kyc_setting(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.set_kyc_setting(text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.save_kyc_form(jsonb, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.activate_kyc_form(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.kyc_missing(jsonb, jsonb, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.kyc_risk(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.kyc_may_touch(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.open_company_kyc(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.save_company_kyc(uuid, jsonb, smallint) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.submit_company_kyc(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.ctx_has_permission(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.kyc_stage_authority(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.may_decide_kyc_stage(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.decide_company_kyc(uuid, text, text, text[], text) FROM PUBLIC;
REVOKE ALL ON FUNCTION iam.kyc_gate(bigint, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION iam.kyc_document_types(), iam.kyc_label_ok(jsonb), iam.kyc_field_problem(jsonb, jsonb, boolean),
  iam.kyc_form_problem(jsonb), iam.kyc_rule_problem(jsonb, boolean), iam.kyc_setting_problem(text, jsonb), iam.kyc_setting(text),
  iam.set_kyc_setting(text, jsonb), iam.save_kyc_form(jsonb, text), iam.activate_kyc_form(integer), iam.kyc_filled(jsonb, jsonb),
  iam.kyc_missing(jsonb, jsonb, bigint), iam.kyc_rule_hit(jsonb, text, jsonb), iam.kyc_risk(jsonb), iam.open_company_kyc(bigint),
  iam.save_company_kyc(uuid, jsonb, smallint), iam.submit_company_kyc(uuid), iam.may_decide_kyc_stage(jsonb),
  iam.decide_company_kyc(uuid, text, text, text[], text)
  TO masslak_app;
COMMENT ON FUNCTION iam.kyc_document_types IS 'The document types a KYC form may ask for (1118)';
COMMENT ON FUNCTION iam.kyc_label_ok IS 'Whether a label the platform gives is {"en": "...", "ar": "..."} (1118)';
COMMENT ON FUNCTION iam.kyc_field_problem IS 'What is wrong with one field or table column of the KYC form, or NULL (1118)';
COMMENT ON FUNCTION iam.kyc_form_problem IS 'What is wrong with a definition of the KYC form, or NULL: sections, fields, option sets, documents (1118)';
COMMENT ON FUNCTION iam.tg_kyc_form_frozen IS 'A version of the KYC form that was in force is never changed or removed (1118)';
COMMENT ON FUNCTION iam.kyc_rule_problem IS 'What is wrong with a risk rule of KYC, or NULL (1118)';
COMMENT ON FUNCTION iam.kyc_setting_problem IS 'What is wrong with a value of a setting of KYC, or NULL (1118)';
COMMENT ON FUNCTION iam.kyc_setting IS 'The value in force of a setting of KYC: the stored one when valid, else the default (1118)';
COMMENT ON FUNCTION iam.set_kyc_setting IS 'The platform sets the review stages, risk rules and levels, review months and gates of KYC (1118)';
COMMENT ON FUNCTION iam.save_kyc_form IS 'The platform saves the draft of the next version of the KYC form, checked (1118)';
COMMENT ON FUNCTION iam.activate_kyc_form IS 'The platform puts a draft version of the KYC form in force; the previous one is retired (1118)';
COMMENT ON FUNCTION iam.kyc_filled IS 'Whether a value answers a field of the KYC form (1118)';
COMMENT ON FUNCTION iam.kyc_missing IS 'What a KYC file still lacks: required fields, table rows and columns, details, documents (1118)';
COMMENT ON FUNCTION iam.kyc_rule_hit IS 'Whether a value passes one test of a risk rule of KYC (1118)';
COMMENT ON FUNCTION iam.kyc_risk IS 'The risk of KYC answers by the rules in force: score, level, rules matched (1118)';
COMMENT ON FUNCTION iam.kyc_may_touch IS 'Whether the caller works on a company''s KYC file: the company itself or the platform (1118)';
COMMENT ON FUNCTION iam.open_company_kyc IS 'The company''s open KYC file, or a new version from the approved answers or what the platform knows (1118)';
COMMENT ON FUNCTION iam.save_company_kyc IS 'The answers of a KYC file as they are filled, while it is a draft or returned (1118)';
COMMENT ON FUNCTION iam.submit_company_kyc IS 'A complete KYC file goes for review, with its risk scored and the review stages in force (1118)';
COMMENT ON FUNCTION iam.ctx_has_permission IS 'Whether the caller holds a permission through a platform role in force (1118)';
COMMENT ON FUNCTION iam.kyc_stage_authority IS 'The authority of a review stage when the caller is one of its members (1118)';
COMMENT ON FUNCTION iam.may_decide_kyc_stage IS 'Whether the caller decides a review stage of KYC (1118)';
COMMENT ON FUNCTION iam.decide_company_kyc IS 'One review stage''s decision on a KYC file: approve, return with what to correct, or reject (1118)';
COMMENT ON FUNCTION iam.kyc_gate IS 'Refuses what the settings allow only with an approved KYC file (1118)';
COMMENT ON FUNCTION ops.tg_trip_kyc_gate IS 'While the settings ask for it, a company publishes trips only with an approved KYC file (1118)';
COMMENT ON FUNCTION fin.tg_withdrawal_kyc_gate IS 'While the settings ask for it, a company withdraws money only with an approved KYC file (1118)';

-- ------------------------------------------------------------------ reading what is kept encrypted
INSERT INTO gov.data_purpose (code, description, requires_reason) VALUES
  ('KYC_REVIEW', 'Reviewing a company''s KYC file: reading an identity document or account number it holds, with the reason (1118)', true)
ON CONFLICT (code) DO NOTHING;

-- ------------------------------------------------------------------ permissions
INSERT INTO iam.permission (code, module, scope, description, is_sensitive) VALUES
  ('company.kyc', 'iam', 'COMPANY', 'Fill and submit the company''s KYC file', true),
  ('kyc.view', 'iam', 'PLATFORM', 'Read companies'' KYC files (each opening is recorded)', true),
  ('kyc.capture', 'iam', 'PLATFORM', 'Fill a company''s KYC file from its paper form, and submit it', true),
  ('kyc.review.compliance', 'iam', 'PLATFORM', 'Decide the compliance stage of KYC files, and set their risk level', true),
  ('kyc.review.finance', 'iam', 'PLATFORM', 'Decide the finance stage of KYC files', true),
  ('kyc.review.tax', 'iam', 'PLATFORM', 'Decide the tax stage of KYC files', true),
  ('kyc.settings', 'iam', 'PLATFORM', 'Make and activate versions of the KYC form, and set its review stages and risk rules', true)
ON CONFLICT (code) DO NOTHING;
INSERT INTO iam.role_permission (role_id, permission_code)
SELECT r.id, p.code FROM iam.role r JOIN (VALUES
    ('PLATFORM_ADMIN', 'kyc.view'), ('PLATFORM_ADMIN', 'kyc.capture'), ('PLATFORM_ADMIN', 'kyc.review.compliance'),
    ('PLATFORM_ADMIN', 'kyc.review.finance'), ('PLATFORM_ADMIN', 'kyc.review.tax'), ('PLATFORM_ADMIN', 'kyc.settings'),
    ('PLATFORM_SECURITY', 'kyc.view'), ('PLATFORM_SECURITY', 'kyc.review.compliance'),
    ('PLATFORM_FINANCE', 'kyc.view'), ('PLATFORM_FINANCE', 'kyc.review.finance'), ('PLATFORM_FINANCE', 'kyc.review.tax'),
    ('PLATFORM_SUPPORT', 'kyc.view'), ('PLATFORM_SUPPORT', 'kyc.capture'),
    ('CARRIER_ACCOUNTANT', 'company.kyc')) p (role, code) ON p.role = r.code
 WHERE r.company_id IS NULL
ON CONFLICT DO NOTHING;

-- ------------------------------------------------------------------ registration
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('iam.kyc_form', '1A', 'E01'), ('iam.company_kyc', '1A', 'E01'), ('iam.kyc_decision', '1A', 'E01')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
INSERT INTO sys.table_class (table_name, data_class, tenant_path, note) VALUES
  ('iam.kyc_form', 'PUBLIC_CATALOG', NULL, 'the versions of the KYC form (1118)'),
  ('iam.company_kyc', 'TENANT_PRIVATE', 'company_id', 'companies'' KYC files (1118)'),
  ('iam.kyc_decision', 'TENANT_PRIVATE', 'kyc_id -> iam.company_kyc.company_id', 'the review decisions on KYC files (1118)')
ON CONFLICT (table_name) DO UPDATE SET data_class = excluded.data_class, tenant_path = excluded.tenant_path, note = excluded.note;
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('iam.kyc_form', 'iam records', 'the KYC form in versions (1118)'),
  ('iam.company_kyc', 'iam records', 'companies'' KYC files (1118)'),
  ('iam.kyc_decision', 'iam records', 'review decisions on KYC files (1118)')
ON CONFLICT (table_name) DO NOTHING;
INSERT INTO sys.json_contract (table_name, column_name, kind, version, spec, note) VALUES
  ('iam.kyc_form', 'definition', 'SHAPE', 1, '{"type": "object", "required": ["sections"]}'::jsonb,
   'the form: sections of fields, option sets and the documents asked for, checked by iam.kyc_form_problem (1118)'),
  ('iam.company_kyc', 'answers', 'PAYLOAD', 1, NULL,
   'the answers by field key, the shape of the form version the file follows; sensitive values encrypted (1118)'),
  ('iam.company_kyc', 'review_stages', 'SNAPSHOT', 1, '{"type": "array"}'::jsonb,
   'the review stages in force when the file was submitted (1118)'),
  ('iam.company_kyc', 'risk_factors', 'SNAPSHOT', 1, '{"type": "array"}'::jsonb,
   'the risk rules the answers matched when submitted (1118)'),
  ('iam.kyc_decision', 'stage', 'SNAPSHOT', 1, '{"type": "object", "required": ["by"]}'::jsonb,
   'the stage decided: compliance, finance, tax or an authority by its code (1118)')
ON CONFLICT DO NOTHING;
SELECT sys.apply_json_contracts();
