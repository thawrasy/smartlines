# Operations runbooks

These procedures cover the operational items of the third-party technical audit (R-09, R-10, R-11, R-12), the technical
audit of design 3.7 (T3-03, T3-08, T3-13, T3-14, T3-15; `docs/database/DESIGN_AUDIT_T3.md`) and the operations gate of the
architecture reports. Each one names the tool in the repository that carries it out.

**Assumed setup.** The commands assume a PostgreSQL 16 server with PostGIS 3, a primary and a streaming standby managed by
Patroni, pgBackRest for backups, and object storage with object lock for archives. Replace the commands where the chosen
hosting differs.

**Keep these procedures alive.** Every procedure here is rehearsed before launch, and then on the schedule in the last
section.

## 1. Incident response

1. **Detect.**
   - Alerts come from monitoring: API error rate, p95 latency, database connections and locks, outbox lag, replica lag.
   - Alerts also come from the outbox events `security.ddl_change` and `integrity.orphans_found`.
2. **Declare.**
   - The on-call engineer opens an incident case and names an incident lead.
   - Severity 1 means bookings or payments are failing; severity 2 means a degraded feature; severity 3 means no
     customer impact.
3. **Contain.**
   - Switch off the affected module through its feature switch (`PUT /api/admin/modules/{key}`). The database closes the
     module's tables the moment its switch is off (`module_gate` and `phase_gate`).
   - Put the API in read-only maintenance if money is at risk.
4. **Recover.** Use the runbook that matches the failure (sections 2 to 6).
5. **Verify.** Run the daily upkeep (`SELECT sys.run_maintenance()`), then check:
   - wallet reconciliation shows no mismatches (`fin.reconcile_wallets()`);
   - there are no orphans (`sys.find_orphans()`);
   - the outbox is drained.
6. **Review.** Write a blameless review within five working days and add a test that would have caught the failure.

## 2. Backup and point-in-time restore (RPO and RTO)

- **Targets:** RPO 60 seconds and RTO 30 minutes, approved by the owner (below).
- **Configuration:** `deploy/pitr/postgresql.pitr.conf` (WAL archiving every 60 s at most, streaming standby) and
  `deploy/pitr/pgbackrest.conf` (encrypted repository in a separate account, schedule, restore command).
- **Backups:**
  - pgBackRest full backup weekly, differential daily, WAL archived continuously to object storage.
  - Backups are encrypted (`repo1-cipher-type=aes-256-cbc`) with a key held in the key service.
  - Backup retention follows `gov.v_lifecycle_matrix.backup_retention_days`, 35 days by default.
- **Restore to a point in time** (into a new server first, never over the primary):
  ```
  pgbackrest --stanza=masslak --type=time --target="2027-03-29 10:15:00+03" --target-action=promote restore
  ```
- **After any restart of the primary** (a crash, maintenance or a failover): run
  `pgbackrest --stanza=masslak check` (with pgBackRest) or `./deploy/pitr/check-archive.sh` (any layout; `update.sh`
  runs it after every update). It forces a WAL switch and proves archiving works. After a crash recovery
  PostgreSQL applies `archive_timeout` only once its checkpointer first wakes, up to `checkpoint_timeout` (5 minutes)
  later, so without this step the window of unarchived WAL can grow past the 60 s RPO (found by the launch gate 1
  rehearsal, `GATE_CLOSURE_PLAN.md`).
- **After a restore:**
  1. Run `db/upgrade.sh` to confirm the schema version.
  2. Run `SELECT sys.run_maintenance()`.
  3. Run `python -m app.tools.keys check`, to prove the key service still opens every data key.
  4. Run the reconciliation checks from section 1.5.
  5. Run `python -m app.tools.files_check` in the API container: every file the restored database refers to is read
     back, decrypted and compared with its recorded size and hash (R-44); it must report nothing missing. With the
     files in an object store, `deploy/restore.sh` first puts back the version each file had when the backup was taken
     (`files_versions.jsonl` in the backup; `python -m app.tools.files_versions restore`, H-04). A backup made before
     release 1.49.0 has no such record: restore the bucket to the database's time by hand first.
- **Targets approved by the owner on 8 October 2026 (T3-01; settings `recovery.rpo_seconds` and `recovery.rto_minutes`):**
  - **RPO:** 60 seconds when the server is lost. WAL is archived at least every `archive_timeout = 60` s; pgBackRest
    archives asynchronously. With the streaming standby, a failover loses only what the standby had not received,
    normally under a second.
  - **RTO:** 30 minutes to a usable database on new hardware, 1 minute for a failover to the standby (section 3).
- **Restore drill (T3-01):** `python3 db/tools/restore_drill.py --source <copy of production> --report <dir> -h ... -U ...`
  rehearses the same mechanism as pgBackRest (base backup, archived WAL, recovery target) on a scratch cluster, in two
  scenarios:
  - **Point in time:** recovery to a chosen moment must contain every transaction up to it and none after.
  - **Server lost:** the server stops with no warning; the drill measures the data lost (RPO) and the time back (RTO).

  Each restored database must pass these checks:
  - wallets reconcile with the ledger, and every ledger transaction balances;
  - there are no references to missing rows;
  - every audit seal recomputes and chains;
  - the schema hash equals the source;
  - row counts match the recovery point.

  The first run is in `docs/operations/evidence/restore_drill_2026-10-07.json`: PASS on the 70 MB demo database. It
  restored to a point in time in 1.2 s; with the server lost, 3.2 s of writes were lost (those after the last archived
  segment) and the database was usable 4.9 s later.
- **Production drill:** monthly, on a production-size copy restored from pgBackRest into an isolated server. Time it,
  record it in `docs/operations/evidence/`, and compare the measured RPO and RTO with the approved targets. The audit
  trail must survive it: compare the latest `audit.ddl_event` and `audit.row_change` ids with the archive (section 7).

## 3. Failover

- **Who decides:** Patroni promotes the standby when the primary fails its health checks, for about 30 seconds of
  detection. The application connects through the Patroni-aware endpoint (HAProxy or PgBouncer in front), so it reaches
  the new primary on reconnect.
- **During failover:**
  - Transactions in flight are rolled back.
  - The API retries idempotent requests. Bookings and payments carry idempotency keys, so a retry never doubles them.
- **Manual switchover** for maintenance: `patronictl switchover --leader <old> --candidate <new>`.
- **The application side** (review stage D6): list every server with `target_session_attrs=read-write`, or go through
  HAProxy port 5000. While no primary answers, the API returns 503 `SERVICE_BUSY` with `Retry-After`, and
  `/api/ready` stays not ready until the pool reaches a primary. Measured on a development pair: writing back 2.3 s
  after the promotion, nothing lost ([HIGH_AVAILABILITY.md](HIGH_AVAILABILITY.md)); the full procedure, the second
  site included, is section 23.
- **Single-server stack (`docker-compose.yml`):**
  - **The replica:** the `db-replica` service is a streaming hot standby. Reports and exports read it; the API and the
    worker refuse to start in production without it.
  - **To promote it:** `docker compose exec -u postgres db-replica pg_ctl promote`. Then point
    `MASSLAK_DATABASE_URL` at `db-replica` and recreate a new replica from it.
  - **If the replica falls behind:** reports show the moment their data reflects (`data_as_of`), and
    `ReplicaLagging` alerts after 30 s.
- **After failover:**
  - Check replica lag on the remaining standby.
  - Check that the outbox worker resumed (`SELECT count(*) FROM sys.outbox_event WHERE status = 'PENDING'`).
  - Run the reconciliation checks from section 1.5.
- **Failure tests** before launch: kill the primary, kill an API instance, kill the worker, block the payment provider,
  delay the broker. After each one, confirm the system recovers without corrupting data.

## 4. Migrations on a live database

- **Expand, migrate, contract:**
  1. Add the new structure (expand).
  2. Deploy code that reads both the old and the new.
  3. Backfill in batches.
  4. Switch reads and writes.
  5. Remove the old structure in a later release (contract).
- **Never edit a schema file that has been applied.** `db/upgrade.sh` refuses to run when one changed (exit code 3,
  nothing applied) and names it; restore the file and add a new file instead. `MASSLAK_SCHEMA_DRIFT=warn` exists for
  development databases only.
- **The record of applied files must match the last release manifest (1058).** Every build and upgrade writes
  `sys.release_manifest`: the release version, the commit, how many schema files are applied and one hash over them.
  `db/upgrade.sh` compares `sys.schema_file` with that hash before it applies anything. A row added or removed by hand
  stops it with exit code 4 (nothing applied), and the alert `ReleaseRecordChanged` fires before that. Compare
  `sys.schema_file` with the last manifest (`SELECT * FROM sys.current_release()`), find who changed the record and
  why, and put it back; `MASSLAK_SCHEMA_DRIFT=warn` passes this check on development databases only.
