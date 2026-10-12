# Migration plans

Every schema file that changes a table with data gets a plan here before it reaches a live database (audit T3-08).
The plan comes from a rehearsal (`db/tools/migration_rehearsal.py`), not from guesswork.

## How a file is rehearsed

```sh
python3 db/tools/migration_rehearsal.py --base <last file of the running release> --scale 200000 --report docs/operations/evidence -h ... -U ...
```

The tool:
1. Builds the previous release.
2. Fills the tables the new files touch with synthetic volume.
3. Runs application-like reads and writes on those tables.
4. Applies the new files with `db/upgrade.sh`. Every statement waits at most `MASSLAK_LOCK_TIMEOUT` (5 s) for a lock
   and runs at most `MASSLAK_STATEMENT_TIMEOUT` (30 min).
5. Records:
   - the migration time and the WAL written;
   - the longest exclusive lock and the sessions queued behind it;
   - the traffic's p50, p99, maximum and errors before, during and after.

On staging, run it on a copy of production instead of synthetic volume (drop `--scale`, point it at the copy).

**To find the slowest statements of a file:** apply it with `\timing on` on the filled rehearsal database
(`(echo '\timing on'; cat db/schema/<file>) | psql -1 -d <db>`).

## Stop criteria

A file goes to production as it is only when the rehearsal shows:
- an exclusive lock of at most **2 s** on any table the booking path writes;
- traffic p99 of at most **1 s** while it runs;
- **no** traffic errors.

Otherwise it is split before it ships:
1. **Expand:** add the structure.
2. **Backfill** in batches of 10,000 rows, committed separately.
3. **Validate** constraints added `NOT VALID` with `VALIDATE CONSTRAINT`, which takes a lock that lets writes continue.
4. **Index** with `CREATE INDEX CONCURRENTLY`, in its own file.
5. **Contract** in a later release.

**During the production run:** watch `pg_stat_activity` for sessions waiting on locks, and the API's p99. Stop the
deployment if either crosses the criteria. A file that fails rolls back by itself, so nothing is left half applied.

## Forward fix, not rollback

- **After failure:** once a file has written data, it is never "rolled back" by hand.
- **Fail before commit:** the transaction undoes everything. Fix the cause, then rerun.
- **Wrong after commit:** write a new file that corrects the result, rehearse it, and apply it. The previous application
  version keeps working, because every change is backwards compatible within a release (expand before contract).
- **Data destroyed:** use the point-in-time restore to the minute before the migration (runbook section 2), then replay
  the new transactions from the application logs.

## 1048_design_audit_t3.sql

**Rehearsal on 7 October 2026** (`docs/operations/evidence/migration_rehearsal_1048_2026-10-07.json`), 200,000 rows each
in positions, outbox events, files and the sensitive-read log (239 MB):

| Run | Migration | WAL | Longest exclusive lock | Traffic p99 during | Traffic max during | Errors |
|---|---|---|---|---|---|---|
| 1 | 5.8 s | 87 MB | 2.41 s | 4.0 ms | 2.35 s | 0 |
| 2 | 5.2 s | 87 MB | 1.98 s | 3.2 ms | 1.90 s | 0 |

- **Where the time goes:** the one-time move of positions from monthly to daily partitions (1.3 s at this volume),
  then the index on the device event id and the constraint checks on files and the sensitive-read log.
- **Verdict:** at the 2 s limit. The file runs before the launch, on a database with no live positions, so it ships as
  it is.
- **If it ever had to run on a live database:** apply the re-partitioning separately, while positions keep arriving.
  1. Create the daily partitions for the days ahead.
  2. Detach each monthly partition `CONCURRENTLY`.
  3. Copy its last seven days in batches.
  4. Drop it.

  Add the constraints `NOT VALID` and validate them afterwards.
- **Stop sign in production:** sessions waiting on locks for more than 2 s on `ops.geo_event`, `sys.outbox_event` or
  `ref.file_object`.

## Release 1.48.0 (1074 to 1079)

**Rehearsal on 10 October 2026** (`docs/operations/evidence/migration_rehearsal_1.48.0_dev_2026-10-10.json`), from a
database at 1073 with 200,000 rows each in positions, outbox events, files and the sensitive-read log (279 MB), traffic
running throughout:

| Migration | WAL | Longest exclusive lock | Sessions waiting | Traffic p99 before / during / after | Errors |
|---|---|---|---|---|---|
| 7.1 s | 3.7 MB | 0.51 s | 0 | 4.9 / 4.9 / 4.3 ms | 0 |

