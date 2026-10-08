# Expert review of October 2026: stage D

Stage D is the three-to-six-month work of the review: what the platform needs to grow beyond one market, one
database server and one site. Each item is in the code or the configuration, tested, and documented. None of it is
needed for the first launch; each part is switched on by configuration when its signal in the capacity model
(`CAPACITY_MODEL.md`, section 6) is reached. The work found five defects along the way, and they are fixed (section 2).
Section 3 says what each item leaves for later.

## 1. What changed

| # | Item | Change | Where | Checked by |
|---|---|---|---|---|
| D1 | Time zone and currency per market | A market is a country with its time zone, currency and language (`ref.market`, Syria the default). Companies and people belong to the market of their country; stations take the time zone of their city. Days, cash limits, dashboards, reports and exports read the market of the data, never a fixed zone; platform reports read one market at a time. Opening a market creates the platform's wallets in its currency; a trip is priced only in the currency of an open market; counter cash is measured per currency. The web and mobile apps format dates and money in the user's market | `db/schema/1061_markets.sql`, `app/markets.py`, reports, dashboards, `frontend/src/i18n`, `mobile/src/i18n` | 8 database checks; `test_markets.py` (4); `test_code_rules.py::test_no_fixed_time_zone_or_currency`; invariants TRIP-CURRENCY and MARKET-TIME-AND-MONEY |
| D2 | Telemetry database for positions | With `MASSLAK_TELEMETRY_DATABASE_URL` set, the history of vehicle positions goes to a PostgreSQL of its own (`db/telemetry/schema.sql`: daily partitions, append-only login, retention from the primary, legal holds respected). The primary grades each batch for the driver's own trip, keeps each vehicle's latest position and closes signal alerts (`ops.accept_positions`); the trust rules exist once (`ops.position_flags`) and both stores use them. If the telemetry database is down, positions get 503 and the apps resend them; the live map keeps moving. Without the setting nothing changes | `db/schema/1063_telemetry.sql`, `db/telemetry/`, `app/telemetry.py`, `routers/driver.py`, the worker, `deploy/telemetry/` | 2 database checks; `test_telemetry.py` (5), run in CI against a second API configured for it; promtool tests for `TelemetryDown`, `TelemetryPartitionMissing`; invariant POSITION-GRADED-ONCE |
| D3 | Warehouse fed by change data capture | The primary publishes 14 tables of facts and dimensions with column lists that leave out everything personal (publication `masslak_dw`, one vetted list in `sys.dw_columns()`). The warehouse subscribes (`db/warehouse/build.py`): same tables, first copy in parallel, changes within seconds, and a `dw` schema with daily sales by market and local day, trip load, daily ledger and payments, refreshed every 15 minutes without blocking readers. The replication login reads exactly the published columns. `wal_level = logical`, a 20 GB cap on what a slot may hold, every replication command logged, and alerts for a slot holding WAL, a slot with no reader and a slot decoding with a foreign plugin | `db/schema/1062_warehouse_publication.sql`, `db/warehouse/`, `deploy/warehouse/`, `docker-compose.yml`, `deploy/pitr`, staging | 3 database checks; CI job "Data warehouse (change data capture)" (two servers, first copy, a streamed change, equal counts, the analyst's login, personal columns refused, full re-copy); promtool tests; invariant WAREHOUSE-NO-PERSONAL-DATA |
| D4 | Sharding study by company | A tool places every table under a split by company, counts rows that point across companies and money transactions that would cross nodes, and measures skew. Result: 55 % of the bytes sit in tables that reach their company only through a parent, and 94 to 100 % of money transactions touch a platform wallet, so a split by carrier would make almost every payment a two-node transaction; no transaction mixes currencies, so a split by market costs nothing. The capacity model's stage 3 now splits by market first and by carrier last, after the platform's wallets are split per carrier | `db/tools/shard_study.py`, `docs/database/SHARDING_STUDY.md`, `CAPACITY_MODEL.md` | run on the volume database (135,005 bookings) and on the demo-flow database |
| D5 | Partitioned bookings | `sales.booking` is partitioned by ranges of 10 million ids, so the 21 tables that refer to a booking by id keep their foreign keys unchanged. The reference, the public id and the booker's idempotency key stay unique over all partitions through `sales.booking_key`, written by a trigger in the same statement. Partitions are created two ranges ahead by the daily upkeep and watched (`masslak_partition_ids_ahead`). The conversion is generic (`sys.partition_by_id`) and keeps every grant, column grant, policy (of the table and of the 12 tables whose policies read it), trigger, comment and publication; generic triggers name the partitioned table in the audit trail and the JSON contracts | `db/schema/1064_partitioned_bookings.sql`, `app/modular/engine.py`, `db/tools/` | 3 database checks; every booking, payment, agency, refund and module test of the full suite runs on the partitioned table; upgrades of the volume database (135,005 bookings, 10 s with the other files) and of the long-lived test database reconcile |
| D6 | Automatic failover and a second site | Patroni with a synchronous standby (no committed transaction lost), etcd, HAProxy routing to the primary by Patroni's health API, pgBackRest archiving to a repository in each site, and a Patroni standby cluster at the second site promoted by a person (`deploy/ha/`). The API lists every server with `target_session_attrs=read-write`, answers 503 `SERVICE_BUSY` with `Retry-After` while no primary answers, and reports ready only on a primary. Standby figures and alerts `NoFailoverCandidate`, `NoSynchronousStandby`. A drill tool measures the time back and the writes lost | `db/schema/1065_failover.sql`, `deploy/ha/`, `app/errors.py`, `app/readiness.py`, `db/tools/failover_drill.py`, `HIGH_AVAILABILITY.md` | 1 database check; `test_failover.py` (8); promtool tests; two drills on a development pair (asynchronous and synchronous): writing back 2.3 s after the promotion, nothing lost, the API ready again on its own after 2.2 s (`evidence/failover_drill_dev_2026-10-08.json`) |

## 2. Defects found and fixed

- **Reports in UTC could not be saved (found by D1's tests).** A report definition whose time zone was UTC was refused
  with a server error, because the time-zone check accepted only area/city names. It now accepts UTC.
- **The volume generator double-counted shared wallets (found by D4).** After a volume run, three DEFERRED wallets
  disagreed with the ledger: the generator stored the full ledger sum as their balance, and the entries still waiting
  for the roll-up were counted a second time when the balance was read. It now stores only what was rolled up.
- **The sharding tool read plain tables as empty (found while checking D4's figures).** Rows and sizes came only from
  partitions, so every table that is not partitioned counted zero. The figures above are from the corrected tool.
- **Lookups and seeding resolved references to a partition (found by the full suite on D5).** A foreign key to a
  partitioned table appears once per partition in the catalogue; the module engine took one of those copies and
  read a partition the application may not read (403 on eight screens), and the demo seeder found no rows. Every
  catalogue reader (the engine, the documentation and dependency tools, the audit pack, the sharding study) now
  keeps the top-level key only, and the rule is in STANDARDS.md.
- **A database failover would have shown error pages (found while building D6).** A broken connection or a server
  shutting down reached the client as a server error (500). They are now 503 with `Retry-After`, like a lock timeout.

## 3. What each item leaves for later

- **D1:** no exchange between currencies: a passenger pays in the trip's currency from a wallet in that currency.
  Prices round to whole currency units, and the price shown to search engines assumes two decimals (the Jordanian
  dinar has three). Screens show times in the
  viewer's market; per-station display for cross-border trips is next. A market is opened by a reviewed migration.
- **D2:** the telemetry database is one server; in production it is archived like the primary. Exports of raw
  positions for an authority need an endpoint reading `tel.position` by trip. TimescaleDB compression is optional.
- **D3:** a role with `REPLICATION` can decode every table with another plugin; this is detected (alert, server log),
  not prevented, so the replication password is kept like the standby's. Columns added to the publication fill older
  rows only after `--resync`. PostgreSQL 16 can decode on a standby, which would move this load off the primary.
- **D4:** skew between carriers must be measured on a restored copy of production before any split by carrier.
- **D5:** a lookup by booking reference probes each partition's index (cheap at tens of partitions); at hundreds, a
  lookup through `sales.booking_key` to the id would prune to one. Detaching a closed year to the archive database is
  documented, not automated. Converting another large table after launch needs a maintenance window.
- **D6:** Patroni, etcd and HAProxy are configured, not yet exercised end to end: the drill ran on two plain servers
  with a scripted promotion. Staging repeats it on the real layout before that layout carries production traffic,
  and promotes the second site once. The single-server stack keeps its manual promotion until the servers exist.

## 4. Tests

- Database: 425 checks pass on a fresh build (17 new in stage D: markets 8, warehouse 3, telemetry 2, partitioned
  bookings 3, failover 1).
- API and unit tests on a fresh database: 336 pass and 10 are skipped in the full run (5 need the external proxy; 5
  are the telemetry tests, which need an API configured with a telemetry database). The telemetry tests (5) pass
  against a second API configured for them, as CI runs them, and `test_failover.py` (8) passes. New files:
  `test_markets.py` (4), `test_telemetry.py` (5), `test_failover.py` (8).
- CI: a data warehouse job with two PostgreSQL servers, the telemetry tests through a second API, promtool with
  tests for the new alerts (43 rules), pinned images for the new overlays.
- Drills: two failover drills (evidence file), the warehouse across two servers and within one, the telemetry
  upkeep, and the bookings conversion on a database of 135,005 bookings.
- Data dictionary, ERD and README figures regenerated from a fresh build: 488 tables (8 partitioned), 425 checks.
