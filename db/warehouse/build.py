#!/usr/bin/env python3
"""Builds and keeps the data warehouse (expert review of October 2026, stage D3; docs/database/WAREHOUSE.md).

    MASSLAK_DW_SOURCE="host=db dbname=masslak user=masslak_cdc password=..." \\
    MASSLAK_DW_URL="postgresql://postgres:...@warehouse/masslak_dw" \\
    python3 db/warehouse/build.py [--wait] [--refresh] [--refresh-every SECONDS] [--check] [--resync]

The primary publishes facts and dimensions without personal data (publication masslak_dw, schema file 1062). This
tool, run against the warehouse database:
  1. reads the published tables and columns from the primary (as masslak_cdc, the only login that may read them);
  2. creates the same tables in the warehouse (same schema and name, the published columns, the primary key; no
     foreign keys or checks: the primary already enforced them, and rows of different tables arrive independently);
  3. subscribes: the replication slot is created on the primary first, so the warehouse may also live in the same
     cluster; an existing subscription takes the new password and picks up tables added to the publication;
  4. creates the analysis layer, schema dw: daily sales by the market and local day of the departure station, trip
     load, daily ledger and payments, and dw.refresh() that refreshes them without blocking readers;
  5. grants reading to the role dw_reader, and creates the login dw_analyst when MASSLAK_DW_ANALYST_PASSWORD is set.
--wait waits until every table finished its first copy. --check prints the state as JSON and fails when a table is
not replicating, when the warehouse holds a column the primary does not publish, or when row counts differ (run it
while writes are quiet). --resync drops the subscription and the slot, empties the tables and copies them again: use
it after the primary dropped the slot (max_slot_wal_keep_size) or after columns were added to the publication.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time

PUBLICATION = SUBSCRIPTION = "masslak_dw"
_IDENT = re.compile(r"^[a-z_][a-z0-9_]*$")
# slot names are per cluster: a second warehouse of the same primary (a test copy) takes another one
SLOT = os.environ.get("MASSLAK_DW_SLOT") or "masslak_dw"

SOURCE_TABLES = r"""
SELECT coalesce(json_agg(json_build_object(
         'schema', pt.schemaname, 'table', pt.tablename,
         'columns', (SELECT json_agg(json_build_object('name', a.attname, 'type', format_type(a.atttypid, a.atttypmod),
                                                       'not_null', a.attnotnull) ORDER BY a.attnum)
                       FROM pg_attribute a
                      WHERE a.attrelid = format('%I.%I', pt.schemaname, pt.tablename)::regclass AND a.attname = ANY (pt.attnames)),
         'key', (SELECT json_agg(a.attname ORDER BY array_position(i.indkey::int2[], a.attnum))
                   FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey::int2[])
                  WHERE i.indrelid = format('%I.%I', pt.schemaname, pt.tablename)::regclass AND i.indisprimary))
         ORDER BY pt.schemaname, pt.tablename), '[]')
  FROM pg_publication_tables pt WHERE pt.pubname = 'masslak_dw'
"""

# The analysis layer. Days are local days: of the departure station for sales and trips (ref.city, else its market),
# of the currency's market for money. Materialized views refresh concurrently (each has a unique index).
DW = r"""
CREATE SCHEMA IF NOT EXISTS dw;
COMMENT ON SCHEMA dw IS 'Analysis views over the replicated facts and dimensions (db/warehouse/build.py)';
CREATE TABLE IF NOT EXISTS dw.refresh_log (view_name text PRIMARY KEY, refreshed_at timestamptz NOT NULL, seconds numeric NOT NULL);

CREATE OR REPLACE VIEW dw.trip_zone AS
SELECT t.id AS trip_id, t.company_id, s.country_code AS market, coalesce(c.timezone, m.time_zone, 'UTC') AS time_zone
  FROM ops.trip t
  JOIN net.route r ON r.id = t.route_id
  JOIN net.station s ON s.id = r.origin_station_id
  LEFT JOIN ref.city c ON c.id = s.city_id
  LEFT JOIN ref.market m ON m.country_code = s.country_code;

