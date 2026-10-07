#!/usr/bin/env python3
"""Production-size volume for staging (audit T3-08, T3-09): history the load tests, migration rehearsals and query plans
must run against, generated from the seeded data so every row is consistent with the schema's rules.

    python3 db/tools/generate_volume.py <database> --months 12 --bookings-per-day 3000 --vehicles 300 \
            --position-seconds 15 [psql connection args...]

What it writes (as the owner, in batches, with business triggers off for speed; the checks at the end prove the result):
* bookings, their passengers and tickets for the past --months, cloned from the seeded bookings (new references, keys
  and dates), each paid as balanced ledger transactions (from the passenger's wallet after a matching sandbox top-up, or
  by card through the gateway clearing wallet when the booker has no wallet);
* positions for the last 7 days (the retention) for --vehicles vehicles, one every --position-seconds while in service
  (16 hours a day), in the daily partitions;
* outbox events already delivered, one per booking, inside their retention.

Then wallet balances are set from the ledger, statistics refreshed, and the run fails unless wallets reconcile, every
ledger transaction balances, and no reference points to a missing row. Live inventory (future trips and seats) still
comes from publishing trips normally; history does not consume seats.

Staging only: refuses to run on a database whose setting deploy.environment is 'production'.
"""
import argparse
import json
import subprocess
import sys
import time


def psql(db, args, sql, single=True):
    r = subprocess.run(["psql", *args, "-d", db, "-At", "-v", "ON_ERROR_STOP=1", "-c", sql], capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"psql failed: {r.stderr.strip()[:800]}")
    out = r.stdout
    return out.strip().splitlines()[-1] if (single and out.strip()) else out


CLONE_DAY = """
SET session_replication_role = replica;
WITH src AS (SELECT b.* FROM sales.booking b WHERE b.booking_ref NOT LIKE 'V%' ORDER BY random() LIMIT {n}),
pick AS (SELECT row_number() OVER () AS k, src.* FROM src CROSS JOIN generate_series(1, {reps}) LIMIT {per_day}),
nb AS (
  INSERT INTO sales.booking (booking_ref, trip_id, company_id, booker_party_id, booker_user_id, channel_id, currency, total_amount,
                             price_breakdown, rules_version, idempotency_key, status, pay_method, confirmed_at, cancelled_at,
                             cancel_reason, created_at, updated_at)
  SELECT 'V' || upper(lpad(to_hex({day} * 100000 + k), 7, '0')), trip_id, company_id, booker_party_id, booker_user_id,
         channel_id, currency, total_amount, price_breakdown, rules_version, 'vol-' || {day} || '-' || k || '-' || md5(random()::text),
         status, 'WALLET', CASE WHEN confirmed_at IS NOT NULL OR status IN ('CONFIRMED', 'COMPLETED') THEN ts + interval '1 minute' END,
         CASE WHEN status = 'CANCELLED' THEN ts + interval '1 hour' END, CASE WHEN status = 'CANCELLED' THEN 'volume' END, ts, ts
    FROM (SELECT pick.*, (current_date - {day}) + (k % 86400) * interval '1 second' AS ts FROM pick) pick RETURNING id, booker_party_id, currency, total_amount, created_at, status)
SELECT count(*) FROM nb;
"""

CLONE_CHILDREN = """
SET session_replication_role = replica;
-- one passenger and one ticket per cloned booking, copied from a seeded ticket of the same trip
WITH nb AS (SELECT b.id, b.trip_id, b.created_at FROM sales.booking b
             WHERE b.booking_ref LIKE 'V%' AND NOT EXISTS (SELECT 1 FROM sales.passenger p WHERE p.booking_id = b.id)),
src AS (SELECT DISTINCT ON (t.trip_id) t.trip_id, t.from_seq, t.to_seq, t.seat_no, t.cabin, t.fare_brand_code, t.fare_amount,
               t.total_amount, t.rules_snapshot, t.status, p.full_name, p.passenger_category, p.first_name, p.last_name,
               p.father_name, p.grandfather_name, p.nationality, p.id_type, p.id_no_last4
          FROM sales.ticket t JOIN sales.passenger p ON p.id = t.passenger_id ORDER BY t.trip_id, t.id),
np AS (INSERT INTO sales.passenger (booking_id, full_name, passenger_category, first_name, last_name, father_name, grandfather_name,
                                    nationality, id_type, id_no_last4, created_at)
       SELECT nb.id, s.full_name, s.passenger_category, s.first_name, s.last_name, s.father_name, s.grandfather_name, s.nationality,
              s.id_type, s.id_no_last4, nb.created_at
         FROM nb JOIN src s ON s.trip_id = nb.trip_id RETURNING id, booking_id)
INSERT INTO sales.ticket (ticket_no, booking_id, passenger_id, trip_id, from_seq, to_seq, seat_no, cabin, fare_brand_code, fare_amount,
                          total_amount, rules_snapshot, status, created_at)
SELECT 'VT' || np.id || substr(md5(random()::text), 1, 6), nb.id, np.id, nb.trip_id, s.from_seq, s.to_seq, s.seat_no, s.cabin,
       s.fare_brand_code, s.fare_amount, s.total_amount, s.rules_snapshot, s.status, nb.created_at
  FROM np JOIN nb ON nb.id = np.booking_id JOIN src s ON s.trip_id = nb.trip_id;
"""

