# Expert review of October 2026: stage B

Stage B covers what must be true before general launch. Most of it is work on staging and by people: the launch
gates. The code side is done: the tools that run and judge the gates, the burst and soak tests, the report freshness
limits, the cash ageing report, and the SSRF and DNS rebinding tests. Two defects found along the way are fixed. The
gates themselves stay open until they run on staging (section 3).

## 1. What changed

| # | Item | Change | Where | Tests |
|---|---|---|---|---|
| B1 | Booking burst at 240 a second | `loadtest.burst` sends bookings at a fixed rate whether the server keeps up or not (an open loop). Each arrival is one traveller on one of a few busy trips: seat map, hold (another seat once if it was taken), book and pay, and in part a cancellation with refund. It checks no seat sold twice, every ledger transaction balanced, wallets reconciled and deadlocks, measures p95 and p99 per step, locks and WAL, and gives PASS, FAIL or INCONCLUSIVE (the generator itself fell behind) | `backend/loadtest/burst.py` | `test_launch_gates_kit.py` (verdicts); runs in `evidence/burst_dev_2026-10-08.json` |
| B2 | Soak of 8 to 24 hours | `loadtest.soak` runs a steady load with think time. Every minute it samples API memory (all worker processes), database size, dead rows and autovacuum on the busy tables, transaction-id age, the outbox and webhook backlogs, replica lag, connections, lock waits, deadlocks, and per-window errors and p95. The verdict uses the trend after warm-up: memory growth, a growing backlog, dead rows, replica lag, deadlocks, error budget, booking latency | `backend/loadtest/soak.py` | `test_launch_gates_kit.py`; a 20-minute run in `evidence/soak_dev_2026-10-08.json` |
| B3 | Report freshness | The lag of the reports replica is measured against the primary (zero when it has replayed everything written). Financial reports (finance datasets) are refused with `REPORT_DATA_STALE` past 60 s, and a scheduled one is retried five minutes later. Other reports are served with a warning past 5 minutes (lists) or 1 hour (totals). Every answer and export carries the lag next to `data_as_of`; the limits are in `sys.setting` `reports.replica_lag` | `backend/app/db.py`, `modules/reports/freshness.py`, `api.py`, `scheduler.py`, report screen | `test_review_stage_b.py` |
| B4 | Cash ageing | `fin.cash_aging()` splits what each carrier owes from counter sales into 0-7, 8-30, 31-60, 61-90 and over 90 days, oldest sales paid first; a carrier sees only its own. It feeds **Payments > Counter cash** (over 30 days, over 90 days, oldest unpaid sale), the report **Counter cash ageing**, the metrics `masslak_cash_owed_minor`, `masslak_cash_overdue_minor`, `masslak_cash_overdue_carriers`, `masslak_cash_near_limit_carriers`, and the alerts `CashOverdue` and `CashNearLimit` | `db/schema/1057_review_stage_b.sql`, `modules/cash/service.py`, reports catalog, `finance/Payments.tsx`, `deploy/monitoring` | 5 database checks; `test_review_stage_b.py`; promtool tests |
| B5 | SSRF and DNS rebinding | 48 cases on partner webhook URLs and provider addresses (`test_ssrf.py`); two gaps fixed (section 2). The proxy's block list gained 64:ff9b:1::/48, 2002::/16 and 2001::/32, and its self-test probes the shared range, NAT64 and numeric spellings | `modules/integration/webhooks.py`, `modules/payments/api.py`, `deploy/egress/squid.conf`, `selftest.sh` | `test_ssrf.py` |
| B6 | Launch gate kit | `db/tools/launch_gates.py check` reads `evidence/` and judges every gate against its success criterion. Only staging (egress: production) evidence counts; a development run shows as "development only". `template <5-8>` gives the skeleton of the evidence people fill in by hand. LAUNCH_GATES.md now says how each gate is run and how its evidence is named | `db/tools/launch_gates.py`, `LAUNCH_GATES.md` | `test_launch_gates_kit.py` |

