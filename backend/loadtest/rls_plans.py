"""Query plans of row-level security at a large number of trips (independent review, round 8, T-09; PERFORMANCE_BASELINE.md).

Seat and ticket rows are visible through the visibility of their trip (an EXISTS on ops.trip in their policies). On a
small database the planner may scan the visible trips; the question is whether, with many trips, it looks up the one
trip by its key instead. This tool answers it with EXPLAIN (ANALYZE, BUFFERS) in a carrier's context, as the
application role (its context signed as the API signs it, so the tool needs the server's signing settings), after adding synthetic trips to a scratch database:

    MASSLAK_OWNER_URL=postgresql://... MASSLAK_DATABASE_URL=postgresql://... python -m loadtest.rls_plans --trips 200000 --seats 44 --scratch [--json out.json]

--trips clones published trips of the seeded carriers to N more (future dates spread over a year, the source trip's vehicle
without its busy period, no service number) with --seats seats each, as the owner with triggers off; --scratch must be given, and a database whose
deploy.environment is 'production' is refused. The verdict fails when a query that names one trip, or five, reads
ops.trip or ops.seat_segment by a sequential scan.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
import uuid

import asyncpg

from app.db import Context, apply_context, prepare_connection

QUERIES = {   # name -> (sql, the trips $1 names: "one", "five" or None)
    "seat map of one trip": ("SELECT s.seat_no, s.seg, s.status FROM ops.seat_segment s WHERE s.trip_id = $1", "one"),
    "tickets of five trips": ("""SELECT k.ticket_no, p.full_name FROM sales.ticket k JOIN sales.passenger p ON p.id = k.passenger_id
                                  WHERE k.trip_id = ANY($1::bigint[])""", "five"),
    "seats of five trips": ("""SELECT s.trip_id, count(*) FILTER (WHERE s.status = 'AVAILABLE') FROM ops.seat_segment s
                                WHERE s.trip_id = ANY($1::bigint[]) GROUP BY s.trip_id""", "five"),
    "trip search, next 7 days": ("""SELECT t.id, t.departure_at FROM ops.trip t WHERE t.status = 'PUBLISHED'
                                     AND t.departure_at BETWEEN now() AND now() + interval '7 days' ORDER BY t.departure_at LIMIT 50""", None),
}

ADD_TRIPS = """
WITH src AS (SELECT array_agg(id ORDER BY id) AS ids FROM ops.trip WHERE status = 'PUBLISHED' AND company_id = ANY($3::bigint[])),
n AS (SELECT g, src.ids[1 + g % cardinality(src.ids)] AS tid FROM src, generate_series(1, $1) g)
INSERT INTO ops.trip (trip_no, company_id, route_id, vehicle_id, trip_type, transport_mode, service_type, departure_at, arrival_at,
                      status, seats_total, segments_count, currency, base_price, published_at, service_date)
SELECT 'PLAN-' || n.g, t.company_id, t.route_id, t.vehicle_id, t.trip_type, t.transport_mode, t.service_type,
       now() + make_interval(mins => 30 + (n.g * 37) % 525600), now() + make_interval(mins => 330 + (n.g * 37) % 525600),
       'PUBLISHED', $2, 1, t.currency, t.base_price, now(), (now() + make_interval(mins => 30 + (n.g * 37) % 525600))::date
  FROM n JOIN ops.trip t ON t.id = n.tid
