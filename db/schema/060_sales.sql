-- =====================================================================
-- 060: القنوات والحجوزات والمسافرون والتذاكر والصعود والاسترداد
-- المرجع: 4.5، 4.12، 5.9، 7.1، 7.3، 7.4، 28 (آلات الحالة)
-- =====================================================================

CREATE TABLE sales.channel (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid           uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  code          text NOT NULL UNIQUE,                 -- WEB, APP_ANDROID, APP_IOS, COUNTER, AGENCY:<x>
  party_id      bigint REFERENCES iam.party(id),
  channel_type  text NOT NULL CHECK (channel_type IN ('DIRECT','COUNTER','AGENCY','API_PARTNER','CORPORATE','CALL_CENTER')),
  api_client_id bigint REFERENCES iam.api_client(id),
  status        text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','SUSPENDED')),
  created_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE sales.channel IS 'قناة البيع (مباشر، شباك، وكالة، شريك API)؛ الاتفاقيات والحصص في المرحلة 9';

CREATE TABLE sales.booking (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                 uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  booking_ref         text NOT NULL UNIQUE CHECK (booking_ref ~ '^[A-Z0-9]{6,8}$'),   -- رمز الحجز (PNR)
  trip_id             bigint NOT NULL REFERENCES ops.trip(id),
  company_id          bigint NOT NULL REFERENCES iam.company(id),   -- الناقل (لعزل المستأجر)
  booker_party_id     bigint NOT NULL REFERENCES iam.party(id),
  booker_user_id      bigint REFERENCES iam.app_user(id),
  channel_id          bigint NOT NULL REFERENCES sales.channel(id),
  status              text NOT NULL DEFAULT 'PENDING_PAYMENT' CHECK (status IN ('PENDING_PAYMENT','CONFIRMED','CANCELLED','COMPLETED','EXPIRED')),
  pay_method          text CHECK (pay_method IN ('WALLET','CARD','BANK','CASH','POINTS','MIXED')),
  currency            char(3) NOT NULL REFERENCES ref.currency(code),
  total_amount        bigint NOT NULL CHECK (total_amount >= 0),
  price_breakdown     jsonb NOT NULL,                 -- لقطة السعر وقت الحجز (price_snapshot)
  rules_version       text NOT NULL,
  price_allocation_id bigint,                         -- FK بعد fin.price_allocation
  idempotency_key     text NOT NULL,
  hold_expires_at     timestamptz,
  confirmed_at        timestamptz,
  cancelled_at        timestamptz,
  cancel_reason       text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (booker_party_id, idempotency_key),
  CHECK (status <> 'CONFIRMED' OR confirmed_at IS NOT NULL)
);
CREATE INDEX booking_trip_idx    ON sales.booking (trip_id, status);
CREATE INDEX booking_booker_idx  ON sales.booking (booker_party_id, created_at DESC);
CREATE INDEX booking_company_idx ON sales.booking (company_id, created_at DESC);
CREATE INDEX booking_hold_idx    ON sales.booking (hold_expires_at) WHERE status = 'PENDING_PAYMENT';
CREATE TRIGGER booking_updated BEFORE UPDATE ON sales.booking FOR EACH ROW EXECUTE FUNCTION sys.tg_set_updated_at();
COMMENT ON TABLE sales.booking IS 'الحجز: لقطة السعر، والقناة، وشجرة التوزيع، ومفتاح عدم التكرار؛ حالاته وفق القسم 28';

-- انتقالات الحالة المسموحة فقط (28: أي انتقال غير مدرج مرفوض)
CREATE OR REPLACE FUNCTION sales.tg_booking_transition() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
       (OLD.status = 'PENDING_PAYMENT' AND NEW.status IN ('CONFIRMED','EXPIRED','CANCELLED')) OR
       (OLD.status = 'CONFIRMED'       AND NEW.status IN ('CANCELLED','COMPLETED'))) THEN
    RAISE EXCEPTION 'INVALID_TRANSITION: booking % -> %', OLD.status, NEW.status USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER booking_transition BEFORE UPDATE OF status ON sales.booking FOR EACH ROW EXECUTE FUNCTION sales.tg_booking_transition();

