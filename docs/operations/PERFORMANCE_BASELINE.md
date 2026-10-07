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

## Next measurements (staging)

1. Load staging with one year of projected data: trips, bookings, tickets, positions, ledger.
2. Run `loadtest.run` at 1x, 2x and 5x the expected peak for 30 minutes each. Then run a soak test for 4 hours at 1x.
3. Run `loadtest.rls_benchmark --runs 200`, and `EXPLAIN (ANALYZE, BUFFERS)` on the 30 most frequent queries from
   `pg_stat_statements`.
4. Record CPU, memory, I/O, lock waits, deadlocks, connections and pool use alongside the latencies.
5. Compare the results with the p95 and p99 targets the owner sets for search, availability, booking and payment.
