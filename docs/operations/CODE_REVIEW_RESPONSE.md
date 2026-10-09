# Response to the code review of October 2026 (release 1.47.0)

Three reports were assessed against the code and a database built from release 1.46.0 (commit f5d0ce7): the
third party's technical and operational analysis (answered in `EXTERNAL_REPORT_RESPONSE.md`), its follow-up on that
answer, and a deep engineering review of the code by a second firm. This page records what the last two found,
what was verified, and what changed in release 1.47.0, with the test that proves each change and its commit on the
branch `claude/land-shipping-development-dz68oz`.

Nothing in either report touched the data model, the booking logic or the money rules. Every finding that held was
in operations and hardening. Verifying them turned up more than the reports said: eleven defects in all, listed in
section 4, each fixed with a test that failed before the fix.

## 1. Findings of the code review, and what changed

| Ref | Finding | Verdict | What changed | Proof | Commit |
|---|---|---|---|---|---|
| H-01 | The request limiter keeps its buckets in each process's memory | Held, and worse: the image runs two processes, so every limit was doubled on one server; the sign-in limit of 20 a minute per address also locked out subscribers behind carrier-grade NAT | 1068: sign-in, registration and password requests draw from buckets in PostgreSQL shared by every process and server, per address (300/min) and per account (10/min, keyed hash); other limits are split between the processes of a server | Two connections share one bucket; 100 users behind one address pass while the 11th attempt on one account waits; checked by hand over HTTP | ba54234 |
| H-02 | A failed activity-log write is swallowed | Held; the data changes themselves were never at risk (78 audit triggers in the same transaction) | Counted (`masslak_audit_write_failures_total`), logged, alert `AuditWriteFailures` | A lost record is counted and logged without breaking the request; promtool test | d4ac936 |
| 3.2 | Metrics live in each process's memory | Held, and worse: a scrape reached one of two processes at random, so counters jumped and rate alerts read the jumps as resets | Each process leaves its figures in a file every 5 s; the process that answers sums them | 200 requests read 201 on every scrape, never less, with two workers | ea64e4c |
| H-04 | Connections multiply with the number of API servers | Partly: PgBouncer already capped the database at 80 | Wait for a connection at most 5 s, then 503 with `Retry-After`; PgBouncer metrics and alerts; the connection count for N servers written down, which showed PostgreSQL's default of 100 connections would be exceeded at three servers, now 200 | An exhausted pool answers busy in under 2 s and recovers; `CAPACITY_MODEL.md` section 10 | ea64e4c, this release's docs |
| H-06 | Duplicate delivery and backlog of outbox events | Partly: claiming with `SKIP LOCKED`, backoff and the five-minute backlog alert existed | Alert `OutboxEventsFailed` when an event gives up after eight attempts; the runbook says how to queue it again | promtool test | ea64e4c |
| H-07 | The application image is `masslak:latest` | Held: no way back without rebuilding | Images tagged with their commit, the previous one kept; an update that does not become ready rolls back by itself; `update.sh --rollback` | CI rolls back on the real stack and the site answers | cf8774d |
| M-01 | The API reports version 0.1.0 | Held | The version is the database's release (`sys.current_release`) | The reported version equals the release | cf8774d |
| 3.1 | `/api/docs` and `/api/openapi.json` are open in production | Held | Open in the sandbox only, or with `MASSLAK_API_DOCS=true`; the partners' document stays published | Closed outside the sandbox, opened by the setting | cf8774d |
| 3.3 | No central redaction of logs | Held: unexpected database errors were logged with their values | Every log record is redacted when it is created: e-mail addresses, numbers of ten digits or more, bearer tokens, secret query values | Redaction of a database error and an access line | d4ac936 |
| 5 | Scenarios not covered: refund against boarding, a payment after the hold, write isolation | Partly: the cancel/board race was already safe in the database | Tests for all three. Two of them found defects: see section 4 (late provider payment) | `test_scenarios.py`, `test_payment_options.py`, `test_isolation.py` | 39ecfa9 |
| 7.3 | Partition upkeep after a delay | Held, and worse: rows waiting in the default partition made the upkeep fail, and the failure aborted the ledger close and the wallet reconciliation with it | 1070: the missing partition is created and its rows moved without firing triggers twice | DB checks with a counting trigger; the outbox case reproduced and fixed | 39ecfa9 |
| M-05 | Files are stored on a local volume | Held: enough for one server, not for two | S3-compatible object store with server-side encryption confirmed on every write; move and verify tool; backups name the bucket | Unit tests against a stand-in server and the AWS signing example; in CI, a third API on SeaweedFS passes the document tests, and answers 503 while the store is stopped | 718e86d |
| M-02 | Web types may drift from the API | Held for the web and mobile apps (the partners' API had a contract test) | Every address the web and mobile apps call is checked against the server's routes and methods | `test_api_contract.py`; it found the support page answered 404 | b3b60a3 |
| 9 | No accessibility or right-to-left checks | Held | axe-core (WCAG 2.1 A/AA) and a sideways-scroll check on 33 pages, English and Arabic, phone and desktop, in CI | 132 page views pass with no critical or serious finding, after the fixes of section 4 | b3b60a3 |
| 7.1 | Migrations on large tables | Held as a rule to write down | `db/README.md`: expand, then contract one release later; the rollback stays possible | The upgrade tests from 1.36.1, 1.45.0 and 1.46.0 (release verification) | cf8774d |
| 10 | Who owns a failover | Held as a page to write | `HIGH_AVAILABILITY.md`, ownership and fencing; a Patroni watchdog added so a hung Patroni cannot leave two primaries | Configuration parsed in review; drills on staging (gate 1) | this release's docs |

## 2. What the review asked to check, and found in place

| Subject | Evidence |
|---|---|
| `SECURITY DEFINER` functions | Every one has a fixed `search_path` and no `EXECUTE` for `PUBLIC` (DB checks) |
| Tenant context on a reused connection | Set with `set_config(..., true)`, local to the transaction |
| Company isolation | `test_isolation.py` reads every company column as every company; row-level security on every table (489 of 489) |
| Payment notifications | HMAC-SHA256 over time and body, refused after five minutes, one row per event |
| Idempotency of payments and refunds | Keys on both; a refund never exceeds its payment (`payment_refund_within_amount`) |
| Sessions | HttpOnly, SameSite=Strict, Secure; a password change ends other sessions; permissions read on every request |
| Account lockout | One `UPDATE` in the database, right with any number of servers |
| Uploads | Type from the first bytes, size limit, random storage name, AES-256-GCM, quarantine until scanned |
| The last seat and the last cargo space | Concurrent requests, one wins; a burst of 240 bookings a second with invariants checked |
| Replica staleness for reports | Freshness limits per report, the report states its data's age |
| Migration fingerprints and drift | Checked in CI since review stage A5; migration rehearsal tool for gate 4 |
| Key rotation | `app.tools.rekey` with tests; keys ACTIVE and DECRYPT_ONLY |
| High availability | Patroni, synchronous standby, second site and drill tool in `deploy/ha` |

## 3. The third party's follow-up

| Point | What existed | What was missing, now done | Commit |
|---|---|---|---|
| Locks and pool exhaustion at peak | Statement 30 s, lock 5 s and idle transaction 2 min limits for the application role; a lock timeout answers busy | A time limit on waiting for a pooled connection (5 s, then 503) | ea64e4c |
| Write-once audit archive | Ed25519-signed, chained export to a bucket in compliance mode; the chain's tip recorded off the platform | The schedule existed only in the runbook: `deploy/audit-archive.sh` hourly from `server-setup.sh`, and the alert `AuditArchiveBehind` (1069) | d4ac936 |
| The driver's phone clock | Minutes of drift had no effect | A larger defect: section 4, first row | aaa1646 |

## 4. Defects found while verifying (in no report)

| Defect | Effect before the fix | Fix | Commit |
|---|---|---|---|
| An offline boarding uploaded after the credential expired was refused | Passengers boarded without a network showed as not boarded | The server judges a scan at its own time (never after the upload); the driver app keeps the server's clock and warns when the phone's is off | aaa1646 |
| Limits doubled by two processes; sign-in limit per address only | Brute force had twice the room; real users behind one mobile address could be locked out | H-01 above | ba54234 |
| Metrics jumping between processes | Rate and latency alerts unreliable | 3.2 above | ea64e4c |
| A late partition upkeep failed and stopped the daily upkeep | Ledger close and wallet reconciliation would stop until someone moved rows by hand | 1070 | 39ecfa9 |
| A provider's confirmation after the platform stopped waiting credited nothing | Money taken by the provider and owed to nobody in the books | 1071: credited to the payer's wallet, booking confirmed only if it still holds its seats, flagged for finance with an alert | 39ecfa9 |
| Trip ratings readable by every company and passenger | A carrier saw competitors' ratings, comments and who had travelled with them | 1072: the rater, the rated carrier and the platform only | 6a5f8d1 |
| The support page answered 404 | Users and crawlers got an error status for a real page | Added to the server's list of app pages, kept in step by a test | b3b60a3 |
| The tracking form and the support table pushed phone pages sideways | Content cut off in both directions | Fixed, checked on every page in CI | b3b60a3 |
| Three form controls without an accessible name | Unusable with a screen reader | Named | b3b60a3 |
| 52 scrollable tables unreachable with the keyboard; links told apart by colour only; dimmed cancelled bookings at 3.6:1 contrast | Below WCAG 2.1 AA | Focusable tables, underlined links, a dashed border instead of dimming | b3b60a3 |
| PostgreSQL's default of 100 connections | Refused direct connections from three API servers on | 200 on every server, with the formula | this release's docs |

## 5. Not done, and why

| Suggestion | Reason |
|---|---|
| Move module registration out of `main.py` | Organisational; changes no behaviour and fixes no defect. Done when the file next needs it |
| Redis for request limits | PostgreSQL is already the source of truth and sign-in traffic is small; another component means more operations, monitoring and recovery without a need |
| Automatic retries in the web interface | Only ever for reads, when needed; never for money, which already holds |

## 6. What the code cannot close

These decide the launch and are in `LAUNCH_GATES.md`; the tools are ready, the inputs come from outside the system.

| Ref | Condition | Needs |
|---|---|---|
| C-01 | Independent penetration test (gate 8), retest of critical and high findings | A contract with a testing firm |
| C-02 | Load at the capacity target on production-like staging (gate 3) | Staging servers |
| C-03 | Point-in-time recovery at the target data size (gate 1) | Staging servers |
| C-04 | Real payments: provider sandbox, then daily reconciliation | Provider contracts |
| 10 | A public TLS certificate on a real domain (`deploy/trial.sh`) | A public server and domain |
| 7.1 | A migration rehearsal on a production-sized copy (gate 4) | A copy of production-sized data |

## 7. How to check

```
db/tests/run.sh -h localhost -U postgres                      # 449 database checks
cd backend && python -m pytest tests -q                       # the API suite, against a running API
cd frontend && npm run build && npm run ui-checks             # accessibility and right-to-left, against that API
cd deploy/monitoring && promtool test rules alerts_test.yml   # every alert added here
```

The release package `masslak-1.47.0` carries `VERIFICATION.md` with the results of these on the packaged files.
