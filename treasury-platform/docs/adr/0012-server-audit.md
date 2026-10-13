# ADR 0012: SQL Server Audit of the database server, declared windows and the AL-18 alerts

Status: decided by the database architect. It builds the proposals of DQ-S08-10 (DOC-S08 section 10; decider: the security officer), DQ-S01-8 (DOC-S01; operations with the DBA) and DQ-S12-5 (DOC-S12 section 3.5; the security officer with the DBA). These are not owner decisions; the security officer confirms the groups, the alert rules and the window model with DOC-S12. It follows ADR 0009 and ADR 0010.

## Context

- **What the database cannot see.** `sysadmin` and `db_owner` pass every row filter and every DENY. They can change any row, disable a trigger or a security policy, and grant themselves anything (DOC-S08 section 9, THR-57 in DOC-S01). The hash chain of `aud.AuditLog` does not show such a change on its own (DOC-S12 section 3.5).
- **What was proposed.** DOC-S08 section 10 proposed a SQL Server Audit with twelve event groups. Its file would be copied off the server at once. Successful logins of the service logins would be left out because of their volume, and their failures kept. Four events would raise an immediate alert:
  - any login with `breakglass`;
  - `sa` being enabled;
  - a grant or a security policy changed outside a deployment window;
  - a login with `bankfas_migrator` outside the window.
- **What DOC-S12 added.** DOC-S12 section 3.5 added backups, database changes and database object changes. It also proposed a database specification on the audit tables and `ON_FAILURE = CONTINUE` with an alert (DQ-S12-5). Its AL-18 rule also lists a stopped audit, a dropped database and changes to the audit tables.
- **What did not exist yet.** Nothing in the repository created the audit. "Outside the window" had no record to be measured against. Three points were marked [تحقق MS]:
  - whether `BY public` covers `dbo` and `sysadmin`;
  - which permission reads the audit files;
  - how a predicate leaves out one kind of event.

## Decision

1. **The audit is a script, run by an administrator** (`db/ops/server_audit.sql`, through `tools/deploy/server_audit.sh apply`). It keeps three objects in place:

   | Object | What it records |
   |---|---|
   | `BankFas_Audit` | Files of 256 MB, at most 40, in `BANKFAS_AUDIT_DIR` (default `/var/opt/mssql/audit`, volume V5 of DOC-S10). Written within a second. `ON_FAILURE = CONTINUE` (DQ-S12-5). A predicate leaves out the successful logins (`LGIS`) of the eight service logins of ADR 0009 and nothing else. |
   | `BankFas_Audit_Server` | 23 groups. The twelve of DOC-S08 section 10 and the three of DOC-S12 section 3.5. Then eight more: user-defined events (the windows below); permissions on a schema, the database or a login; ownership of the database, a schema or an object, since an owner passes every permission; server settings; server objects such as endpoints, linked servers and credentials. |
   | `BankFas_Audit_Database` | In `BankFas`: every `UPDATE` and `DELETE` on `aud.AuditLog`, `aud.SensitiveAccessLog` and `sec.KeyEvent`, and every `DELETE` on `sec.LoginAttempt` and `cfg.JobRun`, `BY public`. |

   - **Idempotent.** A second run compares each object with the definition and changes nothing that matches. A change made by hand is put back, and that is recorded.
   - **Run twice per first deployment.** Before it, so that everything after it is recorded; then inside the window after `deploy.sh`, because the database specification needs the tables. A missing folder stops the run (50120).
   - **`check`** changes nothing and fails (50121) unless the three objects match and the audit has started. It is HS-8 in DOC-S10 and R-08 in DOC-S11.
2. **Windows are declared in the audit itself.** Each script in `tools/deploy` writes a user-defined event with `sys.sp_audit_write`. The event names its change reference `BANKFAS_CHANGE_REF` (`tools/deploy/audit_declare.sh`):

   | Events | Written by | The window ends |
   |---|---|---|
   | 1101 and 1102, a deployment window | `prepare_database.sh open` and `close` | at the next close, or after 12 hours |
   | 1103 and 1104, an administrative change | `prepare_database.sh prepare`, `provision_logins.sh`, `server_audit.sh apply` | at the next 1104 of the same login, or after one hour. The scripts write it even when they fail. |

   - **Who a window covers.** A window silences an alert only for the login that declared it. A deployment window also covers `bankfas_migrator`. A change by anyone else in the same hour still alerts.
   - **Declarations that do not count.** A declaration from a service login is ignored.
   - **Review.** Every declaration carries its administrator and change reference. The monthly review lists them (`server_audit.sh windows`) and matches them with the deployment log (DOC-S11 section 10).
