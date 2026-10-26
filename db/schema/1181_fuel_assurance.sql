-- 1181: fuel stations, the fill made hard to cheat (owner's note of 26 October 2026; docs/design/FUEL_STATIONS.md).
--
-- The vehicle is present: the platform registers every NFC tag it hands to carriers (ptn.fuel_tag) and the carrier binds
-- a tag to its vehicle through the platform before sticking it on; a secure tag (NTAG 424 DNA) signs each tap with a
-- counter that only goes up, so a copied tag or a replayed tap is refused. The pump is real: each pump carries a signed
-- QR sticker beside its meter, asked for when the fill's risk is high or at random. Each identification opens a
-- challenge that the fill must answer within minutes: it names what the fill must show (the pump's QR, the odometer's
-- photo) from a risk score the system works out (how the vehicle was identified, a recent fill, open anomalies, the
-- attendant's record, a station without a pump controller, a random sample). The meter's photo is taken live (the app
-- offers no gallery; the server refuses a file carrying a camera's metadata) and compared with recent photos: the same
-- picture again opens PHOTO_REUSED. When the station's pump controller reports its deliveries, each fill is matched
-- with the pump's own figures; a fill the pump did not deliver, or delivered differently, is held.
--
-- The service is sold: a carrier subscribes for its vehicles by the week, month, quarter or year and pays the platform
-- in advance; a vehicle fills only while a paid subscription covers it. The platform's commission is agreed at the
-- subscription (on the carrier's fills) and with each fuel company (on its stations' fills); each fill records both as
-- due, a fill given back voids them. Fuel money itself stays with the fuel company (1180).
--
-- A card's allowance has an end date, renews with its period (day, week, month, quarter, year), and its owner may pause it.

-- ------------------------------------------------------------------ 1. settings
UPDATE sys.setting
   SET value = '{"identify_methods": ["NFC", "APP", "CARD_NO"], "registered_tags_only": true, "pump_qr": "RISK",
                 "odometer_photo": "RISK", "risk_pump_qr": 30, "risk_odometer_photo": 50, "sample_pct": 10, "refill_hours": 3,
                 "challenge_minutes": 15, "photo_dup_days": 30, "photo_dup_bits": 6, "pump_window_minutes": 15,
                 "pump_litres_tolerance_pct": 0.5}'::jsonb || value,
       description = description || '; identify_methods are the ways a vehicle may be identified; registered_tags_only accepts only tags the platform issued; pump_qr and odometer_photo are OFF, RISK (asked from risk_pump_qr / risk_odometer_photo points or a sample_pct random sample) or ALWAYS; refill_hours marks a fill soon after another as risky; challenge_minutes is how long an identification stays open; a photo within photo_dup_bits of one from the last photo_dup_days is reused; pump_window_minutes and pump_litres_tolerance_pct match a fill with the pump controller''s delivery (1181)',
       updated_at = now()
 WHERE key = 'fuel.checks' AND NOT value ? 'pump_qr';
INSERT INTO sys.setting (key, value, description) VALUES
  ('fuel.subscription', '{"required": true, "prices": {"WEEK": null, "MONTH": null, "QUARTER": null, "YEAR": null},
                          "carrier_commission_pct": 0}'::jsonb,
   'The fuel service sold to carriers (1181): required makes a vehicle fill only under a paid subscription; prices are per vehicle and period in minor units (null: the platform prices each request); carrier_commission_pct is the default commission on the carrier''s fills')
ON CONFLICT (key) DO NOTHING;

-- ------------------------------------------------------------------ 2. NFC tags issued by the platform
CREATE TABLE IF NOT EXISTS ptn.fuel_tag (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid            uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  tag_hash       bytea NOT NULL UNIQUE CHECK (length(tag_hash) = 32),
  kind           text NOT NULL CHECK (kind IN ('PLAIN', 'SECURE')),
  label          text NOT NULL CHECK (label ~ '^[A-Z0-9-]{4,20}$'),
  batch          text CHECK (batch IS NULL OR length(btrim(batch)) BETWEEN 1 AND 60),
  status         text NOT NULL DEFAULT 'STOCK' CHECK (status IN ('STOCK', 'ISSUED', 'LOST', 'RETIRED')),
  issued_to      bigint REFERENCES iam.company(id),
  issued_at      timestamptz,
  issued_by      bigint REFERENCES iam.app_user(id),
  sun_counter    integer CHECK (sun_counter IS NULL OR sun_counter >= 0),
  last_seen_at   timestamptz,
  registered_by  bigint REFERENCES iam.app_user(id),
  created_at     timestamptz NOT NULL DEFAULT now(),
  CHECK ((status = 'STOCK') = (issued_to IS NULL) OR status IN ('LOST', 'RETIRED'))
);
CREATE INDEX IF NOT EXISTS fuel_tag_issued_to_fkx ON ptn.fuel_tag (issued_to);
CREATE INDEX IF NOT EXISTS fuel_tag_issued_by_fkx ON ptn.fuel_tag (issued_by);
CREATE INDEX IF NOT EXISTS fuel_tag_registered_by_fkx ON ptn.fuel_tag (registered_by);
COMMENT ON TABLE ptn.fuel_tag IS 'The NFC tags the platform registers and hands to carriers for their vehicles; only the hash of the tag''s serial is kept (1181)';
COMMENT ON COLUMN ptn.fuel_tag.kind IS 'PLAIN: the tag''s serial only; SECURE: an NTAG 424 DNA that signs each tap with a rising counter (SUN), which a copy cannot do';
COMMENT ON COLUMN ptn.fuel_tag.label IS 'The short number printed on the tag, to find it in the platform''s lists';
COMMENT ON COLUMN ptn.fuel_tag.sun_counter IS 'The last counter a secure tag signed: a tap with a counter not above it is a replay';

ALTER TABLE ptn.fuel_card_tag ADD COLUMN IF NOT EXISTS tag_id bigint REFERENCES ptn.fuel_tag(id);
CREATE INDEX IF NOT EXISTS fuel_card_tag_tag_id_fkx ON ptn.fuel_card_tag (tag_id);
COMMENT ON COLUMN ptn.fuel_card_tag.tag_id IS 'The registered tag bound to the card by the card''s company (1181)';

-- ------------------------------------------------------------------ 3. pumps and their signed QR stickers
CREATE TABLE IF NOT EXISTS ptn.fuel_pump (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid          uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  partner_id   bigint NOT NULL REFERENCES ptn.partner(id),
  pump_no      smallint NOT NULL CHECK (pump_no BETWEEN 1 AND 99),
  qr_version   smallint NOT NULL DEFAULT 1 CHECK (qr_version BETWEEN 1 AND 32000),
  status       text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'RETIRED')),
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (partner_id, pump_no)
);
COMMENT ON TABLE ptn.fuel_pump IS 'The pumps of a fuel station; each carries a signed QR sticker beside its meter (1181)';
COMMENT ON COLUMN ptn.fuel_pump.qr_version IS 'Raised when a sticker is replaced: the older sticker''s code stops working';

ALTER TABLE ptn.partner ADD COLUMN IF NOT EXISTS controller_key_hash bytea CHECK (controller_key_hash IS NULL OR length(controller_key_hash) = 32);
ALTER TABLE ptn.partner ADD COLUMN IF NOT EXISTS controller_since timestamptz;
CREATE UNIQUE INDEX IF NOT EXISTS partner_controller_key_ux ON ptn.partner (controller_key_hash) WHERE controller_key_hash IS NOT NULL;
COMMENT ON COLUMN ptn.partner.controller_key_hash IS 'The hash of the key the station''s pump controller reports its deliveries with (1181)';

-- a station's pumps follow its number of pumps
CREATE OR REPLACE FUNCTION ptn.tg_fuel_pumps() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.partner_type = 'FUEL' AND NEW.pumps IS NOT NULL THEN
    INSERT INTO ptn.fuel_pump (partner_id, pump_no) SELECT NEW.id, n FROM generate_series(1, NEW.pumps) n
    ON CONFLICT (partner_id, pump_no) DO UPDATE SET status = 'ACTIVE';
    UPDATE ptn.fuel_pump SET status = 'RETIRED' WHERE partner_id = NEW.id AND pump_no > NEW.pumps AND status = 'ACTIVE';
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS fuel_pumps ON ptn.partner;
CREATE TRIGGER fuel_pumps AFTER INSERT OR UPDATE OF pumps ON ptn.partner FOR EACH ROW EXECUTE FUNCTION ptn.tg_fuel_pumps();
INSERT INTO ptn.fuel_pump (partner_id, pump_no)
SELECT p.id, n FROM ptn.partner p CROSS JOIN LATERAL generate_series(1, p.pumps) n
 WHERE p.partner_type = 'FUEL' AND p.pumps IS NOT NULL
ON CONFLICT (partner_id, pump_no) DO NOTHING;

-- what the pump controller reported it delivered
CREATE TABLE IF NOT EXISTS ptn.fuel_pump_txn (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  partner_id      bigint NOT NULL REFERENCES ptn.partner(id),
  pump_id         bigint NOT NULL REFERENCES ptn.fuel_pump(id),
  controller_ref  text NOT NULL CHECK (length(btrim(controller_ref)) BETWEEN 1 AND 80),
  fuel_type       text NOT NULL,
  litres          numeric(8,2) NOT NULL CHECK (litres > 0),
  amount          bigint CHECK (amount IS NULL OR amount > 0),
  totalizer       numeric(14,2),
  ended_at        timestamptz NOT NULL,
  received_at     timestamptz NOT NULL DEFAULT now(),
  sale_id         bigint UNIQUE REFERENCES ptn.partner_sale(id),
  UNIQUE (partner_id, controller_ref)
);
CREATE INDEX IF NOT EXISTS fuel_pump_txn_open_ix ON ptn.fuel_pump_txn (pump_id, ended_at) WHERE sale_id IS NULL;
COMMENT ON TABLE ptn.fuel_pump_txn IS 'Each delivery the station''s pump controller reported: pump, litres, amount, totalizer; matched with the attendant''s fill (1181)';

