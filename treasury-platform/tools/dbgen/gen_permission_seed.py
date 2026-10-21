#!/usr/bin/env python3
"""gen_permission_seed.py — writes db/seed/102_permissions.sql: the permission catalogue sec.Permission
(DQ-F07-1 and DQ-F09-1, owner decisions of 2026-10-12; FR-PLT-017, BR-PLT-019).

Usage: python3 tools/dbgen/gen_permission_seed.py [out.sql]
Sources:
  - the codes: DOC-F09 section 3.1 (the codes of the role matrices in specs 11 to 14), DOC-F07 section 3 (the M0 and
    M1 codes) and DOC-F09 section 3.2 (four proposed codes), all approved;
  - the Arabic names: the action text of the role-matrix row that names the code alone (specs 10 to 14), and AR below
    where no such row exists or the text needs shortening;
  - the English names, the modules and the locks: EN, module_of and LOCKED below.
Every code found in the documents must have an English name here, and every name here must match a code, so the
catalogue and the documents cannot drift apart silently. The generated file is committed.
"""
import glob, os, re, sys

ROOT = os.path.join(os.path.dirname(__file__), '..', '..')
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'db', 'seed', '102_permissions.sql')
CODE = re.compile(r'`([a-z][a-z_]*(?:\.[a-z_]+)+)`')

