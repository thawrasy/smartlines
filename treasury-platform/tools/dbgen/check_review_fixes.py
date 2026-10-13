#!/usr/bin/env python3
"""check_review_fixes.py — يتحقق من أن الإصلاحات الحرجة العشرة (docs/review/design-review-2026-10-11.json) موجودة فعلًا في DDL المولَّد،
ومعها الإصلاحات التصريحية للنتائج الرئيسية والطفيفة التي اعتمدها المالك في 2026-10-13 (O-15، docs/32-review-findings-decisions.md).
القوادح والمنع في db/static/043_review_guards.sql تختبرها db/tests/review_fixes_tests.sql."""
import os, re, sys
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
G = os.path.join(ROOT, 'db', 'generated', 'tsql')
S = os.path.join(ROOT, 'db', 'static')
read = lambda p: open(p, encoding='utf-8').read()
fk = read(os.path.join(G, '002_foreign_keys.sql'))
tb = read(os.path.join(G, '001_tables.sql'))
sens = read(os.path.join(G, '006_sensitive_columns.sql'))
static = read(os.path.join(S, '025_tenant_views.sql'))
guards = read(os.path.join(S, '043_review_guards.sql'))
ix = read(os.path.join(G, '003_indexes.sql'))
grants = read(os.path.join(G, '005_delete_grants.sql')) + read(os.path.join(G, '007_table_grants.sql'))
checks = {}

def fkline(child, col):
    return re.search(rf'ALTER TABLE \[\w+\]\.\[{child}\] ADD CONSTRAINT \[FK_{child}_{col}\] FOREIGN KEY \(([^)]*)\) REFERENCES \[\w+\]\.\[\w+\] \(([^)]*)\)', fk)

# DR-01 TenantModule: مملوك للمنصة، ويقرأه التطبيق عبر عرض مُقيَّد بالمشترك
tm_block = re.search(r'CREATE TABLE \[plat\]\.\[TenantModule\] \((.*?)\n\);', tb, re.S).group(1)
checks['DR-01 TenantModule: explicit TenantId, no RLS, tenant view'] = ('[TenantId]' in tm_block and 'plat.v_TenantModule' in static)

# DR-02 key purpose: composite FK with purpose, scope unique on TenantKey
for child, col, purpose in [('AppUser', 'MfaKeyId', 'MfaKeyPurpose'), ('IdentityDocument', 'EncKeyId', 'EncKeyPurpose'),
                            ('IdentityDocument', 'HashKeyId', 'HashKeyPurpose'), ('PartyCustomField', 'EncKeyId', 'EncKeyPurpose'),
                            ('BankAccount', 'EncKeyId', 'EncKeyPurpose'), ('BankAccount', 'HashKeyId', 'HashKeyPurpose'),
                            ('LcTerms', 'EncKeyId', 'EncKeyPurpose'), ('DocumentVersion', 'KeyId', 'KeyPurpose')]:
    m = fkline(child, col)
    checks[f'DR-02 {child}.{col} keyed with {purpose}'] = bool(m and purpose in m.group(1) and 'Purpose' in m.group(2))
checks['DR-02 TenantKey scope unique (TenantId, Purpose, TenantKeyId)'] = 'UQ_TenantKey_Scope_Purpose' in tb

# DR-03/05/07 catalogue tenant-owned: no mixed LookupItem; references composite on TenantId
li_block = re.search(r'CREATE TABLE \[cat\]\.\[LookupItem\] \((.*?)\n\);', tb, re.S).group(1)
checks['DR-03 cat.LookupItem tenant-owned (TenantId NOT NULL, no mixed NULL)'] = '[TenantId] INT NOT NULL' in li_block and '[TenantId] INT NULL' not in li_block
refs = re.findall(r'REFERENCES \[cat\]\.\[LookupItem\] \(([^)]*)\)', fk)
checks['DR-05/07 every LookupItem reference is composite (TenantId, LookupItemId)'] = bool(refs) and all('TenantId' in r for r in refs)

