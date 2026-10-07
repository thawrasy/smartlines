-- =====================================================================
-- 1044: school transport, a phase of its own (owner decisions after the regulators' review)
--   Who carries the pupils, four ways:
--     SCHOOL_OWNED           the school's own buses; the school enrols its pupils on transport (guardian consent in
--                            the app comes later, switched by configuration)
--     TRANSPORT_COMPANY      a specialised company contracts with the guardian
--     INDIVIDUAL             an individual owner-driver contracts with the guardian
--     GOVERNMENT / GOVERNMENT_CONTRACTED  the ministry or a government carrier, or a private carrier under a
--                            government contract
--   Every school transport contract carries the school transport licence number issued by the authority.
--   Every other licence (company, vehicle, driver, attendant) is registered now in sys.compliance_requirement as
--   OPTIONAL and becomes REQUIRED by configuration once the government imposes it.
--   A pupil is a person the guardian defines from their own account (iam.family_member); while the pupil is a minor
--   (sys setting person.age_of_majority) they stay linked to the guardian, and may get their own account later.
--   Safety rules enforced by the database: a minor leaving the bus is handed only to an authorised receiver, and a
--   run cannot close while a pupil is still on board or before the end-of-run check that no child is left behind.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS sch;
COMMENT ON SCHEMA sch IS 'School transport: schools, operators, pupils and guardians, contracts, routes, daily runs and attendance';
GRANT USAGE ON SCHEMA sch TO masslak_app, masslak_readonly, masslak_auditor;

-- Schools and government transport bodies hold a company record to own vehicles and act on the platform
ALTER TABLE iam.company DROP CONSTRAINT IF EXISTS company_company_type_check;
ALTER TABLE iam.company ADD CONSTRAINT company_company_type_check CHECK (company_type IN
  ('CARRIER','INDIVIDUAL_OPERATOR','FOREIGN_CARRIER','AGENCY','PARTNER','SCHOOL','GOVERNMENT'));

-- ------------------------------ ages: minors stay linked to their guardian ------------------------------
INSERT INTO sys.setting (key, value, description) VALUES
  ('person.age_of_majority', '18', 'Age from which a person may hold their own account apart from their guardian'),
  ('school.handover_age', '12', 'Pupils younger than this leave the bus only into the hands of an authorised receiver'),
  ('school.max_ride_minutes', '60', 'Default longest ride of a pupil on a school route')
ON CONFLICT (key) DO NOTHING;
UPDATE sys.setting SET value = value || '{"school_transport": false}'::jsonb
 WHERE key = 'features' AND NOT value ? 'school_transport';

CREATE OR REPLACE FUNCTION iam.age_years(p_birth date, p_on date DEFAULT current_date) RETURNS int
  LANGUAGE sql IMMUTABLE AS $$ SELECT extract(year FROM age(p_on, p_birth))::int $$;
