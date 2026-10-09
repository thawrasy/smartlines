# Database standards

Binding rules for every change to `db/schema`. The build and the tests enforce the ones marked **(checked)**; the
reviewer of a pull request enforces the rest. They write down what the 445 existing tables already follow.

## Names

- Schemas by domain (`iam`, `fleet`, `net`, `ops`, `sales`, `pricing`, `fin`, `acct`, `bill`, `ship`, `brd`, `sec`,
  `gov`, `audit`, `sys`, `ref`, ...). A table belongs to exactly one schema, and that schema's owner module owns it.
- `lower_snake_case`, singular table names (`sales.ticket`, not `tickets`), English only **(checked: scripts/check_language.py)**.
- Foreign-key columns are `<target>_id`; when a table has two references to the same target, the role comes first
  (`origin_station_id`, `dest_station_id`). Typed references behind a polymorphic pair are `<subject>_<target>_id`.
- Indexes: `<table>_<column>_fkx` for a foreign-key index, `<table>_<column>_poly` for a (type, id) pair, `<table>_<what>_uq`
  for a unique index, `<table>_<what>_idx` otherwise.
- Constraints: `<table>_<what>_fk`, `<table>_<what>_uq`, `<table>_<what>_ck` (PostgreSQL defaults `_fkey`, `_key`,
  `_check` are accepted for single columns).
- Triggers say what they guard: `same_company_<column>`, `vehicle_of_company_<column>`, `<table>_<rule>`.
  Trigger functions are `<schema>.tg_<rule>`.
- Row-level security policies: `rw_read`, `rw_insert`, `rw_update`, `rw_delete` (from `sys.rls_rw`), or a name that
  says the rule (`company_read`, `catalog_read`).

## Keys and columns

- Every table has a primary key **(checked)**: `id bigint GENERATED ALWAYS AS IDENTITY` for entities, a composite key
  for association tables. Rows shown outside the platform carry `uid uuid` as well; the `id` never leaves the API.
- Every reference to another row is a foreign key, or is documented in the column comment as `Polymorphic:`,
  `External:` or `No FK:` with the reason **(checked)**.
- Every foreign key has an index, or is exempt by rule (lookup lists, actor columns) **(checked)**.
- A polymorphic pair has a CHECK list of its types; when the types are fixed, each also gets a typed foreign-key column
  set by `sys.typed_reference`.
- Times are `timestamptz`, stored in UTC; dates of a local calendar are `date`. Money is `bigint` in minor units with a
  `currency char(3)` next to it; never `numeric` for money, never a float.
- Status columns have a CHECK list, and a transition trigger when the order of states matters.
- `ON DELETE CASCADE` only for composition (a stop belongs to its trip). Financial, legal and audit rows are never
  deleted: they change status or are pseudonymised (`gov.erase_party`).

## Integrity rules

- A rule that holds for every row is in the database, not only in the service.
- Structural rules (all columns NOT NULL, one parent) are composite foreign keys: `UNIQUE (id, x)` on the parent,
  `FOREIGN KEY (parent_id, x)` on the child. Example: `sales.ticket (booking_id, trip_id) -> sales.booking (id, trip_id)`.
- Rules with an exception (leased vehicles, a refused boarding kept as evidence, shared platform rows without a
  company) are triggers: row level, `BEFORE INSERT OR UPDATE`, enabled, not deferrable, `SECURITY DEFINER` with
  `search_path = pg_catalog, pg_temp` **(checked for tenant guards)**. They fire for COPY as for INSERT.
- A row and the rows it references belong to one company unless the column comment says why not
  (`sys.tg_same_company`, `fleet.tg_vehicle_of_company`).
- Decide carefully what `company_id` means on each table before guarding it: on a partner sale it is the carrier that
  pays, not the station that sells.
- Every business rule has an owner (the database, the application or both), the objects and functions that keep it
  and the tests that prove it, in `docs/database/invariants.json` (rendered as `INVARIANTS.md`). A new rule, or a
  trigger, constraint, function or test renamed, updates the matrix; `backend/tests/test_invariants.py` fails on any
  name that no longer exists **(checked)**.

## Security

- Row-level security on every table, and a data class and owner path in `sys.table_class` **(checked)**.
- Runtime roles own nothing and cannot bypass row security **(checked)**. A `SECURITY DEFINER` function sets its
  `search_path` and checks the caller's context itself.
- The request context is set with `sys.set_context` inside the request's transaction (transaction-local settings), so
  a pooled connection never carries a company into the next request **(checked by an API test)**. Connection poolers
  run in transaction mode only.