-- ------------------------------------------------------------------ 4. a card's allowance: end date, longer periods, pause
ALTER TABLE ptn.fuel_card ADD COLUMN IF NOT EXISTS valid_until date;
ALTER TABLE ptn.fuel_card ADD COLUMN IF NOT EXISTS paused_reason text CHECK (paused_reason IS NULL OR length(btrim(paused_reason)) BETWEEN 3 AND 200);
COMMENT ON COLUMN ptn.fuel_card.valid_until IS 'The last day the allowance may be used; after it the card fills no more until renewed (1181)';
COMMENT ON COLUMN ptn.fuel_card.paused_reason IS 'Why the vehicle''s owner paused the card (1181)';
ALTER TABLE ptn.fuel_card DROP CONSTRAINT IF EXISTS fuel_card_status_check;
ALTER TABLE ptn.fuel_card ADD CONSTRAINT fuel_card_status_check CHECK (status IN ('ACTIVE', 'PAUSED', 'BLOCKED', 'RETIRED'));
ALTER TABLE ptn.fuel_card DROP CONSTRAINT IF EXISTS fuel_card_budget_ck;
ALTER TABLE ptn.fuel_card ADD CONSTRAINT fuel_card_budget_ck CHECK (
      card_no ~ '^[A-Z0-9]{8,12}$'
  AND (budget_period IS NULL OR budget_period IN ('DAY', 'WEEK', 'MONTH', 'QUARTER', 'YEAR'))
  AND (budget_amount IS NULL OR budget_amount > 0) AND (budget_litres IS NULL OR budget_litres > 0)
  AND ((budget_period IS NULL) = (budget_amount IS NULL AND budget_litres IS NULL))
  AND (blocked_reason IS NULL OR length(btrim(blocked_reason)) BETWEEN 3 AND 200)
  AND ((status = 'PAUSED') = (paused_reason IS NOT NULL)));
-- a paused card still holds its vehicle
DROP INDEX IF EXISTS ptn.fuel_card_vehicle_active_ux;
CREATE UNIQUE INDEX IF NOT EXISTS fuel_card_vehicle_active_ux ON ptn.fuel_card (vehicle_id)
  WHERE status IN ('ACTIVE', 'PAUSED') AND vehicle_id IS NOT NULL;
COMMENT ON COLUMN ptn.fuel_card.budget_period IS 'DAY, WEEK, MONTH, QUARTER or YEAR: the period the allowance renews with, counted in the holder''s time zone (1180, 1181)';

-- ------------------------------------------------------------------ 5. the challenge of an identification
CREATE TABLE IF NOT EXISTS ptn.fuel_challenge (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                  uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  partner_id           bigint NOT NULL REFERENCES ptn.partner(id),
  card_id              bigint NOT NULL REFERENCES ptn.fuel_card(id),
  user_id              bigint NOT NULL REFERENCES iam.app_user(id),
  identified_by        text NOT NULL CHECK (identified_by IN ('NFC', 'APP', 'CARD_NO')),
  tag_kind             text CHECK (tag_kind IN ('PLAIN', 'SECURE')),
  risk                 smallint NOT NULL CHECK (risk >= 0),
  factors              jsonb NOT NULL DEFAULT '{}'::jsonb,
  sampled              boolean NOT NULL DEFAULT false,
  need_pump_qr         boolean NOT NULL,
  need_odometer_photo  boolean NOT NULL,
  created_at           timestamptz NOT NULL DEFAULT now(),
  expires_at           timestamptz NOT NULL,
  used_at              timestamptz
);
CREATE INDEX IF NOT EXISTS fuel_challenge_partner_id_fkx ON ptn.fuel_challenge (partner_id);
CREATE INDEX IF NOT EXISTS fuel_challenge_card_id_fkx ON ptn.fuel_challenge (card_id);
CREATE INDEX IF NOT EXISTS fuel_challenge_user_id_fkx ON ptn.fuel_challenge (user_id);
COMMENT ON TABLE ptn.fuel_challenge IS 'What one identification at the pump asks of the fill that follows: the pump''s QR, the odometer''s photo, from the risk worked out; used once, within minutes (1181)';
COMMENT ON COLUMN ptn.fuel_challenge.factors IS 'The risk points by reason: {typed_card_no, app_code, plain_tag, recent_fill, vehicle_anomalies, attendant_record, no_pump_controller} (1181)';
INSERT INTO sys.json_contract (table_name, column_name, kind, version, spec, note) VALUES
  ('ptn.fuel_challenge', 'factors', 'SHAPE', 1, '{"type": "object", "additionalProperties": {"type": "integer"}}'::jsonb,
   'the risk points of an identification at the pump, by reason (1181)')
ON CONFLICT DO NOTHING;
SELECT sys.apply_json_contracts();

-- ------------------------------------------------------------------ 6. the fill: what the challenge asked, the pump, the photos
ALTER TABLE ptn.partner_sale ADD COLUMN IF NOT EXISTS challenge_id bigint REFERENCES ptn.fuel_challenge(id);
ALTER TABLE ptn.partner_sale ADD COLUMN IF NOT EXISTS pump_id bigint REFERENCES ptn.fuel_pump(id);
ALTER TABLE ptn.partner_sale ADD COLUMN IF NOT EXISTS pump_by_qr boolean;
ALTER TABLE ptn.partner_sale ADD COLUMN IF NOT EXISTS odometer_photo_file_id bigint REFERENCES ref.file_object(id);
ALTER TABLE ptn.partner_sale ADD COLUMN IF NOT EXISTS photo_dhash bigint;
ALTER TABLE ptn.partner_sale ADD COLUMN IF NOT EXISTS risk smallint;
CREATE UNIQUE INDEX IF NOT EXISTS partner_sale_challenge_ux ON ptn.partner_sale (challenge_id) WHERE challenge_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS partner_sale_pump_id_fkx ON ptn.partner_sale (pump_id);
CREATE INDEX IF NOT EXISTS partner_sale_odometer_photo_file_id_fkx ON ptn.partner_sale (odometer_photo_file_id);
CREATE INDEX IF NOT EXISTS partner_sale_photo_ix ON ptn.partner_sale (partner_id, created_at) WHERE photo_dhash IS NOT NULL;
COMMENT ON COLUMN ptn.partner_sale.challenge_id IS 'The identification the fill answered (1181)';
COMMENT ON COLUMN ptn.partner_sale.pump_by_qr IS 'The pump was read from its signed QR sticker, not picked from a list (1181)';
COMMENT ON COLUMN ptn.partner_sale.odometer_photo_file_id IS 'The photo of the vehicle''s odometer, for its owner to check the figure entered (1181)';
COMMENT ON COLUMN ptn.partner_sale.photo_dhash IS 'A 64-bit difference hash of the meter''s photo: a near match with an earlier photo is a reused picture (1181)';
COMMENT ON COLUMN ptn.partner_sale.risk IS 'The risk points of the identification the fill answered (1181)';

CREATE OR REPLACE FUNCTION ptn.tg_partner_sale_fixed() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.method = 'PREPAID' THEN
      RAISE EXCEPTION 'FUEL_SALE_KEPT: a fill is never deleted' USING ERRCODE = 'P0001';
    END IF;
    RETURN OLD;
  END IF;
  IF OLD.method = 'PREPAID'
     AND (NEW.partner_id, NEW.card_id, NEW.vehicle_id, NEW.company_id, NEW.fuel_type, NEW.qty, NEW.unit_price, NEW.amount,
          NEW.expected_amount, NEW.meter_photo_file_id, NEW.odometer_km, NEW.created_at, NEW.method, NEW.challenge_id,
          NEW.pump_id, NEW.pump_by_qr, NEW.odometer_photo_file_id, NEW.photo_dhash, NEW.risk)
         IS DISTINCT FROM
         (OLD.partner_id, OLD.card_id, OLD.vehicle_id, OLD.company_id, OLD.fuel_type, OLD.qty, OLD.unit_price, OLD.amount,
          OLD.expected_amount, OLD.meter_photo_file_id, OLD.odometer_km, OLD.created_at, OLD.method, OLD.challenge_id,
          OLD.pump_id, OLD.pump_by_qr, OLD.odometer_photo_file_id, OLD.photo_dhash, OLD.risk) THEN
    RAISE EXCEPTION 'FUEL_SALE_FIXED: what the pump measured is never changed' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;

ALTER TABLE ptn.fuel_anomaly DROP CONSTRAINT IF EXISTS fuel_anomaly_anomaly_type_check;
ALTER TABLE ptn.fuel_anomaly ADD CONSTRAINT fuel_anomaly_anomaly_type_check
  CHECK (anomaly_type IN ('OVER_TANK', 'DISTANCE_MISMATCH', 'CONSUMPTION_HIGH', 'ODOMETER_BACKWARD', 'LOCATION_MISMATCH',
                          'AMOUNT_MISMATCH', 'PHOTO_REUSED', 'PUMP_MISMATCH', 'PUMP_UNCONFIRMED', 'OWNER_QUERY', 'OTHER'));

