# Response to the architecture review of design document v3.9

**What we received:** an architecture and technical review of the Masslak database (design document v3.9), from a
second firm.
- **What it found:** five architectural risks, rated high: performance bottlenecks, future scaling, and operating cost.
- **What it recommends:** removing two-way module dependencies, daily partitions for positions, Debezium and Kafka in
  place of the outbox, moving validation to the application, and separating the financial schemas with sagas.

**How we answered:**
- **Checked against the build:** each statement was checked against the built database (migration 1.32.0, commit
  209133d), not only against the document.
- **Approved by the owner:** the platform owner approved the actions below on 8 October 2026.
- **What was delivered:** schema file `1051_architecture_review.sql` (migration 1.33.0), the read replica in the
  deployment stack, a CI check, and these documents.

## Summary

| # | Review statement | What the build shows | Verdict | What changed |
|---|---|---|---|---|
| A | 21 two-way dependencies between schemas create deadlocks and block sharding | **Accurate count:** 21 two-way schema pairs, plus 20 cycles between tables. Every cycle has a nullable link. Load test at 50 users: **0 deadlocks** | Partly accepted. The fact is right; the consequences are not | Reasons recorded for every pair and cycle; CI now fails on a new cycle without one; generated module map |
| B | RLS on all 475 tables and triggers on every write inflate CPU and latency | **Accurate count:** RLS is on 476 of 476 tables, as the earlier audits required. Measured cost: under 1 ms per query; book-and-pay p95 560 ms at 50 users. Hot tables have 1 to 5 triggers | Not accepted as a high risk; accepted as something to measure | Trigger cost measured per row (staging and load test), 1 ms budget in the standards, alert |
| C | Positions use monthly partitions with a 7-day retention | **Out of date:** daily partitions, dropped whole after 7 days, since file 1048. 16 daily partitions in the build. **Our error:** the table comment still said "monthly", and the document copies comments | Already done; our document was wrong | Comment corrected; a check now keeps partition comments true |
| D | One outbox table filled by triggers will be a single point of failure and a lock hotspot | Events are written in the business transaction. The only trigger numbers events per record and locks one counter row. Workers use `SKIP LOCKED`. Purged after 30 days; backlog alerted | Not accepted as written | Partitioning point and alert; the change data capture (CDC) path documented with the same contract |
| E | The ledger in the operational database lets financial reports slow bookings | Reports could use a replica, but it was optional | Partly accepted. The replica becomes mandatory; separating the ledger is not accepted | Streaming replica in the stack; the API and worker refuse production without it; scheduled reports read it |

## A. Two-way dependencies between schemas

**Facts.** The review's count is right.
- **21 schema pairs:** `db/tools/schema_dependencies.py` lists 21 pairs of schemas that reference each other.
- **20 table cycles** sit behind them. They are of four kinds:
  - **Typed references of a polymorphic owner:** for example `iam.document` points at the vehicle, licence, lease or
    policy it proves, and those keep their current document.
  - **Latest pointers:** for example a booking keeps the price allocation it was sold with, and a licence keeps its
    latest change request.
  - **Two-sided matches:** a bank statement line and a transfer top-up.
  - **The key registry:** company keys, and the encrypted columns that name their key.

**Why the conclusions do not follow:**
- **Schemas are not services.** A schema is a namespace inside one database. A foreign key in either direction keeps
  the reference true at every commit. Replacing foreign keys with API calls would give up that guarantee where it
  matters most: bookings, tickets, payments and the ledger.
- **Deadlocks come from lock order, not from reference direction.** The write paths take row locks in one documented
  order (seats, booking, payment, wallets in ascending id, ledger; `STANDARDS.md`, Locks).
  - **Measured:** the full-mix load test (booking, payment, refund, tracking and reports together, 10 to 50 users)
    had **0 deadlocks**.
  - **Watched:** the `Deadlocks` alert fires on any deadlock in production.
- **Sharding is not planned.** If it ever is, the natural key is the carrier (`company_id`), which every tenant table
  already carries for row-level security, not the schema.