- Restricted reads go through `sec.authorize` with a purpose and a reason.
- The application role reads, inserts and updates; it deletes only from the tables in `sys.app_delete_grant`, each
  with its reason (1059). `sys.grant_rw` grants no DELETE, and a business record is cancelled, closed or archived,
  never deleted. A new delete in the code, or a module list that allows deletes, needs its row in a new schema file
  first **(checked: the database grants exactly the listed tables; `test_code_rules.py` finds every delete in the code)**.
- `db.system_scope` (acting as the platform inside the caller's transaction) is used only where
  `backend/tests/governance_registry.py` lists the function, how many times, and why **(checked)**. Each use is counted
  at run time in `masslak_system_scope_total{site}`.
- Shared (DEFERRED) wallets store a balance that lags their newest entries: the application reads
  `fin.wallet_balance(id)` or `ledger.counted()`, and a direct read of `fin.wallet.balance` or of a raw wallet row is
  listed in the same registry with the reason its balance is exact **(checked)**.

## JSONB

- JSONB holds snapshots (a price breakdown at sale, the rules of a fare at booking) and extension payloads.
- A field that is joined on, filtered on, secured on, or computed with money is a typed column. No policy, foreign key
  or index uses a JSONB field **(checked)**. `sys.v_jsonb_inventory` lists every JSONB column.

## Dependencies between schemas

- Schemas are modules of one database. A foreign key between two of them keeps the reference true at every commit,
  whichever way it points; integrity is never traded for decoupling inside the database.
- Later modules depend on the core, not the reverse. A new reference points one way when the business allows it.
- **New two-way pairs:** `sys.v_schema_dependency` lists the cross-schema edges. A new pair of schemas that depend on
  each other fails the build until it is reviewed and added to the baseline in `db/tests/run_tests.sql` **(checked)**.
- **New table cycles:** a new cycle of foreign keys between tables also fails CI (`db/tools/schema_dependencies.py`)
  until it is added to `db/schema_dependencies.json` with its reason **(checked)**. A cycle needs at least one
  nullable link. The baseline only shrinks otherwise.
- **The map:** `docs/database/SCHEMA_DEPENDENCIES.md` is generated from the build and lists every cross-schema
  reference with the reason for each two-way pair.

## Triggers and policies: cost budget

- **Hot tables:** seats, bookings, tickets, payments, wallets, ledger and positions. A trigger on one of them does
  bounded work: indexed lookups on the row's own keys, no scans, no calls outside the database. Validation of a JSONB
  contract happens once, on write.
- **Budget:** a hot write path spends at most 1 ms of trigger time per row at the 1x staging volume, and policies add
  at most 1 ms per query. Staging records both with `track_functions = pl` (`masslak_db_function_seconds_total`) and
  the RLS benchmark. A change that breaks the budget is fixed in the same release (an index, a cheaper predicate, a
  `SECURITY DEFINER` lookup keyed by id) before it is accepted.
- **Where a rule lives:** a rule that must hold for every writer (API, worker, partner API, administration tools)
  stays in the database. Only presentation and request-shape checks live only in the application.

## Volume (ten million operations a day)

`docs/operations/CAPACITY_MODEL.md` sets the figures.

- **No shared hot row:** no row is updated by many concurrent transactions.
  - A counter or balance that many writers move is kept as appended rows, and folded in by a job. The DEFERRED
    wallets and `fin.roll_up_balances` are the model.
  - Readers use the function that adds what is not folded in yet (`fin.wallet_balance`).
- **Partitioned growing tables:** a table that grows by millions of rows a day and is append-only is partitioned on
  its time column.
  - Days (`ensure_daily_partitions`) when its retention is in days; months otherwise.
  - Its storage settings live in `sys.partition_option`, applied to every new partition.
  - Old partitions are dropped, never deleted row by row.
  - A partition referenced by a foreign key is detached before it is dropped.
- **Identity of a partitioned row:** `(id, time column)`. Code that updates one row gives both, so that only one
  partition is searched.
- **No full-history scans:** daily jobs never read a whole history. Money is checked from the closed-day totals plus
  the open days (`fin.reconcile_wallets`). A closed day takes no new rows.
- **Pooled connections:** code runs behind PgBouncer in transaction mode. No session-level `SET`, `LISTEN`, advisory
  lock or temporary table outlives its transaction.
- **Tables partitioned by id (review stage D5):** a table that many others refer to by its id (bookings) is partitioned
  by ranges of id, so every foreign key to it keeps working. Its unique keys must contain id; any other key that must
  be unique over all partitions lives in a registry table written by a trigger in the same statement
  (`sales.booking_key`). Partitions are created ahead by the daily upkeep (`sys.ensure_id_partitions`), never by a
  default partition. An existing table is converted only with `sys.partition_by_id`, which keeps every grant, policy,
  trigger, comment and reference, and while the table is small or in a maintenance window.
- **Catalogue readers and partitions:** a foreign key to a partitioned table also appears once per partition in
  `pg_constraint`; code that reads keys keeps `conparentid = 0`. A row trigger on a partitioned table runs with the
  partition as its table: a generic trigger that records or looks up its table resolves `pg_partition_root(TG_RELID)`.
- **Markets (review stage D1):** no time zone or currency is written into the code; days and money are read in the
  market of the data (`app.markets`, `ref.company_tz`, `ref.station_tz`). A CI rule refuses a fixed zone or currency.
- **What leaves the primary (review stage D3):** only the columns listed in `sys.dw_columns()` are published to the
  warehouse. A new column is added there, in a schema file, after checking it names, reaches or identifies no person.
- **Positions (review stage D2):** the trust rules of a position live in `ops.position_flags` only; both stores call it.
- **Failover (review stage D6):** connection strings list every server with `target_session_attrs=read-write` (or go
  through HAProxy); code treats a lost connection as "try again" (503), never as a failed booking.

## Phases

- Every table belongs to one project phase (`sys.table_phase`, file 1041) **(checked)**. A table never requires a row of a
  later phase **(checked)**: a reference that points forward is optional and stays empty until that phase starts
  (`sys.v_phase_forward_reference`). Code of a phase does not read or write tables of a later phase.
- Moving a table to another phase is a written decision recorded in a new schema file.

## Locks

Concurrent transactions take row locks in one order, so they wait for each other instead of deadlocking:

1. seats (`ops.seat_segment`, by seat number, then segment: `lock_segments` selects them `ORDER BY seat_no, seg FOR UPDATE`),
2. the booking and its tickets,
3. the payment (`SELECT ... FOR UPDATE`),
4. wallets, in ascending id when a transaction touches several. A passenger or family wallet (IMMEDIATE) is locked
   by every posting; a shared wallet (DEFERRED: carriers, agencies, the platform's wallets) is locked only by a debit
   that must stay covered, never by a credit,
5. ledger entries (append only, no lock taken).

A new code path that locks rows of two of these follows the same order. Queues use `FOR UPDATE SKIP LOCKED`.

Transaction-level advisory locks come before any row lock, in this order (release 1.48.0):

1. `booking-key` (the buyer and the booking's idempotency key): a second request with the same key waits for the
   first and answers with its booking (R-08),
2. `seat-holds` (the person): counting a person's held seats and locking new ones are one step (R-07),
3. `agency-sales` and `cash-sales` (the agency or the carrier): a channel's daily limit,
4. `mfa-send` (the person): the limits on sign-in codes sent by message.

They are `pg_advisory_xact_lock(hashtext(<name>), hashtext(<key>))`, released at commit or rollback, so they are safe
behind PgBouncer in transaction mode. An opened-on-first-use row (a wallet) is inserted with `ON CONFLICT DO NOTHING`
and read again, never read-then-insert alone.

## Migrations

Every change is a new numbered file in `db/schema` (never an edit of a released file) and comes with:

- [ ] Idempotence: the file runs twice without error (`IF NOT EXISTS`, `CREATE OR REPLACE`, guarded `DO` blocks).
- [ ] Upgrade equals fresh build (CI compares them).
- [ ] Expand, then contract: add the new column or table, ship the code that uses it, backfill, then make it required;
      remove the old one only in a later release. Never rename or drop in the release that changes the code.
- [ ] Constraints on existing data are added `NOT VALID` and validated at the end of the file; a failure is reported.
- [ ] Large indexes `CONCURRENTLY` (outside the transaction), backfills in batches outside peak hours.
- [ ] New tables: primary key, row-level security, data class, owner path, foreign-key indexes, column comments, and a
      row in `sys.table_phase` naming its project phase **(checked)**.
- [ ] Impact written in the pull request: relationships, row security, indexes, the queries that change, the rollback.
- [ ] A test in `db/tests/run_tests.sql` for every new rule, and the API tests still passing.
- [ ] The data dictionary, ERD and design document regenerated (`db/tools/gen_docs.py`, `docs/database/generator`).
- [ ] The release manifest is written by `db/build.sh` and `db/upgrade.sh` (1058); never add or remove rows of
      `sys.schema_file` by hand, or the next upgrade refuses to run (exit code 4).
- [ ] Before production: a backup confirmed, and the file rehearsed under load (`db/tools/migration_rehearsal.py`). The
      result and the plan, including the forward fix, go in `docs/database/MIGRATION_PLANS.md`. The stop criteria are
      an exclusive lock of at most 2 s on a table the booking path writes, traffic p99 of at most 1 s, and no errors.