Within the stop criteria. None of the six files rewrites a large table: they add tables, columns without a default
rewrite (`ADD COLUMN ... NULL` or a constant default), triggers and functions; 1078 adds a stored generated column to
`ship.parcel`, which rewrites that table once (small in every deployment so far; on a copy of production, time it and
split it into its own file if it exceeds the criteria); 1079 reads the catalog and writes about 500 small rows. This is a
development rehearsal: the launch gate (`LAUNCH_GATES.md`, gate 4) still needs the same run on a production-size copy.

## Release 1.49.0 (1080 to 1083)

No file changes a business table's rows or structure:

* **1080** adds two small tables (`sys.context_key`, `sys.context_unsigned_window`), replaces `sys.set_context`, and
  withdraws `set_config` and temporary objects from PUBLIC. The withdrawal needs a superuser, which the migration is.
* **1081** changes only the settings of the SECURITY DEFINER functions (`ALTER FUNCTION ... SET search_path`).
* **1082** adds two functions. The upgrade then validates every constraint still NOT VALID, each in its own
  transaction (`CALL sys.validate_constraints()`). VALIDATE takes a SHARE UPDATE EXCLUSIVE lock, so reads and writes
  go on, but it scans the table. On a fresh database this is instant. On a server whose old rows break one, the
  constraint stays NOT VALID and is named, and `/api/ready` reports `"constraints": false` (RUNBOOKS.md, section 31).
* **1083** adds a setting and four functions, and replaces the three partition upkeep functions. It moves no row
  itself: a default partition that holds a large late period on the day of the upgrade is emptied afterwards by the
  worker, one period per transaction.

They take catalog locks for milliseconds, so they were not rehearsed with the tool.

One point needs care. From 1080 on, the database refuses a context without the API's ticket. A 1.48.0 API process
still serving between the migration and its own restart has its requests refused: the gap lasts as long as the
migration, a few seconds.

A server that must not refuse those requests:

1. As a superuser, opens a window of a few minutes before `deploy/update.sh`:
   `INSERT INTO sys.context_unsigned_window (allowed_until, reason) VALUES (now() + interval '15 minutes', 'upgrade to 1.49.0')`.
2. Closes it when `/api/ready` of the new release answers:
   `UPDATE sys.context_unsigned_window SET allowed_until = now() WHERE allowed_until > now()`.

While the window is open, readiness reports not ready (RUNBOOKS.md, section 30).

## Release 1.50.0 (1084, 1085)

**1084** adds four functions and replaces two (`sys.tg_remember_new_row`, `sys.created_here`). It changes no table and
moves no row, so it takes catalog locks for milliseconds and was not rehearsed with the tool. The list of rows a
transaction created moves from one setting per table to the one setting `app.new_rows`; the two functions are replaced
in the same transaction, so a transaction that started before the swap finds its rows the old way until it ends.

What needs care is the database server, not the file: the settings guard is a server module (`db/guard`), loaded when
the server starts. `deploy/update.sh` runs the release's database image, which recreates the database container: the
server restarts once, for the seconds it takes to start (with two database hosts, `install-db-host.sh` with the new
bundle on the standby's host first, then on the primary's, which hands the role over before it restarts:
HIGH_AVAILABILITY.md). Until it has restarted, `sys.guard_status()` is false and `/api/ready` of
a production server reports `"settings_guard": false`; the preflight of the next update refuses a server where it stays
false (RUNBOOKS.md, section 30).

**1085** changes two check constraints and no row: the status `DEACTIVATED` of `iam.app_user` and two sign-in audit events
(`ACCOUNT_DEACTIVATED`, `ACCOUNT_REACTIVATED`). Each `ALTER` takes an access-exclusive lock on its table while it
replaces the check constraint, for a moment. It was not rehearsed with the tool, for the same reason as 1084. Existing
accounts keep their status; no row is rewritten.

**1086** creates one table, `iam.party_photo` (one row per person: the encrypted file, who took it and when), with its
row-level policy, its phase, class and lifecycle rows, and three functions: `iam.set_party_photo` (takes or replaces the photo,
checking that the caller is the person or the head of their family), and `gov.erase_party_photo` (removes the photo in an
erasure). It changes no existing table and no existing row, so it takes no lock on the party table. The photos themselves are
written by the API, not by the migration. Nothing refers to the new table, so it adds no reference cycle. An erasure deletes the
file row in the same transaction; the store deletes the bytes after its 24-hour grace period.

