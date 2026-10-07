#!/usr/bin/env python3
"""Migration rehearsal under load (audit T3-08): applies the newest schema files to a database of the previous release,
filled with synthetic volume, while application-like traffic runs, and measures what the migration costs.

    python3 db/tools/migration_rehearsal.py --base 1047 [--scale 200000] [--report <dir>] [psql connection args...]

Steps:
1. build a scratch database up to schema file --base (db/build.sh with MASSLAK_BUILD_UNTIL);
2. fill the tables the newer files touch with --scale rows each (positions, outbox events, files, sensitive-read log,
   ledger), as owner with triggers off, so the volume costs seconds rather than hours;
3. start traffic: writers and readers on the same tables, each operation timed;
4. run db/upgrade.sh (with its lock and statement timeouts) and sample pg_locks every 100 ms: the longest time any
   ACCESS EXCLUSIVE lock was held or waited for, and how many sessions queued behind it;
5. report per run: migration time, WAL written, the lock profile, and the traffic's p50, p99, max and errors during the
   migration compared with before it. The scratch database is dropped at the end.

Stop criteria for production (docs/database/MIGRATION_PLANS.md): a statement waiting more than MASSLAK_LOCK_TIMEOUT
for a lock fails and rolls back by itself; if the rehearsal shows an exclusive lock longer than 2 s on a table that the
booking path writes, or traffic p99 above 1 s, the migration is split (expand / backfill in batches / validate) before
it goes to production.
"""
import argparse
import asyncio
import json
import os
import statistics
import subprocess
import sys
import time
import uuid

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

FILL = {
    "ops.geo_event": """INSERT INTO ops.geo_event (ts, vehicle_id, lat, lng, accuracy_m, source)
        SELECT now() - (g % 518400) * interval '1 second', (SELECT min(id) FROM fleet.vehicle), 33.5 + (g % 1000) / 1e5,
               36.3 + (g % 997) / 1e5, 8, 'DRIVER_APP' FROM generate_series(1, {n}) g""",
    "sys.outbox_event": """INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, payload, status, published_at)
        SELECT 'rehearsal.event', 'booking', g, '{{}}', 'PUBLISHED', now() FROM generate_series(1, {n}) g""",
    "ref.file_object": """INSERT INTO ref.file_object (storage_key, mime_type, size_bytes, sha256)
        SELECT 'rehearsal/' || g, 'application/pdf', 1000, '\\x00' FROM generate_series(1, {n}) g""",
    "audit.data_access_log": """INSERT INTO audit.data_access_log (user_id, object_type, object_id, fields, purpose, request_id)
        SELECT (SELECT min(id) FROM iam.app_user), 'document', g, '{{file}}', 'rehearsal', gen_random_uuid() FROM generate_series(1, {n}) g""",
}


def sh(cmd, env=None):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, env={**os.environ, **(env or {})}).stdout


def quantiles(xs):
    if not xs:
        return {"n": 0}
    xs = sorted(xs)
    q = statistics.quantiles(xs, n=100, method="inclusive") if len(xs) > 1 else [xs[0]] * 99
    return {"n": len(xs), "p50_ms": round(q[49], 1), "p99_ms": round(q[98], 1), "max_ms": round(xs[-1], 1)}


async def traffic(dsn, stop, results):
    """Small writes and reads on the tables a migration touches, like the API and the worker do."""
    import asyncpg
    conn = await asyncpg.connect(dsn)
    await conn.execute("SET lock_timeout = '10s'")
    ops = [
        ("geo_insert", "INSERT INTO ops.geo_event (ts, vehicle_id, lat, lng, accuracy_m) SELECT now(), min(id), 33.5, 36.3, 9 FROM fleet.vehicle"),
        ("outbox_insert", "INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, payload) VALUES ('rehearsal.live', 'booking', 1, '{}')"),
        ("outbox_read", "SELECT count(*) FROM sys.outbox_event WHERE status = 'PENDING'"),
        ("file_read", "SELECT id FROM ref.file_object ORDER BY id DESC LIMIT 5"),
        ("ledger_read", "SELECT count(*) FROM fin.ledger_txn WHERE created_at > now() - interval '1 day'"),
    ]
    i = 0
    while not stop.is_set():
        name, sql = ops[i % len(ops)]
        i += 1
        t0 = time.perf_counter()
        try:
            await conn.execute(sql)
            ok = True
        except Exception as exc:          # a lock timeout or a refused statement is what we measure
            ok = False
            results.setdefault("errors", []).append(f"{name}: {type(exc).__name__}")
        results.setdefault(results["phase"], []).append(((time.perf_counter() - t0) * 1000, ok))
        await asyncio.sleep(0.01)
    await conn.close()


async def lock_sampler(dsn, stop, out):
    import asyncpg
    conn = await asyncpg.connect(dsn)
    while not stop.is_set():
        r = await conn.fetchrow(
            """SELECT coalesce(max(extract(epoch FROM now() - a.xact_start)) FILTER (WHERE l.mode = 'AccessExclusiveLock' AND l.granted), 0) AS held,
                      count(*) FILTER (WHERE NOT l.granted) AS waiting
                 FROM pg_locks l JOIN pg_stat_activity a ON a.pid = l.pid
                WHERE a.datname = current_database() AND l.locktype = 'relation' AND a.pid <> pg_backend_pid()""")
        out["max_exclusive_s"] = max(out.get("max_exclusive_s", 0.0), float(r["held"]))
        out["max_waiting"] = max(out.get("max_waiting", 0), r["waiting"])
        await asyncio.sleep(0.1)
    await conn.close()


