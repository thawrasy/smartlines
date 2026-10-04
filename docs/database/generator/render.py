#!/usr/bin/env python3
"""Reads the built database and draws the ERDs of the design document in the study's colours.

Usage (from this directory, with graphviz installed):
    python3 render.py <database> [psql connection args...]
Writes ../erd/svg/*.svg, ../erd/png/*.png and ../build/model.json (input of build.js).
"""
import html
import json
import math
import os
import subprocess
import sys

from diagrams import (DATA_STORES, EDGE, FAMILY, GRID, GROUPS, INK, NAVY, ROW_ALT, SCHEMA_FAMILY)

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "erd")
BUILD = os.path.join(HERE, "..", "build")
FONT = "DejaVu Sans"

Q_MODEL = r"""
WITH t AS (
  SELECT c.oid, n.nspname AS schema, c.relname AS name, obj_description(c.oid, 'pg_class') AS comment,
         c.relrowsecurity AS rls, c.relkind = 'p' AS partitioned
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r','p') AND NOT c.relispartition AND n.nspname NOT IN ('pg_catalog','information_schema')
)
SELECT json_agg(json_build_object(
  'schema', t.schema, 'name', t.name, 'comment', t.comment, 'rls', t.rls, 'partitioned', t.partitioned,
  'columns', (SELECT json_agg(json_build_object(
       'name', a.attname, 'type', format_type(a.atttypid, a.atttypmod), 'notnull', a.attnotnull,
       'default', CASE WHEN a.attidentity <> '' THEN 'identity' WHEN a.attgenerated <> '' THEN 'generated'
                       ELSE pg_get_expr(d.adbin, d.adrelid) END,
       'comment', col_description(t.oid, a.attnum)) ORDER BY a.attnum)
     FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
     WHERE a.attrelid = t.oid AND a.attnum > 0 AND NOT a.attisdropped),
  'pk', (SELECT json_agg(a.attname ORDER BY k.ord) FROM pg_constraint p
           CROSS JOIN LATERAL unnest(p.conkey) WITH ORDINALITY k(attnum, ord)
           JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = k.attnum
         WHERE p.conrelid = t.oid AND p.contype = 'p'),
  'unique', (SELECT json_agg(cols) FROM (
       SELECT (SELECT json_agg(a.attname) FROM unnest(u.conkey) k JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = k) AS cols
       FROM pg_constraint u WHERE u.conrelid = t.oid AND u.contype = 'u') x),
  'checks', (SELECT json_agg(pg_get_constraintdef(c.oid) ORDER BY c.conname) FROM pg_constraint c
             WHERE c.conrelid = t.oid AND c.contype IN ('c','x')),
  'indexes', (SELECT json_agg(pg_get_indexdef(i.indexrelid) ORDER BY i.indexrelid) FROM pg_index i
              WHERE i.indrelid = t.oid AND NOT i.indisprimary
                AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid = i.indexrelid)),
  'policies', (SELECT json_agg(p.policyname ORDER BY p.policyname) FROM pg_policies p WHERE p.schemaname = t.schema AND p.tablename = t.name),
  'triggers', (SELECT json_agg(tg.tgname ORDER BY tg.tgname) FROM pg_trigger tg WHERE tg.tgrelid = t.oid AND NOT tg.tgisinternal),
  'fks', (SELECT json_agg(json_build_object(
       'name', f.conname,
       'cols', (SELECT json_agg(a.attname) FROM unnest(f.conkey) k JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = k),
       'ref', fn.nspname || '.' || fc.relname,
       'ref_cols', (SELECT json_agg(a.attname) FROM unnest(f.confkey) k JOIN pg_attribute a ON a.attrelid = f.confrelid AND a.attnum = k),
       'on_delete', f.confdeltype,
       'required', (SELECT bool_and(a.attnotnull) FROM unnest(f.conkey) k JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = k),
       'unique', EXISTS (SELECT 1 FROM pg_constraint u WHERE u.conrelid = t.oid AND u.contype IN ('u','p') AND u.conkey = f.conkey))
       ORDER BY f.conname)
     FROM pg_constraint f JOIN pg_class fc ON fc.oid = f.confrelid JOIN pg_namespace fn ON fn.oid = fc.relnamespace
     WHERE f.conrelid = t.oid AND f.contype = 'f')
) ORDER BY t.schema, t.name) FROM t
"""

