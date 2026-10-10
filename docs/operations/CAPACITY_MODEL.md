# Capacity model: ten million operations a day

**The owner's direction (8 October 2026):** in full operation the platform may reach 10 million operations a day or
more. The architecture and the database design are recalculated on that basis.

**What this document gives:**
- the load, the data volumes and the server sizes at that volume;
- the hotspots the design removes, and what was changed for them (schema files `1052_scale_ten_million.sql` and
  `1053_outbox_partitions.sql`);
- the measurements made so far;
- the stages by which the platform grows, with the measured signals that start each one.

**How to read the figures:**
- Volumes and rates follow from the stated assumptions.
- Throughput per server comes from measurements on a 4-vCPU development host, scaled by core count. Such scaling
  only gives a planning figure.
- Staging confirms these figures at the rates in section 7 before they are relied on.

## 1. What an operation is, and the target

**An operation** is a business transaction written to the database, for example:
- a booking with its payment;
- a shuttle boarding with its automatic charge;
- a ticket scan;
- a wallet movement;
- a shipment event;
- a school attendance record;
- a notification sent.

**Counted separately:**
- reads (search, timetables, seat maps), served mostly from caches and replicas;
- raw vehicle positions, which are telemetry.

| Level | Operations a day | Use |
|---|---|---|
| Owner's figure | 10 million | The full platform, all phases (scenario d below) |
| Design target | 20 million | The database tier carries twice the figure without redesign |
| Growth path | 50 million and more | Stage 3 (section 6): more machines, not a new design |

## 2. Scenario d: the full platform

**Adds to the study's three scenarios (17.1).** Scenarios a, b and c stay as written; d is the full platform with all
phases open:
- 12 million registered users, 2.5 million active each day;
- 20,000 tracked vehicles, trucks included, reporting every 10 seconds for 16 hours a day.

| Operation | Per day |
|---|---|
| Shuttle boardings paid automatically (QR or NFC) | 4,500,000 |
| Intercity bookings with payment: bus, rail, transit (about 1,000,000 tickets) | 600,000 |
| Ticket scans and boarding events | 1,000,000 |
| Wallet top-ups, transfers, refunds and payouts | 600,000 |
| Taxi rides and car rentals | 500,000 |
| School transport: runs, attendance, hand-overs | 800,000 |
| Freight: shipments, legs, cash on delivery, proof of delivery | 500,000 |
| Notifications sent (SMS, push, e-mail) | 1,500,000 |
| **Total operations** | **10,000,000** |
| Vehicle positions (telemetry, counted apart) | 115,000,000 |
| API requests (2.5 million users × 2.5 sessions × 30 requests) | 187,500,000 |

## 3. Rates

**Rules, as in the study (17.1):**
- The peak hour carries 12 % of the day; the commuting peak of the shuttle carries 15 %.
- Bursts inside the hour are three times the hour's average.
- Holiday seasons multiply intercity bookings by four.
- The design margin is 1.5 times the burst.

| Rate | At 10 million a day | At the 20 million design target |
|---|---|---|
| Operations, average over the day | 116 /s | 231 /s |
| Operations, peak-hour average | 333 /s | 667 /s |
| Operations, burst | 1,000 /s | 2,000 /s |
| **Operations, design rate** | **1,500 /s** | **3,000 /s** |
| Database write transactions, design rate (1.5 per operation: the operation and its follow-up by a worker) | 2,250 /s | 4,500 /s |
| Intercity bookings in a holiday burst (2.4 million a day in season) | 240 /s | 480 /s |
| Shuttle boardings in the commuting burst | 560 /s | 1,120 /s |
| Ledger entries, design rate (about 15 million a day) | 2,300 /s | 4,600 /s |
| Outbox events, design rate (about 8 million a day) | 1,250 /s | 2,500 /s |
| Vehicle positions in service hours | 2,000 /s | 2,000 /s (more vehicles means stage 2 sooner) |
| API requests, peak-hour average / burst | 6,250 / 18,750 /s | 12,500 / 37,500 /s |
| API requests, design rate after caches (about 30 % reach the API) | 16,000 /s | 32,000 /s |

## 4. Data volume

Row sizes include their indexes and are estimates.

