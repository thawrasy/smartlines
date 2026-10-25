-- =====================================================================
-- 1166: the miles programme (owner's note 19, wave 6)
--   * The programme's name and unit are settings of the platform (Masslak Miles, miles), in Arabic and English.
--   * A chart of miles per pair of stations (in either direction), on a route of the network or anywhere: a boarded
--     ticket between two stations of the chart earns its miles, times the member's tier multiplier; a ticket the chart
--     does not cover earns by the amount rules as before (1103).
--   * Award tickets: miles plus a fee and a reduced amount for a pair of stations, set by the platform; shown in the
--     first phase, redeemed only when the setting loyalty.award_redemption is on (it needs paying the carrier: the money
--     phase or an agreement with the carrier).
--   * Partners carry a contract number before they are active: carriers, banks, restaurants, rest stops, shops.
--     The partners corner shows them with their offers; a promoted partner is labelled so, and promoted display is a
--     setting, off in the first phase.
-- =====================================================================

-- ------------------------------------------------------------------ the programme's name and unit
ALTER TABLE pricing.loyalty_program ADD COLUMN IF NOT EXISTS name_ar text CHECK (length(btrim(name_ar)) BETWEEN 1 AND 80);
ALTER TABLE pricing.loyalty_program ADD COLUMN IF NOT EXISTS unit_en text NOT NULL DEFAULT 'miles' CHECK (length(btrim(unit_en)) BETWEEN 1 AND 30);
ALTER TABLE pricing.loyalty_program ADD COLUMN IF NOT EXISTS unit_ar text CHECK (length(btrim(unit_ar)) BETWEEN 1 AND 30);
COMMENT ON COLUMN pricing.loyalty_program.unit_en IS 'The unit members see, in English (miles by default; a setting of the platform, 1166)';
-- Arabic defaults written as escapes: the programme's name and its unit
UPDATE pricing.loyalty_program SET name_ar = U&'\0623\0645\064A\0627\0644 \0645\0633\0644\0643' WHERE name_ar IS NULL;
UPDATE pricing.loyalty_program SET unit_ar = U&'\0645\064A\0644' WHERE unit_ar IS NULL;

-- a tier's multiplier on chart miles (benefits.multiplier, 1 when absent)
CREATE OR REPLACE FUNCTION pricing.tier_multiplier(p_tier bigint) RETURNS numeric
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce((SELECT CASE WHEN (t.benefits ->> 'multiplier') ~ '^[0-9]+(\.[0-9]+)?$' THEN (t.benefits ->> 'multiplier')::numeric END
                     FROM pricing.loyalty_tier t WHERE t.id = p_tier), 1)
$$;

-- ------------------------------------------------------------------ the chart of miles
CREATE TABLE IF NOT EXISTS pricing.miles_chart (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  program_id        bigint NOT NULL REFERENCES pricing.loyalty_program(id),
  network_route_id  bigint REFERENCES net.network_route(id),
  from_station_id   bigint NOT NULL REFERENCES net.station(id),
  to_station_id     bigint NOT NULL REFERENCES net.station(id),
  miles             bigint NOT NULL CHECK (miles > 0),
  valid             daterange NOT NULL DEFAULT daterange(current_date, NULL),
  status            text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'RETIRED')),
  created_by        bigint REFERENCES iam.app_user(id),
  created_at        timestamptz NOT NULL DEFAULT now(),
  CHECK (from_station_id <> to_station_id),
  CHECK (NOT isempty(valid) AND NOT lower_inf(valid))
);
CREATE UNIQUE INDEX IF NOT EXISTS miles_chart_pair ON pricing.miles_chart
  (program_id, least(from_station_id, to_station_id), greatest(from_station_id, to_station_id)) WHERE status = 'ACTIVE';
CREATE INDEX IF NOT EXISTS miles_chart_network_route_id_fkx ON pricing.miles_chart (network_route_id);
CREATE INDEX IF NOT EXISTS miles_chart_from_station_id_fkx ON pricing.miles_chart (from_station_id);
CREATE INDEX IF NOT EXISTS miles_chart_to_station_id_fkx ON pricing.miles_chart (to_station_id);
CREATE INDEX IF NOT EXISTS miles_chart_created_by_fkx ON pricing.miles_chart (created_by);
COMMENT ON TABLE pricing.miles_chart IS 'Miles a boarded ticket earns between two stations, in either direction, optionally on a route of the network (1166)';

