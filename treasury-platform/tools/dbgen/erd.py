#!/usr/bin/env python3
"""erd.py — يرسم مخططات العلاقات من النموذج نفسه (المفاتيح الأجنبية الفعلية)، فلا تنحرف عن قاعدة البيانات.

الإخراج: docs/diagrams/src/*.dot (المصدر) و docs/diagrams/*.png (يتطلب Graphviz `dot`).
الألوان: أزرق = مملوك للمشترك · برتقالي = عالمي · بنفسجي = مختلط · أحمر = noapp (محجوب عن التطبيق) · رمادي = جدول خارج الوحدة.
كل جدول يعرض مفتاحه ومفاتيحه الأجنبية؛ وباقي الأعمدة تُختصر بعددها. الفرض TenantId غير مرسوم في كل جدول (يشير كل جدول مملوك إلى plat.Tenant).
"""
import glob, os, subprocess, sys
from html import escape

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, '..', '..')
sys.path.insert(0, HERE)
import dbgen

OUT = os.path.join(ROOT, 'docs', 'diagrams')
SRC = os.path.join(OUT, 'src')
FONT = 'DejaVu Sans'
KIND_FILL = {'tenant': '#DCEBFA', 'global': '#FDE9D9', 'mixed': '#EADCF8', 'noapp': '#F8D7DA', 'stub': '#EEEEEE'}

GROUPS = [
    ('m0_identity', 'م0 · الهوية والمشترك والصلاحيات', ['plat', 'sec']),
    ('m0_platform', 'م0 · التدقيق والمستندات والإعدادات', ['aud', 'doc', 'cfg']),
    ('m1_org', 'م1 · الهيكل المؤسسي والأشخاص', ['org', 'pty']),
    ('m2_3_accounts', 'م2–م3 · المنشآت والحسابات والمفوّضون', ['ins', 'acc']),
    ('m4_catalogs', 'م4 · الكتالوجات والمراجع', ['cat', 'ref']),
    ('m5_facilities', 'م5 · التسهيلات والحدود والتسعير والشروط', ['fac', 'prc', 'cmp']),
    ('m5_collateral', 'م5 · الضمانات والالتزامات والبيانات المالية', ['col', 'obl', 'fin']),
    ('m6_workflow', 'م6 · الطلبات ودورات العمل والإشعارات', ['wfl', 'ntf']),
    ('m7_8_lc', 'م7/م8 · الاعتمادات المستندية والبروفورما', ['lc']),
]
CORE = ['plat.Tenant', 'plat.Plan', 'plat.TenantModule', 'plat.SupportAccessGrant', 'plat.PlatformOperator',
        'sec.TenantKey', 'sec.AppUser', 'sec.Role', 'sec.Permission', 'sec.RolePermission', 'sec.UserRole',
        'sec.UserCompanyScope', 'sec.UserSession', 'org.Company', 'org.Department', 'aud.AuditLog', 'ref.Country']


def kind_of(t):
    if 'noapp' in t.flags: return 'noapp'
    if t.is_global and not t.is_mixed: return 'global'
    if t.is_mixed: return 'mixed'
    return 'tenant'


def pk_of(t):
    if t.pk_cols: return list(t.pk_cols)
    return [f'{t.name}Id']


def node_html(t, kind, tables):
    pk = pk_of(t)
    rows = [f'<TR><TD BGCOLOR="{KIND_FILL[kind]}" ALIGN="LEFT" COLSPAN="2"><B>{escape(t.fq)}</B></TD></TR>']
    shown = set()
    for p in pk:
        rows.append(f'<TR><TD ALIGN="LEFT" PORT="{escape(p)}">PK</TD><TD ALIGN="LEFT">{escape(p)}</TD></TR>'); shown.add(p)
    fks = [c for c in t.cols if c.fk and c.name not in shown]
    for c in fks:
        tgt = c.fk
        rows.append(f'<TR><TD ALIGN="LEFT" PORT="{escape(c.name)}">FK</TD><TD ALIGN="LEFT">{escape(c.name)} → {escape(tgt.split(".")[1]) if tgt.split(".")[0] == t.schema else escape(tgt)}</TD></TR>')
        shown.add(c.name)
    others = len([c for c in t.cols if c.name not in shown and not c.auto]) + len([c for c in t.cols if c.auto and c.name not in shown])
    if others:
        rows.append(f'<TR><TD ALIGN="LEFT" COLSPAN="2"><FONT COLOR="#666666">+ {others} عمودًا آخر</FONT></TD></TR>')
    return '<<TABLE BORDER="1" CELLBORDER="0" CELLSPACING="0" CELLPADDING="3" COLOR="#7A8794">' + ''.join(rows) + '</TABLE>>'


