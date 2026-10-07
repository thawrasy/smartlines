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

- **Targets to confirm with the owner:**
  - RPO of 5 minutes: WAL archived continuously.
  - RTO of 30 to 60 minutes.
- **Backups:**
  - pgBackRest full backup weekly, differential daily, WAL archived continuously to object storage.
  - Backups are encrypted (`repo1-cipher-type=aes-256-cbc`) with a key held in the key service.
  - Backup retention follows `gov.v_lifecycle_matrix.backup_retention_days`, 35 days by default.
- **Restore to a point in time** (into a new server first, never over the primary):
  ```
  pgbackrest --stanza=masslak --type=time --target="2027-03-29 10:15:00+03" --target-action=promote restore
  ```
- **After a restore:**
  1. Run `db/upgrade.sh` to confirm the schema version.
  2. Run `SELECT sys.run_maintenance()`.
  3. Run `python -m app.tools.keys check`, to prove the key service still opens every data key.
  4. Run the reconciliation checks from section 1.5.
- **Restore drill:** monthly, timed, recorded in the operations log. The audit trail must survive it: compare the latest
  `audit.ddl_event` and `audit.row_change` ids with the archive (section 7).

## 3. Failover

- **Who decides:** Patroni promotes the standby when the primary fails its health checks, for about 30 seconds of
  detection. The application connects through the Patroni-aware endpoint (HAProxy or PgBouncer in front), so it reaches
  the new primary on reconnect.
- **During failover:**
  - Transactions in flight are rolled back.
  - The API retries idempotent requests. Bookings and payments carry idempotency keys, so a retry never doubles them.
- **Manual switchover** for maintenance: `patronictl switchover --leader <old> --candidate <new>`.
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
- **Never edit a schema file that has been applied.** `db/upgrade.sh` warns when one changed; add a new file instead.
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

- **Export:** `python -m app.tools.audit_export export /var/lib/masslak/audit-archive` runs hourly as the audit role.
  It writes gzip JSON lines and a manifest chained by SHA-256.
- **Sync** to a bucket with object lock in compliance mode:
  ```
  aws s3api create-bucket --bucket masslak-audit-archive --object-lock-enabled-for-bucket
  aws s3api put-object-lock-configuration --bucket masslak-audit-archive \
      --object-lock-configuration 'ObjectLockEnabled=Enabled,Rule={DefaultRetention={Mode=COMPLIANCE,Days=2555}}'
  aws s3 sync /var/lib/masslak/audit-archive s3://masslak-audit-archive/ --no-progress
  ```
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

## 8. Alerts the database raises

| Event | Meaning | Action |
|---|---|---|
| `security.ddl_change` | A grant, policy, function, trigger or row-level security change made outside a migration | Confirm who made it (`audit.ddl_event`); revert unless it was an approved emergency change, then open an incident |
| `integrity.orphans_found` | References to missing rows (`sys.orphan_check.findings`) | Find the writer (the owner column of `sys.polymorphic_reference`), repair the rows, and add a test |
| Wallet mismatches in `sys.run_maintenance()` | Ledger and balances disagree | Severity 1: freeze payouts, reconcile (`fin.wallet_reconciliation`) |
| `security.break_glass_opened` | Someone holds break-glass access now | The security officer confirms the incident and the approver (section 11) |
| `security.break_glass_expired` | A break-glass access reached its expiry | Revoke any credential issued for it (Vault token, database role); the review is due |
| `security.break_glass_unreviewed` | A break-glass access ended more than 24 hours ago without a review | The security officer and the data owner review it now |
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
- **Retries:** the worker retries pending files every minute, five attempts at most.
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

## Rehearsal schedule

| Procedure | Before launch | After launch |
|---|---|---|
| Restore to a point in time | Twice, timed | Monthly |
| Failover and failure tests | Once per failure mode | Quarterly |
| Key rotation | Once in staging | Yearly, and after any suspected exposure |
| Audit archive verify | Once | Weekly (automatic) |
| Audit archive tamper drill | Once | Quarterly |
| Break-glass open, expire and review | Once in staging | Yearly |
| ClamAV with the EICAR file | Once | After each ClamAV upgrade |
| Load test | At each release candidate | Before each peak season (Eid, summer) |