| Data | Per day | Kept in the database | Steady size |
|---|---|---|---|
| Vehicle positions | 115 M rows, about 25 GB | 7 days (daily partitions dropped whole) | about 175 GB, or on the telemetry cluster from stage 2 |
| Ledger entries and transactions | 15 M + 6.3 M rows, about 5 GB | 25 months online; closed fiscal years then archived (stage 3) | about 3.7 TB |
| Outbox events | 8 M rows, about 5.6 GB | 30 days; 90 days for days with partner deliveries (daily partitions) | 170 to 500 GB |
| Audit change log and access logs | 12 M rows, about 7 GB | 13 months online, then the signed archive with object lock | about 2.8 TB |
| Bookings, tickets, passengers, seats | about 2 GB | by the lifecycle matrix (bookings 10 years: archived by fiscal year at stage 3) | grows about 0.7 TB a year |
| Shuttle rides, boardings, charges | about 3.2 GB | by the lifecycle matrix | grows about 1.2 TB a year |
| Notifications | 1.5 M rows, about 0.75 GB | 365 days | about 270 GB |
| **Write-ahead log** | about 100 GB in stage 1 (about 50 GB once positions leave in stage 2) | archived compressed (about four times smaller) for the 7-day recovery window | about 175 to 350 GB in object storage |

**Primary database size:**
- about 7 TB at the end of the first year at this volume (ledger 1.8 TB, audit 2.6 TB, bookings and rides 1.9 TB, the rest under 1 TB);
- 12 to 16 TB by the third year;
- storage is planned at 16 TB of NVMe, expandable.

## 5. Hotspots and what the design does about them

| Hotspot at this volume | What would happen | What the design does | Where |
|---|---|---|---|
| **Shared wallets.** Every boarding credits its carrier's wallet; every card top-up debits the gateway clearing wallet; every sale credits commission and tax | All those transactions queue on one row each. Measured: postings stopped at 865/s and fell to 688/s at 32 clients | Shared wallets are DEFERRED: a posting appends its entry and takes no lock; a roll-up every 5 s folds entries into the stored balance; the balance that counts is `fin.wallet_balance`. A debit that must stay covered queues only with other debits of the same wallet. Passenger and family wallets stay IMMEDIATE (one owner, exact balance). Refunds debit the escrow wallet one at a time, so a refund is posted last in its transaction and holds the wallet only until the commit (booking burst, review stage B); per-carrier escrow wallets are the next step if the staging burst shows lock waits on it | 1052; measured 2,654 postings/s at 8 and 32 clients, 3.8 times more at 32, reconciliation clean |
| **Ledger size.** About 5.5 billion entries a year | Indexes and the daily reconciliation become heavy; the daily full scan becomes impossible | Monthly partitions; each closed day is totalled per wallet with a running total; nothing is posted into a closed day; reconciliation reads the last running total and the open days only; a past day is re-verified daily | 1052 |
| **The outbox.** About 8 million events a day | Deleting millions of rows a day bloats the table; the queue scan slows | Daily partitions dropped whole; one pending-queue index (the duplicate removed); the worker claims 50 events per transaction, each in its own savepoint | 1053; worker change |
| **Positions.** 2,000 a second in service hours | One request and one commit per position; dashboards searching the history | Daily partitions dropped whole; batch endpoint (up to 120 positions in one request and one transaction); the latest position of every vehicle kept in one row, written once per insert statement | 1048, 1052 |
| **Seats of a sought-after trip** | Hundreds compete for 49 seats | Row locks per seat segment in one order (already); a virtual waiting room for opening days (study 17.3) | Existing |
| **Audit log.** About 12 million rows a day | The largest data set; would hold years online | A wallet change made only by a posting is not copied (the entry is the record); the log keeps the row key on updates (a defect fixed); 13 months online, older months dropped only when the signed archive covers them (`audit_export record`) | 1052 |
| **Connections.** 30 to 40 API instances at peak, each with a pool | Thousands of database sessions | PgBouncer in transaction mode in the stack; the full API suite passes through it (222 tests) using 20 server connections | Stack |
| **Reports** | Heavy queries next to bookings | Read replica, required in production (1051); a data warehouse kept current by logical replication of facts and dimensions, without personal data (1062, `docs/database/WAREHOUSE.md`) | Existing; 1062 |
| **Cost of database rules** (RLS, triggers) | CPU per write | Measured per trigger on staging (`track_functions`), 1 ms budget per row, alert `TriggerCostOverBudget` | 1051 |

## 6. Servers and growth stages

**Planning figure for one 64-vCPU primary on NVMe, at 60 % CPU:**
- 300 to 500 full booking transactions a second;
- 3,000 to 5,000 light write transactions a second.

**How it was reached:**
- **Booking with payment:** 46 per second on 4 shared vCPU, with the API and the load generator on the same host.
- **Ledger posting with no shared row:** 2,654 per second on the same host.
- **Scaling:** both were scaled to a dedicated database host at 60 % CPU.

