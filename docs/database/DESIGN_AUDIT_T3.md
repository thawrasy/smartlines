# Response to the technical audit of design document v3.7 (T3)

The audit reviewed the design document v3.7 only: no code, no running database, no infrastructure. Its findings are
numbered R-01 to R-20 in the report. Here they are written **T3-01 to T3-20**, so they are not confused with the
third-party audit of version 3.6 (`THIRD_PARTY_AUDIT.md`), which used R-01 to R-15 for other subjects.

**Its verdict:** a mature design that should be built on; no redesign. Production waits for P0 and P1 to be closed or
formally accepted.

**How we checked it:** every finding was compared with a database built at schema file 1047 and with the code.
- 9 findings were real gaps.
- 6 were partly in place.
- 4 are operational conditions of the launch.
- 2 described controls that already existed but did not appear in the document.

**What changed:** the owner approved the fixes.
- Schema file `1048_design_audit_t3.sql` (migration 1.30.0) carries the database side.
- The application changes and tests are listed per finding.
- Design document v3.8 states the result.

## Findings and their status

| Finding | Priority (audit / ours) | What we found | What changed | Evidence |
|---|---|---|---|---|
| T3-01 Recovery not proven | P0 / P0, launch gate | Runbooks for backup, point-in-time restore and failover existed; RPO and RTO were proposed, not approved; no restore drill had run (no production yet) | Nothing in the repository; the drill and the owner's RPO/RTO approval are launch conditions | `docs/operations/RUNBOOKS.md` sections 2 and 3 |
| T3-02 Webhooks, HTTP and SSRF | P0 / P2 | **Already in place:** the database accepts only `^https://`; delivery resolves DNS on every attempt, refuses private, loopback, link-local and metadata addresses, connects to the address it checked (no DNS rebinding), follows no redirect, verifies TLS, and sends no personal data unless enabled. **The gap:** government adapter and authority endpoints had no transport rule | Those endpoints accept only `https://`, `sftp://` or `amqps://` | DB test T3-02; `test_webhook_egress.py` |
| T3-03 Break-glass without expiry | P0 / P1 | The log had an optional approver and no expiry | See "T3-03: break-glass access" below | DB tests T3-03 |
| T3-04 References in money and signatures | P0 / P0 | Confirmed, and worse for signatures. `sec.document_signature (doc_type, doc_ref_id)` had no check and was missing from the reference registry, because the registry test only looked for `X_type`/`X_id` pairs. Ledger references were checked only by the weekly sweep | Signatures, ledger transactions, family spending and legal holds check the referenced row when written. Real foreign keys were not used for signatures because they would create new two-way schema dependencies (sec↔acct, sec↔brd; test H-07). Signatures are written once and only revoked. The registry test now also finds `X_type`/`X_ref_id` pairs | DB tests T3-04 |
| T3-05 Scheduled reports | P1 / P1 | **Already in place:** every run re-checks the owner's status, membership and permissions, and stops the schedule if any is missing. **The gap:** any e-mail address could be a recipient | Recipients must be active members of the owner's company. For a platform report: platform accounts or the domains in `reports.platform_recipient_domains`. Checked when the schedule is created and again at every run; departed recipients are dropped, and the schedule stops if none remain | API test `test_a_report_goes_only_to_approved_recipients` |
| T3-06 Size of release 1 | P1 / P2 | Every table of a switched-off phase is already closed in the database (`phase_gate`) | Design v3.8 states the deployment and ownership of releases 1A and 1B; the single-database decision is reviewed at each large phase | Design v3.8, study 22.4 |
| T3-07 Isolation with connection pooling | P1 / P2 | **Already in place:** a pooled-connection test, a write sweep across every company table, automated checks of SECURITY DEFINER functions and search paths, and an application role that owns no table and has no BYPASSRLS | No change; the repeat behind PgBouncer in transaction mode belongs to the staging run | `test_integrity_audit.py`, `test_isolation.py` |
| T3-08 Migrations without downtime | P1 / P1 | The expand/contract procedure is in the runbook. **The gap:** `upgrade.sh` set no lock or statement limits | `upgrade.sh` waits at most 5 s for a lock and stops a statement after 30 min. Both limits are configurable; the failed file rolls back on its own. The rehearsal on production-size data belongs to staging | `db/upgrade.sh`, runbook section 4 |
| T3-09 Performance | P1 / P1, launch gate | The load and row-level-security benchmark tools and first measurements existed but were not in the document | No change; the run on staging at 1x, 2x and 5x the peak is a launch condition | `PERFORMANCE_BASELINE.md` |
| T3-10 GPS retention | P1 / P1 | **Confirmed:** three values disagreed (setting 7 days, lifecycle matrix 90 days, monthly partitions holding up to about 60) | Daily partitions, dropped whole after the retention; one source (the lifecycle matrix, 7 days; the old setting is removed). Existing positions were moved, older ones dropped. A dataset legal hold stops the purge; violation evidence keeps its own copy for 730 days | DB tests T3-10 |
| T3-11 Position evidence | P1 / P1 | **Confirmed:** no device event id, sequence or server receive time; the server time was used as the position time | See "T3-11: position evidence" below | DB tests T3-11, API test `test_positions_carry_evidence_and_duplicates_are_ignored` |
| T3-12 Outbox contract | P1 / P1 | **Already in place:** event id, retries and a dead state. Inbound payment notices are de-duplicated (unique provider and event id), and payments and refunds carry idempotency keys. **The gap:** no schema version, correlation or order | Every event carries `schema_version`, `correlation_id` (the request id) and `aggregate_seq`, numbered per aggregate and surviving the purge. Webhooks send them. The contract for consumers is `docs/integration/EVENTS.md` | DB test T3-12 |
| T3-13 Audit verification outside the database | P1 / P1 | **Already in place:** chained, checksummed exports for object-lock storage. **The gap:** no signature, and no protection against a chain cut short | Manifests are signed with Ed25519 (`MASSLAK_AUDIT_SIGNING_KEY`). `head` prints the tip that the evidence custodian records outside the platform. `verify --public-key --min-sequence` finds forged, unsigned and missing manifests. A separate account for the bucket is a launch condition | API test `test_signed_chain_detects_forgery_and_truncation` |
| T3-14 Regulatory changes | P1 / P1 | **Confirmed:** one person could change a requirement; the application had no write path, but the owner could change it in SQL | See "T3-14: requirement changes" below | DB tests T3-14, API test `test_a_requirement_change_needs_a_second_platform_user` |
| T3-15 Malware scanning | P1 / P1 | **Confirmed:** no quarantine. Uploads were already limited to PDF, PNG and JPEG by their first bytes | See "T3-15: file quarantine" below | DB tests T3-15, API tests for rejected and pending files |
| T3-16 Monitoring and SLOs | P2 / P2, launch gate | The database already raises alerts for unapproved schema changes, orphans and wallet mismatches; dashboards, SLOs and on-call are not in place | New alerts listed in the runbook; dashboards, SLOs and on-call are launch conditions | Runbook section 8 |
| T3-17 Verification numbers in the document | P2 / P2 | **Confirmed:** the cover said 183 API tests, the verification chapter 175 | `generator/verification.py` collects the counts, commit, migration, schema hash and versions from the test run; the document prints only those | Design v3.8, section 9 |
| T3-18 Time zones and currencies | P2 / P2 | Trip times are already `timestamptz`; templates keep local times with the city's zone. **The gap:** cities had Damascus as a default zone | A city must name a valid IANA zone. The exchange-rate source and rounding policy come before multi-currency sales | DB test T3-18 |
| T3-19 Access reviews | P2 / P2 | **Confirmed:** self-review was possible, and a sensitive read could lack an actor | Nobody reviews their own access; every sensitive read names a user, an API client or a named service, and a request id | DB tests T3-19 |
| T3-20 AI and contact center | P2 / phase gate | Phase deferred by the owner | Adopted as the entry gate of that phase | Study 22.4 |

