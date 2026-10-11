#!/usr/bin/env python3
"""erd_pro.py — مخططات ERD احترافية (تدوين Crow's Foot) تُولَّد من نموذج قاعدة البيانات نفسه.

- كل جدول: رأس بالمخطط والاسم، ثم المفتاح الأساسي (PK) والمفاتيح الأجنبية (FK) والفريد (UQ) وأعمدة إلزامية مختارة، مع عدد الباقي.
- كل علاقة: الطرف الأب بشرطة (واحد) والطرف الابن بقدم الغراب (كثير)، ودائرة إن كان الارتباط اختياريًا.
- الجداول خارج المجموعة تُرسم صناديق متقطعة بالاسم الكامل (مخطط.جدول).
- الألوان: الجداول داخل الصورة بخلفية ذهبية فاتحة، والجداول المرجعية خارجها بلا تعبئة.

المخرجات: docs/diagrams/pro/*.png ومصادرها docs/diagrams/pro/src/*.dot
"""
import os, subprocess, sys
from html import escape

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dbgen

ROOT = os.path.join(HERE, '..', '..')
OUT = os.path.join(ROOT, 'docs', 'diagrams', 'pro')
SRC = os.path.join(OUT, 'src')
FONT = 'DejaVu Sans'
HEAD = '#FFF4C7'
MAX_ROWS = 12


def is_owned(t):
    return not t.is_global and not t.is_mixed and 'noapp' not in t.flags


def pk_of(t):
    return list(t.pk_cols) if t.pk_cols else [f'{t.name}Id']


def key_info(t):
    pk = list(t.pk_cols) if t.pk_cols else [f'{t.name}Id']
    fk = {c.name for c in t.cols if c.fk}
    uq = set()
    for u in t.uniques:              # [cols, include, where_expr, where]
        cols, where = u[0], u[-1]
        if len(cols) == 1 and not where: uq.add(cols[0])
    return pk, fk, uq


def col_type(c, tables):
    if isinstance(c, _SurrogateCol): return c.sqltype
    if c.fk:
        return dbgen.pk_sqltype(tables[c.fk])[0] if c.fk in tables else ''
    try:
        return dbgen.coltype_sql(c, 'tsql') or ''
    except Exception:
        return c.sqltype or ''


class _SurrogateCol:
    """المفتاح الاصطناعي <Table>Id لا يُخزَّن في t.cols، فيُعرض بنوعه الفعلي."""
    def __init__(self, name, sqltype):
        self.name = name; self.fk = None; self.req = True; self.auto = True; self.sqltype = sqltype
    def __getattr__(self, k):
        return None


def table_label(t, tables):
    schema, name = t.schema, t.name
    pk, fk, uq = key_info(t)
    cols = {c.name: c for c in t.cols}
    shown = []
    for n in pk:
        if n in cols: shown.append(('PK', cols[n]))
        else: shown.append(('PK', _SurrogateCol(n, dbgen.pk_sqltype(t)[0])))
    for c in t.cols:
        if c.fk and c.name not in pk: shown.append(('FK', c))
    for c in t.cols:
        if c.name in uq and c.name not in pk and not c.fk: shown.append(('UQ', c))
    nonkey = [c for c in t.cols if c.name not in pk and not c.fk and c.name not in uq and not c.auto]
    for c in [c for c in nonkey if c.req][:3] + [c for c in nonkey if not c.req][:1]:
        if len(shown) < MAX_ROWS: shown.append(('', c))
    rows = [f'<TR><TD COLSPAN="3" BGCOLOR="{HEAD}" ALIGN="LEFT"><FONT POINT-SIZE="7" COLOR="#7A6A2E">{escape(schema)}</FONT><BR ALIGN="LEFT"/><FONT POINT-SIZE="11"><B>{escape(name)}</B></FONT></TD></TR>',
            ]
    for kind, c in shown:
        tag = {'PK': '<FONT COLOR="#1D4E89"><B>PK</B></FONT>', 'FK': '<FONT COLOR="#B45309"><B>FK</B></FONT>',
               'UQ': '<FONT COLOR="#0F766E"><B>UQ</B></FONT>', '': ''}[kind]
        bold = '<B>%s</B>' % escape(c.name) if kind in ('PK', 'FK', 'UQ') else escape(c.name)
        port = f' PORT="{escape(c.name)}"' if kind in ('PK', 'FK', 'UQ') else ''
        rows.append(f'<TR><TD ALIGN="LEFT"{port}>{tag}</TD><TD ALIGN="LEFT"{port}>{bold}</TD><TD ALIGN="RIGHT"{port}><FONT COLOR="#6B7280" POINT-SIZE="8">{escape(col_type(c, tables))}</FONT></TD></TR>')
    more = len(t.cols) - len(shown)
    if more > 0:
        rows.append(f'<TR><TD COLSPAN="3" ALIGN="LEFT"><FONT POINT-SIZE="8" COLOR="#6B7280"><I>+ {more} more columns</I></FONT></TD></TR>')
    return ('<<TABLE BORDER="1" COLOR="#8A7A3A" CELLBORDER="0" CELLSPACING="0" CELLPADDING="3" STYLE="rounded" BGCOLOR="white">'
            + ''.join(rows) + '</TABLE>>')