EN = {
    'sec.user.manage': 'Manage users', 'sec.role.manage': 'Manage roles and permissions',
    'sec.support.grant': 'Grant temporary support access',
    'cfg.settings.manage': 'Manage tenant settings', 'cfg.numbering.manage': 'Manage numbering series',
    'cfg.alerts.manage': 'Manage alert rules', 'cfg.jobs.view': 'View background job runs',
    'cfg.export.request': 'Request a full tenant data export', 'cfg.retention.approve': 'Approve retention and destruction',
    'audit.view': 'View the audit log', 'audit.view.treasury': 'View treasury audit events',
    'audit.export': 'Export the audit log',
    'org.company.manage': 'Manage companies and their structure', 'org.company.view': 'View companies',
    'org.catalog.manage': 'Manage organisation lists', 'org.ownership.manage': 'Record ownership',
    'org.body.manage': 'Manage governing bodies and members', 'org.grant.create': 'Create authority grants',
    'org.grant.approve': 'Approve authority grants', 'org.document.manage': 'Manage company documents',
    'org.document.view': 'View company documents',
    'party.manage': 'Manage persons and legal entities', 'party.field.manage': 'Manage custom party fields',
    'party.identity.write': 'Enter identity numbers and images', 'party.view': 'View persons (masked)',
    'party.identity.reveal': 'Reveal full identity numbers', 'party.identity.image.view': 'View identity document images',
    'party.pack.export': 'Export the guarantor pack in full', 'party.pack.draft': 'Print the masked guarantor pack draft',
    'party.merge': 'Merge duplicate persons', 'party.kyc.manage': 'Manage KYC profiles',
    'party.export': 'Export party lists', 'party.export.sensitive': 'Export restricted party columns',
    'ins.view': 'View institutions, contacts and relationships', 'ins.manage': 'Manage institutions and their units',
    'ins.contacts.manage': 'Manage institution contacts', 'ins.relationship.manage': 'Manage bank relationships',
    'ins.wizard.run': 'Run the bank set-up wizard', 'ins.deactivate': 'Deactivate an institution or close a relationship',
    'ins.export': 'Print the escalation sheet',
    'acc.view': 'View bank accounts', 'acc.reveal': 'Reveal full account numbers and IBANs',
    'acc.manage': 'Manage bank accounts', 'acc.close': 'Freeze or close a bank account',
    'acc.facility_link': 'Link accounts to facilities', 'acc.signature.image.view': 'View specimen signature images',
    'sig.view': 'View signatories and their powers', 'sig.manage': 'Manage signatories and their powers',
    'sig.conflict.review': 'Review governance conflicts',
    'cat.view': 'Read catalogues', 'cat.manage.general': 'Manage general catalogues',
    'cat.manage.financial': 'Manage financial catalogues', 'cat.baserate.enter': 'Enter base rate values',
    'cat.global.manage': 'Manage global references and seed packs',
    'fac.view': 'View facilities, limits, terms and utilisation', 'fac.edit': 'Prepare facility revisions',
    'fac.approve': 'Approve or reject facility revisions', 'fac.conflict.resolve': 'Resolve value conflicts',
    'fac.util.manage': 'Enter manual utilisation and recognised balances', 'fac.reserve': 'Reserve limits',
    'fac.override_limit': 'Override availability with a recorded reason', 'fac.lifecycle.manage': 'Resolve facility validity and end a facility',
    'fac.lifecycle.suspend': 'Suspend a facility and lift the suspension',
    'prc.view': 'View pricing and tariffs', 'prc.manage': 'Manage pricing and tariffs', 'prc.tariff.approve': 'Approve tariffs',
    'col.view': 'View collateral and guarantees', 'col.manage': 'Manage collateral and guarantees',
    'col.approve': 'Approve collateral changes',
    'cmp.view': 'View comparable terms', 'cmp.manage': 'Manage comparable terms', 'cmp.term.propose': 'Propose a new term key',
    'obl.view': 'View obligations and the compliance calendar', 'obl.manage': 'Manage obligations and covenants',
    'obl.record': 'Record reports, notices and covenant reviews', 'obl.breach.manage': 'Manage breaches',
    'obl.waiver.approve': 'Approve waivers',
    'fin.view': 'View financial statements and results', 'fin.stmt.enter': 'Enter financial statements',
    'fin.stmt.approve': 'Approve financial statements', 'fin.stats.enter': 'Enter monthly balances and transfers', 'fin.stats.confirm': 'Confirm monthly balances and bank flows', 'fin.credit.assess': 'Prepare and compute credit assessments', 'fin.credit.approve': 'Approve credit assessments', 'fin.credit.endorse': 'Endorse approved credit assessments for use outside the company', 'fin.period.lock': 'Close and reopen the reporting periods of a company',
    'fin.formula.manage': 'Manage covenant formulas', 'fin.formula.approve': 'Approve covenant formulas',
    'fin.verify.run': 'Run verification and re-evaluation',
    'req.create': 'Create requests', 'req.create.child': 'Create child requests', 'req.view.own': 'View my requests',
    'req.view.department': "View my department's requests", 'req.view.all': 'View all requests in scope',
    'req.view.internal': 'View internal stages and comments', 'req.comment': 'Comment visibly to the requester',
    'req.comment.internal': 'Comment internally', 'req.approve': 'Approve, return or reject as assignee',
    'req.treasury.approve': 'Approve as treasury manager at the reservation point',
    'req.treasury.close': 'Close a request for the treasury', 'req.facility.select': 'Select the facility, limit and product line',
    'req.claim': 'Claim requests from the queue', 'req.execute': 'Record execution and issuance',
    'req.reassign': 'Reassign or return requests to the queue', 'req.cancel': 'Cancel my requests',
    'req.cancel.any': 'Cancel any request in scope', 'req.export': 'Export request lists and timelines',
    'req.extref.edit': 'Enter and correct external references', 'req.dashboard.manager': 'Use the manager dashboards',
    'req.delegate.own': 'Delegate my tasks', 'req.delegate.manage': "Manage others' delegations",
    'req.type.manage': 'Manage request types',
    'wfl.template.view': 'View request types and templates', 'wfl.template.manage': 'Edit draft templates',
    'wfl.template.publish': 'Publish templates', 'wfl.request.migrate': 'Move a running request to a newer template',
    'ntf.prefs': 'Manage my notification preferences', 'ntf.manage': 'Manage notification rules and templates',
    'ntf.log.view': 'View the notification log and delivery failures',
    'lc.terms.edit': 'Edit letter of credit terms', 'lc.terms.treasury.edit': 'Edit the treasury fields of the terms',
    'lc.view.own': "View my requests' letters of credit", 'lc.view.all': 'View all letters of credit in scope',
    'lc.view.internal': 'View internal letter of credit details', 'lc.export.view': 'View received export letters of credit',
    'lc.export.record': 'Record a received export letter of credit', 'lc.issuance.record': 'Record letter of credit issuance',
    'lc.proforma.issue': 'Issue proforma invoices', 'lc.proforma.void': 'Void an issued proforma invoice',
    'lc.child.create': 'Create follow-up letter of credit requests', 'lc.amendment.record': 'Record amendments',
    'lc.drawing.record': 'Record drawings and settlements', 'lc.discrepancy.decide': 'Decide on discrepancies',
    'lc.close': 'Close or cancel a letter of credit', 'lc.order.release': 'Close a sales order and release the rest',
    'lc.compare': 'Compare a received letter of credit with the proforma', 'lc.counterparty.manage': 'Manage suppliers and customers',
    'lc.clause.manage': 'Manage the clause library', 'lc.field.manage': 'Configure letter of credit fields',
    'lc.template.manage': 'Manage bank form templates', 'lc.print': 'Print requests, proformas and bank forms',
    'lc.legacy.enter': 'Enter existing letters of credit', 'lc.report.view': 'View letter of credit reports',
    'lc.report.export': 'Export letter of credit reports',
}
# Arabic names where no matrix row names the code alone, or where the row text needs shortening
AR = {
    'sec.user.manage': 'إدارة المستخدمين', 'sec.role.manage': 'إدارة الأدوار والصلاحيات', 'sec.support.grant': 'منح وصول الدعم المؤقت',
    'cfg.settings.manage': 'إدارة إعدادات المشترك', 'cfg.numbering.manage': 'إدارة سلاسل الترقيم', 'cfg.alerts.manage': 'إدارة قواعد التنبيه',
    'cfg.jobs.view': 'عرض تشغيلات المهام الخلفية', 'cfg.export.request': 'طلب تصدير بيانات المشترك كاملة',
    'cfg.retention.approve': 'اعتماد الاحتفاظ والإتلاف', 'audit.export': 'تصدير سجل التدقيق',
    'org.company.manage': 'إنشاء الشركات وتعديل هيكلها وإعداداتها', 'org.company.view': 'عرض الشركات ضمن النطاق',
    'org.catalog.manage': 'إدارة قوائم التنظيم', 'org.ownership.manage': 'تسجيل الملكية وتغييرها',
    'org.body.manage': 'إدارة هيئات الحوكمة وأعضائها', 'org.grant.create': 'إنشاء منح الصلاحيات',
    'org.grant.approve': 'اعتماد منح الصلاحيات', 'org.document.manage': 'رفع المستندات الحكومية وإدارتها',
    'org.document.view': 'عرض المستندات غير المقيّدة',
    'party.manage': 'إنشاء الأشخاص وتعديل بياناتهم غير المقيّدة', 'party.field.manage': 'إدارة الحقول المخصصة للأطراف',
    'party.identity.write': 'إدخال أرقام الهويات وصورها', 'party.view': 'استعراض الأشخاص بأرقام مقنَّعة',
    'party.identity.image.view': 'عرض صور وثائق الهوية', 'party.pack.export': 'تصدير حزمة الكفيل بأرقام كاملة وصور',
    'party.pack.draft': 'طباعة مسودة حزمة الكفيل المقنَّعة', 'party.merge': 'دمج الأشخاص المكرَّرين',
    'party.kyc.manage': 'إدارة قوائم الاكتمال', 'party.export': 'تصدير قوائم الأشخاص',
    'party.export.sensitive': 'تصدير الأعمدة المقيّدة للأشخاص',
    'acc.reveal': 'كشف رقم الحساب وIBAN كاملًا', 'acc.signature.image.view': 'عرض صورة نموذج التوقيع وتنزيلها',
    'fac.override_limit': 'تجاوز الإتاحة بسبب مدوَّن', 'fac.reserve': 'حجز الحدود',
    'fac.lifecycle.manage': 'حسم سريان التسهيل وإنهاؤه', 'fin.stats.confirm': 'تأكيد الأرصدة والمبالغ المحوَّلة للبنك', 'fin.credit.assess': 'إعداد التقييم الائتماني للميزانية وحسابه', 'fin.credit.approve': 'اعتماد التقييم الائتماني', 'fin.credit.endorse': 'تصديق التقييم الائتماني المعتمد لاستعماله خارج الشركة', 'fin.period.lock': 'إقفال فترات القوائم والأرقام الشهرية لشركة وإعادة فتحها', 'fac.lifecycle.suspend': 'تعليق التسهيل ورفع التعليق', 'fac.approve': 'اعتماد مراجعة التسهيل أو رفضها',
    'fac.edit': 'إعداد مسودة مراجعة التسهيل وتقديمها',
    'prc.view': 'عرض التسعير والتعرفات', 'prc.manage': 'إدارة التسعير والتعرفات', 'prc.tariff.approve': 'اعتماد التعرفات',
    'col.view': 'عرض الضمانات والكفالات', 'col.manage': 'إدارة الضمانات والكفالات', 'col.approve': 'اعتماد تغييرات الضمانات',
    'cmp.view': 'عرض الشروط القابلة للمقارنة', 'cmp.manage': 'إدارة الشروط القابلة للمقارنة', 'cmp.term.propose': 'اقتراح مفتاح شرط جديد',
    'obl.breach.manage': 'إدارة المخالفات', 'obl.waiver.approve': 'اعتماد الإعفاءات',
    'fin.stmt.enter': 'إدخال القوائم المالية', 'fin.stmt.approve': 'اعتماد القوائم المالية',
    'fin.formula.manage': 'إدارة معادلات التعهدات', 'fin.formula.approve': 'اعتماد معادلات التعهدات',
    'req.cancel': 'إلغاء طلباتي', 'req.cancel.any': 'إلغاء أي طلب ضمن النطاق', 'req.treasury.close': 'إقفال الطلب من الخزينة',
    'wfl.request.migrate': 'نقل طلب جارٍ إلى نسخة قالب أحدث', 'wfl.template.publish': 'نشر نسخة قالب',
    'lc.terms.edit': 'تحرير شروط الاعتماد', 'lc.view.all': 'عرض كل الاعتمادات ضمن النطاق',
    'lc.view.internal': 'عرض التفاصيل الداخلية للاعتماد', 'lc.issuance.record': 'تسجيل إصدار الاعتماد',
    'lc.child.create': 'إنشاء طلبات المتابعة على الاعتماد', 'lc.report.view': 'عرض تقارير الاعتمادات',
    'lc.report.export': 'تصدير تقارير الاعتمادات', 'lc.compare': 'مقارنة الاعتماد المستلَم بالبروفورما',
    'audit.view': 'عرض سجل التدقيق كاملًا',
}
# BR-PLT-019 and DQ-F09-1: the permissions only TM and FO may hold; they are also sensitive (BR-PLT-008).
LOCKED = {'party.identity.reveal', 'party.identity.image.view', 'party.pack.export', 'party.export.sensitive',
          'acc.signature.image.view'}
