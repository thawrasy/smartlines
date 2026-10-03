-- =====================================================================
-- 030: الشبكة (المحطات، الخطوط، رموز الناقلين، أرقام الخدمات)
--      والأسطول (المركبات، المقاعد، الملكية، الطاقم، التراخيص، التأمين)
-- المرجع: 4.3، 4.4، 4.11، 4.13، 4.14، 4.16، 4.17، 4.18، 7.12 أ
-- =====================================================================

-- ============================== net ==================================
CREATE TABLE net.compliance_profile (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  subject       text NOT NULL DEFAULT 'STATION' CHECK (subject IN ('STATION','COMPANY','VEHICLE')),
  country_code  text NOT NULL,                        -- '*' = كل الدول
  station_class text NOT NULL CHECK (station_class IN ('CENTRAL','COMPANY','EXTERNAL','*')),
  version       int NOT NULL,
  spec          jsonb NOT NULL,                       -- {required:[], optional:[], grace_days}
  status        text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','ACTIVE','RETIRED')),
  created_by    bigint REFERENCES iam.app_user(id),
  approved_by   bigint REFERENCES iam.app_user(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (subject, country_code, station_class, version),
  CHECK (approved_by IS NULL OR approved_by <> created_by)
);
COMMENT ON TABLE net.compliance_profile IS 'ملف الامتثال بإصدارات لكل (دولة، فئة): الحقول المطلوبة ومهلة الاستكمال (4.11 ب)';

CREATE TABLE net.station (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid               uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  code              text NOT NULL UNIQUE CHECK (code ~ '^[A-Z]{2}-[A-Z]{3}-[CPX][0-9]{3,4}$'),  -- SY-DAM-C001
  city_id           bigint NOT NULL REFERENCES ref.city(id),
  country_code      char(2) NOT NULL REFERENCES ref.country(code),
  station_class     text NOT NULL CHECK (station_class IN ('CENTRAL','COMPANY','EXTERNAL')),
  subtype           text NOT NULL DEFAULT 'TERMINAL' CHECK (subtype IN ('TERMINAL','OFFICE','PICKUP','DEPOT','REST','BORDER')),
  owner_company_id  bigint REFERENCES iam.company(id),  -- فارغ للمحطات المركزية
  name_ar           text NOT NULL,
  name_en           text,
  address           text,
  lat               numeric(9,6) NOT NULL,
  lng               numeric(9,6) NOT NULL,
  phone             text,
  email             citext,
  hours             jsonb,
  facilities        text[],
  operator_name     text,
  license_no        text,
  license_authority text,
  license_expiry    date,
  lead_min          int NOT NULL DEFAULT 30 CHECK (lead_min >= 0),   -- زمن الوصول قبل الانطلاق
  status            text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','ACTIVE','SUSPENDED','REJECTED')),
  compliance_state  text NOT NULL DEFAULT 'OK' CHECK (compliance_state IN ('OK','ACTION_REQUIRED','NON_COMPLIANT')),
  compliance_profile_id bigint REFERENCES net.compliance_profile(id),
  extra             jsonb NOT NULL DEFAULT '{}',      -- حقول يفرضها ملف الامتثال دون تغيير المخطط
  verified_by       bigint REFERENCES iam.app_user(id),
  verified_at       timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CHECK (station_class = 'CENTRAL' OR owner_company_id IS NOT NULL)
);
CREATE INDEX station_city_idx ON net.station (city_id) WHERE status = 'ACTIVE';
CREATE INDEX station_name_trgm ON net.station USING gin (name_ar gin_trgm_ops);
CREATE TRIGGER station_updated BEFORE UPDATE ON net.station FOR EACH ROW EXECUTE FUNCTION sys.tg_set_updated_at();
COMMENT ON TABLE net.station IS 'سجل المحطات ونقاط الانطلاق والوصول (مركزية، نقطة شركة، خارجية) بكود فريد (4.11)';

CREATE TABLE net.station_contact (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  station_id  bigint NOT NULL REFERENCES net.station(id) ON DELETE CASCADE,
  role        text,
  name        text NOT NULL,
  phone       text,
  email       citext
);

-- رمز الناقل (4.16 أ)
CREATE TABLE net.carrier_code (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id  bigint NOT NULL REFERENCES iam.company(id),
  code3       char(3) NOT NULL CHECK (code3 ~ '^[A-Z]{3}$'),
  code2       char(2) CHECK (code2 ~ '^[A-Z0-9]{2}$' AND code2 ~ '[A-Z]'),
  code_type   text NOT NULL DEFAULT 'CARRIER' CHECK (code_type IN ('CARRIER','INDIVIDUAL','FOREIGN')),
  status      text NOT NULL DEFAULT 'PROPOSED' CHECK (status IN ('PROPOSED','ACTIVE','RETIRED')),
  approved_by bigint REFERENCES iam.app_user(id),
  valid_from  date,
  retired_at  date
);
CREATE UNIQUE INDEX carrier_code3_uq ON net.carrier_code (code3);
CREATE UNIQUE INDEX carrier_code2_uq ON net.carrier_code (code2) WHERE code2 IS NOT NULL;
CREATE UNIQUE INDEX carrier_one_active ON net.carrier_code (company_id) WHERE status = 'ACTIVE';
COMMENT ON TABLE net.carrier_code IS 'رمز الناقل الثلاثي (والثنائي الاختياري)، فريد على مستوى المنصة ولا يُعاد قبل 24 شهراً';

CREATE TABLE net.code_reservation (
  code    text PRIMARY KEY,
  reason  text NOT NULL CHECK (reason IN ('RESERVED','CONFUSABLE','OFFENSIVE','RETIRED')),
  until   date
);
COMMENT ON TABLE net.code_reservation IS 'رموز محجوزة أو ممنوعة أو مسحوبة مؤقتاً';

-- قالب الخط للناقل (4.4 و4.12)
CREATE TABLE net.route (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid               uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  company_id        bigint NOT NULL REFERENCES iam.company(id),
  code              text NOT NULL,
  origin_station_id bigint NOT NULL REFERENCES net.station(id),
  dest_station_id   bigint NOT NULL REFERENCES net.station(id),
  service_type      text NOT NULL DEFAULT 'DIRECT' CHECK (service_type IN ('DIRECT','INDIRECT')),
  route_scope       text NOT NULL DEFAULT 'DOMESTIC' CHECK (route_scope IN ('DOMESTIC','INTERNATIONAL')),
  distance_km       int CHECK (distance_km > 0),
  std_duration_min  int CHECK (std_duration_min > 0),
  status            text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('DRAFT','ACTIVE','RETIRED')),
  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (company_id, code),
  CHECK (origin_station_id <> dest_station_id)
);
COMMENT ON TABLE net.route IS 'قالب خط الناقل بين محطتين؛ تُنسخ محطاته إلى الرحلة عند توليدها (كتالوج الخطوط المعتمد 4.15 يضاف في المرحلة 2)';

