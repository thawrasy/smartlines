#!/usr/bin/env python3
"""يولّد قاموس البيانات ومخططات ERD من قاعدة مبنية فعلياً (فلا تختلف الوثائق عن المخطط).

الاستخدام:
    python3 db/tools/gen_docs.py <database> [psql connection args...]
المخرجات:
    db/DATA_DICTIONARY.md  — كل جدول بغرضه وأعمدته وأنواعها وقيودها
    db/ERD.md              — مخطط Mermaid لكل وحدة من المفاتيح الأجنبية الفعلية
"""
import json
import os
import subprocess
import sys

SCHEMAS = [
    ("iam", "الهوية والأطراف والمستخدمون والصلاحيات وواجهات API"),
    ("ref", "البيانات المرجعية والملفات"),
    ("sys", "الإعدادات وصندوق الأحداث وWebhooks"),
    ("net", "الشبكة: المحطات والخطوط ورموز الناقلين"),
    ("fleet", "الأسطول: المركبات والمقاعد والطاقم والتراخيص والتأمين"),
    ("pricing", "التسعير والضرائب والعمولات والحملات والولاء"),
    ("ops", "الرحلات والمخزون والتشغيل والتتبع والحوادث"),
    ("sales", "القنوات والحجوزات والمسافرون والتذاكر"),
    ("fin", "المحافظ والدفتر والمدفوعات والتوزيع والتسوية"),
    ("acct", "المحاسبة المبسطة والفوترة الإلكترونية والملف الضريبي"),
    ("crm", "الشكاوى والتقييم والإشعارات والمساعد الذكي"),
    ("gov", "الحوكمة والالتزامات وحماية البيانات"),
    ("sec", "الأمن: قواعد IP والمخاطر والتوقيع ووحدة الأمن"),
    ("audit", "سجلات الدخول والإجراءات (إلحاق فقط)"),
]

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
    AND n.nspname IN ('sys','ref','iam','net','fleet','pricing','ops','sales','fin','acct','crm','gov','sec','audit')
) t
"""

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


# روابط "من نفّذ" وروابط البيانات المرجعية تُحذف من الرسم للوضوح (تبقى كاملة في قاموس البيانات)
ACTOR_COLS = {"created_by", "approved_by", "updated_by", "reviewed_by", "verified_by", "decided_by", "granted_by",
              "revoked_by", "requested_by", "closed_by", "uploaded_by", "changed_by", "by_user_id", "handled_by",
              "executed_by", "assigned_to", "owner_user_id", "reviewer_id", "second_approver", "payout_by",
              "scanned_by_user_id", "reported_by", "added_by", "inspector_user_id", "approver_id", "actor_id"}
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

    # ---------------- قاموس البيانات ----------------
    total_cols = sum(len(t["columns"]) for t in tables)
    lines = ["# قاموس البيانات — قاعدة بيانات مسلك (المرحلة الأولى)", "",
             "> مولَّد آلياً من القاعدة المبنية (`db/tools/gen_docs.py`)؛ لا يُعدَّل يدوياً.", "",
             f"**{len(tables)} جدولاً، {total_cols} عموداً، في {len(by_schema)} مخططاً.**", "",
             "الرموز: 🔑 مفتاح أساسي · 🔗 مفتاح أجنبي · ✱ إلزامي · 🛡️ عزل المستأجر (RLS) · 🧩 مقسّم شهرياً · 🔒 إلحاق فقط/محمي من التعديل", "",
             "## الفهرس", ""]
    for s, title in SCHEMAS:
        if s in by_schema:
            lines.append(f"- [`{s}` — {title}](#{s}) ({len(by_schema[s])} جدولاً)")
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
            if any(x.endswith("immutable") or x in ("einvoice_guard", "journal_guard", "license_locked", "ip_rule_no_delete") for x in trig):
                flags.append("🔒")
            lines += [f"### `{s}.{t['name']}` {' '.join(flags)}", "", t["comment"] or "", "",
                      "| العمود | النوع | قيود | افتراضي |", "|---|---|---|---|"]
            for c in t["columns"]:
                marks = ("🔑 " if c["pk"] else "") + (f"🔗 `{c['fk']}` " if c["fk"] else "") + ("✱" if c["notnull"] else "")
                default = (c["default"] or "").replace("|", "\\|")
                if len(default) > 40:
                    default = default[:37] + "..."
                lines.append(f"| `{c['name']}` | `{c['type']}` | {marks} | {('`' + default + '`') if default else ''} |")
            lines.append("")
    open(os.path.join(root, "DATA_DICTIONARY.md"), "w", encoding="utf-8").write("\n".join(lines))

    # ---------------- ERD ----------------
    out = ["# مخططات العلاقات (ERD) — قاعدة بيانات مسلك (المرحلة الأولى)", "",
           "> مولَّدة آلياً من المفاتيح الأجنبية الفعلية في القاعدة المبنية. كل مخطط يعرض جداول الوحدة بأعمدتها الرئيسية،",
           "> والجداول التي ترتبط بها من وحدات أخرى (بلا أعمدة). الخط المتصل = علاقة إلزامية، والمتقطع = اختيارية.",
           "> للوضوح لا تُرسم روابط «من نفّذ» (created_by، approved_by...) إلى `iam.app_user`، ولا روابط العملة والدولة",
           "> ومفاتيح التشفير والملفات؛ وهي كاملة في [قاموس البيانات](DATA_DICTIONARY.md).", "",
           "## الصورة العامة: الوحدات وعلاقاتها", "", "```mermaid", "flowchart LR"]
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
