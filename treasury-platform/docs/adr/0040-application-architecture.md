# ADR 0040: The application of phase 2 and the database gaps it needed

Status: decided on 2026-10-21 (owner decision 37 in docs/31). The owner chose React with TypeScript for the front
end and the whole of S0 as the first batch. The S0 brief listed the database contract, the sequences and the gaps;
this ADR records how the application is built on that contract and what changed in the database for it.

## Context

The database already holds every security rule it can: passwords are compared inside it, sessions are stored as
SHA-256 of the token, a connection is bound to one user and tenant by `sec.usp_SetSessionContext`, and the row
filters keep each tenant apart. The application has to do what the database cannot:

- hash passwords with Argon2id;
- check TOTP codes;
- encrypt the MFA secrets with the tenant keys, which are wrapped by a master key outside the database;
- send the e-mails;
- run the jobs.

The brief found that thirteen S0 flows had no database support (GAP-1 to GAP-17). The eight below blocked the first
milestone: an operator creates a tenant, the worker prepares it, and its first administrator signs in with MFA.

## Decision

### 1. Stack and projects

All projects live in `treasury-platform/app`, on .NET 10 (`global.json` pins the SDK).

| Project | What it is |
|---|---|
| `BankFas.Core` | The security primitives, with no database or web dependency |
| `BankFas.Data` | Connections per login, procedure wrappers, the error numbers, and the jobs |
| `BankFas.Api` | ASP.NET Core minimal APIs for the tenant portal and the operator panel |
| `BankFas.Worker` | The job worker, a separate process that alone holds the `bankfas_jobs_*` secret (ADR 0009) |
| `web/` | React 19, TypeScript and Vite |
| tests | Unit tests, and integration tests against a deployed database |

Package versions are central (`Directory.Packages.props`) and locked (`packages.lock.json`). Transitive versions are
pinned, which moves `System.Security.Cryptography.Pkcs` past two advisories. Warnings are errors, under the
recommended analyzers. Tests run on Microsoft.Testing.Platform with xUnit v3.

### 2. Data access

- **One login per process, one connection per request.** Each process connects with its own login. A request opens
  one connection, binds it first, outside any transaction, and closes it at the end.
- **Pooling stays on.** The driver resets a pooled connection, which clears the session context. The database
  refuses a second binding of one connection (50004). MARS is off.
- **Binding reads its result from the database.** `sec.usp_SetSessionContext` and then `sec.usp_TouchSession`. The
  user id comes from `SESSION_CONTEXT`, never from the request.
- **Typed procedure calls only.** Procedures are called with typed parameters; SQL text is never built from values.
- **Errors become problems.** Database errors map to RFC 9457 problems in one table (`DbProblemMap`). Every failure
  before a password is proven reads the same.
- **Encrypted connections.** Connections are encrypted with a verified certificate. `TrustServerCertificate` is
  refused outside the Development and Testing environments (ADR 0013).

### 3. Security primitives

- **Passwords.**
  - Argon2id with m=65536 KiB, t=3, p=4, a 16-byte salt and a 32-byte hash.
  - The PHC string uses base64 without padding, over the UTF-8 bytes of the NFKC form.
  - Unit tests compare the output byte for byte with the reference implementation (argon2-cffi).
  - Stored parameters outside sane bounds are refused.
  - An unknown e-mail costs the same hash, on a fixed salt.
- **TOTP.**
  - RFC 6238: HMAC-SHA1, 6 digits, 30 seconds, and one step on either side, compared in constant time.
  - Tested on the vectors of the RFC.
  - A step not after the last accepted one is refused locally, and again by the database.
- **Tokens.** Tokens are 32 random bytes, in base64url. The database keeps only their SHA-256.
- **Recovery codes.** Ten codes of 80 bits each, in Crockford base32 as XXXX-XXXX-XXXX-XXXX. They are normalised
  (O as 0, I and L as 1) before the SHA-256.