ACTOR_COLS = {"created_by", "approved_by", "updated_by", "reviewed_by", "verified_by", "decided_by", "granted_by",
              "revoked_by", "requested_by", "closed_by", "uploaded_by", "changed_by", "by_user_id", "handled_by",
              "executed_by", "assigned_to", "owner_user_id", "reviewer_id", "second_approver", "payout_by",
              "scanned_by_user_id", "reported_by", "added_by", "inspector_user_id", "approver_id", "actor_id",
              "resolved_by", "recorded_by", "released_by", "opened_by", "handed_over_to", "scorer_user_id",
              "actor_user_id", "resolved_by_user_id", "recorded_by_user_id"}
QUIET_REFS = {"ref.currency", "ref.country", "sec.key_registry", "ref.file_object", "ref.locale"}
NOTABLE = ("code", "status", "kind", "name", "trip_no", "booking_ref", "ticket_no", "tracking_no", "invoice_no",
           "number", "plate_no", "period", "valid", "amount", "total", "price", "role", "direction", "mode")


def esc(s):
    return html.escape(str(s), quote=True)


def short_type(t):
    t = t.replace("timestamp with time zone", "timestamptz").replace("character varying", "varchar")
    t = t.replace("character(", "char(").replace("double precision", "float8")
    return t if len(t) <= 16 else t[:15] + "…"


def drawn(fk, group_tables):
    if len(fk["cols"]) == 1 and fk["cols"][0] in ACTOR_COLS:
        return False
    return not (fk["ref"] in QUIET_REFS and fk["ref"] not in group_tables)


def entity_label(t, fam, group_tables):
    pk = set(t["pk"] or [])
    fkcols = {c for f in (t["fks"] or []) if drawn(f, group_tables) for c in f["cols"]}
    uq = {u[0] for u in (t["unique"] or []) if len(u) == 1}
    shown = [c for c in t["columns"] if c["name"] in pk or c["name"] in fkcols]
    extra = [c for c in t["columns"] if c not in shown and (c["name"] in NOTABLE or c["name"] in uq)][:3]
    shown += extra
    hidden = len(t["columns"]) - len(shown)
    rows = [f'<TR><TD COLSPAN="3" BGCOLOR="{FAMILY[fam]["band"]}" HEIGHT="4" CELLPADDING="0"></TD></TR>',
            f'<TR><TD COLSPAN="3" BGCOLOR="{FAMILY[fam]["fill"]}" CELLPADDING="5">'
            f'<FONT POINT-SIZE="11"><B>{esc(t["name"])}</B></FONT><BR/>'
            f'<FONT POINT-SIZE="8" COLOR="#595959">{esc(t["schema"])}</FONT></TD></TR>']
    for i, c in enumerate(shown):
        bg = "#FFFFFF" if i % 2 == 0 else ROW_ALT
        if c["name"] in pk:
            key = f'<FONT COLOR="{NAVY}"><B>PK</B></FONT>'
        elif c["name"] in fkcols:
            key = f'<FONT COLOR="{FAMILY[fam]["band"]}"><B>FK</B></FONT>'
        elif c["name"] in uq:
            key = '<FONT COLOR="#595959"><B>UQ</B></FONT>'
        else:
            key = ""
        name = esc(c["name"]) if not c["notnull"] else f'<B>{esc(c["name"])}</B>'
        rows.append(f'<TR><TD BGCOLOR="{bg}" ALIGN="LEFT" WIDTH="22">{key}</TD>'
                    f'<TD BGCOLOR="{bg}" ALIGN="LEFT" PORT="{esc(c["name"])}">{name}</TD>'
                    f'<TD BGCOLOR="{bg}" ALIGN="LEFT"><FONT POINT-SIZE="8" COLOR="#7F7F7F">{esc(short_type(c["type"]))}</FONT></TD></TR>')
    if hidden > 0:
        rows.append(f'<TR><TD COLSPAN="3" ALIGN="LEFT" BGCOLOR="#FFFFFF"><FONT POINT-SIZE="8" COLOR="#7F7F7F"><I>'
                    f'+ {hidden} more column{"s" if hidden > 1 else ""}</I></FONT></TD></TR>')
    return ('<<TABLE BORDER="1" COLOR="' + INK + '" CELLBORDER="0" CELLSPACING="0" CELLPADDING="3" STYLE="ROUNDED">'
            + "".join(rows) + "</TABLE>>")