CREATE OR REPLACE FUNCTION iam.is_minor(p_birth date, p_on date DEFAULT current_date) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT p_birth IS NOT NULL AND iam.age_years(p_birth, p_on)
         < coalesce((SELECT (value #>> '{}')::int FROM sys.setting WHERE key = 'person.age_of_majority'), 18)
$$;
COMMENT ON FUNCTION iam.is_minor IS 'Younger than the age of majority set by configuration (person.age_of_majority)';
GRANT EXECUTE ON FUNCTION iam.age_years(date, date), iam.is_minor(date, date) TO masslak_app, masslak_readonly;

INSERT INTO sys.compliance_requirement (code, domain, applies_to, level, authority, description) VALUES
  ('school.guardian_consent', 'SCHOOL', 'SCHOOL', 'OPTIONAL', 'Ministry of education',
   'A pupil enrolled by the school rides only once a guardian has approved the transport contract in the app'),
  ('school.guardian_link',    'SCHOOL', 'SCHOOL', 'OPTIONAL', 'Ministry of education',
   'A minor pupil rides only once linked to a guardian''s account'),
  ('school.attendant',        'SCHOOL', 'SCHOOL', 'OPTIONAL', 'Ministry of education',
   'Every school route has an attendant besides the driver')
ON CONFLICT (code) DO NOTHING;

-- ------------------------------ schools and operators ------------------------------
CREATE TABLE IF NOT EXISTS sch.school (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                  uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  company_id           bigint NOT NULL UNIQUE REFERENCES iam.company (id),   -- the school's account on the platform
  ministry_code        text,                                                -- the ministry's school number
  sector               text NOT NULL CHECK (sector IN ('PUBLIC','PRIVATE','INTERNATIONAL')),
  education_license_no text,
  city_id              bigint NOT NULL REFERENCES ref.city (id),
  station_id           bigint REFERENCES net.station (id),                  -- the school gate as a stop
  lat                  numeric(9,6),
  lng                  numeric(9,6),
  status               text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','ACTIVE','SUSPENDED','CLOSED')),
  created_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS school_city_id_fkx ON sch.school (city_id);
CREATE INDEX IF NOT EXISTS school_station_id_fkx ON sch.school (station_id);
COMMENT ON TABLE sch.school IS 'A school on the platform: guardians find it, its staff manage its pupils and, when it owns buses, its transport';
SELECT sys.rls_split('sch.school', 'true', 'sys.tenant_visible(company_id)');
SELECT sys.grant_rw(ARRAY['sch.school']);

CREATE TABLE IF NOT EXISTS sch.operator (
  id                         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id                 bigint NOT NULL UNIQUE REFERENCES iam.company (id),
  operator_kind              text NOT NULL CHECK (operator_kind IN ('SCHOOL_OWNED','TRANSPORT_COMPANY','INDIVIDUAL','GOVERNMENT','GOVERNMENT_CONTRACTED')),
  school_id                  bigint REFERENCES sch.school (id),             -- SCHOOL_OWNED: the school itself
  government_contract_no     text,                                          -- GOVERNMENT_CONTRACTED: the contract with the ministry
  supervising_authority      text,                                          -- ministry or directorate supervising the operator
  school_transport_license_no text NOT NULL,                                -- issued by the competent authority (always required)
  license_issuer             text NOT NULL,
  license_expiry             date,
  license_record_id          bigint REFERENCES fleet.license_record (id),   -- the verified licence document, when uploaded
  status                     text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','APPROVED','SUSPENDED','REVOKED')),
  approved_by                bigint REFERENCES iam.app_user (id),
  approved_at                timestamptz,
  created_at                 timestamptz NOT NULL DEFAULT now(),
  CHECK ((operator_kind = 'SCHOOL_OWNED') = (school_id IS NOT NULL)),
  CHECK (operator_kind <> 'GOVERNMENT_CONTRACTED' OR government_contract_no IS NOT NULL),
  CHECK (length(btrim(school_transport_license_no)) >= 3),
  CHECK ((status = 'APPROVED') <= (approved_by IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS operator_school_id_fkx ON sch.operator (school_id);
CREATE INDEX IF NOT EXISTS operator_license_record_id_fkx ON sch.operator (license_record_id);
CREATE INDEX IF NOT EXISTS operator_approved_by_fkx ON sch.operator (approved_by);
COMMENT ON TABLE sch.operator IS 'Who carries pupils: the school''s own buses, a company, an individual owner-driver, or a government or government-contracted carrier';
SELECT sys.rls_tenant('sch.operator');
SELECT sys.grant_rw(ARRAY['sch.operator']);
DROP TRIGGER IF EXISTS same_company_license_record_id ON sch.operator;
CREATE TRIGGER same_company_license_record_id BEFORE INSERT OR UPDATE OF license_record_id, company_id ON sch.operator
  FOR EACH ROW EXECUTE FUNCTION sys.tg_same_company('license_record_id', 'fleet.license_record');

CREATE OR REPLACE FUNCTION sch.tg_operator_rules() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE ctype text;
BEGIN
  SELECT company_type INTO ctype FROM iam.company WHERE id = NEW.company_id;
  IF NEW.operator_kind = 'SCHOOL_OWNED' AND NOT EXISTS (SELECT 1 FROM sch.school WHERE id = NEW.school_id AND company_id = NEW.company_id) THEN
    RAISE EXCEPTION 'OPERATOR_KIND_MISMATCH: a school-owned operator is the school''s own account' USING ERRCODE = 'P0001';
  END IF;
  IF (NEW.operator_kind = 'INDIVIDUAL') <> (ctype = 'INDIVIDUAL_OPERATOR')
     OR (NEW.operator_kind = 'GOVERNMENT' AND ctype <> 'GOVERNMENT') THEN
    RAISE EXCEPTION 'OPERATOR_KIND_MISMATCH: % does not match the company type %', NEW.operator_kind, ctype USING ERRCODE = 'P0001';
  END IF;
  IF NEW.status = 'APPROVED' AND (TG_OP = 'INSERT' OR OLD.status <> 'APPROVED') THEN
    IF NEW.license_expiry IS NOT NULL AND NEW.license_expiry < current_date THEN
      RAISE EXCEPTION 'LICENSE_EXPIRED: the school transport licence has expired' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM sys.unmet_requirements('SCHOOL', 'COMPANY', NEW.company_id)) THEN
      RAISE EXCEPTION 'REQUIREMENT_UNMET: %', (SELECT string_agg(c, ', ') FROM sys.unmet_requirements('SCHOOL', 'COMPANY', NEW.company_id) c)
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS operator_rules ON sch.operator;
CREATE TRIGGER operator_rules BEFORE INSERT OR UPDATE ON sch.operator FOR EACH ROW EXECUTE FUNCTION sch.tg_operator_rules();

-- ------------------------------ pupils and their guardians ------------------------------
CREATE TABLE IF NOT EXISTS sch.student (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid               uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  school_id         bigint NOT NULL REFERENCES sch.school (id),
  party_id          bigint NOT NULL REFERENCES iam.party (id),             -- the pupil as a person
  family_member_id  bigint REFERENCES iam.family_member (id),              -- the guardian's definition of the pupil, once linked
  student_no        text,
  grade             text,
  class_name        text,
  medical_note_enc  bytea,                                                 -- allergies, medicines: encrypted, for the attendant
  enc_key_id        int REFERENCES sec.key_registry (id),
  photo_document_id bigint REFERENCES iam.document (id),                   -- to recognise the pupil at boarding
  status            text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','LEFT')),
  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (school_id, party_id),
  CHECK (medical_note_enc IS NULL OR enc_key_id IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS student_party_id_fkx ON sch.student (party_id);
CREATE INDEX IF NOT EXISTS student_family_member_id_fkx ON sch.student (family_member_id);
CREATE INDEX IF NOT EXISTS student_enc_key_id_fkx ON sch.student (enc_key_id);
CREATE INDEX IF NOT EXISTS student_photo_document_id_fkx ON sch.student (photo_document_id);
COMMENT ON TABLE sch.student IS 'A pupil of a school; a minor is linked to the guardian''s account through the family member the guardian defined';

CREATE TABLE IF NOT EXISTS sch.student_guardian (
  student_id      bigint NOT NULL REFERENCES sch.student (id) ON DELETE CASCADE,
  party_id        bigint NOT NULL REFERENCES iam.party (id),
  role            text NOT NULL CHECK (role IN ('GUARDIAN','RECEIVER')),     -- RECEIVER: may only take the pupil at drop-off
  relation        text NOT NULL CHECK (relation IN ('FATHER','MOTHER','LEGAL_GUARDIAN','GRANDPARENT','SIBLING','RELATIVE','OTHER')),
  is_primary      boolean NOT NULL DEFAULT false,
  can_receive     boolean NOT NULL DEFAULT true,
  receive_blocked boolean NOT NULL DEFAULT false,                          -- custody restriction: never hand the pupil over
  verified_at     timestamptz,
  verified_by     bigint REFERENCES iam.app_user (id),
  PRIMARY KEY (student_id, party_id),
  CHECK (NOT (receive_blocked AND can_receive))
);
CREATE UNIQUE INDEX IF NOT EXISTS student_guardian_one_primary ON sch.student_guardian (student_id) WHERE is_primary;
CREATE INDEX IF NOT EXISTS student_guardian_party_id_fkx ON sch.student_guardian (party_id);
CREATE INDEX IF NOT EXISTS student_guardian_verified_by_fkx ON sch.student_guardian (verified_by);
COMMENT ON TABLE sch.student_guardian IS 'Guardians and authorised receivers of a pupil, with custody restrictions';

-- Pupils and guardians: the family member must be the same person, and a minor's guardians are adults
CREATE OR REPLACE FUNCTION sch.tg_student_rules() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.family_member_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM iam.family_member WHERE id = NEW.family_member_id AND party_id = NEW.party_id) THEN
    RAISE EXCEPTION 'FAMILY_MEMBER_MISMATCH: the family member is another person' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;

-- ------------------------------ contracts ------------------------------
CREATE TABLE IF NOT EXISTS sch.contract (
  id                          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                         uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  operator_id                 bigint NOT NULL REFERENCES sch.operator (id),
  company_id                  bigint NOT NULL REFERENCES iam.company (id),   -- the operator's company
  contract_kind               text NOT NULL CHECK (contract_kind IN ('SCHOOL_ASSIGNED','GUARDIAN_COMPANY','GUARDIAN_INDIVIDUAL','GOVERNMENT')),
  school_id                   bigint NOT NULL REFERENCES sch.school (id),
  guardian_party_id           bigint REFERENCES iam.party (id),              -- the signing guardian (guardian contracts)
  school_year                 text NOT NULL CHECK (school_year ~ '^[0-9]{4}-[0-9]{4}$'),
  valid                       daterange NOT NULL,
  pricing_mode                text NOT NULL CHECK (pricing_mode IN ('MONTHLY','TERM','YEAR','PER_TRIP','FREE')),
  price                       bigint NOT NULL DEFAULT 0 CHECK (price >= 0),  -- minor units
  currency                    char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency (code),
  school_transport_license_no text NOT NULL,                                 -- snapshot of the licence the contract relies on
  license_authority           text NOT NULL,
  terms                       jsonb NOT NULL DEFAULT '{}',                   -- absence, cancellation and holiday terms
  status                      text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','ACTIVE','SUSPENDED','ENDED')),
  signed_at                   timestamptz,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  CHECK ((contract_kind IN ('GUARDIAN_COMPANY','GUARDIAN_INDIVIDUAL')) = (guardian_party_id IS NOT NULL)),
  CHECK (length(btrim(school_transport_license_no)) >= 3),
  CHECK (NOT isempty(valid))
);
CREATE INDEX IF NOT EXISTS contract_operator_id_fkx ON sch.contract (operator_id);
CREATE INDEX IF NOT EXISTS contract_company_id_fkx ON sch.contract (company_id);
CREATE INDEX IF NOT EXISTS contract_school_id_fkx ON sch.contract (school_id);
CREATE INDEX IF NOT EXISTS contract_guardian_party_id_fkx ON sch.contract (guardian_party_id);
CREATE INDEX IF NOT EXISTS contract_currency_fkx ON sch.contract (currency);
COMMENT ON TABLE sch.contract IS 'A school transport contract: the school assigning its own buses, a guardian with a company or an individual, or a government scheme; always under a school transport licence';
SELECT sys.rls_split('sch.contract',
  'sys.tenant_visible(company_id) OR guardian_party_id = sys.ctx_party_id() OR EXISTS (SELECT 1 FROM sch.school s WHERE s.id = school_id AND sys.tenant_visible(s.company_id))',
  'sys.tenant_visible(company_id)');
SELECT sys.grant_rw(ARRAY['sch.contract']);
DROP TRIGGER IF EXISTS same_company_operator_id ON sch.contract;
CREATE TRIGGER same_company_operator_id BEFORE INSERT OR UPDATE OF operator_id, company_id ON sch.contract
  FOR EACH ROW EXECUTE FUNCTION sys.tg_same_company('operator_id', 'sch.operator');

CREATE OR REPLACE FUNCTION sch.tg_contract_rules() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE o record;
BEGIN
  SELECT * INTO o FROM sch.operator WHERE id = NEW.operator_id;
  IF (NEW.contract_kind = 'SCHOOL_ASSIGNED' AND (o.operator_kind <> 'SCHOOL_OWNED' OR o.school_id <> NEW.school_id))
     OR (NEW.contract_kind = 'GUARDIAN_INDIVIDUAL' AND o.operator_kind <> 'INDIVIDUAL')
     OR (NEW.contract_kind = 'GUARDIAN_COMPANY' AND o.operator_kind NOT IN ('TRANSPORT_COMPANY','GOVERNMENT_CONTRACTED'))
     OR (NEW.contract_kind = 'GOVERNMENT' AND o.operator_kind NOT IN ('GOVERNMENT','GOVERNMENT_CONTRACTED')) THEN
    RAISE EXCEPTION 'CONTRACT_KIND_MISMATCH: a % contract cannot be made with a % operator', NEW.contract_kind, o.operator_kind
      USING ERRCODE = 'P0001';
  END IF;
  IF NEW.status = 'ACTIVE' AND (TG_OP = 'INSERT' OR OLD.status <> 'ACTIVE') THEN
    IF o.status <> 'APPROVED' THEN
      RAISE EXCEPTION 'OPERATOR_NOT_APPROVED: the operator is not approved for school transport' USING ERRCODE = 'P0001';
    END IF;
    IF o.license_expiry IS NOT NULL AND o.license_expiry < lower(NEW.valid) THEN
      RAISE EXCEPTION 'LICENSE_EXPIRED: the school transport licence expires before the contract starts' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS contract_rules ON sch.contract;
CREATE TRIGGER contract_rules BEFORE INSERT OR UPDATE ON sch.contract FOR EACH ROW EXECUTE FUNCTION sch.tg_contract_rules();

-- ------------------------------ routes, stops and enrolments ------------------------------
CREATE TABLE IF NOT EXISTS sch.route (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id         bigint NOT NULL REFERENCES iam.company (id),
  operator_id        bigint NOT NULL REFERENCES sch.operator (id),
  school_id          bigint NOT NULL REFERENCES sch.school (id),
  code               text NOT NULL,
  direction          text NOT NULL CHECK (direction IN ('TO_SCHOOL','FROM_SCHOOL')),
  vehicle_id         bigint REFERENCES fleet.vehicle (id),
  driver_party_id    bigint REFERENCES fleet.crew_profile (party_id),
  attendant_party_id bigint REFERENCES fleet.crew_profile (party_id),
  path               jsonb,                                                -- GeoJSON LineString, checked like an approved line
  corridor_m         int NOT NULL DEFAULT 150 CHECK (corridor_m BETWEEN 20 AND 5000),
  max_ride_min       int CHECK (max_ride_min BETWEEN 5 AND 180),
  depart_time        time NOT NULL,
  operating_days     smallint[] NOT NULL DEFAULT '{1,2,3,4,7}',            -- ISO weekdays (Sunday to Thursday)
  status             text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','ACTIVE','SUSPENDED','RETIRED')),
  created_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (company_id, code),
  CHECK (attendant_party_id IS DISTINCT FROM driver_party_id)
);
CREATE INDEX IF NOT EXISTS route_operator_id_fkx ON sch.route (operator_id);
CREATE INDEX IF NOT EXISTS route_school_id_fkx ON sch.route (school_id);
CREATE INDEX IF NOT EXISTS route_vehicle_id_fkx ON sch.route (vehicle_id);
CREATE INDEX IF NOT EXISTS route_driver_party_id_fkx ON sch.route (driver_party_id);
CREATE INDEX IF NOT EXISTS route_attendant_party_id_fkx ON sch.route (attendant_party_id);
COMMENT ON TABLE sch.route IS 'A school route with its bus, driver and attendant; activation checks the licences the configuration requires';
SELECT sys.rls_split('sch.route',
  'sys.tenant_visible(company_id) OR EXISTS (SELECT 1 FROM sch.school s WHERE s.id = school_id AND sys.tenant_visible(s.company_id))',
  'sys.tenant_visible(company_id)');
SELECT sys.grant_rw(ARRAY['sch.route']);
DROP TRIGGER IF EXISTS same_company_operator_id ON sch.route;
CREATE TRIGGER same_company_operator_id BEFORE INSERT OR UPDATE OF operator_id, company_id ON sch.route
  FOR EACH ROW EXECUTE FUNCTION sys.tg_same_company('operator_id', 'sch.operator');
DROP TRIGGER IF EXISTS vehicle_of_company ON sch.route;
CREATE TRIGGER vehicle_of_company BEFORE INSERT OR UPDATE OF vehicle_id, company_id ON sch.route
  FOR EACH ROW EXECUTE FUNCTION fleet.tg_vehicle_of_company('vehicle_id');

CREATE OR REPLACE FUNCTION sch.tg_route_rules() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE unmet text;
BEGIN
  IF NEW.status <> 'ACTIVE' THEN RETURN NEW; END IF;
  IF NEW.vehicle_id IS NULL OR NEW.driver_party_id IS NULL THEN
    RAISE EXCEPTION 'ROUTE_INCOMPLETE: an active school route needs a vehicle and a driver' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.attendant_party_id IS NULL AND sys.requirement_enforced('school.attendant') THEN
    RAISE EXCEPTION 'REQUIREMENT_UNMET: school.attendant' USING ERRCODE = 'P0001';
  END IF;
  SELECT string_agg(c, ', ') INTO unmet FROM (
    SELECT sys.unmet_requirements('SCHOOL', 'VEHICLE', NEW.vehicle_id) c
    UNION ALL SELECT sys.unmet_requirements('SCHOOL', 'DRIVER', NEW.driver_party_id)
    UNION ALL SELECT sys.unmet_requirements('SCHOOL', 'PERSON', NEW.attendant_party_id) WHERE NEW.attendant_party_id IS NOT NULL) x;
  IF unmet IS NOT NULL THEN
    RAISE EXCEPTION 'REQUIREMENT_UNMET: %', unmet USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS route_rules ON sch.route;
CREATE TRIGGER route_rules BEFORE INSERT OR UPDATE ON sch.route FOR EACH ROW EXECUTE FUNCTION sch.tg_route_rules();

CREATE TABLE IF NOT EXISTS sch.route_stop (
  route_id           bigint NOT NULL REFERENCES sch.route (id) ON DELETE CASCADE,
  seq                smallint NOT NULL CHECK (seq >= 1),
  label              text NOT NULL,
  station_id         bigint REFERENCES net.station (id),
  lat                numeric(9,6) NOT NULL,
  lng                numeric(9,6) NOT NULL,
  planned_offset_min int NOT NULL DEFAULT 0 CHECK (planned_offset_min >= 0),
  PRIMARY KEY (route_id, seq)
);
CREATE INDEX IF NOT EXISTS route_stop_station_id_fkx ON sch.route_stop (station_id);
COMMENT ON TABLE sch.route_stop IS 'Pick-up and drop-off points of a school route, door to door or at gathering points';
SELECT sys.rls_parent('sch.route_stop', 'route_id', 'sch.route');
SELECT sys.grant_rw(ARRAY['sch.route_stop']);

CREATE TABLE IF NOT EXISTS sch.enrollment (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  contract_id         bigint NOT NULL REFERENCES sch.contract (id),
  student_id          bigint NOT NULL REFERENCES sch.student (id),
  to_route_id         bigint REFERENCES sch.route (id),
  to_stop_seq         smallint,
  from_route_id       bigint REFERENCES sch.route (id),
  from_stop_seq       smallint,
  guardian_consent    text NOT NULL DEFAULT 'PENDING' CHECK (guardian_consent IN ('NOT_REQUIRED','PENDING','GIVEN','REFUSED')),
  consent_at          timestamptz,
  consent_by_party_id bigint REFERENCES iam.party (id),
  status              text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','ACTIVE','PAUSED','ENDED')),
  created_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (contract_id, student_id),
  CHECK ((guardian_consent IN ('GIVEN','REFUSED')) = (consent_at IS NOT NULL AND consent_by_party_id IS NOT NULL)),
  CHECK (to_route_id IS NOT NULL OR from_route_id IS NOT NULL OR status <> 'ACTIVE'),
  FOREIGN KEY (to_route_id, to_stop_seq) REFERENCES sch.route_stop (route_id, seq),
  FOREIGN KEY (from_route_id, from_stop_seq) REFERENCES sch.route_stop (route_id, seq)
);
CREATE INDEX IF NOT EXISTS enrollment_student_id_fkx ON sch.enrollment (student_id);
CREATE INDEX IF NOT EXISTS enrollment_to_route_id_fkx ON sch.enrollment (to_route_id, to_stop_seq);
CREATE INDEX IF NOT EXISTS enrollment_from_route_id_fkx ON sch.enrollment (from_route_id, from_stop_seq);
CREATE INDEX IF NOT EXISTS enrollment_consent_by_party_id_fkx ON sch.enrollment (consent_by_party_id);
COMMENT ON TABLE sch.enrollment IS 'A pupil on a contract, with the morning and afternoon routes and stops, and the guardian''s consent';
SELECT sys.rls_parent('sch.enrollment', 'contract_id', 'sch.contract');
SELECT sys.grant_rw(ARRAY['sch.enrollment']);
DROP TRIGGER IF EXISTS zz_audit_capture ON sch.enrollment;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR UPDATE OR DELETE ON sch.enrollment FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();

-- The pupil studies at the contract's school, rides only that school's routes of the same operator, and is active
-- only with the consent and the guardian link the configuration requires
CREATE OR REPLACE FUNCTION sch.tg_enrollment_rules() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE c record; s record; birth date;
BEGIN
  SELECT * INTO c FROM sch.contract WHERE id = NEW.contract_id;
  SELECT * INTO s FROM sch.student WHERE id = NEW.student_id;
  IF s.school_id <> c.school_id THEN
    RAISE EXCEPTION 'WRONG_SCHOOL: the pupil does not study at the contract''s school' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM sch.route r WHERE r.id IN (NEW.to_route_id, NEW.from_route_id)
              AND (r.operator_id <> c.operator_id OR r.school_id <> c.school_id
                   OR r.direction <> CASE WHEN r.id = NEW.to_route_id THEN 'TO_SCHOOL' ELSE 'FROM_SCHOOL' END)) THEN
    RAISE EXCEPTION 'WRONG_ROUTE: the routes must be the operator''s routes to and from the pupil''s school' USING ERRCODE = 'P0001';
  END IF;
  -- a guardian who signed the contract has consented by signing
  IF c.guardian_party_id IS NOT NULL AND NEW.guardian_consent = 'PENDING' THEN
    NEW.guardian_consent := 'GIVEN'; NEW.consent_at := coalesce(c.signed_at, now()); NEW.consent_by_party_id := c.guardian_party_id;
  END IF;
  IF NEW.status = 'ACTIVE' THEN
    IF NEW.guardian_consent = 'REFUSED'
       OR (NEW.guardian_consent <> 'GIVEN' AND sys.requirement_enforced('school.guardian_consent')) THEN
      RAISE EXCEPTION 'CONSENT_MISSING: the guardian has not approved the transport' USING ERRCODE = 'P0001';
    END IF;
    SELECT birth_date INTO birth FROM iam.party WHERE id = s.party_id;
    IF s.family_member_id IS NULL AND (birth IS NULL OR iam.is_minor(birth)) AND sys.requirement_enforced('school.guardian_link') THEN
      RAISE EXCEPTION 'GUARDIAN_LINK_MISSING: a minor pupil rides only once linked to a guardian''s account' USING ERRCODE = 'P0001';
    END IF;
    IF c.status <> 'ACTIVE' THEN
      RAISE EXCEPTION 'CONTRACT_NOT_ACTIVE: the contract is not active' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS enrollment_rules ON sch.enrollment;
CREATE TRIGGER enrollment_rules BEFORE INSERT OR UPDATE ON sch.enrollment FOR EACH ROW EXECUTE FUNCTION sch.tg_enrollment_rules();

-- Pupil policies need the enrolment table, so they are declared once it exists
-- The pupil is visible to the school, to the operators that carry them and to their guardians (no policy recursion:
-- the check runs as the owner)
CREATE OR REPLACE FUNCTION sch.student_visible(p_student bigint) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT sys.ctx_is_platform()
      OR EXISTS (SELECT 1 FROM sch.student s JOIN sch.school sc ON sc.id = s.school_id
                  WHERE s.id = p_student AND sys.tenant_visible(sc.company_id))
      OR EXISTS (SELECT 1 FROM sch.student_guardian g WHERE g.student_id = p_student AND g.role = 'GUARDIAN'
                    AND g.party_id = sys.ctx_party_id())
      OR EXISTS (SELECT 1 FROM sch.student s JOIN iam.family_member m ON m.id = s.family_member_id
                   JOIN iam.family f ON f.id = m.family_id
                  WHERE s.id = p_student AND f.head_party_id = sys.ctx_party_id())
      OR EXISTS (SELECT 1 FROM sch.enrollment e JOIN sch.contract c ON c.id = e.contract_id
                  WHERE e.student_id = p_student AND sys.tenant_visible(c.company_id))
$$;

SELECT sys.rls('sch.student', 'sch.student_visible(id)', 'sys.ctx_is_platform() OR EXISTS (SELECT 1 FROM sch.school sc WHERE sc.id = school_id AND sys.tenant_visible(sc.company_id))');
SELECT sys.grant_rw(ARRAY['sch.student']);
SELECT sys.rls_parent('sch.student_guardian', 'student_id', 'sch.student');
SELECT sys.grant_rw(ARRAY['sch.student_guardian']);
DROP TRIGGER IF EXISTS student_rules ON sch.student;
CREATE TRIGGER student_rules BEFORE INSERT OR UPDATE OF party_id, family_member_id ON sch.student
  FOR EACH ROW EXECUTE FUNCTION sch.tg_student_rules();
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['sch.student','sch.student_guardian','sch.operator','sch.contract','sch.route'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS zz_audit_capture ON %s', t);
    EXECUTE format('CREATE TRIGGER zz_audit_capture AFTER INSERT OR UPDATE OR DELETE ON %s FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change()', t);
  END LOOP;
END $$;

-- ------------------------------ daily runs and attendance ------------------------------
CREATE TABLE IF NOT EXISTS sch.run (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  route_id          bigint NOT NULL REFERENCES sch.route (id),
  run_date          date NOT NULL,
  trip_id           bigint REFERENCES ops.trip (id),                       -- tracking and route compliance of the run
  status            text NOT NULL DEFAULT 'PLANNED' CHECK (status IN ('PLANNED','IN_PROGRESS','COMPLETED','CANCELLED')),
  started_at        timestamptz,
  completed_at      timestamptz,
  sweep_checked_at  timestamptz,                                           -- the walk through the empty bus at the end
  sweep_checked_by  bigint REFERENCES iam.party (id),
  UNIQUE (route_id, run_date),
  CHECK ((sweep_checked_at IS NULL) = (sweep_checked_by IS NULL))
);
CREATE INDEX IF NOT EXISTS run_trip_id_fkx ON sch.run (trip_id);
CREATE INDEX IF NOT EXISTS run_sweep_checked_by_fkx ON sch.run (sweep_checked_by);
COMMENT ON TABLE sch.run IS 'One run of a school route on a day; it closes only after the check that no child is left on the bus';
SELECT sys.rls_parent('sch.run', 'route_id', 'sch.route');
SELECT sys.grant_rw(ARRAY['sch.run']);

CREATE TABLE IF NOT EXISTS sch.attendance (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  run_id               bigint NOT NULL REFERENCES sch.run (id),
  enrollment_id        bigint NOT NULL REFERENCES sch.enrollment (id),
  event                text NOT NULL CHECK (event IN ('BOARD','ALIGHT','HANDED_OVER','ABSENT','NO_RECEIVER')),
  received_by_party_id bigint REFERENCES iam.party (id),
  occurred_at          timestamptz NOT NULL DEFAULT now(),
  lat                  numeric(9,6),
  lng                  numeric(9,6),
  source               text NOT NULL CHECK (source IN ('QR','NFC','DRIVER','ATTENDANT','SYSTEM')),
  recorded_by          bigint REFERENCES iam.app_user (id),
  CHECK ((event = 'HANDED_OVER') = (received_by_party_id IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS attendance_run_idx ON sch.attendance (run_id, enrollment_id, occurred_at);
CREATE INDEX IF NOT EXISTS attendance_enrollment_id_fkx ON sch.attendance (enrollment_id);
CREATE INDEX IF NOT EXISTS attendance_received_by_party_id_fkx ON sch.attendance (received_by_party_id);
CREATE INDEX IF NOT EXISTS attendance_recorded_by_fkx ON sch.attendance (recorded_by);
COMMENT ON TABLE sch.attendance IS 'Boarding, leaving and hand-over of each pupil on a run; append-only, guardians are notified from it';
SELECT sys.rls_parent('sch.attendance', 'run_id', 'sch.run');
SELECT sys.grant_append(ARRAY['sch.attendance']);

-- Hand-over: a pupil under the hand-over age leaves a homeward run only into the hands of an authorised receiver
CREATE OR REPLACE FUNCTION sch.tg_attendance_rules() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE r record; e record; birth date; young boolean;
BEGIN
  SELECT rt.* INTO r FROM sch.run rn JOIN sch.route rt ON rt.id = rn.route_id WHERE rn.id = NEW.run_id;
  SELECT * INTO e FROM sch.enrollment WHERE id = NEW.enrollment_id;
  IF r.id NOT IN (coalesce(e.to_route_id, 0), coalesce(e.from_route_id, 0)) THEN
    RAISE EXCEPTION 'WRONG_ROUTE: the pupil is not enrolled on this route' USING ERRCODE = 'P0001';
  END IF;
  SELECT p.birth_date INTO birth FROM sch.student s JOIN iam.party p ON p.id = s.party_id WHERE s.id = e.student_id;
  young := birth IS NULL OR iam.age_years(birth, NEW.occurred_at::date)
           < coalesce((SELECT (value #>> '{}')::int FROM sys.setting WHERE key = 'school.handover_age'), 12);
  IF r.direction = 'FROM_SCHOOL' AND NEW.event = 'ALIGHT' AND young THEN
    RAISE EXCEPTION 'RECEIVER_REQUIRED: a young pupil leaves the bus only into the hands of an authorised receiver' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.event = 'HANDED_OVER' AND NOT EXISTS (
       SELECT 1 FROM sch.student_guardian g WHERE g.student_id = e.student_id AND g.party_id = NEW.received_by_party_id
          AND g.can_receive AND NOT g.receive_blocked) THEN
    RAISE EXCEPTION 'RECEIVER_NOT_AUTHORIZED: the person is not an authorised receiver of the pupil' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS attendance_rules ON sch.attendance;
CREATE TRIGGER attendance_rules BEFORE INSERT ON sch.attendance FOR EACH ROW EXECUTE FUNCTION sch.tg_attendance_rules();

-- Pupils still on board: their last event on the run is a boarding
CREATE OR REPLACE FUNCTION sch.on_board(p_run bigint) RETURNS SETOF bigint
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT enrollment_id FROM (
    SELECT DISTINCT ON (enrollment_id) enrollment_id, event FROM sch.attendance
     WHERE run_id = p_run ORDER BY enrollment_id, occurred_at DESC, id DESC) last
   WHERE event = 'BOARD'
$$;
GRANT EXECUTE ON FUNCTION sch.on_board(bigint) TO masslak_app, masslak_readonly;

CREATE OR REPLACE FUNCTION sch.tg_run_close() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.status = 'COMPLETED' AND OLD.status <> 'COMPLETED' THEN
    IF EXISTS (SELECT 1 FROM sch.on_board(NEW.id)) THEN
      RAISE EXCEPTION 'CHILD_STILL_ON_BOARD: % pupil(s) boarded and never left the bus', (SELECT count(*) FROM sch.on_board(NEW.id))
        USING ERRCODE = 'P0001';
    END IF;
    IF NEW.sweep_checked_at IS NULL THEN
      RAISE EXCEPTION 'SWEEP_CHECK_MISSING: confirm the bus was checked empty before closing the run' USING ERRCODE = 'P0001';
    END IF;
    NEW.completed_at := coalesce(NEW.completed_at, now());
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS run_close ON sch.run;
CREATE TRIGGER run_close BEFORE UPDATE OF status ON sch.run FOR EACH ROW EXECUTE FUNCTION sch.tg_run_close();

CREATE TABLE IF NOT EXISTS sch.absence_notice (
  enrollment_id        bigint NOT NULL REFERENCES sch.enrollment (id),
  absent_on            date NOT NULL,
  direction            text NOT NULL CHECK (direction IN ('BOTH','TO_SCHOOL','FROM_SCHOOL')),
  reported_by_party_id bigint NOT NULL REFERENCES iam.party (id),
  reported_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (enrollment_id, absent_on, direction)
);
CREATE INDEX IF NOT EXISTS absence_notice_reported_by_party_id_fkx ON sch.absence_notice (reported_by_party_id);
COMMENT ON TABLE sch.absence_notice IS 'The guardian tells the bus in advance that the pupil will not ride';
SELECT sys.rls_parent('sch.absence_notice', 'enrollment_id', 'sch.enrollment');
SELECT sys.grant_rw(ARRAY['sch.absence_notice']);

-- ------------------------------ the module switch, the phase and the data classes ------------------------------
INSERT INTO sys.module_gate (schema_name, feature_keys, phase) VALUES ('sch', '{school_transport}', 'Phase SCH: school transport')
ON CONFLICT (schema_name) DO UPDATE SET feature_keys = EXCLUDED.feature_keys, phase = EXCLUDED.phase;
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT n.nspname || '.' || c.relname AS t FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'sch' AND c.relkind IN ('r','p') AND NOT c.relispartition LOOP
    EXECUTE format('DROP POLICY IF EXISTS module_gate ON %s', r.t);
    EXECUTE format('CREATE POLICY module_gate ON %s AS RESTRICTIVE FOR ALL USING (sys.ctx_is_platform() OR sys.feature_on(%L)) WITH CHECK (sys.ctx_is_platform() OR sys.feature_on(%L))',
                   r.t, '{school_transport}', '{school_transport}');
  END LOOP;
END $$;

INSERT INTO sys.project_phase (code, ordinal, name, study_ref, scope) VALUES
  ('SCH', 14.5, 'Phase SCH: school transport', 'Owner decision (1044); annex D.2',
   'A phase of its own: schools, operators (the school''s own buses, companies, individual owner-drivers, government and '
   || 'government-contracted carriers) under school transport licences, pupils linked to their guardians, contracts, routes '
   || 'with bus, driver and attendant, daily runs, boarding and hand-over to authorised receivers, the empty-bus check, '
   || 'absence notices, and route compliance of school buses')
ON CONFLICT (code) DO UPDATE SET ordinal = EXCLUDED.ordinal, name = EXCLUDED.name, study_ref = EXCLUDED.study_ref, scope = EXCLUDED.scope;
UPDATE sys.project_phase SET name = 'Phase 14: contracted transport (universities and staff)',
       scope = 'Contracts with universities and employers, their routes, riders, receivers, attendance and invoices; '
            || 'school transport is its own phase (SCH)'
 WHERE code = '14';

INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('sch.school', 'SCH', 'E35'), ('sch.operator', 'SCH', 'E35'), ('sch.student', 'SCH', 'E35'), ('sch.student_guardian', 'SCH', 'E35'),
  ('sch.contract', 'SCH', 'E35'), ('sch.route', 'SCH', 'E35'), ('sch.route_stop', 'SCH', 'E35'), ('sch.enrollment', 'SCH', 'E35'),
  ('sch.run', 'SCH', 'E35'), ('sch.attendance', 'SCH', 'E35'), ('sch.absence_notice', 'SCH', 'E35')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;

-- Pupils' identities, guardians, attendance and absences are personal data of minors: classified user-private
DO $$
DECLARE def text;
BEGIN
  def := pg_get_functiondef('sys.refresh_table_class()'::regprocedure);
  IF position('sch.student' IN def) = 0 THEN
    def := replace(def, '  DELETE FROM sys.table_class tc WHERE to_regclass(tc.table_name) IS NULL;',
      '  UPDATE sys.table_class SET data_class = ''USER_PRIVATE''' || chr(10) ||
      '   WHERE table_name IN (''sch.student'',''sch.student_guardian'',''sch.attendance'',''sch.absence_notice'');' || chr(10) ||
      '  DELETE FROM sys.table_class tc WHERE to_regclass(tc.table_name) IS NULL;');
    EXECUTE def;
  END IF;
END $$;

INSERT INTO sys.schema_migration (version, description)
SELECT '1.26.0', 'School transport: its own phase, operators under licence, pupils linked to guardians, hand-over and empty-bus rules'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.26.0');

SELECT sys.refresh_table_class();
