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

## Security

- Row-level security on every table, and a data class and owner path in `sys.table_class` **(checked)**.
- Runtime roles own nothing and cannot bypass row security **(checked)**. A `SECURITY DEFINER` function sets its
  `search_path` and checks the caller's context itself.
- The request context is set with `sys.set_context` inside the request's transaction (transaction-local settings), so
  a pooled connection never carries a company into the next request **(checked by an API test)**. Connection poolers
  run in transaction mode only.
- Restricted reads go through `sec.authorize` with a purpose and a reason.

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
4. wallets, in ascending id when a transaction touches several,
5. ledger entries (append only, no lock taken).

A new code path that locks rows of two of these follows the same order. Queues use `FOR UPDATE SKIP LOCKED`.

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
- [ ] Before production: a backup confirmed, and the file rehearsed under load (`db/tools/migration_rehearsal.py`). The
      result and the plan, including the forward fix, go in `docs/database/MIGRATION_PLANS.md`. The stop criteria are
      an exclusive lock of at most 2 s on a table the booking path writes, traffic p99 of at most 1 s, and no errors.