-- the miles of the chart between two stations on a day, or NULL
CREATE OR REPLACE FUNCTION pricing.chart_miles(p_program bigint, p_from bigint, p_to bigint, p_on date) RETURNS bigint
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT c.miles FROM pricing.miles_chart c
   WHERE c.program_id = p_program AND c.status = 'ACTIVE' AND c.valid @> p_on
     AND least(c.from_station_id, c.to_station_id) = least(p_from, p_to)
     AND greatest(c.from_station_id, c.to_station_id) = greatest(p_from, p_to)
   LIMIT 1
$$;

-- ------------------------------------------------------------------ award tickets
CREATE TABLE IF NOT EXISTS pricing.award_fare (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid              uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  program_id       bigint NOT NULL REFERENCES pricing.loyalty_program(id),
  company_id       bigint REFERENCES iam.company(id),                  -- one carrier, or any carrier when empty
  from_station_id  bigint NOT NULL REFERENCES net.station(id),
  to_station_id    bigint NOT NULL REFERENCES net.station(id),
  miles            bigint NOT NULL CHECK (miles > 0),
  fee              bigint NOT NULL DEFAULT 0 CHECK (fee >= 0),         -- minor units, paid with the miles
  reduced_amount   bigint NOT NULL DEFAULT 0 CHECK (reduced_amount >= 0),
  currency         char(3) NOT NULL DEFAULT 'SYP' REFERENCES ref.currency(code),
  seats_per_trip   integer CHECK (seats_per_trip IS NULL OR seats_per_trip > 0),
  valid            daterange NOT NULL DEFAULT daterange(current_date, NULL),
  status           text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'RETIRED')),
  created_by       bigint REFERENCES iam.app_user(id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  CHECK (from_station_id <> to_station_id),
  CHECK (NOT isempty(valid) AND NOT lower_inf(valid))
);
CREATE INDEX IF NOT EXISTS award_fare_program_id_fkx ON pricing.award_fare (program_id);
CREATE INDEX IF NOT EXISTS award_fare_company_id_fkx ON pricing.award_fare (company_id);
CREATE INDEX IF NOT EXISTS award_fare_from_station_id_fkx ON pricing.award_fare (from_station_id);
CREATE INDEX IF NOT EXISTS award_fare_to_station_id_fkx ON pricing.award_fare (to_station_id);
CREATE INDEX IF NOT EXISTS award_fare_created_by_fkx ON pricing.award_fare (created_by);
CREATE INDEX IF NOT EXISTS award_fare_currency_fkx ON pricing.award_fare (currency);
COMMENT ON TABLE pricing.award_fare IS 'An award ticket between two stations: miles plus a fee and a reduced amount; redeemed only while loyalty.award_redemption is on (1166)';

-- ------------------------------------------------------------------ partners and the corner
ALTER TABLE pricing.loyalty_partner DROP CONSTRAINT IF EXISTS loyalty_partner_partner_type_check;
ALTER TABLE pricing.loyalty_partner ADD CONSTRAINT loyalty_partner_partner_type_check
  CHECK (partner_type IN ('CARRIER', 'BANK', 'RESTAURANT', 'REST_STOP', 'SHOP', 'FUEL', 'RETAIL', 'AIRLINE', 'TRAVEL', 'OTHER'));
ALTER TABLE pricing.loyalty_partner ADD COLUMN IF NOT EXISTS corner_note text CHECK (length(corner_note) <= 300);
ALTER TABLE pricing.loyalty_partner ADD COLUMN IF NOT EXISTS promoted boolean NOT NULL DEFAULT false;
ALTER TABLE pricing.loyalty_partner ADD COLUMN IF NOT EXISTS promoted_until date;
COMMENT ON COLUMN pricing.loyalty_partner.promoted IS 'Shown first in the partners corner with the label Promoted, while loyalty.promoted_display is on (1166)';

-- a partner becomes active only with its contract number
CREATE OR REPLACE FUNCTION pricing.tg_loyalty_partner_contract() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.status = 'ACTIVE' AND length(btrim(coalesce(NEW.contract_ref, ''))) < 3
     AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'ACTIVE' OR NEW.contract_ref IS DISTINCT FROM OLD.contract_ref) THEN
    RAISE EXCEPTION 'PARTNER_CONTRACT_REQUIRED: a partner is active only with its contract number' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS loyalty_partner_contract ON pricing.loyalty_partner;
CREATE TRIGGER loyalty_partner_contract BEFORE INSERT OR UPDATE ON pricing.loyalty_partner
  FOR EACH ROW EXECUTE FUNCTION pricing.tg_loyalty_partner_contract();

