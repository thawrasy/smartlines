"""Cost of row-level security on the hot queries (third-party audit R-4 and R-12).

Each query runs repeatedly twice: as the table owner (row-level security bypassed, the trusted path) and as the
application role inside a company's context (every policy applied). The report gives the median and p95 of the
server-side execution time from EXPLAIN ANALYZE, and the overhead of the policies.

    MASSLAK_OWNER_URL=postgresql://... python -m loadtest.rls_benchmark [--runs 50]
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import statistics
import sys

import asyncpg

QUERIES = {
    "trip search": """SELECT t.id, t.departure_at, t.base_price FROM ops.trip t JOIN net.route r ON r.id = t.route_id
                        WHERE t.status = 'PUBLISHED' AND t.departure_at BETWEEN now() AND now() + interval '7 days'
                        ORDER BY t.departure_at LIMIT 50""",
    "seat map": """SELECT s.seat_no, s.seg, s.status FROM ops.seat_segment s
                    WHERE s.trip_id = (SELECT id FROM ops.trip WHERE status = 'PUBLISHED' ORDER BY departure_at DESC LIMIT 1)""",
    "company bookings": """SELECT b.id, b.booking_ref, b.total_amount FROM sales.booking b ORDER BY b.created_at DESC LIMIT 100""",
    "company tickets of a trip": """SELECT k.ticket_no, p.full_name FROM sales.ticket k JOIN sales.passenger p ON p.id = k.passenger_id
                                     WHERE k.trip_id IN (SELECT id FROM ops.trip ORDER BY departure_at DESC LIMIT 5)""",
    "wallet balance": """SELECT w.id, w.balance FROM fin.wallet w ORDER BY w.id LIMIT 50""",
    "ledger of a wallet": """SELECT e.amount, e.direction FROM fin.ledger_entry e
                              WHERE e.wallet_id = (SELECT id FROM fin.wallet ORDER BY id LIMIT 1) ORDER BY e.id DESC LIMIT 200""",
}


async def timing(conn, sql: str) -> float:
    plan = await conn.fetchval(f"EXPLAIN (ANALYZE, FORMAT JSON) {sql}")  # nosec B608
    plan = json.loads(plan) if isinstance(plan, str) else plan
    return plan[0]["Execution Time"] + plan[0].get("Planning Time", 0)


async def run(url: str, runs: int) -> list[dict]:
    conn = await asyncpg.connect(url)
    try:
        company = await conn.fetchrow("""SELECT c.id, m.user_id FROM iam.company c JOIN iam.company_member m ON m.company_id = c.id
                                          WHERE c.company_type = 'CARRIER' AND m.status = 'ACTIVE' ORDER BY c.id LIMIT 1""")
        out = []
        for name, sql in QUERIES.items():
            owner, app = [], []
            for _ in range(runs):
                owner.append(await timing(conn, sql))
                tr = conn.transaction()
                await tr.start()
                try:
                    await conn.execute("SET LOCAL ROLE masslak_app")
                    await conn.execute("SELECT sys.set_context($1, $2, 'COMPANY')", company["user_id"], company["id"])
                    app.append(await timing(conn, sql))
                finally:
                    await tr.rollback()
            o, a = statistics.median(owner), statistics.median(app)
            out.append({"query": name, "owner_median_ms": round(o, 3), "rls_median_ms": round(a, 3),
                        "rls_p95_ms": round(sorted(app)[int(len(app) * 0.95) - 1], 3),
                        "overhead_ms": round(a - o, 3), "overhead_pct": round((a - o) / o * 100, 1) if o else None})
        return out
    finally:
        await conn.close()


def main() -> int:
    ap = argparse.ArgumentParser(prog="python -m loadtest.rls_benchmark")
    ap.add_argument("--runs", type=int, default=50)
    ap.add_argument("--json")
    args = ap.parse_args()
    url = os.environ.get("MASSLAK_OWNER_URL")
    if not url:
        print("set MASSLAK_OWNER_URL (the table owner's connection)", file=sys.stderr)
        return 2
    rows = asyncio.run(run(url, args.runs))
    print(f"{'query':28} {'owner p50':>10} {'RLS p50':>10} {'RLS p95':>10} {'overhead':>10}")
    for r in rows:
        print(f"{r['query']:28} {r['owner_median_ms']:10} {r['rls_median_ms']:10} {r['rls_p95_ms']:10} {str(r['overhead_pct']) + '%':>10}")
    if args.json:
        with open(args.json, "w") as fh:
            json.dump(rows, fh, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