- **Run** `db/upgrade.sh <database>`. It sets `masslak.migrating=on`, so its schema changes are logged as migrations in
  `audit.ddl_event`. The same changes made by hand raise a `security.ddl_change` alert.
- **Lock and time limits (T3-08):** `upgrade.sh` waits at most `MASSLAK_LOCK_TIMEOUT` (5 s) for a lock and stops a
  statement after `MASSLAK_STATEMENT_TIMEOUT` (30 min).
  - A file that hits either limit rolls back on its own. Bookings never queue behind it.
  - Rerun it off-peak, or split it.
  - Raise a limit only for a planned maintenance window: `MASSLAK_STATEMENT_TIMEOUT=2h db/upgrade.sh ...`.
- **Rehearse** every migration first on a staging copy with production-size data, under synthetic traffic. Record its
  duration, the locks it took and the WAL it wrote.
- **Large tables:**
  - Create indexes concurrently in their own file.
  - Add foreign keys as `NOT VALID`, then `VALIDATE`.
  - Never rewrite a large table during peak hours.
- **Rollback:** restore to the point in time before the migration (section 2) when a contract step has already run.
  Otherwise, deploy the previous application version, which still reads the old structure.

## 5. Keys: envelope encryption and rotation (R-10)

- **Production:**
  - Set `MASSLAK_KMS_PROVIDER=vault`, with `MASSLAK_VAULT_ADDR` (https) and a `MASSLAK_VAULT_TOKEN` allowed only to
    encrypt and decrypt with the Transit key.
  - Data keys are stored wrapped in `sec.key_registry.wrapped_dek`. The API unwraps them at start-up and keeps them in
    memory only. `MASSLAK_FIELD_KEYS` stays unset.
- **Rotate a data key:**
  1. `python -m app.tools.keys new --ref kms://masslak/field/restricted/v2 --kms-key-id masslak-field` prints the
     statements to register the new key. The old key becomes DECRYPT_ONLY.
  2. The database owner runs those statements.
  3. Restart the API.
  4. Run `python -m app.tools.rekey --apply`. It re-encrypts every row, moving the document number and phone number of
     the same row to the new key together.
  5. Run `python -m app.tools.rekey` and confirm it reports zero rows left under the old key.
  6. Mark the old key RETIRED.
- **Rotate the KEK in Vault:** `vault write -f transit/keys/masslak-field/rotate`. Wrapped keys stay readable. Rewrap
  them later with `vault write transit/rewrap/masslak-field`.
- **Check** that every wrapped key opens: `python -m app.tools.keys check`. Run it after every restore and every
  rotation.
- **Break-glass:**
  - Access to Vault's root or unseal keys needs two people.
  - Every use is recorded in `sec.break_glass_log`, with a ticket, a purpose and an expiry.

## 6. Contact data sealing (R-04)

- After upgrading an older database to file 1046, run `python -m app.tools.seal_contacts --apply`.
- Then, as the owner, run the `VALIDATE CONSTRAINT` statements it prints.
- A person's contact left on a party is reported by the tool. Move it to the person's account, then rerun.

## 7. Audit archive with object lock (R-09)

- **Export:** `deploy/audit-archive.sh` runs hourly from cron (installed by `deploy/server-setup.sh`). It runs
  `python -m app.tools.audit_export export` as the audit role into `MASSLAK_AUDIT_ARCHIVE_DIR`
  (default `/var/lib/masslak/audit-archive`): gzip JSON lines and a manifest chained by SHA-256. Outside the sandbox it
  refuses to run without `MASSLAK_AUDIT_SIGNING_KEY_FILE`. Then it runs `MASSLAK_AUDIT_SYNC_COMMAND` (below) and, only
  when the copy succeeded, `record`; it ends by printing the chain's tip. Its log is `/var/log/masslak-audit-archive.log`.
- **Lag:** `masslak_audit_unarchived_seconds` is, per audit log, the age of the oldest record no recorded archive covers
  (1069). Above two hours the alert `AuditArchiveBehind` fires: the export, the copy or the record stopped, or archiving
  was never set up on this server. `masslak_audit_write_failures_total` counts request records the activity log could
  not take (alert `AuditWriteFailures`); the data changes themselves are in `audit.row_change`, written in the same
  transaction.
- **Sync** to a bucket with object lock in compliance mode:
  ```
  aws s3api create-bucket --bucket masslak-audit-archive --object-lock-enabled-for-bucket
  aws s3api put-object-lock-configuration --bucket masslak-audit-archive \
      --object-lock-configuration 'ObjectLockEnabled=Enabled,Rule={DefaultRetention={Mode=COMPLIANCE,Days=2555}}'
  aws s3 sync /var/lib/masslak/audit-archive s3://masslak-audit-archive/ --no-progress
  ```
  In `deploy/.env`: `MASSLAK_AUDIT_SYNC_COMMAND=aws s3 sync {dir} s3://masslak-audit-archive/ --no-progress`
  (`{dir}` stands for the archive directory) and `MASSLAK_AUDIT_VERIFY_KEY_FILE` for the check before recording.
- **Sign (T3-13):** every manifest is signed with Ed25519.
  - The security officer creates the key pair once: `python -m app.tools.audit_export keygen audit.key audit.pub`.
  - The private key goes to the key service. The export job alone receives it, as `MASSLAK_AUDIT_SIGNING_KEY`.
  - The public key goes to every verifier.
- **Separate account:** the bucket lives in a cloud account separate from production, administered by other people. A
  production administrator can neither delete the archive nor forge a signature.
- **Record the tip:** after each export, `python -m app.tools.audit_export head <dir>` prints the sequence and hash of
  the latest manifest. The evidence custodian records it outside the platform (for example, a signed weekly e-mail to
  compliance).
- **Verify** weekly, and after any restore:
  `python -m app.tools.audit_export verify <dir> --public-key audit.pub --min-sequence <recorded sequence>`.
  - It must report 0 problems.
  - It finds edited, missing, unsigned or forged files and manifests, and a chain cut short.
- **Tamper drill:** quarterly, on a copy of the archive:
  1. Edit one batch, remove one, and rewrite one manifest.
  2. Confirm verify reports all three.
  3. Record the result. The automated version runs in CI (`test_audit_export.py`).
- **Retention:** seven years, matching `audit.*` in the lifecycle matrix. Nobody can delete the objects before then,
  including the platform's administrators.
- **Online window (1052):** the database keeps the last `audit.online_months` months (13) of the audit logs.
  - **After each sync**, record how far the archive reaches: `python -m app.tools.audit_export record <dir>
    --public-key audit.pub`. It verifies the chain first, then writes `audit.archive_checkpoint`.
  - **The daily upkeep** drops an audit month older than the window only when every row of it is at or below the
    recorded checkpoint, and no legal hold applies. An unrecorded archive keeps everything online.

## 8. Alerts the database raises

| Event | Meaning | Action |
|---|---|---|
| `security.ddl_change` | A grant, policy, function, trigger or row-level security change made outside a migration | Confirm who made it (`audit.ddl_event`); revert unless it was an approved emergency change, then open an incident |
| `integrity.orphans_found` | References to missing rows (`sys.orphan_check.findings`) | Find the writer (the owner column of `sys.polymorphic_reference`), repair the rows, and add a test |
| Wallet mismatches in `sys.run_maintenance()` | Ledger and balances disagree | Severity 1: freeze payouts, reconcile (`fin.wallet_reconciliation`) |
| `security.break_glass_opened` | Someone holds break-glass access now | The security officer confirms the incident and the approver (section 11) |
| `security.break_glass_expired` | A break-glass access reached its expiry | Revoke any credential issued for it (Vault token, database role); the review is due |
| `security.break_glass_unreviewed` | A break-glass access ended more than 24 hours ago without a review | The security officer and the data owner review it now |
| `integrity.payments_mismatch` | Payments, refunds, provider notices and the ledger disagree | Severity 1: freeze payouts; reconcile (section 16) |
| `security.file_rejected` | An uploaded file failed the scan | Check the uploader's account and other recent uploads; the file stays in quarantine (section 12) |
| `compliance.requirement_proposed`, `compliance.requirement_changed` | A regulatory requirement change is waiting, or was applied | A second administrator decides it; notify the carriers affected (section 13) |

## 9. Data lifecycle (R-11)

- **Matrix:** `gov.v_lifecycle_matrix` lists, for every dataset:
  - its data class and legal basis;
  - its retention and erasure method;
  - where its copies go (replicas, backups, object storage, outbox, webhooks, archives);
  - its backup expiry.
- **Purge:** the daily upkeep purges delivered outbox events, finished webhook deliveries and old notifications when
  their retention ends (`sys.purge_expired`). It drops expired position partitions too.
