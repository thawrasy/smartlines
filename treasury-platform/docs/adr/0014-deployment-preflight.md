# ADR 0014: The deployment preflight, the release register and gate G4

Status: decided by the database architect. It builds the proposals of four decisions:
- DQ-S11-6 (DOC-S11; decided by the tools owner);
- DQ-B11-7 (DOC-B11; decided by the DevOps lead);
- DQ-B11-11 (DOC-B11; decided by the DevOps lead);
- DQ-B01-2 (DOC-B01; decided by the DevOps lead).

These are not owner decisions. It applies item 4 of FR-PLT-045 and follows ADR 0010 and ADR 0013.

## Context

- **`sa` was still the default.** After ADR 0013, `deploy.sh` and the administrator scripts still took `sa` when `SQL_USER` was not set. In production `sa` is disabled and nobody uses it (DOC-S08 section 9; THR-44 in DOC-S01).
- **`-C` could still be passed by hand.** No tool added it any more, but nothing stopped someone from passing it.
- **No check before deploying.** `db/deploy.sql` builds a new database only. On a database that already held tables it failed at the first table, possibly after creating some objects. Nothing checked the target first.
- **Gate G4 did not exist.** FR-PLT-045 item 4 and gate G4 (DOC-B11 section 7) require the deployment script to read the SQL Server and operating system versions of the target and refuse when they differ from the release register. That register did not exist (DQ-B11-7).
- **CI ran a moving image.** CI ran `2025-latest`. On 2026-10-13 that image was SQL Server 2025 CU9 GDR1 (17.0.5015.4) on GitHub and CU9 (17.0.5005.3) in the development container. Nothing tied either to a register.

## Decision

1. **The release register is `treasury-platform/versions.json`** (DQ-B11-7). The repository holds other products, so the register sits at the root of this one.
   - **What it records for the database host:**
     - Ubuntu 24.04;
     - SQL Server 2025 CU9 GDR1, KB5126967, build 17.0.5015.4;
     - the CI image `mcr.microsoft.com/mssql/server:2025-CU9-GDR1-ubuntu-24.04`.
   - **Reviews.** It also keeps a review record (FR-PLT-045 item 3). The first entry adopts this build, the latest one (NFR-OPS-05).
   - **Not in it yet.** The application host and .NET are added when they are decided.
2. **CI runs the image of the register** (DQ-B11-11, DQ-B01-2).
   - The workflow names `2025-CU9-GDR1-ubuntu-24.04` instead of `2025-latest`.
   - Step 3 fails when the workflow's image and the register differ.
   - The workflow also runs when `versions.json` changes.
3. **`deploy.sh` runs `db/ops/deploy_preflight.sql` first** (DQ-S11-6, G4). Nothing runs unless every check passes, in this order:

   | Error | Refused when |
   |---|---|
   | 50140 | the login is `sa`, identified by its SID under any name, or any `sysadmin`. This holds in CI as well: the deployment runs as `bankfas_migrator`, a member of `db_owner` only (ADR 0010). |
   | 50143 | the SQL Server build (`SERVERPROPERTY('ProductVersion')`) or the Ubuntu release (from `@@VERSION`) differs from `versions.json`. The deployment login can read both without any server right. |
   | 50141 | `BankFas` does not exist in `Arabic_100_CI_AS_SC`. |
   | 50142 | `BankFas` already holds tables. An upgrade waits for the migration runner (DQ-B11-4, DOC-S11 section 7.2). |

   - **Default login.** `deploy.sh` now defaults to `SQL_USER=bankfas_migrator`.
   - **Output.** It prints the login, the build and the host it checked.
4. **Two allowances, set only by CI** (`tools/deploy/preflight.sh`, sourced by every script in `tools/deploy`):

   | Allowance | What it permits | What happens without it |
   |---|---|---|
   | `BANKFAS_ALLOW_TRUST_CERT=1` | `-C` in `SQLCMD_OPTS` | Every tool, `check_deployed.py` included, refuses `-C` before it connects. |
   | `BANKFAS_ALLOW_SA=1` | the administrator scripts may run as `sa` | `prepare_database.sh`, `provision_logins.sh`, `provision_monitor.sh` and `server_audit.sh apply` refuse `sa`, under any name (50144). |

   `deploy.sh` has no allowance for `sa`. `tools/ci/db_ci.sh` sets both allowances for its throwaway container.

## Consequences

- **CI:**
  - Step 3 compares the image with the register.
  - Step 4 shows the real deployment passing the preflight.
  - Step 22 (`tools/ci/deploy_preflight_check.sh`) runs five checks:

    | Check | What it shows |
    |---|---|
    | PF1 | a database with tables is refused and nothing changes |
    | PF2 | `sa` and a `sysadmin` are refused even in CI |
    | PF3 | six tools refuse `-C` before connecting, with a server name that does not resolve |
    | PF4 | four administrator scripts refuse `sa` and change nothing |
    | PF5 | another build or Ubuntu release is refused, and the register itself passes |

  - **Checked by mutation.** Four mutations each fail their check:
    - no `sysadmin` rule fails PF2;
    - no version gate fails PF5;
    - no `sa` guard fails PF4;
    - no `-C` guard fails PF3.
- **The development container** was moved to the same pinned image, so it runs the same build as GitHub.
- **Upgrading SQL Server or Ubuntu** (DOC-S10 section 7.3) now starts with a reviewed change to `versions.json`. A server patched ahead of the register cannot be deployed to until the register and the CI image follow. That is the point of G4.
- **Limits:**
  - **The allowances are only a guard against mistakes.** Anyone who can set an environment variable can set them. The audit records what such a run does (ADR 0012).
  - **What the gate reads.** It reads the engine build and the Ubuntu release, not the kernel or the client tools, which DOC-S10 section 7.2 lists. Those stay in the manual checklist.
- **Still open:**
  - `-f 65001`, when the seeds carry Arabic text (DQ-S11-3);
  - the migration runner (DQ-B11-4, DQ-B11-5).
