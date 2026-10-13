# ADR 0010: Deployment runs as bankfas_migrator with db_owner only, and CI deploys the same way

Status: decided by the database architect. It builds the proposals of DQ-S11-1 and DQ-S11-2 (deciders: DBA with the security officer) and the deployment account of DOC-S08 section 3 (DQ-S08-5). These are not owner decisions. It follows ADR 0001 and ADR 0009.

## Context

- CI deployed as `sa`, so nothing showed that `db/deploy.sql` works with the rights production will give it.
- DOC-S11 section 6.1 proposed that an administrator create the empty database first. The deployment login, a member of `db_owner` only, would then deploy inside it. DQ-S11-2 asked for proof that `db_owner` is enough.
- A person must not be `dbo`, and the deployment login must not work outside a deployment window (DOC-S08 sections 3 and 10).

## Decision

1. **The administrator's part** (`db/ops/prepare_database.sql`, `tools/deploy/prepare_database.sh prepare`), once per server, with an administrator's own login:
   - **The database.** BankFas is created empty in `Arabic_100_CI_AS_SC`, with its files in `BANKFAS_DATA_DIR` and `BANKFAS_LOG_DIR` when they are given (DOC-S10 section 3). An existing database in another collation stops the run (50110).
   - **The owner.** `bankfas_owner` owns the database (dbo). Its password is made at random and kept nowhere, and the login stays disabled, so no person is dbo.
   - **The deployment login.** `bankfas_migrator` is a member of `db_owner` in BankFas and of no server role (50111), and is left disabled. Its secret comes from a private file, as in ADR 0009.
2. **The deployment window.** `prepare_database.sh open` enables `bankfas_migrator`. `deploy.sh` then runs with `SQL_USER=bankfas_migrator`. `prepare_database.sh close` disables the login and ends its sessions.
3. **CI uses this path** (`tools/ci/db_ci.sh` step 4). `sa` stands for the administrator, and the deployment itself runs as `bankfas_migrator`. CI then checks:
   - the owner is `bankfas_owner`, disabled;
   - the deployment login is disabled, in `db_owner`, and in no server role;
   - every schema, every `tp_` role and every object is owned by dbo;
   - the collation;
   - the deployment login is refused after the window closes.

   Every later step tests the database deployed this way.

## Consequences

- **`deploy.sql` needed no change** to run with `db_owner` only:
  - it finds the database, so it creates nothing at server level;
  - every schema and role it creates names `AUTHORIZATION dbo`;
  - it creates users without login, modules run as `tp_auth_exec`, and the seed impersonates a temporary user, all within `db_owner`'s rights.

  DQ-S11-2 is answered yes, and proved on every CI run.
- **The order of a production deployment:**
  1. `prepare` (first time);
  2. `open`;
  3. `deploy.sh` as `bankfas_migrator`;
  4. `close`;
  5. `provision_logins.sh` (ADR 0009).

  Steps 1 and 5 need a login that may create logins and databases, that is, an administrator's own account.
- **Still operations:** the administrators' personal accounts, `breakglass`, disabling `sa` (DQ-S08-9) and the SQL Server Audit alert when `bankfas_migrator` logs in outside a window (DOC-S08 section 10).
- **Residual.** `db_owner` can still drop the database. The window is the control: the login is disabled outside it, and its use is audited (DOC-S11 section 7.2).