LEDGER = """
SET session_replication_role = replica;
-- each cloned booking is paid, as balanced ledger transactions: from the passenger's wallet after a sandbox top-up when the
-- booker has one, otherwise by card through the gateway clearing wallet
WITH nb AS (SELECT b.id, b.booker_party_id, b.company_id, b.currency, b.total_amount, b.created_at FROM sales.booking b
             WHERE b.booking_ref LIKE 'V%' AND NOT EXISTS (SELECT 1 FROM fin.ledger_txn t WHERE t.ref_type = 'booking' AND t.ref_id = b.id)),
w AS (SELECT nb.*, (SELECT uw.id FROM fin.wallet uw WHERE uw.owner_party_id = nb.booker_party_id AND uw.wallet_type = 'USER'
                      AND uw.currency = nb.currency ORDER BY uw.id LIMIT 1) AS user_w,
             cw.id AS company_w, gw.id AS gateway_w FROM nb
        JOIN fin.wallet cw ON cw.company_id = nb.company_id AND cw.wallet_type = 'COMPANY' AND cw.currency = nb.currency
        JOIN fin.wallet gw ON gw.wallet_type = 'GATEWAY_CLEARING' AND gw.currency = nb.currency),
topup AS (INSERT INTO fin.ledger_txn (txn_type, currency, ref_type, idempotency_key, memo, created_at)
          SELECT 'TOPUP', currency, NULL, 'vol-topup-' || id, 'volume', created_at - interval '1 minute' FROM w
           WHERE user_w IS NOT NULL RETURNING id, idempotency_key),
pay AS (INSERT INTO fin.ledger_txn (txn_type, currency, ref_type, ref_id, idempotency_key, memo, created_at)
        SELECT 'BOOKING_PAY', currency, 'booking', id, 'vol-pay-' || id, 'volume', created_at FROM w RETURNING id, ref_id),
e1 AS (INSERT INTO fin.ledger_entry (txn_id, wallet_id, direction, amount, created_at)
       SELECT t.id, w.gateway_w, 'DR', w.total_amount, w.created_at FROM topup t JOIN w ON t.idempotency_key = 'vol-topup-' || w.id
       UNION ALL
       SELECT t.id, w.user_w, 'CR', w.total_amount, w.created_at FROM topup t JOIN w ON t.idempotency_key = 'vol-topup-' || w.id
       RETURNING 1)
INSERT INTO fin.ledger_entry (txn_id, wallet_id, direction, amount, created_at)
SELECT p.id, coalesce(w.user_w, w.gateway_w), 'DR', w.total_amount, w.created_at FROM pay p JOIN w ON w.id = p.ref_id
UNION ALL
SELECT p.id, w.company_w, 'CR', w.total_amount, w.created_at FROM pay p JOIN w ON w.id = p.ref_id;
"""

POSITIONS = """
SET session_replication_role = replica;
INSERT INTO ops.geo_event (ts, vehicle_id, lat, lng, accuracy_m, speed_kmh, source, provider, trust, received_at)
SELECT d + make_interval(secs => s), v.id, 33.5 + (v.id % 50) * 0.01 + s * 1e-6, 36.3 + (v.id % 37) * 0.01 + s * 1e-6, 8, 70,
       'DRIVER_APP', 'GPS', 'HIGH', d + make_interval(secs => s + 1)
  FROM (SELECT id FROM fleet.vehicle ORDER BY id LIMIT {vehicles}) v,
       generate_series(6 * 3600, 22 * 3600 - 1, {step}) s
 CROSS JOIN (SELECT (current_date - {day})::timestamptz AS d) dd;
"""

