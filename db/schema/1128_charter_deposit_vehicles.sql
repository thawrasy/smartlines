-- =====================================================================
-- 1128  Charter paid in parts, and several vehicles of a hire named one by one (the open items of 1123)
-- =====================================================================
-- A carrier may ask for a deposit when a charter is accepted (charter_offer.deposit_pct, a share of the price) and the
-- rest a number of hours before the start (balance_hours). The offer's terms keep both, as they keep the rest. The
-- escrow holds what was paid (charter_request.paid_amount); the balance is paid from the same wallet before its time
-- (balance_due, balance_due_at, balance_txn_id). A charter is done only once paid in full; a cancellation refunds out
-- of what was paid; a carrier that cancels a charter whose balance is overdue refunds it as the customer's own late
-- cancellation.
-- A vehicle hire of several vehicles names each of them (sales.charter_vehicle). A vehicle is not named on a hire while
-- it runs a trip or another hire at the same time, and a trip is not given a vehicle hired out at its time: the hire is
-- on the vehicle's schedule (sales.vehicle_hired).

ALTER TABLE sales.charter_offer ADD COLUMN IF NOT EXISTS deposit_pct smallint NOT NULL DEFAULT 0 CHECK (deposit_pct BETWEEN 0 AND 90);
ALTER TABLE sales.charter_offer ADD COLUMN IF NOT EXISTS balance_hours smallint NOT NULL DEFAULT 48 CHECK (balance_hours BETWEEN 0 AND 2160);
COMMENT ON COLUMN sales.charter_offer.deposit_pct IS 'The share of the price paid on acceptance; the rest before the start. 0: paid in full on acceptance (1128)';
COMMENT ON COLUMN sales.charter_offer.balance_hours IS 'How many hours before the start the balance is due (1128)';

ALTER TABLE sales.charter_request ADD COLUMN IF NOT EXISTS paid_amount bigint CHECK (paid_amount >= 0);
ALTER TABLE sales.charter_request ADD COLUMN IF NOT EXISTS balance_due bigint NOT NULL DEFAULT 0 CHECK (balance_due >= 0);
ALTER TABLE sales.charter_request ADD COLUMN IF NOT EXISTS balance_due_at timestamptz;
ALTER TABLE sales.charter_request ADD COLUMN IF NOT EXISTS balance_txn_id bigint REFERENCES fin.ledger_txn(id);
ALTER TABLE sales.charter_request ADD COLUMN IF NOT EXISTS balance_paid_at timestamptz;
CREATE INDEX IF NOT EXISTS charter_request_balance_txn_id_fkx ON sales.charter_request (balance_txn_id);
CREATE INDEX IF NOT EXISTS charter_request_balance_due_ix ON sales.charter_request (balance_due_at) WHERE balance_due > 0 AND status = 'CONFIRMED';
COMMENT ON COLUMN sales.charter_request.paid_amount IS 'What the escrow holds for this charter: the deposit, then the whole price (1128)';
COMMENT ON COLUMN sales.charter_request.balance_due IS 'The part of the price still to pay before balance_due_at (1128)';
UPDATE sales.charter_request SET paid_amount = price WHERE paid_amount IS NULL AND paid_txn_id IS NOT NULL;
ALTER TABLE sales.charter_request DROP CONSTRAINT IF EXISTS charter_request_balance_ck;
ALTER TABLE sales.charter_request ADD CONSTRAINT charter_request_balance_ck CHECK (
  (paid_txn_id IS NULL OR paid_amount IS NOT NULL)
  AND (balance_due = 0 OR balance_due_at IS NOT NULL)
  AND (status <> 'COMPLETED' OR balance_due = 0)
  AND (paid_amount IS NULL OR price IS NULL OR paid_amount + balance_due = price OR status IN ('CANCELLED', 'COMPLETED')));