def external_label(fq):
    return fq


def q(s): return '"' + s.replace('"', '\\"') + '"'


def edges_for(members, tables):
    out, stubs = [], set()
    for fq in members:
        for c in tables[fq].cols:
            if c.fk:
                if c.fk not in members: stubs.add(c.fk)
                out.append((c.fk, fq, c.name, c.req))     # parent -> child
    return out, stubs


def dot_document(title, subtitle, nodes, edge_lines, ortho=False):
    head = ['digraph G {',
            f'  graph [fontname="{FONT}", label=<<B><FONT POINT-SIZE="16">{escape(title)}</FONT></B><BR/><FONT POINT-SIZE="10" COLOR="#4B5563">{escape(subtitle)}</FONT>>, labelloc=t, rankdir=LR, splines={"ortho" if ortho else "spline"}, nodesep=0.45, ranksep=1.7, pad=0.35, bgcolor="white", dpi=110];',
            f'  node [fontname="{FONT}", fontsize=10];',
            f'  edge [fontname="{FONT}", fontsize=8, color="#374151", arrowsize=0.75];']
    return '\n'.join(head + nodes + edge_lines + ['}']) + '\n'


def layer_of(members, tables):
    """طبقات منظّمة: الجدول الأب في عمود يسار ابنه. الطبقة = أطول سلسلة مفاتيح داخل المجموعة."""
    internal = set(members)
    depth = {fq: 0 for fq in members}
    for _ in range(len(members)):            # تكرار كافٍ لانتشار الأطوال في أي مخطط غير دوري
        changed = False
        for fq in members:
            for c in tables[fq].cols:
                if c.fk in internal and c.fk != fq and depth[c.fk] + 1 > depth[fq]:
                    depth[fq] = depth[c.fk] + 1; changed = True
        if not changed: break
    return depth


