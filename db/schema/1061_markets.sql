-- =====================================================================
-- 1061: markets (expert review of October 2026, stage D: time zone and currency per market)
--   Until now the time zone (Asia/Damascus) and the currency (SYP) were fixed in the code. A market is a country the
--   platform operates in, with its time zone, currency and default language. A company belongs to the market of its
--   country (the default market when its country has none); a station takes the time zone of its city. Opening a market
--   creates the platform's wallets in its currency, and a trip is priced in its company's currency unless another
--   currency the platform holds wallets for is chosen. Beirut and Amman carried Damascus's time zone since the seed;
--   they now carry their own.
-- =====================================================================

CREATE TABLE IF NOT EXISTS ref.market (
  country_code  char(2) PRIMARY KEY REFERENCES ref.country(code),
  time_zone     text NOT NULL,
  currency      char(3) NOT NULL REFERENCES ref.currency(code),
  locale        text NOT NULL DEFAULT 'ar' REFERENCES ref.locale(code),
  status        text NOT NULL DEFAULT 'PLANNED' CHECK (status IN ('ACTIVE', 'PLANNED', 'CLOSED')),
  is_default    boolean NOT NULL DEFAULT false,
  opened_at     timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CHECK (NOT is_default OR status = 'ACTIVE')
);
COMMENT ON TABLE ref.market IS 'Countries the platform operates in: time zone, currency and default language of each (1061)';
COMMENT ON COLUMN ref.market.is_default IS 'The market of companies and people whose country has none; exactly one, and active';
CREATE UNIQUE INDEX IF NOT EXISTS market_one_default ON ref.market (is_default) WHERE is_default;
CREATE INDEX IF NOT EXISTS market_currency_fkx ON ref.market (currency);
CREATE INDEX IF NOT EXISTS market_locale_fkx ON ref.market (locale);
SELECT sys.rls_catalog('ref.market');
GRANT SELECT ON ref.market TO masslak_app, masslak_readonly, masslak_auditor;

CREATE OR REPLACE FUNCTION ref.tg_market_rules() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = NEW.time_zone) OR NEW.time_zone !~ '/' THEN
    RAISE EXCEPTION 'MARKET_TIMEZONE: give the market''s IANA time zone (for example Asia/Amman)' USING ERRCODE = 'P0001';
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.status = 'ACTIVE' AND NEW.currency <> OLD.currency THEN
    RAISE EXCEPTION 'MARKET_CURRENCY_FIXED: an open market keeps its currency; its prices, wallets and ledger are in it'
      USING ERRCODE = 'P0001';
  END IF;
  IF NEW.status = 'ACTIVE' AND NEW.opened_at IS NULL THEN
    NEW.opened_at := now();
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS market_rules ON ref.market;
CREATE TRIGGER market_rules BEFORE INSERT OR UPDATE ON ref.market FOR EACH ROW EXECUTE FUNCTION ref.tg_market_rules();

-- The platform's own wallets in a currency (revenue, escrow, commission, tax, clearing, sponsor), created once
CREATE OR REPLACE FUNCTION fin.ensure_platform_wallets(p_currency char(3)) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE added integer;
BEGIN
  INSERT INTO fin.wallet (owner_party_id, wallet_type, label, currency, allow_negative)
  SELECT p.id, w.t, w.l, p_currency, w.neg
    FROM iam.party p
   CROSS JOIN (VALUES ('PLATFORM','Platform revenue',false), ('ESCROW','Escrow funds',false), ('COMMISSION','Commissions',false),
                      ('TAX','Collected taxes',false), ('GATEWAY_CLEARING','Payment gateway clearing',true),
                      ('BANK_CLEARING','Bank transfer clearing',true), ('SPONSOR','Sponsor receivables',true)) AS w(t, l, neg)
   WHERE p.legal_name = 'Masslak Platform' AND p.party_type = 'COMPANY'
     AND NOT EXISTS (SELECT 1 FROM fin.wallet x WHERE x.owner_party_id = p.id AND x.wallet_type = w.t AND x.currency = p_currency);
  GET DIAGNOSTICS added = ROW_COUNT;
  RETURN added;
END $$;
COMMENT ON FUNCTION fin.ensure_platform_wallets IS 'Creates the platform wallets of a currency that are missing (opening a market, 1061)';
REVOKE ALL ON FUNCTION fin.ensure_platform_wallets(char) FROM PUBLIC;

