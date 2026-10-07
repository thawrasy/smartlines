# Operations runbooks

These procedures cover the operational items of the third-party technical audit (R-09, R-10, R-11, R-12) and the
operations gate of the architecture reports. Each one names the tool in the repository that carries it out.

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
- **Verify** weekly, and after any restore: `python -m app.tools.audit_export verify <dir>`. It must report 0 problems.
- **Retention:** seven years, matching `audit.*` in the lifecycle matrix. Nobody can delete the objects before then,
  including the platform's administrators.

## 8. Alerts the database raises

| Event | Meaning | Action |
|---|---|---|
| `security.ddl_change` | A grant, policy, function, trigger or row-level security change made outside a migration | Confirm who made it (`audit.ddl_event`); revert unless it was an approved emergency change, then open an incident |
| `integrity.orphans_found` | References to missing rows (`sys.orphan_check.findings`) | Find the writer (the owner column of `sys.polymorphic_reference`), repair the rows, and add a test |
| Wallet mismatches in `sys.run_maintenance()` | Ledger and balances disagree | Severity 1: freeze payouts, reconcile (`fin.wallet_reconciliation`) |

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

## Rehearsal schedule

| Procedure | Before launch | After launch |
|---|---|---|
| Restore to a point in time | Twice, timed | Monthly |
| Failover and failure tests | Once per failure mode | Quarterly |
| Key rotation | Once in staging | Yearly, and after any suspected exposure |
| Audit archive verify | Once | Weekly (automatic) |
| Load test | At each release candidate | Before each peak season (Eid, summer) |
