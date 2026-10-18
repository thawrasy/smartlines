# ADR 0004: Operator login, support and job bindings, tenant onboarding and tenant settings in the database

Status: accepted by the owner (2026-10-12, docs/31-owner-decisions.md) for the decisions it implements: DQ-S03-6 and DQ-S04-14 (tenant security settings), DQ-S04-10 (operator accounts), DQ-F04-6 (support binding), DQ-F07-3 (first operator), DQ-B05-4 (STANDARD plan), and DQ-F05-2, DQ-F05-4, DQ-F05-6 and DQ-F05-7 (onboarding and tenant status). It also builds the proposals of DQ-F04-4 (job binding), DQ-F05-1, DQ-F05-5 and DQ-F17-2, whose deciders are the database and security architects, not the owner. It closes O-12 of docs/20-database-design.md for onboarding and support. It follows ADR 0002 and ADR 0003: every check that protects a tenant or an account runs inside the database, in procedures run as `tp_auth_exec`, and the application roles lose the direct rights.

## Context

- After ADR 0003 only a tenant user could bind a connection. Background jobs, temporary support and tenant creation had no path, which blocked FR-PLT-044, FR-PLT-007 and the S0 exit condition "a new tenant is onboarded automatically" (DOC-F05 section 7).
- Operators had no login in the database. A support binding that trusted the operator panel would repeat O-17 for operators.
- The operator panel (`tp_platform`) could write `plat.Tenant` and `plat.PlatformOperator` directly, including status, password and MFA columns.
- FR-PLT-043 lets a tenant tighten security settings within platform bounds; the procedures used fixed values.

## Decision

### 1. Tenant security settings (`db/static/028_tenant_settings.sql`)

- The platform seed (`db/seed/100_platform_global.sql`) defines six keys in `cfg.SettingDefinition` with default and bounds (DOC-S04 section 13): password minimum length and history count, lockout threshold, idle and absolute session timeouts, step-up freshness.
- `cfg.fn_SettingInt` gives the value the procedures use: the tenant's value held within the bounds, else the default. Login and touch use the tenant's timeouts, the lockout uses its threshold, and the history rule its count.
- The trigger `cfg.TR_TenantSetting_Bounds` refuses a value outside the bounds, a wrongly typed value, a key the tenant may not edit, and an undefined `security.*` key (50020).
- The history rule now counts the current password among the last N (BR-PLT-004); it was the current one plus N.
- JSON check constraints accept scalar values (`ISJSON(..., VALUE)`), as `jsonb` does in PostgreSQL, so a setting is stored as `15` or `"08:00"`.

### 2. Operator login and accounts (`db/static/036_operator_and_support.sql`)

- Login follows ADR 0002: `plat.usp_GetOperatorPasswordParams`, `plat.usp_StartOperatorSession` (hash compared inside, session token stored as SHA-256 in the new `plat.OperatorSession`, 15 minutes idle and 8 hours absolute), `plat.usp_ConfirmOperatorMfa` (TOTP mandatory, step replay refused), `plat.usp_TouchOperatorSession`, `plat.usp_EndOperatorSession`.
- Five failures within 15 minutes lock an operator until another operator administrator unlocks (`plat.usp_UnlockOperator`, never oneself).
- Accounts change only through procedures. `plat.usp_BootstrapOperator` creates the first operator administrator once, at deployment, as an invitation, so no password is ever in a script (DQ-F07-3). It is refused once any operator exists, and no role may execute it.
- The other account procedures:
  - `plat.usp_InviteOperator`: an operator administrator invites a new operator (48-hour link in the new `plat.OperatorToken`).
  - `plat.usp_CompleteOperatorSetup`: password and TOTP enrolment together, since an operator is never ACTIVE without MFA.
  - `plat.usp_ResetOperator`: another administrator clears the password and MFA and issues a 24-hour link. Operators have no recovery codes (DOC-S04 section 12).
  - `plat.usp_SetOperatorStatus`: never one's own account, and never below two active operator administrators.
- `tp_platform` loses INSERT on `plat.PlatformOperator`, UPDATE on its e-mail, role, status, credential and lock columns, and SELECT on the hash and the secret. It has no rights on operator sessions or links.

### 3. Support binding (DQ-F04-6)

- The support connection logs in as a member of `tp_support`, which is a member of `tp_readonly`. It reads without the restricted columns, writes nothing, and stays under the row filters.
- `sec.usp_SetSupportContext(@TenantId, @SupportAccessGrantId, @OperatorSessionToken, ...)` binds one tenant only when all of these hold:
  - the operator session is live and has a recorded MFA check, and the operator is ACTIVE;
  - the grant is this tenant's, for this operator, started, not ended, not revoked, and at most 72 hours long (BR-PLT-017);
  - the tenant is TRIAL or ACTIVE, or SUSPENDED with a grant made before the suspension (new column `plat.Tenant.SuspendedAt`, DOC-F04 section 7.4).
- `sec.SessionBinding` gains `BindingKind` (USER, JOB, SUPPORT) and `BoundOperatorId`.
- Triggers remove the support bindings when the grant changes, the operator session ends, or the operator leaves ACTIVE.

### 4. Job binding (DQ-F04-4, `db/static/037_job_context.sql`)