CREATE OR REPLACE FUNCTION ref.tg_market_open() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM fin.ensure_platform_wallets(NEW.currency);
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS market_open ON ref.market;
CREATE TRIGGER market_open AFTER INSERT OR UPDATE OF status, currency ON ref.market
  FOR EACH ROW WHEN (NEW.status = 'ACTIVE') EXECUTE FUNCTION ref.tg_market_open();

INSERT INTO ref.market (country_code, time_zone, currency, locale, status, is_default) VALUES
  ('SY', 'Asia/Damascus', 'SYP', 'ar', 'ACTIVE', true),
  ('LB', 'Asia/Beirut', 'LBP', 'ar', 'PLANNED', false),
  ('JO', 'Asia/Amman', 'JOD', 'ar', 'PLANNED', false),
  ('IQ', 'Asia/Baghdad', 'IQD', 'ar', 'PLANNED', false),
  ('SA', 'Asia/Riyadh', 'SAR', 'ar', 'PLANNED', false),
  ('TR', 'Europe/Istanbul', 'TRY', 'en', 'PLANNED', false)
ON CONFLICT (country_code) DO NOTHING;

-- Cities outside Syria took Damascus's time zone from the seed's default (dropped in 1048): they get their country's
UPDATE ref.city c SET timezone = m.time_zone
  FROM ref.market m
 WHERE m.country_code = c.country_code AND c.country_code <> 'SY' AND c.timezone = 'Asia/Damascus';

-- ------------------------------------------------------------------ lookups
-- The market of a country: its own unless closed or missing, otherwise the default market
CREATE OR REPLACE FUNCTION ref.market_of_country(p_country text) RETURNS ref.market
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT m.* FROM ref.market m
   WHERE (m.country_code = p_country AND m.status <> 'CLOSED') OR m.is_default
   ORDER BY (m.country_code = p_country AND m.status <> 'CLOSED') DESC LIMIT 1
$$;
-- The market of a company or a person (party): the market of its country
CREATE OR REPLACE FUNCTION ref.party_market(p_party bigint) RETURNS ref.market
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT ref.market_of_country((SELECT p.country_code FROM iam.party p WHERE p.id = p_party))
$$;
CREATE OR REPLACE FUNCTION ref.company_tz(p_company bigint) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT (ref.party_market(p_company)).time_zone
$$;
CREATE OR REPLACE FUNCTION ref.company_currency(p_company bigint) RETURNS char(3)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT (ref.party_market(p_company)).currency
$$;
-- A station's time zone: its city's, otherwise its country's market
CREATE OR REPLACE FUNCTION ref.station_tz(p_station bigint) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce(c.timezone, (ref.market_of_country(s.country_code)).time_zone)
    FROM net.station s LEFT JOIN ref.city c ON c.id = s.city_id
   WHERE s.id = p_station
$$;
COMMENT ON FUNCTION ref.market_of_country IS 'The market of a country, or the default market (1061)';
COMMENT ON FUNCTION ref.party_market IS 'The market of a company or person: the market of its country (1061)';
COMMENT ON FUNCTION ref.station_tz IS 'The time zone of a station: its city''s, else its country''s market (1061)';
DO $$ DECLARE f text; BEGIN
  FOREACH f IN ARRAY ARRAY['ref.market_of_country(text)', 'ref.party_market(bigint)', 'ref.company_tz(bigint)',
                           'ref.company_currency(bigint)', 'ref.station_tz(bigint)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO masslak_app, masslak_readonly, masslak_auditor', f);
  END LOOP;
END $$;

-- ------------------------------------------------------------------ trips are priced in a currency the platform holds
CREATE OR REPLACE FUNCTION ops.tg_trip_currency() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  NEW.currency := coalesce(NEW.currency, ref.company_currency(NEW.company_id));
  IF NOT EXISTS (SELECT 1 FROM fin.wallet w JOIN iam.party p ON p.id = w.owner_party_id
                  WHERE p.legal_name = 'Masslak Platform' AND p.party_type = 'COMPANY'
                    AND w.wallet_type = 'ESCROW' AND w.currency = NEW.currency) THEN
    RAISE EXCEPTION 'TRIP_CURRENCY_UNSUPPORTED: % is not the currency of an open market', NEW.currency USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
