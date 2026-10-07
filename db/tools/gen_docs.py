#!/usr/bin/env python3
"""Generates the data dictionary and ERD diagrams from a built database (so the docs never drift from the schema).

Usage:
    python3 db/tools/gen_docs.py <database> [psql connection args...]
Output:
    db/DATA_DICTIONARY.md  — every table with its purpose, columns, types and constraints
    db/ERD.md              — a Mermaid diagram per module from the actual foreign keys
"""
import json
import os
import subprocess
import sys

SCHEMAS = [
    ("iam", "Identity, parties, users, permissions and API clients"),
    ("ref", "Reference data, locales and files"),
    ("sys", "Settings, outbox and webhooks"),
    ("net", "Network: stations, routes, lines, corridors and geofences"),
    ("fleet", "Fleet: vehicles, trucks, trailers, seats, crew, licenses and insurance"),
    ("pricing", "Pricing, taxes, commissions, campaigns and loyalty"),
    ("ops", "Trips, inventory, operations, shuttle rides, tracking and incidents"),
    ("sales", "Channels, bookings, passengers, tickets, subscriptions and travel documents"),
    ("fin", "Wallets, ledger, payments, allocation, settlement and float"),
    ("acct", "Simplified accounting, e-invoicing and tax profiles"),
    ("bill", "Carrier subscriptions, metering and platform invoices"),
    ("crm", "Complaints, ratings, notifications, the AI assistant and the contact center"),
    ("gov", "Governance, obligations and data protection"),
    ("sec", "Security: IP rules, risk, signing, the security hub and government adapters"),
    ("ptn", "Service partners: fuel stations, rest stops and maintenance"),
    ("ship", "Shipments and the integrated shipping network"),
    ("frt", "Trucking, heavy transport and transit freight"),
    ("brd", "Border manifest gateway"),
    ("ctr", "Contracted transport: universities and employees"),
    ("sch", "School transport: schools, operators, pupils and guardians, contracts, routes, runs and attendance"),
    ("gis", "PostGIS reference data"),
    ("rail", "Rail extension"),
    ("taxi", "Taxis"),
    ("rent", "Car rental"),
    ("rpt", "Report definitions, runs and schedules"),
    ("audit", "Login and activity logs (append-only)"),
]
SCHEMA_LIST = ",".join(f"'{s}'" for s, _ in SCHEMAS)

Q_TABLES = r"""
SELECT coalesce(json_agg(t ORDER BY t.schema, t.name), '[]') FROM (
  SELECT n.nspname AS schema, c.relname AS name, obj_description(c.oid, 'pg_class') AS comment,
         c.relkind = 'p' AS partitioned, c.relrowsecurity AS rls,
         (SELECT json_agg(json_build_object(
             'name', a.attname, 'type', format_type(a.atttypid, a.atttypmod), 'notnull', a.attnotnull,
             'default', CASE WHEN a.attidentity <> '' THEN 'identity' ELSE pg_get_expr(d.adbin, d.adrelid) END,
             'pk', EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conrelid = c.oid AND k.contype = 'p' AND a.attnum = ANY (k.conkey)),
             'fk', (SELECT fn.nspname || '.' || fc.relname FROM pg_constraint f
                      JOIN pg_class fc ON fc.oid = f.confrelid JOIN pg_namespace fn ON fn.oid = fc.relnamespace
                     WHERE f.conrelid = c.oid AND f.contype = 'f' AND f.conkey = ARRAY[a.attnum] LIMIT 1)
           ) ORDER BY a.attnum)
          FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
          WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped) AS columns,
         (SELECT json_agg(tg.tgname ORDER BY tg.tgname) FROM pg_trigger tg
           WHERE tg.tgrelid = c.oid AND NOT tg.tgisinternal) AS triggers
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition
    AND n.nspname IN (%s)
) t
""" % SCHEMA_LIST

Q_FKS = r"""
SELECT coalesce(json_agg(x), '[]') FROM (
  SELECT n.nspname AS cs, c.relname AS ct, fn.nspname AS ps, fc.relname AS pt,
         (SELECT string_agg(a.attname, ',') FROM unnest(f.conkey) k JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = k) AS cols,
         bool_and(a2.attnotnull) AS required
  FROM pg_constraint f
  JOIN pg_class c ON c.oid = f.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_class fc ON fc.oid = f.confrelid JOIN pg_namespace fn ON fn.oid = fc.relnamespace
  JOIN pg_attribute a2 ON a2.attrelid = c.oid AND a2.attnum = ANY (f.conkey)
  WHERE f.contype = 'f' AND NOT c.relispartition
  GROUP BY n.nspname, c.relname, fn.nspname, fc.relname, f.conkey, c.oid
) x
"""


def q(db, args, sql):
    out = subprocess.run(["psql", *args, "-d", db, "-At", "-c", sql], check=True, capture_output=True, text=True).stdout
    return json.loads(out.strip())


# "Who did it" links and reference-data links are omitted from diagrams for clarity (they remain in the data dictionary)
ACTOR_COLS = {"created_by", "approved_by", "updated_by", "reviewed_by", "verified_by", "decided_by", "granted_by",
              "revoked_by", "requested_by", "closed_by", "uploaded_by", "changed_by", "by_user_id", "handled_by",
              "executed_by", "assigned_to", "owner_user_id", "reviewer_id", "second_approver", "payout_by",
              "scanned_by_user_id", "reported_by", "added_by", "inspector_user_id", "approver_id", "actor_id",
              "resolved_by", "recorded_by", "released_by", "opened_by", "handed_over_to", "scorer_user_id", "actor_user_id"}
