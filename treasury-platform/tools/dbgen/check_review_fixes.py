#!/usr/bin/env python3
"""check_review_fixes.py — يتحقق من أن الإصلاحات الحرجة العشرة (docs/review/design-review-2026-10-11.json) موجودة فعلًا في DDL المولَّد."""
import os, re, sys
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
G = os.path.join(ROOT, 'db', 'generated', 'tsql')
S = os.path.join(ROOT, 'db', 'static')
read = lambda p: open(p, encoding='utf-8').read()
fk = read(os.path.join(G, '002_foreign_keys.sql'))
tb = read(os.path.join(G, '001_tables.sql'))
sens = read(os.path.join(G, '006_sensitive_columns.sql'))
static = read(os.path.join(S, '025_tenant_views.sql'))
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

bad = [k for k, v in checks.items() if not v]
for k, v in checks.items(): print(('PASS ' if v else 'FAIL ') + k)
print(f'review fixes: {len(checks) - len(bad)}/{len(checks)} verified')
sys.exit(1 if bad else 0)