def node_id(full):
    return full.replace(".", "__")


def group_dot(group, model):
    gid, title, sections, fam, desc, tables = group
    tset = set(tables)
    lines = [f'digraph "{gid}" {{',
             f'  graph [rankdir=LR, nodesep=0.45, ranksep=1.1, pad=0.35, splines=ortho, fontname="{FONT}", bgcolor="white"];',
             f'  node [shape=plain, fontname="{FONT}", fontsize=10];',
             f'  edge [color="{EDGE}", penwidth=1.1, dir=both, fontname="{FONT}", fontsize=8, arrowsize=0.8];']
    externals = set()
    edges = []
    for full in tables:
        t = model[full]
        lines.append(f'  {node_id(full)} [label={entity_label(t, fam, tset)}];')
        for f in t["fks"] or []:
            if not drawn(f, tset):
                continue
            tail = "teeodot" if f["unique"] else "crowodot"
            head = "teetee" if f["required"] else "teeodot"
            col = f["cols"][0]
            if f["ref"] in tset:
                edges.append(f'  {node_id(full)} -> {node_id(f["ref"])} [arrowtail={tail}, arrowhead={head}];')
            else:
                externals.add(f["ref"])
                edges.append(f'  {node_id(full)} -> {node_id(f["ref"])} [arrowtail={tail}, arrowhead={head}, style=dashed];')
    for ext in sorted(externals):
        efam = SCHEMA_FAMILY.get(ext.split(".")[0], "core")
        lines.append(f'  {node_id(ext)} [shape=box, style="rounded,dashed,filled", fillcolor="#F7F7F7", color="#8C8C8C", '
                     f'fontcolor="#404040", fontsize=9, margin="0.12,0.05", label="{esc(ext)}"];')
    lines += edges
    lines.append("}")
    return "\n".join(lines)


def overview_dot(model):
    """Block diagram in the style of the study's figure 4.1: modules grouped by family, with their table counts."""
    from diagrams import SCHEMA_TITLE
    by_schema = {}
    for t in model.values():
        by_schema[t["schema"]] = by_schema.get(t["schema"], 0) + 1
    clusters = [("core", "1. CORE: IDENTITY, REFERENCE DATA AND SYSTEM"), ("asset", "2. ASSETS, NETWORK AND SHIPPING"),
                ("trip", "3. TRIPS, OPERATIONS AND LATER-PHASE TRANSPORT"), ("booking", "4. BOOKING AND CHANNELS"),
                ("money", "5. PRICING, MONEY AND ACCOUNTING"), ("service", "6. SERVICE, PARTNERS AND SUPPORT"),
                ("security", "7. SECURITY, BORDERS, GOVERNANCE AND AUDIT")]
    cols = 6
    rows = []
    for fam, label in clusters:
        members = sorted([s for s in by_schema if SCHEMA_FAMILY.get(s) == fam], key=lambda x: -by_schema[x])
        rows.append(f'<TR><TD COLSPAN="{cols}" ALIGN="LEFT" CELLPADDING="6"><FONT POINT-SIZE="13" COLOR="#333333"><B>{label}</B></FONT></TD></TR>')
        cells = "".join(f'<TD BGCOLOR="{FAMILY[fam]["fill"]}" BORDER="1" COLOR="{INK}" STYLE="ROUNDED" WIDTH="190" HEIGHT="62">'
                        f'<FONT POINT-SIZE="13"><B>{s}</B></FONT> <FONT POINT-SIZE="10">({by_schema[s]} tables)</FONT><BR/>'
                        f'<FONT POINT-SIZE="10">{SCHEMA_TITLE.get(s, "")}</FONT></TD>' for s in members)
        cells += "".join('<TD WIDTH="190"></TD>' for _ in range(cols - len(members)))
        rows.append(f"<TR>{cells}</TR>")
    total = sum(by_schema.values())
    rows.append(f'<TR><TD COLSPAN="{cols}" ALIGN="RIGHT"><FONT POINT-SIZE="10" COLOR="#595959">{len(by_schema)} schemas, {total} tables</FONT></TD></TR>')
    label = '<<TABLE BORDER="0" CELLSPACING="10" CELLPADDING="4">' + "".join(rows) + "</TABLE>>"
    return "\n".join(["digraph overview {", f'  graph [pad=0.2, fontname="{FONT}"];',
                      f'  node [shape=plain, fontname="{FONT}"];', f"  grid [label={label}];", "}"])


