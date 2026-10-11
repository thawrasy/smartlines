#!/usr/bin/env python3
"""erd_mermaid.py — مخططات ERD بمعيار Crow's Foot (Mermaid erDiagram) تُولَّد من النموذج والـDDL نفسه.

- كل جدول: المفتاح الأساسي PK من DDL (يشمل TenantId في المفاتيح المركّبة)، والمفاتيح الأجنبية FK العملية.
  كل مخطط يرسم جداول مجموعته فقط؛ الروابط إلى جداول خارج المجموعة تظهر في جدول العلاقات لا في الرسم.
  لا تُرسم أعمدة المشترك ولا أعمدة الإثبات، ولا الأعمدة غير المفتاحية (تفاصيلها في جداول المواصفات).
- كل علاقة: طرف الأب || إذا كان العمود إلزاميًا و |o إذا كان اختياريًا؛ وطرف الابن }o. الخط يحمل أعمدة الربط.
  كل مجموعة أعمدة (إلزامي أو اختياري) بين الأب والابن خط مستقل، فلا يُعرض اختياري كإلزامي.
- يُرسم كل عمود مفتاح عمل مرة واحدة؛ مفتاح الملكية TenantId → plat.Tenant لا يُرسم (الوثيقة تشرحه).
- الإخراج: docs/diagrams/erd/<group>.mmd و.svg (مصدر متجه) و.png بدقة مضاعفة (المدمج في Word، يبقى واضحًا عند التكبير).
  الصورة تُرسم بعرضها الطبيعي لا بعرض نافذة المتصفّح، فيبقى النص بحجمه داخل الشكل.
"""
import glob, math, os, re, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dbgen, erd_pro, ddl_keys

ROOT = os.path.join(HERE, '..', '..')
OUT = os.path.join(ROOT, 'docs', 'diagrams', 'erd')
MMDC = os.environ.get('MMDC', '/tmp/claude-0/mmdc/node_modules/.bin/mmdc')
PUPPET = os.environ.get('PUPPETEER_CFG', '/tmp/claude-0/mmdc/puppeteer.json')
# htmlLabels=false: النص يُكتب SVG <text> لا foreignObject، فيظهر في Word وLibreOffice والمتصفحات
MERMAID_CFG = os.path.join(HERE, 'mermaid_config.json')
# أعمدة الإثبات والتتبع (مصدر القيمة والتحقق والتعارض وسلسلة المراجعة وفاعل الإجراء): تُخفى من الرسم وتُعلَّم «إثبات»
PROVENANCE = {'SourceDocumentId', 'CandidateASourceDocumentId', 'CandidateBSourceDocumentId', 'VerifiedBy',
              'ConflictId', 'SupersedesId', 'CreatedBy', 'UpdatedBy', 'AssignedBy', 'GrantedBy', 'RevokedBy',
              'EndedBy', 'ActorUserId', 'OnBehalfOfUserId'}


def is_prov(name):
    return name in PROVENANCE


def ent(fq):
    return fq.replace('.', '_')


def base_type(c, tables):
    raw = erd_pro.col_type(c, tables) or 'unknown'
    return re.split(r'[\s(]', raw.strip())[0].lower() or 'unknown'


def pk_type(t, name, tables):
    if name == 'TenantId':
        return 'int'
    c = next((x for x in t.cols if x.name == name), None)
    if c is not None:
        return base_type(c, tables)
    return dbgen.pk_sqltype(t)[0].split('(')[0].lower()


def entity_block(fq, tables):
    """المفتاح الأساسي من DDL، والمفاتيح الأجنبية العملية من النموذج؛ بلا أعمدة أخرى."""
    t = tables[fq]
    pk = ddl_keys.pk_cols(fq)
    rows = [f'    {pk_type(t, n, tables)} {n} PK' for n in pk]
    for c in t.cols:
        if c.fk and c.name not in pk and not is_prov(c.name) and not (c.name == 'TenantId' and c.fk == 'plat.Tenant'):
            rows.append(f'    {base_type(c, tables)} {c.name} FK')
    return f'  {ent(fq)}["{fq}"] {{\n' + '\n'.join(rows) + '\n  }'