CREATE TABLE sales.passenger (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  booking_id          bigint NOT NULL REFERENCES sales.booking(id) ON DELETE CASCADE,
  party_id            bigint REFERENCES iam.party(id),   -- إن كان للمسافر حساب
  full_name           text NOT NULL,
  passenger_category  text NOT NULL DEFAULT 'ADULT' CHECK (passenger_category IN ('ADULT','CHILD','INFANT','STUDENT','SENIOR','DISABLED')),
  id_type             text CHECK (id_type IN ('NATIONAL_ID','PASSPORT','RESIDENCE','OTHER')),
  id_no_enc           bytea,
  id_no_bidx          bytea,
  id_no_last4         text,
  passport_no_enc     bytea,                          -- جاهزية الدولي (القرار 88)
  passport_no_bidx    bytea,
  passport_country    char(2) REFERENCES ref.country(code),
  passport_expiry     date,
  enc_key_id          int REFERENCES sec.key_registry(id),
  nationality         char(2) REFERENCES ref.country(code),
  birth_date          date,
  gender              text CHECK (gender IN ('M','F')),
  mobile              text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  CHECK ((id_no_enc IS NULL AND passport_no_enc IS NULL) OR enc_key_id IS NOT NULL)
);
CREATE INDEX passenger_booking_idx ON sales.passenger (booking_id);
CREATE INDEX passenger_id_bidx ON sales.passenger (id_no_bidx) WHERE id_no_bidx IS NOT NULL;
COMMENT ON TABLE sales.passenger IS 'بيانات المسافر في الحجز؛ أرقام الوثائق مشفرة بفهرس أعمى للفحص الأمني والمنافست';

CREATE TABLE sales.ticket (
  id                        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                       uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  ticket_no                 text NOT NULL UNIQUE,
  booking_id                bigint NOT NULL REFERENCES sales.booking(id),
  passenger_id              bigint NOT NULL REFERENCES sales.passenger(id),
  trip_id                   bigint NOT NULL REFERENCES ops.trip(id),
  from_seq                  smallint NOT NULL,
  to_seq                    smallint NOT NULL,
  seat_no                   smallint,                 -- فارغ في الوضع المقفل أو للوقوف
  is_standing               boolean NOT NULL DEFAULT false,
  assigned_seat_at_boarding smallint,
  cabin                     text NOT NULL DEFAULT 'ECONOMY',
  fare_brand_code           text REFERENCES pricing.fare_brand(code),
  fare_amount               bigint NOT NULL CHECK (fare_amount >= 0),
  seat_surcharge            bigint NOT NULL DEFAULT 0,
  baggage_pieces            smallint NOT NULL DEFAULT 0,
  baggage_fee               bigint NOT NULL DEFAULT 0 CHECK (baggage_fee >= 0),
  total_amount              bigint NOT NULL CHECK (total_amount >= 0),
  rules_snapshot            jsonb NOT NULL,           -- شروط الاسترداد والتعديل والأمتعة وقت الإصدار
  qr_key_id                 int REFERENCES sec.key_registry(id),
  qr_serial                 int NOT NULL DEFAULT 0,   -- يتجدد مع QR المتجدد (16.18)
  status                    text NOT NULL DEFAULT 'ISSUED' CHECK (status IN ('ISSUED','BOARDED','NO_SHOW','CANCELLED','HOLD')),
  boarded_at                timestamptz,
  created_at                timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (trip_id, from_seq) REFERENCES ops.trip_stop(trip_id, seq),
  FOREIGN KEY (trip_id, to_seq)   REFERENCES ops.trip_stop(trip_id, seq),
  CHECK (to_seq > from_seq),
  CHECK (NOT (is_standing AND seat_no IS NOT NULL))
);
CREATE INDEX ticket_trip_idx ON sales.ticket (trip_id, status);
CREATE INDEX ticket_booking_idx ON sales.ticket (booking_id);
COMMENT ON TABLE sales.ticket IS 'التذكرة لكل مسافر وزوج محطات، بمقعد مرقَّم أو مضمون أو وقوف، ولقطة الشروط وQR موقّع';

CREATE OR REPLACE FUNCTION sales.tg_ticket_transition() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
       (OLD.status = 'ISSUED' AND NEW.status IN ('BOARDED','NO_SHOW','HOLD','CANCELLED')) OR
       (OLD.status = 'HOLD'   AND NEW.status IN ('ISSUED','CANCELLED'))) THEN
    RAISE EXCEPTION 'INVALID_TRANSITION: ticket % -> %', OLD.status, NEW.status USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER ticket_transition BEFORE UPDATE OF status ON sales.ticket FOR EACH ROW EXECUTE FUNCTION sales.tg_ticket_transition();