INSERT INTO sys.setting (key, value, scope, description) VALUES
  ('loyalty.award_redemption', 'false'::jsonb, 'PLATFORM',
   'Award tickets can be redeemed for miles (1166); off in the first phase: redeeming needs paying the carrier'),
  ('loyalty.promoted_display', 'false'::jsonb, 'PLATFORM',
   'Promoted partners are shown first in the partners corner, labelled Promoted (1166); off in the first phase')
ON CONFLICT (key) DO NOTHING;

SELECT sys.rls('pricing.miles_chart', 'true', 'sys.ctx_is_platform()');
SELECT sys.rls('pricing.award_fare', 'true', 'sys.ctx_is_platform()');
GRANT SELECT, INSERT, UPDATE ON pricing.miles_chart, pricing.award_fare TO masslak_app;
GRANT SELECT ON pricing.miles_chart, pricing.award_fare TO masslak_readonly;
DROP TRIGGER IF EXISTS zz_audit_capture ON pricing.miles_chart;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR UPDATE OR DELETE ON pricing.miles_chart FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();
DROP TRIGGER IF EXISTS zz_audit_capture ON pricing.award_fare;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR UPDATE OR DELETE ON pricing.award_fare FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();

-- ------------------------------------------------------------------ earning: the chart first, then the amount rules
CREATE OR REPLACE FUNCTION pricing.earn_points_for_trip(p_trip_id bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v_trip record;
  v_b record;
  v_r record;
  v_g record;
  v_account bigint;
  v_tier bigint;
  v_points bigint;
  v_ledger bigint;
  v_awarded integer := 0;
  v_total bigint := 0;
  v_earned bigint;
  v_chart bigint;
BEGIN
  SELECT id, company_id, trip_no, status, service_date INTO v_trip FROM ops.trip WHERE id = p_trip_id;
  IF v_trip.status IS DISTINCT FROM 'COMPLETED' THEN
    RETURN jsonb_build_object('bookings', 0, 'points', 0);
  END IF;
  FOR v_b IN
    SELECT b.id, b.booker_party_id, b.booker_user_id, b.currency,
           (SELECT coalesce(sum(k.total_amount), 0) FROM sales.ticket k WHERE k.booking_id = b.id AND k.status = 'BOARDED') AS travelled
      FROM sales.booking b JOIN iam.party p ON p.id = b.booker_party_id
     WHERE b.trip_id = p_trip_id AND b.status = 'COMPLETED' AND b.agency_id IS NULL AND p.party_type = 'PERSON'
  LOOP
    v_earned := 0;
    -- the chart of miles: every boarded ticket between two stations of the chart, times the member's tier
    FOR v_g IN SELECT g.id, g.point_value, g.expiry_months FROM pricing.loyalty_program g
                WHERE g.status = 'ACTIVE' AND g.currency = v_b.currency ORDER BY g.id LOOP
      SELECT coalesce(sum(pricing.chart_miles(v_g.id, fs.station_id, ts.station_id, v_trip.service_date)), 0) INTO v_chart
        FROM sales.ticket k
        JOIN ops.trip_stop fs ON fs.trip_id = p_trip_id AND fs.seq = k.from_seq
        JOIN ops.trip_stop ts ON ts.trip_id = p_trip_id AND ts.seq = k.to_seq
       WHERE k.booking_id = v_b.id AND k.status = 'BOARDED';
      CONTINUE WHEN v_chart <= 0;
      INSERT INTO pricing.points_account (program_id, party_id) VALUES (v_g.id, v_b.booker_party_id)
      ON CONFLICT (program_id, party_id) DO NOTHING;
      SELECT id, tier_id INTO v_account, v_tier FROM pricing.points_account
       WHERE program_id = v_g.id AND party_id = v_b.booker_party_id AND status = 'ACTIVE';
      CONTINUE WHEN v_account IS NULL;
      v_points := floor(v_chart * pricing.tier_multiplier(v_tier));
      INSERT INTO pricing.points_ledger (account_id, txn_type, points, booking_id, rule_id, funded_by, idempotency_key, expires_at)
      VALUES (v_account, 'EARN', v_points, v_b.id, NULL, 'PLATFORM', format('earn:%s:chart:%s', v_b.id, v_g.id),
              now() + make_interval(months => v_g.expiry_months))
      ON CONFLICT (idempotency_key) DO NOTHING RETURNING id INTO v_ledger;
      CONTINUE WHEN v_ledger IS NULL;
      UPDATE pricing.points_account a
         SET balance = a.balance + v_points,
             tier_id = (SELECT t.id FROM pricing.loyalty_tier t WHERE t.program_id = a.program_id
                           AND t.min_points <= (SELECT coalesce(sum(l.points), 0) FROM pricing.points_ledger l
                                                 WHERE l.account_id = a.id AND l.txn_type = 'EARN')
                         ORDER BY t.min_points DESC LIMIT 1)
       WHERE a.id = v_account;
      PERFORM pricing.add_liability(v_g.id, NULL, 'ISSUED', v_points * v_g.point_value);
      v_earned := v_earned + v_points;
    END LOOP;
    -- the amount rules, for a booking the chart does not cover (1103)
    IF v_earned = 0 THEN
      FOR v_r IN
        SELECT r.id AS rule_id, r.formula, r.condition, r.funded_by, g.id AS program_id, g.point_value, g.expiry_months
          FROM pricing.loyalty_rule r JOIN pricing.loyalty_program g ON g.id = r.program_id
         WHERE g.status = 'ACTIVE' AND g.currency = v_b.currency AND r.kind = 'EARN' AND r.active AND r.valid @> now()
           AND v_b.travelled >= coalesce((r.condition ->> 'min_amount')::bigint, 0)
           AND (NOT r.condition ? 'company_ids' OR r.condition -> 'company_ids' @> to_jsonb(v_trip.company_id))
         ORDER BY r.id
      LOOP
        v_points := floor(v_b.travelled / greatest(coalesce((v_r.formula ->> 'per_amount')::bigint, 1), 1))
                    * coalesce((v_r.formula ->> 'points')::bigint, 0) * coalesce((v_r.formula ->> 'multiplier')::numeric, 1);
        CONTINUE WHEN v_points <= 0;
        INSERT INTO pricing.points_account (program_id, party_id) VALUES (v_r.program_id, v_b.booker_party_id)
        ON CONFLICT (program_id, party_id) DO NOTHING;
        SELECT id INTO v_account FROM pricing.points_account
         WHERE program_id = v_r.program_id AND party_id = v_b.booker_party_id AND status = 'ACTIVE';
        CONTINUE WHEN v_account IS NULL;                      -- a frozen or closed account earns nothing
        INSERT INTO pricing.points_ledger (account_id, txn_type, points, booking_id, rule_id, funded_by, idempotency_key, expires_at)
        VALUES (v_account, 'EARN', v_points, v_b.id, v_r.rule_id, v_r.funded_by, format('earn:%s:%s', v_b.id, v_r.rule_id),
                now() + make_interval(months => v_r.expiry_months))
        ON CONFLICT (idempotency_key) DO NOTHING RETURNING id INTO v_ledger;
        CONTINUE WHEN v_ledger IS NULL;                       -- already earned
        UPDATE pricing.points_account a
           SET balance = a.balance + v_points,
               tier_id = (SELECT t.id FROM pricing.loyalty_tier t WHERE t.program_id = a.program_id
                             AND t.min_points <= (SELECT coalesce(sum(l.points), 0) FROM pricing.points_ledger l
                                                   WHERE l.account_id = a.id AND l.txn_type = 'EARN')
                           ORDER BY t.min_points DESC LIMIT 1)
         WHERE a.id = v_account;
        PERFORM pricing.add_liability(v_r.program_id, CASE WHEN v_r.funded_by = 'CARRIER' THEN v_trip.company_id END, 'ISSUED',
                                      v_points * v_r.point_value);
        v_earned := v_earned + v_points;
      END LOOP;
    END IF;
    IF v_earned > 0 THEN
      v_awarded := v_awarded + 1;
      v_total := v_total + v_earned;
      INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, company_id, payload)
      VALUES ('points.earned', 'booking', v_b.id, v_trip.company_id,
              jsonb_build_object('points', v_earned, 'trip_no', v_trip.trip_no, 'booker_user_id', v_b.booker_user_id,
                                 'balance', (SELECT sum(balance) FROM pricing.points_account WHERE party_id = v_b.booker_party_id)));
    END IF;
  END LOOP;
  RETURN jsonb_build_object('bookings', v_awarded, 'points', v_total);
END $$;

-- ------------------------------------------------------------------ registration
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('pricing.miles_chart', '1B', 'E15'), ('pricing.award_fare', '1B', 'E15')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
SELECT sys.refresh_table_class();
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('pricing.miles_chart', 'pricing records', 'miles per pair of stations (1166)'),
  ('pricing.award_fare', 'pricing records', 'award tickets: miles, fee and reduced amount per pair of stations (1166)')
ON CONFLICT (table_name) DO NOTHING;