SENSITIVE = LOCKED | {'acc.reveal'}                   # reveals restricted data; logged (spec 11 matrix)
LC_SALES = {'lc.export.view', 'lc.export.record', 'lc.proforma.issue', 'lc.proforma.void', 'lc.order.release', 'lc.compare'}


def module_of(code):
    p = code.split('.')[0]
    if p in ('ins', 'acc', 'sig'):
        return 'INSTITUTIONS'
    if p in ('fac', 'prc', 'col', 'cmp'):
        return 'FACILITIES'
    if p in ('obl', 'fin'):
        return 'COVENANTS'
    if p == 'req':
        return 'REQUESTS'
    if p == 'wfl':
        return 'WORKFLOW'
    if p == 'lc':
        return 'LC_SALES' if code in LC_SALES else 'LC_PURCHASE'
    return 'CORE'                                      # sec, cfg, audit, org, party, cat, ntf


def clean(t):
    t = re.sub(r'`[^`]*`', '', t)
    t = re.sub(r'[*🟢🟡🔒◐]', '', t)
    t = re.sub(r'\s*\((?:S\d[^)]*|\d\d[^)]*|04 [^)]*|قرار[^)]*|Could|Q-[^)]*)\)', '', t)
    return re.sub(r'\s+', ' ', t).strip(' -—،,')


