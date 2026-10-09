# Staging environment

**Who runs it.** The owner decided (8 October 2026) that staging and the penetration test are run by external
cybersecurity firms or independent testers, not by the development team. This document is what the firm that operates
staging receives. The penetration test has its own scope: `docs/security/PENETRATION_TEST_SCOPE.md`.

**What it is for.** The launch gates (`LAUNCH_GATES.md`) for recovery, capacity, migrations, monitoring and file
scanning are measured here, on production-like hardware with production-size synthetic data. Measurements from a
developer machine or CI are smoke tests, not launch evidence.

## Contents of the kit

| Part | File | What it adds to the production stack |
|---|---|---|
| Compose overlay | `deploy/staging/docker-compose.staging.yml` | Everything below, on top of `docker-compose.yml` |
| Database with pgBackRest | `deploy/staging/db/` | WAL archived through pgBackRest every 60 s at most (approved RPO 60 s), encrypted repository, `pg_stat_statements`, lock and slow-query logging, `track_functions = pl` (trigger cost) |
| Read replica | service `db-replica` (production stack) | Streaming hot standby where reports and exports run; replica lag is monitored; failover drill (RUNBOOKS section 3) |
| ClamAV | service `clamav` | The file scanner's engine (`MASSLAK_CLAMD=clamav:3310`); without it production files stay pending (fail-closed) |
| Prometheus | service `prometheus` | Scrapes `/api/metrics` with the token, evaluates the 43 rules of `deploy/monitoring/alerts.yml` |
| Alertmanager | `deploy/staging/alertmanager.yml` | Severity `page` to the on-call channel, `ticket` to the team queue |
| Grafana | `deploy/staging/grafana/` | The operations dashboard, provisioned; bound to 127.0.0.1 (reach it through an SSH tunnel) |
| Secrets | `deploy/staging/init-secrets.sh` | Metrics token, Grafana password, receiver URLs as files (never committed); prints the `.env` lines |
| Volume generator | `db/tools/generate_volume.py` | Production-size history that passes the money and reference checks |
| Connection pooling | service `pgbouncer` (production stack) | Transaction pooling between the API instances and the primary |
| Shared-wallet benchmark | `db/tools/wallet_contention_bench.py` | Postings per second on one carrier wallet and one clearing wallet (run on a scratch copy) |

## Bring it up

```sh
./deploy/init-env.sh                         # deploy/.env with random secrets; set MASSLAK_SANDBOX=true, MASSLAK_SEED_DEMO=true,
                                             # and MASSLAK_ENVIRONMENT=staging (the gate evidence is filed under it)
./deploy/staging/init-secrets.sh             # add the printed lines to deploy/.env; put the receiver URLs in deploy/staging/secrets
docker compose -f docker-compose.yml -f deploy/staging/docker-compose.staging.yml --env-file deploy/.env up -d --build
docker compose ... exec -u postgres db pgbackrest --stanza=masslak --type=full backup     # first full backup
```

Order the staging servers with encrypted disks and volumes, as production will have them
(`INFRASTRUCTURE_REQUIREMENTS.md` section 5): the recovery drill then restores onto encrypted storage too.

`MASSLAK_ENVIRONMENT=staging` makes the migration record `deploy.environment = staging` in `sys.setting`: the gate
runner files its evidence as staging only then, and the volume generator refuses to run on a database marked
`production`. After every restart of the primary, run `pgbackrest --stanza=masslak check` (RUNBOOKS.md section 2).

## Production-size data

The generator clones the seeded bookings into history, so every row obeys the schema's rules:

- **Bookings:** each comes with its passenger and ticket.
- **Payments:** each booking is paid as balanced ledger transactions, from the passenger's wallet after a sandbox top-up,
  or by card through the gateway clearing wallet.
- **Positions:** 16 hours a day for the last 7 days, in the daily partitions.
- **Events:** delivered outbox events.