- **Legal holds:** a legal hold on a dataset (`gov.legal_hold` with scope `DATASET`) stops its purge.
- **Erasure:** an erasure request pseudonymises the person in the database. Copies in backups expire with the backup
  retention. Archives keep only masked contact fields, because the change log masks them.

## 10. Load and capacity (R-12)

- **Booking spine, at rising concurrency:**
  `python -m loadtest.run --base https://staging.masslak.com --levels 100,500,1000 --seconds 300 --json run.json`
- **The one-seat race:** `python -m loadtest.run --base ... --same-seat 100`. Exactly one hold must be granted.
- **Cost of row-level security on the hot queries:** `python -m loadtest.rls_benchmark --runs 100`.
- **Cost of triggers:** with `track_functions = pl` (the staging overlay sets it), the load test reports milliseconds
  per call for the ten costliest triggers (`trigger_ms_per_call` in its JSON). Prometheus raises
  `TriggerCostOverBudget` above 1 ms per row (budget in `docs/database/STANDARDS.md`).
- **Growth:**
  - **Which tables:** `masslak_table_rows_estimate` and `masslak_table_bytes` cover the tables that grow with
    traffic.
  - **The outbox:** past `capacity.outbox_partition_rows`, partition it by day in the next release (alert
    `OutboxPartitioningDue`, `docs/integration/EVENTS.md`).
- **Connections (code review of October 2026):** a request waits at most `MASSLAK_DB_ACQUIRE_TIMEOUT` (5 s) for a
  connection of its process and is then answered 503 with `Retry-After`; each one counts in
  `masslak_db_pool_timeouts_total` (alert `PoolTimeouts`). PgBouncer's own pools come from the staging exporter:
  `PgBouncerClientsWaiting` (clients wait for a server connection for 2 minutes) and `PgBouncerSlowWait` (a wait over
  1 s) mean `DEFAULT_POOL_SIZE` is too small for the load or transactions are too slow; `PgBouncerDown` means the API
  cannot reach the database at all. Read `SHOW POOLS` on PgBouncer's console before raising the pool size, and check
  that the database still has CPU and connections to spare (`DatabaseConnectionsHigh`).
- **Several processes per instance:** the API runs `WEB_CONCURRENCY` processes (2 in the image). Each leaves its request
  counters in a file every 5 seconds and a scrape sums them, so `masslak_http_requests_total` never goes back when a
  scrape reaches the other process; `masslak_api_processes` shows how many are alive.
- **Targets:** run against staging with production-size data and hardware, at 1x, 2x and 5x the expected peak. The p95
  and p99 targets per step are set by the owner (performance gate). See `PERFORMANCE_BASELINE.md` for the first
  measurements and what they do not prove.

## 11. Break-glass access (T3-03)

- **When:** only during a declared incident, when the normal roles cannot fix it.
- **Open:** insert into `sec.break_glass_log` with:
  - the incident reference, the reason and the scope (`DB`, `PAYMENTS`, `ALL`);
  - an approver other than yourself;
  - an expiry at most `security.break_glass_max_minutes` (240) away.

  When nobody can approve in time, set `emergency = true`; the review afterwards is then mandatory.
- **Grant:** issue the elevated credential (Vault token, temporary database role) with the same expiry as the record.
  Tools that need elevation check `sec.break_glass_active(<user>, <scope>)`; it turns false when the time is up, with no
  job needed.
- **Close:** set `ended_at` and `closed_reason = 'ENDED'` when done. The upkeep closes expired records as `EXPIRED`.
- **Review:** within 24 hours of the end, someone other than the user records what was accessed and why. The record cannot
  be widened, rewritten or deleted.
- **Never:** application roles and workers hold no SUPERUSER or BYPASSRLS. The tests and `audit_pack.sh` check it.

## 12. File scanning (T3-15)

- **Production:** run ClamAV (`clamd`) next to the API. Set `MASSLAK_CLAMD=host:3310` (or the socket path), and keep the
  signatures updated (`freshclam`).
- **Without ClamAV:** files stay `PENDING` and nobody can download or approve them (fail closed). The sandbox may run
  on the built-in checks alone.
- **Retries:** the worker retries pending files every minute. A ClamAV outage uses up no attempt, so files uploaded
  during an outage are scanned as soon as clamd is back, however long it was down; only a file that makes the scan
  itself fail uses one, and stops being retried after five (fixed after the launch gate 7 rehearsal).
- **A file stuck in PENDING:** check clamd, then let the worker retry. Never mark a file CLEAN by hand: only the
  platform's scanner sets a scan result, and a REJECTED or QUARANTINED verdict is final.
- **Drill:** upload the EICAR test file in staging after each ClamAV upgrade. It must be rejected.

## 13. Changing a regulatory requirement (T3-14)

1. A platform administrator proposes the change, with the reason and the date from which it applies:
   `POST /api/admin/compliance/requirements/{code}/changes`.
   - The proposal records its impact: how many vehicles, drivers or companies would fall short on that date.
   - Prefer a future date, so carriers have time to comply.
2. A second administrator reads the impact and decides: `POST /api/admin/compliance/changes/{uid}/decision`.
   - Approval applies the change; rejection keeps the requirement as it was.
   - Nobody can approve their own proposal, and the database refuses a direct change.
3. Notify the carriers affected before the date. Where possible, try the change first in staging, or in one city.

## 14. Egress proxy (T3-02)

- **Design:** the API and the worker have no route to the internet. Every outbound connection goes through the `egress`
  container (Squid), which:
  - tunnels only HTTPS and mail submission (ports 443, 465, 587);
  - refuses private, loopback, link-local, metadata and reserved addresses after its own DNS lookup;
  - allows only allowlisted names.

  The application checks the URL and the resolved address first (two layers).
- **A new payment provider, SMS gateway or SMTP relay:**
  1. Add its domain to `deploy/egress/allowlist.txt`.
  2. Run `docker compose exec egress squid -k reconfigure`.
  3. Run the self-test.
- **Partner webhooks:** the worker writes the domains of active endpoints into the shared list every minute, and Squid
  rereads it every minute. A newly registered endpoint may miss its first attempt and receive it on the retry.
- **Self-test** (after every change and in CI):
  `docker compose exec worker bash /app/deploy/egress/selftest.sh egress:3128 <an allowlisted domain>`.
  Metadata, private, loopback, a name resolving to loopback, IPv6 loopback, IPv4-mapped IPv6, an unlisted name and plain
  HTTP must all answer 403.
- **A delivery fails with `EGRESS_REFUSED`:** read the proxy log (`docker compose exec egress tail /var/log/squid/access.log`).
  A partner endpoint that resolves to a private address stays refused: this is the intended protection.

## 15. Position evidence and violation review (T3-11)

- **Trust grade:** every position gets a grade when it is stored (`ops.tg_geo_event_trust`). The thresholds are settings
  the platform can tune:

| Flag | Rule (setting) | Grade |
|---|---|---|
| `MOCK_LOCATION` | the phone reports a mock location provider | REJECTED |
| `FUTURE_TIME` | device time more than 2 minutes ahead of the server | REJECTED |
| `NO_FIX` | accuracy worse than `tracking.reject_accuracy_m` (500 m) | REJECTED |
| `DEVICE_REVOKED`, `DEVICE_FAILED` | the session's device was revoked, or failed attestation | REJECTED |
| `INACCURATE` | accuracy worse than `tracking.max_accuracy_m` (50 m), or unknown | LOW |
| `LATE` | received more than `tracking.late_minutes` (10) after the device took it | LOW |
| `OUT_OF_ORDER` | sequence not above the previous position's | LOW |
| `IMPOSSIBLE_SPEED` | a jump faster than `tracking.max_speed_kmh` (200 km/h) | LOW |
| `NETWORK_ONLY` | position from cell or Wi-Fi only | LOW |
| `NO_DEVICE`, `NOT_ATTESTED` | only when `tracking.device_attestation` is REQUIRED | LOW |

- **Duplicates:** a position whose device event id was already stored is dropped (replay).
- **Devices:** mobile sessions are bound to a registered device, and each position records it. The driver app sends
  an attestation (Play Integrity or App Attest) to `POST /api/driver/device/attestation`. The verifier service is
  configured by `MASSLAK_ATTESTATION_URL`; until then attestation is refused, never assumed.
- **Review:** a violation built on LOW positions counts only after review. A person with `violation.review` (platform
  administrator or regulator) opens `GET /api/admin/violations/review` and reads the evidence. They then confirm or
  dismiss with a note: `POST /api/admin/violations/{uid}/review`.

  The metric `masslak_violations_awaiting_review` shows the queue. Review within 2 working days.

## 16. Resending money and authority events (T3-12)

