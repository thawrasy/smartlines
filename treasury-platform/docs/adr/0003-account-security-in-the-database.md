# ADR 0003: Account lifecycle, mandatory MFA and tenant-status access in the database

Status: accepted by the owner (2026-10-12, docs/31-owner-decisions.md section 1.1, items 1 to 4). Extended by ADR 0004. It implements DQ-F03-1, DQ-F03-4, DQ-F03-8, DQ-F03-11, DQ-F04-1 (O-18), DQ-S01-3, DQ-S01-5 (O-19), DQ-S03-5 (O-24 R1, R3, R4, R5), DQ-S04-9 and DQ-S04-11. It extends ADR 0002, which stays in force for passwords, sessions and the binding.

## Context

- ADR 0002 moved login and binding into the database: a connection binds only with a session of the tenant, and a session needs the password. Inside one tenant the application role could still set a password, clear a lockout, read password-history and recovery-code hashes, reopen or extend a session, and bind a user without MFA (O-24).
- BR-PLT-002 limits who may enter a tenant that is not TRIAL or ACTIVE. The binding admitted every active user of a SUSPENDED tenant (O-18).
- A tenant connection could write audit rows with TenantId NULL, which look like platform events (O-19).
- The owner decided to close these before login code is written in S0, with narrow procedures on the ADR 0002 pattern (DQ-F03-1), and made MFA mandatory for every non-system user, with no tenant switch (DQ-F03-4, DQ-S04-11).

## Decision

### 1. Tenant status and role (O-18, DOC-F04 section 7.4)

| Tenant status | Who may log in and bind | Writes |
|---|---|---|
| TRIAL, ACTIVE | every active user | yes |
| SUSPENDED | the tenant administrator only (system role TA) | no: read and export |
| CLOSED, less than 30 days after ClosedAt | the tenant administrator only | no: export only (the application offers nothing else) |
| CLOSED after 30 days, ARCHIVED_READ_ONLY | no tenant user | no |

`sec.fn_TenantOpen` gives the statuses that admit anyone; `sec.fn_TenantLoginAllowed` adds the TA rule (`db/static/030_session_context.sql`). `usp_StartSession`, `usp_SetSessionContext` and the pre-login procedures in 035 use them. Writes still need `rls.fn_BoundWrite` (TRIAL or ACTIVE). A status change away from TRIAL or ACTIVE still removes every binding at once (trigger `plat.TR_Tenant_RevokeBinding`), so a TA who stays must bind again.

Errors (DQ-F03-11): every failure before the password is proven returns 50005. Only a user who proved the password and is refused by the table above gets 50006, and the attempt is logged as DENIED_TENANT. An unknown or closed tenant fails as NO_TENANT before the password is read.

### 2. Mandatory MFA (DQ-F03-4, DQ-S01-3, DQ-S04-11)

