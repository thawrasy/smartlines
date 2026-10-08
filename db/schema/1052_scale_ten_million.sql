-- =====================================================================
-- 1052: the database at ten million operations a day (docs/operations/CAPACITY_MODEL.md)
--   A  No shared wallet row on the money path. Wallets that many transactions credit at once (carriers, agencies, the
--      platform's fee, tax, escrow and clearing wallets) keep their balance in DEFERRED mode: a posting appends its
--      entry and touches no wallet row; a roll-up job folds the entries into the stored balance every few seconds.
--      The balance that counts (fin.wallet_balance) is the stored balance plus the entries not yet rolled up. A debit
--      of such a wallet that must not go negative still queues on the wallet and checks that balance. Passenger and
--      family wallets stay IMMEDIATE (each has one owner, and spending needs the exact balance at once).
--   B  Ledger entries partitioned by month. Each closed day is totalled per wallet (fin.ledger_day_total) with a
--      running total, and nothing can be posted into a closed day; the daily reconciliation compares every wallet
--      with its last running total plus the open days only, instead of re-reading the whole ledger.
--   C  The latest position of every vehicle in its own row (ops.vehicle_position), kept by the insert of positions, so
--      live maps and dashboards never search the position history.
--   D  Storage settings per partitioned table (sys.partition_option), applied to every new partition.
--   E  Audit at volume: a wallet change made only by a posting is not copied to the change log (the ledger entry is
--      the record); audit partitions older than the online window are dropped once the signed archive covers them.
-- =====================================================================

-- =====================================================================
-- A  wallets: balance mode
-- =====================================================================
ALTER TABLE fin.wallet ADD COLUMN IF NOT EXISTS balance_mode text;
ALTER TABLE fin.wallet ADD COLUMN IF NOT EXISTS rolled_xid xid8 NOT NULL DEFAULT '0'::xid8;
ALTER TABLE fin.wallet ADD COLUMN IF NOT EXISTS rolled_at timestamptz;
UPDATE fin.wallet SET balance_mode = CASE WHEN wallet_type IN ('USER', 'FAMILY') THEN 'IMMEDIATE' ELSE 'DEFERRED' END
 WHERE balance_mode IS NULL;
ALTER TABLE fin.wallet ALTER COLUMN balance_mode SET NOT NULL;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'fin.wallet'::regclass AND conname = 'wallet_balance_mode_check') THEN
    ALTER TABLE fin.wallet ADD CONSTRAINT wallet_balance_mode_check CHECK (balance_mode IN ('IMMEDIATE', 'DEFERRED'));
  END IF;
  -- the stored balance of a DEFERRED wallet lags its entries; its limits are checked against fin.wallet_balance instead
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'fin.wallet'::regclass AND conname = 'wallet_check') THEN
    ALTER TABLE fin.wallet DROP CONSTRAINT wallet_check;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'fin.wallet'::regclass AND conname = 'wallet_check1') THEN
    ALTER TABLE fin.wallet DROP CONSTRAINT wallet_check1;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'fin.wallet'::regclass AND conname = 'wallet_balance_not_negative') THEN
    ALTER TABLE fin.wallet ADD CONSTRAINT wallet_balance_not_negative CHECK (allow_negative OR balance_mode = 'DEFERRED' OR balance >= 0);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'fin.wallet'::regclass AND conname = 'wallet_hold_within_balance') THEN
    ALTER TABLE fin.wallet ADD CONSTRAINT wallet_hold_within_balance
      CHECK (allow_negative OR balance_mode = 'DEFERRED' OR hold_balance <= balance);
  END IF;
END $$;
COMMENT ON COLUMN fin.wallet.balance_mode IS 'IMMEDIATE: every entry updates the balance at once (passenger and family wallets). DEFERRED: entries are appended without touching this row and folded in by fin.roll_up_balances; the balance that counts is fin.wallet_balance(id) (CAPACITY_MODEL.md)';
COMMENT ON COLUMN fin.wallet.rolled_xid IS 'DEFERRED wallets: entries written by transactions below this id are included in balance';
COMMENT ON COLUMN fin.wallet.rolled_at IS 'DEFERRED wallets: when the roll-up last folded entries into balance';
-- many concurrent single-owner updates of passenger wallets stay on the same page (HOT updates)
ALTER TABLE fin.wallet SET (fillfactor = 80);

CREATE OR REPLACE FUNCTION fin.tg_wallet_defaults() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.balance_mode IS NULL THEN
    NEW.balance_mode := CASE WHEN NEW.wallet_type IN ('USER', 'FAMILY') THEN 'IMMEDIATE' ELSE 'DEFERRED' END;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS wallet_defaults ON fin.wallet;
CREATE TRIGGER wallet_defaults BEFORE INSERT ON fin.wallet FOR EACH ROW EXECUTE FUNCTION fin.tg_wallet_defaults();

-- =====================================================================
-- B  ledger entries partitioned by month (the table has no inbound references, so it is rebuilt in place)
-- =====================================================================
CREATE TABLE IF NOT EXISTS sys.partition_option (
  parent  text PRIMARY KEY,
  options text[] NOT NULL CHECK (cardinality(options) > 0),
  reason  text NOT NULL
);
COMMENT ON TABLE sys.partition_option IS 'Storage settings (autovacuum, fillfactor) applied to every new partition of a partitioned table, since a partitioned parent cannot carry them (CAPACITY_MODEL.md)';
SELECT sys.rls('sys.partition_option', 'sys.ctx_is_platform()');
INSERT INTO sys.partition_option (parent, options, reason) VALUES
  ('ops.geo_event', '{autovacuum_vacuum_insert_scale_factor=0.05,autovacuum_analyze_scale_factor=0.02}',
   'Insert-only daily partitions: keep the visibility map and statistics current while they fill'),
  ('fin.ledger_entry', '{autovacuum_vacuum_insert_scale_factor=0.05,autovacuum_analyze_scale_factor=0.02}',
   'Insert-only monthly partitions of the ledger'),
  ('audit.row_change', '{autovacuum_vacuum_insert_scale_factor=0.05,autovacuum_analyze_scale_factor=0.05}', 'Insert-only audit partitions'),
  ('audit.activity_log', '{autovacuum_vacuum_insert_scale_factor=0.05,autovacuum_analyze_scale_factor=0.05}', 'Insert-only audit partitions'),
  ('audit.data_access_log', '{autovacuum_vacuum_insert_scale_factor=0.05,autovacuum_analyze_scale_factor=0.05}', 'Insert-only audit partitions'),
  ('audit.auth_event', '{autovacuum_vacuum_insert_scale_factor=0.05,autovacuum_analyze_scale_factor=0.05}', 'Insert-only audit partitions')
ON CONFLICT (parent) DO UPDATE SET options = EXCLUDED.options, reason = EXCLUDED.reason;