- **A provider confirmed after we stopped waiting (alert `PaymentCapturedLate`):** the payment had expired, its
  reservation had expired, or the payer cancelled it, and the provider then reported that it took the money (1071).
  The money is in the payer's wallet (`fin.payment.captured_late`, event `payment.captured_late`); the booking was
  confirmed only if it still held its seats. Contact the payer: the money stays usable in the wallet, or finance
  refunds it to its source (`POST /api/admin/payments/{uid}/refund`).
- **Events the worker gave up on (alert `OutboxEventsFailed`):** after eight attempts an outbox event is `FAILED` and
  its notifications and partner deliveries wait. Read the cause in `sys.outbox_event.last_error`, fix it (provider
  down, wrong credentials, a template error), then queue the events again as the database owner:
  `UPDATE sys.outbox_event SET status = 'PENDING', attempts = 0, next_attempt_at = now() WHERE status = 'FAILED' AND id = ANY(...)`.
  A notification already recorded for the event, user and channel is not sent again (`crm.notification`, unique per event).
- **Request:** a partner's retry of a FAILED or DEAD delivery is applied at once for ordinary events. For a payment,
  refund, wallet, withdrawal, payout, settlement, manifest, authority or cancellation event, it becomes a request instead.
- **Approval:** a person with `events.replay_approve` (platform administrator or finance), other than the requester,
  approves or rejects it: `GET /api/admin/delivery-retries`, `POST /api/admin/delivery-retries/{uid}/decision`.
- **Before approving:** confirm with the partner that they did not apply the event already. Their inbox should make a
  repeat harmless (`docs/integration/EVENTS.md`), but money is checked twice.
- **Daily reconciliation:** the daily upkeep runs `fin.reconcile_payments()`, which checks:
  - refunds against refunded amounts;
  - refunds and payments without a ledger transaction;
  - currency mismatches;
  - provider notices not applied after an hour.

  Any mismatch raises `integrity.payments_mismatch` and the `masslak_payment_mismatches` metric. **Severity 1:** freeze
  payouts, then reconcile the named payments one by one.

## 17. Ten million operations a day

The capacity model and its stages are in `CAPACITY_MODEL.md`.

- **Shared wallets (DEFERRED):**
  - **The balance that counts:** carrier, agency and platform wallets take credits without a row lock. The balance
    that counts is `fin.wallet_balance(id)`, never the stored `balance` column.
  - **The roll-up:** the worker runs `SELECT fin.roll_up_balances()` every 5 s.
  - **If `WalletRollupLagging` fires:** check that the worker runs, and look for long transactions
    (`pg_stat_activity`). Balances stay correct meanwhile, but closing days waits.
  - **A wallet that must change mode:** `UPDATE fin.wallet SET balance_mode = ...`. Leaving DEFERRED is refused
    until its entries are rolled up.
- **Closed ledger days:**
  - **What the daily upkeep does:** it runs `fin.close_ledger_days()`. It closes finished UTC days once no older
    transaction is running and every entry of a shared wallet in them is rolled up. It also re-verifies the day closed
    seven days earlier (`fin.verify_ledger_day`).
  - **`LEDGER_DAY_CLOSED`:** a correction never goes into a closed day. Post a correcting transaction today, with its
    reason.
  - **If `LedgerDaysNotClosing` fires:** look for a transaction left open (`idle in transaction`), then for the
    roll-up.
  - **Balances at a moment:** `fin.wallet_balance_at(wallet, moment)`. It is what statements use.
- **Outbox days (1053):**
  - **Dropping a day:** a finished day of events is dropped whole after its retention
    (`sys.drop_outbox_days()`, called by the purge), unless an event of it still waits or a delivery of it is still
    kept.
  - **The worker:** it claims `MASSLAK_OUTBOX_BATCH` events per transaction (50), each in its own savepoint. Add
    worker replicas when `OutboxBacklog` fires at the peak.
- **Positions:**
  - **Batches:** apps send buffered positions to `POST /api/driver/locations` (up to 120 at once).
  - **Live maps** read `ops.vehicle_position`.
  - **Telemetry cluster:** when positions stay above 500 a second, or above 30 % of the primary's WAL, move them to
    the telemetry cluster (stage 2).
- **PgBouncer:**
  - **The setup:** the API and the worker connect through `pgbouncer:6432` in transaction mode. The audit and report
    connections stay direct.
  - **Pools:** inspect them with `SHOW POOLS;` on the `pgbouncer` admin database.
  - **When clients wait:** raise `DEFAULT_POOL_SIZE` if clients wait (`cl_waiting`) while the database still has CPU
    to spare.

## 18. Counter cash and report freshness (review stage B)

- **Cash ageing:** what each carrier owes from counter sales, split by age (0-7, 8-30, 31-60, 61-90, over 90 days),
  is in **Payments > Counter cash** and the report **Counter cash ageing** (`fin.cash_aging`). Set-offs, remittances
  and cash refunds pay the oldest sales first, so what is owed is always the newest sales.
- **If `CashOverdue` fires** (cash sold more than 30 days ago is still owed):
  1. Open **Counter cash** and sort by "Owed over 30 days".
  2. Ask the carrier for the remittance. Record it, and have a second officer confirm it.
  3. If the carrier does not pay, lower its cash limit (**Set limit**, with a reason). Its counter sales stop once
     the debt reaches the limit.
- **If `CashNearLimit` fires:** the carrier will soon be unable to sell for cash. Tell the carrier before its
  counter staff are refused.
- **Report freshness:**
  - Reports read the replica.
  - A financial report is refused with `REPORT_DATA_STALE` while the replica is more than 60 s behind. A scheduled
    one is retried five minutes later.
  - Other reports are served with a warning past 5 minutes (lists) or 1 hour (totals).
  - The limits are in `sys.setting` `reports.replica_lag`.
  - If staff report `REPORT_DATA_STALE`, follow `ReplicaLagging`: check `pg_stat_replication` on the primary, then
    the replica's disk and replay.

## 19. Release, supply chain and finer monitoring (review stage C)

- **Which release a database is at:** `SELECT * FROM sys.current_release()` gives the version, the commit, the number of
  applied files, their hash and whether the record still matches. Reports carry the same version as their
  `source_version`, and the scrape exposes `masslak_release_info` and `masslak_release_hash_matches`.
- **Installing from a release archive:** a tag `v*` publishes the archive, its bill of materials (SPDX), `SHA256SUMS`
  and keyless Sigstore signatures (`.github/workflows/release.yml`). Download all of them into one directory and run
  `deploy/verify-release.sh masslak-vX.Y.Z.tar.gz` (it needs `cosign`) before extracting. It refuses an archive not
  signed by this repository's release workflow for a `v*` tag, or one that does not match the checksums, and prints the
  commit recorded in `RELEASE`. `deploy/update.sh --sha <commit>` then checks that commit, and the release manifest
  records it.
- **Publishing a release:** push the tag with git (`git tag -a vX.Y.Z <commit> -m "Masslak vX.Y.Z"`, then
  `git push origin vX.Y.Z`), or publish a release from the repository's Releases page with a new tag `vX.Y.Z` on the
  branch or commit to release. Either way the workflow runs CI on the tagged commit, then creates the release or adds
  the signed files to the one published from the page, naming it `Masslak vX.Y.Z` if its title was left empty. If no
  run starts, open Actions → Release → Run workflow and choose the tag as the ref. GitHub runs the workflow file of the
  tagged commit, so tag a commit that has the current `release.yml`. With immutable releases switched on in the
  repository settings a published release takes no more files: push the tag with git instead.
- **Base images and CI actions are pinned:** every image is `name:tag@sha256:<digest>` and every action
  `owner/repo@<commit> # vX.Y.Z`, checked on every push by `scripts/pin_images.py`. Move the pins once a month and
  after a security advisory: `python3 scripts/pin_images.py --update`, review the diff (the tag each pin follows stays
  in the line), let CI build and test it, then merge. Never take a pin from an unreviewed source.
- **Lock waits on one table (`LockWaitsOnTable`):** `masslak_lock_waiting{table}` and `masslak_lock_wait_seconds_max{table}`
  name the table. The API gives up a lock after 5 s (`LOCK_TIMEOUT`), so waits near 3 s mean contention, not a stuck
  session.
  - Find the holders: `SELECT pid, now() - xact_start, state, query FROM pg_stat_activity WHERE pid IN (SELECT unnest(pg_blocking_pids(pid)) FROM pg_stat_activity WHERE wait_event_type = 'Lock')`.
  - A migration or a console session holding the lock: stop it (section 4).
  - The escrow or a company wallet under a burst: see section 17 and stage B (refunds posted last).
  - A seat map under a sale rush: expected for seconds; if it lasts, check the hold expiry job.