OUTBOX = """
SET session_replication_role = replica;
INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, payload, status, created_at, published_at, aggregate_seq)
SELECT 'booking.confirmed', 'booking', b.id, jsonb_build_object('booking_ref', b.booking_ref), 'PUBLISHED', b.created_at, b.created_at, 1
  FROM sales.booking b WHERE b.booking_ref LIKE 'V%' AND b.created_at > now() - interval '30 days'
   AND NOT EXISTS (SELECT 1 FROM sys.outbox_event o WHERE o.aggregate_type = 'booking' AND o.aggregate_id = b.id);
"""

FINISH = """
SET session_replication_role = replica;
UPDATE fin.wallet w SET balance = s.ledger
  FROM (SELECT w2.id, coalesce(sum(CASE e.direction WHEN 'CR' THEN e.amount ELSE -e.amount END), 0) AS ledger
          FROM fin.wallet w2 LEFT JOIN fin.ledger_entry e ON e.wallet_id = w2.id GROUP BY w2.id) s
 WHERE s.id = w.id AND w.balance <> s.ledger;
SET session_replication_role = origin;
ANALYZE;
"""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter, add_help=False)
    ap.add_argument("--help", action="help")
    ap.add_argument("--months", type=int, default=12)
    ap.add_argument("--bookings-per-day", type=int, default=3000)
    ap.add_argument("--vehicles", type=int, default=300)
    ap.add_argument("--position-seconds", type=int, default=15)
    a, rest = ap.parse_known_args()
    db, args = rest[0], rest[1:]
    if psql(db, args, "SELECT coalesce((SELECT value #>> '{}' FROM sys.setting WHERE key = 'deploy.environment'), 'staging')") == "production":
        sys.exit("refusing to generate synthetic data in a production database")
    t0 = time.time()
    days = a.months * 30
    seeded = int(psql(db, args, "SELECT count(*) FROM sales.booking WHERE booking_ref NOT LIKE 'V%'"))
    if seeded == 0:
        sys.exit("seed the database first (backend/scripts/seed_demo.py): history is cloned from seeded bookings")
    reps = max(1, a.bookings_per_day // seeded + 1)
    for day in range(1, days + 1):
        psql(db, args, CLONE_DAY.format(n=seeded, reps=reps, per_day=a.bookings_per_day, day=day))
        if day % 30 == 0 or day == days:
            psql(db, args, CLONE_CHILDREN)
            psql(db, args, LEDGER)
            print(f"  {day}/{days} days of bookings ({time.time() - t0:.0f}s)", flush=True)
    psql(db, args, "SELECT sys.ensure_daily_partitions('ops.geo_event', 7, 7)")
    for day in range(0, 7):
        psql(db, args, POSITIONS.format(vehicles=a.vehicles, step=a.position_seconds, day=day))
    psql(db, args, OUTBOX)
    psql(db, args, FINISH)
    checks = json.loads(psql(db, args, """SELECT json_build_object(
        'bookings', (SELECT count(*) FROM sales.booking), 'tickets', (SELECT count(*) FROM sales.ticket),
        'ledger_txns', (SELECT count(*) FROM fin.ledger_txn), 'positions', (SELECT count(*) FROM ops.geo_event),
        'database', pg_size_pretty(pg_database_size(current_database())),
        'wallet_mismatches', (fin.reconcile_wallets()).mismatches,
        'unbalanced_txns', (SELECT count(*) FROM (SELECT txn_id FROM fin.ledger_entry GROUP BY txn_id
                             HAVING sum(CASE WHEN direction = 'DR' THEN amount ELSE -amount END) <> 0) x),
        'unpaid_bookings', (SELECT count(*) FROM sales.booking b WHERE b.booking_ref LIKE 'V%' AND NOT EXISTS
                             (SELECT 1 FROM fin.ledger_txn t WHERE t.ref_type = 'booking' AND t.ref_id = b.id)),
        'orphans', (SELECT coalesce(sum(orphans), 0) FROM sys.find_orphans()))"""))
    checks["seconds"] = round(time.time() - t0)
    print(json.dumps(checks, indent=1))
    ok = checks["wallet_mismatches"] == 0 and checks["unbalanced_txns"] == 0 and checks["orphans"] == 0 and checks["unpaid_bookings"] == 0
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
