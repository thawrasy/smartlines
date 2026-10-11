#!/usr/bin/env python3
"""erd.py — يرسم مخططات قاعدة البيانات من النموذج نفسه (المفاتيح الأجنبية الفعلية)، فلا تنحرف عن البناء.

الإخراج: docs/diagrams/src/*.dot (المصدر) و docs/diagrams/*.png (يتطلب Graphviz `dot`).
الألوان: أزرق = مملوك للمشترك · برتقالي = عالمي · بنفسجي = مختلط · أحمر = محجوب عن تطبيق المشترك (noapp) · رمادي = جدول خارج الصورة.
الأسهم = مفاتيح أجنبية فعلية، وتُكتب على السهم اسم العمود. كل جدول مملوك يحمل TenantId ويشير إلى plat.Tenant:
الصورة الأساسية ترسم ذلك صراحة، والصور الأخرى تذكره في العنوان.
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
FILL = {'tenant': '#DCEBFA', 'global': '#FDE9D9', 'mixed': '#EADCF8', 'noapp': '#F8D7DA', 'stub': '#EEEEEE', 'hub': '#FFF3B0'}

# (اسم الصورة، العنوان، المحتوى: مخطط كامل أو جداول محددة)
GROUPS = [
    ('m0_identity', 'م0 · الهوية والمشترك والصلاحيات', ['plat', 'sec']),
    ('m0_platform', 'م0 · التدقيق والمستندات والإعدادات', ['aud', 'doc', 'cfg']),
    ('m1_org', 'م1 · الهيكل المؤسسي والأشخاص', ['org', 'pty']),
    ('m2_3_accounts', 'م2–م3 · المنشآت والحسابات والمفوّضون', ['ins', 'acc']),
    ('m4_catalogs', 'م4 · الكتالوجات', ['cat']),
    ('m5_facilities', 'م5 · التسهيلات والحدود', ['fac']),
    ('m5_pricing', 'م5 · التسعير والتعرفة وشروط المقارنة', ['prc', 'cmp']),
    ('m5_collateral', 'م5 · الضمانات', ['col']),
    ('m5_obligations', 'م5 · الالتزامات والبيانات المالية', ['obl', 'fin']),
    ('m6_workflow', 'م6 · محرك الطلبات ودورات العمل', ['wfl']),
    ('m6_notifications', 'م6 · الإشعارات', ['ntf']),
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
    return list(t.pk_cols) if t.pk_cols else [f'{t.name}Id']


def node_html(t, kind):
    pk = pk_of(t)
    rows = [f'<TR><TD BGCOLOR="{FILL[kind]}" ALIGN="LEFT" COLSPAN="2"><B>{escape(t.fq)}</B></TD></TR>']
    shown = set()
    for p in pk:
        rows.append(f'<TR><TD ALIGN="LEFT">PK</TD><TD ALIGN="LEFT">{escape(p)}</TD></TR>'); shown.add(p)
    for c in [c for c in t.cols if c.fk and c.name not in shown]:
        rows.append(f'<TR><TD ALIGN="LEFT">FK</TD><TD ALIGN="LEFT">{escape(c.name)} → {escape(c.fk)}</TD></TR>'); shown.add(c.name)
    others = len([c for c in t.cols if c.name not in shown])
    if others:
        rows.append(f'<TR><TD ALIGN="LEFT" COLSPAN="2"><FONT COLOR="#666666">+ {others} عمودًا آخر</FONT></TD></TR>')
    return '<<TABLE BORDER="1" CELLBORDER="0" CELLSPACING="0" CELLPADDING="3" COLOR="#7A8794">' + ''.join(rows) + '</TABLE>>'


def stub_html(fq):
    return f'<<TABLE BORDER="1" CELLBORDER="0" CELLSPACING="0" CELLPADDING="4" COLOR="#9AA3AD"><TR><TD BGCOLOR="{FILL["stub"]}"><FONT COLOR="#444444">{escape(fq)}</FONT></TD></TR></TABLE>>'


def q(s): return '"' + s.replace('"', '\\"') + '"'


def header(title, note):
    return [f'digraph G {{',
            f'  graph [fontname="{FONT}", fontsize=18, label=<<B>{escape(title)}</B><BR/><FONT POINT-SIZE="11">{escape(note)}</FONT>>, labelloc=t, rankdir=LR, nodesep=0.4, ranksep=1.2, pad=0.3, bgcolor="white", splines=true];',
            f'  node [shape=plaintext, fontname="{FONT}", fontsize=10];',
            f'  edge [fontname="{FONT}", fontsize=9, color="#5B6B7A", arrowsize=0.7];']


def build_module(title, note, tables, members):
    lines = header(title, note)
    stubs, edges = set(), []
    for fq in members:
        for c in tables[fq].cols:
            if c.fk:
                if c.fk not in members: stubs.add(c.fk)
                edges.append((fq, c.fk, c.name))
    for fq in members:
        lines.append(f'  {q(fq)} [label={node_html(tables[fq], kind_of(tables[fq]))}];')
    for s_ in sorted(stubs):
        lines.append(f'  {q(s_)} [label={stub_html(s_)}];')
    for src, tgt, col in sorted(set(edges)):
        style = 'dashed' if tgt in stubs and kind_of(tables[tgt]) in ('global', 'noapp') else 'solid'
        lines.append(f'  {q(src)} -> {q(tgt)} [label={q(col)}, style={style}];')
    return '\n'.join(lines + ['}']) + '\n'


def build_core(tables, members):
    """الجداول المملوكة للمشترك في عنقود واحد يشير بسهم واحد إلى plat.Tenant، بدل سهم متقطع لكل جدول."""
    lines = header('العلاقات الأساسية: المشترك والمستخدمون والصلاحيات والمفاتيح',
                   'الأسهم المتصلة = مفاتيح أجنبية فعلية · العنقود الأزرق = الجداول المملوكة للمشترك، كلها تحمل TenantId وتشير إلى plat.Tenant')
    lines[0] = 'digraph G {\n  compound=true;'
    owned = [fq for fq in members if fq != 'plat.Tenant' and kind_of(tables[fq]) in ('tenant', 'mixed')]
    others = [fq for fq in members if fq not in owned]
    stubs, edges = set(), []
    for fq in members:
        for c in tables[fq].cols:
            if c.fk:
                if c.fk not in members: stubs.add(c.fk)
                edges.append((fq, c.fk, c.name))
    lines.append('  subgraph cluster_owned {')
    lines.append('    label=<<B>الجداول المملوكة للمشترك</B><BR/><FONT POINT-SIZE="10">كل جدول فيها: TenantId → plat.Tenant</FONT>>; style="rounded,filled"; fillcolor="#F4F8FD"; color="#2B5C8A"; fontname="%s";' % FONT)
    for fq in owned:
        lines.append(f'    {q(fq)} [label={node_html(tables[fq], kind_of(tables[fq]))}];')
    lines.append('  }')
    for fq in others:
        lines.append(f'  {q(fq)} [label={node_html(tables[fq], "hub" if fq == "plat.Tenant" else kind_of(tables[fq]))}];')
    for s_ in sorted(stubs):
        lines.append(f'  {q(s_)} [label={stub_html(s_)}];')
    for src, tgt, col in sorted(set(edges)):
        style = 'dashed' if tgt in stubs and kind_of(tables[tgt]) in ('global', 'noapp') else 'solid'
        lines.append(f'  {q(src)} -> {q(tgt)} [label={q(col)}, style={style}];')
    if 'plat.Tenant' in members and owned:
        lines.append(f'  {q(owned[0])} -> {q("plat.Tenant")} [ltail=cluster_owned, label="TenantId\\n(كل جدول في العنقود)", style=bold, color="#B8860B", fontcolor="#8A6D00", penwidth=2];')
    return '\n'.join(lines + ['}']) + '\n'


def build_isolation():
    return '\n'.join([
        'digraph G {',
        f'  graph [fontname="{FONT}", fontsize=18, label=<<B>عزل المشتركين: مثال بمشترك A ومشترك B</B><BR/><FONT POINT-SIZE="11">المفتاح المركّب (TenantId, …) يمنع أي سهم بين المشتركين، والجداول العامة مشتركة للقراءة فقط</FONT>>, labelloc=t, rankdir=LR, nodesep=0.5, ranksep=1.0, pad=0.3, bgcolor="white"];',
        f'  node [shape=box, style="rounded,filled", fontname="{FONT}", fontsize=11, fillcolor="#DCEBFA", color="#5B7DA8"];',
        f'  edge [fontname="{FONT}", fontsize=10, color="#5B6B7A"];',
        '  subgraph cluster_A { label="المشترك A (TenantId = 1)"; style="rounded,filled"; fillcolor="#F4F8FD"; color="#2B5C8A"; fontname="%s";' % FONT,
        '    A_user [label="sec.AppUser\\nTenantId=1"]; A_co [label="org.Company\\nTenantId=1"]; A_fac [label="fac.Facility\\nTenantId=1"]; }',
        '  subgraph cluster_B { label="المشترك B (TenantId = 2)"; style="rounded,filled"; fillcolor="#FDF6F4"; color="#A0522D"; fontname="%s";' % FONT,
        '    B_user [label="sec.AppUser\\nTenantId=2"]; B_co [label="org.Company\\nTenantId=2"]; B_fac [label="fac.Facility\\nTenantId=2"]; }',
        '  G_cur [label="ref.Currency\\n(عام، للقراءة فقط)", shape=box, style="rounded,filled", fillcolor="#FDE9D9", color="#B8860B"];',
        '  A_fac -> A_co [label="(TenantId, CompanyId)"]; A_co -> A_user [label="(TenantId, CreatedBy)"];',
        '  B_fac -> B_co [label="(TenantId, CompanyId)"]; B_co -> B_user [label="(TenantId, CreatedBy)"];',
        '  A_fac -> G_cur [style=dashed, label="FK عام"]; B_fac -> G_cur [style=dashed];',
        '  A_fac -> B_co [label="مرفوض: لا يصحّ المفتاح المركّب", color="#C0392B", fontcolor="#C0392B", style=dashed, constraint=false];',
        '  A_user -> B_user [label="مرفوض", color="#C0392B", fontcolor="#C0392B", style=dashed, constraint=false];',
        '}', ''])


def build_access():
    return '\n'.join([
        'digraph G {',
        f'  graph [fontname="{FONT}", fontsize=18, label=<<B>صلاحيات الأدوار على الجداول</B><BR/><FONT POINT-SIZE="11">المنح صريحة لكل جدول ومولَّدة (007)؛ لا منح على مستوى المخطط</FONT>>, labelloc=t, rankdir=LR, nodesep=0.4, ranksep=1.6, pad=0.3, bgcolor="white"];',
        f'  node [fontname="{FONT}", fontsize=11];',
        f'  edge [fontname="{FONT}", fontsize=9, color="#5B6B7A"];',
        '  subgraph cluster_roles { label="الأدوار"; style=rounded; color="#999999"; fontname="%s";' % FONT,
        '    app [shape=box, style="rounded,filled", fillcolor="#DCEBFA", label="tp_app\\nتطبيق المشترك"];',
        '    plat [shape=box, style="rounded,filled", fillcolor="#FDE9D9", label="tp_platform\\nمشغّلو المنصة"];',
        '    auth [shape=box, style="rounded,filled", fillcolor="#EADCF8", label="tp_auth\\nداخلي (إجراء الجلسة فقط)"];',
        '    ro [shape=box, style="rounded,filled", fillcolor="#E8F5E9", label="tp_readonly\\nتقارير"];',
        '    mig [shape=box, style="rounded,filled", fillcolor="#EEEEEE", label="tp_migrator\\nالنشر"]; }',
        '  subgraph cluster_res { label="أنواع الجداول"; style=rounded; color="#999999"; fontname="%s";' % FONT,
        '    tenant [shape=box, style=filled, fillcolor="#DCEBFA", label="جداول المشترك\\n(TenantId + RLS)"];',
        '    glob [shape=box, style=filled, fillcolor="#FDE9D9", label="جداول عامة\\n(ref · sec.Permission · cfg.SettingDefinition)"];',
        '    mixed [shape=box, style=filled, fillcolor="#EADCF8", label="جداول مختلطة\\n(aud.AuditLog · cfg.NonWorkingDay · ref.UcpArticle)"];',
        '    noapp [shape=box, style=filled, fillcolor="#F8D7DA", label="plat.Tenant · PlatformOperator\\nReservedSubdomain · TenantModule\\n(noapp)"]; }',
        '  app -> tenant [label="SELECT, INSERT, UPDATE"];',
        '  app -> glob [label="SELECT فقط"];',
        '  app -> mixed [label="SELECT, INSERT, UPDATE\\n(RLS يقصر الكتابة)"];',
        '  app -> noapp [label="لا منح", style=dashed, color="#C0392B", fontcolor="#C0392B"];',
        '  plat -> tenant [label="لا وصول مباشر", style=dashed, color="#C0392B", fontcolor="#C0392B"];',
        '  plat -> glob [label="SELECT, INSERT, UPDATE"];',
        '  plat -> mixed [label="SELECT, INSERT, UPDATE"];',
        '  plat -> noapp [label="SELECT, INSERT, UPDATE"];',
        '  auth -> noapp [label="sec.AppUser و plat.Tenant\\nفحص الجلسة فقط", style=dotted];',
        '  ro -> tenant [label="SELECT (دون الأعمدة الحساسة)"];',
        '  ro -> glob [label="SELECT"];',
        '}', ''])


def build_lifecycle():
    return '\n'.join([
        'digraph G {',
        f'  graph [fontname="{FONT}", fontsize=18, label=<<B>دورة حياة الطلب: إقفال دورة العمل بيد إدارة الخزينة</B><BR/><FONT POINT-SIZE="11">الإكمال لا يحدث إلا بعد الإقفال (BR-WFL-027)</FONT>>, labelloc=t, rankdir=LR, nodesep=0.5, ranksep=0.9, pad=0.3, bgcolor="white"];',
        f'  node [shape=box, style="rounded,filled", fontname="{FONT}", fontsize=11, fillcolor="#FFFFFF", color="#5B6B7A"];',
        f'  edge [fontname="{FONT}", fontsize=9, color="#5B6B7A"];',
        '  DRAFT [label="DRAFT\\nمسودة"];',
        '  ACTIVE [label="ACTIVE\\nقيد المعالجة"];',
        '  AWAITING [label="AWAITING_CLOSE\\nانتهت المراحل بنجاح\\nتنتظر إقفال الخزينة", fillcolor="#FFF3B0", color="#B8860B", penwidth=2];',
        '  COMPLETED [label="COMPLETED\\nمكتمل (بعد الإقفال)", fillcolor="#E8F5E9", color="#2E7D32", penwidth=2];',
        '  REJECTED [label="REJECTED\\nمرفوض", fillcolor="#F8D7DA", color="#C0392B"];',
        '  CANCELLED [label="CANCELLED\\nملغى", fillcolor="#EEEEEE"];',
        '  DRAFT -> ACTIVE [label="تقديم"];',
        '  DRAFT -> CANCELLED [label="إلغاء المسودة"];',
        '  ACTIVE -> ACTIVE [label="موافقة · إرجاع · إعادة تقديم"];',
        '  ACTIVE -> AWAITING [label="انتهاء المرحلة الأخيرة بنجاح\\n(ReadyToCloseAt)"];',
        '  AWAITING -> COMPLETED [label="إقفال من مدير الخزينة\\n(req.treasury.close · ClosedByUserId · ClosedAt)", penwidth=2];',
        '  ACTIVE -> REJECTED [label="رفض"];',
        '  ACTIVE -> CANCELLED [label="إلغاء"];',
        '}', ''])


def render(name, dot_text):
    os.makedirs(SRC, exist_ok=True)
    src = os.path.join(SRC, name + '.dot')
    open(src, 'w', encoding='utf-8').write(dot_text)
    png = os.path.join(OUT, name + '.png')
    subprocess.run(['dot', '-Tpng', '-Gdpi=110', src, '-o', png], check=True)
    # صور المخططات ذات ألوان قليلة: تحويل إلى لوحة 256 لونًا يصغّر الملف كثيرًا دون فقد ظاهر
    from PIL import Image
    im = Image.open(png).convert('RGB').quantize(colors=256, method=Image.Quantize.MEDIANCUT)
    im.save(png, optimize=True)
    return png


def main():
    tables, errs, _ = dbgen.load(sorted(glob.glob(os.path.join(ROOT, 'db', 'model', '*.model'))), False)
    if errs: raise SystemExit('model errors: ' + '; '.join(errs[:3]))
    fqs = {t.fq for t in tables.values()}
    made = [render('erd_00_core_tenancy', build_core(tables, [c for c in CORE if c in fqs])),
            render('erd_01_isolation', build_isolation()),
            render('erd_02_access_roles', build_access()),
            render('erd_03_request_lifecycle', build_lifecycle())]
    for name, title, schemas in GROUPS:
        members = sorted(t.fq for t in tables.values() if t.schema in schemas)
        made.append(render('erd_' + name, build_module(title, f'{len(members)} جدولًا · كل جدول مملوك للمشترك يحمل TenantId · الرمادي = خارج الصورة',
                                                       tables, members)))
    print('rendered', len(made), 'diagrams ->', OUT)


if __name__ == '__main__':
    main()