- **Partitions running out (`PartitionsRunningOut`) or rows in a default partition (`RowsInDefaultPartition`):** the
  daily upkeep (`sys.run_maintenance()`) creates daily partitions 7 days ahead and monthly ones 3 months ahead.
  - Running out: check `masslak_job_last_success_age_seconds{task="maintenance"}` and run `SELECT sys.run_maintenance()`.
  - Rows in a default partition block creating the partition for their range. Move them with one reviewed migration
    file, rehearsed on staging first: detach the default partition, create the missing partition and a new empty
    default, copy the rows of the detached table into the parent table (they land in the new partition), then drop
    the detached table. The rows are copied, never edited, so append-only tables such as `fin.ledger_entry` keep their
    guards.
- **Waiting for a connection (`PoolWaits`):** `masslak_db_pool_acquire_seconds` is the time a request waited for a
  connection of its API process. Before raising the pool or PgBouncer sizes, look for slow transactions
  (`LongTransaction`) and lock waits, which hold connections longer (section 10).

## 20. Opening a market (review stage D)

- **What a market is:** a country with its time zone, currency and language (`ref.market`). Companies and people
  belong to the market of their country (`iam.party.country_code`); stations take the time zone of their city.
  Syria is the default market; days, cash limits and reports read the market of the data, never a fixed zone.
- **Opening one:** a reviewed migration (`UPDATE ref.market SET status = 'ACTIVE' WHERE country_code = '<XX>'`); the
  owner approves it like any schema change. Opening creates the platform's wallets in the market's currency, and from
  then on companies may be onboarded into it (`market` in the onboarding form). Then set the carriers' cash limit for
  that currency (the default limit is in the default market's currency, so a new market's carriers sell for cash
  only once given their own).
- **Checks after opening:** `GET /api/markets` lists it; `SELECT * FROM sys.finance_metrics()` reports its cash apart
  (`currency` label); a test carrier's dashboard shows its days in the market's time.
- **Not yet:** prices in one currency bought from a wallet in another (no exchange); a market's own payment providers
  are configured like any provider.

## 21. Data warehouse (review stage D)

Design: [WAREHOUSE.md](../database/WAREHOUSE.md). The warehouse subscribes to publication `masslak_dw` on the primary
and holds no personal data.

- **Setting it up:** set `MASSLAK_CDC_PASSWORD`, `MASSLAK_DW_PASSWORD` and `MASSLAK_DW_ANALYST_PASSWORD` in
  `deploy/.env`, run the migration (it gives `masslak_cdc` its login), then
  `docker compose -f docker-compose.yml -f deploy/warehouse/docker-compose.warehouse.yml --env-file deploy/.env up -d`.
  `warehouse-setup` creates the tables, subscribes and waits for the first copy.
- **Is it current?** `SELECT * FROM dw.freshness` on the warehouse; `python3 db/warehouse/build.py --check` compares
  every table's rows with the primary (run it while writes are quiet) and fails on any column the primary does not
  publish.
- **A slot holding WAL (`ReplicationSlotRetainingWal`, `ReplicationSlotInactive`):** the warehouse is stopped or behind.
  Start it (`docker compose ... up -d warehouse`) and watch `masslak_replication_slot_retained_bytes` fall. If it cannot
  be started within hours, drop the slot on the primary (`SELECT pg_drop_replication_slot('masslak_dw')`) before the
  disk fills, and copy again later. The primary drops it by itself at 20 GB (`max_slot_wal_keep_size`).
- **Copying everything again** (after the primary dropped the slot, or after columns were added to the publication):
  `docker compose ... run --rm warehouse-setup python /app/db/warehouse/build.py --resync --wait`.
- **A slot with a foreign plugin (`ReplicationSlotForeignPlugin`, page):** a logical slot decoding with anything but
  `pgoutput` can read every table, personal data included. Treat it as a security incident (section 1): note the slot
  (`SELECT * FROM pg_replication_slots`), find who created it in the server log (`log_replication_commands`), drop it,
  and rotate `MASSLAK_CDC_PASSWORD` and `MASSLAK_REPLICATION_PASSWORD`.
- **Publishing a new column:** a new schema file changes `sys.dw_columns()` and calls `sys.dw_publish()`; the database
  checks refuse anything personal. Then run `build.py` on the warehouse.

## 22. Telemetry database (review stage D)

The history of vehicle positions can live in a PostgreSQL of its own (`db/telemetry/schema.sql`); the primary keeps
the grades, the latest position of each vehicle and the tracking alerts (schema file 1063).

- **Turning it on:** set `MASSLAK_TELEMETRY_OWNER_PASSWORD`, `MASSLAK_TELEMETRY_PASSWORD` and
  `MASSLAK_TELEMETRY_UPKEEP_PASSWORD` in `deploy/.env`, then
  `docker compose -f docker-compose.yml -f deploy/telemetry/docker-compose.telemetry.yml --env-file deploy/.env up -d`.
  The migration creates the telemetry schema; the API and the worker get `MASSLAK_TELEMETRY_DATABASE_URL`. Positions
  already on the primary stay there until their retention drops them.
- **Telemetry down (`TelemetryDown`, page):** the API refuses positions with 503 and the driver apps keep them and send
  them again; the live map still moves (the latest position is written on the primary first). Restore the service;
  nothing needs replaying. If it cannot come back within the apps' buffer (about a day), turn the telemetry database
  off (remove `MASSLAK_TELEMETRY_DATABASE_URL`) so positions go to the primary again.
- **Partitions (`TelemetryPartitionMissing`):** the worker's daily upkeep creates them 7 days ahead and drops days past
  the retention the primary sets (`gov.data_inventory`, `ops.geo_event`). Two logins (reviews of October 2026, C-02):
  the API's (`masslak_tel`) only appends positions and creates days ahead; the worker's (`masslak_tel_upkeep`,
  `MASSLAK_TELEMETRY_UPKEEP_URL`) drops. A legal hold the primary reports is recorded in `tel.policy` and stops every
  drop until released, and nothing younger than `tel.policy.min_keep_days` (7 by default; `-v min_keep_days=` when
  the schema is applied) is ever dropped. Without the upkeep login the worker logs that the retention is not applied.
  Run it by hand: `python -m app.modules.notify.worker --maintenance`.
- **Evidence:** positions are graded by the same rules in both stores (`ops.position_flags`). Violation reviews read
  their evidence from the violation itself; exporting raw positions for an authority reads `tel.position` by trip.

## 23. Automatic failover and the second site (review stage D)

Design and measured times: [HIGH_AVAILABILITY.md](HIGH_AVAILABILITY.md). Configuration: `deploy/ha/`.

- **A failover happened (Patroni promoted a standby):** nothing to do to keep bookings running. Then:
  - `patronictl -c /etc/patroni/patroni.yml list`: one leader, the old primary rejoining as a replica (pg_rewind);
  - `NoFailoverCandidate` or `NoSynchronousStandby` clear once it streams again; if the old server cannot rejoin,
    build a new standby from the backup repository (`create_replica_methods: pgbackrest`);
  - the checks of section 3 (lag, outbox, reconciliation), and the warehouse slot moved with the primary
    (`SELECT * FROM pg_replication_slots` on the new primary).
- **No standby (`NoFailoverCandidate`, page):** a failure now stops bookings until a restore. Bring the standby back or
  build a new one the same day.
- **Losing the main site (declared by the on-call lead):** a cut link and a lost site look alike from the second site,
  so it never promotes itself.
  1. Confirm the main site is down and will not come back within the RTO; tell the owner.
  2. Fence it: stop the main site's applications and databases if they can be reached, or block them at the network.
  3. Promote the second site: `patronictl -c /etc/patroni/patroni.yml edit-config --force --set standby_cluster=null`
     on `db-b1`; check `SELECT pg_is_in_recovery()` is false.
  4. Start the API, the worker and Caddy at the second site; move the DNS name to it.
  5. Note the last WAL the second site replayed (`pg_last_wal_replay_lsn()` before promotion) and compare with
     repo1 when the main site returns: transactions after it are the loss, reconciled by hand with the ledger tools.
- **Drills:** `python3 db/tools/failover_drill.py --dsn "<every server, target_session_attrs=read-write>" --kill "<stop
  the primary>" [--promote ...] --api https://<site>/api/ready --json evidence.json` on staging; it fails when writing
  is not back within 60 s or an acknowledged write is lost with a synchronous standby.

## 24. Files in an S3-compatible object store (code review of October 2026, 3.2)

Documents and generated reports are encrypted by the platform (AES-256-GCM, the storage key as associated data) and
written either to the `files` volume (`MASSLAK_FILES_BACKEND=local`) or to an S3-compatible object store
(`MASSLAK_FILES_BACKEND=s3`). A volume belongs to one server: as soon as the API runs on two servers, files go to the
object store. Every write asks the store for server-side encryption (`MASSLAK_FILES_S3_SSE`, `AES256` or `aws:kms`)
and is removed and refused unless the store confirms it, so a bucket without encryption shows at the first upload.