# DR-04 owner arcs: four nullable FKs, no polymorphic OwnerType/OwnerId
for t in ['Address', 'ContactMethod']:
    checks[f'DR-04 pty.{t} exclusive owner arcs, no OwnerType'] = all(fkline(t, c) for c in ['PartyId', 'InstitutionId', 'UnitId', 'ContactId']) and 'OwnerType' not in tb.split(f'CREATE TABLE [pty].[{t}]')[1][:4000]

# DR-06 pricing/term keys bound to the limit
p = fkline('PricingRule', 'ScopeLimitProductLineId')
checks['DR-06 PricingRule.ScopeLimitProductLineId bound to ScopeLimitId'] = bool(p and 'ScopeLimitId' in p.group(1) and 'LimitId' in p.group(2))
t = fkline('TermValue', 'LimitProductLineId')
checks['DR-06 TermValue.LimitProductLineId bound to LimitId'] = bool(t and 'LimitId' in t.group(1))

# DR-08 collateral attributes restricted; cash margin account is a typed reference
checks['DR-08 Collateral.Attributes restricted (DENY for tp_readonly)'] = 'Attributes' in sens and 'Collateral' in sens
checks['DR-08 Collateral.CashMarginAccountId typed FK to acc.BankAccount'] = bool(fkline('Collateral', 'CashMarginAccountId'))

# DR-09 request stage instances pinned to the template
checks['DR-09 RequestStageInstance.TemplateId column'] = '[TemplateId]' in re.search(r'CREATE TABLE \[wfl\]\.\[RequestStageInstance\] \((.*?)\n\);', tb, re.S).group(1)
s = fkline('RequestStageInstance', 'StageId')
checks['DR-09 RequestStageInstance.StageId bound to TemplateId'] = bool(s and 'TemplateId' in s.group(1))

# DR-10 request to letter-of-credit links bound to the company
r = fkline('Request', 'LcId')
checks['DR-10 Request.LcId bound to CompanyId'] = bool(r and 'CompanyId' in r.group(1))
for child in ['LcSalesOrder', 'LcDrawing', 'LcAmendment']:
    q = fkline(child, 'RequestId')
    checks[f'DR-10 {child}.RequestId bound to CompanyId'] = bool(q and 'CompanyId' in q.group(1))

# DR-02 دورة حياة المفتاح: التفعيل مطلوب للحالات النشطة، وتاريخ التقاعد مطلوب للمتقاعد
checks['DR-02 TenantKey lifecycle CHECKs (ActivatedAt, RetiredAt)'] = 'CK_TenantKey_2' in tb and 'CK_TenantKey_3' in tb
# DR-04 قوس المالك: عمود واحد غير فارغ بالضبط في pty.Address
checks['DR-04 pty.Address exactly-one owner CHECK'] = bool(re.search(r'CK_Address_1\] CHECK \(\(PartyId IS NOT NULL AND InstitutionId IS NULL AND UnitId IS NULL AND ContactId IS NULL\)', tb))

# ---- O-15: the major and minor findings approved on 2026-10-13 (declarative part)
def block(schema, table):
    m = re.search(rf'CREATE TABLE \[{schema}\]\.\[{table}\] \((.*?)\n\);', tb, re.S)
    return m.group(1) if m else ''
def has_check(schema, table, *parts):
    return any(all(p in c for p in parts) for c in re.findall(r'CHECK \((.*)\)', block(schema, table)))
def fk_has(child, col, *cols):
    m = fkline(child, col)
    return bool(m) and all(c in m.group(1) for c in cols)

