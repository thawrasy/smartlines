#!/usr/bin/env python3
"""erd_open_items.py — open items and decisions for the database design, taken from the two specialist reviews.

Each item says what the review found, where the model stands today, and what is still needed. "Status" is
checked against the repository when this file is changed: a status that claims a control must name the file
that implements it. The Word document renders these rows in section 4.
"""

REVIEW_A = 'Review A (analysis review, 12 Oct 2026)'
REVIEW_B = 'Review B (technical analysis, 12 Oct 2026)'

ITEMS = [
    {
        'id': 'O-01', 'sources': f'{REVIEW_A}; {REVIEW_B}',
        'finding': 'The password hashing algorithm is not documented. Review B recommends Argon2id with 64 MB memory, 3 iterations and 4 lanes.',
        'status': 'Decided by the owner (2026-10-12): Argon2id, PHC string, minimum m=65536, t=3, p=4. Recorded in FR-PLT-010 and docs/adr/0002-login-and-session-bound-context.md. A CHECK enforces the Argon2id format on sec.AppUser, sec.UserPasswordHistory and plat.PlatformOperator (db/model/10-platform.model). The application computes the hash; sec.usp_StartSession compares it in the database.',
        'next': 'Choose a reviewed Argon2id library for .NET when the application is built.',
    },
    {
        'id': 'O-02', 'sources': f'{REVIEW_A}; {REVIEW_B}',
        'finding': 'The schema has never run on SQL Server 2025.',
        'status': 'Executed on SQL Server 2025 (RTM-CU9): db/deploy.sql runs to completion and the deployed counts match the DDL (195 tables, 20 schemas, 764 foreign keys, 515 unique constraints, 1,161 CHECK constraints, 700 indexes). The CI script tools/ci/db_ci.sh passes in full against the Ubuntu-based SQL Server 2025 container in the development environment. On GitHub it runs from .github/workflows/treasury-db-ci.yml at the repository root (GitHub reads workflows only there) on every change under treasury-platform/db, tools/dbgen or tools/ci; the first green run is https://github.com/thawrasy/smartlines/actions/runs/38283663041 (6 + 41 tests). Not yet run on the production server.',
        'next': 'Run tools/deploy/deploy.sh on the production Ubuntu 24.04 VPS (ADR 0001), the way CI already does since docs/adr/0010-deployment-as-db-owner.md: an administrator prepares the empty database once (tools/deploy/prepare_database.sh), and the deployment login bankfas_migrator, a member of db_owner only, runs it inside an open window. tools/deploy/deploy.ps1 is kept for a Windows host and has not been run.',
    },
    {
        'id': 'O-03', 'sources': f'{REVIEW_A}; {REVIEW_B}',
        'finding': 'Lender shares must total 100 per facility and at most one lender may hold the AGENT role. The model says the application checks both.',
        'status': 'Trigger in db/static/050_fac_share_rule.sql, deployed by db/deploy.sql. Six tests pass on SQL Server 2025 (db/tests/fac_share_rule_tests.sql): valid approval, rejected total above 100, rejected approval without lenders for the new revision, valid new revision, rejected second agent, and a partial draft accepted.',
        'next': 'Decided by the owner (2026-10-12, docs/31-owner-decisions.md): a lender change after approval goes through a CORRECTION revision only; the trigger stays as the last guard (DQ-F13-7). To build with the facility service in S2.',
    },
    {
        'id': 'O-04', 'sources': REVIEW_B,
        'finding': 'A SHARED payer in the LC charge matrix needs a valid share.',
        'status': 'Enforced in the model: check Payer <> SHARED OR share in (0,100) on lc.LcChargesMatrix (V-LCT-12).',
        'next': 'None.',
    },
    {
        'id': 'O-05', 'sources': REVIEW_B,
        'finding': 'An LC terms record needs six complete charge rows, one per category. The model checks this in the application only.',
        'status': 'Open. The state in which completeness must hold is not defined, so no database rule is written yet.',
        'next': 'Business decision: at which status (draft, submitted, approved) the six rows must be complete.',
    },
    {
        'id': 'O-06', 'sources': f'{REVIEW_A}; {REVIEW_B}',
        'finding': 'UCP 600 article numbers are not verified against the official ICC text.',
        'status': 'Open. The analysis document marks them UNVERIFIED, and the platform seed holds the 39 articles as UNVERIFIED platform rows (db/seed/103_lc_reference.sql, ADR 0005), so the badge and the print footnote show until they are checked.',
        'next': 'Check each article number against the official text and record the result.',
    },
    {
        'id': 'O-07', 'sources': f'{REVIEW_A}; {REVIEW_B}',
        'finding': '155 open questions are answered with default values.',
        'status': 'Listed in docs/10-detailed-analysis/90-consolidated-open-questions.md. Defaults are in use.',
        'next': 'Owner decision 2026-10-12 (DQ-B09-2): add owner, needed-by and review-date columns to section 14 of each specification and to tools/gen_indexes.py; resolve the critical questions before slices S0 to S2.',
    },
    {
        'id': 'O-08', 'sources': f'{REVIEW_A}; {REVIEW_B}',
        'finding': 'TLS version, cipher suites and HSTS are not specified.',
        'status': 'Open. Not documented in the analysis or the model.',
        'next': 'Write a TLS policy: TLS 1.2 minimum, TLS 1.3 preferred, HSTS, and no SSLv3, TLS 1.0 or 1.1.',
    },
    {
        'id': 'O-09', 'sources': REVIEW_A,
        'finding': 'Tenant isolation is designed (TenantId, row-level security, composite keys) but not tested across endpoints.',
        'status': 'Database tests: db/tests/tenant_isolation_tests.sql runs 41 cases (T1-T38) as the application role and the reporting role (cross-tenant reads, inserts, updates and deletes, global rows, the audit log, the binding procedure, login, lockout, MFA, session revocation, the platform audit read, column grants, policy coverage). CI step 7 in tools/ci/db_ci.sh runs them. With every policy switched off, the row-filter cases fail. One weakness is recorded as O-16.',
        'next': 'Add cross-tenant (IDOR) and no-context tests at the API level for every endpoint once the API exists. Resolve O-16 first.',
    },
    {
        'id': 'O-10', 'sources': REVIEW_B,
        'finding': 'wfl.Request has 22 foreign keys besides the tenant key, which can slow writes on the busiest table.',
        'status': 'Verified: every foreign key is indexed (509) or flagged noidx on purpose (70), with no gaps. On wfl.Request, 8 are indexed and 14 are noidx. Guard: tools/dbgen/check_fk_indexes.py.',
        'next': 'Keep the noidx choices; review them with Query Store once the schema runs on SQL Server.',
    },
    {
        'id': 'O-11', 'sources': f'{REVIEW_A}; {REVIEW_B}',
        'finding': 'Derived values (for example PctOfLimit) are computed on each read.',
        'status': 'Documented as derived in the model; not stored.',
        'next': 'Decide between persisted computed columns and a summary table after slice S3.',
    },
    {
        'id': 'O-12', 'sources': REVIEW_B,
        'finding': 'Numbering is required to be gap-free, which conflicts with rollbacks and concurrent writers.',
        'status': 'Closed. Decided by the owner (2026-10-12, docs/31-owner-decisions.md): numbers of requests and proformas are gap-free (Q-PLT-08, DQ-B02-4); other series may have gaps. Built in docs/adr/0005-document-numbering-and-reference-seeds.md: cfg.usp_AllocateNumber takes the counter row under an update lock inside the business transaction, so a rollback returns the number and the next request waits for the commit; a gap-free sequence is refused outside a transaction; a number is voided with a reason, never reused (db/static/039_numbering.sql). Tests N1 to N8 (db/tests/numbering_tests.sql, including AC-PLT-3) and a concurrency test (tools/ci/numbering_concurrency.sh: six connections, a quarter of the transactions rolled back, numbers 1 to N with no duplicate and no gap).',
        'next': 'Accepted cost: requests on one gap-free sequence are serialised until each commits, so the business transaction that takes a number must stay short (take the number last). Measure under load in S1.',
    },
    {
        'id': 'O-13', 'sources': REVIEW_A,
        'finding': 'Two cascade deletes exist in the organisation module. Credit and audit data must not be deleted by cascade.',
        'status': 'Closed (docs/adr/0006-kyc-history-and-cascade-deletes.md). The cascade from org.CompanyWealthSource to the KYC financial profile is removed: a profile is dated history and its removal is an explicit retention step. The cascade from pty.KycProfileItemLegalForm to its item stays, since a condition is part of its item, and items and conditions now change only while the profile is a DRAFT (db/static/041_kyc_profile_versions.sql, 50033). Rule R11 in tools/dbgen/check_grants.py refuses any other cascade. Tests K1 to K4 (db/tests/kyc_history_tests.sql).',
        'next': 'None. A new cascade needs a review and an entry in CASCADE_ALLOWED.',
    },
    {
        'id': 'O-15', 'sources': 'Execution on SQL Server 2025',
        'finding': 'Running the deployment exposed four defects that no static check had caught: a column named FreeText and a column named LineNo, which are T-SQL keywords, used unbracketed in CHECK text; a composite key whose linking enum column was VARCHAR(10) while the referenced column was VARCHAR(11); dynamic SQL built with EXEC(expression), which T-SQL rejects; and EXECUTE AS on a role, which SQL Server does not allow.',
        'status': 'Fixed. The generator brackets reserved column names in CHECK text and gives a linking enum column the type of the column it references (tools/dbgen/dbgen.py). The two static scripts use a variable for dynamic SQL, and the context procedure runs as the user tp_auth_exec, a member of role tp_auth (db/static/010, 020, 030).',
        'next': 'None. Keep running db/deploy.sql on every model change to catch the same class of error.',
    },
    {
        'id': 'O-14', 'sources': f'{REVIEW_A}; {REVIEW_B}',
        'finding': 'The vertical-slice plan (S0 to S5) gates the rest of the build.',
        'status': 'Planned in the analysis document; not started.',
        'next': 'Start S0 once O-01, O-02 and O-07 are decided.',
    },
    {
        'id': 'O-16', 'sources': 'Tenant-isolation tests (db/tests/tenant_isolation_tests.sql, case T16)',
        'finding': 'The application role can set TenantId directly with sp_set_session_context, which skips the membership check in sec.usp_SetSessionContext. Row-level security trusts the session context, so code that runs on the application connection outside the procedure can read or write another tenant. A DENY on the system procedure cannot be applied from a user database (error 4629).',
        'status': 'Closed by design (a), hardened after an adversarial review. Row filters (rls.fn_Bound, db/static/010_rls.sql) show a row only when the connection binding in sec.SessionBinding names the same tenant and its token matches SESSION_CONTEXT(N\'BindingToken\'); only sec.usp_SetSessionContext writes the binding (db/static/030_session_context.sql). The views check the binding (db/static/025_tenant_views.sql). Disabling a user, deleting a user, or closing a tenant revokes its bindings (triggers in db/static/030). Binding locks the tenant and user rows (OUT-01). Writes need an open tenant (BR-PLT-002), including DELETE. Tests T16 to T31 in db/tests/tenant_isolation_tests.sql cover these; a control with the binding check removed fails T16 and T16c.',
        'next': 'None for the context itself. O-17, O-18, O-19 and O-24 are closed; O-20 to O-22 are accepted low residual risks.',
    },
    {
        'id': 'O-17', 'sources': 'Design review of O-16 (db/static/030_session_context.sql); confirmed by CTX-02-KR and PRED-06 in the adversarial review',
        'finding': 'sec.usp_SetSessionContext trusts the user id that the application passes. A connection that can run the procedure binds to any tenant whose active user id it knows, and user ids are sequential. Confirmed: a refused user of tenant A is refused for tenant B (50003), and a scan of user ids binds to tenant B and reads its rows.',
        'status': 'Closed (decided by the owner 2026-10-12, docs/adr/0002-login-and-session-bound-context.md). sec.usp_SetSessionContext takes a session token and takes the user from the session. Sessions are created only by sec.usp_StartSession, which checks the password hash inside the database; the application role cannot read stored hashes, insert sessions or change a session token (db/static/020, 030). Tests T17 to T20 and T32 to T36 cover it.',
        'next': 'None for the binding. Residual risks within one tenant: O-24.',
    },
    {
        'id': 'O-18', 'sources': 'BR-PLT-002 (docs/10-detailed-analysis/10-m0-m1-platform-organization.md); adversarial review findings CTX-2, PRED-07, sb-02',
        'finding': 'Access to a SUSPENDED tenant does not follow BR-PLT-002. The procedure lets any active user bind to a SUSPENDED or ARCHIVED_READ_ONLY tenant, while the rule admits only the account administrator to a suspended tenant (read and export). An existing connection loses its rows when the tenant is suspended, but a new connection still reads them.',
        'status': 'Closed (decided by the owner 2026-10-12, option (a), DQ-F04-1; docs/adr/0003-account-security-in-the-database.md). sec.fn_TenantOpen and sec.fn_TenantLoginAllowed (db/static/030_session_context.sql): SUSPENDED admits the tenant administrator (system role TA) only, with no writes; CLOSED admits the TA for 30 days after ClosedAt; ARCHIVED_READ_ONLY admits no tenant user. A proven password refused by the status gets 50006 (DQ-F03-11). Tests T40 to T42.',
        'next': 'None. The application offers only export to a CLOSED tenant.',
    },
    {
        'id': 'O-19', 'sources': 'Adversarial review finding PRED-02',
        'finding': 'A tenant connection can insert audit rows with TenantId NULL. rls.fn_AuditWrite allows NULL, so a tenant can add rows that look like platform events: the platform reads them, the tenant cannot read them back.',
        'status': 'Closed (decided by the owner 2026-10-12, DQ-S01-5). rls.fn_AuditWrite admits TenantId NULL only for tp_platform and tp_auth (db/static/010_rls.sql). Test T44.',
        'next': 'None.',
    },
    {
        'id': 'O-20', 'sources': 'Adversarial review finding PRED-03',
        'finding': 'Foreign keys to mixed-scope tables ignore the row filters. A tenant row can reference another tenant\'s ref.UcpArticle: the insert succeeds, and the owner of the article gets error 547 when it deletes its own row. This is a reference and existence oracle across tenants. The generator writes a simple foreign key to a mixed table, not a tenant-composite one (tools/dbgen/dbgen.py).',
        'status': 'Accepted by the owner (2026-10-12) as a low residual risk, with an owner and a review before S2, after the application controls in DOC-S01 section 5 (DQ-S01-6).',
        'next': 'Add a check that the referenced row is global or belongs to the referencing row\'s tenant, for every foreign key from a tenant table to a mixed table, and test it.',
    },
    {
        'id': 'O-21', 'sources': 'Adversarial review findings PRED-01 and PRED-05',
        'finding': 'Unique keys are checked before the row filters and block predicates. A tenant connection can learn whether a value exists in another tenant: an e-mail (unique on TenantId and Email) and a PublicId. The insert of a row for another tenant returns 2627 rather than 33504.',
        'status': 'Accepted by the owner (2026-10-12) as a low residual risk, with an owner and a review before S2 (DQ-S01-6).',
        'next': 'Decide: route inserts that name another tenant through a procedure that takes TenantId from the binding, or accept the oracle as a residual risk with an owner.',
    },
    {
        'id': 'O-22', 'sources': 'Adversarial review findings OUT-02, sb-03, CTX-5, CTX-3 (fixed)',
        'finding': 'Open cursors keep delivering rows after revocation (OUT-02, STATIC and KEYSET cursors). A module owned by dbo could call the procedure through ownership chaining for tp_readonly (sb-03, latent: no such module exists). The procedure\'s error codes reveal the status of any tenant to any caller (CTX-5, low).',
        'status': 'Accepted by the owner (2026-10-12) as a low residual risk, with an owner and a review before S2 (DQ-S01-6). CTX-3 (a deleted user keeps its binding) is fixed by a delete trigger.',
        'next': 'Require the application to close cursors and reset the connection on revocation, forbid dbo-owned modules that call sec.usp_SetSessionContext, and decide whether the error codes should be unified.',
    },
    {
        'id': 'O-23', 'sources': 'Team decision on Linux (docs/adr/0001-schema-work-on-linux.md); Microsoft release notes for SQL Server 2025 on Linux (search summary, to verify)',
        'finding': 'The company servers run SUSE (SLES). SQL Server 2025 on Linux is supported on RHEL and Ubuntu only; SLES is listed through SQL Server 2022. The production VPS is a Linux server, and the owner has chosen Ubuntu 24.04 LTS for it (2026-10-12).',
        'status': 'Decided by the owner: Ubuntu 24.04 LTS on the external VPS. ADR 0001 matches it. FR-PLT-045 and decision 01 section 13 are updated for the database host (the application tier is unchanged). CI runs on Ubuntu 24.04 with the Ubuntu-based SQL Server 2025 container, and the full CI passed on it. The official Microsoft support page could not be opened from the sandbox; Ubuntu 24.04 support rests on search summaries only.',
        'next': 'Verify Ubuntu 24.04 support for SQL Server 2025 on the official Microsoft page. Provision the VPS (needs SSH access) and run tools/deploy/deploy.sh there. Close the open key-custody, data-residency and backup decisions before real data is loaded.',
    },
    {
        'id': 'O-24', 'sources': 'Design of O-17 (docs/adr/0002-login-and-session-bound-context.md)',
        'finding': 'Residual risks within one tenant after O-17. A bound application connection can still: update PasswordHash and the lockout counters (FailedAttempts, LockedUntil, Status) of a user of its own tenant; read sec.UserPasswordHistory.PasswordHash (offline cracking of earlier passwords); delete sec.LoginAttempt rows (the only login trace, since sec.usp_StartSession writes no aud.AuditLog row); read sec.MfaRecoveryCode.CodeHash; extend the idle expiry of a session; and clear EndedAt to reopen an ended session, which would undo a termination by an administrator. The TOTP check is trusted to the application (sec.usp_ConfirmMfa records its result and has no failure limit), and a user with MfaEnabled = 0 binds without MFA although FR-PLT-011 and BR-PLT-006 make MFA mandatory. The 12-hour absolute expiry is protected (DENY in 030, test T35). None of these crosses a tenant boundary. Threat model: docs/30-readiness/DOC-S01-threat-model.md.',
        'status': 'Closed for R1, R3, R4 and R5 (decided by the owner 2026-10-12, DQ-S03-5, DQ-S01-2, DQ-F03-1; docs/adr/0003-account-security-in-the-database.md). Password change and reset with the history rule, invitation, links, unlock, MFA enrolment and reset, recovery codes, user status, session touch and end are procedures run as tp_auth_exec (db/static/035_account_security.sql); tp_app is denied the direct rights, and an insert guard keeps new users INVITED without credentials. MFA is mandatory for every non-system user; TOTP failures, replayed steps and wrong recovery codes count toward the lockout. Tests T43, T45, T46 and A1 to A14 (db/tests/auth_flow_tests.sql).',
        'next': 'Kept as accepted residual risks (ADR 0003): the application sees raw link tokens because it sends the e-mail; the TOTP check runs in the application (R2). R6 is closed by docs/adr/0007-audit-written-by-the-database.md (DQ-F03-10): a trigger copies every login attempt into aud.AuditLog, so deleting attempts no longer removes the trace (test AU2).',
    },
    {
        'id': 'O-25', 'sources': 'ADR 0004 (docs/adr/0004-platform-access-jobs-and-onboarding.md)',
        'finding': 'Residual risks and gaps of the platform-side paths built in ADR 0004. The job worker login can bind any tenant as its service account for a catalogued job without a user session (it cannot use the administrator account procedures). Operator roles cannot be changed. The ISO seed sets the dial code and weekend for the six GCC states only; the other dial codes need an ITU source, and the GCC weekends are proposals to verify (Q-CAT-12). Closing an ACTIVE or SUSPENDED tenant is refused until the data export exists (DQ-F05-7). Trial dates use the UTC date.',
        'status': 'Open. The job login risk is proposed for acceptance with a named owner (DQ-F04-4); the rest is planned for S0 and S1. The procedures now write their own audit rows: onboarding, status changes, support and job bindings, and operator logins and accounts (docs/adr/0007-audit-written-by-the-database.md, tests AU1 to AU7, P11, J7). The ISO country and currency lists (DQ-B05-5) and the 138 permission codes (DQ-F07-1, DQ-F09-1) are now seeded (docs/adr/0005-document-numbering-and-reference-seeds.md). The export writes needed in SUSPENDED and CLOSED go through procedures, with the new job JOB-PLT-EXPORT (DQ-F04-8, docs/adr/0008-data-export-in-read-only-states.md, tests X1 to X6). The worker, the support connection, the web application and the operator panel have their own logins and secrets, one role each (docs/adr/0009-service-logins.md, checks LG1 to LG6).',
        'next': 'Chain the audit rows when FR-PLT-025 is built (S2); add the other dial codes from an ITU source; build the export package in the application and then lift the closing guard (FR-PLT-039, DQ-F05-7).',
    },
]