def render_group(name, title, subtitle, members, tables):
    """تخطيط منظّم: الأعمدة = طبقات الاعتماد (الأب يسارًا)، الأسهم متعامدة تربط صفّ المفتاح بصفّ المفتاح، بلا تسميات متزاحمة."""
    internal = set(members)
    depth = layer_of(members, tables)
    nodes = []
    stub_list = sorted({c.fk for fq in members for c in tables[fq].cols if c.fk and c.fk not in internal})
    for fq in members:
        nodes.append(f'  {q(fq)} [shape=plain, label={table_label(tables[fq], tables)}];')
    for fq in stub_list:
        nodes.append(f'  {q(fq)} [shape=box, style="rounded,dashed", color="#6B7280", fontcolor="#374151", margin="0.12,0.05", label={q(fq)}];')
    # الأعمدة: المراجع الخارجية أقصى اليسار، ثم الطبقات الداخلية بالترتيب
    levels = {}
    for fq in members: levels.setdefault(depth[fq], []).append(fq)
    rank_lines = []
    lines = []
    for fq in members:
        t = tables[fq]
        for c in t.cols:
            if not c.fk: continue
            parent = c.fk
            if parent == fq:          # مرجع ذاتي: يظهر في صفّ الجدول (FK → نفسه)، ولا يُرسم حلقة متعامدة
                continue
            if parent in internal:
                ppk = pk_of(tables[parent])[0]
                tail = f'{q(parent)}:{q(ppk)}:e'
                external = False
            else:
                tail = q(parent)
                external = True
            arrow = 'crow' if c.req else 'crowodot'
            style = 'dashed' if external else 'solid'
            color = '#9CA3AF' if external else '#374151'
            lines.append(f'  {tail} -> {q(fq)}:{q(c.name)}:w [dir=both, arrowtail=tee, arrowhead={arrow}, style={style}, color="{color}", arrowsize=0.7];')
    # الصفوف المتعامدة تحتاج منافذ فعلية في الصفوف المرئية فقط؛ المفاتيح الأجنبية الظاهرة تُدرج في الجدول
    return dot_document(title, subtitle, nodes + rank_lines, lines, ortho=True)


CORE_TENANCY = ['plat.Tenant', 'plat.Plan', 'plat.TenantModule', 'plat.SupportAccessGrant', 'plat.PlatformOperator',
                'sec.TenantKey', 'sec.AppUser', 'sec.Role', 'sec.Permission', 'sec.RolePermission', 'sec.UserRole',
                'sec.UserCompanyScope', 'sec.UserSession', 'org.Company', 'org.Department', 'aud.AuditLog', 'ref.Country']


def render_schema_map(tables):
    schemas = {}
    for t in tables.values(): schemas.setdefault(t.schema, []).append(t)
    cnt = {}
    for t in tables.values():
        for c in t.cols:
            if c.fk:
                a, b = t.schema, c.fk.split('.')[0]
                if a != b: cnt[(b, a)] = cnt.get((b, a), 0) + 1
    nodes = []
    for s, ts in sorted(schemas.items()):
        glob_ = all(not is_owned(t) for t in ts)
        fill = '#E5E7EB' if glob_ else HEAD
        nodes.append(f'  {q(s)} [shape=box, style="rounded,filled", fillcolor="{fill}", color="#8A7A3A", label={q(f"{s}\\n{len(ts)} جدولًا")}];')
    lines = []
    for (p, c), n in sorted(cnt.items()):
        lines.append(f'  {q(p)} -> {q(c)} [dir=both, arrowtail=tee, arrowhead=crow, label="{n} FK"];')
    return dot_document('خريطة المخططات (Schema Map)', 'كل مخطط كصندوق · الأسهم = مفاتيح أجنبية بين المخططات مع عددها', nodes, lines)


