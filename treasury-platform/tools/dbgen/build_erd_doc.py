#!/usr/bin/env python3
"""build_erd_doc.py — يُنتج docs/20-database-design-and-erd.md: وثيقة التصميم والـ ERD بصيغتها المهنية.

- الأقسام السردية (القرارات والعزل والأمن والنشر...) تُنقل من docs/20-database-design.md كما هي.
- §10 تُولَّد من النموذج: مخطط المخططات، ومخطط كل مجموعة جداول (ERD بتدوين Crow's Foot)،
  وجدول مواصفات لكل جدول، وجدول علاقات لكل مفتاح أجنبي (الأب، الإلزام، النطاق، الحذف).
"""
import glob, os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dbgen, erd_pro

ROOT = os.path.join(HERE, '..', '..')
DOCS = os.path.join(ROOT, 'docs')
OLD = os.path.join(DOCS, '20-database-design.md')
NEW = os.path.join(DOCS, '20-database-design-and-erd.md')


def trim(s, n=150):
    s = (s or '').strip()
    return s if len(s) <= n else s[:n - 1] + '…'


def esc_cell(s):
    return str(s).replace('|', '\\|').replace('\n', ' ')


def scope_of(child, parent):
    if erd_pro.is_owned(child) and erd_pro.is_owned(parent): return 'مشترك · مركّب'
    if erd_pro.is_owned(child) and not erd_pro.is_owned(parent): return 'مرجع عام'
    return 'عام'


def table_rows(members, tables):
    rows = ['| الجدول | الغرض | PK | FK | UQ | CHECK | أعمدة أخرى |', '|---|---|---|---|---|---|---|']
    for fq in members:
        t = tables[fq]
        pk, fk, uq = erd_pro.key_info(t)
        others = len(t.cols) - len(set(pk) | {c.name for c in t.cols if c.fk} | {c for c in uq})
        rows.append(f'| `{fq}` | {esc_cell(trim(t.comment))} | {", ".join(pk)} | {len([c for c in t.cols if c.fk])} | {len(uq)} | {len(t.checks)} | {others} |')
    return rows


def relation_rows(members, tables):
    rows = ['| الطفل (الجدول.العمود) | الأب | العلاقة | الإلزام | النطاق | الحذف | أعمدة النطاق |', '|---|---|---|---|---|---|---|']
    for fq in members:
        t = tables[fq]
        for c in t.cols:
            if not c.fk: continue
            p = tables[c.fk]
            rows.append(f'| `{fq}.{c.name}` | `{c.fk}` | 1 : N | {"إلزامي" if c.req else "اختياري"} | {scope_of(t, p)} | {"CASCADE" if c.cascade else "قيد"} | {", ".join(c.via) if c.via else "—"} |')
    if len(rows) == 2:
        rows.append('| — | — | — | — | — | — | — |')
    return rows


MODULE_ORDER = [
    ('m0', 'م0 · المنصة والهوية والتدقيق'),
    ('m1', 'م1 · الهيكل المؤسسي والأشخاص'),
    ('m2_3', 'م2–م3 · الجهات المالية والحسابات'),
    ('m4', 'م4 · الكتالوجات والمراجع'),
    ('m5', 'م5 · التسهيلات والتسعير والضمانات والالتزامات والبيانات المالية'),
    ('m6', 'م6 · الطلبات ودورات العمل والإشعارات'),
    ('m7_8', 'م7/م8 · الاعتمادات المستندية والبروفورما'),
]


def generated_section(plan, tables):
    out = ['## 10. ERD والمواصفات التفصيلية حسب الوحدة', '',
           'كل مخطط في هذا القسم **مُولَّد من النموذج نفسه** (`db/model`)، فلا ينحرف عن قاعدة البيانات. الترتيب: أولًا خريطة المخططات، ثم مخطط كل مجموعة، ثم جدول مواصفات الجداول، ثم جدول علاقات كل مفتاح أجنبي.', '',
           '### 10.1 خريطة المخططات (Schema Map)', '',
           '![خريطة المخططات: المخططات والعلاقات بينها (خمسة مفاتيح أجنبية فأكثر)](diagrams/erd/schema_map.png)', '',
           '### 10.2 قراءة المخططات', '',
           '**مفتاح الرسم (معيار Crow\'s Foot):** `PK` المفتاح الأساسي · `FK` مفتاح أجنبي · `UK` فريد. طرف الأب `||` = واحد إلزامي، وطرف الابن `}o` = صفر أو أكثر؛ الاختياري `|o` = واحد أو لا شيء. اسم العلاقة = أعمدة الربط.', '',
           'الإحاطة: كل جدول مملوك للمشترك يحمل `TenantId` ويشير إلى `plat.Tenant`، ولم يُرسم هذا الربط في كل مخطط. العلاقات المرسومة **مفاتيح أجنبية فعلية**، وكل علاقة مكتوبة في جدول العلاقات بإلزامها ونطاقها وسلوك حذفها. أعمدة الإثبات والتدقيق (`SourceDocumentId` و`VerifiedBy` و`ConflictId` و`SupersedesId` و`CreatedBy` و`UpdatedBy`…) لا تُرسم في المخطط لتقليل الازدحام، وترد كاملة في جداول العلاقات. الجداول خارج المجموعة تظهر بمفتاحها فقط.', '']
    n = 3
    for prefix, title in MODULE_ORDER:
        groups = [g for g in plan if g[0].startswith(prefix + '_') or g[0] == prefix or (prefix == 'm0' and g[0].startswith('m0_'))]
        if prefix == 'm2_3': groups = [g for g in plan if g[0].startswith('m2_3')]
        if prefix == 'm7_8': groups = [g for g in plan if g[0].startswith('m7_8')]
        if prefix == 'm4': groups = [g for g in plan if g[0].startswith('m4')]
        if prefix == 'm5': groups = [g for g in plan if g[0].startswith('m5')]
        if prefix == 'm6': groups = [g for g in plan if g[0].startswith('m6')]
        if prefix == 'm1': groups = [g for g in plan if g[0].startswith('m1')]
        if prefix == 'm0': groups = [g for g in plan if g[0].startswith('m0')]
        if not groups: continue
        out += [f'### 10.{n} {title}', '']
        n += 1
        for key, gtitle, gsub, members in groups:
            out += [f'#### {gtitle}', '', f'*{gsub}* — {len(members)} جدولًا', '',
                    f'![{gtitle}](diagrams/erd/{key}.png)', '',
                    '**مواصفات الجداول**', ''] + table_rows(members, tables) + ['',
                    '**العلاقات (المفاتيح الأجنبية)**', ''] + relation_rows(members, tables) + ['']
    # الجداول المرجعية الخارجية (ref) ضمن m4 ومجموعة المراجع العامة
    return out