ALTER TABLE ops.seat_segment ADD CONSTRAINT seat_segment_ticket_fk FOREIGN KEY (ticket_id) REFERENCES sales.ticket(id);
ALTER TABLE pricing.points_ledger ADD CONSTRAINT points_ledger_booking_fk FOREIGN KEY (booking_id) REFERENCES sales.booking(id);

CREATE TABLE sales.boarding_event (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ticket_id         bigint NOT NULL REFERENCES sales.ticket(id),
  trip_id           bigint NOT NULL REFERENCES ops.trip(id),
  stop_seq          smallint NOT NULL,
  event_type        text NOT NULL CHECK (event_type IN ('BOARD','ALIGHT','NO_SHOW','DENIED')),
  method            text NOT NULL DEFAULT 'AGENT_SCAN' CHECK (method IN ('AGENT_SCAN','SELF_SCAN','VALIDATOR_QR','VALIDATOR_NFC','MANUAL')),
  result            text NOT NULL DEFAULT 'OK' CHECK (result IN ('OK','DUPLICATE','INVALID_QR','WRONG_TRIP','DOCS_REQUIRED')),
  scanned_by_user_id bigint REFERENCES iam.app_user(id),
  device_id         bigint REFERENCES iam.device(id),
  lat               numeric(9,6),
  lng               numeric(9,6),
  ts                timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX boarding_trip_idx ON sales.boarding_event (trip_id, ts);
CREATE TRIGGER boarding_event_immutable BEFORE UPDATE OR DELETE ON sales.boarding_event
  FOR EACH ROW EXECUTE FUNCTION sys.tg_forbid_mutation();
COMMENT ON TABLE sales.boarding_event IS 'أحداث الصعود والنزول بالمسح (أساس التفويج والتسوية والمنافست)؛ إلحاق فقط';

CREATE TABLE sales.refund_request (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  booking_id        bigint NOT NULL REFERENCES sales.booking(id),
  ticket_id         bigint REFERENCES sales.ticket(id),
  reason            text NOT NULL CHECK (reason IN ('CUSTOMER','TRIP_CANCELLED','DELAY_OVER_LIMIT','DISRUPTION','DUPLICATE','OTHER')),
  amount_requested  bigint NOT NULL CHECK (amount_requested >= 0),
  amount_approved   bigint CHECK (amount_approved >= 0),
  policy_snapshot   jsonb NOT NULL,
  status            text NOT NULL DEFAULT 'REQUESTED' CHECK (status IN ('REQUESTED','APPROVED','REJECTED','PAID')),
  requested_by      bigint REFERENCES iam.app_user(id),
  decided_by        bigint REFERENCES iam.app_user(id),
  credit_note_id    bigint,                           -- FK بعد acct.einvoice_document
  created_at        timestamptz NOT NULL DEFAULT now(),
  decided_at        timestamptz,
  CHECK (amount_approved IS NULL OR amount_approved <= amount_requested)
);
COMMENT ON TABLE sales.refund_request IS 'طلب الاسترداد بلقطة السياسة؛ لا يُحرَّر المبلغ قبل إقفال الإشعار الدائن (BR-EIN-03)';

CREATE TABLE sales.campaign_redemption (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  campaign_id     bigint NOT NULL REFERENCES pricing.campaign(id),
  promo_code_id   bigint REFERENCES pricing.promo_code(id),
  booking_id      bigint NOT NULL REFERENCES sales.booking(id),
  party_id        bigint NOT NULL REFERENCES iam.party(id),
  discount_amount bigint NOT NULL CHECK (discount_amount >= 0),
  sponsor_amount  bigint NOT NULL DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (campaign_id, booking_id)
);
COMMENT ON TABLE sales.campaign_redemption IS 'استخدام الحملة في حجز ومن يموّل الخصم';

CREATE TABLE sales.passenger_compensation (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  booking_id          bigint NOT NULL REFERENCES sales.booking(id),
  trip_disruption_id  bigint REFERENCES ops.trip_disruption(id),
  type                text NOT NULL CHECK (type IN ('REFUND','CREDIT','POINTS')),
  amount              bigint NOT NULL CHECK (amount >= 0),
  charged_to_company_id bigint REFERENCES iam.company(id),
  credit_note_id      bigint,                         -- FK بعد acct.einvoice_document
  status              text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','APPROVED','PAID','REJECTED')),
  created_at          timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE sales.passenger_compensation IS 'تعويض المسافرين عن الإلغاء أو التعطل، ويُحمَّل على الناقل المتسبب';