It ends by setting wallet balances from the ledger and refreshing statistics. It fails unless wallets reconcile, every
transaction balances, every booking is paid and no reference points to a missing row.

| Scale | Command | Use |
|---|---|---|
| 1x (expected first year) | `--months 12 --bookings-per-day 3000 --vehicles 300 --position-seconds 15` | Baseline, migrations on a realistic size |
| 2x | `--bookings-per-day 6000 --vehicles 600` | Growth margin |
| 5x | `--bookings-per-day 15000 --vehicles 1500` | Peak season and headroom |

Agree the 1x figures with the owner before the run if the business plan has changed.

```sh
python3 db/tools/generate_volume.py masslak --months 12 --bookings-per-day 3000 --vehicles 300 --position-seconds 15 -h <db> -U postgres
```

## What staging must produce (one JSON file each, into docs/operations/evidence)

Each row is one command of `db/tools/gate_run.py`, which writes the file itself; the commands with their options
are in [GATE_CLOSURE_PLAN.md](GATE_CLOSURE_PLAN.md), section 4.

| Gate | Command | Pass criterion |
|---|---|---|
| Capacity at 1x, 2x, 5x | `python -m loadtest.run --base https://<staging> --levels 50,100,200 --mix full --owner-dsn ... --json load_<scale>.json` | The SLOs hold at 1x and 2x (booking p95 ≤ 0.8 s, p99 ≤ 1.5 s, 5xx < 0.1 %); 0 deadlocks; 0 wallet mismatches; no trigger over 1 ms per row (`trigger_ms_per_call`). At 5x, the limit and the first resource to saturate are recorded |
| Recovery | `pgbackrest restore` to a new host with `--type=time`, then the checks of `db/tools/restore_drill.py` | Data lost ≤ 60 s; usable in ≤ 30 min; wallets, ledger, orphans, audit seals and schema hash all pass |
| Failover | Promote `db-replica` while the load test runs | The API recovers without manual data repair; time recorded |
| Migrations | `db/tools/migration_rehearsal.py --base <previous release>` against the 1x copy | Within the stop criteria of `docs/database/MIGRATION_PLANS.md` |
| Monitoring | Fire a test alert; stop the API; fill the outbox | Each page arrives on the on-call channel; time to acknowledge recorded |
| File scanning | Upload a clean file and the EICAR test file; stream EICAR to clamd directly | Clean file accepted after a ClamAV scan; EICAR rejected, and named by ClamAV; nothing stays pending over 15 min |

**For the ten-million figure:** `CAPACITY_MODEL.md` section 7 lists the database-tier rates staging also runs
(2,250 write transactions a second, 2,000 positions a second, 1,250 events a second).

## Checked before handover

The overlay was brought up and checked on the development host on 7 October 2026. Results are in
`evidence/staging_kit_check_2026-10-07.json`:

- **Database:** the standby streamed from the primary, and WAL segments were archived (6 archived, 0 failed). That
  standby has since become the `db-replica` service of the production stack, and was checked again on 8 October
  2026 (see `ARCHITECTURE_REVIEW_RESPONSE.md`).
- **Monitoring:** Prometheus loaded the 24 rules and found Alertmanager. Alertmanager's configuration passed `amtool`.
  Grafana provisioned the data source and the dashboard.
- **File scanning:** ClamAV detected the EICAR test file through the API's scanner.
- **Data:** the generator produced 30,034 bookings and 403,204 positions in 15 s, with zero mismatches, unbalanced
  transactions, unpaid bookings or orphans.

**Limits of that check:**
- pgBackRest itself could not be installed in the development sandbox then, so a stand-in archived the WAL. On
  9 October 2026 the recovery gate was rehearsed with pgBackRest 2.50 itself (encrypted repository, restore onto a
  second server), and file scanning with ClamAV and the API (`GATE_CLOSURE_PLAN.md`, section 2). The staging runs
  remain the evidence.
- The API was not part of the 7 October check.
