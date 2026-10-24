# ADR 0048: Sign-in names, temporary passwords, product scope and the two-step switch

Status: accepted on 2026-10-24 at the owner's request (docs/31, row 46). Written by an AI agent.

## Context

S0 built one way in: the tenant's sub-domain, the e-mail, a password set from an invitation link, and two-step
verification for every user (ADR 0003). The owner asked for the following (docs/31 row 46):

- the company's code;
- a user identifier the company allows: an employee code, a mobile number or the official e-mail;
- users created either by an invitation e-mail or by a predefined identity with a temporary password, changed at the
  first sign-in, the choice being the company's;
- every employee limited to some companies and some products;
- two-step verification built but switched by the platform administration, off for the trial.

Options are settings, not code (row 45).

## Decision

- **The company code.** The tenant stays chosen by the host, never by the request body (FR-PLT-046). The code is the
  sub-domain. A common page on the bare domain (or `www.`, `app.`, `login.`) asks for the company code and goes to
  `{code}.{domain}/login`. The login page shows the code it belongs to.
- **Sign-in names.**
  - `sec.AppUser` gains `EmployeeCode` (2 to 30 Latin letters, digits, `.`, `_` or `-`) and `Mobile` (international
    form `+…`). Each is unique in the tenant.
  - `sec.fn_LoginUser` finds the user by the e-mail, the employee code or the mobile, as the tenant's
    `security.login.identifiers` allows (default `EMAIL,EMPLOYEE_CODE,MOBILE`).
  - A mobile number is compared without spaces, dashes or brackets, and `00` is read as `+`.
  - A name that matches more than one user matches none, and gets the same answer as an unknown name.
  - The login, the password parameters and the reset request all use the function. The reset link still goes to the
    account's e-mail.
- **Temporary password.**
  - `security.user.creation` (default `INVITATION,TEMP_PASSWORD`) says which ways an administrator may use.
  - For a temporary password, the API generates a random password of at least 19 characters, or the tenant's minimum
    if longer, from characters that cannot be confused. `sec.usp_SetTemporaryPassword` stores its Argon2id hash and
    sets `MustChangePassword`. The plain value is shown once to the administrator and is never stored or sent.
  - Setting one needs `sec.user.manage` and a fresh proof (step-up), is recorded HIGH, and ends the user's links and
    sessions. It is never for one's own account.
  - A session with `MustChangePassword` does not bind (`sec.usp_SetSessionContext`). The user changes the password
    first through `POST /auth/password-change`, which applies the tenant's rules, the breached list and the history.
- **The two-step switch.**
  - `security.mfa.required` is a platform setting (`IsTenantEditable = 0`), `false` for the trial, inserted once and
    never reset by a deployment. `plat.Tenant.MfaPolicy` (`PLATFORM`, `REQUIRED`, `OFF`) overrides it for one tenant.
  - Both are set only by an operator administrator with a fresh code, in the panel (Security page; tenant page), and
    both are audited.
  - A user who enrolled is always asked (`sec.usp_StartSession`).
  - `sec.UserSession.MfaRequired` records the answer at sign-in. The binding admits a session without a TOTP check
    only while MFA is still not required of the user now, so switching it on stops such sessions at their next
    request.
  - A user without MFA, where it is not required, steps up with the password (`sec.usp_ConfirmPasswordStepUp`), and a
    wrong password counts toward the lockout. An enrolled user steps up with TOTP as before. A user may enrol of
    their own accord.
  - `sec.usp_GetSessionStep` tells the API what comes next: `MFA_ENROLMENT_REQUIRED`, `MFA_REQUIRED`,
    `PASSWORD_CHANGE_REQUIRED` or `DONE`.
- **Product scope.**
  - `sec.AppUser.ProductScopeMode` (`ALL` by default, or `SELECTED`) and `sec.UserProductScope (UserId, ModuleCode)`.
    CORE is always in.
  - `BoundUser.ModuleEnabledAsync` requires the module to be enabled for the tenant and in the user's scope, so every
    endpoint that checks a module checks the user too, and `/me` lists only those modules.
  - The scope narrows the roles. It never widens them.

## Consequences

- ADR 0003's "MFA for every user, no tenant switch" is replaced by the platform switch above.
- The S0 tests that need two-step verification set the tenant's policy to REQUIRED: the integration fixture, the
  database tests and the browser test.
- The new paths are tested in `SignInTests` and in `db/tests/auth_flow_tests.sql` A18 to A21.
- An employee without an e-mail is not modelled yet. `Email` stays required, because the links and the notifications
  go to it. A company that gives none can enter its official addresses.
- The product scope works where a module is checked today: institutions, facilities, covenants, workflow, requests
  and letters of credit. A module checked nowhere yet (reports) is gated when its endpoints come.
- No migration script: the release is still the baseline (db/migrations/README.md).