def codes_from_documents():
    f9 = open(glob.glob(os.path.join(ROOT, 'docs/30-readiness/DOC-F09*.md'))[0], encoding='utf-8').read().split('\n')
    i = next(k for k, l in enumerate(f9) if l.startswith('### 3.1'))
    j = next(k for k, l in enumerate(f9) if l.startswith('### 3.2'))
    k = next(k for k, l in enumerate(f9) if k > j and l.startswith('## '))
    codes = set()
    for l in f9[i:j]:
        if l.startswith('| ') and '`' in l:
            codes |= set(CODE.findall(l.split('|')[2]))
    for l in f9[j:k]:
        if l.startswith('| `'):
            codes |= set(CODE.findall(l.split('|')[1]))
    f7 = open(glob.glob(os.path.join(ROOT, 'docs/30-readiness/DOC-F07*.md'))[0], encoding='utf-8').read().split('\n')
    i = next(k for k, l in enumerate(f7) if l.startswith('## 3.'))
    j = next(k for k, l in enumerate(f7) if k > i and l.startswith('## '))
    for l in f7[i:j]:
        if l.startswith('| `'):
            codes |= set(CODE.findall(l.split('|')[1]))
    return codes


def matrix_names():
    names = {}
    for f in sorted(glob.glob(os.path.join(ROOT, 'docs/10-detailed-analysis/1[0-4]-*.md'))):
        for l in open(f, encoding='utf-8'):
            if not l.startswith('|'):
                continue
            cells = [c.strip() for c in l.strip().strip('|').split('|')]
            for k in (1, 2):
                if len(cells) > k and cells[k].startswith('`'):
                    found = CODE.findall(cells[k])
                    if len(found) == 1 and found[0] not in names:
                        names[found[0]] = clean(cells[k - 1])
    return names