def render_legend():
    nodes = [
        '  parent [shape=plain, label=<<TABLE BORDER="1" COLOR="#8A7A3A" CELLBORDER="0" CELLSPACING="0" CELLPADDING="3" BGCOLOR="white"><TR><TD COLSPAN="3" BGCOLOR="#FFF4C7" ALIGN="LEFT"><FONT POINT-SIZE="7" COLOR="#7A6A2E">schema</FONT><BR ALIGN="LEFT"/><FONT POINT-SIZE="11"><B>parent_table</B></FONT></TD></TR><TR><TD ALIGN="LEFT"><FONT COLOR="#1D4E89"><B>PK</B></FONT></TD><TD ALIGN="LEFT"><B>ParentId</B></TD><TD ALIGN="RIGHT"><FONT COLOR="#6B7280" POINT-SIZE="8">bigint</FONT></TD></TR></TABLE>>];',
        '  child [shape=plain, label=<<TABLE BORDER="1" COLOR="#8A7A3A" CELLBORDER="0" CELLSPACING="0" CELLPADDING="3" BGCOLOR="white"><TR><TD COLSPAN="3" BGCOLOR="#FFF4C7" ALIGN="LEFT"><FONT POINT-SIZE="7" COLOR="#7A6A2E">schema</FONT><BR ALIGN="LEFT"/><FONT POINT-SIZE="11"><B>child_table</B></FONT></TD></TR><TR><TD ALIGN="LEFT"><FONT COLOR="#1D4E89"><B>PK</B></FONT></TD><TD ALIGN="LEFT"><B>ChildId</B></TD><TD ALIGN="RIGHT"><FONT COLOR="#6B7280" POINT-SIZE="8">bigint</FONT></TD></TR><TR><TD ALIGN="LEFT"><FONT COLOR="#B45309"><B>FK</B></FONT></TD><TD ALIGN="LEFT"><B>ParentId</B></TD><TD ALIGN="RIGHT"><FONT COLOR="#6B7280" POINT-SIZE="8">bigint</FONT></TD></TR></TABLE>>];',
        '  opt [shape=plain, label=<<TABLE BORDER="1" COLOR="#8A7A3A" CELLBORDER="0" CELLSPACING="0" CELLPADDING="3" BGCOLOR="white"><TR><TD BGCOLOR="#FFF4C7" ALIGN="LEFT"><FONT POINT-SIZE="11"><B>mandatory vs optional</B></FONT></TD></TR></TABLE>>];',
        '  stub [shape=box, style="rounded,dashed", color="#6B7280", fontcolor="#374151", label="ref.Country (خارج الصورة)"];',
    ]
    lines = ['  parent -> child [dir=both, arrowtail=tee, arrowhead=crow, label="إلزامي: 1 ← N"];',
             '  parent -> opt [dir=both, arrowtail=tee, arrowhead=crowodot, label="اختياري: 1 ← 0..N"];',
             '  parent -> stub [dir=both, arrowtail=tee, arrowhead=crow, style=dashed, color="#9CA3AF", label="مرجع خارجي"];']
    return dot_document('مفتاح الرسم', 'PK مفتاح أساسي · FK مفتاح أجنبي · UQ فريد · الشرطة = طرف الواحد · قدم الغراب = طرف الكثير · الدائرة = اختياري',
                        nodes, lines)


