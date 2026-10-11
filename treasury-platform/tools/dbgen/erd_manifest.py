#!/usr/bin/env python3
"""erd_manifest.py — يُخرج JSON يصف مخطط علاقات الجداول كما يُرسم في docs/diagrams/erd، ليبني منه erd_docx.js ملف Word.

الاستخدام:  python3 tools/dbgen/erd_manifest.py | NODE_PATH=... node tools/dbgen/erd_docx.js docs/20-DATABASE-RELATIONSHIPS-ERD.docx docs
المصادر: النموذج db/model/*.model (الأعمدة والعلاقات والغرض) والـDDL المولَّد db/generated/tsql (المفاتيح الأساسية
والقيود الفريدة وعدد المفاتيح). لا رقم مكتوب يدويًا، وكل مجموع يُقارَن بالـDDL قبل الكتابة.
"""
import glob, json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dbgen, erd_pro, erd_mermaid, ddl_keys

ROOT = os.path.join(HERE, '..', '..')
DIAG = 'diagrams/erd'                       # مسارات الصور نسبةً إلى docs/
DATE = '2026-10-11'
MODULE_ORDER = [('m0', 'م0'), ('m1', 'م1'), ('m2_3', 'م2–م3'), ('m4', 'م4'), ('m5', 'م5'), ('m6', 'م6'), ('m7_8', 'م7/م8')]


def module_of(key):
    for prefix, _ in sorted(MODULE_ORDER, key=lambda x: -len(x[0])):
        if key.startswith(prefix):
            return prefix
    return 'other'


def purpose(comment):
    """الغرض = الجزء قبل «--»؛ ما بعده ملاحظات تطوير (جديد/أولوية) لا تُعرض كغرض."""
    return ' '.join((comment or '').split()).split(' -- ')[0].strip()


def is_owner_key(c):
    return c.name == 'TenantId' and c.fk == 'plat.Tenant'


def natural_size(name):
    return erd_mermaid.svg_size(os.path.join(ROOT, 'docs', DIAG, name + '.svg'))


def members_of(fqs, tables):
    rows = []
    for fq in fqs:
        t = tables[fq]
        rows.append({'fq': fq, 'schema': t.schema, 'purpose': purpose(t.comment),
                     'pk': ', '.join(ddl_keys.pk_cols(fq)),
                     'fk': sum(1 for c in t.cols if c.fk and not is_owner_key(c)),
                     'uq': ddl_keys.unique_count(fq)})
    return rows


def relations_of(fqs, tables):
    """كل مفتاح أجنبي عملي لجدول داخل المجموعة (الابن). مفتاح الملكية TenantId لا يُعرض؛ ويُعلَّم كل صف:
    «إثبات» لأعمدة المصدر والتحقق والتعارض والتتبع، و«عمل» لغيرها. «مرسوم» = الأب داخل المجموعة نفسها."""
    inside = set(fqs)
    out = []
    for fq in fqs:
        for c in tables[fq].cols:
            if not c.fk or is_owner_key(c):
                continue
            out.append({'child': fq, 'column': c.name, 'parent': c.fk, 'required': bool(c.req),
                        'cascade': bool(c.cascade), 'via': list(c.via or []),
                        'kind': 'إثبات' if erd_mermaid.is_prov(c.name) else 'عمل',
                        'drawn': c.fk in inside and not erd_mermaid.is_prov(c.name)})
    return out


def entry(key, title, sub, members, tables, module_label=None):
    w, h = natural_size(key)
    e = {'key': key, 'title': title, 'sub': sub, 'image': f'{DIAG}/{key}.png', 'svg': f'{DIAG}/{key}.svg',
         'w': w, 'h': h, 'members': members_of(members, tables), 'relations': relations_of(members, tables)}
    if module_label:
        e['module'] = module_label
    return e