3. **The AL-18 rules** (`db/ops/server_audit_alerts.sql`, run by `server_audit.sh alerts`; exit code 3 when there is any):

   | Rule | Event | When |
   |---|---|---|
   | BREAKGLASS | a login with `breakglass`, successful or failed | any time |
   | SA | a change to the `sa` login (principal 1) other than disabling it; still found after a rename | any time |
   | SERVER_RIGHTS | a server role member added or dropped, or a server permission changed | any time |
   | DROP_DB | a database dropped | any time |
   | AUDIT_STOP | the audit stopped or destroyed | any time |
   | AUDIT_ROWS | `UPDATE` or `DELETE` on the three audit tables. A `DELETE` on `sec.LoginAttempt` or `cfg.JobRun` counts unless a service login made it (the retention jobs). | any time |
   | MIGRATOR | `bankfas_migrator` enabled, or a login with it, successful or failed | outside a deployment window |
   | GRANT | a permission granted, denied or revoked; a database role member added or dropped; an ownership taken; a security policy created, altered or dropped | outside its login's window |
   | AUDIT | the audit or a specification altered or dropped. Creating one only adds records. | outside its login's window |
   | SCHEMA | `BankFas` or one of its objects created, altered or dropped. Index and statistics maintenance does not count. | outside its login's window |

   The script is the reference for the central monitoring, which evaluates the same rules on the shipped records (DOC-S12 section 3.5). It is also the tool of the monthly review and of an investigation.
4. **The answers to the three checks, proven in CI:**
   - **`BY public`.** It covers `dbo` and `sysadmin`. A statement is recorded even when it changes no row and is rolled back.
   - **Reading the audit.** `alerts` and `windows` need only `VIEW SERVER SECURITY AUDIT`. `check` also needs:
     - `VIEW SERVER SECURITY STATE` and `VIEW ANY SECURITY DEFINITION`;
     - in `BankFas`, a user with `VIEW DEFINITION` on the schemas `aud`, `sec` and `cfg`, and no right on their rows.

     A reader therefore needs no administrator rights. The login itself waits for DQ-S12-6.
   - **The predicate.** A predicate takes an action as a number: its four characters read backwards (`LGIS` is 1397311308).
5. **The order of a deployment** (DOC-S11):
   1. `server_audit.sh apply`, the first time;
   2. `prepare_database.sh prepare`, the first time;
   3. `prepare_database.sh open`;
   4. `deploy.sh` as `bankfas_migrator`;
   5. `server_audit.sh apply`;
   6. `provision_logins.sh`;
   7. `prepare_database.sh close`.

   The service logins are provisioned inside the window, before the close.

## Consequences

- **CI.**
  - Step 4 deploys the way production does: it starts the audit before anything else and declares every step (change `CI`). In CI only, it makes the folder with `xp_create_subdir`; in production the folder is a volume (DOC-S10 section 3).
  - Step 20 (`tools/ci/server_audit_check.sh`) runs seven checks:

    | Check | What it shows |
    |---|---|
    | SA1 | the audit is in place and idempotent, and a missing folder stops it |
    | SA2 | the deployment is recorded inside its window and raises no alert; the migrator's refused login after the close does |
    | SA3 | a service login is recorded only when it fails; its retention delete and its provisioning raise no alert |
    | SA4 | `sysadmin`, as `dbo`, is recorded on the audit tables |
    | SA5 | each rule fires outside a window, and maintenance does not |
    | SA6 | a reader needs only view permissions |
    | SA7 | a stopped audit is alerted, `check` fails while it is stopped, and `apply` starts it again |

    The checks fail when a guard is removed. This was tested three ways:
    - a predicate that leaves out no service login fails SA1 and SA3;
    - windows that silence everyone fail SA2 and SA3;
    - no AUDIT_ROWS rule fails SA4.

- **Limits:**
  - **Faked windows.** Anyone with `sysadmin` can declare a window, or stop the audit. A declaration is recorded with its login, though, and a stop is alerted and recorded before it happens. What remains is the review, and the copy off the server that the server cannot erase (DOC-S12 sections 3.5 and 5.2).
  - **Root on the server.** A root user can stop SQL Server and edit the files. auditd and the immediate shipping cover that (DOC-S10 section 6.8).
  - **Volume.** The log backups every 15 minutes (`BACKUP_RESTORE_GROUP`) and every administrator login are recorded. The volume is small next to 40 files of 256 MB. It is measured in the first weeks (DQ-S12-13).
  - **Not built here:** the shipping job, the central store, the reading login (DQ-S12-1, DQ-S12-2, DQ-S12-6) and the alerting itself. The rules are ready for them.
- **Scripts:**
  - `prepare_database.sh`, `provision_logins.sh` and `server_audit.sh` take `BANKFAS_CHANGE_REF`. Without it a declaration says `unrecorded`, which the review must explain.
  - The service login check (CI step 18) is unchanged.
  - The GitHub workflow `.github/workflows/treasury-db-ci.yml` now also runs on a change under `tools/deploy`, whose scripts CI runs.