CREATE TABLE net.route_stop (
  route_id      bigint NOT NULL REFERENCES net.route(id) ON DELETE CASCADE,
  seq           smallint NOT NULL CHECK (seq >= 0),
  station_id    bigint NOT NULL REFERENCES net.station(id),
  kind          text NOT NULL CHECK (kind IN ('ORIGIN','STOP','REST','DEST')),
  arr_offset_min int NOT NULL DEFAULT 0,
  dep_offset_min int NOT NULL DEFAULT 0,
  rest_min      smallint NOT NULL DEFAULT 0,
  dist_from_origin_km int,
  fare_from_origin bigint CHECK (fare_from_origin >= 0),   -- سلّم الأسعار الافتراضي (4.12 ب)
  sellable      boolean NOT NULL DEFAULT true,
  PRIMARY KEY (route_id, seq),
  CHECK (dep_offset_min >= arr_offset_min)
);
COMMENT ON TABLE net.route_stop IS 'محطات الخط بالترتيب، وأزمنة الإزاحة، وسلّم السعر من الأصل';

-- رقم الخدمة (4.16 ب)
CREATE TABLE net.service_number (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id  bigint NOT NULL REFERENCES iam.company(id),
  number      int NOT NULL CHECK (number BETWEEN 1 AND 9999),
  block       text NOT NULL CHECK (block IN ('SCHEDULED','INTL','SHUTTLE','CARGO','EXTRA')),
  route_id    bigint REFERENCES net.route(id),
  direction   text NOT NULL CHECK (direction IN ('OUTBOUND','INBOUND')),
  valid       daterange NOT NULL DEFAULT daterange(current_date, NULL),
  created_at  timestamptz NOT NULL DEFAULT now(),
  CHECK (
    (block = 'SCHEDULED' AND number BETWEEN 1 AND 999) OR
    (block = 'INTL'      AND number BETWEEN 1000 AND 1999) OR
    (block = 'SHUTTLE'   AND number BETWEEN 2000 AND 2999) OR
    (block = 'CARGO'     AND number BETWEEN 3000 AND 3999) OR
    (block = 'EXTRA'     AND number BETWEEN 5000 AND 9999)),
  CHECK ((direction = 'OUTBOUND') = (number % 2 = 1) OR block = 'EXTRA'),   -- فردي ذهاب، زوجي عودة
  EXCLUDE USING gist (company_id WITH =, number WITH =, valid WITH &&)
);
COMMENT ON TABLE net.service_number IS 'رقم الخدمة المتكررة من كتلة النوع؛ لا يتكرر للناقل في فترة متداخلة';