def relation_lines(members, tables):
    """خط لكل (أب، ابن، إلزام): الإلزامي و الاختياري منفصلان، والتسمية = أعمدة الربط."""
    internal = set(members)
    groups, stubs = {}, set()
    for fq in members:
        for c in tables[fq].cols:
            if not c.fk or c.fk == fq or is_prov(c.name): continue
            if c.name == 'TenantId' and c.fk == 'plat.Tenant': continue
            if c.fk not in internal: stubs.add(c.fk)
            groups.setdefault((c.fk, fq, bool(c.req)), []).append(c.name)
    out = []
    for (parent, child, req), cols in sorted(groups.items(), key=lambda kv: (kv[0][0], kv[0][1], not kv[0][2])):
        left = '||' if req else '|o'
        label = ', '.join(sorted(set(cols)))
        out.append(f'  {ent(parent)} {left}--o{{ {ent(child)} : "{label}"')
    return out, stubs


def group_source(title, members, tables):
    """مخطط المجموعة: جداولها فقط؛ الروابط بين جداولها تُرسم، والروابط إلى جداول خارجية تظهر في جدول العلاقات
    (والعمود FK يبقى ظاهرًا داخل الجدول)، فيبقى الرسم بعرض صفحة مقروء."""
    rel, _ = relation_lines(members, tables)
    keep = [line for line in rel if any(ent(m) == line.split()[0] for m in members)]
    head = [f'%% {title}', 'erDiagram']
    ents = [entity_block(fq, tables) for fq in members]
    return '\n'.join(head + ents + keep) + '\n'


def svg_size(svg_path):
    s = open(svg_path, encoding='utf-8').read()
    root = re.search(r'<svg\b[^>]*>', s).group(0)
    vb = re.search(r'viewBox="([-\d.]+) ([-\d.]+) ([\d.]+) ([\d.]+)"', root)
    return float(vb.group(3)), float(vb.group(4))


def fix_svg_size(svg_path, w, h):
    """يثبت أبعاد جذر SVG بالقيم الطبيعية حتى تعرضها Word بنسبة صحيحة، ويُبقي بقية الجذر (المعرّف والأنماط) كما هي."""
    s = open(svg_path, encoding='utf-8').read()

    def fix_root(m):
        tag = re.sub(r'\swidth="[^"]*"', '', m.group(0))
        tag = re.sub(r'\sheight="[^"]*"', '', tag)
        return tag.replace('<svg', f'<svg width="{w:.0f}" height="{h:.0f}"', 1)

    s = re.sub(r'<svg\b[^>]*>', fix_root, s, count=1)
    open(svg_path, 'w', encoding='utf-8').write(s)


def render(name, text):
    """يرسم بعرضه الطبيعي: المتصفح يرسم SVG بالحجم الطبيعي ثم يُصدَّر PNG بالمقاس نفسه."""
    os.makedirs(OUT, exist_ok=True)
    mmd = os.path.join(OUT, name + '.mmd'); svg = os.path.join(OUT, name + '.svg'); png = os.path.join(OUT, name + '.png')
    open(mmd, 'w', encoding='utf-8').write(text)
    subprocess.run([MMDC, '-p', PUPPET, '-c', MERMAID_CFG, '-i', mmd, '-o', svg, '-b', 'white'], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=240)
    w, h = svg_size(svg)
    fix_svg_size(svg, w, h)
    subprocess.run([MMDC, '-p', PUPPET, '-c', MERMAID_CFG, '-i', mmd, '-o', png, '-b', 'white', '-w', str(math.ceil(w)),
                    '-H', str(math.ceil(h)), '-s', '2'], check=True,
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
    chunks = [core[i:i + erd_pro.MAX_PER_DIAGRAM] for i in range(0, len(core), erd_pro.MAX_PER_DIAGRAM)]
    for i, chunk in enumerate(chunks, 1):
        made.append(render(f'core_tenancy_{i}', group_source(f'النواة ({i}/{len(chunks)})', chunk, tables)))
    made.append(render('schema_map', schema_source(tables)))
    print('rendered', len(made), 'ERD diagrams (svg + png) ->', OUT)


if __name__ == '__main__':
    main()