def stub_html(fq):
    return f'<<TABLE BORDER="1" CELLBORDER="0" CELLSPACING="0" CELLPADDING="4" COLOR="#9AA3AD"><TR><TD BGCOLOR="{KIND_FILL["stub"]}"><FONT COLOR="#444444">{escape(fq)}</FONT></TD></TR></TABLE>>'


def ident(fq): return '"' + fq.replace('"', '') + '"'


def build_dot(name, title, tables, members, note):
    """members: fq list drawn as full nodes; any FK target outside members becomes a stub node"""
    lines = ['digraph G {', f'  graph [fontname="{FONT}", fontsize=18, label=<<B>{escape(title)}</B><BR/><FONT POINT-SIZE="11">{escape(note)}</FONT>>, labelloc=t, rankdir=LR, nodesep=0.35, ranksep=1.1, pad=0.3, bgcolor="white"];',
             f'  node [shape=plaintext, fontname="{FONT}", fontsize=10];', f'  edge [fontname="{FONT}", fontsize=9, color="#5B6B7A", arrowsize=0.7];']
    stubs = set()
    edges = []
    for fq in members:
        t = tables[fq]
        for c in t.cols:
            if not c.fk: continue
            if c.fk not in members:
                stubs.add(c.fk)
            edges.append((fq, c.name, c.fk, tables[c.fk].schema == t.schema if c.fk in tables else False))
    for fq in members:
        t = tables[fq]
        lines.append(f'  {ident(fq)} [label={node_html(t, kind_of(t), tables)}];')
    for s_ in sorted(stubs):
        lines.append(f'  {ident(s_)} [label={stub_html(s_)}];')
    for src, col, tgt, _ in edges:
        style = 'dashed' if tgt.split('.')[0] in ('ref', 'plat') and kind_of(tables[tgt]) in ('global', 'noapp') else 'solid'
        lines.append(f'  {ident(src)}:"{escape(col)}":e -> {ident(tgt)} [style={style}];')
    lines.append('}')
    return '\n'.join(lines) + '\n'


def legend_dot():
    rows = ''.join(f'<TR><TD BGCOLOR="{KIND_FILL[k]}" WIDTH="26"> </TD><TD ALIGN="LEFT">{label}</TD></TR>' for k, label in [
        ('tenant', 'مملوك للمشترك (TenantId + مفتاح مركّب)'), ('global', 'عالمي (بلا TenantId، للقراءة فقط لتطبيق المشترك)'),
        ('mixed', 'مختلط (صفوف المنصة TenantId=NULL + صفوف المشترك)'), ('noapp', 'محجوب عن تطبيق المشترك (noapp)'), ('stub', 'جدول خارج هذه الصورة (مرجع)')])
    return ('digraph G { graph [fontname="%s", fontsize=12, label=<<B>مفتاح الألوان</B>>, labelloc=t, pad=0.2];\n  node [shape=plaintext, fontname="%s", fontsize=10];\n'
            '  L [label=<<TABLE BORDER="1" CELLBORDER="0" CELLSPACING="0" CELLPADDING="4">%s</TABLE>>];\n}\n') % (FONT, FONT, rows)


def render(name, dot_text):
    os.makedirs(SRC, exist_ok=True)
    src = os.path.join(SRC, name + '.dot')
    open(src, 'w', encoding='utf-8').write(dot_text)
    png = os.path.join(OUT, name + '.png')
    subprocess.run(['dot', '-Tpng', '-Gdpi=130', src, '-o', png], check=True)
    return png


def main():
    tables, errs, _ = dbgen.load(sorted(glob.glob(os.path.join(ROOT, 'db', 'model', '*.model'))), False)
    if errs: raise SystemExit('model errors: ' + '; '.join(errs[:3]))
    fqs = {t.fq for t in tables.values()}
    made = []
    made.append(render('erd_00_core_tenancy', build_dot('core', 'العلاقات الأساسية: المشترك والمستخدمون والصلاحيات والمفاتيح',
                       tables, [c for c in CORE if c in fqs], 'كل جدول مملوك للمشترك يشير إلى plat.Tenant عبر TenantId (غير مرسوم)')))
    made.append(render('erd_00_legend', legend_dot()))
    for name, title, schemas in GROUPS:
        members = sorted(t.fq for t in tables.values() if t.schema in schemas)
        made.append(render('erd_' + name, build_dot(name, title, tables, members,
                    f'{len(members)} جدولًا · الأسهم = مفاتيح أجنبية فعلية · الجداول الرمادية خارج الوحدة')))
    print('rendered', len(made), 'diagrams ->', OUT)


if __name__ == '__main__':
    main()