**What we changed:**
- **The baseline:** `db/schema_dependencies.json` lists every two-way pair and table cycle with its reason.
- **The CI check:** `db/tools/schema_dependencies.py` runs in CI on the built database. It fails on a new pair or
  cycle without a recorded reason, and reports entries that disappeared, so the count only goes down.
  - The schema-pair check alone already existed as database test H-07. Table cycles and the reasons are new.
- **The map:** `docs/database/SCHEMA_DEPENDENCIES.md` is generated with every cross-schema reference.
- **The standard:** "Dependencies between schemas" in `STANDARDS.md` now says that integrity is never traded for
  decoupling inside the database, and that a new reference points one way when the business allows it.

## B. Row-level security and triggers

**Facts:**
- **Row-level security** is on all 476 tables. Two earlier audits required it, and a database check enforces it.
- **Hot tables carry few triggers:** `sales.booking` 5, `sales.ticket` 4, `fin.ledger_txn` 4, `fin.ledger_entry` 3,
  `ops.geo_event` 1, `sys.outbox_event` 1.

**Measured** (`docs/operations/PERFORMANCE_BASELINE.md`):
- **Row-level security:** adds 0.15 to 0.93 ms per hot query, mostly planning time.
- **Full mix at 50 users:** book-and-pay p95 560 ms and p99 723 ms; search p95 194 ms; position p95 329 ms.
- **Errors and money:** 0 errors, and 0 wallet mismatches after 3,582 bookings and refunds.

The review gives no measurement for its claim.

**Why the rules stay in the database.** Four kinds of writer reach the same tables:
- the API,
- the worker,
- the partner API,
- administration tools.

A rule that must hold for every writer, such as tenant isolation, money balance or a frozen price snapshot, belongs
where all of them pass. Moving it to one application would let the others bypass it. That is exactly the gap the
previous audits asked us to close.

**What we changed: cost is now measured, with a budget:**
- **Per-trigger timing:** `sys.capacity_metrics()` exports the time spent in each trigger and function
  (`masslak_db_function_seconds_total`) when `track_functions = pl`. The staging overlay turns it on.
- **The load test:** reports milliseconds per row for the ten costliest triggers (`trigger_ms_per_call`).
- **The budget:** at most 1 ms of trigger time per row on hot paths (`STANDARDS.md`, Triggers and policies: cost
  budget). The alert `TriggerCostOverBudget` and the capacity launch gate enforce it.
- **First reading:** with the setting on, the development database showed about 0.7 ms per row for the audit-capture
  trigger and 0.5 ms for the JSON contract check, on a cold, single-row run. Staging at 1x, 2x and 5x gives the
  numbers that count.

## C. Position partitions

**The statement is out of date:**
- **Since file 1048:** `ops.geo_event` has used daily partitions, created ahead by `sys.ensure_daily_partitions` and
  dropped whole after the 7-day retention (lifecycle matrix: `DROP_PARTITION`).
- **The build:** has 16 daily partitions.
- **Monitored:** a missing partition is alerted (`PositionPartitionMissing`).

**The mistake was ours.** The table's own comment still said "partitioned monthly", and the design document copies
table comments. So version 3.9 told the reader two different things, and the reviewers quoted the wrong one.

**What we changed:**
- **The comment:** corrected in file 1051.
- **The check:** a new database test fails when the comment of a partitioned table says daily or monthly against its
  actual partitions.
- **The document:** version 3.10 of the design document carries the corrected text.

## D. The outbox

**How it works:**
- **Written in the transaction.** The event is written in the same transaction as the change. A booking is never
  confirmed without its event, and no event exists for a change that rolled back.
  - Most events are written by the application, some by functions.
  - The one trigger on `sys.outbox_event` numbers events per record. It locks that record's counter row, not the
    table.
- **Competing workers.** Workers claim batches with `FOR UPDATE SKIP LOCKED`, so several can run without waiting for
  each other.
- **Purge and alerts.** Published events are deleted after 30 days. The age of the oldest pending event is alerted.
- **Failover.** The outbox is not a separate point of failure. It fails only if the database does, and the database
  now has a streaming replica.