def groups_plan():
    S = lambda *names: [f'{n}' for n in names]
    return [
        ('m0_tenancy', 'م0 · المشترك والاشتراكات والمشغّلون', 'Tenancy & platform operators', ['plat']),
        ('m0_identity', 'م0 · الهوية والصلاحيات', 'Identity & authorisation', ['sec.AppUser', 'sec.Role', 'sec.Permission', 'sec.RolePermission', 'sec.UserRole', 'sec.UserCompanyScope', 'sec.ExternalIdentity']),
        ('m0_sessions', 'م0 · الجلسات والمفاتيح والمحاولات', 'Sessions, keys & attempts', ['sec.UserSession', 'sec.LoginAttempt', 'sec.MfaRecoveryCode', 'sec.UserToken', 'sec.UserPasswordHistory', 'sec.TenantKey', 'sec.KeyEvent']),
        ('m0_audit_docs', 'م0 · التدقيق والمستندات', 'Audit & documents', ['aud', 'doc']),
        ('m0_config', 'م0 · الإعدادات والمهام الخلفية', 'Configuration & background jobs', ['cfg']),
        ('m1_company', 'م1 · الشركات والحوكمة', 'Company structure & governance', ['org.Company', 'org.CompanyTaxRate', 'org.Department', 'org.Shareholding', 'org.GoverningBody', 'org.BodyMember', 'org.AuthorityGrant']),
        ('m1_company_kyc', 'م1 · ملف الشركة و KYC', 'Company profile & KYC', ['org.CompanyProfile', 'org.CompanyBranch', 'org.CompanyKycFinancialProfile', 'org.CompanyExpectedFlow', 'org.CompanyWealthSource', 'org.CompanyDisclosure', 'org.CompanyKeyRelation']),
        ('m1_party', 'م1 · الأشخاص والهوية و KYC', 'Parties, identity documents & KYC', ['pty']),
        ('m2_3_institutions', 'م2–م3 · الجهات المالية والحسابات والمفوّضون', 'Institutions, bank accounts & signatories', ['ins', 'acc']),
        ('m4_products', 'م4 · المنتجات والرسوم والتمويل والضمانات', 'Products, fees, financing & collateral types', ['cat.ProductCategory', 'cat.Product', 'cat.FeeType', 'cat.FinancingType', 'cat.ProductFeeType', 'cat.ProductFinancingType', 'cat.FacilityType', 'cat.LimitType', 'cat.LimitTypeProduct', 'cat.CollateralType', 'cat.CollateralTypeAttribute', 'cat.ObligationType']),
        ('m4_reference', 'م4 · الكتالوجات المرجعية', 'Reference catalogues', ['cat.TenantCurrency', 'cat.InstitutionType', 'cat.AccountType', 'cat.LegalEntityType', 'cat.DocumentType', 'cat.Position', 'cat.PowerType']),
        ('m4_rates_lookups', 'م4 · الأسعار المرجعية والقوائم', 'Base rates & lookup lists', ['cat.OperationType', 'cat.OperationTypePowerType', 'cat.BaseRate', 'cat.BaseRateAlias', 'cat.BaseRateValue', 'cat.LookupList', 'cat.LookupItem']),
        ('m4_global_ref', 'م4 · المراجع العامة (ref)', 'Global references (shared, read-only)', ['ref']),
        ('m5_facility_core', 'م5 · التسهيلات والمراجعات', 'Facilities & revisions', ['fac.Facility', 'fac.FacilityRevision', 'fac.FacilityDocument', 'fac.FacilityLender', 'fac.OutstandingSnapshot', 'fac.ValueConflict']),
        ('m5_limits', 'م5 · الحدود والاستخدام والحجوزات', 'Limits, utilisation & reservations', ['fac.Limit', 'fac.LimitProductLine', 'fac.LimitCompanyRule', 'fac.ProductLineTerm', 'fac.Utilization', 'fac.LimitReservation', 'fac.LimitMovement']),
        ('m5_pricing', 'م5 · التسعير وشروط المقارنة', 'Pricing, tariffs & comparable terms', ['prc', 'cmp']),
        ('m5_collateral', 'م5 · الضمانات', 'Collateral & guarantees', ['col']),
        ('m5_obligations', 'م5 · الالتزامات والتعهدات', 'Obligations, covenants & reporting', ['obl']),
        ('m5_financials', 'م5 · البيانات المالية والأرصدة', 'Financial statements & balances', ['fin']),
        ('m6_wf_templates', 'م6 · قوالب دورات العمل', 'Workflow templates', ['wfl.RequestType', 'wfl.RequestTypeAudience', 'wfl.ExternalPhase', 'wfl.WorkflowTemplate', 'wfl.WorkflowStage', 'wfl.StageApprover', 'wfl.WorkflowTransition', 'wfl.WorkflowStageHook', 'wfl.TemplateField', 'wfl.TemplateAttachmentRule']),
        ('m6_requests', 'م6 · الطلبات وإجراءاتها', 'Requests, approvals & actions', ['wfl.Request', 'wfl.RequestComment', 'wfl.RequestAttachment', 'wfl.RequestExternalRef', 'wfl.RequestStageInstance', 'wfl.RequestApproval', 'wfl.RequestAction', 'wfl.HookExecution', 'wfl.UserDelegation']),
        ('m6_notifications', 'م6 · الإشعارات', 'Notifications', ['ntf']),
        ('m7_8_lc_terms', 'م7/م8 · شروط الاعتماد والنماذج', 'LC terms, fields & form maps', ['lc.LcFieldDefinition', 'lc.LcFieldUcpRef', 'lc.Counterparty', 'lc.LcDocumentClause', 'lc.LcDocumentClauseUcpRef', 'lc.LcTerms', 'lc.LcTermsDocument', 'lc.LcChargesMatrix', 'lc.LcFormTemplate', 'lc.LcFormFieldMap']),
        ('m7_8_lc_ops', 'م7/م8 · الاعتمادات والبروفورما', 'Letters of credit & proforma', ['lc.LetterOfCredit', 'lc.LcExternalRef', 'lc.LcAmendment', 'lc.LcDrawing', 'lc.LcSalesOrder', 'lc.LcDrawingAllocation', 'lc.LcDiscrepancy', 'lc.ProformaInvoice', 'lc.ProformaLine', 'lc.LcTermsComparison', 'lc.LcTermsComparisonLine']),
    ]