-- ------------------------------------------------------------------ 7. the service sold: subscriptions and commissions
CREATE TABLE IF NOT EXISTS ptn.fuel_subscription (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid                uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  company_id         bigint NOT NULL REFERENCES iam.company(id),
  period             text NOT NULL CHECK (period IN ('WEEK', 'MONTH', 'QUARTER', 'YEAR')),
  vehicles           integer NOT NULL CHECK (vehicles BETWEEN 1 AND 100000),
  price_per_vehicle  bigint CHECK (price_per_vehicle IS NULL OR price_per_vehicle >= 0),
  amount             bigint CHECK (amount IS NULL OR amount >= 0),
  currency           char(3) NOT NULL REFERENCES ref.currency(code),
  commission_pct     numeric(5,2) CHECK (commission_pct IS NULL OR commission_pct BETWEEN 0 AND 100),
  starts_on          date NOT NULL,
  ends_on            date NOT NULL,
  status             text NOT NULL DEFAULT 'REQUESTED' CHECK (status IN ('REQUESTED', 'ACTIVE', 'ENDED', 'CANCELLED')),
  requested_by       bigint REFERENCES iam.app_user(id),
  requested_at       timestamptz NOT NULL DEFAULT now(),
  paid_reference     text CHECK (paid_reference IS NULL OR length(btrim(paid_reference)) BETWEEN 1 AND 80),
  paid_at            timestamptz,
  confirmed_by       bigint REFERENCES iam.app_user(id),
  note               text CHECK (note IS NULL OR length(btrim(note)) BETWEEN 3 AND 300),
  CHECK (ends_on >= starts_on),
  CHECK (status <> 'ACTIVE' OR (paid_at IS NOT NULL AND paid_reference IS NOT NULL AND price_per_vehicle IS NOT NULL
                                AND amount = price_per_vehicle * vehicles AND commission_pct IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS fuel_subscription_company_ix ON ptn.fuel_subscription (company_id, ends_on);
CREATE INDEX IF NOT EXISTS fuel_subscription_currency_fkx ON ptn.fuel_subscription (currency);
CREATE INDEX IF NOT EXISTS fuel_subscription_requested_by_fkx ON ptn.fuel_subscription (requested_by);
CREATE INDEX IF NOT EXISTS fuel_subscription_confirmed_by_fkx ON ptn.fuel_subscription (confirmed_by);
COMMENT ON TABLE ptn.fuel_subscription IS 'A carrier''s subscription to the fuel service for its vehicles, paid to the platform in advance; the platform''s commission on its fills is agreed here (1181)';

CREATE TABLE IF NOT EXISTS ptn.fuel_subscription_vehicle (
  subscription_id  bigint NOT NULL REFERENCES ptn.fuel_subscription(id),
  vehicle_id       bigint NOT NULL REFERENCES fleet.vehicle(id),
  PRIMARY KEY (subscription_id, vehicle_id)
);
CREATE INDEX IF NOT EXISTS fuel_subscription_vehicle_vehicle_id_fkx ON ptn.fuel_subscription_vehicle (vehicle_id);
COMMENT ON TABLE ptn.fuel_subscription_vehicle IS 'The vehicles a fuel subscription covers (1181)';

CREATE TABLE IF NOT EXISTS ptn.fuel_company_terms (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  fuel_company_id  bigint NOT NULL REFERENCES iam.company(id),
  commission_pct   numeric(5,2) NOT NULL CHECK (commission_pct BETWEEN 0 AND 100),
  valid_from       date NOT NULL,
  note             text CHECK (note IS NULL OR length(btrim(note)) BETWEEN 3 AND 300),
  set_by           bigint REFERENCES iam.app_user(id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (fuel_company_id, valid_from)
);
CREATE INDEX IF NOT EXISTS fuel_company_terms_set_by_fkx ON ptn.fuel_company_terms (set_by);
COMMENT ON TABLE ptn.fuel_company_terms IS 'The platform''s commission on a fuel company''s fills, agreed in its contract, from a date (1181)';

CREATE TABLE IF NOT EXISTS ptn.fuel_commission (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sale_id      bigint NOT NULL REFERENCES ptn.partner_sale(id),
  side         text NOT NULL CHECK (side IN ('CARRIER', 'FUEL_COMPANY')),
  company_id   bigint NOT NULL REFERENCES iam.company(id),
  pct          numeric(5,2) NOT NULL CHECK (pct > 0 AND pct <= 100),
  amount       bigint NOT NULL CHECK (amount >= 0),
  currency     char(3) NOT NULL REFERENCES ref.currency(code),
  status       text NOT NULL DEFAULT 'DUE' CHECK (status IN ('DUE', 'VOID')),
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (sale_id, side)
);
CREATE INDEX IF NOT EXISTS fuel_commission_company_ix ON ptn.fuel_commission (company_id, created_at);
CREATE INDEX IF NOT EXISTS fuel_commission_currency_fkx ON ptn.fuel_commission (currency);
COMMENT ON TABLE ptn.fuel_commission IS 'The platform''s commission due on a fill, from the carrier (its subscription) and from the fuel company (its terms); void when the fill is given back (1181)';

-- ------------------------------------------------------------------ 8. isolation and privileges
SELECT sys.rls_split('ptn.fuel_tag', 'sys.ctx_is_platform() OR sys.tenant_visible(issued_to)', 'sys.ctx_is_platform()');
SELECT sys.rls_split('ptn.fuel_pump', 'sys.ctx_is_platform() OR EXISTS (SELECT 1 FROM ptn.partner p WHERE p.id = fuel_pump.partner_id AND sys.tenant_visible(p.company_id))', 'sys.ctx_is_platform()');
SELECT sys.rls_split('ptn.fuel_pump_txn', 'sys.ctx_is_platform() OR EXISTS (SELECT 1 FROM ptn.partner p WHERE p.id = fuel_pump_txn.partner_id AND sys.tenant_visible(p.company_id))', 'sys.ctx_is_platform()');
SELECT sys.rls_split('ptn.fuel_challenge', 'sys.ctx_is_platform() OR EXISTS (SELECT 1 FROM ptn.partner p WHERE p.id = fuel_challenge.partner_id AND sys.tenant_visible(p.company_id))', 'sys.ctx_is_platform()');
SELECT sys.rls_split('ptn.fuel_subscription', 'sys.ctx_is_platform() OR sys.tenant_visible(company_id)', 'sys.ctx_is_platform()');
SELECT sys.rls_split('ptn.fuel_subscription_vehicle', 'EXISTS (SELECT 1 FROM ptn.fuel_subscription s WHERE s.id = fuel_subscription_vehicle.subscription_id)', 'sys.ctx_is_platform()');
SELECT sys.rls_split('ptn.fuel_company_terms', 'sys.ctx_is_platform() OR sys.tenant_visible(fuel_company_id)', 'sys.ctx_is_platform()');
SELECT sys.rls_split('ptn.fuel_commission', 'sys.ctx_is_platform() OR sys.tenant_visible(company_id)', 'sys.ctx_is_platform()');
GRANT SELECT ON ptn.fuel_tag, ptn.fuel_pump, ptn.fuel_pump_txn, ptn.fuel_challenge, ptn.fuel_subscription,
                ptn.fuel_subscription_vehicle, ptn.fuel_company_terms, ptn.fuel_commission TO masslak_app, masslak_readonly;
-- the platform registers and issues tags and sets the fuel companies' terms directly; everything else moves by the functions
GRANT INSERT, UPDATE ON ptn.fuel_tag TO masslak_app;
GRANT INSERT ON ptn.fuel_company_terms TO masslak_app;
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['ptn.fuel_tag', 'ptn.fuel_pump', 'ptn.fuel_pump_txn', 'ptn.fuel_challenge', 'ptn.fuel_subscription',
                           'ptn.fuel_subscription_vehicle', 'ptn.fuel_company_terms', 'ptn.fuel_commission'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS module_gate ON %s', t);
    EXECUTE format('CREATE POLICY module_gate ON %s AS RESTRICTIVE FOR ALL USING (sys.ctx_is_platform() OR sys.feature_on(%L)) '
                   || 'WITH CHECK (sys.ctx_is_platform() OR sys.feature_on(%L))', t, '{service_partners}', '{service_partners}');
  END LOOP;
END $$;
DROP TRIGGER IF EXISTS zz_audit_capture ON ptn.fuel_tag;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR DELETE OR UPDATE OF status, issued_to ON ptn.fuel_tag
  FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();     -- each tap's counter is not an audit event
DROP TRIGGER IF EXISTS zz_audit_capture ON ptn.fuel_subscription;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR UPDATE OR DELETE ON ptn.fuel_subscription FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();
DROP TRIGGER IF EXISTS zz_audit_capture ON ptn.fuel_company_terms;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR UPDATE OR DELETE ON ptn.fuel_company_terms FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();
DROP TRIGGER IF EXISTS zz_audit_capture ON ptn.fuel_pump;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR UPDATE OR DELETE ON ptn.fuel_pump FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();

-- ------------------------------------------------------------------ 9. the functions
DROP FUNCTION IF EXISTS ptn.fuel_identify(uuid, bytea, text, uuid);
DROP FUNCTION IF EXISTS ptn.fuel_bind_tag(uuid, uuid, bytea);
DROP FUNCTION IF EXISTS ptn.fuel_fill(uuid, uuid, text, text, numeric, bigint, bigint, integer, text);

CREATE OR REPLACE FUNCTION ptn.budget_start(p_period text, p_company bigint) RETURNS timestamptz
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT CASE WHEN p_period IS NULL THEN NULL
              ELSE date_trunc(lower(p_period), now() AT TIME ZONE coalesce(ref.company_tz(p_company), 'UTC'))
                   AT TIME ZONE coalesce(ref.company_tz(p_company), 'UTC') END
$$;

-- the holder's date today
CREATE OR REPLACE FUNCTION ptn.company_today(p_company bigint) RETURNS date
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT (now() AT TIME ZONE coalesce(ref.company_tz(p_company), 'UTC'))::date
$$;

-- the paid subscription covering a vehicle today, if any
CREATE OR REPLACE FUNCTION ptn.fuel_cover(p_vehicle_id bigint, p_company bigint) RETURNS ptn.fuel_subscription
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT s.* FROM ptn.fuel_subscription s JOIN ptn.fuel_subscription_vehicle sv ON sv.subscription_id = s.id
   WHERE sv.vehicle_id = p_vehicle_id AND s.company_id = p_company AND s.status = 'ACTIVE'
     AND ptn.company_today(p_company) BETWEEN s.starts_on AND s.ends_on
   ORDER BY s.ends_on DESC LIMIT 1
$$;

-- what a card can still take now: the allowance left and when it renews, the balance, fuel types, prices, and why not
CREATE OR REPLACE FUNCTION ptn.card_state(p_card_id bigint, p_partner_id bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE c ptn.fuel_card%ROWTYPE; a ptn.fuel_account%ROWTYPE; p ptn.partner%ROWTYPE; v record; sub ptn.fuel_subscription%ROWTYPE;
        v_from timestamptz; v_used_amount bigint := 0; v_used_litres numeric := 0; v_reason text; v_required boolean;
BEGIN
  SELECT * INTO c FROM ptn.fuel_card WHERE id = p_card_id;
  SELECT * INTO p FROM ptn.partner WHERE id = p_partner_id;
  SELECT * INTO a FROM ptn.fuel_account WHERE id = c.account_id;
  SELECT vh.plate_no, vh.fuel_type, vh.status, coalesce(fp.tank_capacity_l, vh.fuel_tank_l) AS tank INTO v
    FROM fleet.vehicle vh LEFT JOIN fleet.vehicle_fuel_profile fp ON fp.vehicle_id = vh.id WHERE vh.id = c.vehicle_id;
  v_required := coalesce((SELECT (value ->> 'required')::boolean FROM sys.setting WHERE key = 'fuel.subscription'), true);
  sub := ptn.fuel_cover(c.vehicle_id, c.company_id);
  v_from := ptn.budget_start(c.budget_period, c.company_id);
  IF v_from IS NOT NULL THEN
    SELECT coalesce(sum(s.amount), 0), coalesce(sum(s.qty), 0) INTO v_used_amount, v_used_litres
      FROM ptn.partner_sale s WHERE s.card_id = c.id AND s.status <> 'REVERSED' AND s.created_at >= v_from;
  END IF;
  v_reason := CASE WHEN c.status <> 'ACTIVE' THEN 'CARD_' || c.status
                   WHEN c.valid_until IS NOT NULL AND c.valid_until < ptn.company_today(c.company_id) THEN 'CARD_EXPIRED'
                   WHEN c.vehicle_id IS NULL THEN 'CARD_NO_VEHICLE'
                   WHEN v.status IS DISTINCT FROM 'ACTIVE' THEN 'VEHICLE_INACTIVE'
                   WHEN v_required AND sub.id IS NULL THEN 'NO_SUBSCRIPTION'
                   WHEN a.id IS NULL THEN 'NO_ACCOUNT'
                   WHEN a.fuel_company_id <> p.company_id THEN 'ACCOUNT_OTHER_COMPANY'
                   WHEN a.status <> 'ACTIVE' THEN 'ACCOUNT_CLOSED'
                   WHEN a.balance = 0 THEN 'NO_BALANCE'
                   WHEN c.budget_amount IS NOT NULL AND v_used_amount >= c.budget_amount THEN 'BUDGET_USED'
                   WHEN c.budget_litres IS NOT NULL AND v_used_litres >= c.budget_litres THEN 'BUDGET_USED' END;
  RETURN jsonb_build_object(
    'card_uid', c.uid, 'card_no', c.card_no, 'status', c.status, 'plate_no', v.plate_no, 'vehicle_fuel', v.fuel_type,
    'tank_l', v.tank, 'fuel_types', to_jsonb(c.fuel_types), 'valid_until', c.valid_until,
    'holder', (SELECT legal_name FROM iam.party WHERE id = c.company_id),
    'currency', a.currency, 'balance', CASE WHEN a.fuel_company_id = p.company_id THEN a.balance END,
    'subscription_until', sub.ends_on,
    'budget', jsonb_build_object('period', c.budget_period, 'amount', c.budget_amount, 'litres', c.budget_litres,
                                 'used_amount', v_used_amount, 'used_litres', v_used_litres,
                                 'left_amount', CASE WHEN c.budget_amount IS NOT NULL THEN greatest(c.budget_amount - v_used_amount, 0) END,
                                 'left_litres', CASE WHEN c.budget_litres IS NOT NULL THEN greatest(c.budget_litres - v_used_litres, 0) END,
                                 'renews_at', CASE WHEN c.budget_period IS NOT NULL
                                                   THEN v_from + ('1 ' || lower(c.budget_period))::interval END),
    'prices', coalesce((SELECT jsonb_object_agg(fuel_type, unit_price) FROM (
                          SELECT DISTINCT ON (fuel_type) fuel_type, unit_price FROM ptn.fuel_price
                           WHERE partner_id = p.id AND valid_from <= now() AND currency = a.currency
                           ORDER BY fuel_type, valid_from DESC) pr), '{}'::jsonb),
    'tag_bound', EXISTS (SELECT 1 FROM ptn.fuel_card_tag t WHERE t.card_id = c.id AND t.unbound_at IS NULL),
    'can_fill', v_reason IS NULL, 'reason', v_reason);
END $$;

-- the attendant identifies the vehicle (a tag's hash with a secure tag's counter, a card number, or the app code's card);
-- the system works out the fill's risk and opens the challenge the fill must answer
CREATE OR REPLACE FUNCTION ptn.fuel_identify(p_partner_uid uuid, p_tag_hash bytea, p_tag_counter integer, p_card_no text,
                                             p_card_uid uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE p ptn.partner%ROWTYPE; cfg jsonb; v_card bigint; t ptn.fuel_tag%ROWTYPE; v_by text; v_risk integer := 0;
        v_factors jsonb := '{}'::jsonb; v_sampled boolean; v_qr boolean; v_odo boolean; v_fills integer; v_flagged integer;
        st jsonb; ch ptn.fuel_challenge%ROWTYPE; c ptn.fuel_card%ROWTYPE;
BEGIN
  p := ptn.attendant_station(p_partner_uid);
  cfg := coalesce((SELECT value FROM sys.setting WHERE key = 'fuel.checks'), '{}'::jsonb);
  IF num_nonnulls(p_tag_hash, p_card_no, p_card_uid) <> 1 THEN
    RAISE EXCEPTION 'FUEL_IDENTIFY_ONE: identify the vehicle one way' USING ERRCODE = 'P0001';
  END IF;
  v_by := CASE WHEN p_tag_hash IS NOT NULL THEN 'NFC' WHEN p_card_uid IS NOT NULL THEN 'APP' ELSE 'CARD_NO' END;
  IF NOT coalesce(cfg -> 'identify_methods', '["NFC", "APP", "CARD_NO"]'::jsonb) ? v_by THEN
    RAISE EXCEPTION 'FUEL_METHOD_OFF: the platform does not accept this way of identifying a vehicle' USING ERRCODE = 'P0001';
  END IF;
  IF p_tag_hash IS NOT NULL THEN
    SELECT * INTO t FROM ptn.fuel_tag WHERE tag_hash = p_tag_hash FOR UPDATE;
    IF t.id IS NULL AND coalesce((cfg ->> 'registered_tags_only')::boolean, true) THEN
      RAISE EXCEPTION 'FUEL_TAG_UNREGISTERED: the platform did not issue this tag' USING ERRCODE = 'P0001';
    END IF;
    IF t.status IN ('LOST', 'RETIRED') THEN
      RAISE EXCEPTION 'FUEL_TAG_STOPPED: this tag was reported lost or retired' USING ERRCODE = 'P0001';
    END IF;
    IF t.kind = 'SECURE' THEN
      IF p_tag_counter IS NULL THEN
        RAISE EXCEPTION 'FUEL_TAG_SECURE: this tag signs each tap; read its signed message, not its serial' USING ERRCODE = 'P0001';
      END IF;
      IF t.sun_counter IS NOT NULL AND p_tag_counter <= t.sun_counter THEN
        RAISE EXCEPTION 'FUEL_TAG_REPLAY: this tap was read before; tap the tag on the vehicle again' USING ERRCODE = 'P0001';
      END IF;
      UPDATE ptn.fuel_tag SET sun_counter = p_tag_counter, last_seen_at = now() WHERE id = t.id;
    ELSIF t.id IS NOT NULL THEN
      UPDATE ptn.fuel_tag SET last_seen_at = now() WHERE id = t.id;
    END IF;
  END IF;
  SELECT c2.id INTO v_card FROM ptn.fuel_card c2
   WHERE (p_tag_hash IS NOT NULL AND c2.id = (SELECT ct.card_id FROM ptn.fuel_card_tag ct WHERE ct.tag_hash = p_tag_hash AND ct.unbound_at IS NULL))
      OR (p_card_no IS NOT NULL AND c2.card_no = upper(btrim(p_card_no)))
      OR (p_card_uid IS NOT NULL AND c2.uid = p_card_uid);
  IF v_card IS NULL THEN
    RAISE EXCEPTION 'FUEL_CARD_UNKNOWN: no fuel card answers to this' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO c FROM ptn.fuel_card WHERE id = v_card;
  st := ptn.card_state(v_card, p.id);

  -- the risk of this fill
  CASE v_by
    WHEN 'CARD_NO' THEN v_risk := v_risk + 40; v_factors := v_factors || '{"typed_card_no": 40}';
    WHEN 'APP' THEN v_risk := v_risk + 15; v_factors := v_factors || '{"app_code": 15}';
    ELSE IF coalesce(t.kind, 'PLAIN') = 'PLAIN' THEN v_risk := v_risk + 10; v_factors := v_factors || '{"plain_tag": 10}'; END IF;
  END CASE;
  IF EXISTS (SELECT 1 FROM ptn.partner_sale s WHERE s.card_id = v_card AND s.status <> 'REVERSED'
                AND s.created_at > now() - make_interval(hours => coalesce((cfg ->> 'refill_hours')::int, 3))) THEN
    v_risk := v_risk + 30; v_factors := v_factors || '{"recent_fill": 30}';
  END IF;
  IF EXISTS (SELECT 1 FROM ptn.fuel_anomaly an JOIN ptn.fuel_session fs ON fs.id = an.session_id
              WHERE fs.vehicle_id = c.vehicle_id AND an.anomaly_type <> 'PUMP_UNCONFIRMED'
                AND (an.status IN ('OPEN', 'CONFIRMED')) AND an.created_at > now() - interval '30 days') THEN
    v_risk := v_risk + 20; v_factors := v_factors || '{"vehicle_anomalies": 20}';
  END IF;
  SELECT count(*), count(*) FILTER (WHERE fs.status = 'FLAGGED') INTO v_fills, v_flagged
    FROM ptn.fuel_session fs JOIN ptn.station_employee e ON e.id = fs.station_employee_id
   WHERE e.user_id = sys.ctx_user_id() AND fs.opened_at > now() - interval '30 days';
  IF v_fills >= 5 AND v_flagged * 10 >= v_fills THEN
    v_risk := v_risk + 20; v_factors := v_factors || '{"attendant_record": 20}';
  END IF;
  IF p.controller_key_hash IS NULL THEN
    v_risk := v_risk + 10; v_factors := v_factors || '{"no_pump_controller": 10}';
  END IF;
  v_sampled := random() * 100 < coalesce((cfg ->> 'sample_pct')::numeric, 10);
  v_qr := CASE coalesce(cfg ->> 'pump_qr', 'RISK') WHEN 'ALWAYS' THEN true WHEN 'OFF' THEN false
               ELSE v_sampled OR v_risk >= coalesce((cfg ->> 'risk_pump_qr')::int, 30) END
          AND EXISTS (SELECT 1 FROM ptn.fuel_pump fp WHERE fp.partner_id = p.id AND fp.status = 'ACTIVE');
  v_odo := CASE coalesce(cfg ->> 'odometer_photo', 'RISK') WHEN 'ALWAYS' THEN true WHEN 'OFF' THEN false
                ELSE v_sampled OR v_risk >= coalesce((cfg ->> 'risk_odometer_photo')::int, 50) END;
  INSERT INTO ptn.fuel_challenge (partner_id, card_id, user_id, identified_by, tag_kind, risk, factors, sampled,
                                  need_pump_qr, need_odometer_photo, expires_at)
  VALUES (p.id, v_card, sys.ctx_user_id(), v_by, t.kind, v_risk, v_factors, v_sampled, v_qr, v_odo,
          now() + make_interval(mins => coalesce((cfg ->> 'challenge_minutes')::int, 15)))
  RETURNING * INTO ch;
  RETURN st || jsonb_build_object('identified_by', v_by, 'tag_kind', t.kind,
                                  'challenge', jsonb_build_object('uid', ch.uid, 'risk', ch.risk, 'factors', ch.factors, 'sampled', ch.sampled,
                                                                  'need_pump_qr', ch.need_pump_qr, 'need_odometer_photo', ch.need_odometer_photo,
                                                                  'expires_at', ch.expires_at),
                                  'pumps', coalesce((SELECT jsonb_agg(jsonb_build_object('uid', fp.uid, 'pump_no', fp.pump_no) ORDER BY fp.pump_no)
                                                       FROM ptn.fuel_pump fp WHERE fp.partner_id = p.id AND fp.status = 'ACTIVE'), '[]'::jsonb));
END $$;

-- the card's company binds a tag the platform issued to it; a card keeps one tag, a tag serves one card
CREATE OR REPLACE FUNCTION ptn.fuel_bind_card_tag(p_card_uid uuid, p_tag_hash bytea) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE c ptn.fuel_card%ROWTYPE; t ptn.fuel_tag%ROWTYPE;
BEGIN
  SELECT * INTO c FROM ptn.fuel_card WHERE uid = p_card_uid AND company_id = sys.ctx_company_id()
     AND status IN ('ACTIVE', 'PAUSED') FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'FUEL_CARD_UNKNOWN: no card of your company in use' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO t FROM ptn.fuel_tag WHERE tag_hash = p_tag_hash FOR UPDATE;
  IF t.id IS NULL OR t.issued_to IS DISTINCT FROM c.company_id OR t.status <> 'ISSUED' THEN
    RAISE EXCEPTION 'FUEL_TAG_NOT_YOURS: the platform did not issue this tag to your company' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM ptn.fuel_card_tag WHERE tag_hash = p_tag_hash AND unbound_at IS NULL) THEN
    RAISE EXCEPTION 'FUEL_TAG_TAKEN: this tag already serves a card' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM ptn.fuel_card_tag WHERE card_id = c.id AND unbound_at IS NULL) THEN
    RAISE EXCEPTION 'FUEL_CARD_HAS_TAG: the card has a tag; unbind it first' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO ptn.fuel_card_tag (card_id, tag_hash, tag_id, bound_by) VALUES (c.id, p_tag_hash, t.id, sys.ctx_user_id());
  RETURN t.label;
END $$;

-- the holder reports a tag lost: it is unbound and never identifies a vehicle again
CREATE OR REPLACE FUNCTION ptn.fuel_tag_lost(p_card_uid uuid) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE n integer;
BEGIN
  UPDATE ptn.fuel_tag t SET status = 'LOST'
    FROM ptn.fuel_card_tag ct JOIN ptn.fuel_card c ON c.id = ct.card_id
   WHERE ct.tag_id = t.id AND ct.unbound_at IS NULL AND c.uid = p_card_uid AND c.company_id = sys.ctx_company_id();
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM ptn.fuel_unbind_tag(p_card_uid);
  RETURN n;
END $$;

-- a held sale follows its anomalies once none is open
CREATE OR REPLACE FUNCTION ptn.fuel_settle(p_session_id bigint) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_status text;
BEGIN
  IF EXISTS (SELECT 1 FROM ptn.fuel_anomaly WHERE session_id = p_session_id AND status = 'OPEN') THEN
    RETURN 'PENDING';
  END IF;
  v_status := CASE WHEN EXISTS (SELECT 1 FROM ptn.fuel_anomaly WHERE session_id = p_session_id AND status = 'CONFIRMED')
                   THEN 'DISPUTED' ELSE 'COMPLETED' END;
  UPDATE ptn.partner_sale SET status = v_status WHERE session_id = p_session_id AND status = 'PENDING';
  UPDATE ptn.fuel_session SET status = CASE WHEN v_status = 'COMPLETED' THEN 'COMPLETED' ELSE 'FLAGGED' END WHERE id = p_session_id;
  RETURN v_status;
END $$;

-- the fill at the pump, answering its challenge
CREATE OR REPLACE FUNCTION ptn.fuel_fill(p_challenge_uid uuid, p_fuel_type text, p_litres numeric, p_amount bigint,
                                         p_photo_file_id bigint, p_photo_dhash bigint, p_odometer_km integer,
                                         p_odometer_photo_file_id bigint, p_pump_uid uuid, p_pump_qr_version integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE ch ptn.fuel_challenge%ROWTYPE; p ptn.partner%ROWTYPE; c ptn.fuel_card%ROWTYPE; a ptn.fuel_account%ROWTYPE; st jsonb; cfg jsonb;
        pu ptn.fuel_pump%ROWTYPE; tx ptn.fuel_pump_txn%ROWTYPE; sub ptn.fuel_subscription%ROWTYPE;
        v_price bigint; v_expected bigint; v_tank numeric; v_profile record; v_last record; v_employee bigint;
        v_session bigint; v_sale bigint; v_sale_uid uuid; v_anomalies jsonb := '[]'::jsonb; v_km integer; v_rate numeric;
        v_limit numeric; v_after bigint; e jsonb; v_dup record; v_tol numeric; v_pct numeric; v_held boolean;
BEGIN
  SELECT * INTO ch FROM ptn.fuel_challenge WHERE uid = p_challenge_uid FOR UPDATE;
  IF NOT FOUND OR ch.user_id <> sys.ctx_user_id() THEN
    RAISE EXCEPTION 'FUEL_CHALLENGE_UNKNOWN: identify the vehicle first' USING ERRCODE = 'P0001';
  END IF;
  IF ch.used_at IS NOT NULL THEN
    RAISE EXCEPTION 'FUEL_CHALLENGE_USED: this identification already served a fill; identify the vehicle again' USING ERRCODE = 'P0001';
  END IF;
  IF ch.expires_at < now() THEN
    RAISE EXCEPTION 'FUEL_CHALLENGE_EXPIRED: the identification expired; identify the vehicle again' USING ERRCODE = 'P0001';
  END IF;
  p := ptn.attendant_station((SELECT uid FROM ptn.partner WHERE id = ch.partner_id));
  cfg := coalesce((SELECT value FROM sys.setting WHERE key = 'fuel.checks'), '{}'::jsonb);
  SELECT * INTO c FROM ptn.fuel_card WHERE id = ch.card_id FOR UPDATE;
  st := ptn.card_state(c.id, p.id);
  IF NOT (st ->> 'can_fill')::boolean THEN
    RAISE EXCEPTION 'FUEL_CANNOT_FILL: %', st ->> 'reason' USING ERRCODE = 'P0001';
  END IF;
  IF NOT (p_fuel_type = ANY (c.fuel_types)) THEN
    RAISE EXCEPTION 'FUEL_TYPE_NOT_ALLOWED: the card does not take %', p_fuel_type USING ERRCODE = 'P0001';
  END IF;
  v_price := (st -> 'prices' ->> p_fuel_type)::bigint;
  IF v_price IS NULL THEN
    RAISE EXCEPTION 'FUEL_NO_PRICE: the station has no price for %', p_fuel_type USING ERRCODE = 'P0001';
  END IF;
  IF p_litres IS NULL OR p_litres <= 0 OR p_litres > 2000 OR p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'FUEL_FIGURES: enter the litres and the amount shown on the meter' USING ERRCODE = 'P0001';
  END IF;
  IF coalesce((cfg ->> 'photo_required')::boolean, true) AND p_photo_file_id IS NULL THEN
    RAISE EXCEPTION 'FUEL_PHOTO_REQUIRED: photograph the pump''s meter' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM ref.file_object f WHERE f.id IN (p_photo_file_id, p_odometer_photo_file_id)
                AND f.uploaded_by IS DISTINCT FROM sys.ctx_user_id()) THEN
    RAISE EXCEPTION 'FUEL_PHOTO_REQUIRED: the photos are ones the attendant took' USING ERRCODE = 'P0001';
  END IF;
  IF ch.need_odometer_photo AND (p_odometer_photo_file_id IS NULL OR p_odometer_km IS NULL) THEN
    RAISE EXCEPTION 'FUEL_ODOMETER_PHOTO: photograph the vehicle''s odometer and enter its reading' USING ERRCODE = 'P0001';
  END IF;
  -- the pump: read from its sticker when the challenge asks for it, otherwise picked from the station's pumps
  IF p_pump_uid IS NOT NULL THEN
    SELECT * INTO pu FROM ptn.fuel_pump WHERE uid = p_pump_uid AND partner_id = p.id AND status = 'ACTIVE';
    IF pu.id IS NULL THEN
      RAISE EXCEPTION 'FUEL_PUMP_UNKNOWN: this is not a pump of this station' USING ERRCODE = 'P0001';
    END IF;
    IF p_pump_qr_version IS NOT NULL AND p_pump_qr_version <> pu.qr_version THEN
      RAISE EXCEPTION 'FUEL_PUMP_QR_OLD: this sticker was replaced; scan the pump''s current sticker' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  IF ch.need_pump_qr AND (pu.id IS NULL OR p_pump_qr_version IS NULL) THEN
    RAISE EXCEPTION 'FUEL_PUMP_QR: scan the QR sticker on the pump' USING ERRCODE = 'P0001';
  END IF;
  IF (st -> 'budget' ->> 'left_amount') IS NOT NULL AND p_amount > (st -> 'budget' ->> 'left_amount')::bigint THEN
    RAISE EXCEPTION 'FUEL_BUDGET: the budget left is %', st -> 'budget' ->> 'left_amount' USING ERRCODE = 'P0001';
  END IF;
  IF (st -> 'budget' ->> 'left_litres') IS NOT NULL AND p_litres > (st -> 'budget' ->> 'left_litres')::numeric THEN
    RAISE EXCEPTION 'FUEL_BUDGET_LITRES: the litres left are %', st -> 'budget' ->> 'left_litres' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO a FROM ptn.fuel_account WHERE id = c.account_id;
  SELECT id INTO v_employee FROM ptn.station_employee WHERE partner_id = p.id AND user_id = sys.ctx_user_id();
  UPDATE ptn.fuel_challenge SET used_at = now() WHERE id = ch.id;

  -- the checks of 1180
  v_expected := round(p_litres * v_price);
  IF abs(v_expected - p_amount) > greatest(v_expected * coalesce((cfg ->> 'amount_tolerance_pct')::numeric, 1) / 100, 1) THEN
    v_anomalies := v_anomalies || jsonb_build_object('type', 'AMOUNT_MISMATCH', 'severity', 'HIGH',
                                                     'evidence', jsonb_build_object('expected', v_expected, 'meter', p_amount, 'price', v_price));
  END IF;
  v_tank := (st ->> 'tank_l')::numeric;
  IF v_tank IS NOT NULL AND p_litres > v_tank * (1 + coalesce((cfg ->> 'tank_margin_pct')::numeric, 5) / 100) THEN
    v_anomalies := v_anomalies || jsonb_build_object('type', 'OVER_TANK', 'severity', 'HIGH',
                                                     'evidence', jsonb_build_object('tank_l', v_tank, 'litres', p_litres));
  END IF;
  SELECT r.value_km, r.ts INTO v_last FROM ptn.odometer_reading r WHERE r.vehicle_id = c.vehicle_id ORDER BY r.ts DESC, r.id DESC LIMIT 1;
  IF p_odometer_km IS NOT NULL AND v_last.value_km IS NOT NULL THEN
    v_km := p_odometer_km - v_last.value_km;
    IF v_km < 0 THEN
      v_anomalies := v_anomalies || jsonb_build_object('type', 'ODOMETER_BACKWARD', 'severity', 'HIGH',
                                                       'evidence', jsonb_build_object('last_km', v_last.value_km, 'now_km', p_odometer_km));
    ELSE
      SELECT fp.expected_l_per_100km, fp.tolerance_pct INTO v_profile FROM fleet.vehicle_fuel_profile fp WHERE fp.vehicle_id = c.vehicle_id;
      v_limit := coalesce(v_profile.expected_l_per_100km, (cfg ->> 'default_l_per_100km')::numeric, 40)
                 * (1 + coalesce(v_profile.tolerance_pct, (cfg ->> 'consumption_margin_pct')::numeric, 25) / 100);
      IF v_km = 0 THEN
        v_anomalies := v_anomalies || jsonb_build_object('type', 'DISTANCE_MISMATCH', 'severity', 'MEDIUM',
                                                         'evidence', jsonb_build_object('km', 0, 'litres', p_litres));
      ELSE
        v_rate := round(p_litres * 100 / v_km, 1);
        IF v_rate > v_limit THEN
          v_anomalies := v_anomalies || jsonb_build_object('type', 'CONSUMPTION_HIGH', 'severity', 'MEDIUM',
                                                           'evidence', jsonb_build_object('km', v_km, 'l_per_100km', v_rate, 'limit', round(v_limit, 1)));
        END IF;
      END IF;
    END IF;
  END IF;

  -- the same picture again: a near match with a recent meter photo at this station or of this card
  IF p_photo_dhash IS NOT NULL THEN
    SELECT s.uid, s.created_at, bit_count(int8send(s.photo_dhash # p_photo_dhash)) AS bits INTO v_dup
      FROM ptn.partner_sale s
     WHERE s.photo_dhash IS NOT NULL AND (s.partner_id = p.id OR s.card_id = c.id)
       AND s.created_at > now() - make_interval(days => coalesce((cfg ->> 'photo_dup_days')::int, 30))
     ORDER BY bit_count(int8send(s.photo_dhash # p_photo_dhash)), s.created_at DESC LIMIT 1;
    IF v_dup.bits IS NOT NULL AND v_dup.bits <= coalesce((cfg ->> 'photo_dup_bits')::int, 6) THEN
      v_anomalies := v_anomalies || jsonb_build_object('type', 'PHOTO_REUSED', 'severity', 'HIGH',
                                                       'evidence', jsonb_build_object('like_fill', v_dup.uid, 'of', v_dup.created_at, 'bits', v_dup.bits));
    END IF;
  END IF;

  -- the pump controller's own figures
  IF p.controller_key_hash IS NOT NULL THEN
    IF pu.id IS NULL THEN
      v_anomalies := v_anomalies || jsonb_build_object('type', 'PUMP_UNCONFIRMED', 'severity', 'MEDIUM',
                                                       'evidence', jsonb_build_object('reason', 'no pump named'));
    ELSE
      SELECT * INTO tx FROM ptn.fuel_pump_txn t
       WHERE t.pump_id = pu.id AND t.sale_id IS NULL AND t.fuel_type = p_fuel_type
         AND t.ended_at > now() - make_interval(mins => coalesce((cfg ->> 'pump_window_minutes')::int, 15))
       ORDER BY abs(t.litres - p_litres), t.ended_at DESC LIMIT 1 FOR UPDATE;
      IF tx.id IS NULL THEN
        v_anomalies := v_anomalies || jsonb_build_object('type', 'PUMP_UNCONFIRMED', 'severity', 'MEDIUM',
                                                         'evidence', jsonb_build_object('reason', 'the pump has not reported this delivery'));
      ELSE
        v_tol := coalesce((cfg ->> 'pump_litres_tolerance_pct')::numeric, 0.5);
        IF abs(tx.litres - p_litres) > tx.litres * v_tol / 100
           OR (tx.amount IS NOT NULL AND abs(tx.amount - p_amount) > greatest(tx.amount * coalesce((cfg ->> 'amount_tolerance_pct')::numeric, 1) / 100, 1)) THEN
          v_anomalies := v_anomalies || jsonb_build_object('type', 'PUMP_MISMATCH', 'severity', 'HIGH',
                                                           'evidence', jsonb_build_object('pump_litres', tx.litres, 'pump_amount', tx.amount,
                                                                                          'entered_litres', p_litres, 'entered_amount', p_amount,
                                                                                          'controller_ref', tx.controller_ref));
        END IF;
      END IF;
    END IF;
  END IF;

  v_held := jsonb_array_length(v_anomalies) > 0;
  INSERT INTO ptn.fuel_session (partner_id, pump_ref, station_employee_id, company_id, vehicle_id, fuel_card_id, closed_at, status)
  VALUES (p.id, pu.pump_no::text, v_employee, c.company_id, c.vehicle_id, c.id, now(), CASE WHEN v_held THEN 'FLAGGED' ELSE 'COMPLETED' END)
  RETURNING id INTO v_session;
  IF p_odometer_km IS NOT NULL THEN
    INSERT INTO ptn.odometer_reading (vehicle_id, session_id, value_km, source, photo_file_id, employee_confirmed)
    VALUES (c.vehicle_id, v_session, p_odometer_km, CASE WHEN p_odometer_photo_file_id IS NULL THEN 'MANUAL' ELSE 'PHOTO' END,
            p_odometer_photo_file_id, true);
  END IF;
  INSERT INTO ptn.partner_sale (partner_id, session_id, company_id, vehicle_id, driver_party_id, fuel_type, qty, unit_price, amount,
                                currency, method, odometer_km, status, card_id, meter_photo_file_id, expected_amount, identified_by,
                                plate_no, holder_name, station_name, pump_ref, challenge_id, pump_id, pump_by_qr,
                                odometer_photo_file_id, photo_dhash, risk)
  VALUES (p.id, v_session, c.company_id, c.vehicle_id, c.driver_party_id, p_fuel_type, p_litres, v_price, p_amount,
          a.currency, 'PREPAID', p_odometer_km, CASE WHEN v_held THEN 'PENDING' ELSE 'COMPLETED' END,
          c.id, p_photo_file_id, v_expected, ch.identified_by, st ->> 'plate_no', st ->> 'holder',
          (SELECT legal_name FROM iam.party WHERE id = p.party_id), pu.pump_no::text, ch.id, pu.id,
          CASE WHEN pu.id IS NOT NULL THEN p_pump_qr_version IS NOT NULL END, p_odometer_photo_file_id, p_photo_dhash, ch.risk)
  RETURNING id, uid INTO v_sale, v_sale_uid;
  IF tx.id IS NOT NULL THEN
    UPDATE ptn.fuel_pump_txn SET sale_id = v_sale WHERE id = tx.id;
  END IF;
  INSERT INTO ptn.fuel_account_entry (account_id, kind, amount, balance_after, sale_id, recorded_by)
  VALUES (a.id, 'FILL', -p_amount, 0, v_sale, sys.ctx_user_id())
  RETURNING balance_after INTO v_after;
  FOR e IN SELECT * FROM jsonb_array_elements(v_anomalies) LOOP
    INSERT INTO ptn.fuel_anomaly (session_id, anomaly_type, severity, liters, evidence)
    VALUES (v_session, e ->> 'type', e ->> 'severity', p_litres, e -> 'evidence');
  END LOOP;

  -- the platform's commission: the carrier's from its subscription, the fuel company's from its terms
  sub := ptn.fuel_cover(c.vehicle_id, c.company_id);
  v_pct := coalesce(sub.commission_pct, 0);
  IF v_pct > 0 THEN
    INSERT INTO ptn.fuel_commission (sale_id, side, company_id, pct, amount, currency)
    VALUES (v_sale, 'CARRIER', c.company_id, v_pct, round(p_amount * v_pct / 100), a.currency);
  END IF;
  SELECT t.commission_pct INTO v_pct FROM ptn.fuel_company_terms t
   WHERE t.fuel_company_id = p.company_id AND t.valid_from <= ptn.company_today(p.company_id) ORDER BY t.valid_from DESC LIMIT 1;
  IF coalesce(v_pct, 0) > 0 THEN
    INSERT INTO ptn.fuel_commission (sale_id, side, company_id, pct, amount, currency)
    VALUES (v_sale, 'FUEL_COMPANY', p.company_id, v_pct, round(p_amount * v_pct / 100), a.currency);
  END IF;

  RETURN jsonb_build_object('sale_uid', v_sale_uid, 'sale_id', v_sale, 'status', CASE WHEN v_held THEN 'HELD' ELSE 'COMPLETED' END,
                            'anomalies', v_anomalies, 'balance', v_after, 'low_balance', a.low_balance IS NOT NULL AND v_after < a.low_balance,
                            'currency', a.currency, 'plate_no', st ->> 'plate_no', 'holder_company_id', c.company_id,
                            'station', (SELECT legal_name FROM iam.party WHERE id = p.party_id), 'expected_amount', v_expected,
                            'pump_no', pu.pump_no, 'risk', ch.risk,
                            'left_amount', CASE WHEN (st -> 'budget' ->> 'left_amount') IS NOT NULL
                                                THEN (st -> 'budget' ->> 'left_amount')::bigint - p_amount END);
END $$;

CREATE OR REPLACE FUNCTION ptn.decide_fuel_anomaly(p_anomaly_uid uuid, p_outcome text, p_note text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE an ptn.fuel_anomaly%ROWTYPE; s ptn.fuel_session%ROWTYPE;
BEGIN
  SELECT * INTO an FROM ptn.fuel_anomaly WHERE uid = p_anomaly_uid FOR UPDATE;
  SELECT * INTO s FROM ptn.fuel_session WHERE id = an.session_id;
  IF an.id IS NULL OR NOT (sys.ctx_is_platform() OR sys.tenant_visible(s.company_id)
                           OR EXISTS (SELECT 1 FROM ptn.partner p WHERE p.id = s.partner_id AND p.company_id = sys.ctx_company_id())) THEN
    RAISE EXCEPTION 'FUEL_ANOMALY_UNKNOWN: no such anomaly for you' USING ERRCODE = 'P0001';
  END IF;
  IF an.status <> 'OPEN' THEN
    RAISE EXCEPTION 'FUEL_ANOMALY_DECIDED: the anomaly was already decided' USING ERRCODE = 'P0001';
  END IF;
  IF p_outcome NOT IN ('EXPLAINED', 'CONFIRMED', 'DISMISSED') OR p_note IS NULL OR length(btrim(p_note)) < 3 THEN
    RAISE EXCEPTION 'FUEL_ANOMALY_NOTE: decide EXPLAINED, CONFIRMED or DISMISSED, with a note' USING ERRCODE = 'P0001';
  END IF;
  UPDATE ptn.fuel_anomaly SET status = p_outcome, note = btrim(p_note), resolved_by = sys.ctx_user_id(), resolved_at = now()
   WHERE id = an.id;
  RETURN ptn.fuel_settle(s.id);
END $$;

-- the vehicle's owner questions a fill after looking at its photos: an anomaly the fuel company answers
CREATE OR REPLACE FUNCTION ptn.fuel_owner_query(p_sale_uid uuid, p_note text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE s ptn.partner_sale%ROWTYPE; v_uid uuid;
BEGIN
  SELECT * INTO s FROM ptn.partner_sale WHERE uid = p_sale_uid AND method = 'PREPAID' AND company_id = sys.ctx_company_id();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'FUEL_SALE_UNKNOWN: no fill of your vehicles' USING ERRCODE = 'P0001';
  END IF;
  IF s.status = 'REVERSED' THEN
    RAISE EXCEPTION 'FUEL_SALE_REVERSED: the fill was already given back' USING ERRCODE = 'P0001';
  END IF;
  IF p_note IS NULL OR length(btrim(p_note)) < 3 THEN
    RAISE EXCEPTION 'FUEL_ANOMALY_NOTE: say what does not match' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM ptn.fuel_anomaly WHERE session_id = s.session_id AND anomaly_type = 'OWNER_QUERY' AND status = 'OPEN') THEN
    RAISE EXCEPTION 'FUEL_QUERY_OPEN: this fill is already questioned' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO ptn.fuel_anomaly (session_id, anomaly_type, severity, liters, evidence)
  VALUES (s.session_id, 'OWNER_QUERY', 'MEDIUM', s.qty, jsonb_build_object('note', btrim(p_note)))
  RETURNING uid INTO v_uid;
  RETURN v_uid;
END $$;

-- the fuel company gives a fill back; the platform's commissions on it are void
CREATE OR REPLACE FUNCTION ptn.fuel_reverse_sale(p_sale_uid uuid, p_reason text) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE s ptn.partner_sale%ROWTYPE; v_account bigint; v_after bigint;
BEGIN
  SELECT * INTO s FROM ptn.partner_sale WHERE uid = p_sale_uid AND method = 'PREPAID' FOR UPDATE;
  IF NOT FOUND OR NOT EXISTS (SELECT 1 FROM ptn.partner p WHERE p.id = s.partner_id AND p.company_id = sys.ctx_company_id()) THEN
    RAISE EXCEPTION 'FUEL_SALE_UNKNOWN: no fill of your stations' USING ERRCODE = 'P0001';
  END IF;
  IF s.status = 'REVERSED' THEN
    RAISE EXCEPTION 'FUEL_SALE_REVERSED: the fill was already given back' USING ERRCODE = 'P0001';
  END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) < 3 THEN
    RAISE EXCEPTION 'FUEL_REASON: a fill is given back with its reason' USING ERRCODE = 'P0001';
  END IF;
  SELECT account_id INTO v_account FROM ptn.fuel_account_entry WHERE sale_id = s.id AND kind = 'FILL';
  INSERT INTO ptn.fuel_account_entry (account_id, kind, amount, balance_after, sale_id, note, recorded_by)
  VALUES (v_account, 'REVERSAL', s.amount, 0, s.id, btrim(p_reason), sys.ctx_user_id())
  RETURNING balance_after INTO v_after;
  UPDATE ptn.partner_sale SET status = 'REVERSED' WHERE id = s.id;
  UPDATE ptn.fuel_commission SET status = 'VOID' WHERE sale_id = s.id;
  RETURN v_after;
END $$;

-- the station's pump controller reports a delivery (called with the hash of its key); it is matched with the fill it
-- belongs to, which an earlier PUMP_UNCONFIRMED held
CREATE OR REPLACE FUNCTION ptn.fuel_controller_txn(p_key_hash bytea, p_pump_no integer, p_ref text, p_fuel_type text,
                                                   p_litres numeric, p_amount bigint, p_totalizer numeric, p_ended_at timestamptz) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE p ptn.partner%ROWTYPE; pu ptn.fuel_pump%ROWTYPE; cfg jsonb; v_txn bigint; s ptn.partner_sale%ROWTYPE; an ptn.fuel_anomaly%ROWTYPE;
        v_ok boolean; v_status text;
BEGIN
  SELECT * INTO p FROM ptn.partner WHERE controller_key_hash = p_key_hash AND partner_type = 'FUEL' AND status = 'ACTIVE';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'FUEL_CONTROLLER_KEY: unknown or revoked controller key' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO pu FROM ptn.fuel_pump WHERE partner_id = p.id AND pump_no = p_pump_no;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'FUEL_PUMP_UNKNOWN: the station has no pump %', p_pump_no USING ERRCODE = 'P0001';
  END IF;
  IF p_litres IS NULL OR p_litres <= 0 OR p_ended_at IS NULL OR p_ended_at > now() + interval '5 minutes' THEN
    RAISE EXCEPTION 'FUEL_FIGURES: a delivery has its litres and its end time' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO ptn.fuel_pump_txn (partner_id, pump_id, controller_ref, fuel_type, litres, amount, totalizer, ended_at)
  VALUES (p.id, pu.id, btrim(p_ref), p_fuel_type, p_litres, p_amount, p_totalizer, p_ended_at)
  ON CONFLICT (partner_id, controller_ref) DO NOTHING
  RETURNING id INTO v_txn;
  IF v_txn IS NULL THEN
    RETURN jsonb_build_object('duplicate', true);
  END IF;
  cfg := coalesce((SELECT value FROM sys.setting WHERE key = 'fuel.checks'), '{}'::jsonb);
  -- the fill this delivery belongs to: same pump and fuel, near in time, still waiting for the pump, the nearest in litres
  SELECT sa.* INTO s FROM ptn.partner_sale sa
   WHERE sa.pump_id = pu.id AND sa.fuel_type = p_fuel_type AND sa.status = 'PENDING'
     AND NOT EXISTS (SELECT 1 FROM ptn.fuel_pump_txn t WHERE t.sale_id = sa.id)
     AND sa.created_at BETWEEN p_ended_at - make_interval(mins => coalesce((cfg ->> 'pump_window_minutes')::int, 15))
                           AND p_ended_at + make_interval(mins => coalesce((cfg ->> 'pump_window_minutes')::int, 15))
     AND EXISTS (SELECT 1 FROM ptn.fuel_anomaly x WHERE x.session_id = sa.session_id AND x.anomaly_type = 'PUMP_UNCONFIRMED' AND x.status = 'OPEN')
   ORDER BY abs(sa.qty - p_litres) LIMIT 1 FOR UPDATE;
  IF s.id IS NULL THEN
    RETURN jsonb_build_object('matched', false);
  END IF;
  UPDATE ptn.fuel_pump_txn SET sale_id = s.id WHERE id = v_txn;
  SELECT * INTO an FROM ptn.fuel_anomaly WHERE session_id = s.session_id AND anomaly_type = 'PUMP_UNCONFIRMED' AND status = 'OPEN';
  v_ok := abs(p_litres - s.qty) <= p_litres * coalesce((cfg ->> 'pump_litres_tolerance_pct')::numeric, 0.5) / 100
          AND (p_amount IS NULL OR abs(p_amount - s.amount) <= greatest(p_amount * coalesce((cfg ->> 'amount_tolerance_pct')::numeric, 1) / 100, 1));
  UPDATE ptn.fuel_anomaly SET status = 'DISMISSED', resolved_at = now(),
         note = CASE WHEN v_ok THEN 'confirmed by the pump controller' ELSE 'the pump controller reported other figures' END
   WHERE id = an.id;
  IF NOT v_ok THEN
    INSERT INTO ptn.fuel_anomaly (session_id, anomaly_type, severity, liters, evidence)
    VALUES (s.session_id, 'PUMP_MISMATCH', 'HIGH', s.qty,
            jsonb_build_object('pump_litres', p_litres, 'pump_amount', p_amount, 'entered_litres', s.qty, 'entered_amount', s.amount,
                               'controller_ref', btrim(p_ref)));
  END IF;
  v_status := ptn.fuel_settle(s.session_id);
  RETURN jsonb_build_object('matched', true, 'sale_uid', s.uid, 'agrees', v_ok, 'sale_status', v_status);
END $$;

-- the fuel company's manager replaces a pump's sticker: the older one stops working
CREATE OR REPLACE FUNCTION ptn.fuel_pump_new_qr(p_pump_uid uuid) RETURNS smallint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v smallint;
BEGIN
  UPDATE ptn.fuel_pump fp SET qr_version = qr_version + 1
    FROM ptn.partner p WHERE p.id = fp.partner_id AND fp.uid = p_pump_uid AND p.company_id = sys.ctx_company_id()
  RETURNING fp.qr_version INTO v;
  IF v IS NULL THEN
    RAISE EXCEPTION 'FUEL_PUMP_UNKNOWN: no pump of your stations' USING ERRCODE = 'P0001';
  END IF;
  RETURN v;
END $$;

-- the fuel company's manager sets (or clears) the key its pump controller reports with
CREATE OR REPLACE FUNCTION ptn.fuel_set_controller(p_partner_uid uuid, p_key_hash bytea) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  UPDATE ptn.partner SET controller_key_hash = p_key_hash, controller_since = CASE WHEN p_key_hash IS NULL THEN NULL ELSE now() END
   WHERE uid = p_partner_uid AND partner_type = 'FUEL' AND company_id = sys.ctx_company_id();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'FUEL_STATION_UNKNOWN: no station of your company' USING ERRCODE = 'P0001';
  END IF;
END $$;

-- a carrier asks for the fuel service for some of its vehicles; the price comes from the platform's list when it has one
CREATE OR REPLACE FUNCTION ptn.fuel_request_subscription(p_period text, p_starts_on date, p_vehicle_uids uuid[]) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE cfg jsonb; v_price bigint; v_ids bigint[]; v_sub ptn.fuel_subscription%ROWTYPE; v_end date; v_company bigint := sys.ctx_company_id();
BEGIN
  IF v_company IS NULL OR NOT EXISTS (SELECT 1 FROM iam.company WHERE id = v_company
                                         AND company_type IN ('CARRIER', 'INDIVIDUAL_OPERATOR', 'FOREIGN_CARRIER', 'SCHOOL', 'PARTNER')) THEN
    RAISE EXCEPTION 'NOT_A_FLEET: the fuel service is taken by a company with vehicles' USING ERRCODE = 'P0001';
  END IF;
  IF p_period NOT IN ('WEEK', 'MONTH', 'QUARTER', 'YEAR') THEN
    RAISE EXCEPTION 'FUEL_PERIOD: a subscription runs a week, a month, a quarter or a year' USING ERRCODE = 'P0001';
  END IF;
  IF p_starts_on IS NULL OR p_starts_on < ptn.company_today(v_company) THEN
    RAISE EXCEPTION 'FUEL_START: a subscription starts today or later' USING ERRCODE = 'P0001';
  END IF;
  SELECT array_agg(v.id) INTO v_ids FROM fleet.vehicle v WHERE v.uid = ANY (p_vehicle_uids) AND v.company_id = v_company;
  IF v_ids IS NULL OR cardinality(v_ids) <> cardinality(ARRAY(SELECT DISTINCT unnest(p_vehicle_uids))) THEN
    RAISE EXCEPTION 'VEHICLE_NOT_OWNED_OR_LEASED: choose vehicles of your company' USING ERRCODE = 'P0001';
  END IF;
  v_end := (p_starts_on + ('1 ' || lower(p_period))::interval)::date - 1;
  cfg := coalesce((SELECT value FROM sys.setting WHERE key = 'fuel.subscription'), '{}'::jsonb);
  v_price := (cfg -> 'prices' ->> p_period)::bigint;
  INSERT INTO ptn.fuel_subscription (company_id, period, vehicles, price_per_vehicle, amount, currency, commission_pct,
                                     starts_on, ends_on, requested_by)
  VALUES (v_company, p_period, cardinality(v_ids), v_price, v_price * cardinality(v_ids),
          ref.company_currency(v_company),
          (cfg ->> 'carrier_commission_pct')::numeric, p_starts_on, v_end, sys.ctx_user_id())
  RETURNING * INTO v_sub;
  INSERT INTO ptn.fuel_subscription_vehicle (subscription_id, vehicle_id) SELECT v_sub.id, unnest(v_ids);
  RETURN v_sub.uid;
END $$;

-- the carrier withdraws a request not yet paid
CREATE OR REPLACE FUNCTION ptn.fuel_cancel_subscription(p_uid uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  UPDATE ptn.fuel_subscription SET status = 'CANCELLED'
   WHERE uid = p_uid AND status = 'REQUESTED' AND (company_id = sys.ctx_company_id() OR sys.ctx_is_platform());
  IF NOT FOUND THEN
    RAISE EXCEPTION 'FUEL_SUBSCRIPTION_UNKNOWN: no request awaiting payment' USING ERRCODE = 'P0001';
  END IF;
END $$;

-- the platform records the advance payment it received; the subscription opens its vehicles to filling
CREATE OR REPLACE FUNCTION ptn.fuel_confirm_subscription(p_uid uuid, p_price bigint, p_commission_pct numeric, p_reference text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE s ptn.fuel_subscription%ROWTYPE;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'NOT_PLATFORM: the platform records a subscription''s payment' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO s FROM ptn.fuel_subscription WHERE uid = p_uid FOR UPDATE;
  IF NOT FOUND OR s.status <> 'REQUESTED' THEN
    RAISE EXCEPTION 'FUEL_SUBSCRIPTION_UNKNOWN: no request awaiting payment' USING ERRCODE = 'P0001';
  END IF;
  IF coalesce(p_price, s.price_per_vehicle) IS NULL OR coalesce(p_commission_pct, s.commission_pct) IS NULL
     OR p_reference IS NULL OR length(btrim(p_reference)) < 1 THEN
    RAISE EXCEPTION 'FUEL_SUBSCRIPTION_TERMS: the price per vehicle, the commission and the payment''s reference' USING ERRCODE = 'P0001';
  END IF;
  UPDATE ptn.fuel_subscription
     SET price_per_vehicle = coalesce(p_price, price_per_vehicle), commission_pct = coalesce(p_commission_pct, commission_pct),
         amount = coalesce(p_price, price_per_vehicle) * vehicles, paid_reference = btrim(p_reference), paid_at = now(),
         confirmed_by = sys.ctx_user_id(), status = 'ACTIVE'
   WHERE id = s.id RETURNING * INTO s;
  RETURN jsonb_build_object('uid', s.uid, 'amount', s.amount, 'currency', s.currency, 'starts_on', s.starts_on, 'ends_on', s.ends_on,
                            'company_id', s.company_id);
END $$;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['ptn.tg_fuel_pumps()', 'ptn.company_today(bigint)', 'ptn.fuel_cover(bigint,bigint)',
                           'ptn.fuel_identify(uuid,bytea,integer,text,uuid)', 'ptn.fuel_bind_card_tag(uuid,bytea)', 'ptn.fuel_tag_lost(uuid)',
                           'ptn.fuel_settle(bigint)',
                           'ptn.fuel_fill(uuid,text,numeric,bigint,bigint,bigint,integer,bigint,uuid,integer)',
                           'ptn.fuel_owner_query(uuid,text)',
                           'ptn.fuel_controller_txn(bytea,integer,text,text,numeric,bigint,numeric,timestamp with time zone)',
                           'ptn.fuel_pump_new_qr(uuid)', 'ptn.fuel_set_controller(uuid,bytea)',
                           'ptn.fuel_request_subscription(text,date,uuid[])', 'ptn.fuel_cancel_subscription(uuid)',
                           'ptn.fuel_confirm_subscription(uuid,bigint,numeric,text)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
  END LOOP;
  FOREACH f IN ARRAY ARRAY['ptn.company_today(bigint)', 'ptn.fuel_identify(uuid,bytea,integer,text,uuid)', 'ptn.fuel_bind_card_tag(uuid,bytea)', 'ptn.fuel_tag_lost(uuid)',
                           'ptn.fuel_fill(uuid,text,numeric,bigint,bigint,bigint,integer,bigint,uuid,integer)',
                           'ptn.fuel_owner_query(uuid,text)',
                           'ptn.fuel_controller_txn(bytea,integer,text,text,numeric,bigint,numeric,timestamp with time zone)',
                           'ptn.fuel_pump_new_qr(uuid)', 'ptn.fuel_set_controller(uuid,bytea)',
                           'ptn.fuel_request_subscription(text,date,uuid[])', 'ptn.fuel_cancel_subscription(uuid)',
                           'ptn.fuel_confirm_subscription(uuid,bigint,numeric,text)'] LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO masslak_app', f);
  END LOOP;
END $$;
COMMENT ON FUNCTION ptn.company_today IS 'The company''s date today in its time zone (1181)';
COMMENT ON FUNCTION ptn.fuel_cover IS 'The paid fuel subscription covering a vehicle today (1181)';
COMMENT ON FUNCTION ptn.fuel_identify IS 'The attendant identifies a vehicle by a registered tag (a secure tag''s counter must rise), its card number or its app code; the risk is worked out and a challenge opened for the fill (1180, 1181)';
COMMENT ON FUNCTION ptn.fuel_bind_card_tag IS 'The card''s company binds a tag the platform issued to it (1181)';
COMMENT ON FUNCTION ptn.fuel_tag_lost IS 'The card''s company reports its tag lost: unbound and stopped for good (1181)';
COMMENT ON FUNCTION ptn.fuel_settle IS 'A held fill completes or becomes disputed once none of its anomalies is open (1181)';
COMMENT ON FUNCTION ptn.fuel_fill IS 'A fill answering its challenge: the pump (its QR when asked), the meter''s photo (a reused one is flagged), the odometer''s photo when asked, the pump controller''s figures; paid from the account, commissions recorded, held when a check fails (1180, 1181)';
COMMENT ON FUNCTION ptn.fuel_owner_query IS 'The vehicle''s owner questions a fill: an OWNER_QUERY anomaly for the fuel company to answer (1181)';
COMMENT ON FUNCTION ptn.fuel_controller_txn IS 'A delivery reported by the station''s pump controller, matched with the fill it belongs to (1181)';
COMMENT ON FUNCTION ptn.fuel_pump_new_qr IS 'A new QR sticker for a pump; the older sticker stops working (1181)';
COMMENT ON FUNCTION ptn.fuel_set_controller IS 'Sets or clears the key of a station''s pump controller (1181)';
COMMENT ON FUNCTION ptn.fuel_request_subscription IS 'A carrier asks for the fuel service for chosen vehicles and a period (1181)';
COMMENT ON FUNCTION ptn.fuel_cancel_subscription IS 'A subscription request not yet paid is withdrawn (1181)';
COMMENT ON FUNCTION ptn.fuel_confirm_subscription IS 'The platform records the advance payment of a subscription, with its price and commission; its vehicles may fill (1181)';
COMMENT ON FUNCTION ptn.card_state IS 'What a fuel card may still take at a station: allowance left and its renewal, end date, subscription, balance, fuel types, prices, and why not (1180, 1181)';

-- ------------------------------------------------------------------ registration
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('ptn.fuel_tag', '9', 'E27'), ('ptn.fuel_pump', '9', 'E27'), ('ptn.fuel_pump_txn', '9', 'E27'), ('ptn.fuel_challenge', '9', 'E27'),
  ('ptn.fuel_subscription', '9', 'E27'), ('ptn.fuel_subscription_vehicle', '9', 'E27'), ('ptn.fuel_company_terms', '9', 'E27'),
  ('ptn.fuel_commission', '9', 'E27')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
INSERT INTO sys.table_class (table_name, data_class, tenant_path, note) VALUES
  ('ptn.fuel_tag', 'TENANT_PRIVATE', 'issued_to', 'NFC tags the platform registered and issued to carriers (1181)'),
  ('ptn.fuel_pump', 'TENANT_PRIVATE', 'parent ptn.partner', 'pumps of fuel stations and the version of their QR sticker (1181)'),
  ('ptn.fuel_pump_txn', 'TENANT_PRIVATE', 'parent ptn.partner', 'deliveries reported by stations'' pump controllers (1181)'),
  ('ptn.fuel_challenge', 'TENANT_PRIVATE', 'parent ptn.partner', 'identifications at the pump with their risk and what the fill must show (1181)'),
  ('ptn.fuel_subscription', 'TENANT_PRIVATE', 'company_id', 'carriers'' subscriptions to the fuel service, paid in advance (1181)'),
  ('ptn.fuel_subscription_vehicle', 'TENANT_PRIVATE', 'parent ptn.fuel_subscription', 'vehicles of fuel subscriptions (1181)'),
  ('ptn.fuel_company_terms', 'TENANT_PRIVATE', 'fuel_company_id', 'the platform''s commission with each fuel company (1181)'),
  ('ptn.fuel_commission', 'TENANT_PRIVATE', 'company_id', 'the platform''s commission due on each fill (1181)')
ON CONFLICT (table_name) DO UPDATE SET data_class = excluded.data_class, tenant_path = excluded.tenant_path, note = excluded.note;
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('ptn.fuel_tag', 'ptn records', 'NFC tags of the fuel service (1181)'),
  ('ptn.fuel_pump', 'ptn records', 'pumps of fuel stations (1181)'),
  ('ptn.fuel_pump_txn', 'ptn records', 'pump controller deliveries (1181)'),
  ('ptn.fuel_challenge', 'ptn records', 'identifications at the pump (1181)'),
  ('ptn.fuel_subscription', 'ptn records', 'fuel subscriptions (1181)'),
  ('ptn.fuel_subscription_vehicle', 'ptn records', 'vehicles of fuel subscriptions (1181)'),
  ('ptn.fuel_company_terms', 'ptn records', 'fuel companies'' commission terms (1181)'),
  ('ptn.fuel_commission', 'ptn records', 'commissions on fills (1181)')
ON CONFLICT (table_name) DO NOTHING;
SELECT sys.refresh_table_class();