### T3-03: break-glass access

- **Expiry:** every grant has a mandatory expiry, at most `security.break_glass_max_minutes` (240).
- **Approval:** an approver other than its user, or a declared emergency.
- **Context:** an incident reference and a scope.
- **Alerts:** it raises `security.break_glass_opened` when opened.
- **Expiry needs no job:** `sec.break_glass_active` stops answering true when the time is up.
- **Upkeep:** closes expired grants and raises `security.break_glass_unreviewed` for any grant not reviewed within 24 hours of its end.
- **Sealed:** a grant cannot be extended, rewritten or deleted.
- **Independent review:** a grant is reviewed after it ends, with a note, by someone other than its user.

### T3-11: position evidence

- **Device fields:** each position carries the device's event id and sequence, the device time, the server receive time, the provider and a mock-location flag.
- **Filing time:** a position is filed under the device time when that time is plausible.
- **Duplicates:** a position sent again is dropped.
- **Trust grade:** each position gets HIGH, LOW or REJECTED. The checks look for late, out-of-order, inaccurate, network-only, impossible-speed and mock positions.
- **Violations:** a violation built on low-trust positions is confirmed or reported only after a person reviews it.
- **Web driver page:** sends the event id, sequence and device time.

### T3-14: requirement changes

- **Proposal:** a platform user proposes a change with `sys.propose_requirement_change`. The impact is measured at that moment: how many vehicles, drivers or companies would fall short.
- **Decision:** a second platform user decides with `sys.decide_requirement_change`. The change then applies with its date.
- **Direct changes refused:** a direct update is refused outside a migration.
- **API:** `GET /api/admin/compliance/requirements`, `POST .../{code}/changes` and `POST /api/admin/compliance/changes/{uid}/decision`.

