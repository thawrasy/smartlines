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
        'status': 'Open decision. The analysis document does not name the algorithm.',
        'next': 'Record the algorithm and parameters in the security section of the analysis document.',
    },
    {
        'id': 'O-02', 'sources': f'{REVIEW_A}; {REVIEW_B}',
        'finding': 'The schema has never run on SQL Server 2025.',
        'status': 'Executed on SQL Server 2025 (RTM-CU9): db/deploy.sql runs to completion and the deployed counts match the DDL (194 tables, 20 schemas, 763 foreign keys, 515 unique constraints, 1,158 CHECK constraints, 700 indexes). A CI gate runs the same steps on every change to db/, tools/dbgen/ or tools/ci/ (tools/ci/db_ci.sh, .github/workflows/db-ci.yml). The gate has passed locally; its first run on GitHub is pending. Not yet run on the production server.',
        'next': 'Check the first GitHub run in the Actions tab, then run db/deploy.sql on the target Windows server.',
    },
    {
        'id': 'O-03', 'sources': f'{REVIEW_A}; {REVIEW_B}',
        'finding': 'Lender shares must total 100 per facility and at most one lender may hold the AGENT role. The model says the application checks both.',
        'status': 'Trigger in db/static/050_fac_share_rule.sql, deployed by db/deploy.sql. Six tests pass on SQL Server 2025 (db/tests/fac_share_rule_tests.sql): valid approval, rejected total above 100, rejected approval without lenders for the new revision, valid new revision, rejected second agent, and a partial draft accepted.',
        'next': 'Add the test script to CI. Decide the behaviour for a lender change after approval, which the trigger currently rejects.',
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
        'status': 'Open. The analysis document marks them UNVERIFIED.',
        'next': 'Check each article number against the official text and record the result.',
    },
    {
        'id': 'O-07', 'sources': f'{REVIEW_A}; {REVIEW_B}',
        'finding': '155 open questions are answered with default values.',
        'status': 'Listed in docs/10-detailed-analysis/90-consolidated-open-questions.md. Defaults are in use.',
        'next': 'Assign an owner and a review date to each question; resolve the critical ones before slices S0 to S2.',
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
        'status': 'Database tests: db/tests/tenant_isolation_tests.sql runs 24 cases as the application role and the reporting role (cross-tenant reads, inserts, updates and deletes, global rows, the audit log, the context procedure, column grants, policy coverage). CI step 7 in tools/ci/db_ci.sh runs them. With every policy switched off, the row-filter cases fail. One weakness is recorded as O-16.',
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
        'status': 'Open. Range allocation is proposed; no decision recorded.',
        'next': 'Legal and operational decision on whether gaps are acceptable, then a numbering design.',
    },
    {
        'id': 'O-13', 'sources': REVIEW_A,
        'finding': 'Two cascade deletes exist in the organisation module. Credit and audit data must not be deleted by cascade.',
        'status': 'Open. The two cascade rules are in db/model/11-organization-party.model and have not been reviewed against this rule.',
        'next': 'Review the two rules; replace cascade with archive or close where the data is credit or audit data.',
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
        'status': 'Closed by design (a). The row filters (rls.fn_Bound, db/static/010_rls.sql) show a row only when the connection binding in sec.SessionBinding names the same tenant and its token matches SESSION_CONTEXT(N\'BindingToken\'). Only sec.usp_SetSessionContext writes the binding (db/static/030_session_context.sql). Tests T16, T16b and T16c in db/tests/tenant_isolation_tests.sql cover a direct context change, the binding table, and a wrong or missing token.',
        'next': 'None for the context itself. The residual risk is recorded as O-17.',
    },
    {
        'id': 'O-17', 'sources': 'Design review of O-16 (db/static/030_session_context.sql)',
        'finding': 'sec.usp_SetSessionContext trusts the user id that the application passes. A compromised application connection can bind to any tenant whose active user id it knows, and user ids are sequential.',
        'status': 'Open decision. The binding (O-16) stops a forged context, but not a call to the procedure with another user\'s id.',
        'next': 'Decide whether the procedure verifies a server-side session token instead of the caller\'s user id (sec.UserSession.TokenHash is already in the model). Recommended. Then add a test that a wrong token is refused.',
    },
]