- `usp_StartSession` always returns `@MfaRequired = 1`, and `@MfaEnrolmentRequired = 1` when the user has no MFA yet.
- `usp_SetSessionContext` binds only a session with `MfaVerifiedAt` set, for a user with `IsSystemUser = 0`. Service accounts never bind through it: they will bind through a job procedure (DQ-F04-4, not built yet).
- The application verifies the TOTP code (the secret's key stays in the application, BR-PLT-015) and passes the result and the code's time step to `usp_ConfirmMfa`. A step not after `MfaLastUsedStep` is a replay and counts as a failure.
- Failed TOTP checks and wrong recovery codes count toward the same lockout as passwords (BR-PLT-005): five failures in 15 minutes lock the account for 15 minutes, and the third lockout in 24 hours needs an administrator. A lockout during the MFA step ends that session (EndReason MFA_FAILED). Service accounts are never counted, so nobody can lock them by guessing.

### 3. Procedures (`db/static/035_account_security.sql`)

All run as `tp_auth_exec`. tp_app may execute the public ones only; `usp_RecordAuthFailure`, `usp_ResolvePasswordActor` and `usp_ApplyNewPassword` are internal.

| Caller state | Procedure | What it does |
|---|---|---|
| none | `usp_ResolveTenant(@Code)` | sub-domain code to TenantId and status (FR-PLT-046) |
| session waiting for MFA | `usp_GetMfaChallenge` | the encrypted TOTP secret and last step, or the flag that enrolment (or re-enrolment) is needed |
| session waiting for MFA | `usp_CompleteMfaEnrolment` | stores the encrypted secret, the step of the verified code and ten recovery-code hashes; marks the session verified. After an MFA reset it needs the e-mailed MFA_REENROLMENT link (50013) |
| session waiting for MFA | `usp_UseRecoveryCode` | a single-use code instead of TOTP; a wrong code counts as a failure (50009) |
| live session | `usp_TouchSession` | extends the idle expiry (30 minutes) up to the absolute expiry (12 hours) |
| own session, or bound administrator | `usp_EndSession` | logout by token (LOGOUT), or another session of the tenant by id (TERMINATED_BY_ADMIN, EndedBy from the binding) |
| live verified session, or reset link | `usp_GetPasswordHistoryParams` | the Argon2id parameters and salts of the current password and the last five, without hashes |
| live verified session | `usp_ChangePassword` | proves the current password (a wrong one counts as a failure, 50010), applies the history rule, ends the user's other sessions |
| none | `usp_RequestPasswordReset` | a 30-minute link for a known active or locked user; an unknown address gets NULL and no error |
| reset link | `usp_ResetPassword` | history rule, every session ended, a temporary lock cleared; an administrator's lock stays (DQ-S04-12) |
| invitation link | `usp_CompleteInvitation` | sets the first password once; INVITED becomes ACTIVE; MFA enrolment follows at the first login |
| bound with write access | `usp_IssueUserToken` | INVITATION (48 hours), PASSWORD_RESET (30 minutes) or MFA_REENROLMENT (24 hours, DQ-F03-8) link for a user of the tenant |
| bound with write access | `usp_UnlockUser` | lifts any lock, including the third lockout (50018 if not locked) |
| bound with write access | `usp_ResetMfa` | clears the secret and recovery codes and ends the sessions (MFA_RESET); the user re-enrols with a link |
| bound with write access | `usp_SetUserStatus` | DISABLED, ACTIVE (from DISABLED with a password) or ARCHIVED; never one's own account (50019); disabling ends the sessions |

Links: the application generates a random token of at least 32 bytes and sends it by e-mail; the database stores only its SHA-256. Issuing a new link revokes the user's unused links of the same purpose.

History rule (BR-PLT-004): the database never returns a stored hash. The application hashes the new password under each parameter set from `usp_GetPasswordHistoryParams` and passes the results as a JSON array. The procedure refuses the change if a stored set has no candidate (50015) or a candidate equals a stored hash (50011), then keeps the last five.

The application still checks the permission code of an administrator action (`sec.user.manage`, DOC-F07). The database checks that the caller is bound to the tenant with write access and that the target user belongs to it.

### 4. Direct rights removed (O-24 R1, R3, R4, R5)

After the generated grants (007), 030 and 035 deny tp_app:
- SELECT on `sec.AppUser.PasswordHash` and `MfaSecretEnc`; UPDATE on every status, password, MFA, lockout, last-login and archive column of `sec.AppUser`.
- INSERT and UPDATE on `sec.UserSession` (start, MFA mark, touch and end go through procedures).
- SELECT on `sec.UserPasswordHistory.PasswordHash` and INSERT on the table.
- SELECT on `sec.MfaRecoveryCode.CodeHash`, INSERT and UPDATE on the table.
- INSERT on `sec.UserToken` and UPDATE on its identity, purpose, hash, expiry and use columns.

tp_app keeps INSERT on `sec.AppUser` for user creation, but the trigger `sec.TR_AppUser_InsertGuard` refuses a new user that has a password, MFA, a status other than INVITED, or lockout state (50012). A new user therefore enters only through the invitation link.

### 5. Audit rows without a tenant (O-19)

`rls.fn_AuditWrite` admits TenantId NULL only for tp_platform and tp_auth. A tenant connection writes audit rows of its own tenant only (`db/static/010_rls.sql`).

### Error numbers

50001 arguments, 50002 unknown or closed tenant, 50003 no valid session or not bound, 50004 already bound, 50005 invalid e-mail or password, 50006 tenant not available to this user, 50008 MFA enrolment required, 50009 invalid recovery code, 50010 current password wrong, 50011 password used recently, 50012 direct insert of a privileged user, 50013 re-enrolment link required, 50014 ten recovery-code hashes required, 50015 history candidates incomplete, 50016 link cannot be issued, 50017 invalid or expired link, 50018 user not locked, 50019 status change not allowed.

## Consequences

- Tests: tenant isolation T40 to T46 (tenant status, 50006, MFA before binding, O-19, the DENYs, service accounts) in `db/tests/tenant_isolation_tests.sql`, and A1 to A14 in `db/tests/auth_flow_tests.sql` (insert guard, invitation, first enrolment, TOTP replay, MFA lockout, recovery codes, password change and reset, administrator actions, status, sessions, internal procedures, the full path to a bound connection). `tools/ci/db_ci.sh` runs both.
- The application must name the columns it reads from `sec.AppUser`, `sec.UserPasswordHistory` and `sec.MfaRecoveryCode`: `SELECT *` and `COUNT(*)` fail with error 230 because some columns are denied.
- The application performs every password, MFA, link and status change through the procedures above. Every pre-login procedure takes the tenant from the sub-domain (`usp_ResolveTenant`), never from the browser.

Residual risks (accepted, within one tenant):
- The application sends each link by e-mail, so it sees the raw token. A fully compromised application server can still take over an account through a reset link; the user is told by e-mail and the action is logged. What is closed is change through table rights.
- The TOTP check runs in the application, which holds the key (R2, accepted in DOC-S03 section 12). The database adds the replay check and the failure limit.
- `sec.LoginAttempt` is still the only login trace, and tp_app may still delete its rows (R6). The proposal in DQ-F03-10 (procedures also write `aud.AuditLog`, tp_auth gets INSERT on it) is not decided yet.

Built since, in ADR 0004: per-tenant session timeouts, lockout threshold and history count from `cfg.TenantSetting` (DQ-S03-6, DQ-S04-14; the history rule now counts the current password among the last N), the support binding (DQ-F04-6) and the job binding (DQ-F04-4). The administrator procedures above now require a USER binding (`sec.fn_BoundAsUser`), so a job or support binding cannot use them, and each writing procedure undoes only its own work when the caller holds a transaction.

Not built yet, recorded for S0: a link check before the form is shown (`usp_CheckUserToken`, DQ-F03-5), the five-minute limit on a session waiting for MFA (DQ-F03-2) and rehashing with stronger parameters (DQ-S04-3).
