# ADR 0009: One database login per process, provisioned with private secrets

Status: decided by the database architect, building the proposals of DOC-S08 (DQ-S08-1 accounts, DQ-S08-2 SQL logins on Linux, DQ-S08-3 one secret per process, DQ-S08-4 rotation with paired accounts), whose deciders are the database administrator, the security officer and DevOps. Those decisions are not the owner's. It closes the first open point of O-25 (tools/dbgen/erd_open_items.py) and follows ADR 0004.

## Context

- The roles exist: `tp_app`, `tp_platform`, `tp_jobs` (a member of `tp_app`) and `tp_support` (a member of `tp_readonly`). No login was mapped to them; CI and tests connect as `sa` and impersonate users without login.
- ADR 0004 left open the logins of the job worker and the support connection, whose secrets the web server must never hold. Whoever holds the worker's login can bind any tenant as its service account (DQ-F04-4). Keeping that secret away from the web server is the control.

## Decision

1. **Four service logins, each mapped to one role** (`db/ops/service_logins.sql`):
   - `bankfas_app_<set>` → `tp_app`
   - `bankfas_jobs_<set>` → `tp_jobs`
   - `bankfas_platform_<set>` → `tp_platform`
   - `bankfas_support_<set>` → `tp_support`

   Every login is a SQL login with password policy on and default database BankFas. `<set>` is `a` or `b`: two identical accounts per process, so a secret is rotated without downtime (DOC-S08 section 6). No reporting login until a use is decided (DQ-S08-6).
2. **Provisioning** (`tools/deploy/provision_logins.sh`) runs after `deploy.sh`.
   - It needs a login that may create logins (ALTER ANY LOGIN), so it is a DBA's personal administrator account, not `bankfas_migrator`, which is `db_owner` only.
   - It reads one secret file per login (`<login>.secret`). The file must be owned by the caller, have mode 600 or 400, and hold 32 to 128 characters of `[A-Za-z0-9_-]` with an upper-case letter, a lower-case letter and a digit. `--generate` creates missing files from `/dev/urandom`.
   - The secrets reach `sqlcmd` in a private temporary copy of the template, deleted at the end, never on a command line or in the environment.
   - The process that uses a login reads the same secret from its own secret store (DOC-S08 section 5, DQ-S08-3).
3. **Safe to run again, and a rotation.** An existing login takes the new secret and is enabled, and an existing user keeps its role. Rotating set `a` in place briefly refuses new connections that still hold the old secret. Rotating through set `b` avoids this:
   1. provision `b`;
   2. switch the process to `b`;
   3. disable `a`.
4. **Guards in the template.** Provisioning stops when:
   - a service login is a member of a server role (50101);
   - a service user is in a role other than its own, or holds a direct permission (50102);
   - anyone may impersonate `tp_auth_exec`, whose rights pass the row filters (50103).
5. **Secrets stay out of the repository.** `.gitignore` ignores `*.secret`.

## Consequences

- **Tests.** LG1 to LG6 in `tools/ci/service_logins_check.sh` pass in CI (`tools/ci/db_ci.sh` step 18). They connect as each login, which no earlier test did:
  - memberships;
  - the procedures and tables each process may use and not those of the others;
  - rotation in place;
  - the a/b pair;
  - refusal of a weak or readable secret;
  - the guards.
- **Deployment (DOC-S11).** After `deploy.sh`, the DBA runs `provision_logins.sh` with the secret folder of the target host, then places each secret in the secret store of its process.
- **Still operations, not code:**
  - `bankfas_migrator`, enabled during the deployment window;
  - the personal administrator accounts and `breakglass`;
  - disabling `sa` (DOC-S08 section 9, DQ-S08-9);
  - the SQL Server Audit groups (DQ-S08-10);
  - the shape of each host's secret store (DQ-S08-3).
- **Residual.** The worker's login still binds any tenant for a catalogued job (DQ-F04-4, proposed for acceptance with a named owner). Separate logins and secrets confine that power to the worker process.