CREATE MATERIALIZED VIEW IF NOT EXISTS dw.sales_daily AS
SELECT (b.created_at AT TIME ZONE z.time_zone)::date AS day, z.market, b.company_id, ch.channel_type, b.pay_method,
       b.currency,
       count(*) AS bookings,
       count(*) FILTER (WHERE b.status IN ('CONFIRMED', 'COMPLETED')) AS confirmed,
       count(*) FILTER (WHERE b.status = 'CANCELLED') AS cancelled,
       coalesce(sum(b.total_amount) FILTER (WHERE b.status IN ('CONFIRMED', 'COMPLETED')), 0) AS amount
  FROM sales.booking b
  JOIN dw.trip_zone z ON z.trip_id = b.trip_id
  LEFT JOIN sales.channel ch ON ch.id = b.channel_id
 GROUP BY 1, 2, 3, 4, 5, 6
WITH NO DATA;
CREATE UNIQUE INDEX IF NOT EXISTS sales_daily_key ON dw.sales_daily (day, market, company_id, channel_type, pay_method, currency)
  NULLS NOT DISTINCT;

CREATE MATERIALIZED VIEW IF NOT EXISTS dw.trip_load AS
SELECT t.id AS trip_id, t.company_id, t.route_id, z.market, (t.departure_at AT TIME ZONE z.time_zone)::date AS departure_day,
       t.service_type, t.status, t.seats_total, t.currency,
       count(k.id) FILTER (WHERE k.status IN ('ISSUED', 'BOARDED', 'NO_SHOW')) AS tickets,
       count(k.id) FILTER (WHERE k.status = 'BOARDED') AS boarded,
       round(count(k.id) FILTER (WHERE k.status IN ('ISSUED', 'BOARDED', 'NO_SHOW'))::numeric / nullif(t.seats_total, 0), 4) AS load_factor,
       coalesce(sum(k.total_amount) FILTER (WHERE k.status IN ('ISSUED', 'BOARDED', 'NO_SHOW')), 0) AS revenue
  FROM ops.trip t
  JOIN dw.trip_zone z ON z.trip_id = t.id
  LEFT JOIN sales.ticket k ON k.trip_id = t.id
 GROUP BY t.id, z.market, z.time_zone
WITH NO DATA;
CREATE UNIQUE INDEX IF NOT EXISTS trip_load_key ON dw.trip_load (trip_id);

CREATE MATERIALIZED VIEW IF NOT EXISTS dw.ledger_daily AS
SELECT (x.created_at AT TIME ZONE coalesce(mz.time_zone, 'UTC'))::date AS day, x.txn_type, x.currency,
       count(*) AS transactions, sum(x.amount) AS amount
  FROM (SELECT t.id, t.created_at, t.txn_type, t.currency,
               (SELECT sum(e.amount) FROM fin.ledger_entry e WHERE e.txn_id = t.id AND e.direction = 'DR') AS amount
          FROM fin.ledger_txn t) x
  LEFT JOIN LATERAL (SELECT m.time_zone FROM ref.market m WHERE m.currency = x.currency
                      ORDER BY m.is_default DESC, m.country_code LIMIT 1) mz ON true
 GROUP BY 1, 2, 3
WITH NO DATA;
CREATE UNIQUE INDEX IF NOT EXISTS ledger_daily_key ON dw.ledger_daily (day, txn_type, currency);

CREATE MATERIALIZED VIEW IF NOT EXISTS dw.payments_daily AS
SELECT (p.created_at AT TIME ZONE coalesce(mz.time_zone, 'UTC'))::date AS day, p.purpose, p.method, p.provider_id, p.status,
       p.currency, count(*) AS payments, sum(p.amount) AS amount, sum(p.fee) AS fees, sum(p.platform_fee) AS platform_fees,
       sum(p.refunded_amount) AS refunded
  FROM fin.payment p
  LEFT JOIN LATERAL (SELECT m.time_zone FROM ref.market m WHERE m.currency = p.currency
                      ORDER BY m.is_default DESC, m.country_code LIMIT 1) mz ON true
 GROUP BY 1, 2, 3, 4, 5, 6
