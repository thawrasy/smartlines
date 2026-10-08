# Performance baseline (first measurements)

These are the first runs of the load and row-level security tools (third-party audit R-12). They were taken on a
development container, so they prove the tools and the correctness of the booking spine under concurrency, not the
platform's capacity. The capacity evidence comes from the same tools on staging, with production-size data and hardware
(see `RUNBOOKS.md`, section 10).

**Environment:**
- 4 vCPU and 15 GB, shared by the database, one API process and the load generator.
- PostgreSQL 16 with PostGIS 3.
- Demo data: 34 published trips and about 2,800 seeded module rows.
- Date: 7 October 2026.

## One seat, one hundred users

`python -m loadtest.run --same-seat 100`: 100 requests for the same seat, sent at once.

| Granted | Refused (seat taken) | Other errors | Result |
|---|---|---|---|
| 1 | 99 | 0 | Exactly one hold, as gate C requires |

## Booking spine at rising concurrency

`python -m loadtest.run --levels 10,25,50 --seconds 20`. Each virtual user loops: search, seat map, hold one free seat,
release it.

| Users | Step | Requests | per second | p50 ms | p95 ms | p99 ms | Errors |
|---|---|---|---|---|---|---|---|
| 10 | search | 1,692 | 84 | 22 | 34 | 55 | 0 |
| 10 | hold | 1,462 | 73 | 40 | 55 | 75 | 0 |
| 25 | search | 1,767 | 88 | 53 | 81 | 130 | 0 |
| 25 | hold | 1,520 | 75 | 98 | 158 | 208 | 0 |
| 50 | search | 1,844 | 91 | 97 | 216 | 297 | 0 |
| 50 | hold | 1,599 | 79 | 178 | 328 | 426 | 0 |

**What this shows:**
- No errors and no double holds at any level.
- Throughput levels off at about 320 requests per second in total. That is the limit of one API process sharing four
  cores with the load generator, which is why latency grows with users while throughput stays flat.
- In staging the API runs several workers on separate hosts. The test must then be repeated at 1x, 2x and 5x the expected
  peak.

## Shared wallets under contention (1052)

`db/tools/wallet_contention_bench.py` posts real ledger transactions through the production triggers. Half of them
credit one carrier wallet; the other half debit the gateway clearing wallet. Measured on the same 4-vCPU host
(`evidence/scale_ten_million_2026-10-08.json`):

| Clients | Before: shared row updated by every posting | After: DEFERRED (no row lock on credits) |
|---|---|---|
| 1 | 401 postings/s, 2.5 ms | 420 postings/s, 2.4 ms |
| 8 | 865 postings/s, 9.3 ms | 2,654 postings/s, 3.0 ms |
| 32 | 688 postings/s, 46.5 ms | 2,625 postings/s, 12.2 ms |

**What this shows:**
- **Before:** the shared row capped the whole platform's money postings, and more clients made it worse.
- **After:** throughput rises with clients until the host's CPUs are the limit.
- **Reconciliation:** clean after both runs.

## Cost of row-level security

`python -m loadtest.rls_benchmark --runs 40` compares two paths on the hot queries:
- **Owner path:** the table owner, with row-level security bypassed.
- **Application path:** the application role in a carrier's context.

| Query | Owner p50 ms | RLS p50 ms | RLS p95 ms | Overhead |
|---|---|---|---|---|
| Trip search | 0.21 | 0.44 | 0.64 | +0.23 ms |
| Seat map of a trip | 0.18 | 1.11 | 1.24 | +0.93 ms |
| Company bookings | 0.08 | 0.25 | 0.35 | +0.17 ms |
| Tickets of the company's trips | 0.38 | 1.26 | 1.70 | +0.89 ms |
| Wallet balances | 0.06 | 0.21 | 0.32 | +0.15 ms |
| Ledger of a wallet | 0.10 | 0.38 | 0.47 | +0.28 ms |

**What this shows:**
- The policies add under one millisecond per query on this data.
- Most of the added time is planning: the seat map plans in about 1.4 ms and executes in 0.2 ms. The API's prepared
  statements absorb most of the planning cost.
- **One point to watch at scale:** the trip-visibility condition of seat and ticket policies is planned here as a hashed
  scan of the visible trips. With production volumes of trips, the planner should switch to an index lookup per trip.
  This must be confirmed with `EXPLAIN (ANALYZE, BUFFERS)` on staging data. If it does not switch, the remedy is a
  `SECURITY DEFINER` visibility function on the trip, keyed by the trip id; the policy stays and only its plan changes.

## End to end: booking, payment, refund, tracking and reports (T3-09)

`python -m loadtest.run --levels 10,25,50 --seconds 20 --mix full --owner-dsn ...`:
- **Passengers:** each one searches, opens the seat map, holds a seat, books and pays from the wallet, then cancels for a
  refund.
- **Drivers:** two drivers send a position every second.
- **Carrier staff:** run the daily sales report every 2 seconds.

The database counters come from `pg_stat_database` and `pg_stat_activity`, sampled every 0.5 s. The full output is in
`evidence/load_test_full_mix_2026-10-07.json`.

| Users | Book and pay p50 / p95 / p99 ms | Refund p95 ms | Search p95 ms | Position p95 ms | Report p95 ms | Errors | Deadlocks | Commits/s | WAL MB | Longest lock wait |
|---|---|---|---|---|---|---|---|---|---|---|
| 10 | 82 / 120 / 147 | 95 | 30 | 65 | 94 | 0 | 0 | 1,376 | 28.5 | 0.04 s |
| 25 | 204 / 475 / 660 | 434 | 60 | 121 | 211 | 0 | 0 | 1,338 | 26.8 | 0.74 s |
| 50 | 329 / 560 / 723 | 551 | 194 | 329 | 372 | 0 | 0 | 1,488 | 29.0 | 0.58 s |

**What this shows:**
- No errors and no deadlocks at any level.
- After 3,582 bookings and their refunds, wallet reconciliation found **zero** mismatches, and every ledger transaction
  balances.
- The cache hit ratio stayed at 100 %, and no temporary files were written.
- The longest lock wait (0.74 s) is bookings queueing on the same trip's seats and the same wallets. That serialisation
  is by design and is correct.
- Throughput levels off at about 46 bookings per second plus their refunds. As in the first run, that is the limit of
  one API process sharing four cores with the load generator and the database (host load 4.3 at 50 users).

## Next measurements (staging)

1. Load staging with one year of projected data: trips, bookings, tickets, positions, ledger.
2. Run `loadtest.run` at 1x, 2x and 5x the expected peak for 30 minutes each. Then run a soak test for 4 hours at 1x.
3. Run `loadtest.rls_benchmark --runs 200`, and `EXPLAIN (ANALYZE, BUFFERS)` on the 30 most frequent queries from
   `pg_stat_statements`.
4. Record CPU, memory, I/O, lock waits, deadlocks, connections and pool use alongside the latencies.
5. Compare the results with the p95 and p99 targets the owner sets for search, availability, booking and payment.