**The result:** one well-sized primary carries the 20 million design target once telemetry has moved off it. Staging
confirms this before stage 2 is relied on.

| Stage | Volume | Database | Application | Other services |
|---|---|---|---|---|
| **1. Launch** | up to about 3 M operations a day | Primary 32 vCPU, 256 GB RAM, 4 TB NVMe; one streaming replica (reports, failover); PgBouncer | 4 to 12 API instances (2 vCPU), 2 workers | Redis (3 nodes), object storage, CDN |
| **2. Growth** | 3 to 20 M a day | Primary 64 vCPU, 512 GB RAM, 16 TB NVMe; two replicas under Patroni with a synchronous standby and a second site (`HIGH_AVAILABILITY.md`); **telemetry database** for the history of positions (1063, `MASSLAK_TELEMETRY_DATABASE_URL`) | 10 to 40 API instances, autoscaled; 4 to 8 workers | Search cluster (3 nodes), Redis cluster, data warehouse fed by change data capture (1062) |
| **3. National scale** | above 20 M a day | Split by market first (markets share no transaction and no currency, 1061); then move whole domains that share no money with bookings (freight, school transport) to their own cluster. Distribution by carrier comes last and only after the platform's wallets are split per carrier: measured, 94 to 100 % of money transactions touch a platform wallet (`docs/database/SHARDING_STUDY.md`) | as needed | Closed fiscal years of the ledger and of bookings (partitioned by id, 1064) detached to an archive database |

**What starts the next stage:**

| Signal | Threshold | Action |
|---|---|---|
| Positions sustained | above 500 a second, or above 30 % of the primary's WAL | Telemetry cluster (stage 2) |
| Primary CPU at the peak hour | above 60 % for two weeks after tuning | Stage 2 hardware; then stage 3 |
| Commit latency p99 | above 20 ms at the peak hour | Investigate locks and I/O; then the next stage |
| WAL per day | above 150 GB | Telemetry off the primary; review indexes |
| Outbox pending age | above 2 minutes at the peak with 8 workers | More workers; partner deliveries on their own workers |
| Roll-up lag / open ledger days | above 5 minutes / above 2 days | Worker health; long transactions (alerts `WalletRollupLagging`, `LedgerDaysNotClosing`) |
| `fin.ledger_txn` rows | above 2 billion | Archive closed fiscal years (stage 3) |

## 7. What staging must show for this volume

The launch gate for capacity (`LAUNCH_GATES.md`, gate 3) measures the launch volume at 1x, 2x and 5x. For the
10 million figure, staging also runs the database tier alone at the design rates. The data comes from
`db/tools/generate_volume.py` at production size (12 months), and the tests are:
- `db/tools/wallet_contention_bench.py` at 64 and 128 clients;
- the full-mix load test at its highest level;
- a position injector at 2,000 positions a second, in batches.

| Check | Pass criterion |
|---|---|
| Mixed write load at 2,250 transactions a second for one hour | p99 commit under 20 ms; no deadlocks; 0 wallet mismatches after |
| Ledger postings to shared wallets at 2,300 entries a second | Roll-up lag under 30 s; reconciliation clean |
| Positions at 2,000 a second in batches | Insert p99 under 50 ms; `vehicle_position` current within 15 s |
| Outbox at 1,250 events a second | Oldest pending event under 2 minutes |
| Day close and reconciliation on a 12-month ledger | Both finish within 30 minutes |
| Failover of the primary under that load | The API recovers; RTO 30 min, RPO 60 s |

## 8. What was changed and measured (8 October 2026)

**Database: schema files 1052 and 1053 (migrations 1.34.0 and 1.35.0).** In short:
- DEFERRED balances for shared wallets;
- monthly ledger partitions with closed-day totals and incremental reconciliation;
- latest vehicle positions;
- storage settings for every partition;
- the audit online window, with archive checkpoints;
- the audit row key on updates;
- daily outbox partitions, with deliveries keeping the event's day.

**Application:**
- every reader of a shared wallet uses the balance that counts;
- holds are checked against that balance;
- statements compute a running balance from the closed-day totals;
- the worker rolls up balances every 5 s and claims events in batches;
- new batch position endpoint;
- `audit_export record`.

**Stack:**
- PgBouncer in transaction mode;
- `track_functions` on staging;
- alerts for roll-up lag and open ledger days.

**Measured (`evidence/scale_ten_million_2026-10-08.json`):**
- **Shared wallets:** 3.1 to 3.8 times more postings per second at 8 to 32 clients, with clean reconciliation.
- **Upgrade of a populated database from 1051:** 46,049 ledger entries and 14,547 events converted in 5.6 s, wallets
  reconciled before and after, 30 days closed and verified.
