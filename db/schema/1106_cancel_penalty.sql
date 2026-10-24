-- =====================================================================
-- Masslak - 1106: a penalty on the carrier for a cancelled trip, only when the regulators impose one (owner's decision,
-- October 2026)
--
-- A carrier that cancels a trip refunds every passenger in full (1102). A penalty on the carrier applies only where the
-- competent authorities impose one; the platform then turns it on in its settings, citing the regulator's decision:
--   trip.cancel_penalty = {"enabled": true, "basis": "PERCENT_OF_FARES" | "PER_TICKET" | "PER_TRIP", "value": n,
--                          "payee": "PLATFORM" | "PASSENGERS" | "AUTHORITY", "authority_party_id": id (for AUTHORITY),
--                          "within_hours": n (only for a cancellation this close to departure; null: any), "legal_ref": "..."}
--   PERCENT_OF_FARES takes value percent of the fares refunded; PER_TICKET value minor units per refunded ticket;
--   PER_TRIP value minor units once. PASSENGERS shares it among the refunded bookings by their fares, paid to the
--   wallet each booking was paid from; AUTHORITY pays the named party (a regulator's account); PLATFORM keeps it.
-- The penalty is recorded with the trip (ops.trip_cancel_penalty) and taken from the carrier's balance at once when
-- the balance covers it; otherwise it stays DUE and is set off from the carrier's next released earnings (the trip
-- completion). Off at launch: nothing changes until the platform turns it on.
-- =====================================================================