def expand(spec, tables):
    out = []
    for item in spec:
        if item in tables: out.append(item); continue
        out += sorted(t.fq for t in tables.values() if t.schema == item)
    return out


MAX_PER_DIAGRAM = 4   # 4 جداول بحد أقصى لكل صورة: النص يبقى بحجم 7pt فأكثر عند عرضها بعرض صفحة أفقية


def plan_members(tables):
    """يقسّم كل مجموعة إلى صور من حتى MAX_PER_DIAGRAM جدولًا، فتبقى الصورة مقروءة في Word."""
    plan = []
    for key, title, sub, spec in groups_plan():
        members = expand(spec, tables)
        if len(members) <= MAX_PER_DIAGRAM:
            plan.append((key, title, sub, members)); continue
        parts = [members[i:i + MAX_PER_DIAGRAM] for i in range(0, len(members), MAX_PER_DIAGRAM)]
        for i, chunk in enumerate(parts, 1):
            plan.append((f'{key}_{i}', f'{title} ({i}/{len(parts)})', sub, chunk))
    return plan


def main():
    import glob
    tables, errs, _ = dbgen.load(sorted(glob.glob(os.path.join(ROOT, 'db', 'model', '*.model'))), False)
    if errs: raise SystemExit('model errors: ' + '; '.join(errs[:3]))
    plan = plan_members(tables)
    assigned = [fq for _, _, _, m in plan for fq in m]
    missing = set(tables) - set(assigned)
    dup = {x for x in assigned if assigned.count(x) > 1}
    if missing or dup:
        raise SystemExit(f'plan error: missing={sorted(missing)[:5]} duplicated={sorted(dup)[:5]}')
    os.makedirs(SRC, exist_ok=True)
    made = []
    fallbacks = []
    def write_and_render(name, text):
        src = os.path.join(SRC, name + '.dot')
        png = os.path.join(OUT, name + '.png')
        open(src, 'w', encoding='utf-8').write(text)
        try:
            subprocess.run(['dot', '-Tpng', src, '-o', png], check=True, stderr=subprocess.DEVNULL)
        except subprocess.CalledProcessError:
            # التوجيه المتعامد يتعثر أحيانًا مع منافذ الجداول: نعيد الرسم بتوجيه منحنٍ مع الإبقاء على المنافذ
            fallbacks.append(name)
            text2 = text.replace('splines=ortho', 'splines=spline')
            open(src, 'w', encoding='utf-8').write(text2)
            subprocess.run(['dot', '-Tpng', src, '-o', png], check=True, stderr=subprocess.DEVNULL)
        from PIL import Image
        im = Image.open(png).convert('RGB').quantize(colors=256, method=Image.Quantize.MEDIANCUT)
        im.save(png, optimize=True)
        made.append(png)
    write_and_render('schema_map', render_schema_map(tables))
    write_and_render('core_tenancy', render_group('core_tenancy', 'العلاقات الأساسية: المشترك والمستخدمون والصلاحيات',
                     'Core tenancy, identity & authorisation · جداول مملوكة للمشترك وجداول عامة وجداول محجوبة معًا',
                     [t for t in CORE_TENANCY if t in tables], tables))
    write_and_render('legend', render_legend())
    for key, title, sub, members in plan:
        write_and_render(key, render_group(key, title, sub, members, tables))
    print(f'rendered {len(made)} diagrams -> {OUT} ; tables covered={len(assigned)} ; spline fallback={fallbacks}')
    return plan, tables


if __name__ == '__main__':
    main()