- **The envelope.**
  - Layout: `0x01 ‖ nonce(12) ‖ AES-256-GCM ciphertext ‖ tag(16)`.
  - The associated data is length-prefixed: tenant id (4 bytes, big-endian), table, column, and the row's PublicId
    (16 bytes, RFC 4122 order).
  - A tenant key is wrapped with associated data of its tenant, purpose and version.
  - Operator secrets use tenant id 0 and no row id. The id is not known before set-up, and operator rows change only
    through procedures.
- **Master keys.**
  - Master keys sit behind `IKeyWrapper`. The product is still open (DQ-S02-1).
  - `LocalKeyWrapper` takes its keys from configuration and works only in Development and Testing.
  - Unwrapped tenant keys stay in memory for at most 15 minutes.

### 4. Web surface

- **Hosts.**
  - The host decides the surface: `admin.<domain>` is the operator panel, and `<code>.<domain>` is a tenant.
  - The code never comes from the body, query or path.
  - An unknown code and an archived tenant get the same 404 (Q-1).
- **Cookies.**
  - The session cookie is `__Host-bf_session`: Secure, HttpOnly, SameSite=Lax, with no Domain.
  - The CSRF check is a double submit: the `__Host-bf_csrf` cookie, the `X-CSRF-Token` header, and an Origin check.
  - A TOTP secret waiting for its first code travels in a cookie protected by Data Protection, tied to the session or
    link it was made for, for 10 minutes. The database stores nothing until the code checks out.
- **Headers and limits.**
  - Security headers include a strict CSP, HSTS, `nosniff`, `no-referrer` and `frame-ancestors 'none'`.
  - Rate limits per address: 10 logins a minute and 10 MFA attempts in 15 minutes.
- **Step-up.** Creating a tenant and changing its status take a fresh TOTP code in the same request. The database
  requires a check in the last 5 minutes.

### 5. Database changes (the S0 gaps)

| Gap | Change | Test |
|---|---|---|
| GAP-13 | `sec.usp_ResolveTenant` also returns NameEn, NameAr and DefaultLanguage | A2 |
| GAP-2 | `sec.usp_GetMfaChallenge` returns the wrapped key (WrappedKey, MasterKeyRef, KeyVersion, Algorithm) and the user's PublicId. For an enrolment it names the tenant's ACTIVE DATA key. A REVOKED or RETIRED key is never returned | A15 |
| GAP-3 | `@StepUp = 1` on the same procedure serves a session whose check is done, with `@MfaVerifiedAt` | A15 |
| GAP-4 | `@Accepted` output on `sec.usp_ConfirmMfa` and `plat.usp_ConfirmOperatorMfa`. A user's code without a step now counts as a failure, as it already did for operators | A16, P12, T36 |
| GAP-1 | New `plat.usp_GetOperatorMfaChallenge(@SessionToken)` returns the encrypted secret, its key reference, the last step and the MFA state | P12 |
| GAP-7 | `plat.usp_TouchOperatorSession` returns the operator, the role and MfaVerifiedAt, and touches ACTIVE operators only | P12 |
| GAP-8 | New `sec.usp_GetPasswordPolicy(@TenantId)` returns the minimum length and the history count before binding | A17 |
| GAP-10 | An operator may set TRIAL again on a TRIAL tenant to extend it, only to a later date. The old date is audited | O6 |

### 6. The onboarding job (JOB-PLT-ONBOARD)

The job runs once for each tenant whose `tenant.created` event is pending, bound as the tenant's service account:

1. It claims the event.
2. It creates any missing DATA, BLIND_INDEX and FILE key: version 1, PENDING then ACTIVE, with the KeyEvent rows
   CREATED and ACTIVATED.
3. In one transaction, it calls `sec.usp_SeedCoreRoles`, gives the first administrator every company, and calls
   `sec.usp_InviteFirstAdministrator`.
4. After the commit, it sends the e-mail and records SendStatus.
5. It marks the event DELIVERED and writes a JobRun row.

A failure sets the event to FAILED with a back-off, and to DEAD after five attempts. Running the job again adds
nothing. In development the e-mail is a file in a drop directory; the SMTP relay waits for the hosting decision.

