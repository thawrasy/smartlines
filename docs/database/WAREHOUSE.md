# Data warehouse fed by change data capture

Expert review of October 2026, stage D3. Schema file `1062_warehouse_publication.sql`, tool `db/warehouse/build.py`,
deployment `deploy/warehouse/docker-compose.warehouse.yml`, operations in `docs/operations/RUNBOOKS.md` section 21.

## Why

Reports for carriers and the platform already run on the streaming replica, so they never slow bookings. Analysis
over months of history (sales by market and day, load factors across routes, money by kind of transaction) is a
different load: long scans that would hold the replica's WAL replay back and that need no live data. They belong in a
database of their own that is kept current from the primary's changes, not from nightly exports.

## How it works

```
primary (wal_level = logical)                              warehouse (another server)
  publication masslak_dw ── logical replication ──▶  subscription masslak_dw
    14 tables, listed columns only                      same tables, published columns only
  slot masslak_dw (WAL kept until read)                 dw schema: materialized views, refreshed every 15 min
  role masslak_cdc (reads the listed columns)           role dw_reader / login dw_analyst
```

* **What leaves the primary** is decided in one place, `sys.dw_columns()`: the facts (trips, bookings, tickets,
  payments, wallets, ledger transactions and entries) and the dimensions they need (markets, cities, stations, routes,
  carrier codes, companies, sales channels). Each table carries only the listed columns. Names, contact data,
  identity numbers, the booker, the payer, family links, wallet owners, ledger memos and card details stay on the
  primary. `sys.dw_publish()` applies the list to the publication and to the column grants of `masslak_cdc`.
* **Partitioned tables** (ledger entries) are published as one table (`publish_via_partition_root`), so the
  warehouse needs no partition upkeep of its own.
* **The subscription** is created by `db/warehouse/build.py`. It reads the published tables and column types from
  the primary, creates them in the warehouse with their primary keys (no foreign keys: tables arrive independently),
  creates the replication slot on the primary and then the subscription (so a warehouse inside the primary's own
  cluster works too, which the CI job and local tests use). The first copy of every table runs in parallel; changes
  stream afterwards within seconds.
* **The analysis layer** is schema `dw`:

  | View | Grain | Local day |
  |---|---|---|
  | `dw.sales_daily` | day, market, company, channel, pay method, currency: bookings, confirmed, cancelled, amount | departure station's city (else its market) |
  | `dw.trip_load` | trip: seats, tickets, boarded, load factor, revenue | departure station |
  | `dw.ledger_daily` | day, kind of transaction, currency: transactions, amount | the currency's market |
  | `dw.payments_daily` | day, purpose, method, provider, status, currency: payments, amount, fees, refunds | the currency's market |
  | `dw.freshness` | when the subscription last heard from the primary and when each view was refreshed | |

  `dw.refresh()` refreshes them concurrently: readers keep the previous figures while it runs. The
  `warehouse-refresh` service calls it every 15 minutes.

## Security

* The warehouse holds no personal data, so analysts (`dw_analyst`, member of `dw_reader`) may read all of it. The
  database checks (`db/tests/run_tests.sql`, "Warehouse:") fail the build when the publication differs from the list,
  when a published table is classed as personal, security or audit data, or when a published column looks personal;
  `build.py --check` fails when the warehouse holds a column the primary does not publish.
* `masslak_cdc` has `REPLICATION` (not inherited, so it signs in itself) and `BYPASSRLS` (the first copy must see
  every company's rows), and column grants on exactly the published columns. It owns nothing and belongs to no role.
  It has no login until the deployment gives it a password (`MASSLAK_CDC_PASSWORD`); `pg_hba.conf` lets it open
  logical replication connections (which name the database) and never a physical stream of the cluster.
* **Residual risk, accepted and documented.** Any role with `REPLICATION` can create a logical slot with another
  output plugin (PostgreSQL ships `test_decoding`) and decode every change of every table, whatever the publication
  says. The column lists protect what the warehouse stores, not what a thief of the `masslak_cdc` password could read.
  The password is therefore a secret of the same class as `MASSLAK_REPLICATION_PASSWORD`: it lives only in
  `deploy/.env` and in the warehouse's subscription (readable by its superuser alone) and is rotated with the others.
  Misuse is detected, not prevented: a logical slot with any plugin but `pgoutput` raises the paging alert
  `ReplicationSlotForeignPlugin` at the next scrape, and `log_replication_commands = on` records every slot created,
  by whom and with which plugin, including short-lived ones the alert could miss.

## Keeping the primary safe

A replication slot keeps WAL until its reader has it. A stopped warehouse would otherwise fill the primary's disk.

* `max_slot_wal_keep_size = 20GB` (docker-compose.yml, `deploy/pitr`, staging): beyond it the primary drops the slot
  and keeps running; the warehouse then copies everything again (`build.py --resync`).
* `sys.replication_metrics()` reports, per slot, the WAL it holds back, whether a reader is connected and whether it
  decodes with a foreign plugin. Alerts: `ReplicationSlotRetainingWal` (more than 5 GB for 15 minutes),
  `ReplicationSlotInactive` (no reader for 30 minutes) and `ReplicationSlotForeignPlugin` (at once), with promtool
  tests.
* `wal_level = logical` is set on the primary from this release, so adding a warehouse later needs no restart of the
  primary. Its cost is a little more WAL for updates; the physical replica and archiving are unaffected.

## Changing what is published

1. Edit `sys.dw_columns()` in a new schema file and call `SELECT sys.dw_publish()` in it.
2. Check the new columns against the security rules above; the database checks must still pass.
3. Run `build.py` again on the warehouse: new tables are created and copied, new columns are added. Rows that do not
   change afterwards keep the new column empty until `build.py --resync`.

## Tested

* Locally: a primary (masslak_c) streaming to a warehouse on a second PostgreSQL server (port 5434) and to a warehouse
  in the same cluster; first copy of the 14 tables in about 3 seconds; a change visible in the warehouse within 2
  seconds; `--check` with equal row counts; `--resync`; a column added by hand in the warehouse reported.
* CI job "Data warehouse (change data capture)": two PostgreSQL servers, the full schema and demo data on the
  primary, subscription and first copy, a streamed change, equal counts, the analyst reads the views, the replication
  login refused personal columns, and a full re-copy.