WITH NO DATA;
CREATE UNIQUE INDEX IF NOT EXISTS payments_daily_key ON dw.payments_daily (day, purpose, method, provider_id, status, currency)
  NULLS NOT DISTINCT;

-- Refreshes every analysis view; readers keep the previous figures while it runs (CONCURRENTLY needs one full
-- refresh first). Returns the views refreshed.
CREATE OR REPLACE FUNCTION dw.refresh() RETURNS integer LANGUAGE plpgsql AS $$
DECLARE v record; t0 timestamptz; n integer := 0;
BEGIN
  FOR v IN SELECT schemaname, matviewname, ispopulated FROM pg_matviews WHERE schemaname = 'dw' ORDER BY matviewname LOOP
    t0 := clock_timestamp();
    EXECUTE format('REFRESH MATERIALIZED VIEW %s %I.%I', CASE WHEN v.ispopulated THEN 'CONCURRENTLY' ELSE '' END,
                   v.schemaname, v.matviewname);
    INSERT INTO dw.refresh_log VALUES (v.matviewname, now(), extract(epoch FROM clock_timestamp() - t0))
      ON CONFLICT (view_name) DO UPDATE SET refreshed_at = excluded.refreshed_at, seconds = excluded.seconds;
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;

-- How current the warehouse is: replication from the primary, and the last refresh of each analysis view
CREATE OR REPLACE VIEW dw.freshness AS
SELECT 'subscription' AS part, s.subname AS name, s.latest_end_time AS as_of,
       extract(epoch FROM now() - s.last_msg_receipt_time) AS seconds_since_message
  FROM pg_stat_subscription s WHERE s.relid IS NULL