CREATE OR REPLACE FUNCTION sys.apply_partition_options(p_partition text, p_parent text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE opts text[] := (SELECT options FROM sys.partition_option WHERE parent = p_parent);
BEGIN
  IF opts IS NOT NULL THEN
    EXECUTE format('ALTER TABLE %s SET (%s)', p_partition, array_to_string(opts, ', '));
  END IF;
END $$;

CREATE OR REPLACE FUNCTION sys.ensure_monthly_partitions(p_parent text, p_months_ahead integer DEFAULT 3, p_months_back integer DEFAULT 1)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE m date; part text; sch text := split_part(p_parent, '.', 1); tbl text := split_part(p_parent, '.', 2);
BEGIN
  FOR m IN SELECT generate_series(date_trunc('month', now()) - make_interval(months => p_months_back),
                                  date_trunc('month', now()) + make_interval(months => p_months_ahead),
                                  interval '1 month')::date LOOP
    part := format('%I.%I', sch, tbl || '_' || to_char(m, 'YYYYMM'));
    IF to_regclass(part) IS NULL THEN
      EXECUTE format('CREATE TABLE %s PARTITION OF %s FOR VALUES FROM (%L) TO (%L)',
                     part, p_parent, m, (m + interval '1 month')::date);
      PERFORM sys.apply_partition_options(part, p_parent);
    END IF;
  END LOOP;
  part := format('%I.%I', sch, tbl || '_default');
  IF to_regclass(part) IS NULL THEN
    EXECUTE format('CREATE TABLE %s PARTITION OF %s DEFAULT', part, p_parent);
  END IF;
END $$;

CREATE OR REPLACE FUNCTION sys.ensure_daily_partitions(p_parent text, p_days_ahead int DEFAULT 7, p_days_back int DEFAULT 1)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE d date; part text; sch text := split_part(p_parent, '.', 1); tbl text := split_part(p_parent, '.', 2);
BEGIN
  FOR d IN SELECT generate_series(current_date - p_days_back, current_date + p_days_ahead, interval '1 day')::date LOOP
    part := format('%I.%I', sch, tbl || '_' || to_char(d, 'YYYYMMDD'));
    IF to_regclass(part) IS NULL THEN
      EXECUTE format('CREATE TABLE %s PARTITION OF %s FOR VALUES FROM (%L) TO (%L)', part, p_parent, d, d + 1);
      PERFORM sys.apply_partition_options(part, p_parent);
    END IF;
  END LOOP;
  part := format('%I.%I', sch, tbl || '_default');
  IF to_regclass(part) IS NULL THEN
    EXECUTE format('CREATE TABLE %s PARTITION OF %s DEFAULT', part, p_parent);
  END IF;
END $$;

DO $$
DECLARE first_month date; months_back int; mx bigint; pol record; saved jsonb := '[]';
BEGIN
  IF (SELECT relkind FROM pg_class WHERE oid = 'fin.ledger_entry'::regclass) = 'p' THEN
    RETURN;                                   -- already converted
  END IF;
  -- policies of other tables that read the ledger entries (fin.ledger_txn) are set aside and recreated on the new table
  FOR pol IN SELECT p.polrelid::regclass::text AS tbl, p.polname, p.polcmd, p.polpermissive,
                    array_to_string(ARRAY(SELECT CASE WHEN r = 0 THEN 'PUBLIC' ELSE quote_ident(r::regrole::text) END
                                            FROM unnest(p.polroles) r), ', ') AS roles,
                    pg_get_expr(p.polqual, p.polrelid) AS qual, pg_get_expr(p.polwithcheck, p.polrelid) AS chk
               FROM pg_policy p
              WHERE p.polrelid <> 'fin.ledger_entry'::regclass
                AND p.oid IN (SELECT objid FROM pg_depend WHERE refobjid = 'fin.ledger_entry'::regclass AND classid = 'pg_policy'::regclass) LOOP
    saved := saved || jsonb_build_object('sql', format('CREATE POLICY %I ON %s AS %s FOR %s TO %s%s%s', pol.polname, pol.tbl,
               CASE WHEN pol.polpermissive THEN 'PERMISSIVE' ELSE 'RESTRICTIVE' END,
               CASE pol.polcmd WHEN 'r' THEN 'SELECT' WHEN 'a' THEN 'INSERT' WHEN 'w' THEN 'UPDATE' WHEN 'd' THEN 'DELETE' ELSE 'ALL' END,
               pol.roles, CASE WHEN pol.qual IS NOT NULL THEN ' USING (' || pol.qual || ')' ELSE '' END,
               CASE WHEN pol.chk IS NOT NULL THEN ' WITH CHECK (' || pol.chk || ')' ELSE '' END));
    EXECUTE format('DROP POLICY %I ON %s', pol.polname, pol.tbl);
  END LOOP;
  ALTER TABLE fin.ledger_entry RENAME TO ledger_entry_unpartitioned;
  ALTER INDEX fin.ledger_entry_pkey RENAME TO ledger_entry_unpartitioned_pkey;
  ALTER INDEX fin.ledger_entry_wallet_idx RENAME TO ledger_entry_unpartitioned_wallet_idx;
  ALTER INDEX fin.ledger_entry_txn_idx RENAME TO ledger_entry_unpartitioned_txn_idx;
  CREATE TABLE fin.ledger_entry (
    id            bigint GENERATED ALWAYS AS IDENTITY,
    txn_id        bigint NOT NULL REFERENCES fin.ledger_txn(id),
    wallet_id     bigint NOT NULL REFERENCES fin.wallet(id),
    direction     char(2) NOT NULL CHECK (direction IN ('DR','CR')),
    amount        bigint NOT NULL CHECK (amount > 0),
    balance_after bigint,
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_xid   xid8,
    PRIMARY KEY (id, created_at)
  ) PARTITION BY RANGE (created_at);
  first_month := coalesce((SELECT date_trunc('month', min(created_at))::date FROM fin.ledger_entry_unpartitioned), date_trunc('month', now())::date);
  months_back := (extract(year FROM age(date_trunc('month', now()), first_month)) * 12 + extract(month FROM age(date_trunc('month', now()), first_month)))::int;
  PERFORM sys.ensure_monthly_partitions('fin.ledger_entry', 3, greatest(months_back, 1));
  INSERT INTO fin.ledger_entry (id, txn_id, wallet_id, direction, amount, balance_after, created_at)
  OVERRIDING SYSTEM VALUE
  SELECT id, txn_id, wallet_id, direction, amount, balance_after, created_at FROM fin.ledger_entry_unpartitioned;
  mx := coalesce((SELECT max(id) FROM fin.ledger_entry_unpartitioned), 0);
  EXECUTE format('ALTER TABLE fin.ledger_entry ALTER COLUMN id RESTART WITH %s', mx + 1);
  DROP TABLE fin.ledger_entry_unpartitioned;
  FOR pol IN SELECT value ->> 'sql' AS sql FROM jsonb_array_elements(saved) LOOP
    EXECUTE pol.sql;
  END LOOP;
END $$;
CREATE INDEX IF NOT EXISTS ledger_entry_wallet_idx ON fin.ledger_entry (wallet_id, created_at);
CREATE INDEX IF NOT EXISTS ledger_entry_txn_idx ON fin.ledger_entry (txn_id);
-- the entries of DEFERRED wallets not yet rolled up are found by wallet and transaction id
CREATE INDEX IF NOT EXISTS ledger_entry_unrolled_idx ON fin.ledger_entry (wallet_id, created_xid) WHERE created_xid IS NOT NULL;
-- closing a day reads that day's range of its month
CREATE INDEX IF NOT EXISTS ledger_entry_created_brin ON fin.ledger_entry USING brin (created_at);
COMMENT ON TABLE fin.ledger_entry IS 'Ledger entry (debit/credit); append-only, in monthly partitions; an entry of an IMMEDIATE wallet updates its balance atomically, an entry of a DEFERRED wallet is folded in by the roll-up (1052)';
COMMENT ON COLUMN fin.ledger_entry.balance_after IS 'Balance of an IMMEDIATE wallet after this entry; empty for DEFERRED wallets (their statements compute it, fin.wallet_balance_at)';
COMMENT ON COLUMN fin.ledger_entry.created_xid IS 'Transaction that wrote an entry of a DEFERRED wallet; the roll-up folds entries below the oldest running transaction';
SELECT sys.rls('fin.ledger_entry', 'EXISTS (SELECT 1 FROM fin.wallet p WHERE p.id = ledger_entry.wallet_id)');
GRANT SELECT, INSERT ON fin.ledger_entry TO masslak_app;
GRANT SELECT ON fin.ledger_entry TO masslak_readonly;
REVOKE UPDATE, DELETE ON fin.ledger_entry FROM masslak_app;

-- =====================================================================
-- B  closed days, running totals and the balance that counts
-- =====================================================================
CREATE TABLE IF NOT EXISTS fin.ledger_close (
  id             boolean PRIMARY KEY DEFAULT true CHECK (id),
  closed_through date,
  closed_at      timestamptz
);
INSERT INTO fin.ledger_close (id) VALUES (true) ON CONFLICT DO NOTHING;
COMMENT ON TABLE fin.ledger_close IS 'The last UTC day of the ledger that is closed: totalled per wallet, and no entry may be written into it';
SELECT sys.rls('fin.ledger_close', 'sys.ctx_is_platform()');

CREATE TABLE IF NOT EXISTS fin.ledger_day_total (
  wallet_id     bigint NOT NULL REFERENCES fin.wallet(id),
  day           date NOT NULL,
  credit        bigint NOT NULL CHECK (credit >= 0),
  debit         bigint NOT NULL CHECK (debit >= 0),
  entries       integer NOT NULL CHECK (entries > 0),
  running_total bigint NOT NULL,
  PRIMARY KEY (wallet_id, day)
);
COMMENT ON TABLE fin.ledger_day_total IS 'Per wallet and closed UTC day: credits, debits and the running total of every entry up to the end of that day. Written once by fin.close_ledger_days, never changed';
COMMENT ON COLUMN fin.ledger_day_total.running_total IS 'Sum of every entry of the wallet up to the end of this day (credits minus debits)';
SELECT sys.rls('fin.ledger_day_total', 'EXISTS (SELECT 1 FROM fin.wallet p WHERE p.id = ledger_day_total.wallet_id)');
GRANT SELECT ON fin.ledger_day_total TO masslak_app, masslak_readonly;
REVOKE INSERT, UPDATE, DELETE ON fin.ledger_day_total FROM masslak_app;
DROP TRIGGER IF EXISTS ledger_day_total_immutable ON fin.ledger_day_total;
CREATE TRIGGER ledger_day_total_immutable BEFORE UPDATE OR DELETE ON fin.ledger_day_total
  FOR EACH ROW EXECUTE FUNCTION sys.tg_forbid_mutation();

-- the first moment entries may still be written (the start of the first open day), -infinity before any close
CREATE OR REPLACE FUNCTION fin.ledger_open_from() RETURNS timestamptz LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce((SELECT (closed_through + 1)::timestamp AT TIME ZONE 'UTC' FROM fin.ledger_close WHERE id), '-infinity'::timestamptz)
$$;

-- the balance that counts: the stored balance plus, for a DEFERRED wallet, the entries the roll-up has not folded in yet.
-- Runs with the caller's rights, so a caller who cannot see the wallet gets nothing.
CREATE OR REPLACE FUNCTION fin.wallet_balance(p_wallet bigint) RETURNS bigint LANGUAGE sql STABLE AS $$
  SELECT w.balance + CASE WHEN w.balance_mode = 'DEFERRED' THEN coalesce((
           SELECT sum(CASE e.direction WHEN 'CR' THEN e.amount ELSE -e.amount END) FROM fin.ledger_entry e
            WHERE e.wallet_id = w.id AND e.created_xid >= w.rolled_xid AND e.created_at >= fin.ledger_open_from()), 0)
         ELSE 0 END
    FROM fin.wallet w WHERE w.id = p_wallet
$$;
COMMENT ON FUNCTION fin.wallet_balance(bigint) IS 'The balance that counts, for both balance modes; every reader of a DEFERRED wallet uses it';

-- the balance of a wallet at a moment: the running total of its last closed day before that moment, plus its entries after it
CREATE OR REPLACE FUNCTION fin.wallet_balance_at(p_wallet bigint, p_at timestamptz) RETURNS bigint LANGUAGE sql STABLE AS $$
  WITH last_day AS (
    SELECT d.day, d.running_total FROM fin.ledger_day_total d
     WHERE d.wallet_id = p_wallet AND d.day < (p_at AT TIME ZONE 'UTC')::date ORDER BY d.day DESC LIMIT 1)
  SELECT coalesce((SELECT running_total FROM last_day), 0)
       + coalesce((SELECT sum(CASE e.direction WHEN 'CR' THEN e.amount ELSE -e.amount END) FROM fin.ledger_entry e
                    WHERE e.wallet_id = p_wallet AND e.created_at < p_at
                      AND e.created_at >= coalesce((SELECT (day + 1)::timestamp AT TIME ZONE 'UTC' FROM last_day), '-infinity'::timestamptz)), 0)
   WHERE EXISTS (SELECT 1 FROM fin.wallet w WHERE w.id = p_wallet)
$$;
COMMENT ON FUNCTION fin.wallet_balance_at(bigint, timestamptz) IS 'Balance of a wallet at a moment (statements, opening balances), from the closed day totals and the entries after them';

-- posting an entry
CREATE OR REPLACE FUNCTION fin.tg_ledger_entry_apply() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE w record; t_currency char(3); delta bigint; avail bigint;
BEGIN
  SELECT id, currency, status, balance_mode, allow_negative INTO w FROM fin.wallet WHERE id = NEW.wallet_id;
  IF w.id IS NULL THEN
    RETURN NEW;                                            -- the foreign key reports the missing wallet
  END IF;
  SELECT currency INTO t_currency FROM fin.ledger_txn WHERE id = NEW.txn_id;
  IF w.currency <> t_currency THEN
    RAISE EXCEPTION 'CURRENCY_MISMATCH: wallet % vs txn %', w.currency, t_currency USING ERRCODE = 'P0001';
  END IF;
  IF NEW.created_at < fin.ledger_open_from() THEN
    RAISE EXCEPTION 'LEDGER_DAY_CLOSED: % falls in a closed ledger day; post a correcting entry today', NEW.created_at
      USING ERRCODE = 'P0001';
  END IF;
  delta := CASE WHEN NEW.direction = 'CR' THEN NEW.amount ELSE -NEW.amount END;
  IF w.balance_mode = 'IMMEDIATE' THEN
    -- one owner: update the balance with a row lock; a CHECK constraint on the wallet rejects a negative balance
    SELECT id, status INTO w FROM fin.wallet WHERE id = NEW.wallet_id FOR UPDATE;
    IF w.status <> 'ACTIVE' THEN
      RAISE EXCEPTION 'WALLET_NOT_ACTIVE' USING ERRCODE = 'P0001';
    END IF;
    NEW.created_xid := NULL;
    PERFORM set_config('fin.posting_entry', NEW.txn_id::text, true);
    UPDATE fin.wallet SET balance = balance + delta WHERE id = NEW.wallet_id RETURNING balance INTO NEW.balance_after;
    PERFORM set_config('fin.posting_entry', '', true);
  ELSE
    -- shared wallet: append only; credits never wait for one another
    IF w.status <> 'ACTIVE' THEN
      RAISE EXCEPTION 'WALLET_NOT_ACTIVE' USING ERRCODE = 'P0001';
    END IF;
    NEW.created_xid := pg_current_xact_id();
    NEW.balance_after := NULL;
    IF NEW.direction = 'DR' AND NOT w.allow_negative THEN
      -- a debit that must stay covered queues on the wallet (with other debits and the roll-up) and checks the balance
      -- that counts; credits still in flight are not counted, which only errs on the safe side
      PERFORM 1 FROM fin.wallet WHERE id = NEW.wallet_id FOR UPDATE;
      avail := fin.wallet_balance(NEW.wallet_id) - (SELECT hold_balance FROM fin.wallet WHERE id = NEW.wallet_id);
      IF avail < NEW.amount THEN
        RAISE EXCEPTION 'INSUFFICIENT_BALANCE: wallet % has % available, % asked', NEW.wallet_id, avail, NEW.amount
          USING ERRCODE = 'check_violation';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END $$;

-- a transaction balances at commit; its entries share the transaction's start time, so only its day is searched.
-- It counts every entry of the transaction, whoever posts it (SECURITY DEFINER, as since 1039)
CREATE OR REPLACE FUNCTION fin.tg_ledger_txn_balanced() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE dr bigint; cr bigint; n int;
BEGIN
  SELECT coalesce(sum(amount) FILTER (WHERE direction = 'DR'), 0),
         coalesce(sum(amount) FILTER (WHERE direction = 'CR'), 0), count(*)
    INTO dr, cr, n FROM fin.ledger_entry
   WHERE txn_id = NEW.txn_id AND created_at BETWEEN NEW.created_at - interval '1 day' AND NEW.created_at + interval '1 day';
  IF dr <> cr OR n < 2 THEN
    RAISE EXCEPTION 'UNBALANCED_TXN: txn % DR=% CR=% lines=%', NEW.txn_id, dr, cr, n USING ERRCODE = 'P0001';
  END IF;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS ledger_entry_apply ON fin.ledger_entry;
CREATE TRIGGER ledger_entry_apply BEFORE INSERT ON fin.ledger_entry FOR EACH ROW EXECUTE FUNCTION fin.tg_ledger_entry_apply();
DROP TRIGGER IF EXISTS ledger_txn_balanced ON fin.ledger_entry;
CREATE CONSTRAINT TRIGGER ledger_txn_balanced AFTER INSERT ON fin.ledger_entry DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION fin.tg_ledger_txn_balanced();
DROP TRIGGER IF EXISTS ledger_entry_immutable ON fin.ledger_entry;
CREATE TRIGGER ledger_entry_immutable BEFORE DELETE OR UPDATE ON fin.ledger_entry FOR EACH ROW EXECUTE FUNCTION sys.tg_forbid_mutation();

-- a wallet changes mode only when nothing is waiting to be folded in
CREATE OR REPLACE FUNCTION fin.tg_wallet_mode_change() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.balance_mode IS DISTINCT FROM OLD.balance_mode THEN
    IF OLD.balance_mode = 'DEFERRED' AND fin.wallet_balance(OLD.id) <> OLD.balance THEN
      RAISE EXCEPTION 'WALLET_MODE_PENDING: roll up the wallet before making it IMMEDIATE' USING ERRCODE = 'P0001';
    END IF;
    IF NEW.balance_mode = 'DEFERRED' THEN
      -- every entry written so far is already in the balance
      NEW.rolled_xid := greatest(pg_current_xact_id(),
                                 coalesce((SELECT max(created_xid) FROM fin.ledger_entry WHERE wallet_id = OLD.id), '0'::xid8));
      NEW.rolled_xid := (NEW.rolled_xid::text::numeric + 1)::text::xid8;
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS wallet_mode_change ON fin.wallet;
CREATE TRIGGER wallet_mode_change BEFORE UPDATE OF balance_mode ON fin.wallet FOR EACH ROW EXECUTE FUNCTION fin.tg_wallet_mode_change();

-- the roll-up: fold the entries of finished transactions into the stored balance of DEFERRED wallets. A wallet whose
-- row is locked by a debit in flight is skipped and caught on the next run.
CREATE OR REPLACE FUNCTION fin.roll_up_balances(p_max int DEFAULT 10000) RETURNS int LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE horizon xid8 := pg_snapshot_xmin(pg_current_snapshot()); open_from timestamptz := fin.ledger_open_from();
        w record; delta bigint; n int := 0;
BEGIN
  PERFORM set_config('fin.posting_entry', 'roll-up', true);
  FOR w IN SELECT x.id, x.rolled_xid FROM fin.wallet x
            WHERE x.balance_mode = 'DEFERRED'
              AND EXISTS (SELECT 1 FROM fin.ledger_entry e WHERE e.wallet_id = x.id AND e.created_xid >= x.rolled_xid
                             AND e.created_xid < horizon AND e.created_at >= open_from)
            ORDER BY x.id LIMIT p_max
            FOR UPDATE OF x SKIP LOCKED LOOP
    SELECT coalesce(sum(CASE direction WHEN 'CR' THEN amount ELSE -amount END), 0) INTO delta
      FROM fin.ledger_entry WHERE wallet_id = w.id AND created_xid >= w.rolled_xid AND created_xid < horizon AND created_at >= open_from;
    UPDATE fin.wallet SET balance = balance + delta, rolled_xid = horizon, rolled_at = now() WHERE id = w.id;
    n := n + 1;
  END LOOP;
  PERFORM set_config('fin.posting_entry', '', true);
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION fin.roll_up_balances(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fin.roll_up_balances(int) TO masslak_app;
COMMENT ON FUNCTION fin.roll_up_balances(int) IS 'Folds the entries of DEFERRED wallets into their stored balance; the worker runs it every few seconds';

-- holds (a withdrawal waiting for approval): checked against the balance that counts, under the wallet's lock
CREATE OR REPLACE FUNCTION fin.adjust_hold(p_wallet bigint, p_delta bigint) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE w record; avail bigint;
BEGIN
  SELECT id, allow_negative, hold_balance INTO w FROM fin.wallet WHERE id = p_wallet FOR UPDATE;
  IF w.id IS NULL THEN
    RAISE EXCEPTION 'WALLET_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF p_delta > 0 AND NOT w.allow_negative THEN
    avail := fin.wallet_balance(p_wallet) - w.hold_balance;
    IF avail < p_delta THEN
      RAISE EXCEPTION 'INSUFFICIENT_BALANCE: % available, % to hold', avail, p_delta USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  UPDATE fin.wallet SET hold_balance = hold_balance + p_delta WHERE id = p_wallet RETURNING hold_balance INTO avail;
  RETURN avail;
END $$;
COMMENT ON FUNCTION fin.adjust_hold(bigint, bigint) IS 'Moves money in or out of a wallet hold, refusing a hold above the balance that counts';

-- closing days: total every wallet per day and forbid later entries in those days. A day closes only when no
-- transaction that started on it can still write (entries carry their transaction''s start time) and when every
-- entry of a DEFERRED wallet in it is already rolled up.
CREATE OR REPLACE FUNCTION fin.close_ledger_days(p_until date DEFAULT NULL) RETURNS int LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE last_closed date; first_day date; d date; n int := 0; oldest timestamptz; until date; blocked date;
BEGIN
  SELECT closed_through INTO last_closed FROM fin.ledger_close WHERE id FOR UPDATE;
  SELECT min(xact_start) INTO oldest FROM pg_stat_activity
   WHERE xact_start IS NOT NULL AND pid <> pg_backend_pid() AND backend_type = 'client backend' AND datname = current_database();
  until := ((least(coalesce(oldest, now()), now() - interval '1 hour')) AT TIME ZONE 'UTC')::date - 1;
  IF p_until IS NOT NULL THEN
    until := least(until, p_until);
  END IF;
  PERFORM fin.roll_up_balances();
  SELECT min((e.created_at AT TIME ZONE 'UTC')::date) INTO blocked
    FROM fin.wallet w JOIN fin.ledger_entry e ON e.wallet_id = w.id AND e.created_xid >= w.rolled_xid
   WHERE w.balance_mode = 'DEFERRED' AND e.created_at >= fin.ledger_open_from();
  IF blocked IS NOT NULL THEN
    until := least(until, blocked - 1);
  END IF;
  first_day := coalesce(last_closed + 1, (SELECT (min(created_at) AT TIME ZONE 'UTC')::date FROM fin.ledger_entry));
  IF first_day IS NULL OR first_day > until THEN
    RETURN 0;
  END IF;
  FOR d IN SELECT generate_series(first_day, until, interval '1 day')::date LOOP
    INSERT INTO fin.ledger_day_total (wallet_id, day, credit, debit, entries, running_total)
    SELECT s.wallet_id, d, s.cr, s.dr, s.n, coalesce(p.running_total, 0) + s.cr - s.dr
      FROM (SELECT wallet_id, coalesce(sum(amount) FILTER (WHERE direction = 'CR'), 0) AS cr,
                   coalesce(sum(amount) FILTER (WHERE direction = 'DR'), 0) AS dr, count(*)::int AS n
              FROM fin.ledger_entry
             WHERE created_at >= d::timestamp AT TIME ZONE 'UTC' AND created_at < (d + 1)::timestamp AT TIME ZONE 'UTC'
             GROUP BY wallet_id) s
      LEFT JOIN LATERAL (SELECT t.running_total FROM fin.ledger_day_total t WHERE t.wallet_id = s.wallet_id AND t.day < d
                          ORDER BY t.day DESC LIMIT 1) p ON true;
    n := n + 1;
  END LOOP;
  UPDATE fin.ledger_close SET closed_through = until, closed_at = now() WHERE id;
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION fin.close_ledger_days(date) FROM PUBLIC;
COMMENT ON FUNCTION fin.close_ledger_days(date) IS 'Closes finished UTC days of the ledger: per-wallet day totals with running totals; later entries in them are refused';

-- re-reading a closed day must give the same totals (run on a past day by the daily upkeep)
CREATE OR REPLACE FUNCTION fin.verify_ledger_day(p_day date) RETURNS int LANGUAGE sql STABLE
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  WITH fresh AS (
    SELECT wallet_id, coalesce(sum(amount) FILTER (WHERE direction = 'CR'), 0) AS cr,
           coalesce(sum(amount) FILTER (WHERE direction = 'DR'), 0) AS dr, count(*)::int AS n
      FROM fin.ledger_entry
     WHERE created_at >= p_day::timestamp AT TIME ZONE 'UTC' AND created_at < (p_day + 1)::timestamp AT TIME ZONE 'UTC'
     GROUP BY wallet_id),
  stored AS (
    SELECT t.wallet_id, t.credit, t.debit, t.entries, t.running_total,
           coalesce((SELECT p.running_total FROM fin.ledger_day_total p WHERE p.wallet_id = t.wallet_id AND p.day < t.day
                      ORDER BY p.day DESC LIMIT 1), 0) AS previous
      FROM fin.ledger_day_total t WHERE t.day = p_day)
  SELECT count(*)::int FROM fresh f FULL JOIN stored s USING (wallet_id)
   WHERE s.wallet_id IS NULL OR f.wallet_id IS NULL OR f.cr <> s.credit OR f.dr <> s.debit OR f.n <> s.entries
      OR s.running_total <> s.previous + s.credit - s.debit
$$;
REVOKE ALL ON FUNCTION fin.verify_ledger_day(date) FROM PUBLIC;

-- the daily reconciliation: each wallet against its last running total plus the open days (no full ledger scan)
CREATE OR REPLACE FUNCTION fin.reconcile_wallets() RETURNS fin.wallet_reconciliation LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE r fin.wallet_reconciliation; open_from timestamptz := fin.ledger_open_from();
BEGIN
  WITH sums AS (
    SELECT w.id, fin.wallet_balance(w.id) AS balance,
           coalesce((SELECT d.running_total FROM fin.ledger_day_total d WHERE d.wallet_id = w.id ORDER BY d.day DESC LIMIT 1), 0)
         + coalesce((SELECT sum(CASE e.direction WHEN 'CR' THEN e.amount ELSE -e.amount END) FROM fin.ledger_entry e
                      WHERE e.wallet_id = w.id AND e.created_at >= open_from), 0) AS ledger
      FROM fin.wallet w),
  bad AS (SELECT id, balance, ledger FROM sums WHERE balance <> ledger)
  INSERT INTO fin.wallet_reconciliation (wallets, mismatches, detail)
  SELECT (SELECT count(*) FROM sums), (SELECT count(*) FROM bad),
         coalesce((SELECT jsonb_agg(jsonb_build_object('wallet_id', id, 'balance', balance, 'ledger', ledger)) FROM bad), '[]')
  RETURNING * INTO r;
  IF r.mismatches > 0 THEN
    INSERT INTO sys.outbox_event (aggregate_type, aggregate_id, event_type, payload)
    VALUES ('WALLET_RECONCILIATION', r.id, 'ledger.imbalance', jsonb_build_object('mismatches', r.mismatches));
  END IF;
  RETURN r;
END $$;

-- =====================================================================
-- C  the latest position of each vehicle
-- =====================================================================
CREATE TABLE IF NOT EXISTS ops.vehicle_position (
  vehicle_id     bigint PRIMARY KEY REFERENCES fleet.vehicle(id),
  trip_id        bigint REFERENCES ops.trip(id),
  driver_user_id bigint REFERENCES iam.app_user(id),
  ts             timestamptz NOT NULL,
  lat            numeric NOT NULL,
  lng            numeric NOT NULL,
  speed_kmh      real,
  heading        smallint,
  accuracy_m     real,
  trust          text NOT NULL,
  updated_at     timestamptz NOT NULL DEFAULT now()
) WITH (fillfactor = 50, autovacuum_vacuum_scale_factor = 0.02, autovacuum_analyze_scale_factor = 0.05);
CREATE INDEX IF NOT EXISTS vehicle_position_trip_id_fkx ON ops.vehicle_position (trip_id);
CREATE INDEX IF NOT EXISTS vehicle_position_driver_user_id_fkx ON ops.vehicle_position (driver_user_id);
COMMENT ON TABLE ops.vehicle_position IS 'The latest accepted position of every vehicle, one row each, kept by the insert of positions (live maps and dashboards read here, never the position history)';
SELECT sys.rls('ops.vehicle_position',
  'sys.ctx_is_platform() OR (trip_id IS NOT NULL AND EXISTS (SELECT 1 FROM ops.trip x WHERE x.id = vehicle_position.trip_id AND sys.tenant_visible(x.company_id)))
   OR EXISTS (SELECT 1 FROM fleet.vehicle v WHERE v.id = vehicle_position.vehicle_id AND sys.tenant_visible(v.company_id))
   OR (driver_user_id IS NOT NULL AND driver_user_id = sys.ctx_user_id())');
GRANT SELECT ON ops.vehicle_position TO masslak_app, masslak_readonly;
REVOKE INSERT, UPDATE, DELETE ON ops.vehicle_position FROM masslak_app;

-- once per insert statement: the newest accepted position of each vehicle in it
CREATE OR REPLACE FUNCTION ops.tg_vehicle_position() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  INSERT INTO ops.vehicle_position AS p (vehicle_id, trip_id, driver_user_id, ts, lat, lng, speed_kmh, heading, accuracy_m, trust, updated_at)
  SELECT DISTINCT ON (n.vehicle_id) n.vehicle_id, n.trip_id, n.driver_user_id, n.ts, n.lat, n.lng, n.speed_kmh, n.heading,
         n.accuracy_m, n.trust, now()
    FROM new_positions n
   WHERE n.vehicle_id IS NOT NULL AND n.trust IS DISTINCT FROM 'REJECTED'
   ORDER BY n.vehicle_id, n.ts DESC
  ON CONFLICT (vehicle_id) DO UPDATE
     SET trip_id = EXCLUDED.trip_id, driver_user_id = EXCLUDED.driver_user_id, ts = EXCLUDED.ts, lat = EXCLUDED.lat,
         lng = EXCLUDED.lng, speed_kmh = EXCLUDED.speed_kmh, heading = EXCLUDED.heading, accuracy_m = EXCLUDED.accuracy_m,
         trust = EXCLUDED.trust, updated_at = now()
   WHERE p.ts < EXCLUDED.ts;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS geo_event_latest ON ops.geo_event;
CREATE TRIGGER geo_event_latest AFTER INSERT ON ops.geo_event REFERENCING NEW TABLE AS new_positions
  FOR EACH STATEMENT EXECUTE FUNCTION ops.tg_vehicle_position();
-- the positions already stored
INSERT INTO ops.vehicle_position (vehicle_id, trip_id, driver_user_id, ts, lat, lng, speed_kmh, heading, accuracy_m, trust)
SELECT DISTINCT ON (vehicle_id) vehicle_id, trip_id, driver_user_id, ts, lat, lng, speed_kmh, heading, accuracy_m, coalesce(trust, 'HIGH')
  FROM ops.geo_event WHERE vehicle_id IS NOT NULL AND trust IS DISTINCT FROM 'REJECTED'
 ORDER BY vehicle_id, ts DESC
ON CONFLICT (vehicle_id) DO NOTHING;

-- =====================================================================
-- D  storage settings on the partitions that exist now, and on the busiest plain tables
-- =====================================================================
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT o.parent, c.oid::regclass::text AS part FROM sys.partition_option o
             JOIN pg_inherits i ON i.inhparent = to_regclass(o.parent) JOIN pg_class c ON c.oid = i.inhrelid LOOP
    PERFORM sys.apply_partition_options(r.part, r.parent);
  END LOOP;
END $$;
-- the outbox changes status on every event: room for updates on the same page, and vacuum soon after (on its daily
-- partitions from 1053 on, through sys.partition_option)
DO $$ BEGIN
  IF (SELECT relkind FROM pg_class WHERE oid = 'sys.outbox_event'::regclass) = 'r' THEN
    ALTER TABLE sys.outbox_event SET (fillfactor = 80, autovacuum_vacuum_scale_factor = 0.01, autovacuum_analyze_scale_factor = 0.02);
  END IF;
END $$;
ALTER TABLE sys.webhook_delivery SET (fillfactor = 80, autovacuum_vacuum_scale_factor = 0.02);

-- =====================================================================
-- E  audit at volume
-- =====================================================================
-- the change log names the row of an update too: its key is read before the update is reduced to the changed fields
-- (until now an update kept only the changed fields, so row_pk was empty unless the key itself changed)
CREATE OR REPLACE FUNCTION audit.tg_capture_change() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE o jsonb; n jsonb; pk text;
BEGIN
  IF TG_OP <> 'INSERT' THEN o := audit.redact(to_jsonb(OLD)); END IF;
  IF TG_OP <> 'DELETE' THEN n := audit.redact(to_jsonb(NEW)); END IF;
  pk := coalesce(n->>'id', o->>'id', n->>'party_id', o->>'party_id', n->>'company_id', o->>'company_id', n->>'key', o->>'key');
  IF TG_OP = 'UPDATE' THEN               -- store changed fields only
    SELECT jsonb_object_agg(k, o->k), jsonb_object_agg(k, n->k) INTO o, n
      FROM jsonb_object_keys(n) k WHERE (o->k) IS DISTINCT FROM (n->k) AND k NOT IN ('updated_at');
    IF n IS NULL THEN RETURN NULL; END IF;
  END IF;
  INSERT INTO audit.row_change (schema_name, table_name, op, row_pk, old_values, new_values,
                                user_id, api_client_id, company_id, request_id, ip)
  VALUES (TG_TABLE_SCHEMA, TG_TABLE_NAME, left(TG_OP, 1), pk, o, n,
          sys.ctx_user_id(), sys.ctx_api_client_id(), sys.ctx_company_id(), sys.ctx_request_id(), sys.ctx_ip());
  RETURN NULL;
END $$;

-- a wallet row changed only by a posting (its balance, or the roll-up's watermark) is not copied: the entry is the record
DROP TRIGGER IF EXISTS zz_audit_capture ON fin.wallet;
DROP TRIGGER IF EXISTS zz_audit_capture_update ON fin.wallet;
CREATE TRIGGER zz_audit_capture AFTER INSERT OR DELETE ON fin.wallet FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change();
CREATE TRIGGER zz_audit_capture_update AFTER UPDATE ON fin.wallet FOR EACH ROW
  WHEN (coalesce(current_setting('fin.posting_entry', true), '') = ''
        OR (to_jsonb(OLD) - 'balance' - 'rolled_xid' - 'rolled_at') IS DISTINCT FROM (to_jsonb(NEW) - 'balance' - 'rolled_xid' - 'rolled_at'))
  EXECUTE FUNCTION audit.tg_capture_change();

-- the online window: audit partitions older than audit.online_months are dropped once the signed archive covers them
INSERT INTO sys.setting (key, value, description) VALUES
  ('audit.online_months', '13', 'Months of audit logs kept in the database; older months live in the signed archive with object lock (RUNBOOKS section 7)')
ON CONFLICT (key) DO NOTHING;

CREATE TABLE IF NOT EXISTS audit.archive_checkpoint (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  table_name      text NOT NULL CHECK (table_name IN ('audit.activity_log', 'audit.row_change', 'audit.data_access_log',
                                                      'audit.auth_event', 'audit.ddl_event', 'audit.log_seal')),
  through_id      bigint NOT NULL CHECK (through_id > 0),
  manifest_sha256 text NOT NULL CHECK (manifest_sha256 ~ '^[0-9a-f]{64}$'),
  recorded_by     text NOT NULL DEFAULT current_user,
  recorded_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS archive_checkpoint_table_idx ON audit.archive_checkpoint (table_name, through_id DESC);
COMMENT ON COLUMN audit.archive_checkpoint.through_id IS 'No FK: the last row id of table_name that the archive covers (the rows themselves may already be dropped)';
COMMENT ON TABLE audit.archive_checkpoint IS 'Each export of the audit logs to the signed archive: up to which row of which log, and the manifest that proves it (app.tools.audit_export)';
SELECT sys.rls('audit.archive_checkpoint', 'sys.ctx_is_platform()');
DROP POLICY IF EXISTS auditor_read ON audit.archive_checkpoint;
CREATE POLICY auditor_read ON audit.archive_checkpoint FOR SELECT USING (true);
GRANT SELECT ON audit.archive_checkpoint TO masslak_auditor, masslak_readonly;
DROP TRIGGER IF EXISTS archive_checkpoint_immutable ON audit.archive_checkpoint;
CREATE TRIGGER archive_checkpoint_immutable BEFORE UPDATE OR DELETE ON audit.archive_checkpoint
  FOR EACH ROW EXECUTE FUNCTION sys.tg_forbid_mutation();

CREATE OR REPLACE FUNCTION audit.record_archive(p_table text, p_through bigint, p_manifest text) RETURNS void LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF p_through < coalesce((SELECT max(through_id) FROM audit.archive_checkpoint WHERE table_name = p_table), 0) THEN
    RAISE EXCEPTION 'ARCHIVE_CHECKPOINT_BACKWARDS: % was already archived further' , p_table USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO audit.archive_checkpoint (table_name, through_id, manifest_sha256) VALUES (p_table, p_through, p_manifest);
END $$;
REVOKE ALL ON FUNCTION audit.record_archive(text, bigint, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION audit.record_archive(text, bigint, text) TO masslak_auditor;

CREATE OR REPLACE FUNCTION audit.drop_archived_partitions() RETURNS int LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE r record; n int := 0; months int := coalesce((SELECT value::int FROM sys.setting WHERE key = 'audit.online_months'), 13);
        cutoff timestamptz := date_trunc('month', now()) - make_interval(months => months); archived bigint; top bigint;
BEGIN
  FOR r IN SELECT p.oid::regclass::text AS parent, c.oid::regclass::text AS part,
                  substring(pg_get_expr(c.relpartbound, c.oid) from 'TO \(''([0-9-]+)')::date AS upper_bound
             FROM pg_class p JOIN pg_inherits i ON i.inhparent = p.oid JOIN pg_class c ON c.oid = i.inhrelid
            WHERE p.relnamespace = 'audit'::regnamespace AND p.relkind = 'p'
              AND pg_get_expr(c.relpartbound, c.oid) LIKE 'FOR VALUES FROM%' LOOP
    CONTINUE WHEN r.upper_bound > cutoff;
    CONTINUE WHEN EXISTS (SELECT 1 FROM gov.legal_hold WHERE released_at IS NULL AND scope_type = 'DATASET' AND dataset = r.parent);
    archived := (SELECT max(through_id) FROM audit.archive_checkpoint WHERE table_name = r.parent);
    EXECUTE format('SELECT max(id) FROM %s', r.part) INTO top;
    CONTINUE WHEN top IS NOT NULL AND (archived IS NULL OR top > archived);
    EXECUTE format('DROP TABLE %s', r.part);
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION audit.drop_archived_partitions() FROM PUBLIC;
COMMENT ON FUNCTION audit.drop_archived_partitions() IS 'Drops audit partitions older than audit.online_months whose every row is in the signed archive (archive_checkpoint), unless a legal hold applies';

-- =====================================================================
-- the daily upkeep: close ledger days, verify a past one, drop archived audit months
-- =====================================================================
CREATE OR REPLACE FUNCTION sys.run_maintenance_body()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'pg_catalog', 'pg_temp' AS $function$
DECLARE p text; done jsonb := '{}'::jsonb; keep_days int; dropped int := 0; held boolean; r fin.wallet_reconciliation;
        orphans bigint; closed int; checked_day date; day_mismatch int;
BEGIN
  FOR p IN SELECT n.nspname || '.' || c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind = 'p' AND NOT c.relispartition LOOP
    IF p IN ('ops.geo_event', 'sys.outbox_event') THEN
      PERFORM sys.ensure_daily_partitions(p, 7, 1);
    ELSE
      PERFORM sys.ensure_monthly_partitions(p, 3, 1);
    END IF;
  END LOOP;
  SELECT retention_days INTO keep_days FROM gov.data_inventory WHERE dataset = 'ops.geo_event';
  held := EXISTS (SELECT 1 FROM gov.legal_hold WHERE released_at IS NULL AND scope_type = 'DATASET' AND dataset = 'ops.geo_event');
  IF keep_days IS NOT NULL AND NOT held THEN
    dropped := sys.drop_daily_partitions_older_than('ops.geo_event', keep_days);
  END IF;
  -- a vehicle that stopped reporting does not keep its last position beyond the retention of positions
  DELETE FROM ops.vehicle_position
   WHERE ts < now() - make_interval(days => coalesce((SELECT retention_days FROM gov.data_inventory WHERE dataset = 'ops.vehicle_position'), 7));
  closed := fin.close_ledger_days();
  checked_day := (SELECT closed_through - 7 FROM fin.ledger_close WHERE id);
  day_mismatch := CASE WHEN checked_day IS NULL THEN 0 ELSE fin.verify_ledger_day(checked_day) END;
  r := fin.reconcile_wallets();
  IF NOT EXISTS (SELECT 1 FROM sys.orphan_check WHERE checked_at > now() - interval '7 days') THEN
    orphans := sys.run_orphan_check();
  END IF;
  done := jsonb_build_object('partitions_checked', true, 'geo_partitions_dropped', dropped, 'geo_retention_held', held,
                             'expired_holds_released', ops.release_expired_holds(),
                             'ledger_days_closed', closed, 'ledger_day_verified', checked_day, 'ledger_day_mismatches', day_mismatch,
                             'wallet_mismatches', r.mismatches + day_mismatch, 'orphans', orphans, 'purged', sys.purge_expired(),
                             'audit_partitions_dropped', audit.drop_archived_partitions(),
                             'break_glass', sec.break_glass_upkeep(), 'at', now());
  RETURN done;
END $function$;

-- =====================================================================
-- metrics of this file (added to the scrape next to sys.ops_metrics and sys.capacity_metrics)
-- =====================================================================
CREATE OR REPLACE FUNCTION sys.scale_metrics() RETURNS TABLE (metric text, labels jsonb, value double precision)
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  -- how far the roll-up lags: the oldest entry of a DEFERRED wallet not yet folded in
  RETURN QUERY SELECT 'masslak_wallet_rollup_lag_seconds'::text, '{}'::jsonb,
    coalesce(extract(epoch FROM now() - (SELECT min(e.created_at) FROM fin.wallet w
                                           JOIN fin.ledger_entry e ON e.wallet_id = w.id AND e.created_xid >= w.rolled_xid
                                          WHERE w.balance_mode = 'DEFERRED' AND e.created_at >= fin.ledger_open_from())), 0)::float8;
  -- days of the ledger not yet closed (normally one or two)
  RETURN QUERY SELECT 'masslak_ledger_open_days'::text, '{}'::jsonb,
    coalesce((now() AT TIME ZONE 'UTC')::date - (SELECT closed_through FROM fin.ledger_close WHERE id), 0)::float8;
  -- audit months kept in the database
  RETURN QUERY SELECT 'masslak_audit_online_months'::text, jsonb_build_object('table', p.oid::regclass::text),
    count(*)::float8 FROM pg_class p JOIN pg_inherits i ON i.inhparent = p.oid
   WHERE p.relnamespace = 'audit'::regnamespace AND p.relkind = 'p' GROUP BY p.oid;
END $$;
REVOKE ALL ON FUNCTION sys.scale_metrics() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sys.scale_metrics() TO masslak_app, masslak_readonly;
COMMENT ON FUNCTION sys.scale_metrics IS 'Roll-up lag, open ledger days and online audit months for the monitoring scrape (1052)';

-- =====================================================================
-- registrations
-- =====================================================================
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  ('sys.partition_option', '1A', 'E03'), ('fin.ledger_close', '1B', 'E16'), ('fin.ledger_day_total', '1B', 'E16'),
  ('ops.vehicle_position', '1B', 'E09'), ('audit.archive_checkpoint', '1A', 'E25')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;
INSERT INTO gov.data_inventory (dataset, data_class, owner, purpose, legal_basis, retention_days, erasure_method, copies, backup_retention_days) VALUES
  ('fin.ledger_day_total', 'CONFIDENTIAL', 'fin', 'Closed-day totals of the ledger per wallet', 'Accounting law', 3650, 'KEEP_LEGAL', '{replica,backup}', 35),
  ('ops.vehicle_position', 'CONFIDENTIAL', 'ops', 'Latest position of each vehicle for live operations', 'Contract', 7, 'DELETE', '{replica,backup}', 35),
  ('audit.archive_checkpoint', 'INTERNAL', 'audit', 'Proof of what the signed audit archive covers', 'Legal obligation', 2555, 'KEEP_LEGAL', '{backup}', 35)
ON CONFLICT (dataset) DO NOTHING;

INSERT INTO sys.schema_migration (version, description)
SELECT '1.34.0', 'Ten million operations a day: DEFERRED balances for shared wallets, monthly ledger partitions with closed-day totals, latest vehicle positions, partition storage settings, audit online window'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.34.0');

SELECT sys.refresh_table_class();
