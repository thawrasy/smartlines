# Response to the re-audit of design document v3.8

The auditors re-read the design document v3.8. They had no access to the repository or to a running build.

**Their verdict:**
- **Findings:** 10 closed on paper, 6 partly addressed, 4 open or deferred.
- **Development:** continue.
- **General launch:** not before recovery (T3-01) and egress (T3-02) are proven.

We agree with the verdict.

**What this round does:**
- **Raw evidence:** answers their request with a pack generated from the candidate build (`db/tools/evidence_pack.sh`),
  so they can re-run every test.
- **Code and tooling:** closes what the repository can close, in schema file `1049_recheck_operations.sql` (migration
  1.31.0), in the application, and in operations tooling with measured results.

**Correction to our own document:**
- **The gap:** the v3.8 change log described only the transport rule for government endpoints.
- **What was already there:** the webhook SSRF controls existed and were tested, but the document did not mention them.
- **Consequence:** this is why T3-02 read as "no evidence" of internal-address, metadata, rebinding or redirect
  protection.
- **Fix:** design v3.9 now describes those controls (section "Outbound connections").

## Status after this round

| Finding | Auditors (v3.8) | Now | What was added | Evidence (in the pack) |
|---|---|---|---|---|
| T3-01 Recovery | Open | **Mechanism proven; production drill pending** | `db/tools/restore_drill.py` restores to a point in time and after a total loss of the server, then checks the restored database: <ul><li>wallets against the ledger;</li><li>ledger balance;</li><li>orphans;</li><li>audit seals;</li><li>the schema hash;</li><li>row counts.</li></ul> First run passed. Production WAL archiving and pgBackRest configuration added (`deploy/pitr`). RPO 60 s and RTO 30 min proposed for the owner's approval | `evidence/restore_drill_2026-10-07.json`: point in time exact (counts match, nothing after the target); server lost: 3.2 s of writes lost, usable in 4.9 s |
| T3-02 SSRF and egress | Partial | **Closed in the repository** | Every outbound connection (webhooks, payment providers, SMS, SMTP) goes through an egress proxy, and production refuses to start without one. **Squid:** <ul><li>refuses private, loopback, link-local, metadata and reserved IPv4 and IPv6 addresses after its own DNS lookup;</li><li>allows only allowlisted names (fixed providers, plus partner endpoints the worker keeps current);</li><li>tunnels only ports 443, 465 and 587.</li></ul>The API and worker containers have no route out. **Application layer, in front:** https only, the address checked and pinned at every attempt, no redirects | `tests/api/test_webhook_egress.py` (10 cases: http, credentials, metadata, private, IPv6, IPv4-mapped, rebinding at delivery, redirects), `test_egress.py` (proxy tunnel, refusals, production check; also run against a real Squid), `deploy/egress/selftest.sh` (all forbidden targets 403 on a real Squid), and a CI step in the deployment stack |
| T3-03 Break-glass | Closed on paper | Closed; re-run in the pack | none | `tests/db_tests.log` (T3-03 checks), `audit_pack/role_attributes.csv` (no SUPERUSER or BYPASSRLS for application roles) |
| T3-04 References | Closed on paper | Closed; re-run in the pack | none | `tests/db_tests.log` (T3-04), `audit_pack/polymorphic_references.csv`, `orphan_findings.csv` |
| T3-05 Scheduled reports | Partial | **Closed** | <ul><li>A report with personal or money columns is **sensitive**. It needs the owner's explicit consent (recorded), goes only to named accounts (never to a domain), and arrives as a per-recipient link valid 72 hours, never as an attachment.</li><li>Every download is counted and logged in `audit.data_access_log`.</li><li>A recipient who leaves the company loses the link and the schedule; another user's link answers 404.</li></ul> | `test_recheck.py::test_a_sensitive_report_needs_consent_and_goes_by_a_personal_link`; earlier tests on removed recipients |
| T3-06 Scope and phases | Partial | **Closed** | `db/tools/release_map.py` generates `docs/operations/RELEASE_MAP.md` from the database: <ul><li>per release, the tables, owning teams, external services, workers and switches;</li><li>launch scope 1A and 1B; 92 tables closed by `phase_gate` until their switch opens.</li></ul> | `docs/RELEASE_MAP.md`, `audit_pack/phase_map.csv`, the R-14 database checks, `test_modules.py` |
| T3-07 RLS and pooling | Closed on paper | Closed; re-run in the pack | none | `tests/api_tests.log`, the write sweep and pooled-connection tests, `audit_pack/security_definer_functions.csv` |
| T3-08 Migrations | Partial | **Closed in the repository; staging run pending** | `db/tools/migration_rehearsal.py` applies the new files to the previous release while it runs traffic, and measures locks, WAL and latency. **Documented:** stop criteria, forward-fix rules, and the 1048 plan. The rule is now part of the standards | `evidence/migration_rehearsal_1048_2026-10-07.json` (200,000 rows per table): exclusive lock 1.98 s (2.41 s in a first run), traffic p99 3 ms, 0 errors. The cause (the one-time move to daily partitions) is identified, with its live-database plan |
| T3-09 Performance | Open | **Measured on development; staging run pending** | The load test runs booking, payment, refund, tracking and reports together, and records database counters: commits, deadlocks, WAL, lock waits, cache, temp | `evidence/load_test_full_mix_2026-10-07.json`: 10 to 50 users, 0 errors, 0 deadlocks; 3,582 bookings and refunds reconciled with 0 mismatches |
| T3-10 Position partitions | Closed on paper | Closed; re-run in the pack | Partition gaps are now monitored (`masslak_geo_partitions_missing`) | `tests/db_tests.log` (T3-10), alert `PositionPartitionMissing` |
| T3-11 Position evidence | Partial | **Closed** | <ul><li>Positions record the registered device of the mobile session; a revoked device or a failed attestation rejects them.</li><li>Attestation (Play Integrity or App Attest) is prepared behind a verifier and switched by the requirement `tracking.device_attestation` (OFF until a regulator asks).</li><li>Clock-skew, lateness and replay are tested.</li><li>Thresholds and the review screen for low-trust violations are documented.</li></ul> | DB checks T3-11 (revoked device, missing device when required, clock 10 min ahead, 30 min behind, replay); `test_recheck.py::test_positions_carry_the_device_and_a_failed_attestation_rejects_them`; runbook section 15 |
| T3-12 Outbox contract | Partial | **Closed** | <ul><li>The consumer contract (`docs/integration/EVENTS.md`, which already existed) states at-least-once delivery, per-record order, idempotent inboxes and schema versions.</li><li>Resending a money or authority event now needs a platform approval by a second person.</li><li>Payments, refunds, provider notices and the ledger are reconciled daily, with an alert on any mismatch.</li></ul> | `test_recheck.py::test_resending_a_cancellation_waits_for_a_platform_approval`; DB checks T3-12; `test_integration.py` (duplicates, signatures, retries) |
| T3-13 Audit archive | Closed on paper | Closed; separate account pending | none | `test_audit_export.py` (forged, unsigned and truncated chains) |
| T3-14 Requirement changes | Closed on paper | Closed; re-run in the pack | none | DB checks T3-14, `test_design_audit_t3.py` |
| T3-15 File scanning | Closed on paper | Closed; ClamAV service pending | Scan backlog monitored (`masslak_files_oldest_pending_scan_seconds`) | DB checks T3-15, API tests on rejected and pending files |
| T3-16 Monitoring | Open | **Closed in the repository; deployment pending** | <ul><li>`GET /api/metrics` (bearer token): request counts and latency per route, plus database health from `sys.ops_metrics()`. It covers outbox age, deliveries, partitions, scans, jobs, WAL archiving, connections, locks, long transactions, deadlocks, vacuum, wraparound, replica lag, payments and review queues.</li><li>24 alert rules (`deploy/monitoring/alerts.yml`), proven by promtool unit tests, plus a Grafana dashboard.</li><li>`docs/operations/SLO.md`: objectives proposed for approval, and the on-call arrangement.</li></ul> | `monitoring/promtool.txt` (check and unit tests), `test_recheck.py::test_metrics_need_the_token_and_expose_slis_and_database_health`, DB checks T3-16 |
| T3-17 Traceability | Closed on paper | Closed | The document's numbers come from the run (`verification.py`); the raw logs are in the pack | `tests/*.log`, `evidence/verification.json` |
| T3-18 Time zones | Closed on paper | Closed; re-run in the pack | none | DB check T3-18 |
| T3-19 Access reviews | Closed on paper | Closed; re-run in the pack | none | DB checks T3-19 |
| T3-20 AI and contact center | Deferred | **Gate defined** | Threat model and DPIA, with the acceptance items that must be signed before the phase switches on | `docs/AI_ASSISTANT_THREAT_MODEL_DPIA.md` |