UNION ALL
SELECT 'view', r.view_name, r.refreshed_at, extract(epoch FROM now() - r.refreshed_at) FROM dw.refresh_log r;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dw_reader') THEN CREATE ROLE dw_reader NOLOGIN; END IF;
END $$;
REVOKE ALL ON FUNCTION dw.refresh() FROM PUBLIC;
COMMENT ON ROLE dw_reader IS 'Reads the warehouse: replicated facts and dimensions, and the dw views (no personal data)';
"""


def run(url: str, sql: str, *, single: bool = False, quiet: bool = True) -> str:
    """Runs SQL with psql against a connection string; single=True runs it as one transaction."""
    cmd = ["psql", url, "-X", "-At", "-v", "ON_ERROR_STOP=1"] + (["-q"] if quiet else []) + (["-1"] if single else [])
    r = subprocess.run(cmd + ["-f", "-"], input=sql, capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"psql failed: {r.stderr.strip()[:1200]}")
    return r.stdout.strip()


def literal(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"


def ident(s: str) -> str:
    if not _IDENT.match(s):
        sys.exit(f"unexpected name from the publication: {s!r}")
    return s


def source_tables(source: str) -> list:
    tables = json.loads(run(source, SOURCE_TABLES) or "[]")
    if not tables:
        sys.exit("publication masslak_dw is empty or missing on the primary (schema file 1062)")
    return tables


def create_tables(dw: str, tables: list) -> None:
    sql = []
    for t in tables:
        s, n = ident(t["schema"]), ident(t["table"])
        cols = [f"{ident(c['name'])} {c['type']}{' NOT NULL' if c['not_null'] else ''}" for c in t["columns"]]
        key = ", ".join(ident(k) for k in t["key"] or [])
        sql.append(f"CREATE SCHEMA IF NOT EXISTS {s};")
        sql.append(f"CREATE TABLE IF NOT EXISTS {s}.{n} ({', '.join(cols)}{f', PRIMARY KEY ({key})' if key else ''});")
        # a column added to the publication later: it arrives with the next change of each row (or after --resync)
        sql += [f"ALTER TABLE {s}.{n} ADD COLUMN IF NOT EXISTS {ident(c['name'])} {c['type']};" for c in t["columns"]]
        sql += [f"CREATE INDEX IF NOT EXISTS {n}_{c['name']}_idx ON {s}.{n} ({ident(c['name'])});"
                for c in t["columns"] if (c["name"].endswith("_id") or c["name"] == "created_at") and c["name"] not in (t["key"] or [])]
    run(dw, "\n".join(sql), single=True)


def subscribe(dw: str, source: str) -> str:
    exists = run(dw, f"SELECT count(*) FROM pg_subscription WHERE subname = {literal(SUBSCRIPTION)}") == "1"
    if exists:
        run(dw, f"ALTER SUBSCRIPTION {SUBSCRIPTION} CONNECTION {literal(source)}")
        run(dw, f"ALTER SUBSCRIPTION {SUBSCRIPTION} REFRESH PUBLICATION WITH (copy_data = true)")
        return "refreshed"
    # a slot the primary gave up (wal_status lost) cannot be resumed: a fresh one and a fresh copy
    run(source, f"SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots "
                f"WHERE slot_name = {literal(SLOT)} AND wal_status = 'lost' AND NOT active")
    run(source, f"SELECT pg_create_logical_replication_slot({literal(SLOT)}, 'pgoutput') "
                f"WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = {literal(SLOT)})")
    # created apart from the slot, so a warehouse in the primary's own cluster works too
    run(dw, f"CREATE SUBSCRIPTION {SUBSCRIPTION} CONNECTION {literal(source)} PUBLICATION {PUBLICATION} "
            f"WITH (create_slot = false, slot_name = {literal(SLOT)}, copy_data = true, streaming = on)")
    return "created"


def resync(dw: str, source: str, tables: list) -> None:
    if run(dw, f"SELECT count(*) FROM pg_subscription WHERE subname = {literal(SUBSCRIPTION)}") == "1":
        run(dw, f"ALTER SUBSCRIPTION {SUBSCRIPTION} DISABLE")
        run(dw, f"ALTER SUBSCRIPTION {SUBSCRIPTION} SET (slot_name = NONE)")
        run(dw, f"DROP SUBSCRIPTION {SUBSCRIPTION}")
    run(source, f"SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name = {literal(SLOT)} AND NOT active")
    names = ", ".join(f"{ident(t['schema'])}.{ident(t['table'])}" for t in tables)
    run(dw, f"TRUNCATE {names}")


def grants(dw: str, tables: list, analyst_password: str | None) -> None:
    schemas = sorted({ident(t["schema"]) for t in tables} | {"dw"})
    sql = [f"GRANT USAGE ON SCHEMA {s} TO dw_reader;" for s in schemas]
    sql += [f"GRANT SELECT ON {ident(t['schema'])}.{ident(t['table'])} TO dw_reader;" for t in tables]
    sql += ["GRANT SELECT ON ALL TABLES IN SCHEMA dw TO dw_reader;"]
    if analyst_password:
        sql += ["SELECT format('CREATE ROLE dw_analyst LOGIN IN ROLE dw_reader') "
                "WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dw_analyst') \\gexec",
                f"ALTER ROLE dw_analyst PASSWORD {literal(analyst_password)};",
                "ALTER ROLE dw_analyst SET statement_timeout = '10min';"]
    run(dw, "\n".join(sql))


def state(dw: str, source: str, tables: list, counts: bool) -> dict:
    sync = json.loads(run(dw, "SELECT coalesce(json_object_agg(srrelid::regclass::text, srsubstate), '{}') FROM pg_subscription_rel") or "{}")
    published = {f"{t['schema']}.{t['table']}": {c["name"] for c in t["columns"]} for t in tables}
    schemas = ", ".join(sorted({literal(t["schema"]) for t in tables}))
    held = json.loads(run(dw, f"""
        SELECT coalesce(json_object_agg(c.table_schema || '.' || c.table_name, c.cols), '{{}}')
          FROM (SELECT table_schema, table_name, json_agg(column_name) AS cols FROM information_schema.columns
                 WHERE table_schema IN ({schemas}) GROUP BY 1, 2) c""") or "{}")
    extra = {t: sorted(set(cols) - published.get(t, set())) for t, cols in held.items()}
    out = {"subscription": run(dw, f"SELECT CASE WHEN subenabled THEN 'enabled' ELSE 'disabled' END FROM pg_subscription "
                                   f"WHERE subname = {literal(SUBSCRIPTION)}") or "missing",
           "tables": len(tables),
           "not_ready": sorted(t for t in published if sync.get(t) != "r"),
           "unpublished_columns": {t: c for t, c in extra.items() if c},
           "slot": json.loads(run(source, f"""SELECT coalesce(json_agg(json_build_object('active', active, 'wal_status', wal_status,
                       'retained_bytes', pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn))), '[]')
                  FROM pg_replication_slots WHERE slot_name = {literal(SLOT)}""") or "[]")}
    if counts:
        q = " UNION ALL ".join(f"SELECT {literal(t)}, count(*) FROM {t}" for t in published)
        a = dict(line.split("|") for line in run(source, q).splitlines())
        b = dict(line.split("|") for line in run(dw, q).splitlines())
        out["count_differences"] = {t: {"primary": int(a[t]), "warehouse": int(b[t])} for t in published if a[t] != b[t]}
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--wait", action="store_true", help="wait until every table finished its first copy")
    ap.add_argument("--refresh", action="store_true", help="only refresh the dw views")
    ap.add_argument("--refresh-every", type=int, metavar="SECONDS", help="keep refreshing the dw views at this interval")
    ap.add_argument("--check", action="store_true", help="print the replication state as JSON; non-zero when unhealthy")
    ap.add_argument("--resync", action="store_true", help="drop the subscription and slot and copy every table again")
    ap.add_argument("--timeout", type=int, default=1800, help="seconds --wait waits (default 1800)")
    a = ap.parse_args()
    source, dw = os.environ.get("MASSLAK_DW_SOURCE", ""), os.environ.get("MASSLAK_DW_URL", "")
    if not _IDENT.match(SLOT):
        sys.exit(f"MASSLAK_DW_SLOT is not a plain name: {SLOT!r}")
    if not dw or (not source and not a.refresh and not a.refresh_every):
        sys.exit("set MASSLAK_DW_URL (the warehouse) and MASSLAK_DW_SOURCE (the primary, as masslak_cdc)")
    if a.refresh_every:
        while True:
            t0 = time.time()
            n = run(dw, "SELECT dw.refresh()")
            print(f"refreshed {n} views in {time.time() - t0:.1f}s", flush=True)
            time.sleep(max(60, a.refresh_every))
    if a.refresh:
        print(f"refreshed {run(dw, 'SELECT dw.refresh()')} views")
        return 0
    tables = source_tables(source)
    if a.check:
        s = state(dw, source, tables, counts=True)
        print(json.dumps(s, indent=1))
        ok = s["subscription"] == "enabled" and not s["not_ready"] and not s["unpublished_columns"] and not s["count_differences"]
        return 0 if ok else 1
    if a.resync:
        resync(dw, source, tables)
    create_tables(dw, tables)
    print(f"subscription {subscribe(dw, source)}: {len(tables)} tables", flush=True)
    run(dw, DW)
    grants(dw, tables, os.environ.get("MASSLAK_DW_ANALYST_PASSWORD") or None)
    if a.wait:
        deadline = time.time() + a.timeout
        while (pending := state(dw, source, tables, counts=False)["not_ready"]) and time.time() < deadline:
            time.sleep(2)
        if pending:
            sys.exit(f"tables still copying after {a.timeout}s: {', '.join(pending)}")
        print(f"first copy done; refreshed {run(dw, 'SELECT dw.refresh()')} views")
    return 0


if __name__ == "__main__":
    sys.exit(main())