def main():
    tables, errs, _ = dbgen.load(sorted(glob.glob(os.path.join(ROOT, 'db', 'model', '*.model'))), False)
    if errs:
        raise SystemExit('model errors: ' + '; '.join(errs[:3]))
    plan = erd_pro.plan_members(tables)

    # ---- التحقق من الأرقام مقابل DDL قبل أي كتابة ----
    ddl = ddl_keys.totals()
    model_fk = sum(1 for t in tables.values() for c in t.cols if c.fk and not is_owner_key(c))
    owners = ddl_keys.owner_tables()
    if len(tables) != ddl['tables']:
        raise SystemExit(f'table count mismatch: model={len(tables)} DDL={ddl["tables"]}')
    if len(owners) + model_fk != ddl['fk_total']:
        raise SystemExit(f'FK mismatch: owner={len(owners)} + model={model_fk} != DDL {ddl["fk_total"]}')
    if {t.fq for t in tables.values() if any(is_owner_key(c) for c in t.cols)} - owners:
        raise SystemExit('a model owner key has no matching DDL foreign key')

    # ---- المخططات ----
    schemas = {}
    for t in tables.values():
        schemas.setdefault(t.schema, []).append(t)
    schema_rows = [{'schema': s, 'tables': len(ts), 'owned': sum(1 for t in ts if t.fq in owners)}
                   for s, ts in sorted(schemas.items())]
    pairs = {}
    for t in tables.values():
        for c in t.cols:
            if c.fk and c.fk.split('.')[0] != t.schema:
                k = (c.fk.split('.')[0], t.schema)
                pairs[k] = pairs.get(k, 0) + 1
    pair_rows = [{'parent': p, 'child': c, 'count': n} for (p, c), n in sorted(pairs.items()) if n >= 5]

    # ---- النواة والوحدات ----
    core_members = [t for t in erd_pro.CORE_TENANCY if t in tables]
    core = entry('core_tenancy', 'العلاقات الأساسية: المشترك والمستخدمون والصلاحيات',
                 'جداول النواة: المشترك والهوية والأدوار والصلاحيات ومفتاح التشفير والشركة', core_members, tables)
    core['image'] = f'{DIAG}/core_tenancy.png'
    core['svg'] = f'{DIAG}/core_tenancy.svg'

    core_chunks = [core_members[i:i + erd_pro.MAX_PER_DIAGRAM] for i in range(0, len(core_members), erd_pro.MAX_PER_DIAGRAM)]
    core_groups = []
    for i, chunk in enumerate(core_chunks, 1):
        cg = entry(f'core_tenancy_{i}', f'النواة ({i}/{len(core_chunks)}) · المشترك والهوية والصلاحيات', 'جداول النواة في رسم مستقل ليبقى النص مقروءًا', chunk, tables)
        core_groups.append(cg)

    groups = []
    for prefix, label in MODULE_ORDER:
        for key, title, sub, members in plan:
            if module_of(key) == prefix:
                groups.append(entry(key, title, sub, members, tables, label))
    if sorted(m['fq'] for g in groups for m in g['members']) != sorted(tables):
        raise SystemExit('every table must belong to exactly one module group')

    modules = []
    for prefix, label in MODULE_ORDER:
        gs = [g for g in groups if g['module'] == label]
        modules.append({'label': label, 'groups': len(gs), 'tables': sum(len(g['members']) for g in gs)})

    group_of = {m['fq']: g['title'] for g in groups for m in g['members']}
    index = [{'fq': fq, 'schema': tables[fq].schema, 'group': group_of[fq], 'purpose': purpose(tables[fq].comment)}
             for fq in sorted(tables)]

    sw, sh = natural_size('schema_map')
    out = {
        'meta': {
            'title': 'مخطط علاقات جداول قاعدة البيانات',
            'subtitle': 'مخطط ERD بتدوين Crow\'s Foot · SQL Server 2025',
            'version': 'v0.3 مسودة', 'date': DATE,
            'tables': ddl['tables'], 'schemas': len(schemas), 'fk_total': ddl['fk_total'],
            'fk_owner': len(owners), 'fk_model': model_fk,
            'fk_prov': sum(1 for t in tables.values() for c in t.cols if c.fk and erd_mermaid.is_prov(c.name)),
            'unique_total': ddl['unique_total'],
            'groups': len(groups) + len(core_groups), 'module_groups': len(groups), 'core_groups': len(core_groups),
            'provenance': sorted(erd_mermaid.PROVENANCE),
            'max_tables': erd_pro.MAX_PER_DIAGRAM,
            'source': 'db/model/*.model (الأعمدة والعلاقات) · db/generated/tsql (المفاتيح والقيود) · tools/dbgen/erd_manifest.py',
        },
        'modules': modules,
        'schemaMap': {'image': f'{DIAG}/schema_map.png', 'svg': f'{DIAG}/schema_map.svg', 'w': sw, 'h': sh,
                      'schemas': schema_rows, 'pairs': pair_rows},
        'core': core, 'coreGroups': core_groups, 'groups': groups, 'index': index,
    }
    json.dump(out, sys.stdout, ensure_ascii=False, indent=1)


if __name__ == '__main__':
    main()