REF_TABLES = {("ref", "currency"), ("ref", "country"), ("sec", "key_registry"), ("ref", "file_object")}


def drawn(f):
    return not (f["cols"] in ACTOR_COLS or (f["ps"], f["pt"]) in REF_TABLES)


def ent(schema, table):
    return f"{schema}_{table}"


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    db, args = sys.argv[1], sys.argv[2:]
    tables = q(db, args, Q_TABLES)
    fks = q(db, args, Q_FKS)
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    by_schema = {}
    for t in tables:
        by_schema.setdefault(t["schema"], []).append(t)

    # ---------------- Data dictionary ----------------
    total_cols = sum(len(t["columns"]) for t in tables)
    lines = ["# Data Dictionary — Masslak Database (study v2.6)", "",
             "> Generated from the built database (`db/tools/gen_docs.py`); do not edit by hand.", "",
             f"**{len(tables)} tables, {total_cols} columns, in {len(by_schema)} schemas.**", "",
             "Legend: 🔑 primary key · 🔗 foreign key · ✱ required · 🛡️ tenant isolation (RLS) · 🧩 partitioned monthly · 🔒 append-only / change-protected", "",
             "## Index", ""]
    for s, title in SCHEMAS:
        if s in by_schema:
            lines.append(f"- [`{s}` — {title}](#{s}) ({len(by_schema[s])} tables)")
    lines.append("")
    for s, title in SCHEMAS:
        if s not in by_schema:
            continue
        lines += [f'<a id="{s}"></a>', f"## `{s}` — {title}", ""]
        for t in by_schema[s]:
            flags = []
            if t["rls"]:
                flags.append("🛡️")
            if t["partitioned"]:
                flags.append("🧩")
            trig = t["triggers"] or []
            if any(x.endswith("immutable") or x in ("forbid_mutation", "einvoice_guard", "journal_guard", "license_locked", "ip_rule_no_delete") for x in trig):
                flags.append("🔒")
            lines += [f"### `{s}.{t['name']}` {' '.join(flags)}", "", t["comment"] or "", "",
                      "| Column | Type | Constraints | Default |", "|---|---|---|---|"]
            for c in t["columns"]:
                marks = ("🔑 " if c["pk"] else "") + (f"🔗 `{c['fk']}` " if c["fk"] else "") + ("✱" if c["notnull"] else "")
                default = (c["default"] or "").replace("|", "\\|")
                if len(default) > 40:
                    default = default[:37] + "..."
                lines.append(f"| `{c['name']}` | `{c['type']}` | {marks} | {('`' + default + '`') if default else ''} |")
            lines.append("")
    open(os.path.join(root, "DATA_DICTIONARY.md"), "w", encoding="utf-8").write("\n".join(lines))

    # ---------------- ERD ----------------
    out = ["# Entity-Relationship Diagrams — Masslak Database (study v2.6)", "",
           "> Generated from the actual foreign keys of the built database. Each diagram shows the module's tables with their key columns,",
           "> plus the tables they reference in other modules (without columns). Solid line = required relationship, dashed = optional.",
           "> For clarity, \"who did it\" links (created_by, approved_by...) to `iam.app_user` and links to currency, country,",
           "> encryption keys and files are not drawn; they are all listed in the [data dictionary](DATA_DICTIONARY.md).", "",
           "## Overview: modules and their relationships", "", "```mermaid", "flowchart LR"]
    edges = {}
    for f in fks:
        if f["cs"] != f["ps"] and drawn(f):
            edges[(f["cs"], f["ps"])] = edges.get((f["cs"], f["ps"]), 0) + 1
    for s, title in SCHEMAS:
        out.append(f'  {s}["{s}<br/>{title}"]')
    for (a, b), n in sorted(edges.items()):
        if a != "audit":
            out.append(f"  {a} -->|{n}| {b}")
    out += ["```", ""]
    for s, title in SCHEMAS:
        if s not in by_schema:
            continue
        own = {t["name"]: t for t in by_schema[s]}
        rels = [f for f in fks if f["cs"] == s and drawn(f)]
        ext = sorted({(f["ps"], f["pt"]) for f in rels if f["ps"] != s})
        out += [f"## `{s}` — {title}", "", "```mermaid", "erDiagram"]
        for name, t in own.items():
            out.append(f"  {ent(s, name)} {{")
            for c in t["columns"]:
                if c["pk"] or c["fk"] or c["name"] in ("uid", "code", "status", "trip_no", "booking_ref", "number"):
                    typ = c["type"].split("(")[0].replace(" ", "_").replace("[]", "_arr")
                    key = "PK" if c["pk"] else ("FK" if c["fk"] else "")
                    out.append(f"    {typ} {c['name']} {key}".rstrip())
            out.append("  }")
        for ps, pt in ext:
            out.append(f"  {ent(ps, pt)} {{")
            out.append("    ref external")
            out.append("  }")
        for f in rels:
            child, parent = ent(f["cs"], f["ct"]), ent(f["ps"], f["pt"])
            card = "}o--||" if f["required"] else "}o..o|"
            out.append(f'  {child} {card} {parent} : "{f["cols"]}"')
        out += ["```", ""]
    open(os.path.join(root, "ERD.md"), "w", encoding="utf-8").write("\n".join(out))
    print(f"generated: {len(tables)} tables, {total_cols} columns, {len(fks)} foreign keys")


if __name__ == "__main__":
    main()
