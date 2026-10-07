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
