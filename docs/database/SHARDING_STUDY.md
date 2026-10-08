# Splitting the data by company: a measured study

Expert review of October 2026, stage D4. Tool `db/tools/shard_study.py`; figures of 8 October 2026.

The capacity model (`docs/operations/CAPACITY_MODEL.md`, stage 3) named distribution by carrier, on the `company_id`
column every tenant table carries for row-level security, as the path above 20 million operations a day. This study
measures, on the real schema, how much of the data and of the money would actually stay on one node under that
split, before anyone builds it.

## Method

`python3 db/tools/shard_study.py <database> --json out.json --md out.md [psql connection args]` reads only. It
places every table under a split by company:

| Placement | Meaning | What a split needs |
|---|---|---|
| DISTRIBUTE | the table has `company_id` | nothing: rows go to the company's node |
| CHILD | reaches its company through a parent (`sys.table_class.tenant_path` = "parent ...") | the column added and filled, or co-location by the parent's key |
| SHARED | reached through a function: rows two companies both see (partners, schools, interline) | a design: replicate, or pick an owner |
| REFERENCE | catalogues and system tables | replicated to every node |
| CENTRAL | people, platform money, security, audit | one central node, reached across the network |

It then counts, for each foreign key between two tables that both carry `company_id`, the rows pointing at another
company's row; for each ledger transaction, the companies, people and platform wallets it touches and its
currencies; and how bookings spread over companies.

It was run on two databases:

* **Volume**: the full schema with three months of synthetic history (`db/tools/generate_volume.py --months 3
  --bookings-per-day 1500`): 135,005 bookings, 135,002 ledger transactions, 134,400 positions, 315 MB.
* **Demo flows**: the long-lived test database, whose 120 ledger transactions were all made through the API by the
  end-to-end tests (top-ups, wallet and card bookings, refunds, cash remittance and netting, payouts, subscriptions,
  shipments, family wallets), so every kind of money movement appears.

## Results

### Where the data would go (volume database)

| Placement | Tables | Rows | Size (MB) |
|---|---|---|---|
| DISTRIBUTE | 121 | 180,190 | 116.2 |
| CHILD | 128 | 653,901 | 159.0 |
| SHARED | 39 | 361 | 3.0 |
| REFERENCE | 90 | 2,033 | 5.0 |
| CENTRAL | 107 | 1,839 | 7.1 |

The largest tables:

| Table | Placement | Rows | MB | Reaches its company through |
|---|---|---|---|---|
| sales.booking | DISTRIBUTE | 135,005 | 88.5 | `company_id` |
| fin.ledger_entry | CHILD | 270,004 | 45.6 | its wallet |
| fin.ledger_txn | CHILD | 135,002 | 38.8 | its entries' wallets |
| ops.geo_event | CHILD | 134,400 | 31.0 | its trip |
| sales.ticket | CHILD | 54,002 | 22.8 | its booking |
| sys.outbox_event | DISTRIBUTE | 43,506 | 16.2 | `company_id` |
| sales.passenger | CHILD | 54,012 | 13.0 | its booking |

**55 % of the bytes are in CHILD tables.** Tickets and passengers follow their booking cleanly (adding `company_id`
is mechanical). The ledger does not: an entry belongs to a wallet, and a wallet belongs to a person, a company or the
platform. Positions leave the primary anyway (stage D2, telemetry database).

### Money that would cross nodes

Demo flows (all kinds of transaction):

| Transactions | Several companies | A person and a company | A platform wallet | Several currencies |
|---|---|---|---|---|
| 120 | 1.7 % | 3.3 % | **94.2 %** | 0 |

Volume database: 135,002 transactions, 100 % touch a platform wallet (card payments clear through the platform's
gateway wallet), 0 % several companies, 0 several currencies.

Every booking payment, refund, top-up, payout and compensation moves money through a platform wallet: escrow,
gateway clearing, bank clearing or fees. Under a split by company the platform's wallets live on one node, so **almost
every money transaction would span two nodes** and need a two-phase commit, which is slower than the single-node
commit it replaces and blocks both nodes when the coordinator fails.

**No transaction mixes currencies.** Each market's money stays in its own currency (stage D1), so a split by market
cuts no transaction at all.

### Rows that point at another company

143 foreign keys join two tables that both carry `company_id`; rows cross companies in 3 of them, all by design:

| Foreign key | Rows | Why |
|---|---|---|
| ptn.fuel_session → ptn.partner | 60 | a fuel station serves many carriers |
| ptn.partner_sale → ptn.partner | 40 | the same |
| sch.contract → sch.school | 1 | a school contracts a carrier |

Partners and schools would be replicated to every node (REFERENCE-like), or their facts split by the carrier side.

### Skew

Both databases hold the bookings of one demo carrier, so skew cannot be measured here. Intercity coach markets
usually have a few large carriers selling most seats: the largest carrier's node would carry a large share of the
load whatever the number of nodes. **Measure it on staging with a restored copy of production** (the tool's
`largest_share` and `companies_for_80_percent`) before any decision.

## Recommendation

1. **Do not distribute by carrier now.** One primary carries the 20 million design target once positions have left
   it (capacity model, section 6), and a split by carrier would turn nearly every payment into a two-node
   transaction.
2. **Split by market first, when a second market grows.** Markets share no transaction, no currency and no
   carrier: each market can run its own complete stack (primary, replica, warehouse, telemetry), with the platform
   catalogue (`ref.market`, currencies, global settings) replicated from a central database. Stage D1 already keeps
   every market's days and money apart.
3. **Inside a market, move whole domains that share no money with bookings** (freight, school transport) to their
   own cluster before splitting carriers.
4. **Only then, if one market outgrows one primary**, distribute by carrier, with these preconditions:
   * the platform's wallets split per carrier (escrow, gateway and bank clearing held per carrier, settled to the
     central platform asynchronously through the outbox), so that a booking's money stays on its carrier's node;
   * `company_id` added to the CHILD tables of the booking path (tickets, passengers, seat segments, payments,
     ledger transactions and entries of carrier wallets), or co-location by booking;
   * the 39 SHARED tables given an owner or replicated;
   * people (accounts, passengers' own wallets) on a central node, reached only at sign-in and top-up, with
     wallet payments to a carrier made through a per-carrier clearing wallet;
   * skew measured on production data, with the largest carriers on nodes of their own.

The capacity model's stage 3 now reads this way.

## Re-running

On staging with production-size data or a restored copy of production:

```
python3 db/tools/shard_study.py masslak --json shard.json --md shard.md -h <host> -U <owner>
```

The tool also found and fixed two defects on the way: the row and size figures of plain (not partitioned) tables
were read as zero, and the volume generator set the stored balance of shared (DEFERRED) wallets to the full ledger,
counting entries still waiting for the roll-up twice (three wallets disagreed with the ledger after a volume run;
none after the fix).
