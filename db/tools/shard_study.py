#!/usr/bin/env python3
"""Measures how well the data would split by company (expert review of October 2026, stage D: the sharding study).

    python3 db/tools/shard_study.py <database> [--json out.json] [--md out.md] [psql connection args...]

Run it against staging with production-size data (db/tools/generate_volume.py) or a restored copy of production. It
reads only; the numbers feed docs/database/SHARDING_STUDY.md. What it measures:

1. Placement of every table under a split by company (the distribution column every tenant table carries for
   row-level security): DISTRIBUTE (has company_id), CHILD (reaches its company through a parent, so the column would
   have to be added), SHARED (reached through a function: rows two companies both see), REFERENCE (catalogues,
   replicated everywhere), CENTRAL (people, platform money, security and audit), with rows and bytes of each.
2. Rows that point at another company's row, for every foreign key between two tables that both carry company_id.
3. Money that crosses companies: how many ledger transactions touch the wallets of more than one company, of a person
   and a company, or of the platform, per kind of transaction. A split must keep each of them on one node or pay a
   two-phase commit.
4. Skew: bookings and tickets per company (the largest company's share, and how many companies hold 80 %).
5. Markets: transactions whose wallets are in more than one currency (a split by market must find none).
"""
import argparse
import json
import subprocess
import sys

INVENTORY = r"""
WITH t AS (
  SELECT c.oid, n.nspname || '.' || c.relname AS name, c.relkind
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition
     AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'public', 'gis') AND n.nspname NOT LIKE 'pg\_%'
), sized AS (
  -- a partitioned table holds its rows in its partitions (pg_partition_tree lists nothing for a plain table)
  SELECT t.name, t.relkind,
         (SELECT coalesce(sum(greatest(k.reltuples, 0)), 0) FROM pg_class k
           WHERE k.oid = t.oid AND t.relkind = 'r'
              OR k.oid IN (SELECT p.relid FROM pg_partition_tree(t.oid) p WHERE p.isleaf))::bigint AS rows,
         CASE WHEN t.relkind = 'r' THEN pg_total_relation_size(t.oid)
              ELSE (SELECT coalesce(sum(pg_total_relation_size(p.relid)), 0) FROM pg_partition_tree(t.oid) p WHERE p.isleaf)
         END::bigint AS bytes,
         EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = t.oid AND a.attname = 'company_id' AND NOT a.attisdropped) AS has_company
    FROM t
)
SELECT coalesce(json_agg(json_build_object('table', s.name, 'rows', s.rows, 'bytes', s.bytes, 'has_company', s.has_company,
                                           'data_class', tc.data_class, 'tenant_path', tc.tenant_path) ORDER BY s.name), '[]')
  FROM sized s LEFT JOIN sys.table_class tc ON tc.table_name = s.name
"""

TENANT_FKS = r"""
SELECT coalesce(json_agg(json_build_object('child', c.conrelid::regclass::text, 'parent', c.confrelid::regclass::text,
                                           'child_col', a.attname, 'parent_col', pa.attname, 'name', c.conname)), '[]')
  FROM pg_constraint c
  JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
  JOIN pg_attribute pa ON pa.attrelid = c.confrelid AND pa.attnum = c.confkey[1]
 WHERE c.contype = 'f' AND cardinality(c.conkey) = 1 AND c.conrelid <> c.confrelid AND c.conparentid = 0
   AND EXISTS (SELECT 1 FROM pg_attribute x WHERE x.attrelid = c.conrelid AND x.attname = 'company_id' AND NOT x.attisdropped)
   AND EXISTS (SELECT 1 FROM pg_attribute x WHERE x.attrelid = c.confrelid AND x.attname = 'company_id' AND NOT x.attisdropped)
   AND NOT EXISTS (SELECT 1 FROM pg_inherits i WHERE i.inhrelid = c.conrelid)
"""

MONEY = r"""
WITH platform AS (SELECT id FROM iam.party WHERE party_type = 'COMPANY' AND legal_name = 'Masslak Platform'),
e AS (
  SELECT t.id, t.txn_type, w.currency, w.wallet_type,
         CASE WHEN w.owner_party_id IN (SELECT id FROM platform) THEN NULL
              WHEN w.wallet_type IN ('USER', 'FAMILY') THEN NULL ELSE coalesce(w.company_id, w.owner_party_id) END AS company,
         (w.owner_party_id IN (SELECT id FROM platform)) AS platform_wallet,
         (w.wallet_type IN ('USER', 'FAMILY')) AS person_wallet
    FROM fin.ledger_txn t JOIN fin.ledger_entry le ON le.txn_id = t.id JOIN fin.wallet w ON w.id = le.wallet_id
), per AS (
  SELECT id, txn_type, count(DISTINCT company) AS companies, bool_or(person_wallet) AS person, bool_or(platform_wallet) AS platform,
         count(DISTINCT currency) AS currencies
    FROM e GROUP BY id, txn_type
)
SELECT coalesce(json_agg(x ORDER BY x.total DESC), '[]') FROM (
  SELECT txn_type, count(*) AS total,
         count(*) FILTER (WHERE companies = 0) AS no_company,
         count(*) FILTER (WHERE companies = 1) AS one_company,
         count(*) FILTER (WHERE companies > 1) AS several_companies,
         count(*) FILTER (WHERE person AND companies >= 1) AS person_and_company,
         count(*) FILTER (WHERE platform) AS with_platform,
         count(*) FILTER (WHERE currencies > 1) AS several_currencies
    FROM per GROUP BY txn_type) x
"""