- **Tests:** 357 database checks pass. The full API suite (222 tests) passes three ways: directly, through
  PgBouncer, and on the upgraded database.

## 9. Stage D of the expert review (8 October 2026)

What stage D added to this model, each part tested (`docs/operations/REVIEW_STAGE_D.md`):

- **Markets (1061):** each market keeps its own time zone, currency and platform wallets; no transaction mixes
  currencies, which makes the market the first and cheapest way to split the platform.
- **Telemetry database (1063):** with `MASSLAK_TELEMETRY_DATABASE_URL` set, the history of positions (about half the
  primary's WAL at the target) goes to its own PostgreSQL; the primary keeps the grades, the latest position and the
  alerts. Without it, nothing changes.
- **Data warehouse (1062):** analysis runs on a database of its own, kept current within seconds by logical
  replication, never on the primary or its replica.
- **Sharding study:** a split by carrier would make almost every payment a two-node transaction; the stage 3 row
  above now says what must change first.
- **Bookings partitioned by id (1064):** ranges of 10 million ids (about a week at the design peak), created ahead by
  the daily upkeep; vacuum, reindex and archiving work one partition at a time. Converting the 135,005 bookings of
  the volume database took part of a 10-second upgrade.
- **Automatic failover (1065, `deploy/production/ha`, installed with two database hosts; H-01):** Patroni with a synchronous standby (no committed transaction lost) and a
  second site; measured on a development pair: writing back 2.3 s after the promotion.

## 10. Database connections with N API servers (code review of October 2026, H-04)

Each API server runs `WEB_CONCURRENCY` processes (2 in the image); each worker replica runs one. Every process opens
its own pools (`backend/app/db.py`), and waits at most `MASSLAK_DB_ACQUIRE_TIMEOUT` (5 s) for one of its connections
before it answers 503 with `Retry-After` (counted in `masslak_db_pool_timeouts_total`).

| Pool, per process | At most | Goes to |
|---|---|---|
| main (every request) | 20 | PgBouncer, transaction mode |
| audit (security console) | 2 (`MASSLAK_DB_AUDIT_POOL_MAX`), none when idle; the role is capped at 20 in all | the primary, directly |
| reports | 4 (`MASSLAK_DB_REPORTS_POOL_MAX`), none when idle | the read replica, directly |
| telemetry (optional) | 10 | the telemetry database |

With **P = 2N + W** processes (N API servers, W worker replicas):

| Where | Connections | Limit | Holds while |
|---|---|---|---|
| Clients of PgBouncer | 20 P | `MAX_CLIENT_CONN` 4,000 | P ≤ 200 |
| PgBouncer to the primary | 80 at most (`DEFAULT_POOL_SIZE` 60 + `RESERVE_POOL_SIZE` 20), whatever N | | always |
| The primary in all | 80 + at most 20 (audit, capped by its role, 1076) + about 8 (replica, warehouse slot, backups, migration, superuser reserve) | `max_connections` 200 | always: 108 at most, whatever N (review of 1.47.0, R-46) |
| The read replica | the reports running at the moment (idle pools hold none), at most 4 P | `max_connections` 200 | in practice always; P ≤ 48 if every process ran four reports at once |

`max_connections` was PostgreSQL's default of 100 until this review: three API servers and two workers could
then reach 80 + 32 + 8 = 120 with the security console busy, and the direct connections would have been refused. It
is now 200 on the primary, the replica and every Patroni member (a hot standby needs at least the primary's value).

**What the count means for load.** The database never sees more than the 80 PgBouncer connections at work, however
many API servers run: more servers add waiting clients, not database sessions. At the design rate of 4,500 write
transactions a second (section 3) and about 5 ms a transaction, 23 connections are busy on average; 60 leave room for
bursts and slow statements, and the reserve 20 open only when a client has waited 5 s
(`reserve_pool_timeout`). When all 80 are busy, PgBouncer queues the clients. A request never waits without end: its statements stop at 30 s, and a process whose own pool is exhausted answers 503 within 5 s. A saturation that lasts shows as the alerts `PgBouncerClientsWaiting` (clients waiting for two minutes) and `PgBouncerSlowWait` (the longest wait above 1 s for two minutes).

**When adding servers:** the primary's count no longer grows with P (release 1.48.0: idle audit pools hold no
connection and the audit role is capped at 20, so the 10 to 40 API servers of phase 2 fit); raise
`DEFAULT_POOL_SIZE` only with measurements from staging (gate 3), since more concurrent transactions on the same
rows add lock waits rather than throughput.