**The bucket.** A dedicated bucket created with Object Lock (which turns versioning on, and cannot be added later),
a default retention of at least `MASSLAK_BACKUP_KEEP_DAYS` days in GOVERNANCE or COMPLIANCE mode, replication to a
second site, no public access, and server-side encryption enabled. On a production server the migration's preflight
refuses a bucket without versioning, without Object Lock or with a shorter retention (H-04). The credentials in
`deploy/.env` belong to a user that may only read and write objects of that bucket. A store outside the private network
is reached through the egress proxy (`MASSLAK_FILES_S3_VIA_PROXY=true`): the worker adds its domain to the proxy's
allowlist. The nightly backup does not copy the files once they are in the store. It records the version each file
has (`files_versions.jsonl`, encrypted like the rest of the backup), so a restore brings every file back to that
moment:

```
docker compose --env-file deploy/.env run --rm --no-deps app python -m app.tools.files_versions check
aws s3api create-bucket --bucket masslak-files --object-lock-enabled-for-bucket
aws s3api put-object-lock-configuration --bucket masslak-files \
  --object-lock-configuration '{"ObjectLockEnabled":"Enabled","Rule":{"DefaultRetention":{"Mode":"GOVERNANCE","Days":30}}}'
```

Deleting a file (the daily sweep of unreferenced files, M-04) only adds a delete marker: the locked versions stay until
their retention ends, and a lifecycle rule removes noncurrent versions after that.

**Moving an installation from the volume to the store**, without stopping it:

1. Fill in the `MASSLAK_FILES_S3_*` settings in `deploy/.env`, leaving `MASSLAK_FILES_BACKEND=local`.
2. `docker compose run --rm --no-deps app python -m app.tools.files_move copy`: copies every file of the volume that
   the store does not have yet (they stay encrypted as they are; the store encrypts them again on arrival).
3. Set `MASSLAK_FILES_BACKEND=s3` and run `deploy/update.sh` (the API and the worker restart on the store).
4. Run `copy` again: it copies only the files uploaded between steps 2 and 3.
5. `docker compose run --rm --no-deps app python -m app.tools.files_move verify`: every file the database refers to
   is in the store and, byte for byte, the one on the volume. Keep the volume until it reports nothing missing and
   nothing different (exit code 0), then for one more backup cycle.