RETURNING id
"""


def nodes(plan: dict):
    yield plan
    for p in plan.get("Plans", []):
        yield from nodes(p)


async def run(url: str, app_url: str, trips: int, seats: int, scratch: bool) -> dict:
    conn = await asyncpg.connect(url)
    try:
        env = await conn.fetchval("SELECT value #>> '{}' FROM sys.setting WHERE key = 'deploy.environment'")
        if env == "production":
            raise SystemExit("refused: this database is production")
        carriers = [r["id"] for r in await conn.fetch(
            "SELECT DISTINCT company_id AS id FROM ops.trip WHERE status = 'PUBLISHED'")]
        added = 0
        if trips:
            if not scratch:
                raise SystemExit("--trips writes synthetic trips: give --scratch on a database made for it")
            async with conn.transaction():
                await conn.execute("SET LOCAL session_replication_role = replica")     # history: no triggers, as generate_volume
                ids = [r["id"] for r in await conn.fetch(ADD_TRIPS, trips, seats, carriers)]
                await conn.execute("""INSERT INTO ops.seat_segment (trip_id, seat_no, seg, status)
                                      SELECT t, s, 0, 'AVAILABLE' FROM unnest($1::bigint[]) t, generate_series(1, $2) s""", ids, seats)
                added = len(ids)
            await conn.execute("ANALYZE ops.trip; ANALYZE ops.seat_segment; ANALYZE sales.ticket")
        counts = await conn.fetchrow("SELECT (SELECT count(*) FROM ops.trip) AS trips, (SELECT count(*) FROM ops.seat_segment) AS seats")
        company = await conn.fetchrow("""SELECT c.id, m.user_id FROM iam.company c JOIN iam.company_member m ON m.company_id = c.id
                                          WHERE c.company_type = 'CARRIER' AND m.status = 'ACTIVE'
                                            AND EXISTS (SELECT 1 FROM sales.ticket k JOIN ops.trip t ON t.id = k.trip_id WHERE t.company_id = c.id)
                                          ORDER BY c.id LIMIT 1""")
        one = await conn.fetchval("SELECT trip_id FROM sales.ticket k JOIN ops.trip t ON t.id = k.trip_id WHERE t.company_id = $1 LIMIT 1", company["id"])
        five = [r["id"] for r in await conn.fetch("SELECT DISTINCT k.trip_id AS id FROM sales.ticket k JOIN ops.trip t ON t.id = k.trip_id "
                                                  "WHERE t.company_id = $1 LIMIT 5", company["id"])]
        results = []
        app = await asyncpg.connect(app_url)          # the API's own login: the role the policies apply to
        await prepare_connection(app)                 # as the API prepares it (no set_config for JIT, 1080)
        for name, (sql, keyed) in QUERIES.items():
            tr = app.transaction()
            await tr.start()
            try:
                # the context with its signed ticket, as the API sets it (1080)
                await apply_context(app, Context(request_id=uuid.uuid4(), ip="127.0.0.1", user_id=company["user_id"],
                                                  company_id=company["id"], scope="COMPANY"))
                params = {"one": [one], "five": [five], None: []}[keyed]
                raw = await app.fetchval(f"EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {sql}", *params)  # nosec B608
            finally:
                await tr.rollback()
            plan = (json.loads(raw) if isinstance(raw, str) else raw)[0]
            ns = list(nodes(plan["Plan"]))
            seq = sorted({f"{n.get('Schema', '')}.{n.get('Relation Name')}" for n in ns
                          if n["Node Type"] == "Seq Scan" and n.get("Relation Name") in ("trip", "seat_segment")})
            results.append({
                "query": name, "names_trips": keyed or "none",
                "execution_ms": round(plan["Execution Time"], 3), "planning_ms": round(plan["Planning Time"], 3),
                "shared_buffers": plan["Plan"].get("Shared Hit Blocks", 0) + plan["Plan"].get("Shared Read Blocks", 0),
                "scans": sorted({f"{n['Node Type']} {n.get('Relation Name')}" for n in ns if n.get("Relation Name")}),
                "sequential_on_trip_or_seats": seq,
                "ok": not (keyed and seq)})
        await app.close()
        return {"trips": counts["trips"], "seat_rows": counts["seats"], "added_trips": added, "company": company["id"],
                "queries": results, "verdict": "PASS" if all(r["ok"] for r in results) else "FAIL"}
    finally:
        await conn.close()


def main() -> int:
    ap = argparse.ArgumentParser(prog="python -m loadtest.rls_plans")
    ap.add_argument("--trips", type=int, default=0)
    ap.add_argument("--seats", type=int, default=44)
    ap.add_argument("--scratch", action="store_true")
    ap.add_argument("--json")
    a = ap.parse_args()
    url = os.environ.get("MASSLAK_OWNER_URL")
    if not url or not os.environ.get("MASSLAK_DATABASE_URL"):
        print("set MASSLAK_OWNER_URL (the table owner) and MASSLAK_DATABASE_URL (the API's login) to the same database",
              file=sys.stderr)
        return 2
    out = asyncio.run(run(url, os.environ.get("MASSLAK_DATABASE_URL", ""), a.trips, a.seats, a.scratch))
    print(f"trips {out['trips']:,}, seat rows {out['seat_rows']:,}")
    for r in out["queries"]:
        print(f"{r['query']:28} {r['execution_ms']:>9} ms  plan {r['planning_ms']:>7} ms  {', '.join(r['scans'])}"
              + ("  SEQUENTIAL: " + ", ".join(r["sequential_on_trip_or_seats"]) if r["sequential_on_trip_or_seats"] else ""))
    print("verdict:", out["verdict"])
    if a.json:
        with open(a.json, "w") as fh:
            json.dump(out, fh, indent=1)
    return 0 if out["verdict"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
