#!/usr/bin/env python3
"""erd_manifest.py — يُخرج JSON يصف مخطط علاقات الجداول كما يُرسم في docs/diagrams/erd، ليبني منه erd_docx.js ملف Word.

الاستخدام:  python3 tools/dbgen/erd_manifest.py | NODE_PATH=... node tools/dbgen/erd_docx.js docs/20-DATABASE-RELATIONSHIPS-ERD.docx docs
المصدر الوحيد للبيانات هو النموذج db/model/*.model؛ لا أرقام مكتوبة يدويًا.
"""
import glob, json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dbgen, erd_pro, erd_mermaid
from PIL import Image

ROOT = os.path.join(HERE, '..', '..')
DIAG = os.path.join('diagrams', 'erd')           # مسارات الصور نسبةً إلى docs/
DATE = '2026-10-11'
MODULE_ORDER = [('m0', 'م0'), ('m1', 'م1'), ('m2_3', 'م2–م3'), ('m4', 'م4'), ('m5', 'م5'), ('m6', 'م6'), ('m7_8', 'م7/م8')]
PROV = erd_mermaid.PROVENANCE


def trim(s, n=170):
    s = ' '.join((s or '').split())
    return s if len(s) <= n else s[:n - 1] + '…'


def dims(rel):
    p = os.path.join(ROOT, 'docs', rel)
    with Image.open(p) as im:
        return im.size


def module_of(key):
    for prefix, _ in sorted(MODULE_ORDER, key=lambda x: -len(x[0])):   # m7_8 قبل m2_3 قبل m0 ...
        if key.startswith(prefix):
            return prefix
    return 'other'


def members_of(fqs, tables):
    rows = []
    for fq in fqs:
        t = tables[fq]
        pk, fk, uq = erd_pro.key_info(t)
        rows.append({'fq': fq, 'schema': t.fq.split('.')[0], 'purpose': trim(t.comment),
                     'pk': ', '.join(pk), 'fk': sum(1 for c in t.cols if c.fk), 'uq': len(uq)})
    return rows


def relations_of(fqs, tables):
    """كل مفتاح أجنبي عملي لجدول داخل المجموعة (الابن = الجدول). يُستبعد عمود المشترك TenantId → plat.Tenant
    لأنه ملكية لا علاقة عمل، ويُعلَّم عمود الإثبات بنوع «إثبات»."""
    out = []
    for fq in fqs:
        for c in tables[fq].cols:
            if not c.fk or (c.name == 'TenantId' and c.fk == 'plat.Tenant'):
                continue
            out.append({'child': fq, 'column': c.name, 'parent': c.fk, 'required': bool(c.req),
                        'cascade': bool(c.cascade), 'via': list(c.via or []),
                        'kind': 'إثبات' if c.name in PROV else 'عمل', 'drawn': c.name not in PROV})
    return out


def group_entry(key, title, sub, members, tables, is_core=False):
    png = f'{DIAG}/{key}.png'
    w, h = dims(png)
    return {'key': key, 'title': title, 'sub': sub, 'image': png, 'w': w, 'h': h,
            'members': members_of(members, tables), 'relations': relations_of(members, tables)}


def main():
    tables, errs, _ = dbgen.load(sorted(glob.glob(os.path.join(ROOT, 'db', 'model', '*.model'))), False)
    if errs:
        raise SystemExit('model errors: ' + '; '.join(errs[:3]))
    plan = erd_pro.plan_members(tables)

    # المفاتيح الأجنبية في DDL = ملكية المشترك (TenantId → plat.Tenant، تُولَّد آليًا) + مفاتيح النموذج نفسه
    owner_fk = sum(1 for t in tables.values() if t.tenant_scoped or any(c.name == 'TenantId' and c.fk == 'plat.Tenant' for c in t.cols))
    model_fk = sum(1 for t in tables.values() for c in t.cols if c.fk and not (c.name == 'TenantId' and c.fk == 'plat.Tenant'))
    prov_fk = sum(1 for t in tables.values() for c in t.cols if c.fk and c.name in PROV)
    ddl = os.path.join(ROOT, 'db', 'generated', 'tsql', '002_foreign_keys.sql')
    ddl_fk = open(ddl, encoding='utf-8').read().count('FOREIGN KEY')
    if owner_fk + model_fk != ddl_fk:
        raise SystemExit(f'FK count mismatch: model+owner={owner_fk + model_fk} DDL={ddl_fk}')
    schemas = {}
    for t in tables.values():
        schemas.setdefault(t.schema, []).append(t)
    schema_rows = [{'schema': s, 'tables': len(ts), 'owned': sum(1 for t in ts if erd_pro.is_owned(t))}
                   for s, ts in sorted(schemas.items())]
    pairs = {}
    for t in tables.values():
        for c in t.cols:
            if c.fk:
                p = c.fk.split('.')[0]
                if p != t.schema:
                    pairs[(p, t.schema)] = pairs.get((p, t.schema), 0) + 1
    pair_rows = [{'parent': p, 'child': c, 'count': n} for (p, c), n in sorted(pairs.items()) if n >= 5]

    core_members = [t for t in erd_pro.CORE_TENANCY if t in tables]
    core = group_entry('core_tenancy', 'العلاقات الأساسية: المشترك والمستخدمون والصلاحيات',
                       'جداول النواة: المشترك والهوية والأدوار والصلاحيات ومفتاح التشفير والشركة', core_members, tables, True)
    core['image'] = f'{DIAG}/core_tenancy.png'

    groups = []
    for prefix, label in MODULE_ORDER:
        for key, title, sub, members in plan:
            if module_of(key) == prefix:
                groups.append(dict(group_entry(key, title, sub, members, tables), module=label))

    index = []
    group_of = {}
    for g in groups:
        for m in g['members']:
            group_of.setdefault(m['fq'], g['title'])
    for fq in sorted(tables):
        t = tables[fq]
        index.append({'fq': fq, 'schema': t.schema, 'group': group_of.get(fq, '—'), 'purpose': trim(t.comment, 120)})

    meta = {
        'title': 'مخطط علاقات جداول قاعدة البيانات',
        'subtitle': 'مخطط ERD بتدوين Crow\'s Foot · SQL Server 2025',
        'version': 'v0.3 مسودة', 'date': DATE,
        'tables': len(tables), 'schemas': len(schemas), 'fk_total': ddl_fk,
        'fk_owner': owner_fk, 'fk_model': model_fk, 'fk_prov': prov_fk, 'groups': len(groups) + 1,
        'source': 'db/model/*.model (النموذج المرجعي) · مُولَّد بـ tools/dbgen/erd_manifest.py',
    }
    out = {'meta': meta, 'schemaMap': {'image': f'{DIAG}/schema_map.png', 'w': dims(f'{DIAG}/schema_map.png')[0],
           'h': dims(f'{DIAG}/schema_map.png')[1], 'schemas': schema_rows, 'pairs': pair_rows},
           'core': core, 'groups': groups, 'index': index}
    json.dump(out, sys.stdout, ensure_ascii=False, indent=1)


if __name__ == '__main__':
    main()
