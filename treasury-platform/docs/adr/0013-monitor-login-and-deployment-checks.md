# ADR 0013: The monitoring login, a post-deployment check it can run, and no trusted certificate by default

Status: decided by the database architect. It builds the proposals of three decisions:
- DQ-S12-6 (DOC-S12; decided by the DBA with the security officer);
- DQ-S11-7 (DOC-S11; decided by the tools owner);
- DQ-S05-7 (DOC-S05; decided by the tools owner).

These are not owner decisions. It follows ADR 0009, ADR 0010 and ADR 0012.

## Context

DOC-S11 named two blockers for the first production deployment:

- **`-C` by default.** Every script in `tools/deploy` passed `-C` unless `SQLCMD_OPTS` was set. `-C` trusts any server certificate (DOC-S05 section 5.3). With an administrator's login, an intercepted connection becomes full control (THR-44 in DOC-S01).
- **`check_deployed.py` could not run in production.** The post-deployment check passed `-U sa -C` itself. In production `sa` is disabled and `-C` is refused. The checks of DOC-S11 section 8.2 (security policies, the procedures that run as `tp_auth_exec`, the collation) were manual queries.

Two more gaps:

- **No login for reading the state.** DQ-S12-6 proposed one: `bankfas_monitor`, with the state of the server and the backup history, and no tenant data. ADR 0012 showed what reading the audit needs, but created no login.
- **Nothing tested that the checks can run without administrator rights.**

## Decision

1. **No tool trusts a certificate by itself (DQ-S05-7).**
   - **Default.** `SQLCMD_OPTS` defaults to nothing in every script under `tools/deploy` and in `check_deployed.py`.
   - **CI.** `tools/ci/db_ci.sh` exports `SQLCMD_OPTS=-C` for its throwaway container, and step 3 fails if any of these tools adds `-C` on its own.
   - **Windows.** `tools/deploy/deploy.ps1` no longer adds `-C` to a SQL login. It takes `-TrustServerCertificate` instead. That path has still not been run (ADR 0001).
2. **`check_deployed.py` connects like the wrappers (DQ-S11-7)** and runs the read-only checks of DOC-S11 section 8.2.
   - **Connection.** `SQL_USER` (default `sa`; empty selects `-E`), `SQLCMDPASSWORD` and `SQLCMD_OPTS`.
   - **Expected values.** They come from the generated DDL and from the static scripts that `db/deploy.sql` runs.

   | Check | Expected |
   |---|---|
   | tables, schemas, foreign keys, unique and check constraints, indexes | as in the generated DDL |
   | security policies | one per table in `004_rls_tables` (184 today) |
   | disabled policies | none |
   | modules that run as `tp_auth_exec` | every procedure and trigger whose static script says so (55 today) |
   | collation | `Arabic_100_CI_AS_SC` |

   It reads definitions only, so it needs no right on rows.
3. **`bankfas_monitor` (DQ-S12-6)** is made by `tools/deploy/provision_monitor.sh` (`db/ops/monitor_login.sql`). An administrator runs it inside the deployment window, after `deploy.sh`.

   | Where | Right | For |
   |---|---|---|
   | server | `VIEW SERVER PERFORMANCE STATE` | sessions, waits and log space (DOC-S10 section 9, AL-14) |
   | server | `VIEW SERVER SECURITY STATE` | the audit status (`server_audit.sh check`, HS-8) |
   | server | `VIEW SERVER SECURITY AUDIT` | the audit files (`server_audit.sh alerts` and `windows`, AL-18) |
   | server | `VIEW ANY SECURITY DEFINITION` | the audit and its specifications. Password hashes stay hidden. |
   | `msdb` | `SELECT` on `dbo.backupset` and `dbo.backupmediafamily` | the backup history (DOC-S09, AL-15) |
   | `BankFas` | `VIEW DEFINITION` | the catalogue `check_deployed.py` reads; no row, no procedure |

   - **No roles.** It is a member of no server role and no database role.
   - **The proposal, widened.** DQ-S12-6 proposed server state and backup history. This adds the audit (ADR 0012) and the definitions of `BankFas`, which the two checks need. `VIEW DEFINITION` on the database replaces the schema-level grants ADR 0012 listed for `check`.
   - **Guards.** The script refuses a monitoring login or user that holds more than the table above:
     - 50130: a server role, or a server right beyond the table;
     - 50131: a role, or a right in `BankFas` beyond `VIEW DEFINITION`;
     - 50132: another `msdb` table.

     A right added by hand is therefore found at the next run.
   - **Secret and rotation.** The secret is a private file, as in ADR 0009. Running the script again with a new secret rotates it. There is one login, not a pair: a monitoring gap of a minute during rotation is accepted.
   - **Audit.** Its successful logins are recorded, unlike those of the service logins. They come about once a minute, and a reading login is worth tracing.
4. **The deployment order** (DOC-S11):
   1. `server_audit.sh apply` (first time);
   2. `prepare` (first time);
   3. `open`;
   4. `deploy.sh`;
   5. `server_audit.sh apply`;
   6. `provision_logins.sh`;
   7. `provision_monitor.sh`;
   8. `close`.

   Then `check_deployed.py` and `server_audit.sh check` run as `bankfas_monitor` (F-07, F-12a).

## Consequences

- **CI:**
  - Step 3 rejects a tool that adds `-C` by itself.
  - Step 4 provisions the monitoring login inside the window.
  - Step 5 runs the post-deployment check as `bankfas_monitor`: ten checks, all `ok`.
  - Step 21 (`tools/ci/monitor_login_check.sh`) runs six checks:

    | Check | What it shows |
    |---|---|
    | MN1 | the exact rights, no role, and a private secret |
    | MN2 | it runs the post-deployment check, the audit check and alerts, and the health queries |
    | MN3 | it reads no row, deletes nothing, runs no procedure and sees no password hash |
    | MN4 | its check finds a disabled security policy |
    | MN5 | each kind of added right stops the provisioning |
    | MN6 | a new secret rotates it |

  - **Checked by mutation:**
    - a tool with a `-C` default fails step 3;
    - without the server-right guard, MN5 fails;
    - a check that ignores disabled policies fails MN4.
- **Production:**
  - The deployment sets `SQL_SERVER` to the name in the server's certificate (DOC-S05 section 5.2). A wrong name now fails, as it should, instead of passing silently.
  - Until that certificate is installed, nothing connects.
- **Still open:**
  - the preflight that rejects `sa` and `-C` outside CI and checks the versions (DQ-S11-6);
  - `-f 65001` (DQ-S11-3);
  - the monitoring agent and its central store (DQ-S12-1). The login is ready for them.
- **ADR 0012:** the reading login it left to DQ-S12-6 is this one.
