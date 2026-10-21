#!/usr/bin/env python3
"""erd_plan.py — English chart plan for the database relationship document.

Each chart shows at most MAX_MEMBERS tables of one functional group. Parents outside a chart appear as grey
reference boxes, so every connector drawn has both of its ends on the page. Every table belongs to exactly one
chart as a member; the plan is checked against the model before any file is written.
"""
import math

MAX_MEMBERS = 8

# module key prefix → (module label, short label used in headings)
MODULES = [
    ('m0', 'M0 · Platform and security'),
    ('m1', 'M1 · Organisation and parties'),
    ('m2_3', 'M2–M3 · Institutions and accounts'),
    ('m4', 'M4 · Products and catalogues'),
    ('m5', 'M5 · Facilities and collateral'),
    ('m6', 'M6 · Workflow and notifications'),
    ('m7_8', 'M7–M8 · Letters of credit'),
]

# key, title, subtitle, members (schema names or schema-qualified table names)
GROUPS = [
    ('m0_tenancy', 'Tenancy, plans and support access', 'plat schema: tenants, plans and modules, reserved sub-domains, support access grants',
     ['plat.Tenant', 'plat.Plan', 'plat.PlanModule', 'plat.TenantModule', 'plat.ReservedSubdomain', 'plat.SupportAccessGrant']),
    ('m0_operators', 'Platform operators', 'plat schema: operator accounts, their sessions and set-up links (ADR 0004)',
     ['plat.PlatformOperator', 'plat.OperatorSession', 'plat.OperatorToken']),
    ('m0_identity', 'Identity and authorisation', 'sec schema: users, roles, permissions, company scopes, external identities',
     ['sec.AppUser', 'sec.Role', 'sec.Permission', 'sec.RolePermission', 'sec.UserRole', 'sec.UserCompanyScope', 'sec.ExternalIdentity']),
    ('m0_sessions', 'Sessions, keys and authentication attempts', 'sessions, login attempts, MFA recovery codes, tokens, password history, encryption keys',
     ['sec.UserSession', 'sec.LoginAttempt', 'sec.MfaRecoveryCode', 'sec.UserToken', 'sec.UserPasswordHistory', 'sec.TenantKey', 'sec.KeyEvent', 'sec.SessionBinding']),
    ('m0_audit_docs', 'Audit trail and documents', 'aud and doc schemas: audit log, its hash chain head and anchors, and document store',
     ['aud', 'doc']),
    ('m0_config', 'Configuration, background jobs and schema migrations', 'cfg schema: tenant settings, scheduled and background jobs; the schema migration journal (ADR 0034)',
     ['cfg', 'plat.SchemaMigration']),
    ('m1_company', 'Company structure and governance', 'org schema: company, tax rates, departments, shareholding, governing bodies, authority grants',
     ['org.Company', 'org.CompanyTaxRate', 'org.Department', 'org.Shareholding', 'org.GoverningBody', 'org.BodyMember', 'org.AuthorityGrant']),
    ('m1_company_kyc', 'Company profile and KYC', 'company profile, branches, financial profile, expected flows, wealth sources, disclosures, key relations',
     ['org.CompanyProfile', 'org.CompanyBranch', 'org.CompanyKycFinancialProfile', 'org.CompanyExpectedFlow', 'org.CompanyWealthSource', 'org.CompanyDisclosure', 'org.CompanyKeyRelation']),
    ('m1_party', 'Parties, identity documents and KYC', 'pty schema: the shared party model (persons and legal entities)',
     ['pty']),
    ('m2_3_institutions', 'Financial institutions, bank accounts and signatories', 'ins and acc schemas: institutions, accounts, signatories',
     ['ins', 'acc']),
    ('m4_products', 'Products, fees, financing and collateral types', 'cat schema: product categories, products, fee and financing types, limit and collateral types',
     ['cat.ProductCategory', 'cat.Product', 'cat.FeeType', 'cat.FinancingType', 'cat.ProductFeeType', 'cat.ProductFinancingType', 'cat.FacilityType', 'cat.LimitType', 'cat.LimitTypeProduct', 'cat.CollateralType', 'cat.CollateralTypeAttribute', 'cat.ObligationType']),
    ('m4_reference', 'Reference catalogues', 'cat schema: currencies, institution types, account types, legal entity types, document types, positions, powers',
     ['cat.TenantCurrency', 'cat.InstitutionType', 'cat.AccountType', 'cat.LegalEntityType', 'cat.DocumentType', 'cat.Position', 'cat.PowerType']),
    ('m4_rates_lookups', 'Base rates and lookup lists', 'cat schema: operation types, base rates and their values, lookup lists',
     ['cat.OperationType', 'cat.OperationTypePowerType', 'cat.BaseRate', 'cat.BaseRateAlias', 'cat.BaseRateValue', 'cat.LookupList', 'cat.LookupItem']),
    ('m4_global_ref', 'Global references (shared, read-only)', 'ref schema: shared reference data owned by the platform',
     ['ref']),
    ('m5_facility_core', 'Facilities and revisions', 'fac schema: facilities, revisions, documents, lenders, outstanding snapshots, value conflicts',
     ['fac.Facility', 'fac.FacilityRevision', 'fac.FacilityDocument', 'fac.FacilityLender', 'fac.OutstandingSnapshot', 'fac.FacilityLenderDecision', 'fac.ValueConflict']),
    ('m5_limits', 'Limits, utilisation and reservations', 'fac schema: limits, product lines, company rules, terms, utilisation, reservations, movements',
     ['fac.Limit', 'fac.LimitProductLine', 'fac.LimitCompanyRule', 'fac.ProductLineTerm', 'fac.Utilization', 'fac.LimitReservation', 'fac.LimitMovement']),
    ('m5_pricing', 'Pricing, tariffs and comparable terms', 'prc and cmp schemas: pricing, tariffs, comparable terms',
     ['prc', 'cmp']),
    ('m5_collateral', 'Collateral and guarantees', 'col schema: collateral items, valuations and guarantees',
     ['col']),
    ('m5_obligations', 'Obligations, covenants and reporting', 'obl schema: obligations, covenants and reporting',
     ['obl']),
    ('m5_financials', 'Financial statements and balances', 'fin schema: financial statements and balances',
     ['fin']),
    ('m6_wf_templates', 'Workflow templates', 'wfl schema: request types, workflow templates, stages, approvers, transitions, hooks, template fields',
     ['wfl.RequestType', 'wfl.RequestTypeAudience', 'wfl.ExternalPhase', 'wfl.WorkflowTemplate', 'wfl.WorkflowStage', 'wfl.StageApprover', 'wfl.WorkflowTransition', 'wfl.WorkflowStageHook', 'wfl.TemplateField', 'wfl.TemplateAttachmentRule']),
    ('m6_requests', 'Requests, approvals and actions', 'wfl schema: requests, comments, attachments, stage instances, approvals, actions, hook executions, delegations',
     ['wfl.Request', 'wfl.RequestComment', 'wfl.RequestAttachment', 'wfl.RequestExternalRef', 'wfl.RequestStageInstance', 'wfl.RequestApproval', 'wfl.RequestAction', 'wfl.HookExecution', 'wfl.UserDelegation']),
    ('m6_notifications', 'Notifications', 'ntf schema: notifications and delivery',
     ['ntf']),
    ('m7_8_lc_terms', 'Letter of credit terms, fields and form maps', 'lc schema: LC field definitions, UCP references, counterparties, clauses, terms, charges, form templates',
     ['lc.LcFieldDefinition', 'lc.LcFieldUcpRef', 'lc.Counterparty', 'lc.LcDocumentClause', 'lc.LcDocumentClauseUcpRef', 'lc.LcTerms', 'lc.LcTermsDocument', 'lc.LcChargesMatrix', 'lc.LcFormTemplate', 'lc.LcFormFieldMap']),
    ('m7_8_lc_ops', 'Letters of credit and proforma invoices', 'lc schema: letters of credit, amendments, drawings, sales orders, discrepancies, proforma invoices, terms comparison',
     ['lc.LetterOfCredit', 'lc.LcExternalRef', 'lc.LcAmendment', 'lc.LcDrawing', 'lc.LcSalesOrder', 'lc.LcDrawingAllocation', 'lc.LcDiscrepancy', 'lc.ProformaInvoice', 'lc.ProformaLine', 'lc.LcTermsComparison', 'lc.LcTermsComparisonLine']),
]


