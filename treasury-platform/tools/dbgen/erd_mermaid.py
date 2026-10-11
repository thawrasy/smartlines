#!/usr/bin/env python3
"""erd_mermaid.py — مخططات ERD بمعيار Crow's Foot (Mermaid erDiagram) تُولَّد من النموذج نفسه.

- كل جدول: المفتاح الأساسي PK، والمفاتيح الأجنبية FK، والفريد UK، ومفتاح أعمال واحد أو اثنان عند الحاجة.
- كل علاقة: الأب ||  ·  الابن }o (إلزامي) أو |o--o{ (اختياري)، واسمها اسم عمود الربط.
- الجداول خارج الصورة: تظهر بمفتاحها فقط، وتحمل تعليق (external) في الاسم.
الإخراج: docs/diagrams/erd/<group>.mmd و <group>.png  (يتطلب mmdc ومتصفحًا)
"""
import glob, os, re, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dbgen, erd_pro

ROOT = os.path.join(HERE, '..', '..')
OUT = os.path.join(ROOT, 'docs', 'diagrams', 'erd')
MMDC = os.environ.get('MMDC', '/tmp/claude-0/mmdc/node_modules/.bin/mmdc')
PUPPET = os.environ.get('PUPPETEER_CFG', '/tmp/claude-0/mmdc/puppeteer.json')
MAX_ATTR = 6
# أعمدة الإثبات والتدقيق (المصدر والتحقق والتتبع): تُجمَّع في علاقة واحدة لكل أب، ولا تملأ الكيان
PROVENANCE = {'SourceDocumentId', 'VerifiedBy', 'ConflictId', 'SupersedesId', 'CreatedBy', 'UpdatedBy',
              'AssignedBy', 'GrantedBy', 'RevokedBy', 'EndedBy', 'ActorUserId', 'OnBehalfOfUserId'}


def ent(fq):
    return fq.replace('.', '_')


def base_type(c, tables):
    raw = erd_pro.col_type(c, tables) or 'unknown'
    base = re.split(r'[\s(]', raw.strip())[0].lower() or 'unknown'
    return base


def entity_block(fq, tables, external=False):
    t = tables[fq]
    pk, fk, uq = erd_pro.key_info(t)
    rows = []
    for n in pk:
        col = next((c for c in t.cols if c.name == n), None)
        typ = base_type(col, tables) if col else base_type(erd_pro._SurrogateCol(n, dbgen.pk_sqltype(t)[0]), tables) if False else dbgen.pk_sqltype(t)[0].split('(')[0].lower()
        rows.append(f'    {typ} {n} PK')
    if not external:
        for c in t.cols:
            if c.fk and c.name not in pk and c.name not in PROVENANCE:
                rows.append(f'    {base_type(c, tables)} {c.name} FK')
        extra = [c for c in t.cols if c.name not in pk and not c.fk and c.name in uq]
        for c in extra[:2]:
            rows.append(f'    {base_type(c, tables)} {c.name} UK')
        biz = [c for c in t.cols if not c.fk and c.name not in pk and c.name not in uq and not c.auto and c.req]
        for c in biz[: max(0, MAX_ATTR - len(rows))]:
            rows.append(f'    {base_type(c, tables)} {c.name}')
    return f'  {ent(fq)}["{fq}"] {{\n' + '\n'.join(rows) + '\n  }' if rows else f'  {ent(fq)}["{fq}"]'


def relation_lines(members, tables):
    """علاقة واحدة لكل زوج (أب، ابن): الإلزام = أي عمود إلزامي، والتسمية = أعمدة الربط."""
    internal = set(members)
    pairs, stubs = {}, set()
    for fq in members:
        for c in tables[fq].cols:
            if not c.fk or c.fk == fq or c.name in PROVENANCE: continue
            if c.fk not in internal: stubs.add(c.fk)
            cols, req = pairs.get((c.fk, fq), ([], False))
            cols.append(c.name); pairs[(c.fk, fq)] = (cols, req or c.req)
    out = []
    for (parent, child), (cols, req) in sorted(pairs.items()):
        left = '||' if req else '|o'
        label = ', '.join(sorted(set(cols)))
        out.append(f'  {ent(parent)} {left}--o{{ {ent(child)} : "{label}"')
    return out, stubs


def group_source(title, members, tables):
    rel, stubs = relation_lines(members, tables)
    head = [f'%% {title}', 'erDiagram']
    ents = [entity_block(fq, tables) for fq in members] + [entity_block(s, tables, external=True) for s in sorted(stubs)]
    return '\n'.join(head + ents + rel) + '\n'


def render(name, text):
    os.makedirs(OUT, exist_ok=True)
    mmd = os.path.join(OUT, name + '.mmd'); png = os.path.join(OUT, name + '.png')
    open(mmd, 'w', encoding='utf-8').write(text)
    subprocess.run([MMDC, '-p', PUPPET, '-i', mmd, '-o', png, '-b', 'white', '-s', '2'], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=240)
    return png


def schema_source(tables, min_fk=5):
    # خريطة المخططات: كل مخطط كيان بعدد جداوله، والعلاقة = عدد المفاتيح الأجنبية بين المخططين (≥ min_fk)
    sizes, cnt = {}, {}
    for t in tables.values():
        sizes[t.schema] = sizes.get(t.schema, 0) + 1
        for c in t.cols:
            if c.fk:
                p = c.fk.split('.')[0]
                if p != t.schema: cnt[(p, t.schema)] = cnt.get((p, t.schema), 0) + 1
    head = [f'%% خريطة المخططات: العلاقة = عدد المفاتيح الأجنبية بين المخططين (≥ {min_fk})', 'erDiagram']
    ents = []
    for s in sorted(sizes):
        ents += [f'  {s} {{', f'    int tables "{sizes[s]}"', '  }']
    rels = [f'  {p} ||--o{{ {c} : "{n} FK"' for (p, c), n in sorted(cnt.items()) if n >= min_fk]
    return '\n'.join(head + ents + rels) + '\n'


def main():
    tables, errs, _ = dbgen.load(sorted(glob.glob(os.path.join(ROOT, 'db', 'model', '*.model'))), False)
    if errs: raise SystemExit('model errors')
    plan = erd_pro.plan_members(tables)
    made = []
    for key, title, sub, members in plan:
        made.append(render(key, group_source(f'{title} — {sub}', members, tables)))
    core = [t for t in erd_pro.CORE_TENANCY if t in tables]
    made.append(render('core_tenancy', group_source('العلاقات الأساسية: المشترك والمستخدمون والصلاحيات', core, tables)))
    made.append(render('schema_map', schema_source(tables)))
    print('rendered', len(made), 'ERD diagrams ->', OUT)


if __name__ == '__main__':
    main()