**1087** adds the boarding photo policy and its replacement: two tables (`iam.photo_rule`, `iam.photo_change_request`), both
platform-only under row-level security, and functions that write them with four eyes (a proposer, an approver and a retirer
are different people; the database checks it, the API answers first with `FOUR_EYES`). It widens two existing checks, which
is the only change to existing objects: `iam.party_photo.taken_by` may now be `PLATFORM`, and `sales.boarding_event.result` may
now be `PHOTO_REQUIRED`. The constraint changes take a short lock on those two tables, and no data is rewritten. `gov.erase_party_photo`
is redefined to remove the evidence and candidate photos of the person's requests. Nothing refers to the two new tables, so the
schema dependency check stays at its baseline. Applied on a fresh database; a live database applies it in a maintenance window
because the two constraint changes validate the existing rows.

**1088** makes the documents accepted for a change of the boarding photo a platform setting. It adds `iam.photo_evidence_kind`
(three kinds seeded: civil registry extract, national identity card, passport; each on or off), replaces the fixed check on
the request's evidence kind by a reference to it, and redefines `iam.request_photo_change` to refuse a kind that is off. It
changes no existing row. The constraint change validates the existing requests, which all carry one of the three kinds.

**1089** makes a change to the accepted documents, and to the age rule for the national identity card, need two people. It adds
two tables (`iam.photo_policy_change`, `iam.photo_policy_approval`), platform-only under row-level security, and five functions
that write them. It drops the one-person switch of 1088, which had not been released, and redefines
`iam.request_photo_change` to check the evidence through `iam.evidence_accepted`. It adds two `sys.setting` keys with
their defaults (`photo.policy_min_approvals` = 2, `photo.identity_card_min_age` = null, meaning no age rule). It changes no
existing request, and the approval count cannot be set below two.

**1090** completes the list of documents accepted nationally for a photo change: it adds two kinds (the travel document
issued by a Syrian mission abroad, for Syrian citizens only; and the temporary identity document of the first phase), adds
a flag to mark the kinds under the age rule of the identity card (the national identity card and the temporary identity
document), and redefines `iam.evidence_accepted` to apply the nationality condition. It changes no existing request, and no
table is added.

**1091** makes the approval stages a platform setting and snapshots them with each change. A change to the photo on file,
to the accepted documents, to the age rule, or to a required data item passes the stages: one person per stage, never the
one who asked, and never the same person twice. It replaces the two-person approvals of 1089 with one table
(`iam.photo_approval`) and drops the 1089 table, which had not been released. It sets the age default to 18, adds the table
of required data items (`iam.data_requirement`) with four seeded items, all optional, and redefines the request and the
approval functions to use them. It replaces the photo change's single approver of 1087 with the staged approval. The
stages are not a fixed number of people: the platform sets them, and the function never accepts fewer than two.

**1092** applies the approval stages to the photo rules. A proposal is in force when its stages are passed; a proposal not
yet in force is withdrawn; a rule in force is retired through its own stages, and it stays in force until they are passed.
The retirement has its own approval subject (a value from a sequence), so approvals of a rejected retirement never count for
a later one. The rule table gains the stage snapshots and the retirement fields, with a check that a retirement has them; the
status set gains `RETIRING`; the approval table takes the subjects `RULE` and `RULE_RETIREMENT`, and the registry and the JSON
contracts know them. `iam.photo_requirement` counts a rule being retired as in force. The one-person functions of 1087 for
approving, retiring and withdrawing a rule are replaced; the rule table had no release. No row is changed.

**1093** applies the owner's decision on retirements: the person who proposed a photo rule does not approve its retirement.
It redefines `iam.approve_photo_rule_retirement` with that check; the proposer may still ask for the retirement. No row is
changed, and no table is added.

**1094** switches the boarding photo off at launch. The switch is the setting `photo.enabled` (false), read by
`iam.photo_enabled()`. A change to it is a policy change with a legal basis (`legal_basis`, at least ten characters) that
passes the approval stages like the others; applying it sets the setting. `iam.set_party_photo` refuses a photo while the
switch is off. Existing rows are unchanged; one switch change may wait for approval at a time.

**1095** makes the approval stages of the photo policy a setting the platform changes: at least two stages, the final
approval always last, and no stage forced (a security or third-party check is one choice). A change keeps the stages it was
asked with. The approval takes an optional legal document number, recorded on the change. No table is added.