def legend_dot():
    fam = "core"
    def ent(name, rows):
        r = "".join(f'<TR><TD ALIGN="LEFT" BGCOLOR="{"#FFFFFF" if i % 2 == 0 else ROW_ALT}">{k}</TD>'
                    f'<TD ALIGN="LEFT" BGCOLOR="{"#FFFFFF" if i % 2 == 0 else ROW_ALT}" PORT="{p}">{c}</TD></TR>'
                    for i, (k, c, p) in enumerate(rows))
        return (f'<<TABLE BORDER="1" COLOR="{INK}" CELLBORDER="0" CELLSPACING="0" CELLPADDING="3" STYLE="ROUNDED">'
                f'<TR><TD COLSPAN="2" BGCOLOR="{FAMILY[fam]["band"]}" HEIGHT="4" CELLPADDING="0"></TD></TR>'
                f'<TR><TD COLSPAN="2" BGCOLOR="{FAMILY[fam]["fill"]}"><B>{name}</B></TD></TR>{r}</TABLE>>')
    pk = f'<FONT COLOR="{NAVY}"><B>PK</B></FONT>'
    fk = f'<FONT COLOR="{FAMILY[fam]["band"]}"><B>FK</B></FONT>'
    return "\n".join([
        "digraph legend {",
        f'  graph [rankdir=LR, nodesep=0.5, ranksep=1.6, pad=0.3, fontname="{FONT}"];',
        f'  node [shape=plain, fontname="{FONT}", fontsize=10];',
        f'  edge [color="{EDGE}", dir=both, fontname="{FONT}", fontsize=9, arrowsize=0.9];',
        f'  child [label={ent("child", [(fk, "<B>parent_id</B>", "r"), (fk, "other_id", "o"), ("", "status", "s")])}];',
        f'  parent [label={ent("parent", [(pk, "<B>id</B>", "id")])}];',
        f'  other [label={ent("other", [(pk, "<B>id</B>", "id")])}];',
        '  ext [shape=box, style="rounded,dashed,filled", fillcolor="#F7F7F7", color="#8C8C8C", fontsize=9, label="schema.table (other module)"];',
        f'  child:r -> parent:id [arrowtail=crowodot, arrowhead=teetee, label="required: many to exactly one"];',
        f'  child:o -> other:id [arrowtail=crowodot, arrowhead=teeodot, label="optional: many to zero or one"];',
        f'  child:s -> ext [arrowtail=teeodot, arrowhead=teetee, style=dashed, label="one to one (unique key), to another module"];',
        "}"])


def render(name, dot):
    for d in ("svg", "png", "dot"):
        os.makedirs(os.path.join(OUT, d), exist_ok=True)
    open(os.path.join(OUT, "dot", name + ".dot"), "w", encoding="utf-8").write(dot)
    subprocess.run(["dot", "-Tsvg", "-o", os.path.join(OUT, "svg", name + ".svg")], input=dot.encode(), check=True)
    subprocess.run(["dot", "-Tpng", "-Gdpi=170", "-o", os.path.join(OUT, "png", name + ".png")], input=dot.encode(), check=True)
    # diagrams use few colours: an indexed palette keeps them sharp at a third of the size
    from PIL import Image
    png = os.path.join(OUT, "png", name + ".png")
    Image.open(png).convert("RGB").quantize(colors=64, method=Image.Quantize.MEDIANCUT).save(png, optimize=True)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    db, args = sys.argv[1], sys.argv[2:]
    out = subprocess.run(["psql", *args, "-d", db, "-At", "-c", Q_MODEL], check=True, capture_output=True, text=True).stdout
    tables = json.loads(out)
    model = {f'{t["schema"]}.{t["name"]}': t for t in tables}
    render("E00_overview", overview_dot(model))
    render("legend", legend_dot())
    for g in GROUPS:
        render(f"{g[0]}", group_dot(g, model))
    os.makedirs(BUILD, exist_ok=True)
    json.dump({"tables": tables, "groups": GROUPS, "stores": DATA_STORES}, open(os.path.join(BUILD, "model.json"), "w"), indent=0)
    print(f"rendered {len(GROUPS) + 2} diagrams for {len(tables)} tables")


if __name__ == "__main__":
    main()
