# ADR 0039: Hardening the audit anchors, the migrations, the keys and CI after internal review v6

Status: decided by the database architect on 2026-10-21. The owner asked for a deep internal review of the whole
system before the package goes to the external expert, and for every confirmed finding to be fixed without asking.
The review was carried out by five AI agents, each working through one lens: database code, tests and CI, documents
against artifacts, security and operations, and finance and credit. Every finding was checked against the code
before it was fixed. Findings and how each was handled are in docs/41. This ADR records the decisions on the
operations and integrity side. ADR 0037 covers the finance controls and ADR 0038 the credit engine.

## Context

The review found that the controls of reviews v4 and v5 had gaps where they meet operations:

- **The anchor job trusted the database (D1, D2, A7, B4).**
  - `take` anchored whatever head the database held. A chain rewritten with every hash computed again was therefore
    anchored as genuine the next day.
  - "Moved since the last anchor" was decided by `aud.AuditChainAnchor`, a table inside the database. A forged row far
    ahead in it stopped a chain from ever being anchored.
  - An anchor recorded in the database whose file was never written (a store not mounted, two runs in one second) was
    never taken again.
  - Nothing failed when the job stopped anchoring.
- **The chain had races and blockers (A2, A3, A12, A13).**
  - A full check raced live writers into false HEAD_MISMATCH alarms.
  - The anchor job held update locks on every head.
  - Two writers could deadlock on heads locked in id order.
  - One unchained row stopped every later migration.
- **migrate.sh lacked the production gates (D3 to D7, D17, B5, B8, B21).**
  - The baseline did not journal the versioned scripts.
  - A failed repeatable run was never taken up again.
  - A script could commit outside its journal row.
  - There was no sysadmin refusal, version gate, change reference, backup check or check that the application was
    stopped.
  - status exited 0 on drift.
- **The fingerprint was blind to grants to users, to role membership and to DDL triggers (A10, B6, D8).**
- **The key table was open to the application (A5, A8, A9).**
  - Keys could be inserted already ACTIVE, and their bytes rewritten.
  - Rows on a REVOKED key could still be written.
  - A key could leave ACTIVE between the guard's check and the row's commit.
- **Smaller gaps:**
  - Operators could insert audit rows of any tenant (A1).
  - The heads, anchors and journal were readable through `tp_readonly`'s schema grant (A11, B3).
  - Error 50029 had two meanings (A6).
  - Nested triggers were not checked (A14).
  - One failing tenant stopped the daily status job (A15).
  - The CI scripts had no shared guard (D9, D10).

## Decision

### 1. The store judges the anchors

- **take verifies first.**
  - `audit_anchor.sh take` first checks every chain from its latest anchor in the store, and anchors nothing if one is
    not OK (AA4).
  - It passes the store's latest anchors to `aud.usp_TakeAuditAnchors` (`@StoreLatest`, required: 50148), which
    anchors each head that moved past them. `aud.AuditChainAnchor` stays the database's own record only (AA5, AC2).
- **Files cannot be lost silently.**
  - The store must carry the file `.bankfas-anchor-store`, so a folder that is not mounted is refused (AA1).
  - File names carry a random suffix.
  - Each file is written without overwriting, read back, compared, and made read-only.
  - An anchor whose file was not written is taken again on the next run, since the store has no newer anchor.
- **A job that stops anchoring is an alarm.** `verify` fails a chain that moved past an anchor older than
  `BANKFAS_ANCHOR_MAX_AGE_HOURS` (default 26, STALE), and one with no anchor whose first row is older than that
  (NOT_ANCHORED). `aud.usp_ListAuditChains` gives the heads (AA6).
- **The weekly check covers every anchor.** `verify --full` checks every anchor of the store
  (`@MoreAnchors` of `aud.usp_VerifyAuditChain`), not only the latest.
- **Restores are recorded.** `audit_anchor.sh restored <store> <change reference>` handles a restore to an earlier time.
  - It checks every chain in full against the anchors up to its restored head.
  - It then writes a `restore-...` file with the restored heads and the change reference. The anchors past those heads
    no longer count (AA7; DOC-S09 section 8, step 11b).
  - The monthly review lists these files.
- **The daily job runs `take`, and the weekly job runs `verify --full`.**

### 2. The chain under load

- **Verification reads a fixed head.** `usp_VerifyAuditChain` reads the head first, verifies the rows up to it, then
  reads the head again. A row above the new head is a HEAD_MISMATCH; rows that writers add meanwhile are not.
- **No locks while anchoring.** `usp_TakeAuditAnchors` reads the heads without locks.
- **Heads are locked in order.** `usp_ChainRows` locks every head it will write in ChainKey order before it writes,
  so two writers wait for each other instead of deadlocking.
- **Unchained rows no longer block deployments.**
  - `usp_ChainExistingRows` chains only chains without a head. It finds them through `plat.Tenant`, so a run with
    nothing to do reads no audit row.
  - Rows written with the trigger off are left for the verification to report (UNCHAINED). They no longer stop a
    deployment (AC5, AC8).
- **Heads, anchors and journal are hidden from tp_readonly.** `DENY SELECT` on `aud.AuditChainHead`,
  `aud.AuditChainAnchor` and `plat.SchemaMigration` to `tp_readonly` (and so to `tp_support`). AC6 now asks, as a
  member of each role, what the role can read.

### 3. migrate.sh runs as in production

- **The server gate runs first.** `db/ops/server_gate.sql` is the first part of deploy.sh's preflight, and migrate.sh
  runs it before `baseline` and `apply`. It refuses:
  - sa, a member of a server role, or a holder of a server-wide right (50140);
  - a server that differs from the release register (50143);
  - a server with "nested triggers" off (50150, new; A14).
