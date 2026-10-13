# ADR 0007: The database audits the security and platform events of its own procedures

Status: decided by the database architect. It builds the proposal of DQ-F03-10, whose decider is the database architect, and needs no owner decision. It closes R6 of O-24 and the audit gap of O-25 (tools/dbgen/erd_open_items.py). It follows ADR 0003 and ADR 0004.

## Context

- FR-PLT-022 requires an audit row for logins, logouts, failures, lockouts and permission changes. BR-PLT-009 makes support access, MFA resets and sensitive permission grants high severity.
- The procedures of 030 and 035 to 038 change accounts, sessions, bindings and tenants. Until now they wrote no audit row:
  - `sec.LoginAttempt` was the only trace of a login, and the application may delete its rows (R6 of O-24);
  - many of these events happen before any binding (login, MFA, password reset by link, invitation), where `rls.fn_AuditWrite` refuses a tenant row from the application;
  - operators have no tenant at all;
  - the audit of onboarding, status changes, and support and job bindings rested on the application (O-25).

## Decision

1. **One internal writer.** `aud.usp_WriteEvent` (`db/static/029_audit_writer.sql`) writes one `aud.AuditLog` row.
   - It runs as its caller. The procedures run as `tp_auth_exec`, which the write filter admits.
   - No role may execute it, and `tp_auth` gains no right: the ownership chain covers the insert.
   - The actor is given as a user or operator id and stored as that account's PublicId.
   - The client address and the correlation id default to the binding's context keys.
2. **Same transaction.** Each procedure writes its row in the transaction of the change, so the event and its row commit or roll back together. Logout and unlock procedures that wrote without a transaction now use the savepoint pattern.
3. **Logins through a trigger.** `sec.TR_LoginAttempt_Audit` copies every login attempt into the audit log: success, wrong password, refused lock or tenant, MFA or recovery-code failure, lockout. Deleting attempts no longer removes the trace, because nobody may update or delete `aud.AuditLog`.
4. **Tenant rows and platform rows.**
   - A tenant row (TenantId set) is what the tenant's audit viewer shows. It covers the tenant's accounts and sessions, the support binding (so the tenant sees which operator entered its data), job bindings and the first administrator's invitation.
   - Operator accounts, operator logins, tenant creation and tenant status changes are platform rows (TenantId NULL), for the operators only.
5. **Nothing secret in a row.** No row holds a password hash, a token, a secret or an e-mail address. An attempt with an unknown address has no actor, and an anonymous reset request records only the account it is for.

### Events

| Where | Action | Category | Severity |
|---|---|---|---|
| Trigger on `sec.LoginAttempt` | LOGIN_SUCCESS, FAILED_PASSWORD, DENIED_LOCKED, DENIED_TENANT, FAILED_MFA, LOCKOUT | SECURITY | INFO |
| 035, before binding | MFA_ENROLLED, RECOVERY_CODE_USED, LOGOUT, PASSWORD_CHANGED, PASSWORD_RESET_REQUESTED, PASSWORD_RESET, INVITATION_ACCEPTED | SECURITY | INFO |
| 035, administrator | SESSION_TERMINATED, LINK_ISSUED, USER_UNLOCKED, USER_STATUS_CHANGED | SECURITY | INFO |
| 035, administrator | MFA_RESET | SECURITY | HIGH |
| 036, support | SUPPORT_ACCESS_BOUND (tenant row) | SECURITY | HIGH |
| 036, operators (platform rows) | OPERATOR_LOGIN_SUCCESS, OPERATOR_LOGIN_FAILED, OPERATOR_LOGIN_DENIED, OPERATOR_MFA_FAILED, OPERATOR_LOGOUT, OPERATOR_UNLOCKED, OPERATOR_SETUP_COMPLETED, OPERATOR_STATUS_CHANGED | PLATFORM | INFO |
| 036, operators (platform rows) | OPERATOR_LOCKOUT, OPERATOR_BOOTSTRAPPED, OPERATOR_INVITED, OPERATOR_RESET | PLATFORM | HIGH |
| 037 | JOB_BOUND, with the JobKey and the service account as actor | SYSTEM | INFO |
| 038 | FIRST_ADMIN_INVITED (tenant row, actor the onboarding job) | CONFIG | HIGH |
| 038 (platform rows) | TENANT_CREATED; TENANT_STATUS_CHANGED with the old and new status and the reason | PLATFORM | HIGH for SUSPENDED, CLOSED and ARCHIVED_READ_ONLY, else INFO |

## Consequences

- **Tests.** All pass in CI (`tools/ci/db_ci.sh`):
  - AU1 to AU7 in `db/tests/audit_trail_tests.sql` (step 16): login outcomes; attempts deleted while their rows stay; administrator actions; logout and reset; operator events; a tenant's life; who reads which rows; no address or hash in any row;
  - P11 (step 9): the support binding's row;
  - J7 (step 10): the job binding's row.

  With the login trigger disabled, AU1 fails.
- **Application.** It still writes the rows of what it does itself: treasury data, reveals and exports (`aud.SensitiveAccessLog`), audit viewing, and support page views by the operator panel (DOC-F04). It no longer writes the rows of the events above, which would double them.
- **Volume.** Every job binding writes a row (DOC-F04 section 5.2). A worker that binds every minute per tenant writes about 1,440 rows a day per job and tenant. It should bind once per batch, and the retention of DOC-S12 section 5.1 applies.
- **Hash chain.** `ChainSeq`, `PrevHash` and `RowHash` stay empty until FR-PLT-025 is built in S2. Its writer must then chain these rows too, which is simpler now that they come through one procedure and one trigger.
- **Not covered.**
  - A refused support or job binding, or a refused administrator action, writes no row. The procedure stops before writing, and a row written there would roll back with the refusal unless it were committed first, as the login procedures do.
  - Tenant status changes are platform rows only; the tenant learns them from its status and the event `tenant.status_changed`.
