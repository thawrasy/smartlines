# ADR 0002: Login and session-bound tenant context in the database

Status: accepted by the owner (2026-10-12). Closes O-01 (password hashing) and O-17 (the context procedure trusted the caller's user id).

## Context

- Row-level security trusts the connection binding (ADR on O-16, `db/static/010_rls.sql`). The binding was made by `sec.usp_SetSessionContext`, which took a user id from the application. A connection that could run the procedure could bind to any tenant whose user id it knew (O-17, confirmed by the adversarial review).
- Moving the check to a session token only helps if creating a session also needs proof that the user knows the password. Otherwise the gap moves from binding to login.
- The password hash algorithm was not recorded (O-01). Review B recommended Argon2id.

## Decision

Passwords:
- Argon2id, stored as a PHC string (`$argon2id$v=19$m=...,t=...,p=...$salt$hash`). Minimum parameters: 64 MB memory (m=65536), 3 iterations (t=3), 4 lanes (p=4). Stronger parameters may be used later; the stored string carries its own.
- The database enforces the algorithm and format with a CHECK on `sec.AppUser.PasswordHash`, `sec.UserPasswordHistory.PasswordHash` and `plat.PlatformOperator.PasswordHash`. The parameters are not enforced by the CHECK, so an upgrade does not need a schema change.

Login and binding (all procedures run as `tp_auth_exec`, `db/static/030_session_context.sql`):
1. `sec.usp_GetPasswordParams(@TenantId, @Email)` returns the PHC string without the hash (algorithm, parameters, salt). NULL for an unknown user; the application then answers as for a wrong password.
2. The application computes Argon2id of the typed password with those parameters and builds the PHC string.
3. `sec.usp_StartSession(@TenantId, @Email, @PasswordHash, @SessionToken, ...)` compares that string with the stored one inside the database (binary comparison, because base64 is case-sensitive and the database collation is not). It applies the lockout rules (five failures in 15 minutes lock for 15 minutes; the third lockout in 24 hours needs an administrator), logs every attempt, and on success stores the SHA-256 of the random session token (at least 32 bytes) with a 30-minute idle and a 12-hour absolute expiry. It returns one error (50005) for every failure.
4. If the user has MFA, the application verifies the TOTP code and records the result with `sec.usp_ConfirmMfa(@TenantId, @SessionToken, @Passed)`.
5. For each request, `sec.usp_SetSessionContext(@TenantId, @SessionToken)` finds a valid session for that tenant (not ended, not expired, active user, MFA recorded when required), takes the user from the session, and binds the connection.

Grants (`db/static/020_roles_and_grants.sql`): the application role cannot read stored password hashes, cannot insert sessions, and cannot change a session's tenant, user, token or MFA mark.

Revocation: ending or deleting a session, disabling or deleting a user, and closing or suspending a tenant remove the matching bindings at once (triggers in 030).

## Consequences

- A connection can bind to a tenant only with a valid session of that tenant, and it can create a session only with the user's password. Tests T17, T18, T19, T20 and T32 to T36 in `db/tests/tenant_isolation_tests.sql` cover this.
- The application must keep the session token secret (cookie or equivalent) and pass it on every bind. The pool's `sp_reset_connection` clears the context between requests.
- Residual risks within one tenant are recorded as O-24: the application role can still update `PasswordHash` (password change and reset flows), the TOTP check is trusted to the application, and the application extends the idle expiry.
- The login API must not reveal whether an e-mail exists (FR-PLT-012), because `usp_GetPasswordParams` returns NULL for an unknown user.