def split_sections(text):
    parts = re.split(r'(?m)^(?=## )', text)
    return parts


def main():
    tables, errs, _ = dbgen.load(sorted(glob.glob(os.path.join(ROOT, 'db', 'model', '*.model'))), False)
    if errs: raise SystemExit('model errors: ' + '; '.join(errs[:3]))
    plan = erd_pro.plan_members(tables)
    old = open(OLD, encoding='utf-8').read()
    parts = split_sections(old)
    head_and_sections = {}
    keep = []
    for p in parts:
        if p.startswith('# ') and not p.startswith('## '):
            continue           # العنوان القديم
        if p.startswith('## 10.'):
            continue
        if p.startswith('## 10. '):
            # نُبقي جدول خريطة المخططات القديم كمرجع داخل §10
            keep.append('__OLD10__')
            continue
        keep.append(p)
    body = ''.join(x for x in keep if x != '__OLD10__')
    body = body.replace('(diagrams/erd_', '(diagrams/erd_')
    # §3.7 و§9 و§11 تبقى بصورها القديمة كما هي
    front = ['# DATABASE DESIGN AND ERD — BankFas', '',
             '| البند | القيمة |', '|---|---|',
             '| الحالة | **مسودة للتقييم (الإصدار 0.3)** — تصميم قاعدة البيانات مع مخططات ERD مهنية (تدوين Crow\'s Foot) ومواصفات الجداول والعلاقات، مُولَّدة من النموذج |',
             '| التاريخ | 2026-10-10 |',
             '| المحرك المعتمد | **SQL Server 2025** |',
             '| المرجع | `db/model/*.model` (194 جدولًا في 20 مخططًا) — الملفات المولَّدة لا تُعدَّل يدويًا |',
             '| الدعم | `tools/dbgen/erd_pro.py` · `tools/dbgen/build_erd_doc.py` · `tools/dbgen/check_grants.py` |', '']
    changelog_row = '| C-11 | إعادة بناء الوثيقة كـ **DATABASE DESIGN AND ERD**: مخططات Crow\'s Foot مهنية، ومواصفة لكل جدول ولكل علاقة، مُولَّدة من النموذج بدل الصور البسيطة السابقة | طُلب ERD بمستوى مهني ومواصفات كاملة لكل جدول ومودول وعلاقة |'
    lines = body.split('\n')
    for i, ln in enumerate(lines):
        if ln.startswith('| C-10 |'):
            lines.insert(i + 1, changelog_row); break
    body = '\n'.join(lines)
    body = body.replace('![العلاقات الأساسية: المشترك والمستخدمون والأدوار والصلاحيات والمفاتيح](diagrams/pro/core_tenancy.png)',
                        '![المشترك والهوية: الجداول المملوكة للمشترك وكيف ترتبط بالمستخدمين والشركات](diagrams/erd/m0_identity.png)\n\n![المشترك والاشتراكات: الخطة والوحدات والمشغّلون ودعم الوصول](diagrams/erd/m0_tenancy.png)')
    gen = generated_section(plan, tables)
    marker = '\n## 11. '
    assert body.count(marker) == 1, body.count(marker)
    body = body.replace(marker, '\n' + '\n'.join(gen) + '\n' + marker.lstrip('\n') if False else marker, 1)
    before, after = body.split(marker, 1)
    doc = '\n'.join(front) + '\n' + before.rstrip() + '\n\n' + '\n'.join(gen) + '\n\n## 11. ' + after
    open(NEW, 'w', encoding='utf-8').write(doc)
    print('wrote', NEW, 'lines', doc.count('\n'))


if __name__ == '__main__':
    main()