**When the store is down**, uploads and downloads are answered 503 with `Retry-After` ("the file store did not answer
in time") and the security scanner leaves files waiting without using up their attempts (alert FilesWaitingForScan);
bookings, payments and boarding do not depend on it. **When verify reports a file missing**, look for it on the
volume and in the bucket's earlier versions before anything else; a file that is in neither cannot be recovered, and
its document is asked for again from the company.

## 25. Money boundaries, fees and approvals (1.48)

**Provider calls.** A card, e-wallet, instalment or financing payment is written and committed before its provider is
called; the call runs outside any transaction, in a thread, under a merchant reference fixed by the payment
(`CRD…`, `EWL…`, `INS…`, `FIN…` followed by the payment's id). A provider that does not answer leaves the payment
`PENDING` at stage `PROVIDER_UNKNOWN`: the payer sees "the provider did not answer" and repeating the same request asks
again with the same reference; the provider's signed notice or the expiry settles it otherwise (a late notice is
credited, alert PaymentCapturedLate). Five unanswered calls in a row to one provider open its circuit for 30 seconds
(`MASSLAK_PSP_BREAKER_FAILURES`, `MASSLAK_PSP_BREAKER_OPEN_SECONDS`): calls are refused at once with 503 and
`Retry-After`, then one call is tried. **PaymentProviderCircuitOpen** (page) means a provider has not answered for five
minutes: check the provider's status page and the egress proxy's log (`docker compose logs egress`) before anything else.

**Refunds.** A refund holds its amount in the payer's wallet when it is asked for and is posted only once the provider
accepted it, under the reference `RFD…` fixed by the refund. When the provider's answer is lost the refund waits at
stage `UNKNOWN` and the worker sends it again, same reference, after 1, 5, 15, 60 and then every 240 minutes; finance
can send it at once (Payments and refunds, or `POST /api/admin/payments/refunds/{uid}/resend`). **RefundOutcomeUnknown**
means a refund has waited an hour: ask the provider whether the reference was paid. Never refund the same payment
by hand while a refund of it is `UNKNOWN`: if the provider did pay it, the next send records it.

**Payment fees** (decision 4) are rules on the Payment fees tab: per way of paying, currency and, if wanted, one
customer; a percentage, a fixed amount, both, or none (offers); with a period, a floor and a cap, and rounding to a
step (in the currency's minor units) up, down or to the nearest. The most specific rule in force applies. By default
the customer pays it, sees it before paying and the provider is asked for the amount plus the fee; the fee is posted
to platform revenue (`PLATFORM` wallet). A rule paid by Masslak shows no fee to the customer and records the
amount absorbed on the payment. The percentage and payer on a provider's screen are that provider's default rule.

**The approval matrix** (decision 5) is on the Approvals tab. For a credit from a bank statement line and for a refund
to the source: the number of levels (0 to 5), and for each level who decides (the holders of a permission, or only
the people named) and from which amount it applies. The defaults: one finance review for statement credits, none
for refunds. A request freezes the levels its amount needs when it is made; levels are decided in order; nobody
decides their own request or two levels of one (the database refuses it). A rejection puts a statement line back
among the lines to review and releases a held refund. Changing the matrix raises a security event
(`approval.policy_changed`). A request whose level was removed by a later change cannot be decided: an administrator
cancels it (Approvals, or `POST /api/admin/approvals/{uid}/cancel`) and finance proposes it again. **ApprovalsWaiting**
means a decision has waited a day.

**Unsigned notices.** Every notice a provider endpoint receives is kept; only a signed one counts and takes its event
id (1073). **UnsignedNoticesBurst** (more than 20 in an hour for one provider) means someone is probing the endpoint
or the provider's signing secret changed: compare `MASSLAK_PSP_<CODE>_SECRET` with the provider's console first.

## 26. Sign-in, boarding and positions (1.48)

**Two-factor sign-in policy** (owner's decision 2) is on Security, Two-step sign-in (`security.console`). It sets which
methods are open (an authenticator app such as Google Authenticator, a code by text message, a code by WhatsApp; one
or more), which portals must use one (platform staff, inspectors, carrier staff, drivers, agency staff, passengers),
how long a message code lives (2 to 10 minutes), the wait before another can be sent and the codes per person per
hour. Platform staff always use one outside the sandbox, whatever is chosen. A change reaches every API process
within half a minute and raises a security event (`security.mfa_policy_changed`). A portal added to the list asks its
people for a second factor at their next sign-in: those without one enrol first, on the website or in the app.

**Message codes** leave only when the server has delivery for the channel: `MASSLAK_NOTIFY_SMS=http` with its gateway,
`MASSLAK_NOTIFY_WHATSAPP=cloud` with the WhatsApp Business Cloud API endpoint, token and an approved authentication
template (`MASSLAK_WHATSAPP_TEMPLATE`). A method open in the policy but not configured on the server is not offered
(the policy page says so). Codes are kept only as keyed hashes, five wrong entries close a code, a code works once.
**MfaCodesFailing** means codes are not leaving: check the gateway or WhatsApp account first; people can still use the
authenticator app or a recovery code. When the platform closes a method, the people who had only that one enrol
another at their next sign-in.

**A person who lost every factor** (phone lost, no recovery code): security staff confirm the person's identity outside
the platform, then disable the person's factors (`UPDATE iam.mfa_factor SET disabled_at = now() WHERE user_id = ...`
by the owner role, recorded in the change log); the next sign-in enrols again. Never do it on a request received only
by e-mail or message.

**Boarding stops.** A scan names the stop where the passenger boards, by default the first stop of their ticket. A
stop the trip does not have answers UNKNOWN_STOP and is not recorded; a stop the ticket does not cover answers
WRONG_STOP and is recorded as a refusal. The database refuses both from any writer.

**Offline scans** are dated at the scan, unless the time is more than a day before departure or earlier than the
driver's first download of the trip's pack: then at the upload, and judged then (an expired credential is refused).

**Late partitions.** The daily upkeep now creates every past day (month) that has rows waiting in a default partition,
not only yesterday, so a long stop of the worker leaves nothing outside the retention. The metric of rows in default
partitions (`masslak_partition_default_rows`) returns to zero after the next upkeep.

**Positions waiting for the telemetry database.** When the telemetry database does not answer, positions are graded
on the primary as usual and kept there (`ops.position_backlog`); the driver's app gets its answer and does not have
to send them again. The worker delivers the backlog in order once a minute (duplicates are skipped there).
**PositionBacklogGrowing** means positions have waited 15 minutes: see section 22 for the telemetry database. Delivered
batches are purged after 7 days.

## 27. Durability and backups off the server (1.48)

**Zero data loss** (owner's decision 1) is the setting `MASSLAK_ZERO_DATA_LOSS` in `deploy/.env`: `on` (the production
default) makes the standby confirm every commit before the client is told, so nothing the platform confirmed is lost
with the primary; `off` lets the primary confirm alone, and a lost primary may take the last seconds with it.
`deploy/durability.sh` applies it (install and every update run it; run it by hand after changing the setting). In the
standard stack the standby is the read replica, `replica1`; with Patroni, `deploy/ha/durability.sh` sets
`synchronous_mode_strict` from the same setting. The choice has a cost the owner accepted: with `on`, when no standby
can confirm, commits wait and bookings pause rather than be confirmed without a copy.

- **CommitsWaitingForStandby** (page): commits wait and no standby confirms. Bring the standby back
  (`docker compose restart db-replica`, or the Patroni replica). Only if it cannot come back soon and the owner's
  representative agrees, switch the setting to `off` and run `./deploy/durability.sh`; record the decision, and switch
  it back once a standby streams again.
- **ZeroDataLossNotEnforced** (page): the setting is `on` but commits do not wait (a restore, a configuration reset, a
  new primary after a failover). Run `./deploy/durability.sh` (Patroni: `./deploy/ha/durability.sh`).

**Backups off the server** (R-41): every nightly backup is copied to `MASSLAK_BACKUP_OFFSITE` with rclone, checked
against its checksums, and both copies are recorded (`sys.backup_run`). **BackupStale** and **BackupOffsiteStale**
fire when the last good copy is more than 26 hours old: read `/var/log/masslak-backup.log`, fix the cause, run
`./deploy/backup.sh` by hand and see the alert clear at the next scrape. pgBackRest's second repository (`repo2`, the
second site) is the off-site copy of the point-in-time backups in the high-availability layout.

**Connections** (R-46): the security console's and the reports' pools open connections only while used and close them
after a minute idle (`MASSLAK_DB_AUDIT_POOL_MAX`, `MASSLAK_DB_REPORTS_POOL_MAX`), and the database caps the security
console's role at 20 connections, so adding API servers adds no idle connections to the primary
(`CAPACITY_MODEL.md`, section 10).

## 28. Logs, traces and slow statements (1.48)

**Logs** (report 3, 7.2): outside the sandbox the API and the worker write one JSON object per line on standard output
(`MASSLAK_LOG_FORMAT=text` gives the classic lines back). Every line has `ts` (UTC), `severity`, `service`, `version`,
`environment`, `logger` and `message`; inside a request or an outbox event also `request_id` and `trace_id`. Each API
request writes one line from `masslak.access` with `method`, `route` (the route template, never the address with its
identifiers), `status`, `duration_ms`, `error_code` when refused, and where the time went: `pool_wait_ms` (waiting for a
database connection), `db_ms` with `db_transactions` (holding one) and `egress_ms` with `egress_calls` (calls to
providers). Personal data and secrets are removed before a line is written (`app/logredact.py`).

**Following one request**: the response header `traceparent` (W3C Trace Context) carries its trace; a client or a
proxy that sends one keeps it. The same trace is on the outbox events the request wrote
(`sys.outbox_event.correlation_id`), on the worker's lines for them and on every outbound call through the egress proxy.
To follow a booking: take the trace from the response or from the request line, then
`docker compose logs app worker | grep <trace>`, and `SELECT event_type, status, attempts FROM sys.outbox_event WHERE
correlation_id = '<trace as a UUID>'`.

**Slow statements** (report 3, 4.1): the database keeps statistics per statement (`pg_stat_statements`, preloaded by
`docker-compose.yml`, the replica, staging and Patroni). The security console's *Slowest statements* page
(`/security/statements`) and `SELECT * FROM sys.top_statements('MEAN', 20, 50)` (orders TOTAL, MEAN, CALLS, READS; at
least 50 calls) list them with placeholders instead of values. Before adding an index:

1. Pick the statement by total time (what the server spends most on) or by mean time among frequent ones.
2. Run `EXPLAIN (ANALYZE, BUFFERS, SETTINGS)` with representative values on the staging copy (never `ANALYZE` a
   statement that writes, on production), keep the plan in the change.
3. Add the index `CONCURRENTLY` in a migration, then *Start a new window* on the page (or
   `SELECT sys.reset_statement_stats()`) and compare the same statement after a day.

`masslak_db_statement_stats_enabled` reads 0 where the server does not preload the extension (a managed server:
add `pg_stat_statements` to its `shared_preload_libraries` and, if the owner role may not read other roles' statements,
`GRANT pg_read_all_stats TO <owner role>`). A rising `masslak_db_statement_evictions_total` means
`pg_stat_statements.max` (default 5000) is too small for the number of distinct statements. Statements slower than one
second also reach the database log, without their bind values (`log_parameter_max_length=0`).

**Watchdog** (R-45): this alert always fires. Alertmanager sends it every minute to the dead man's switch
(`deploy/staging/secrets/deadman_webhook_url`: a heartbeat service with its own paging), which pages the on-call engineer
when the heartbeats stop: Prometheus, Alertmanager or the network to the receivers is down. Never silence it; if the
switch pages, check those three before anything else.

**Reports built off the request loop** (R-46): an export is rendered in a worker thread, at most
`MASSLAK_EXPORT_RENDER_SLOTS` (default 2) at a time per process; a burst waits up to 15 s and is then answered 503
`EXPORT_BUSY` with `Retry-After`. Raise the slots only with CPU to spare: each slot can keep one core busy.

## 29. Archiving a closed financial year (R-05)

Bookings are partitioned by ranges of id (1064), not by year, and about 22 tables refer to `sales.booking`. A closed
year is therefore archived by **copying it out and keeping it readable**, never by detaching a partition the foreign
keys still point into. This is a planned task for the third phase of the capacity model (`CAPACITY_MODEL.md`), not a
launch requirement; rehearse it on a copy before the first real run.

1. **Scope.** The year must be closed in the ledger (`fin.ledger_close.closed_through` past its last day) and on no legal
   hold (`gov.v_table_lifecycle.on_legal_hold`). The ids to archive are the bookings created in that year:
   `SELECT min(id), max(id), count(*) FROM sales.booking WHERE created_at >= '<year>-01-01' AND created_at < '<year+1>-01-01'`.
2. **Dependency map.** List what refers to those bookings (tickets, payments, refunds, allocations, ledger references,
   manifests, notifications):
   `SELECT conrelid::regclass, conname FROM pg_constraint WHERE confrelid = 'sales.booking'::regclass AND contype = 'f'`.
   Each referring table is archived for the same ids, so the archive is complete on its own.
3. **Copy.** Into an archive database (same schema version), table by table in id batches of 10,000:
   `COPY (SELECT * FROM <table> WHERE booking_id BETWEEN ...) TO STDOUT` piped into `COPY ... FROM STDIN` on the archive.
   Record per table the row count and `md5(string_agg(t::text, '' ORDER BY id))` on both sides; they must match.
4. **Read path.** Support and audit read the archive through a read-only role on the archive database
   (`masslak_readonly` there); the platform's reports name the archive for periods before the cut. The primary keeps
   the bookings until step 5 is signed.
5. **Remove from the primary** only after the owner signs the comparison of step 3, in the reverse order of the
   dependency map, in batches, with `masslak.purging=on` so the audit trail records it as a purge. The ledger is never
   removed: closed days keep their totals (`fin.ledger_day_total`), which the reconciliation reads.
6. **Prove it.** `fin.reconcile_wallets()` with zero mismatches, support can open an archived booking by reference from
   the archive, and a restore of the archive database from its own backup gives the same counts and hashes.

## 30. The request context and its ticket (reviews of October 2026, C-01 and C-02)

Row-level security trusts the context the API sets at the start of each transaction. Since schema file 1080 the
database accepts a context from the API's login only with a ticket: an HMAC of the context and its time, under a key
the login cannot read (`sys.context_key`). `set_config` and temporary objects are withdrawn from the application's
roles, so no statement it runs can rewrite the context or the transaction flags the ledger and wallet guards read.

- **The key.** Derived from `MASSLAK_SIGNING_SECRET` (`python -m app.tools.context_key` prints it in hex);
  `deploy/migrate.sh` writes it on every start through `db/create_login_roles.sql -v context_key=...`. A changed
  signing secret brings its key; the key it replaces stays a day for API processes still running with it.
- **`/api/ready` says `"context": false`.** `SELECT sys.context_status('<fingerprint>')` (as the owner) tells which part:
  `key` false means the database does not hold the API's key: run the migration again (`docker compose ... up migrate`)
  with the API's `deploy/.env`. `set_config_withdrawn` or `temporary_withdrawn` false means the database was created
  anew (a restore) and has PostgreSQL's defaults back: the migration withdraws both again on every start, so run it
  (`deploy/restore.sh` does).
  `no_unsigned_window` false means a rollback window is open (below).
- **The warehouse login keeps `set_config`.** A logical replication connection clears its search path with it before
  streaming. `masslak_cdc` bypasses row security and reads only the published columns, so it gains nothing from it.
- **Every request fails with `CONTEXT_TICKET_*` in the database log.** `STALE`: the API's clock and the database's
  differ by more than five minutes; fix the time service (NTP) on both. `UNKNOWN`/`INVALID`: the API and the database
  hold different keys (see above).
- **Rolling back to a release before 1.49.0.** Those releases set the context without a ticket. After
  `deploy/update.sh --rollback`, a superuser opens a window of at most a day, with a reason:
  `INSERT INTO sys.context_unsigned_window (allowed_until, reason) VALUES (now() + interval '4 hours', 'rollback to 1.48.0: <ticket>')`.
  While it is open `/api/ready` of a 1.49.0 server reports not ready and `set_config` stays withdrawn. Close it when
  the platform is back on 1.49.0 or later: `UPDATE sys.context_unsigned_window SET allowed_until = now() WHERE allowed_until > now()`.
- **What remains.** A person holding the API login's password and a connection to the database could still type
  `SET app.scope = ...` as a statement of their own (PostgreSQL lets any login set custom settings, and only a server
  extension can forbid it). In the production profile (section 31) the database accepts the API's login only over TLS,
  with scram, from the container network it is attached to; the password reaches only the containers that use it
  (deploy/env-split.sh), never the whole deploy/.env. Keep it in the secret store, never in a shared file.
- **Telemetry (C-02).** The API's login to the telemetry database appends positions and nothing else; the worker's
  upkeep login drops days, never younger than `tel.policy.min_keep_days` and never while a hold stands (section 22).

## 31. The production profile (reviews of October 2026, package 2)

A production server runs `deploy/production/docker-compose.production.yml` (docs/operations/PRODUCTION_PROFILE.md).
Each part is checked before the server changes anything.

### The install or the update stops at the preflight

The message names each gap. Fixes:

| Message | Fix |
|---|---|
| `MASSLAK_KMS_PROVIDER=vault is required` / `MASSLAK_VAULT_*` | Fill in the key service in `deploy/.env` (PRODUCTION_PROFILE.md, section 1) |
| `PGBACKREST_REPO1_TYPE ... keeps WAL on this host` | Point pgBackRest at object storage, sftp or a repository host |
| `... is a placeholder: put the page receiver's address there` | Write the receiver's address in `deploy/production/secrets/page_webhook_url` (and `ticket_`, `deadman_`) |
| `TLS is off on the database` | The database does not run the production image: `COMPOSE_FILE` in `deploy/.env` must name the profile (`deploy/production/init.sh` writes it), then `./deploy/update.sh` |
| `pgBackRest could not archive a WAL segment to its repository just now` | The repository refused or was unreachable; the message carries pgBackRest's last lines. Check the bucket and its credentials, then `docker compose --env-file deploy/.env exec -u postgres db pgbackrest --stanza=masslak check` |
| `logical decoding plugins other than pgoutput are installed` | The database image is not `deploy/production/db`: rebuild it |
| `the backup before this update was not copied off the server` | Fix `MASSLAK_BACKUP_OFFSITE` (rclone configuration, reachability) and update again; nothing was changed |
| `the database's certificate expires within 30 days` | Renew it (below) |

### The API or the worker refuses to start: "the production profile is incomplete"

* "does not run the production profile" or "does not check the database's certificate": the container was started
  without the overlay. Use `docker compose --env-file deploy/.env ...`, which reads `COMPOSE_FILE`.
* "data keys sit in this process's environment" or "secrets this process must not hold": it was started with the
  whole `deploy/.env`. Run `./deploy/env-split.sh` and start it again.
* "the data keys must come from the key service": set `MASSLAK_KMS_PROVIDER=vault` (section 1 of the profile document).

### The key service

* **Unreachable at start.** The API and the worker unwrap the data keys when they start: a process cannot start while
  Vault is unreachable, and running processes keep working with the keys they hold.
  1. Check `docker compose --env-file deploy/.env logs egress` for the key service line.
  2. Check that `MASSLAK_VAULT_ADDR` is the host and port the proxy lets through.
* **Token.** Renew or replace `MASSLAK_VAULT_TOKEN` before it expires, run `./deploy/env-split.sh`, and restart the
  app and the worker.
* **Transit key.** Rotate it with `vault write -f transit/keys/masslak-field/rotate`. Wrapped keys made under the older
  version still open. `docker compose --env-file deploy/.env exec app python -m app.tools.keys check` reports any that
  does not.

### Renewing the database's certificates (every 825 days; the preflight warns 30 days ahead)

1. Bring `ca.key` back from offline storage into `deploy/production/tls/`.
2. Delete `server.crt` and `server.key` (and `masslak_cdc.*` for the warehouse's).
3. Run `sudo ./deploy/production/init.sh`.
4. Restart: `docker compose --env-file deploy/.env up -d --force-recreate db db-replica pgbouncer`.
5. Copy the new client certificate to the warehouse server.
6. Move `ca.key` back offline.

### Rotating the warehouse login's password (yearly, and after any suspected exposure)

1. Write a new `MASSLAK_CDC_PASSWORD` in `deploy/.env`.
2. Run `./deploy/update.sh`; the migration sets the new password.
3. On the warehouse server, update the subscription:
   `ALTER SUBSCRIPTION masslak_dw CONNECTION '<the connection string with the new password>'`.
4. Check the alerts `ReplicationSlotInactive` and `ReplicationSlotRetainingWal`.

### `/api/ready` reports `"constraints": false`

A constraint is still NOT VALID because rows that existed before it break it.

1. `SELECT * FROM sys.unvalidated_constraints()` names it, and the last migration's log gives the error.
2. Fix the rows. For the contact constraints of 1046, run
   `docker compose --env-file deploy/.env exec app python -m app.tools.seal_contacts`.
3. Run the migration again (`./deploy/update.sh`, or `docker compose --env-file deploy/.env up migrate`). It validates
   the constraint.

### Monitoring

* **`MetricsMissing`.** A metric an alert rests on is no longer collected; its label names it. Find its source:
  * the API's `/api/metrics`, while the database answers (Alertmanager inhibits this alert while `DatabaseDown` fires);
  * the PgBouncer exporter;
  * node_exporter.
* **`ScrapeTargetDown`.** Check the target with `docker compose --env-file deploy/.env ps`, then its logs.
* **Alert drill.** Run `./deploy/monitoring/alert-drill.sh` after installing, after changing a receiver, and monthly.
  The person on call confirms receipt of the drill's identifier. Record the date, the identifier and who confirmed it
  as launch gate evidence. Leave five minutes between two drills: Alertmanager sends a second drill in the same group only at the
  group's next interval (`group_interval`), after the drill has stopped waiting.

## Rehearsal schedule

| Procedure | Before launch | After launch |
|---|---|---|
| Restore to a point in time | Twice, timed | Monthly |
| Failover and failure tests | Once per failure mode | Quarterly |
| Failover drill (`failover_drill.py`) with Patroni and HAProxy | On staging, before the layout carries production traffic | Quarterly |
| Promoting the second site | Once on staging | Yearly |
| Warehouse copied again (`build.py --resync`) | Once on staging | After each publication change |
| Key rotation | Once in staging | Yearly, and after any suspected exposure |
| Audit archive verify | Once | Weekly (automatic) |
| Alert drill (`deploy/monitoring/alert-drill.sh`) | After installing and after each receiver change | Monthly |
| Warehouse login password | Once on staging | Yearly |
| Database certificates (section 31) | Once on staging | Every 825 days (the preflight warns 30 days ahead) |
| Audit archive tamper drill | Once | Quarterly |
| Break-glass open, expire and review | Once in staging | Yearly |
| ClamAV with the EICAR file | Once | After each ClamAV upgrade |
| Egress self-test | Every deployment (CI) | After each allowlist change |
| Load test | At each release candidate | Before each peak season (Eid, summer) |
| Booking burst (`loadtest.burst`, 1x, 2x, 5x) | On staging, gate 3 | Before each peak season |
| Soak (`loadtest.soak`, 8 to 24 h) | On staging, gate 3 | After a release that changes the booking or money path |