-- the vehicles of a hire
CREATE TABLE IF NOT EXISTS sales.charter_vehicle (
  request_id  bigint NOT NULL REFERENCES sales.charter_request(id),
  vehicle_id  bigint NOT NULL REFERENCES fleet.vehicle(id),
  named_by    bigint REFERENCES iam.app_user(id),
  named_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (request_id, vehicle_id)
);
CREATE INDEX IF NOT EXISTS charter_vehicle_vehicle_id_fkx ON sales.charter_vehicle (vehicle_id);
CREATE INDEX IF NOT EXISTS charter_vehicle_named_by_fkx ON sales.charter_vehicle (named_by);
COMMENT ON TABLE sales.charter_vehicle IS 'The vehicles a carrier names on a vehicle hire, one by one (1128)';
SELECT sys.rls_parent('sales.charter_vehicle', 'request_id', 'sales.charter_request');
GRANT SELECT, INSERT, DELETE ON sales.charter_vehicle TO masslak_app;
INSERT INTO sys.app_delete_grant (table_name, reason) VALUES
  ('sales.charter_vehicle', 'a carrier takes a vehicle off a vehicle hire before it starts')
ON CONFLICT (table_name) DO NOTHING;
GRANT SELECT ON sales.charter_vehicle TO masslak_readonly, masslak_auditor;
INSERT INTO sales.charter_vehicle (request_id, vehicle_id)
SELECT id, vehicle_id FROM sales.charter_request WHERE vehicle_id IS NOT NULL ON CONFLICT DO NOTHING;

-- a vehicle hired out from a time to a time, other than by the request given
CREATE OR REPLACE FUNCTION sales.vehicle_hired(p_vehicle bigint, p_from timestamptz, p_to timestamptz, p_except bigint DEFAULT NULL)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT r.ref FROM sales.charter_vehicle cv JOIN sales.charter_request r ON r.id = cv.request_id
   WHERE cv.vehicle_id = p_vehicle AND r.id IS DISTINCT FROM p_except AND r.status IN ('QUOTED', 'CONFIRMED')
     AND tstzrange(r.starts_at, r.ends_at) && tstzrange(p_from, p_to)
   LIMIT 1
$$;
REVOKE ALL ON FUNCTION sales.vehicle_hired(bigint, timestamptz, timestamptz, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sales.vehicle_hired(bigint, timestamptz, timestamptz, bigint) TO masslak_app;
COMMENT ON FUNCTION sales.vehicle_hired IS 'The hire a vehicle is named on at some moment of a period, if any (1128)';

-- a trip is not given a vehicle hired out at its time
CREATE OR REPLACE FUNCTION ops.tg_trip_vehicle_hired() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_ref text;
BEGIN
  IF NEW.vehicle_id IS NULL OR NEW.status IN ('CANCELLED', 'COMPLETED') THEN RETURN NEW; END IF;
  v_ref := sales.vehicle_hired(NEW.vehicle_id, NEW.departure_at, coalesce(NEW.arrival_at, NEW.departure_at + interval '1 hour'));
  IF v_ref IS NOT NULL THEN
    RAISE EXCEPTION 'VEHICLE_HIRED: the vehicle is hired out at that time (%)', v_ref USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trip_vehicle_hired ON ops.trip;
CREATE TRIGGER trip_vehicle_hired BEFORE INSERT OR UPDATE OF vehicle_id, departure_at, arrival_at ON ops.trip
  FOR EACH ROW EXECUTE FUNCTION ops.tg_trip_vehicle_hired();

INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('sales.charter_vehicle', '1B', 'E11')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
SELECT sys.apply_phase_gates();
SELECT sys.refresh_table_class();
SELECT sys.enforce_app_delete_grants();
INSERT INTO gov.dataset_member (table_name, dataset, note) VALUES
  ('sales.charter_vehicle', 'sales records', 'the vehicles named on a vehicle hire (1128)')
ON CONFLICT (table_name) DO NOTHING;