- **Every run names its change.** `BANKFAS_CHANGE_REF` is required, and `plat.SchemaMigration.ChangeRef` records it.
- **The baseline knows the existing scripts.**
  - `baseline --after-deploy`, called only by deploy.sh, journals the versioned scripts that are present as applied.
    The new database was built from the model they lead to.
  - A manual `baseline` is refused (MG10).
- **Failed and unsafe runs are caught.**
  - When the last run in the journal is a versioned script, the next `apply` runs the repeatable scripts again (MG9).
  - A versioned script with a line that ends or opens a transaction, or with a sqlcmd command, is refused before
    anything runs (MG5).
  - The fingerprint is compared again inside each script's transaction.
  - `status` exits 1 when it lists a problem (MG7).
- **Opening the window checks the server.** `prepare_database.sh open` refuses:
  - when the server audit is not running (50151);
  - when a service login has a session (50152);
  - for a database holding tables, when there is no full backup within `BANKFAS_BACKUP_MAX_AGE_HOURS` (default 24,
    50153; MG8).
- **The audit alerts end an undeclared window after 4 hours, not 12.** DOC-S11 sets a 2-hour window.
- **CI runs migrate.sh like production.** It runs as `bankfas_migrator`, inside a window opened after a backup. sa is
  refused there (MG8).

### 4. The fingerprint covers grants and membership

- **New parts.** Three parts are added to `plat.fn_SchemaFingerprintParts`:
  - `members`: role membership, including fixed roles;
  - `owners`: schema and object owners;
  - `ddltriggers`: database DDL triggers.
- **permissions** now covers every principal.
- **What is left out.** Only what provisioning does on every server: each service user `bankfas_<svc>_*` in its own
  role, the right to connect, and `bankfas_monitor`'s VIEW DEFINITION.
- **Tested.** MG7 changes a table, a db_owner member, a grant to a user and a DDL trigger outside the journal; each one
  stops `apply`.

### 5. The key itself

`sec.TR_TenantKey_Lifecycle` now fires AFTER INSERT and UPDATE:

- A key is created PENDING.
- Tenant, purpose and version never change.
- The wrapped bytes change only together with the master key reference (a re-wrap), and never once the key is RETIRED
  or REVOKED.

The reference triggers read the key under REPEATABLEREAD. A row on a REVOKED key is frozen until it is moved to an
ACTIVE key or cleared (KG7).

`tp_app` keeps INSERT and UPDATE on `sec.TenantKey`. It is the application's envelope-encryption key manager
(DOC-S02 section 6); the trigger, not the grant, enforces the lifecycle.

Revocation of several keys in one statement stays allowed. It is the emergency path (KG5), and every change is in
the audit.

Who reads the key references:

- The rotation job reads `sec.v_KeyReferences` (tp_jobs, filtered to its tenant).
- Operators read the counts across tenants through `sec.usp_KeyReferenceCounts` (tp_platform), which returns no row
  content.

### 6. Smaller fixes

- **Operators cannot write tenant audit rows (A1).** `rls.fn_AuditWrite` admits `tp_platform` for platform events only
  (TenantId NULL). A tenant event of an operator is written by its procedure, which runs as `tp_auth_exec` (AC10).
- **Error 50029 has one meaning again (A6).** The catalogue error of 057 is now 50149; 50029 stays the gap-free
  numbering error of 039.
- **One failing tenant no longer stops the status job (A15).**
  - `plat.usp_RunTenantTransitions` checks each tenant again before it changes it, and skips one that no longer
    qualifies.
  - A tenant that fails becomes a `TENANT_TRANSITION_FAILED` platform event of high severity (`@Failed`), and the job
    goes on with the next tenant.
- **Service logins are enabled last (D15).**
  - The administrator runs `service_logins.sql`.
  - A new service login is created disabled. The four logins are enabled only after every check has passed.
  - A server right other than CONNECT SQL is refused (50101).
- **One guard for every CI script (D9, D10).**
  - Every script of tools/ci, and run_perf.sh, sources `tools/ci/ci_guard.sh`.
  - The guard requires the CI allowance and a server on this machine.
  - Before BankFas is dropped, it refuses a database that holds a tenant other than the performance run's (50991).
    Through an SSH tunnel, a production server also answers on localhost.
- **Step 23 counts first.** It counts the test users left behind before it drops any (B9).
- **Step 24 checks more.** It requires J2 and J4 to be OK, and the concurrent writers' rows to be in the chain.
- **The dated literal in the performance script is gone.** It would have failed CI from 2026-10-23 (B1).

## Consequences

- The daily job runs `take`; the weekly job runs `verify --full`. Both need the store mounted and marked.
- A restore needs `audit_anchor.sh restored` before the next `take`. Until then the daily job fails, which is the
  intended alarm.
- Error numbers 50148 to 50153 are new.
- Tests:
  - AA grows from 3 to 7 cases and MG from 7 to 12.
  - Integrity tests: KG7 is new, and AC8 to AC10 are new.
  - CI keeps 33 steps.

## What stays open

- **Two-writer races are only tested indirectly.** The case of a writer adding rows during a full check has no test
  of its own. The bounded read is covered by AC1 to AC10 and by the four concurrent writers of the performance run
  (C1).
- **Production identities.** The store's write credential must be held by the job runner, never by a database
  administrator (DOC-S12 section 5.3). This separation is organisational and is checked at go-live.