checks['DR-11 DocumentVersion.StorageKey unique on the platform'] = 'CONSTRAINT [UQ_DocumentVersion_StorageKey] UNIQUE ([StorageKey])' in tb
checks['DR-11 DocumentVersion content columns not updatable by tp_app (043)'] = bool(re.search(r'DENY UPDATE ON doc\.DocumentVersion \([^)]*Sha256', guards))
checks['DR-12 SensitiveAccessLog.AuditLogId required, same-tenant composite FK'] = fk_has('SensitiveAccessLog', 'AuditLogId', 'TenantId') and '[AuditLogId] BIGINT NOT NULL' in block('aud', 'SensitiveAccessLog')
checks['DR-13 DataExportJob approval and expiry checks'] = has_check('cfg', 'DataExportJob', "Status = 'REQUESTED' OR ApprovedBy IS NOT NULL") and has_check('cfg', 'DataExportJob', 'ExpiresAt IS NOT NULL')
checks['DR-14 OutboxEvent lease, delivery and dead-letter checks'] = all(has_check('cfg', 'OutboxEvent', x) for x in ['LockedUntil IS NOT NULL', 'DeliveredAt IS NOT NULL', 'LastError IS NOT NULL']) and 'IX_OutboxEvent_LockedUntil' in ix
checks['DR-15 SupportAccessGrant 1 to 72 hours, paired revocation'] = has_check('plat', 'SupportAccessGrant', 'DATEADD(HOUR, 72') and has_check('plat', 'SupportAccessGrant', 'RevokedBy IS NOT NULL')
checks['DR-16 locked permission trigger and role column DENY (043)'] = 'TR_RolePermission_Locked' in guards and 'DENY UPDATE ON sec.Role (Code, IsSystem, SeedKey)' in guards
checks['DR-18 Document.CurrentVersionId bound to the document; no PUBLIC'] = fk_has('Document', 'CurrentVersionId', 'DocumentId') and has_check('doc', 'Document', "Sensitivity <> 'PUBLIC'")
checks['DR-19 Signatory revocation evidence'] = has_check('acc', 'Signatory', "Status <> 'REVOKED'", 'RevokedReason') and 'TR_Signatory_FinalStatus' in guards
checks['DR-21 AuthorityGrant approver, supersession within the company'] = has_check('org', 'AuthorityGrant', 'ApprovedAt IS NOT NULL') and fk_has('AuthorityGrant', 'SupersedesGrantId', 'CompanyId')
checks['DR-23 IdentityDocument.SupersededById bound to the party'] = fk_has('IdentityDocument', 'SupersededById', 'PartyId')
checks['DR-24 one company-mirror link, to an organisation'] = 'LinkedCompanyId' not in block('pty', 'Party') and fk_has('Company', 'PartyId', 'PartyKind')
checks['DR-25 Company.TaxNumber labelled confidential'] = bool(re.search(r'TaxNumber\s+ascii\(30\)\s+sens=confidential', read(os.path.join(ROOT, 'db', 'model', '11-organization-party.model'))))
checks['DR-26 Utilization: no polymorphic SourceRefId; typed request link'] = 'SourceRefId' not in block('fac', 'Utilization') and fk_has('Utilization', 'SourceRequestId', 'CompanyId') and fk_has('LetterOfCredit', 'UtilizationId', 'CompanyId')
checks['DR-27 ValueConflict target list'] = has_check('fac', 'ValueConflict', "TargetEntity IN ('fac.Facility'")
checks['DR-29 BaseRate currency required; alias in its rate scope'] = '[CurrencyId] INT NOT NULL' in block('cat', 'BaseRate') and fk_has('BaseRateAlias', 'BaseRateId', 'ScopeKey')
checks['DR-31 agreement text denied to tp_readonly (043)'] = 'OriginalText' in guards and 'tp_readonly' in guards
checks['DR-32 set{} columns carry a membership check'] = all(f'CK_{t}_{c}]' in tb for t, c in [('JobDefinition', 'RunsInStatuses'), ('Country', 'WeekendDays'), ('DocumentType', 'AppliesTo'), ('FacilityLender', 'Roles'), ('LcAmendment', 'ChangeKinds')])
checks['DR-33 Guarantee identity document bound to the guarantor'] = fk_has('Guarantee', 'GuarantorIdentityDocumentId', 'GuarantorPartyId')
checks['DR-34 FinancialStatement.SupersedesId bound to its series'] = fk_has('FinancialStatement', 'SupersedesId', 'CompanyId', 'Basis', 'Assurance', 'PeriodType', 'PeriodEnd')
checks['DR-35 Obligation.ScopeProductLineId bound to ScopeLimitId'] = fk_has('Obligation', 'ScopeProductLineId', 'ScopeLimitId') and has_check('obl', 'Obligation', 'ScopeProductLineId IS NULL OR ScopeLimitId IS NOT NULL')
checks['DR-37 MonthEnd is a month end'] = has_check('fin', 'AccountMonthlyStat', 'DAY(DATEADD(DAY, 1, MonthEnd)) = 1') and has_check('fin', 'BankFlowEntry', 'DAY(DATEADD(DAY, 1, MonthEnd)) = 1')
checks['DR-38 Covenant SET threshold has a unit'] = has_check('obl', 'Covenant', 'ThresholdUnit IS NOT NULL')
checks['DR-40 subtypes bound to the parent kind'] = all(fk_has(c, 'CollateralId', 'StructureKind') for c in ['Guarantee', 'PromissoryNote', 'InsurancePolicyAssignment', 'ValuationSchedule']) and all(fk_has(c, 'ObligationId', 'Family') for c in ['ReportingObligation', 'Covenant'])
checks['DR-41 ProformaLine append-only; ProformaInvoice content not updatable (043)'] = 'DENY UPDATE ON [lc].[ProformaLine]' in grants and 'DENY UPDATE ON lc.ProformaInvoice' in guards
checks['DR-42 LC and its terms agree on class, currency and tolerance'] = fk_has('LetterOfCredit', 'CurrentTermsId', 'LcClass', 'CurrencyId', 'TolerancePlusPct') and fk_has('ProformaInvoice', 'TermsId', 'TermsPurpose') and fk_has('LcAmendment', 'TermsId', 'TermsPurpose')
checks['DR-43 HookExecution key includes ActionFilter'] = bool(re.search(r'UQ_HookExecution_\w*ActionFilter', tb + ix))
checks['DR-45 purchase LC names its issuing bank'] = has_check('lc', 'LetterOfCredit', "LcClass = 'SALES' OR InstitutionId IS NOT NULL")
checks['DR-46 no IBAN value in comparison lines'] = has_check('lc', 'LcTermsComparisonLine', 'beneficiaryAccountIban')
checks['DR-47 ErpCodeNormalized computed'] = 'ErpCodeNormalized] AS (' in block('org', 'Company') and 'ErpCodeNormalized] AS (' in block('lc', 'Counterparty')
checks['DR-48 code checks compare in binary'] = 'Iso2 COLLATE Arabic_100_BIN2' in tb
checks['DR-49 request number sequence key follows the code'] = has_check('wfl', 'RequestType', "CONCAT('req:', Code)")
checks['DR-50 state evidence: rejection reason, publisher, locker, delegation, notification key'] = (
    has_check('wfl', 'Request', "Status <> 'REJECTED' OR OutcomeReason IS NOT NULL") and has_check('wfl', 'WorkflowTemplate', 'PublishedBy IS NOT NULL')
    and has_check('lc', 'LcTerms', 'LockedBy IS NOT NULL') and has_check('wfl', 'RequestApproval', 'OnBehalfOfUserId IS NULL AND DelegationId IS NULL')
    and '[DedupKey] VARCHAR(200) NOT NULL' in block('ntf', 'Notification'))

bad = [k for k, v in checks.items() if not v]
for k, v in checks.items(): print(('PASS ' if v else 'FAIL ') + k)
print(f'review fixes: {len(checks) - len(bad)}/{len(checks)} verified')
sys.exit(1 if bad else 0)