## 2. Defects found and fixed

**Refunds queued on the escrow wallet (found by the burst test).**
- **What happened:** under the burst, every waiting session was a ledger posting on one row, the platform escrow
  wallet.
- **Why:** a debit of a shared wallet locks it until commit, so that the wallet stays covered (1052). The refund was
  posted in the middle of the cancellation, so the lock was held through the allocation updates and the outbox event.
- **Fix:** the refund is now posted last, so the lock lasts only from the posting to the commit.
- **Effect:** on the development host at 25 bookings a second, the two versions were run alternately. Book-and-pay
  p95 fell by 22 to 30 % and refund p95 by 23 to 33 %. At 30 a second, the knee of that host, the version with the
  refund in the middle collapsed (hold p95 1.8 s, book 3.1 s), while the reordered one passed in one run (hold p95
  30 ms) and failed in another. Runs that close to saturation are noisy.
- **What remains:** escrow debits still pass one at a time. Their rate is bounded by the commit time (about 1 ms on
  NVMe), far above the roughly 24 refunds a second at the launch peak. Gate 3 watches the lock waits on staging;
  per-carrier escrow wallets are the next step if they show (stage D).

**Two SSRF gaps in the application's own address check (found by the SSRF tests).**
- **The shared range 100.64.0.0/10 counted as public.** A cloud metadata service lives there (100.100.100.200).
  Python's `is_private` leaves this range out; `is_global` does not.
- **NAT64 addresses counted as public.** `64:ff9b::a9fe:a9fe` is 169.254.169.254 behind a NAT64 gateway. IPv4 inside
  IPv6 is now judged as IPv4.
- **Exposure:** the egress proxy already refused both in production, so the exposure was the sandbox and the second
  layer of the defence.
- **Also hardened:**
  - Outside the sandbox, registration refuses internal names (`localhost`, single labels, `.internal`, `.local`, ...),
    numeric spellings (`2130706433`, `0x7f000001`, `127.1`) and ports other than 443.
  - A delivery has a total deadline of 30 s, so an endpoint that answers one byte at a time cannot hold a worker
    thread.
  - Payment provider addresses follow the same rules.

## 3. The gates after stage B

`python3 db/tools/launch_gates.py check` on the repository's evidence:

| # | Gate | Status | What it needs |
|---|---|---|---|
| 1 | Recovery | Development only | pgBackRest restore on staging within RPO 60 s and RTO 30 min |
| 2 | Egress | Open | The self-test in production with the real allowlist |
| 3 | Capacity | Development only | Burst passing at 240 and 480 a second, a 1,200 a second run recorded, and a soak of 8 hours or more, all on staging hardware with production-size data |
| 4 | Migrations | Development only | The rehearsal of the release on a production-size copy |
| 5 | Monitoring | Open | An alert drill acknowledged within 15 minutes, with the on-call rota in place |
| 6 | Audit archive | Open | The locked bucket, an export verified and retrieved, the custodian's receipt |
| 7 | File scanning | Open | ClamAV next to the API on staging: clean served, EICAR and scanner-down refused |
| 8 | Security testing | Open | The external test and retest, every critical and high finding closed |
| 9 | AI and contact centre | Not applicable yet | The phase stays closed until its DPIA is approved (enforced since 1055) |

None of these can be closed from the code. They need the staging environment, the production network and bucket,
the on-call rota and the external firm (owner decisions of 8 October 2026). The decision on general launch stays as
it was: after gates 1 to 8 pass with signed evidence.

## 4. Tests

- Database: 399 checks pass on a fresh build (5 new: cash ageing, ageing as of an earlier day, the metrics, carrier
  isolation, privileges).
- API and unit tests: 317 pass and 5 are skipped (external proxy) on a fresh database. The new files are
  `test_ssrf.py` (48), `test_review_stage_b.py` (8) and `test_launch_gates_kit.py` (9).
- Alert rules: promtool, with tests for `CashOverdue` and `CashNearLimit`.