async def rehearse(args, conn_args, db):
    import asyncpg
    host = conn_args[conn_args.index("-h") + 1] if "-h" in conn_args else "localhost"
    user = conn_args[conn_args.index("-U") + 1] if "-U" in conn_args else os.environ.get("PGUSER", "postgres")
    dsn = f"postgresql://{user}:{os.environ.get('PGPASSWORD', '')}@{host}:5432/{db}"
    owner = await asyncpg.connect(dsn)
    report = {"base": args.base, "scale": args.scale, "fill_s": {}}
    # one account to act as the reader of sensitive data (a schema-only build has none)
    await owner.execute("""INSERT INTO iam.party (party_type, legal_name) VALUES ('PERSON', 'Rehearsal Reader');
                           INSERT INTO iam.app_user (party_id, account_kind, email)
                           SELECT id, 'PLATFORM', 'rehearsal@masslak.invalid' FROM iam.party WHERE legal_name = 'Rehearsal Reader'""")
    await owner.execute("SET session_replication_role = replica")        # bulk volume without triggers
    for table, sql in FILL.items():
        t0 = time.perf_counter()
        await owner.execute(sql.format(n=args.scale))
        report["fill_s"][table] = round(time.perf_counter() - t0, 1)
    await owner.execute("SET session_replication_role = origin")
    await owner.execute("ANALYZE")
    report["database_size"] = await owner.fetchval("SELECT pg_size_pretty(pg_database_size(current_database()))")
    results = {"phase": "before"}
    stop = asyncio.Event()
    workers = [asyncio.create_task(traffic(dsn, stop, results)) for _ in range(args.clients)]
    await asyncio.sleep(args.warmup)
    results["phase"] = "during"
    locks = {}
    lstop = asyncio.Event()
    sampler = asyncio.create_task(lock_sampler(dsn, lstop, locks))
    wal0 = await owner.fetchval("SELECT pg_current_wal_lsn()")
    t0 = time.perf_counter()
    proc = await asyncio.create_subprocess_exec(os.path.join(ROOT, "db", "upgrade.sh"), db, *conn_args,
                                                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
    out, _ = await proc.communicate()
    report["migration_s"] = round(time.perf_counter() - t0, 1)
    report["migration_ok"] = proc.returncode == 0
    report["migration_output"] = out.decode()[-1500:]
    report["wal_mb"] = round(float(await owner.fetchval("SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), $1::pg_lsn)", wal0)) / 1e6, 1)
    lstop.set()
    await sampler
    results["phase"] = "after"
    await asyncio.sleep(2)
    stop.set()
    await asyncio.gather(*workers)
    report["locks"] = {"max_access_exclusive_held_s": round(locks.get("max_exclusive_s", 0.0), 2),
                       "max_sessions_waiting": locks.get("max_waiting", 0)}
    for phase in ("before", "during", "after"):
        xs = results.get(phase, [])
        report[f"traffic_{phase}"] = {**quantiles([ms for ms, _ in xs]), "errors": sum(1 for _, ok in xs if not ok)}
    report["traffic_error_kinds"] = sorted(set(results.get("errors", [])))
    report["applied"] = await owner.fetchval("SELECT file FROM sys.schema_file ORDER BY split_part(file, '_', 1)::int DESC LIMIT 1")
    await owner.close()
    during = report["traffic_during"]
    report["within_criteria"] = (report["migration_ok"] and report["locks"]["max_access_exclusive_held_s"] <= 2.0
                                 and during.get("p99_ms", 0) <= 1000 and during["errors"] == 0)
    return report


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter, add_help=False)
    ap.add_argument("--help", action="help")
    ap.add_argument("--base", required=True, help="last schema file of the previous release, e.g. 1047")
    ap.add_argument("--scale", type=int, default=200000)
    ap.add_argument("--clients", type=int, default=8)
    ap.add_argument("--warmup", type=float, default=5)
    ap.add_argument("--report", default=".")
    args, conn = ap.parse_known_args()
    db = f"masslak_rehearsal_{uuid.uuid4().hex[:6]}"
    sh(["createdb", *conn, db])
    try:
        sh([os.path.join(ROOT, "db", "build.sh"), db, *conn], env={"MASSLAK_BUILD_UNTIL": args.base})
        report = asyncio.run(rehearse(args, conn, db))
    finally:
        subprocess.run(["dropdb", *conn, "--if-exists", db], capture_output=True)
    os.makedirs(args.report, exist_ok=True)
    with open(os.path.join(args.report, f"migration_rehearsal_{report['applied'].split('_')[0]}.json"), "w") as f:
        json.dump(report, f, indent=1)
    print(json.dumps({k: v for k, v in report.items() if k != "migration_output"}, indent=1))
    return 0 if report["within_criteria"] else 1


if __name__ == "__main__":
    sys.exit(main())