### 7. CI

`tools/ci/app_ci.sh` runs after `db_ci.sh` in the same workflow:

- it builds the solution and runs the unit tests;
- it type-checks and builds the web front end;
- it provisions the service logins into a private temporary directory;
- it runs the integration tests on the deployed database, then drops the logins.

The integration test walks the S0 exit check (AC-PLT-5) end to end. It also checks the refusals: a wrong code, a
replayed step, a missing step-up, a used link, a short password, a missing CSRF token, an unknown sub-domain, and the
wrong surface.

### 8. The rest of S0

- **Users, roles and step-up.**
  - The application keeps one active account administrator at least (GAP-14, 409 LAST_ACCOUNT_ADMIN).
  - Giving TM or FO takes a fresh code and writes a HIGH audit row.
  - A permission the platform locks is refused before the write (403 PERMISSION_LOCKED).
  - Sensitive tenant actions take a fresh code in the same request and answer 401 REAUTH_REQUIRED without one. The
    operator's answer 403 STEP_UP_REQUIRED, and a missing code counts towards the lockout.
- **API conventions (DOC-B04).**
  - ETag and If-Match: 428 without one, 409 VERSION_CONFLICT on a stale one.
  - An Idempotency-Key on POST, kept 24 hours.
  - Cursors and references protected with Data Protection.
  - An unknown query parameter is 400 UNKNOWN_PARAMETER.
- **Support and the panel (GAP-5, GAP-6).** `db/static/059_support_and_panel.sql` holds the support operators and
  grants lists, the support page log (SUPPORT_PAGE_VIEWED, and SUPPORT_ACCESS_DENIED as HIGH), the tenant counters
  and the resend of the first invitation.
- **Jobs.**
  - The outbox job claims batches of 50 with UPDLOCK and READPAST, in order per aggregate, on a 60-second lease,
    with back-off and DEAD after five attempts.
  - Weekly purges of the outbox and the job runs.
  - Trial reminders at 7, 3 and 1 days, once each.
  - An SMTP sender with STARTTLS when `Mail:Smtp:Host` is set.
- **Links.** A link's token is in the URL fragment, built by `UriBuilder.Fragment`. The first version escaped the
  `#`, which sent the token to the server; a unit test now pins it.
- **The front end.**
  - English keys with an Arabic dictionary (`web/src/ar.ts`), `dir="rtl"`, and CSS logical properties.
  - The QR code is drawn in the browser (`qrcode`), so the secret does not leave the page.
  - One dialog asks for the fresh code and retries the request.
- **The leaked-password list (DQ-S04-1).**
  - `BreachedPasswords` reads the published SHA-1 range files (`XXXXX.txt`, `SUFFIX:COUNT`) from a local directory.
  - It checks the password as typed and in NFKC, on every password set by a user or an operator, after the cheaper
    rules (422 PASSWORD_BREACHED).
  - A missing directory stops the API at start-up, and a missing range refuses the password. A partial list is
    allowed in Development and Testing only.
- **Browser tests.**
  - `tools/ci/e2e.sh` runs the API and the worker on HTTPS with a throwaway certificate, and maps `*.bankfas.test` to
    127.0.0.1 in Chromium.
  - It walks AC-PLT-5 in the browser, with the leaked-password refusal, the QR code and the switch to Arabic.
  - Its operator invites the integration tests' operator, so both run on one fresh database.

## Consequences

- **Decisions still open.** A KMS product (DQ-S02-1), the mail provider, the production domain, and the source and
  refresh schedule of the leaked-password list are decisions outside the build; docs/42 section 9 lists them.
- **A server needs the leaked-password list to start.** Deployment downloads it and refreshes it every three
  months.
- **A wrong TOTP code costs more.** A user's code without a step is now a failure. A client that sent `@Passed = 1`
  without a step loses that path. The application always sends the step.
- **Gaps left for later.** GAP-9, 11, 12 and 15 to 17 stay as the brief describes them. They are taken up with the
  screens that need them.