### T3-15: file quarantine

- **Quarantine:** every file starts as PENDING.
- **Scanner checks:** the scanner (`app/modules/documents/scanner.py`) checks:
  - the real type and that it matches the stored type;
  - the EICAR test signature;
  - active content in PDFs;
  - data appended after the end of the file.
- **ClamAV:** used through clamd when `MASSLAK_CLAMD` is set, and required in production, where a file stays PENDING without it.
- **Download and approval:** only a CLEAN file is downloaded, signed or approved; a verdict is final.
- **Who sets the result:** only the platform's scanner sets a scan result.
- **Retries:** the worker retries files that are still pending.

## What remains outside the repository (launch conditions)

1. RPO and RTO approved by the owner, and a timed restore drill (T3-01).
2. Staging with production-size data: load test at 1x, 2x and 5x the peak, migration rehearsal, and the isolation test behind PgBouncer (T3-07, T3-08, T3-09).
3. An egress proxy for the integration workers (T3-02, defence in depth).
4. A separate account for the audit archive bucket, with object lock in compliance mode, and a custodian who records the signed tip (T3-13).
5. A ClamAV service next to the API (T3-15).
6. Dashboards, SLOs, on-call and alert drills (T3-16).
7. A penetration test by an external party.

## Acceptance tests the audit proposed (section 7)

| Area | Where it is tested |
|---|---|
| Restore | Staging drill (runbook section 2) |
| Row-level security with switching companies on one connection | `test_integrity_audit.py`, write sweep in `test_isolation.py` |
| Migrations under load | Staging rehearsal (runbook section 4) |
| Booking race | `loadtest.run --same-seat 100`, DB tests on concurrent holds |
| Money: repeated webhooks, cut connections, refunds | `test_payments.py` (idempotency keys, unique provider events) |
| Outbox duplicates and order | Envelope fields and the consumer contract (`EVENTS.md`); DB test T3-12 |
| GPS replay, duplicate, out of order, spoof | DB tests T3-11, API test on positions |
| Webhooks: HTTP, redirect, internal IP, rebinding, invalid TLS | `test_webhook_egress.py` (http, credentials, metadata and private addresses, rebinding at delivery, redirects not followed), `test_integration.py`; TLS is verified by the default context |
| Reports after a role is removed | Scheduler re-checks at every run; API test on recipients |
| Files: malicious, fake MIME, huge | DB tests T3-15, API tests on rejected and pending files; upload type and size limits |
| Audit tampering | `test_audit_export.py` (forged, unsigned and missing manifests) |
| Compliance self-approval | DB tests T3-14, API test |