- `cfg.JobDefinition` is the closed catalogue of the 29 jobs of DOC-F17 section 5.2 plus the onboarding job, 30 in all (31 with JOB-PLT-EXPORT, ADR 0008), with the scope (TENANT or PLATFORM) and the tenant statuses each may run in (DOC-F04 section 7.4).
- The worker logs in as a member of `tp_jobs`, a member of `tp_app`.
- `plat.usp_ListTenantsForJobs` gives the tenants a job runs for: id, status and time zone.
- `sec.usp_SetJobContext` binds as the tenant's active service account, for a catalogued tenant job, in an allowed status. UserId, JobKey and CorrelationId are read-only.
- The administrator account procedures of ADR 0003 now require a USER binding (`sec.fn_BoundAsUser`). A job binding has the application's rights and could otherwise reset an administrator's MFA and issue links.

### 5. Tenant onboarding and status (`db/static/038_tenant_onboarding.sql`)

- **Stage A, `plat.usp_CreateTenant`.** An operator administrator with an MFA check in the last 5 minutes (step-up) creates, in one transaction:
  - the tenant: TRIAL for 30 days, with a lower-case code; reserved codes are refused (50025) and used codes too (50026);
  - its modules from the plan, with CORE;
  - the service account and the first administrator (INVITED, no password);
  - the event `tenant.created`.
- **Stages B and C.** The onboarding job (JOB-PLT-ONBOARD) seeds the packs in the application (FR-PLT-008), then calls `sec.usp_InviteFirstAdministrator`. That procedure gives the first administrator the TA role and an invitation link once the roles exist. Called again, it replaces an unused link, and it refuses a second administrator.
- **Status changes.** All transitions go through one internal procedure with the table in DOC-F05 section 6.2:
  - `plat.usp_SetTenantStatus` for an operator administrator with a fresh MFA check;
  - `plat.usp_RunTenantTransitions` for the daily jobs JOB-PLT-TRIAL-EXPIRE and JOB-PLT-ARCHIVE.
  Suspension needs a reason and ends the sessions the new status no longer admits. SUSPENDED may go back to TRIAL with a new end date (DQ-F05-6). A cancelled TRIAL closes (DQ-F05-4). Closing an ACTIVE or SUSPENDED tenant is refused until the data export exists (DQ-F05-7, 50027). Each change writes `tenant.status_changed`.
- `tp_platform` loses INSERT on `plat.Tenant` and UPDATE on its code, status and status dates (DQ-F05-5).
- The platform seed adds the STANDARD plan with every module (DQ-B05-4) and 23 reserved sub-domains, a proposal for OPS with SEC.

### 6. Transactions

Every procedure that writes takes a savepoint when its caller already holds a transaction, and rolls back to it on failure. Before this, a refusal after the first write left the partial change in the caller's transaction (found by test P5). The checks of `plat.usp_SetOperatorStatus` and `sec.usp_CompleteMfaEnrolment` also moved before their first write.

### Error numbers added

| Code | Meaning |
|---|---|
| 50020 | Tenant setting outside the bounds |
| 50021 | Operator administrator with MFA required (with a fresh check for onboarding and status) |
| 50022 | No active support grant |
| 50023 | Operators already exist |
| 50024 | Unknown or platform job |
| 50025 | Reserved code |
| 50026 | Code in use |
| 50027 | Closing waits for the data export |
| 50028 | Roles not seeded, or the first administrator already chosen |

## Consequences

- **Tests.** Every case passes in CI (`tools/ci/db_ci.sh` steps 4b and 8 to 11):
  - S1 to S6 in `db/tests/auth_flow_tests.sql`;
  - P1 to P10 in `db/tests/operator_support_tests.sql`;
  - J1 to J7 in `db/tests/job_context_tests.sql`;
  - O1 to O5 in `db/tests/tenant_onboarding_tests.sql`;
  - the seed check, which runs the platform seed twice and expects nothing to change.
- **Deployment.** It must create the first operator with `plat.usp_BootstrapOperator` and send its link. The worker and the support connection need their own logins, in `tp_jobs` and `tp_support`, whose secrets the web server never holds (DOC-S08); built in ADR 0009 (`tools/deploy/provision_logins.sh`).
- **Application.** The panel calls `plat.usp_ConfirmOperatorMfa` again right before creating a tenant or changing its status.

Residual risks and open points:
- **Job worker login (DQ-F04-4 proposes accepting it with a named owner).** Whoever holds it can bind any tenant as its service account for a catalogued job, without a user session. It cannot use the administrator account procedures.
- **Link e-mails.** The application, the panel and the worker send them, so they see raw link tokens (as in ADR 0003).
- **Audit rows.** ~~The procedures write events to `cfg.OutboxEvent` but no audit rows.~~ Built in ADR 0007: onboarding, status changes, support and job bindings, and operator logins and accounts write their audit rows in the same transaction.
- **Dates.** `TrialEndsOn` and the trial expiry use the UTC date; the tenant's time zone can move them by a day.
- **Not built yet:**
  - changing an operator's role;
  - the package builder of the data export (FR-PLT-039, application), which closing an active tenant waits for. The export's database side, with the writes jobs need in SUSPENDED and CLOSED (DQ-F04-8), is built in ADR 0008.

Built since, in ADR 0005: the ISO country and currency lists (DQ-B05-5) and the 138 permission codes (DQ-F07-1, DQ-F09-1) in the platform seed, and gap-free document numbering (O-12 of tools/dbgen/erd_open_items.py).
