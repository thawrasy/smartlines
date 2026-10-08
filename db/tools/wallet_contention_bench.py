#!/usr/bin/env python3
"""Contention on shared wallets (capacity model, docs/operations/CAPACITY_MODEL.md): how many money postings per second
the database accepts when every one of them touches the same carrier wallet or the same payment-gateway clearing wallet.

Run it on a scratch copy of a seeded database, never on a database that serves users:

    python3 db/tools/wallet_contention_bench.py <scratch database> --clients 1,8,32 --seconds 15 [--json out.json] \
            [psql connection args...]

It creates 2,000 funded passenger wallets, then runs pgbench with two equally weighted transactions:
* pay:    a passenger pays a carrier (debit the passenger's wallet, credit one carrier wallet shared by every client);
* top-up: a passenger tops up by card (debit the gateway clearing wallet shared by every client, credit the passenger).
Each is a real ledger transaction: the entries go through the same triggers as in production (wallet rules, balance
check at commit, audit of wallet changes). The result is transactions per second and latency at each client count, and
how long postings waited for row locks.

Refuses to run on a database whose setting deploy.environment is 'production'.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

WALLETS = 2000

SETUP = f"""
SET session_replication_role = replica;   -- the setup itself is bulk data; the benchmark runs with every trigger on
INSERT INTO iam.party (party_type, legal_name)
SELECT 'PERSON', 'bench passenger ' || g FROM generate_series(1, {WALLETS}) g
 WHERE NOT EXISTS (SELECT 1 FROM iam.party WHERE legal_name = 'bench passenger 1');
SET session_replication_role = origin;
INSERT INTO fin.wallet (owner_party_id, wallet_type, label, currency)
SELECT p.id, 'USER', 'bench', 'SYP' FROM iam.party p
 WHERE p.legal_name LIKE 'bench passenger %' AND NOT EXISTS (SELECT 1 FROM fin.wallet w WHERE w.owner_party_id = p.id);
"""

FUND = """
DO $$
DECLARE w record; t bigint; gw bigint := (SELECT id FROM fin.wallet WHERE wallet_type = 'GATEWAY_CLEARING' AND currency = 'SYP' ORDER BY id LIMIT 1);
BEGIN
  FOR w IN SELECT id FROM fin.wallet WHERE label = 'bench' AND balance = 0 LOOP
    INSERT INTO fin.ledger_txn (txn_type, currency, idempotency_key, memo) VALUES ('TOPUP', 'SYP', 'bench-fund-' || w.id, 'bench')
      RETURNING id INTO t;
    INSERT INTO fin.ledger_entry (txn_id, wallet_id, direction, amount) VALUES (t, gw, 'DR', 1000000000), (t, w.id, 'CR', 1000000000);
  END LOOP;
END $$;
"""

PAY = """\\set u random(1, {n})
BEGIN;
INSERT INTO fin.ledger_txn (txn_type, currency, idempotency_key, memo) VALUES ('BOOKING_PAY', 'SYP', gen_random_uuid()::text, 'bench') RETURNING id AS t \\gset
INSERT INTO fin.ledger_entry (txn_id, wallet_id, direction, amount) VALUES (:t, (SELECT id FROM bench_wallets WHERE n = :u), 'DR', 100), (:t, {company}, 'CR', 100);
COMMIT;
"""

TOPUP = """\\set u random(1, {n})
BEGIN;
INSERT INTO fin.ledger_txn (txn_type, currency, idempotency_key, memo) VALUES ('TOPUP', 'SYP', gen_random_uuid()::text, 'bench') RETURNING id AS t \\gset
INSERT INTO fin.ledger_entry (txn_id, wallet_id, direction, amount) VALUES (:t, {gateway}, 'DR', 100), (:t, (SELECT id FROM bench_wallets WHERE n = :u), 'CR', 100);
COMMIT;
"""


def psql(db, args, sql):
    r = subprocess.run(["psql", *args, "-d", db, "-At", "-v", "ON_ERROR_STOP=1", "-c", sql], capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"psql failed: {r.stderr.strip()[:800]}")
    return r.stdout.strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter, add_help=False)
    ap.add_argument("--help", action="help")
    ap.add_argument("--clients", default="1,8,32")
    ap.add_argument("--seconds", type=int, default=15)
    ap.add_argument("--json")
    a, rest = ap.parse_known_args()
    db, args = rest[0], rest[1:]
    if psql(db, args, "SELECT coalesce((SELECT value #>> '{}' FROM sys.setting WHERE key = 'deploy.environment'), 'staging')") == "production":
        sys.exit("refusing to run on a production database")
    psql(db, args, SETUP)
    psql(db, args, FUND)
    psql(db, args, "DROP TABLE IF EXISTS bench_wallets; CREATE UNLOGGED TABLE bench_wallets AS "
                   "SELECT row_number() OVER (ORDER BY id) AS n, id FROM fin.wallet WHERE label = 'bench'; "
                   "CREATE UNIQUE INDEX ON bench_wallets (n); ANALYZE bench_wallets")
    company = int(psql(db, args, "SELECT id FROM fin.wallet WHERE wallet_type = 'COMPANY' AND currency = 'SYP' ORDER BY id LIMIT 1"))
    gateway = int(psql(db, args, "SELECT id FROM fin.wallet WHERE wallet_type = 'GATEWAY_CLEARING' AND currency = 'SYP' ORDER BY id LIMIT 1"))
    mode = psql(db, args, f"SELECT coalesce(to_jsonb(w) ->> 'balance_mode', 'IMMEDIATE') FROM fin.wallet w WHERE id = {company}")
    out = {"company_wallet_mode": mode, "wallets": WALLETS, "seconds": a.seconds, "levels": []}
    with tempfile.TemporaryDirectory() as tmp:
        pay, top = os.path.join(tmp, "pay.sql"), os.path.join(tmp, "topup.sql")
        open(pay, "w").write(PAY.format(n=WALLETS, company=company))
        open(top, "w").write(TOPUP.format(n=WALLETS, gateway=gateway))
        for c in [int(x) for x in a.clients.split(",")]:
            psql(db, args, "SELECT pg_stat_reset()")
            r = subprocess.run(["pgbench", *args, "-n", "-M", "prepared", "-c", str(c), "-j", str(min(c, 4)), "-T", str(a.seconds),
                                "-f", f"{pay}@1", "-f", f"{top}@1", "-r", db], capture_output=True, text=True)
            if r.returncode:
                sys.exit(f"pgbench failed: {r.stderr.strip()[-1500:]}")
            tps = float(re.search(r"tps = ([0-9.]+)", r.stdout).group(1))
            lat = float(re.search(r"latency average = ([0-9.]+) ms", r.stdout).group(1))
            failed = int(re.search(r"number of failed transactions: (\d+)", r.stdout).group(1)) if "failed transactions" in r.stdout else 0
            locks = psql(db, args, "SELECT coalesce(sum(deadlocks), 0) FROM pg_stat_database WHERE datname = current_database()")
            out["levels"].append({"clients": c, "tps": round(tps, 1), "latency_ms": round(lat, 2), "failed": failed,
                                  "deadlocks": int(locks)})
            print(f"  {c:>3} clients: {tps:8.1f} postings/s, {lat:7.2f} ms average, {failed} failed", flush=True)
    out["reconcile_mismatches"] = int(psql(db, args, "SELECT (fin.reconcile_wallets()).mismatches"))
    print(json.dumps(out, indent=1))
    if a.json:
        open(a.json, "w").write(json.dumps(out, indent=1))
    return 0 if out["reconcile_mismatches"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
