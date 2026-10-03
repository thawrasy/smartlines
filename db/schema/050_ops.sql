-- =====================================================================
-- 050: الرحلات والمخزون حسب المقطع والطاقم والتشغيل والتتبع والحوادث
-- المرجع: 4.5، 4.12، 4.14 أ، 4.16 د، 7.8، 7.9، 7.12
-- منع التعارض بقيود استبعاد في القاعدة نفسها:
--   مركبة واحدة لا تُسند لرحلتين متداخلتين (مع هامش التجهيز)،
--   وفرد الطاقم لا يُسند لرحلتين متداخلتين.
-- =====================================================================

CREATE TABLE ops.trip_template (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id          bigint NOT NULL REFERENCES iam.company(id),
  route_id            bigint NOT NULL REFERENCES net.route(id),
  service_number_id   bigint REFERENCES net.service_number(id),
  default_vehicle_id  bigint REFERENCES fleet.vehicle(id),
  departure_time      time NOT NULL,
  days_of_week        smallint[] NOT NULL DEFAULT '{1,2,3,4,5,6,7}',
  recurrence_rule     text,                           -- RRULE اختياري للحالات المعقدة
  fare_brand_codes    text[] NOT NULL DEFAULT '{}',
  base_price          bigint NOT NULL CHECK (base_price >= 0),
  currency            char(3) NOT NULL REFERENCES ref.currency(code),
  active              daterange NOT NULL,
  status              text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','PAUSED','RETIRED')),
  created_at          timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE ops.trip_template IS 'نمط الرحلة المتكررة الذي يولّد الرحلات الفعلية';

CREATE TABLE ops.trip (
  id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                   uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  trip_no               text NOT NULL UNIQUE,         -- QD214A/02OCT26 (4.16)
  company_id            bigint NOT NULL REFERENCES iam.company(id),
  service_number_id     bigint REFERENCES net.service_number(id),
  section_suffix        char(1) CHECK (section_suffix ~ '^[A-Z]$'),
  template_id           bigint REFERENCES ops.trip_template(id),
  route_id              bigint NOT NULL REFERENCES net.route(id),
  trip_type             text NOT NULL DEFAULT 'SCHEDULED' CHECK (trip_type IN ('SCHEDULED','SHUTTLE','INTERNATIONAL','CARGO','EXTRA')),
  transport_mode        text NOT NULL DEFAULT 'BUS' CHECK (transport_mode IN ('BUS','TRAIN','OTHER')),
  service_type          text NOT NULL DEFAULT 'DIRECT' CHECK (service_type IN ('DIRECT','INDIRECT')),
  has_rest              boolean NOT NULL DEFAULT false,
  vehicle_id            bigint REFERENCES fleet.vehicle(id),
  departure_at          timestamptz NOT NULL,
  arrival_at            timestamptz NOT NULL,
  turnaround_min        smallint NOT NULL DEFAULT 30 CHECK (turnaround_min >= 0),
  vehicle_busy          tstzrange,                    -- يُحسب آلياً: الانطلاق → الوصول + التجهيز
  status                text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','PUBLISHED','BOARDING','DEPARTED','COMPLETED','CANCELLED')),
  capacity_mode         text NOT NULL DEFAULT 'SEATED' CHECK (capacity_mode IN ('SEATED','CAPACITY')),
  seat_selection_mode   text NOT NULL DEFAULT 'OPEN_PAID' CHECK (seat_selection_mode IN ('OPEN_PAID','FAMILY_ZONES','CARRIER_ASSIGNED')),
  seats_total           smallint NOT NULL CHECK (seats_total >= 0),
  standing_capacity     smallint NOT NULL DEFAULT 0,
  standing_factor       numeric(4,3) NOT NULL DEFAULT 0.600,
  cargo_capacity_kg     int NOT NULL DEFAULT 0,
  segments_count        smallint NOT NULL CHECK (segments_count >= 1),
  currency              char(3) NOT NULL REFERENCES ref.currency(code),
  base_price            bigint NOT NULL CHECK (base_price >= 0),
  fare_brand_codes      text[] NOT NULL DEFAULT '{}',
  baggage_policy        jsonb NOT NULL DEFAULT '{}',
  crew_snapshot         jsonb NOT NULL DEFAULT '{}',  -- لقطة الطاقم عند النشر (4.14)
  seat_prices_snapshot  jsonb NOT NULL DEFAULT '[]',
  post_departure_policy text NOT NULL DEFAULT 'PHYSICAL_FREE' CHECK (post_departure_policy IN ('PHYSICAL_FREE','FREED_ONLY')),
  sales_cutoff_min      smallint NOT NULL DEFAULT 15,
  hold_min              smallint NOT NULL DEFAULT 10,
  shift_min             int NOT NULL DEFAULT 0,       -- إجمالي التأخير المتراكم (7.9)
  clearance_status      text NOT NULL DEFAULT 'NOT_REQUIRED' CHECK (clearance_status IN ('NOT_REQUIRED','PENDING','CLEARED','DENIED')),
  tracking_level        text NOT NULL DEFAULT 'NORMAL' CHECK (tracking_level IN ('NORMAL','STRICT')),
  published_at          timestamptz,
  external_ref          text,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  CHECK (arrival_at > departure_at),
  CHECK (status IN ('DRAFT','CANCELLED') OR vehicle_id IS NOT NULL),
  EXCLUDE USING gist (vehicle_id WITH =, vehicle_busy WITH &&)
    WHERE (vehicle_id IS NOT NULL AND status <> 'CANCELLED')
);
CREATE INDEX trip_search_idx  ON ops.trip (route_id, departure_at) WHERE status IN ('PUBLISHED','BOARDING','DEPARTED');
CREATE INDEX trip_company_idx ON ops.trip (company_id, departure_at DESC);
COMMENT ON TABLE ops.trip IS 'الرحلة الفعلية (الكيان المحوري) برقمها والمركبة والسعة واللقطات والسياسات؛ قيد استبعاد يمنع تعارض المركبة';

CREATE OR REPLACE FUNCTION ops.tg_trip_busy() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.vehicle_busy := tstzrange(NEW.departure_at, NEW.arrival_at + make_interval(mins => NEW.turnaround_min), '[)');
  NEW.updated_at := now();
  RETURN NEW;
END $$;
CREATE TRIGGER trip_busy BEFORE INSERT OR UPDATE ON ops.trip FOR EACH ROW EXECUTE FUNCTION ops.tg_trip_busy();

-- لا تُسند لرحلة منشورة مركبة غير فعّالة (ترخيص/تأمين/إيجار منتهٍ يجعلها BLOCKED)
CREATE OR REPLACE FUNCTION ops.tg_trip_vehicle_eligible() RETURNS trigger LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_status text; v_company bigint;
BEGIN
  IF NEW.vehicle_id IS NOT NULL AND NEW.status IN ('PUBLISHED','BOARDING')
     AND (TG_OP = 'INSERT' OR NEW.vehicle_id IS DISTINCT FROM OLD.vehicle_id OR NEW.status IS DISTINCT FROM OLD.status) THEN
    SELECT status, company_id INTO v_status, v_company FROM fleet.vehicle WHERE id = NEW.vehicle_id;
    IF v_status IS DISTINCT FROM 'ACTIVE' THEN
      RAISE EXCEPTION 'VEHICLE_NOT_ELIGIBLE: vehicle status is %', v_status USING ERRCODE = 'P0001';
    END IF;
    IF v_company <> NEW.company_id AND NOT EXISTS (
         SELECT 1 FROM fleet.vehicle_lease l WHERE l.vehicle_id = NEW.vehicle_id AND l.lessee_company_id = NEW.company_id
           AND l.status = 'ACTIVE' AND l.period @> (NEW.departure_at AT TIME ZONE 'UTC')::date) THEN
      RAISE EXCEPTION 'VEHICLE_NOT_OWNED_OR_LEASED' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trip_vehicle_eligible BEFORE INSERT OR UPDATE ON ops.trip FOR EACH ROW EXECUTE FUNCTION ops.tg_trip_vehicle_eligible();

CREATE TABLE ops.trip_stop (
  trip_id           bigint NOT NULL REFERENCES ops.trip(id) ON DELETE CASCADE,
  seq               smallint NOT NULL CHECK (seq >= 0),
  station_id        bigint NOT NULL REFERENCES net.station(id),
  kind              text NOT NULL DEFAULT 'STATION' CHECK (kind IN ('STATION','REST')),
  sellable          boolean NOT NULL DEFAULT true,
  sched_arr         timestamptz,
  sched_dep         timestamptz,
  actual_arr        timestamptz,
  actual_dep        timestamptz,
  rest_min          smallint NOT NULL DEFAULT 0,
  fare_from_origin  bigint NOT NULL DEFAULT 0 CHECK (fare_from_origin >= 0),  -- سلّم السعر (4.12 ب)
  sales_closed_at   timestamptz,
  PRIMARY KEY (trip_id, seq)
);
COMMENT ON TABLE ops.trip_stop IS 'محطات الرحلة (لقطة من الخط) بالأوقات الموعودة والفعلية وسلّم السعر';

CREATE TABLE ops.trip_pair_fare (
  trip_id   bigint NOT NULL REFERENCES ops.trip(id) ON DELETE CASCADE,
  from_seq  smallint NOT NULL,
  to_seq    smallint NOT NULL,
  price     bigint NOT NULL CHECK (price >= 0),
  PRIMARY KEY (trip_id, from_seq, to_seq),
  CHECK (to_seq > from_seq)
);
COMMENT ON TABLE ops.trip_pair_fare IS 'سعر استثنائي لزوج محطات يتجاوز فرق السلّم';

-- مخزون المقعد لكل مقطع: صف لكل (رحلة، مقعد، مقطع) — قفل ذري للمقاطع كلها أو الرفض
CREATE TABLE ops.seat_segment (
  trip_id         bigint NOT NULL REFERENCES ops.trip(id) ON DELETE CASCADE,
  seat_no         smallint NOT NULL,
  seg             smallint NOT NULL,                  -- المقطع i بين المحطة i والمحطة i+1
  status          text NOT NULL DEFAULT 'AVAILABLE' CHECK (status IN ('AVAILABLE','LOCKED','SOLD','BLOCKED')),
  lock_token      uuid,
  lock_user_id    bigint,
  lock_expires_at timestamptz,
  ticket_id       bigint,                             -- FK بعد sales.ticket
  PRIMARY KEY (trip_id, seat_no, seg),
  CHECK (status <> 'LOCKED' OR (lock_token IS NOT NULL AND lock_expires_at IS NOT NULL)),
  CHECK (status <> 'SOLD' OR ticket_id IS NOT NULL)
);
CREATE INDEX seat_segment_avail ON ops.seat_segment (trip_id, seg) WHERE status = 'AVAILABLE';
CREATE INDEX seat_segment_locks ON ops.seat_segment (lock_expires_at) WHERE status = 'LOCKED';
COMMENT ON TABLE ops.seat_segment IS 'مخزون المقعد لكل مقطع (4.12 ج): المقعد يُباع للزوج إن كان شاغراً في كل مقاطعه';

CREATE TABLE ops.standing_segment (
  trip_id   bigint NOT NULL REFERENCES ops.trip(id) ON DELETE CASCADE,
  seg       smallint NOT NULL,
  capacity  smallint NOT NULL CHECK (capacity >= 0),
  used      smallint NOT NULL DEFAULT 0,
  PRIMARY KEY (trip_id, seg),
  CHECK (used BETWEEN 0 AND capacity)
);
COMMENT ON TABLE ops.standing_segment IS 'عدّاد أماكن الوقوف لكل مقطع، لا يتجاوز السعة';

CREATE TABLE ops.family_zone (
  trip_id   bigint NOT NULL REFERENCES ops.trip(id) ON DELETE CASCADE,
  seat_nos  smallint[] NOT NULL,
  label     text NOT NULL DEFAULT 'FAMILY',
  PRIMARY KEY (trip_id, label)
);
COMMENT ON TABLE ops.family_zone IS 'مناطق العائلات في الرحلة (4.14 أ)';

CREATE TABLE ops.crew_assignment (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  trip_id     bigint NOT NULL REFERENCES ops.trip(id) ON DELETE CASCADE,
  party_id    bigint NOT NULL REFERENCES fleet.crew_profile(party_id),
  crew_role   text NOT NULL CHECK (crew_role IN ('DRIVER','CO_DRIVER','HOST','ASSISTANT')),
  busy        tstzrange NOT NULL,                     -- يُنسخ من الرحلة آلياً
  status      text NOT NULL DEFAULT 'ASSIGNED' CHECK (status IN ('ASSIGNED','CONFIRMED','RELEASED')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (trip_id, party_id),
  EXCLUDE USING gist (party_id WITH =, busy WITH &&) WHERE (status <> 'RELEASED')
);
COMMENT ON TABLE ops.crew_assignment IS 'إسناد الطاقم للرحلة؛ قيد استبعاد يمنع إسناد الفرد لرحلتين متداخلتين';

CREATE OR REPLACE FUNCTION ops.tg_crew_busy() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  SELECT vehicle_busy INTO NEW.busy FROM ops.trip WHERE id = NEW.trip_id;
  RETURN NEW;
END $$;
CREATE TRIGGER crew_busy BEFORE INSERT OR UPDATE OF trip_id ON ops.crew_assignment FOR EACH ROW EXECUTE FUNCTION ops.tg_crew_busy();

CREATE TABLE ops.trip_stop_event (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  trip_id     bigint NOT NULL REFERENCES ops.trip(id),
  seq         smallint NOT NULL,
  kind        text NOT NULL CHECK (kind IN ('ARRIVE','DEPART')),
  ts          timestamptz NOT NULL,
  delay_min   int,
  source      text NOT NULL DEFAULT 'DRIVER_APP' CHECK (source IN ('DRIVER_APP','OPERATOR','TRACKING','GATE')),
  by_user_id  bigint REFERENCES iam.app_user(id),
  created_at  timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (trip_id, seq) REFERENCES ops.trip_stop(trip_id, seq)
);
COMMENT ON TABLE ops.trip_stop_event IS 'الوصول والمغادرة الفعليان لكل محطة (أساس الالتزام بالموعد 4.12 ح)';

CREATE TABLE ops.trip_change (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  trip_id         bigint NOT NULL REFERENCES ops.trip(id),
  kind            text NOT NULL CHECK (kind IN ('DELAY','RESCHEDULE','CANCEL','VEHICLE_SWAP','STOP_CHANGE')),
  old_departure   timestamptz,
  new_departure   timestamptz,
  shift_min       int,
  reason          text NOT NULL,
  by_user_id      bigint REFERENCES iam.app_user(id),
  created_at      timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE ops.trip_change IS 'سجل تغييرات الرحلة وأسبابها (7.9)';

CREATE TABLE ops.vehicle_swap (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  trip_id         bigint NOT NULL REFERENCES ops.trip(id),
  from_vehicle_id bigint NOT NULL REFERENCES fleet.vehicle(id),
  to_vehicle_id   bigint NOT NULL REFERENCES fleet.vehicle(id),
  reason          text NOT NULL,
  seats_reassigned boolean NOT NULL DEFAULT false,
  approved_by     bigint REFERENCES iam.app_user(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  CHECK (from_vehicle_id <> to_vehicle_id)
);
COMMENT ON TABLE ops.vehicle_swap IS 'تبديل مركبة الرحلة دون تغيير رقمها (4.16 د)';

-- ------------------------------ التتبع (مقسّم شهرياً) ----------------
CREATE TABLE ops.geo_event (
  id            bigint GENERATED ALWAYS AS IDENTITY,
  ts            timestamptz NOT NULL,
  trip_id       bigint,
  vehicle_id    bigint,
  driver_user_id bigint,
  lat           numeric(9,6) NOT NULL,
  lng           numeric(9,6) NOT NULL,
  accuracy_m    real,
  speed_kmh     real,
  heading       smallint,
  source        text NOT NULL DEFAULT 'DRIVER_APP' CHECK (source IN ('DRIVER_APP','GPS_DEVICE')),
  PRIMARY KEY (id, ts)
) PARTITION BY RANGE (ts);
CREATE INDEX geo_event_trip_idx ON ops.geo_event (trip_id, ts);
COMMENT ON TABLE ops.geo_event IS 'مواقع التتبع؛ مقسّم شهرياً، ومدة احتفاظ قصيرة (16.13: 7 أيام افتراضياً للأفراد)؛ بلا FK لأداء الإدخال';

CREATE TABLE ops.tracking_alert (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  trip_id     bigint NOT NULL REFERENCES ops.trip(id),
  kind        text NOT NULL CHECK (kind IN ('SIGNAL_LOST','TRACKING_OFF','OFF_ROUTE','MISSED_STOP','UNSCHEDULED_STOP','SPEEDING')),
  severity    text NOT NULL CHECK (severity IN ('LOW','MEDIUM','HIGH','CRITICAL')),
  status      text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','RESOLVED')),
  escalated   boolean NOT NULL DEFAULT false,
  detail      jsonb,
  opened_at   timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz
);
CREATE INDEX tracking_alert_open ON ops.tracking_alert (trip_id) WHERE status = 'OPEN';

-- ------------------------------ الحوادث واستمرارية الرحلة (7.12) ------
CREATE TABLE ops.incident (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid               uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  company_id        bigint NOT NULL REFERENCES iam.company(id),
  vehicle_id        bigint REFERENCES fleet.vehicle(id),
  trip_id           bigint REFERENCES ops.trip(id),
  driver_party_id   bigint REFERENCES iam.party(id),
  type              text NOT NULL CHECK (type IN ('COLLISION','BREAKDOWN','FIRE','SECURITY','SEIZURE','MEDICAL','OTHER')),
  severity          text NOT NULL CHECK (severity IN ('MINOR','MAJOR','SEVERE')),
  injuries          boolean NOT NULL DEFAULT false,
  lat               numeric(9,6),
  lng               numeric(9,6),
  occurred_at       timestamptz NOT NULL,
  police_report_no  text,
  reported_via      text NOT NULL DEFAULT 'DRIVER_APP' CHECK (reported_via IN ('DRIVER_APP','OPERATOR','CALL_CENTER','SOS')),
  reported_by       bigint REFERENCES iam.app_user(id),
  status            text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','UNDER_REVIEW','CLOSED')),
  created_at        timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE ops.incident IS 'الحادث أو العطل؛ الجسيم منه يوقف المركبة فوراً ويطلب قرار استمرارية';

ALTER TABLE fleet.vehicle_status_history ADD CONSTRAINT vsh_incident_fk FOREIGN KEY (incident_id) REFERENCES ops.incident(id);

CREATE TABLE ops.incident_evidence (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  incident_id bigint NOT NULL REFERENCES ops.incident(id),
  file_id     bigint NOT NULL REFERENCES ref.file_object(id),
  kind        text NOT NULL CHECK (kind IN ('PHOTO','VIDEO','REPORT')),
  uploaded_by bigint REFERENCES iam.app_user(id),
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE ops.incident_external_link (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  incident_id   bigint NOT NULL REFERENCES ops.incident(id),
  authority     text NOT NULL CHECK (authority IN ('TRAFFIC','POLICE','REGULATOR','INSURER')),
  external_ref  text,
  status        text NOT NULL DEFAULT 'PENDING',
  last_sync_at  timestamptz,
  UNIQUE (incident_id, authority)
);
COMMENT ON TABLE ops.incident_external_link IS 'الربط مع المرور والشرطة وشركات التأمين (يُفعَّل بعد الربط الحكومي)';

CREATE TABLE ops.trip_disruption (
  id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  trip_id               bigint NOT NULL REFERENCES ops.trip(id),
  incident_id           bigint REFERENCES ops.incident(id),
  decision              text CHECK (decision IN ('REPLACE','LEASE','INTERLINE','RESCUE','CANCEL')),
  replacement_vehicle_id bigint REFERENCES fleet.vehicle(id),
  partner_company_id    bigint REFERENCES iam.company(id),
  decision_deadline     timestamptz NOT NULL,
  decided_by            bigint REFERENCES iam.app_user(id),
  decided_at            timestamptz,
  status                text NOT NULL DEFAULT 'AWAITING_DECISION' CHECK (status IN ('AWAITING_DECISION','DECIDED','AUTO_FALLBACK','CLOSED')),
  created_at            timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE ops.trip_disruption IS 'قرار استمرارية الرحلة: بديلة، استئجار، تعاون، إنقاذ، إيقاف (7.12 ج)';