SKEW = r"""
WITH b AS (SELECT company_id, count(*) AS n FROM sales.booking GROUP BY 1),
     k AS (SELECT b.company_id, count(*) AS n FROM sales.ticket t JOIN sales.booking b ON b.id = t.booking_id GROUP BY 1),
     ranked AS (SELECT n, sum(n) OVER (ORDER BY n DESC) AS running, sum(n) OVER () AS total, row_number() OVER (ORDER BY n DESC) AS r FROM b)
SELECT json_build_object(
  'companies_with_bookings', (SELECT count(*) FROM b),
  'bookings', (SELECT coalesce(sum(n), 0) FROM b),
  'largest_share', (SELECT round(max(n)::numeric / nullif(sum(n), 0), 3) FROM b),
  'companies_for_80_percent', (SELECT min(r) FROM ranked WHERE running >= 0.8 * total),
  'tickets', (SELECT coalesce(sum(n), 0) FROM k),
  'agency_bookings', (SELECT count(*) FROM sales.booking WHERE agency_id IS NOT NULL AND agency_id <> company_id),
  'family_bookings', (SELECT count(*) FROM sales.booking WHERE family_id IS NOT NULL))
"""


def psql(db: str, args: list[str], sql: str):
    r = subprocess.run(["psql", *args, "-d", db, "-At", "-v", "ON_ERROR_STOP=1", "-c", sql], capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"psql failed: {r.stderr.strip()[:600]}")
    return json.loads(r.stdout.strip())        # one JSON value (json_agg puts a newline between elements)


def placement(t: dict) -> str:
    cls, path = t.get("data_class") or "", t.get("tenant_path") or ""
    if t["has_company"]:
        return "DISTRIBUTE"
    if cls in ("PUBLIC_CATALOG", "SYSTEM"):
        return "REFERENCE"
    if cls in ("USER_PRIVATE", "RESTRICTED_SECURITY", "APPEND_ONLY_AUDIT", "PLATFORM_CONFIDENTIAL"):
        return "CENTRAL"
    if path.startswith("parent "):
        return "CHILD"
    if path.startswith("via "):
        return "SHARED"
    return "CENTRAL"


def cross_rows(db: str, args: list[str], fk: dict) -> int:
    sql = (f"SELECT count(*) FROM {fk['child']} c JOIN {fk['parent']} p ON p.{fk['parent_col']} = c.{fk['child_col']} "
           f"WHERE c.company_id IS NOT NULL AND p.company_id IS NOT NULL AND c.company_id <> p.company_id")
    r = subprocess.run(["psql", *args, "-d", db, "-At", "-c", sql], capture_output=True, text=True)
    return int(r.stdout.strip() or 0) if r.returncode == 0 else -1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], add_help=False)   # -h is psql's host
    ap.add_argument("database")
    ap.add_argument("--json")
    ap.add_argument("--md")
    opts, rest = ap.parse_known_args()
    db, args = opts.database, rest
    subprocess.run(["psql", *args, "-d", db, "-qc", "ANALYZE"], capture_output=True)
    tables = psql(db, args, INVENTORY)
    for t in tables:
        t["placement"] = placement(t)
    groups: dict = {}
    for t in tables:
        g = groups.setdefault(t["placement"], {"tables": 0, "rows": 0, "bytes": 0})
        g["tables"] += 1
        g["rows"] += t["rows"]
        g["bytes"] += t["bytes"]
    fks = psql(db, args, TENANT_FKS)
    crossing = [{**fk, "rows": cross_rows(db, args, fk)} for fk in fks]
    money = psql(db, args, MONEY)
    skew = psql(db, args, SKEW)
    total_txn = sum(m["total"] for m in money) or 1
    result = {
        "placement": groups,
        "largest_tables": sorted(({k: t[k] for k in ("table", "placement", "rows", "bytes", "tenant_path")} for t in tables),
                                 key=lambda x: -x["bytes"])[:25],
        "tenant_foreign_keys": len(fks),
        "foreign_keys_with_cross_company_rows": [c for c in crossing if c["rows"] > 0],
        "money": money,
        "money_summary": {
            "transactions": total_txn,
            "several_companies_pct": round(100 * sum(m["several_companies"] for m in money) / total_txn, 1),
            "person_and_company_pct": round(100 * sum(m["person_and_company"] for m in money) / total_txn, 1),
            "with_platform_pct": round(100 * sum(m["with_platform"] for m in money) / total_txn, 1),
            "several_currencies": sum(m["several_currencies"] for m in money),
        },
        "skew": skew,
    }
    if opts.json:
        with open(opts.json, "w", encoding="utf-8") as f:
            json.dump(result, f, indent=2)
    lines = ["| Placement | Tables | Rows | Size (MB) |", "|---|---|---|---|"]
    for k in ("DISTRIBUTE", "CHILD", "SHARED", "REFERENCE", "CENTRAL"):
        g = groups.get(k, {"tables": 0, "rows": 0, "bytes": 0})
        lines.append(f"| {k} | {g['tables']} | {g['rows']:,} | {g['bytes'] / 1e6:,.1f} |")
    ms = result["money_summary"]
    lines += ["", f"Ledger transactions: {ms['transactions']:,}; touching several companies {ms['several_companies_pct']} %, "
              f"a person and a company {ms['person_and_company_pct']} %, the platform {ms['with_platform_pct']} %, "
              f"several currencies {ms['several_currencies']}.",
              f"Foreign keys between tenant tables: {len(fks)}; with rows of another company: "
              f"{len(result['foreign_keys_with_cross_company_rows'])}.",
              f"Bookings: {skew['bookings']:,} by {skew['companies_with_bookings']} companies; the largest holds "
              f"{float(skew['largest_share'] or 0) * 100:.1f} %; {skew['companies_for_80_percent']} companies hold 80 %."]
    text = "\n".join(lines) + "\n"
    if opts.md:
        with open(opts.md, "w", encoding="utf-8") as f:
            f.write(text)
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