INSERT INTO sys.setting (key, value, scope, description) VALUES
  ('trip.cancel_penalty', '{"enabled": false}'::jsonb, 'PLATFORM',
   'Penalty on a carrier that cancels a trip, only where the regulators impose one; off at launch (1106)')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION ops.set_cancel_penalty(p_value jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_value numeric;
BEGIN
  IF NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'FORBIDDEN: the cancellation penalty is a platform setting' USING ERRCODE = 'P0001';
  END IF;
  IF jsonb_typeof(p_value -> 'enabled') IS DISTINCT FROM 'boolean' THEN
    RAISE EXCEPTION 'INVALID_SETTING: enabled is true or false' USING ERRCODE = 'P0001';
  END IF;
  IF (p_value ->> 'enabled')::boolean THEN
    IF p_value ->> 'basis' IS NULL OR p_value ->> 'basis' NOT IN ('PERCENT_OF_FARES', 'PER_TICKET', 'PER_TRIP') THEN
      RAISE EXCEPTION 'INVALID_SETTING: basis is PERCENT_OF_FARES, PER_TICKET or PER_TRIP' USING ERRCODE = 'P0001';
    END IF;
    IF jsonb_typeof(p_value -> 'value') IS DISTINCT FROM 'number' THEN
      RAISE EXCEPTION 'INVALID_SETTING: value is a number' USING ERRCODE = 'P0001';
    END IF;
    v_value := (p_value ->> 'value')::numeric;
    IF v_value <= 0 OR (p_value ->> 'basis' = 'PERCENT_OF_FARES' AND v_value > 100)
       OR (p_value ->> 'basis' <> 'PERCENT_OF_FARES' AND v_value <> trunc(v_value)) THEN
      RAISE EXCEPTION 'INVALID_SETTING: a percentage is above 0 and at most 100; an amount is a whole number of minor units' USING ERRCODE = 'P0001';
    END IF;
    IF p_value ->> 'payee' IS NULL OR p_value ->> 'payee' NOT IN ('PLATFORM', 'PASSENGERS', 'AUTHORITY') THEN
      RAISE EXCEPTION 'INVALID_SETTING: payee is PLATFORM, PASSENGERS or AUTHORITY' USING ERRCODE = 'P0001';
    END IF;
    IF p_value ->> 'payee' = 'AUTHORITY' AND NOT EXISTS (
         SELECT 1 FROM iam.party WHERE id = (CASE WHEN jsonb_typeof(p_value -> 'authority_party_id') = 'number'
                                                  THEN (p_value ->> 'authority_party_id')::bigint END)) THEN
      RAISE EXCEPTION 'INVALID_SETTING: an AUTHORITY payee names the party that receives the penalty' USING ERRCODE = 'P0001';
    END IF;
    IF p_value ? 'within_hours' AND p_value -> 'within_hours' <> 'null'::jsonb
       AND NOT (jsonb_typeof(p_value -> 'within_hours') = 'number' AND (p_value ->> 'within_hours')::numeric BETWEEN 0 AND 720) THEN
      RAISE EXCEPTION 'INVALID_SETTING: within_hours is between 0 and 720, or null' USING ERRCODE = 'P0001';
    END IF;
    IF length(btrim(coalesce(p_value ->> 'legal_ref', ''))) NOT BETWEEN 3 AND 120 THEN
      RAISE EXCEPTION 'INVALID_SETTING: legal_ref names the regulator''s decision that imposes the penalty' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  INSERT INTO sys.setting (key, value, scope, description, updated_by, updated_at)
  VALUES ('trip.cancel_penalty', p_value, 'PLATFORM', 'Penalty on a carrier that cancels a trip (1106)', sys.ctx_user_id(), now())
  ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  RETURN p_value;
END $$;
REVOKE ALL ON FUNCTION ops.set_cancel_penalty(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.set_cancel_penalty(jsonb) TO masslak_app;
COMMENT ON FUNCTION ops.set_cancel_penalty IS 'Checks and stores the cancellation penalty setting; platform only (1106)';

CREATE TABLE IF NOT EXISTS ops.trip_cancel_penalty (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uid               uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  trip_id           bigint NOT NULL UNIQUE REFERENCES ops.trip(id),
  company_id        bigint NOT NULL REFERENCES iam.company(id),
  currency          char(3) NOT NULL REFERENCES ref.currency(code),
  amount            bigint NOT NULL CHECK (amount > 0),
  basis             text NOT NULL CHECK (basis IN ('PERCENT_OF_FARES', 'PER_TICKET', 'PER_TRIP')),
  rate              numeric(12,4) NOT NULL,
  payee             text NOT NULL CHECK (payee IN ('PLATFORM', 'PASSENGERS', 'AUTHORITY')),
  payee_party_id    bigint REFERENCES iam.party(id),
  shares            jsonb NOT NULL DEFAULT '[]',          -- PASSENGERS: [{"booking_id", "wallet_id", "amount"}]
  legal_ref         text NOT NULL CHECK (length(legal_ref) BETWEEN 3 AND 120),
  status            text NOT NULL DEFAULT 'DUE' CHECK (status IN ('DUE', 'COLLECTED', 'WAIVED')),
  created_at        timestamptz NOT NULL DEFAULT now(),
  collected_at      timestamptz,
  CHECK ((status = 'COLLECTED') = (collected_at IS NOT NULL)),
  CHECK ((payee = 'AUTHORITY') = (payee_party_id IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS trip_cancel_penalty_company_id_fkx ON ops.trip_cancel_penalty (company_id, status);
CREATE INDEX IF NOT EXISTS trip_cancel_penalty_payee_party_id_fkx ON ops.trip_cancel_penalty (payee_party_id);
COMMENT ON TABLE ops.trip_cancel_penalty IS 'Penalty charged to a carrier for a cancelled trip under the regulators'' rule; DUE until set off from its balance (1106)';
SELECT sys.rls_tenant('ops.trip_cancel_penalty');
GRANT SELECT, INSERT ON ops.trip_cancel_penalty TO masslak_app;
GRANT UPDATE (status, collected_at) ON ops.trip_cancel_penalty TO masslak_app;
GRANT SELECT ON ops.trip_cancel_penalty TO masslak_readonly;

INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('ops.trip_cancel_penalty', '1A', 'E09')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
INSERT INTO sys.table_class (table_name, data_class, tenant_path, note) VALUES
  ('ops.trip_cancel_penalty', 'TENANT_PRIVATE', 'company_id', 'penalties charged to carriers for cancelled trips (1106)')
ON CONFLICT (table_name) DO UPDATE SET data_class = excluded.data_class, tenant_path = excluded.tenant_path, note = excluded.note;
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('ops.trip_cancel_penalty', 'ops records', 'the cancellation penalties of carriers (1106)')
ON CONFLICT (table_name) DO NOTHING;

-- the money transaction of a penalty names the penalty it collects
UPDATE sys.polymorphic_reference SET targets = targets || '{"trip_cancel_penalty": "ops.trip_cancel_penalty"}'::jsonb
 WHERE table_name = 'fin.ledger_txn' AND NOT targets ? 'trip_cancel_penalty';

INSERT INTO sys.json_contract (table_name, column_name, kind, version, spec, note) VALUES
  ('ops.trip_cancel_penalty', 'shares', 'SNAPSHOT', 1, '{"type": "array"}'::jsonb,
   'the passengers'' shares of a penalty paid to them: booking, paying wallet and amount, fixed when charged (1106)')
ON CONFLICT DO NOTHING;
SELECT sys.apply_json_contracts();