-- ============================== fleet ================================
CREATE TABLE fleet.seat_layout (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id  bigint REFERENCES iam.company(id),      -- فارغ = قالب عام
  name        text NOT NULL,
  total_seats smallint NOT NULL CHECK (total_seats > 0),
  decks       smallint NOT NULL DEFAULT 1 CHECK (decks IN (1,2)),
  created_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE fleet.seat_layout IS 'مخططات المقاعد القابلة لإعادة الاستخدام';

CREATE TABLE fleet.seat_layout_seat (
  layout_id   bigint NOT NULL REFERENCES fleet.seat_layout(id) ON DELETE CASCADE,
  seat_no     smallint NOT NULL CHECK (seat_no > 0),
  label       text,                                   -- 1A, 1B ...
  row_no      smallint NOT NULL,
  col_no      smallint NOT NULL,
  deck        smallint NOT NULL DEFAULT 1,
  cabin       text NOT NULL DEFAULT 'ECONOMY' CHECK (cabin IN ('ECONOMY','BUSINESS','VIP','ACCESSIBLE')),
  PRIMARY KEY (layout_id, seat_no),
  UNIQUE (layout_id, deck, row_no, col_no)
);
COMMENT ON TABLE fleet.seat_layout_seat IS 'مقاعد الركاب في المخطط (مقاعد الطاقم لا تدخل المخزون 4.14)';

CREATE TABLE fleet.vehicle (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid               uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  company_id        bigint NOT NULL REFERENCES iam.company(id),
  vehicle_class     text NOT NULL DEFAULT 'BUS' CHECK (vehicle_class IN ('BUS','TRUCK','TRAIN','CAR','OTHER')),
  vehicle_type      text NOT NULL CHECK (vehicle_type IN ('COACH','MINIBUS','CITY_BUS','VAN','TRAIN_SET','OTHER')),
  make              text,
  model             text,
  manufacture_year  smallint CHECK (manufacture_year BETWEEN 1950 AND 2100),
  plate_no          text NOT NULL,
  plate_country     char(2) NOT NULL DEFAULT 'SY' REFERENCES ref.country(code),
  chassis_no        text NOT NULL,
  serial_no         text,
  machine_no        text,
  seat_layout_id    bigint REFERENCES fleet.seat_layout(id),
  passenger_seats   smallint NOT NULL CHECK (passenger_seats >= 0),
  standing_capacity smallint NOT NULL DEFAULT 0 CHECK (standing_capacity >= 0),
  standing_factor   numeric(4,3) NOT NULL DEFAULT 0.600,
  crew_seats        jsonb NOT NULL DEFAULT '{"driver":1}',   -- {driver, steward, assistant}
  cargo_capacity_kg int NOT NULL DEFAULT 0 CHECK (cargo_capacity_kg >= 0),
  fuel_tank_l       int,
  ownership_type    text NOT NULL DEFAULT 'OWNED' CHECK (ownership_type IN ('OWNED','LEASED')),
  owner_party_id    bigint NOT NULL REFERENCES iam.party(id),
  status            text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','ACTIVE','BLOCKED','OUT_OF_SERVICE','IMPOUNDED','RETIRED')),
  block_reason      text,                             -- مثل LICENSE_EXPIRED, INSURANCE_EXPIRED, LEASE_EXPIRED
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (plate_country, plate_no),
  UNIQUE (chassis_no)
);
CREATE INDEX vehicle_company_idx ON fleet.vehicle (company_id, status);
CREATE TRIGGER vehicle_updated BEFORE UPDATE ON fleet.vehicle FOR EACH ROW EXECUTE FUNCTION sys.tg_set_updated_at();
COMMENT ON TABLE fleet.vehicle IS 'المركبة: النوع والسعة الجالسة والواقفة، الملكية والمالك، والحالة التي تحجبها عن الإسناد (4.3، 4.13، 4.17، 4.18)';

CREATE TABLE fleet.seat_price_rule (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id    bigint NOT NULL REFERENCES iam.company(id),
  vehicle_id    bigint REFERENCES fleet.vehicle(id),
  seat_layout_id bigint REFERENCES fleet.seat_layout(id),
  seat_nos      smallint[] NOT NULL,
  price_delta   bigint NOT NULL,                      -- موجب للمميز، سالب للمخفض
  label         text NOT NULL,
  active        boolean NOT NULL DEFAULT true,
  CHECK (vehicle_id IS NOT NULL OR seat_layout_id IS NOT NULL)
);
COMMENT ON TABLE fleet.seat_price_rule IS 'أسعار المقاعد المميزة أو المخفضة يحددها الناقل (4.14 أ)';

CREATE TABLE fleet.vehicle_lease (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  vehicle_id        bigint NOT NULL REFERENCES fleet.vehicle(id),
  owner_party_id    bigint NOT NULL REFERENCES iam.party(id),
  lessee_company_id bigint NOT NULL REFERENCES iam.company(id),
  contract_no       text NOT NULL,
  period            daterange NOT NULL,
  document_id       bigint REFERENCES iam.document(id),
  status            text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','EXPIRED','TERMINATED')),
  created_at        timestamptz NOT NULL DEFAULT now(),
  EXCLUDE USING gist (vehicle_id WITH =, period WITH &&) WHERE (status = 'ACTIVE')
);
COMMENT ON TABLE fleet.vehicle_lease IS 'عقد إيجار المركبة؛ مستأجر فعّال واحد لكل مركبة في الفترة (قيد استبعاد)';

CREATE TABLE fleet.crew_profile (
  party_id      bigint PRIMARY KEY REFERENCES iam.party(id),
  company_id    bigint NOT NULL REFERENCES iam.company(id),
  crew_type     text NOT NULL CHECK (crew_type IN ('DRIVER','HOST','ASSISTANT')),
  license_class text,
  status        text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('PENDING','ACTIVE','BLOCKED','LEFT')),
  created_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE fleet.crew_profile IS 'السائقون والمضيفون؛ رخصهم وتواريخها في fleet.license_record';

-- سجل التراخيص الموحد (4.18): تاريخ انتهاء مقفل بعد الحفظ، وتعديل باعتماد مزدوج
CREATE TABLE fleet.license_record (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id        bigint REFERENCES iam.company(id),
  subject_type      text NOT NULL CHECK (subject_type IN ('VEHICLE','DRIVER','COMPANY','STATION','PARTNER')),
  subject_id        bigint NOT NULL,
  license_type      text NOT NULL CHECK (license_type IN ('TRANSPORT','INSPECTION','INSURANCE','DRIVING','MEDICAL','CR','STATION','OTHER')),
  license_no        text NOT NULL,
  issuer            text NOT NULL,
  issue_date        date NOT NULL,
  expiry_date       date NOT NULL,
  source            text NOT NULL DEFAULT 'MANUAL' CHECK (source IN ('MANUAL','GOV')),
  locked            boolean NOT NULL DEFAULT true,
  document_id       bigint REFERENCES iam.document(id),
  status            text NOT NULL DEFAULT 'PENDING_REVIEW' CHECK (status IN ('PENDING_REVIEW','VALID','EXPIRING','EXPIRED','SUSPENDED')),
  verified_by       bigint REFERENCES iam.app_user(id),
  last_change_request_id bigint,
  last_gov_sync_at  timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  CHECK (expiry_date > issue_date)
);
CREATE INDEX license_subject_idx ON fleet.license_record (subject_type, subject_id, license_type);
CREATE INDEX license_expiry_idx  ON fleet.license_record (expiry_date) WHERE status IN ('VALID','EXPIRING');
COMMENT ON TABLE fleet.license_record IS 'كل تاريخ انتهاء يحكم أهلية التشغيل (ترخيص، فحص، تأمين، رخصة قيادة)؛ مقفل بعد الحفظ';

CREATE TABLE fleet.license_change_request (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  license_record_id bigint NOT NULL REFERENCES fleet.license_record(id),
  requested_by      bigint NOT NULL REFERENCES iam.app_user(id),
  new_values        jsonb NOT NULL,
  document_id       bigint REFERENCES iam.document(id),
  status            text NOT NULL DEFAULT 'SUBMITTED' CHECK (status IN ('SUBMITTED','REVIEWED','APPROVED','REJECTED')),
  reviewed_by       bigint REFERENCES iam.app_user(id),
  approved_by       bigint REFERENCES iam.app_user(id),
  decision_reason   text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  decided_at        timestamptz,
  CHECK (approved_by IS NULL OR (approved_by <> requested_by AND approved_by IS DISTINCT FROM reviewed_by))
);
ALTER TABLE fleet.license_record ADD CONSTRAINT license_last_change_fk
  FOREIGN KEY (last_change_request_id) REFERENCES fleet.license_change_request(id);
COMMENT ON TABLE fleet.license_change_request IS 'طلب تعديل ترخيص مقفل: مراجعة ثم اعتماد من مسؤول مختلف';

-- لا يُعدَّل رقم الترخيص أو تاريخه بعد الإقفال إلا بطلب معتمد جديد
CREATE OR REPLACE FUNCTION fleet.tg_license_locked() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.locked AND (NEW.expiry_date IS DISTINCT FROM OLD.expiry_date
                  OR NEW.license_no  IS DISTINCT FROM OLD.license_no
                  OR NEW.issue_date  IS DISTINCT FROM OLD.issue_date) THEN
    IF NEW.source = 'GOV' AND OLD.source = 'GOV' THEN
      RETURN NEW;                                       -- التحديث الحكومي هو المرجع (4.18 ج)
    END IF;
    IF NEW.last_change_request_id IS NOT DISTINCT FROM OLD.last_change_request_id
       OR NOT EXISTS (SELECT 1 FROM fleet.license_change_request r
                      WHERE r.id = NEW.last_change_request_id AND r.status = 'APPROVED'
                        AND r.license_record_id = NEW.id) THEN
      RAISE EXCEPTION 'LICENSE_LOCKED: change requires an approved change request' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER license_locked BEFORE UPDATE ON fleet.license_record FOR EACH ROW EXECUTE FUNCTION fleet.tg_license_locked();

CREATE TABLE fleet.insurance_policy (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  vehicle_id        bigint NOT NULL REFERENCES fleet.vehicle(id),
  insurer_party_id  bigint REFERENCES iam.party(id),
  insurer_name      text NOT NULL,
  policy_no         text NOT NULL,
  coverage_type     text NOT NULL CHECK (coverage_type IN ('THIRD_PARTY','COMPREHENSIVE')),
  passenger_cover   boolean NOT NULL DEFAULT false,
  cargo_cover       boolean NOT NULL DEFAULT false,
  limits            jsonb,
  period            daterange NOT NULL,
  license_record_id bigint REFERENCES fleet.license_record(id),   -- يحكم الحجب عند الانتهاء
  document_id       bigint REFERENCES iam.document(id),
  source            text NOT NULL DEFAULT 'MANUAL' CHECK (source IN ('MANUAL','TRAFFIC','INSURER')),
  verified_at       timestamptz,
  status            text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','VALID','EXPIRED','CANCELLED')),
  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (insurer_name, policy_no)
);
COMMENT ON TABLE fleet.insurance_policy IS 'عقد التأمين شرط لتفعيل المركبة؛ يُتحقق منه لاحقاً من المرور أو شركات التأمين (7.12 أ)';

CREATE TABLE fleet.vehicle_qr_tag (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  vehicle_id  bigint NOT NULL REFERENCES fleet.vehicle(id),
  token_hash  bytea NOT NULL UNIQUE,
  issued_at   timestamptz NOT NULL DEFAULT now(),
  revoked_at  timestamptz
);
CREATE UNIQUE INDEX vehicle_qr_one_active ON fleet.vehicle_qr_tag (vehicle_id) WHERE revoked_at IS NULL;
COMMENT ON TABLE fleet.vehicle_qr_tag IS 'ملصق QR الموقّع على المركبة للتحقق الميداني (4.18 هـ)';

CREATE TABLE fleet.field_check_log (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  inspector_user_id   bigint NOT NULL REFERENCES iam.app_user(id),
  vehicle_id          bigint REFERENCES fleet.vehicle(id),
  method              text NOT NULL CHECK (method IN ('QR','PLATE')),
  result              text NOT NULL CHECK (result IN ('VALID','EXPIRED','NOT_FOUND','MISMATCH')),
  lat                 numeric(9,6),
  lng                 numeric(9,6),
  created_at          timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE fleet.field_check_log IS 'كل استعلام ميداني من رجال الأمن والجهات المخوّلة';

CREATE TABLE fleet.vehicle_status_history (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  vehicle_id    bigint NOT NULL REFERENCES fleet.vehicle(id),
  status        text NOT NULL,
  reason        text NOT NULL,
  incident_id   bigint,                               -- FK بعد ops.incident
  changed_by    bigint REFERENCES iam.app_user(id),
  release_document_id bigint REFERENCES iam.document(id),
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX vehicle_status_hist_idx ON fleet.vehicle_status_history (vehicle_id, created_at DESC);
COMMENT ON TABLE fleet.vehicle_status_history IS 'تاريخ حالة المركبة (إيقاف بعد حادث، حجز، إفراج) بالسبب والدليل';