COMMENT ON FUNCTION ops.tg_trip_currency IS 'A trip is priced in its company''s market currency unless another currency of an open market is given (1061)';
DROP TRIGGER IF EXISTS trip_currency ON ops.trip;
CREATE TRIGGER trip_currency BEFORE INSERT OR UPDATE OF currency ON ops.trip FOR EACH ROW EXECUTE FUNCTION ops.tg_trip_currency();

-- ------------------------------------------------------------------ counter cash per market
-- The default cash limit of the CASH_COUNTER option is in the default market's currency; a carrier of another market
-- sells for cash only once platform administration gives it its own limit
CREATE OR REPLACE FUNCTION fin.cash_limit(p_company bigint) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce((SELECT l.limit_amount FROM fin.cash_credit_limit l WHERE l.company_id = p_company),
                  CASE WHEN (ref.party_market(p_company)).is_default
                       THEN (SELECT (m.config ->> 'default_credit_limit')::bigint FROM fin.payment_method m WHERE m.code = 'CASH_COUNTER') END,
                  0)
$$;
COMMENT ON FUNCTION fin.cash_limit IS 'The carrier''s cash credit limit: its own, or (default market only) the default of the CASH_COUNTER option (1056, 1061)';

-- Cash owed per currency of each open market, labelled with the currency, so figures of two currencies never add up
CREATE OR REPLACE FUNCTION sys.finance_metrics() RETURNS TABLE (metric text, labels jsonb, value double precision)
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE cur char(3);
BEGIN
  FOR cur IN SELECT DISTINCT m.currency FROM ref.market m WHERE m.status = 'ACTIVE' ORDER BY 1 LOOP
    RETURN QUERY
      WITH a AS MATERIALIZED (SELECT * FROM fin.cash_aging(now(), cur)),      -- the ageing is computed once per scrape
           t AS (SELECT coalesce(sum(owed), 0)::float8 AS owed, coalesce(sum(overdue), 0)::float8 AS overdue,
                        count(*) FILTER (WHERE overdue > 0)::float8 AS overdue_carriers,
                        count(*) FILTER (WHERE credit_limit > 0 AND owed >= 0.9 * credit_limit)::float8 AS near_limit FROM a)
      SELECT x.metric, jsonb_build_object('currency', cur), x.value FROM t, LATERAL (VALUES
        ('masslak_cash_owed_minor'::text, t.owed), ('masslak_cash_overdue_minor', t.overdue),
        ('masslak_cash_overdue_carriers', t.overdue_carriers), ('masslak_cash_near_limit_carriers', t.near_limit)) AS x(metric, value);
  END LOOP;
END $$;
COMMENT ON FUNCTION sys.finance_metrics IS 'Finance metrics for the monitoring scrape: cash owed and overdue from counter sales, per currency (1057, 1061)';

-- ------------------------------------------------------------------ school absences: today in the operator's market
CREATE OR REPLACE FUNCTION sch.tg_absence_notice_rules() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE e record;
BEGIN
  SELECT en.student_id, c.company_id INTO e FROM sch.enrollment en JOIN sch.contract c ON c.id = en.contract_id
   WHERE en.id = NEW.enrollment_id;
  IF sys.ctx_scope() = 'PASSENGER' AND NOT sch.is_guardian(e.student_id) THEN
    RAISE EXCEPTION 'NOT_GUARDIAN: only the pupil''s guardian or the operator reports an absence' USING ERRCODE = 'P0001';
  END IF;
  NEW.reported_by_party_id := coalesce(NEW.reported_by_party_id, sys.ctx_party_id());
  IF NEW.absent_on < (now() AT TIME ZONE ref.company_tz(e.company_id))::date THEN
    RAISE EXCEPTION 'ABSENCE_IN_PAST: an absence is reported for today or a later day' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
COMMENT ON FUNCTION sch.tg_absence_notice_rules IS 'Absences: from the passenger portal only by a guardian of the pupil, for today or later in the operator''s market (1054, 1061)';

-- the platform's wallets of every open market (the default market's exist since the seed)
SELECT fin.ensure_platform_wallets(m.currency) FROM ref.market m WHERE m.status = 'ACTIVE';

INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('ref.market', '1A', 'E03')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;

INSERT INTO sys.schema_migration (version, description)
SELECT '1.40.0', 'Expert review stage D: markets with their time zone and currency; city time zones of Beirut and Amman'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.40.0');

SELECT sys.refresh_table_class();