def q(s):
    return "N'" + s.replace("'", "''") + "'"


def main():
    codes = codes_from_documents()
    missing = sorted(codes - set(EN))
    extra = sorted(set(EN) - codes)
    if missing or extra:
        raise SystemExit(f'English names out of step with the documents: missing {missing}, not in documents {extra}')
    names = matrix_names()
    rows = []
    for c in sorted(codes):
        ar = AR.get(c) or names.get(c)
        if not ar:
            raise SystemExit(f'no Arabic name for {c}')
        locked = "N'[\"TM\",\"FO\"]'" if c in LOCKED else 'NULL'
        rows.append(f"    ('{c}', '{module_of(c)}', {q(ar)}, {q(EN[c])}, {1 if c in SENSITIVE else 0}, {locked})")
    with open(OUT, 'w', encoding='utf-8') as f:
        f.write(f"""/* ============================================================================
   BankFas - 102: the permission catalogue (DQ-F07-1, DQ-F09-1, owner decisions 2026-10-12; FR-PLT-017, BR-PLT-019)
   GENERATED by tools/dbgen/gen_permission_seed.py from DOC-F07 section 3, DOC-F09 sections 3.1 and 3.2 and the
   role matrices of specs 10 to 14 — do not edit by hand.

   {len(rows)} codes. LockedToRoleCodes ["TM","FO"] for the {len(LOCKED)} permissions only the treasury manager and the
   facilities officer may hold (BR-PLT-019, DQ-F09-1); they and acc.reveal are sensitive (BR-PLT-008).
   The default role assignment (role matrices) is the CORE.ROLES tenant pack: tools/dbgen/core_roles_pack.py, 057.
   Insert only: a code that exists is never changed.
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
MERGE sec.Permission AS d
USING (VALUES
{",\n".join(rows)}
) AS s (Code, ModuleCode, NameAr, NameEn, IsSensitive, LockedToRoleCodes)
   ON d.Code = s.Code
WHEN NOT MATCHED THEN
    INSERT (Code, ModuleCode, NameAr, NameEn, IsSensitive, LockedToRoleCodes, IsActive)
    VALUES (s.Code, s.ModuleCode, s.NameAr, s.NameEn, s.IsSensitive, s.LockedToRoleCodes, 1);
GO
""")
    print(f'wrote {OUT}: {len(rows)} permissions, {len(LOCKED)} locked, {len(SENSITIVE)} sensitive')


if __name__ == '__main__':
    main()