def module_of(key):
    for prefix, label in sorted(MODULES, key=lambda m: -len(m[0])):
        if key.startswith(prefix):
            return label
    raise KeyError(key)


def expand(spec, tables):
    out = []
    for item in spec:
        if item in tables:
            out.append(item)
        else:
            out += sorted(t.fq for t in tables.values() if t.schema == item)
    return out


def plan(tables):
    """Charts in reading order: dict(key, module, title, subtitle, part, parts, members)."""
    charts = []
    for key, title, sub, spec in GROUPS:
        members = expand(spec, tables)
        n_parts = math.ceil(len(members) / MAX_MEMBERS)
        size = math.ceil(len(members) / n_parts)
        for i in range(n_parts):
            chunk = members[i * size:(i + 1) * size]
            if not chunk:
                continue
            ck = key if n_parts == 1 else f'{key}_{i + 1}'
            charts.append({'group': key, 'key': ck, 'module': module_of(key), 'title': title, 'subtitle': sub,
                           'part': i + 1, 'parts': n_parts, 'members': chunk})
    assigned = [fq for c in charts for fq in c['members']]
    if sorted(assigned) != sorted(tables) or len(set(assigned)) != len(assigned):
        missing = sorted(set(tables) - set(assigned))
        raise SystemExit(f'plan does not cover each table exactly once; missing={missing[:5]}')
    return charts