**1096** makes the rest of the photo's switches platform settings, each changed through the approval stages: who may see the photo and when (`photo.view_access`), the date the rules are enforced from (`photo.enforce_from`), how often a person is checked (`photo.verify_every_days`) and the identity provider (`photo.identity_provider`, NONE until one is connected). The database checks each new value and reads only these keys. No table is added.

**1097** builds the boarding stations, off at launch (`docs/operations/BOARDING_STATIONS.md`). The platform settings are off or empty and are changed through `net.set_boarding_setting`, which checks each key. Two tables are added: `net.station_boarding` (each station's switch, counter system, screens and check-in window, phase 7 and so closed while the stations switch is off) and `net.operation_reference` (a carrier's agreement and licence numbers, phase 1A). One column is added to `net.station_gate` (`operator_company_id`, required for a counter only). The migration is fast on a live database: the column is nullable and the table is small. The platform numbers the counters and bays per station (`net.open_station_gate`), and no number is reused. Two permissions are added, `boarding.manage` for the platform administrator and `boarding.references` for the carrier's operations role. Each new table has its classification (`sys.table_class`) and dataset (`gov.dataset_member`).

**1098** adds what an operating company may do at a station, for which carrier (step 2 of the boarding stations). One table is added, `net.station_operator_grant`: a carrier grants a right (`BOOKING`, `BOARDING_PASS`, `BOARDING`) for its own trips at one station or every station; the platform grants a state-mandated operator the same rights with no carrier. Rows are revoked, never changed or deleted; the carrier's rows are written only by the carrier, the platform's only by the platform, and each party sees the grants it gave or received. The decision `net.operator_may` reads the station's switch and the mode that gave the grant, so nothing acts at launch. Phase 7, like the station switch. One permission is added, `boarding.operators`, for the carrier's operations role. The migration is fast: the table is new and empty.

## 1064_partitioned_bookings.sql on a live database (R-06)

1064 turns `sales.booking` into a table partitioned by ranges of id **in place, under an ACCESS EXCLUSIVE lock**: it
copies every booking into the new partitions and re-points about 22 foreign keys. Bookings and payments wait for the
whole copy. It is therefore never applied to a live database as a routine upgrade:

1. **Measure first** on a copy of production with `migration_rehearsal.py --base 1063` (no `--scale`): the copy time
   per million bookings, the WAL written and the lock time. The rule from the rehearsals so far: the lock lasts as long
   as the copy; budget it as the measured rows-per-second times the bookings held.
2. **Decide the window.** Up to the stop criteria (2 s): apply as a normal upgrade. Above them: announce a maintenance
   window sized from the measurement plus 50 %, stop selling (take the API servers out of the load balancer, as for any maintenance window) and let in-flight holds expire.
3. **Before:** backup with a fresh pgBackRest full and confirm WAL archiving (`deploy/pitr/check-archive.sh`); record
   booking, ticket and ledger counts and `fin.reconcile_wallets()`.
4. **Run** `db/upgrade.sh` with `MASSLAK_STATEMENT_TIMEOUT` raised to the window and the lock timeout unchanged.
5. **After:** the same counts, `fin.reconcile_wallets()` with zero mismatches, the foreign-key checks of
   `db/tests/run_tests.sql` (partitioned bookings), and a test booking end to end. Reopen sales.
6. **Stop and forward fix:** the file runs in one transaction; a failure or a cancelled statement leaves the table as it
   was. Point-in-time restore is only for a wrong result found after commit.

Dated reports at 1x, 2x and 5x the expected volume (`generate_volume.py`) are the evidence the gate asks for
(`evidence/migration_rehearsal_staging_1064_<scale>_<date>.json`).

## 1070: late partitions moved out of the default partition (R-06)

`sys.create_partition` detaches the default partition, copies one period's rows into the new partition and deletes them
from the default partition **in one transaction**, holding the parent's lock while it does. The time is proportional to
the rows that piled up in the default partition, which is why the monitoring pages as soon as it holds rows
(alert `RowsInDefaultPartition` on `masslak_partition_default_rows`):

- **In normal operation** the default partition is empty and the function only creates the next period: milliseconds.
- **After an outage of the upkeep** (rows in the default partition): run the upkeep by hand outside peak hours. Above
  about 200,000 rows in one period, move them in batches first (`INSERT ... SELECT ... LIMIT 10000` into a staging table
  and `DELETE` the same keys, repeated), then let `sys.create_partition` attach the period with few rows left.
- **Measure** the move time per 100,000 rows on staging with a filled default partition (the database checks of 1070
  build one) and record it here before the first production upkeep after an outage.