**On Debezium and Kafka:**
- **They complement the outbox; they do not replace it.** The standard pattern is an outbox read from the write-ahead
  log by Debezium's outbox event router.
- **Not now.** Adding them today means two more clusters to run and secure, at a volume (thousands of bookings a day)
  where no outbox bottleneck has been measured.

**What we changed:**
- **Growth metrics:** `masslak_table_rows_estimate` and `masslak_table_bytes` for the outbox and the other growing
  tables, and the purge backlog (`OutboxPurgeBehind`).
- **Partitioning point:** the setting `capacity.outbox_partition_rows` (20 million). The alert
  `OutboxPartitioningDue` opens the work to partition the outbox by day, as positions already are.
- **The documented path:** `docs/integration/EVENTS.md`, "How events leave the database". It records that a later
  move to CDC keeps the envelope, ids, per-record sequence and schema versions, so receivers change nothing.

## E. The ledger and the operational database

**Why the ledger stays.** Booking, payment and ledger are written in one transaction. That is why a booking without
its ledger entries, or ledger entries without their booking, cannot exist.

**Why sagas are not accepted.** Separating the ledger and coordinating with sagas or distributed transactions:
- replaces that guarantee with compensation steps and later reconciliation;
- adds new ways for money to disagree;
- is a worse trade for a payment system at this scale.

**Accepted: reports must never load the primary.** Before this change, a replica for reports was optional
(`MASSLAK_REPORTS_DATABASE_URL`). Now:
- **The stack:** `docker-compose.yml` runs `db-replica`, a streaming hot standby with a replication slot. On first
  start it copies the primary with `pg_basebackup`, using its own replication role and the client-authentication file
  in `deploy/postgres`. The API and the worker read reports from it.
- **The startup check:** in production the API and the worker refuse to start without a replica, or when the address
  given is a primary (`pg_is_in_recovery()` is false). The rule has unit tests.
- **Scheduled reports:** now run their query on the replica, like interactive reports. The record of the run is still
  written on the primary.
- **Existing servers:** `deploy/update.sh` adds the new replication secret, and `deploy/migrate.sh` creates the
  replication role.
- **CI:** the deployment-stack job checks that the replica is streaming and that the API reads reports from it.
- **The replica's other uses:** it is also the failover candidate (`RUNBOOKS.md`, section 3). Reports show the moment
  their data reflects (`data_as_of`), and replica lag is alerted.

**Later, if needed:** heavy financial analysis belongs in a data warehouse fed from the replica, not in a second
transactional database.

## Verification

- **Database checks:** the new checks cover the partition comments, the capacity metrics and the partitioning setting.
- **API unit tests:** `tests/test_reports_replica.py` checks that production requires a replica, that a primary is
  refused, and that the sandbox may use the main pool.
- **Replica, checked with Docker on 8 October 2026** (`docs/operations/evidence/reports_replica_check_2026-10-08.json`):
  - **Streaming:** the primary started with the new client-authentication file. The replication role SQL of
    `migrate.sh` ran twice without error. The replica copied the primary, streamed through slot `replica1`, and served a
    row written on the primary.
  - **Rebuild:** a replica rebuilt from an empty volume reused the slot cleanly.
  - **Startup check:** it accepted the replica and refused both the primary and a missing address.
- **Monitoring:** promtool reports 27 alert rules and the unit tests pass, including the new capacity alerts.
- **Dependency check:** run on the build, it reports 21 pairs and 20 cycles, all with reasons.

## What we did not do, and why

| Recommendation | Decision | Reason |
|---|---|---|
| Remove the 21 two-way dependencies, connect modules by API | Not done | Loses referential integrity on money and bookings; deadlocks measured at zero; growth is now controlled instead |
| Move JSON contracts and business validation to the application | Not done | Several writers reach the tables; a rule kept in one of them is bypassed by the others. Cost is measured against a budget instead |
| Debezium and Kafka now | Deferred | No measured bottleneck; the partitioning point and the CDC path are documented and alerted |
| Separate the financial schemas with sagas | Not done | Replaces an atomic guarantee with reconciliation; the read replica removes the report load that motivated it |