## What only operations can close (launch gates)

**Since this response (8 October 2026):**
- **Owner decisions:**
  - RPO 60 s, RTO 30 min and the SLOs are approved, and stored as settings (`1050_owner_decisions.sql`).
  - Staging and the penetration test are run by external firms or independent testers.
  - Reviewers get time-bound access through the permission matrix only (`sec.external_access_grant`).
- **Go/no-go:** the nine gates of the auditors' follow-up report, section 6, are tracked in
  `docs/operations/LAUNCH_GATES.md`, each with its measurement, evidence and approver.
- **Staging kit:** `deploy/staging` and `docs/operations/STAGING.md`.
- **Penetration test scope:** `docs/security/PENETRATION_TEST_SCOPE.md`.

| Gate | What is ready in the repository | What remains |
|---|---|---|
| Recovery (T3-01) | Drill tool, WAL and pgBackRest configuration, proposed RPO and RTO | Owner approved RPO and RTO (8 Oct 2026); timed drill from pgBackRest on production-size data |
| Egress (T3-02) | Proxy, configuration, self-test, CI check | Run the stack's proxy in production with the providers' domains in the allowlist |
| Capacity (T3-09) | Full-mix load test with database counters | Staging with production-size data, at 1x, 2x and 5x the peak |
| Migrations (T3-08) | Rehearsal tool, criteria, plans | Rehearsal on a copy of production for each release |
| Monitoring (T3-16) | Metrics, rules, dashboard, SLOs | Prometheus, Alertmanager and Grafana deployed; on-call rota; first alert drill |
| Audit archive (T3-13) | Signed chain, verifier | Bucket with object lock in a separate account; custodian records the tip |
| File scanning (T3-15) | Scanner with ClamAV support, fail-closed | ClamAV service next to the API |
| Penetration test | Evidence pack | External test |

## How to verify this build

```sh
./db/tests/run.sh -h <host> -U <owner> > db-tests.log                    # database checks
# start the API on a seeded copy, then:
cd backend && python -m pytest tests -q > api-tests.log                   # API tests
db/tools/evidence_pack.sh <database> /tmp/masslak-evidence --db-log db-tests.log --api-log api-tests.log -h <host> -U <owner>
```

The pack's `SHA256SUMS` and archive hash identify what was delivered. `source/SOURCE.txt` names the commit and says
whether the working tree was clean.
