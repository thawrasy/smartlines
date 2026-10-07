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
| Database with pgBackRest | `deploy/staging/db/` | WAL archived through pgBackRest every 60 s at most (approved RPO 60 s), encrypted repository, `pg_stat_statements`, lock and slow-query logging |
| Streaming standby | service `db-standby` | Hot standby from a replication slot; replica lag is monitored; failover drill (RUNBOOKS section 2) |
| ClamAV | service `clamav` | The file scanner's engine (`MASSLAK_CLAMD=clamav:3310`); without it production files stay pending (fail-closed) |
| Prometheus | service `prometheus` | Scrapes `/api/metrics` with the token, evaluates the 24 rules of `deploy/monitoring/alerts.yml` |
| Alertmanager | `deploy/staging/alertmanager.yml` | Severity `page` to the on-call channel, `ticket` to the team queue |
| Grafana | `deploy/staging/grafana/` | The operations dashboard, provisioned; bound to 127.0.0.1 (reach it through an SSH tunnel) |
| Secrets | `deploy/staging/init-secrets.sh` | Metrics token, Grafana password, receiver URLs as files (never committed); prints the `.env` lines |
| Volume generator | `db/tools/generate_volume.py` | Production-size history that passes the money and reference checks |

## Bring it up

```sh
./deploy/init-env.sh                         # deploy/.env with random secrets; set MASSLAK_SANDBOX=true, MASSLAK_SEED_DEMO=true
./deploy/staging/init-secrets.sh             # add the printed lines to deploy/.env; put the receiver URLs in deploy/staging/secrets
docker compose -f docker-compose.yml -f deploy/staging/docker-compose.staging.yml --env-file deploy/.env up -d --build
docker compose ... exec -u postgres db pgbackrest --stanza=masslak --type=full backup     # first full backup
```

Set `deploy.environment` to `staging` in `sys.setting`: the volume generator refuses to run on a database marked
`production`.

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

| Gate | Command | Pass criterion |
|---|---|---|
| Capacity at 1x, 2x, 5x | `python -m loadtest.run --base https://<staging> --levels 50,100,200 --mix full --owner-dsn ... --json load_<scale>.json` | The SLOs hold at 1x and 2x (booking p95 ≤ 0.8 s, p99 ≤ 1.5 s, 5xx < 0.1 %); 0 deadlocks; 0 wallet mismatches. At 5x, the limit and the first resource to saturate are recorded |
| Recovery | `pgbackrest restore` to a new host with `--type=time`, then the checks of `db/tools/restore_drill.py` | Data lost ≤ 60 s; usable in ≤ 30 min; wallets, ledger, orphans, audit seals and schema hash all pass |
| Failover | Promote `db-standby` while the load test runs | The API recovers without manual data repair; time recorded |
| Migrations | `db/tools/migration_rehearsal.py --base <previous release>` against the 1x copy | Within the stop criteria of `docs/database/MIGRATION_PLANS.md` |
| Monitoring | Fire a test alert; stop the API; fill the outbox | Each page arrives on the on-call channel; time to acknowledge recorded |
| File scanning | Upload a clean file and the EICAR test file | Clean file accepted; EICAR rejected; nothing stays pending over 15 min |

## Checked before handover

The overlay was brought up and checked on the development host on 7 October 2026. Results are in
`evidence/staging_kit_check_2026-10-07.json`:

- **Database:** the standby streamed from the primary, and WAL segments were archived (6 archived, 0 failed).
- **Monitoring:** Prometheus loaded the 24 rules and found Alertmanager. Alertmanager's configuration passed `amtool`.
  Grafana provisioned the data source and the dashboard.
- **File scanning:** ClamAV detected the EICAR test file through the API's scanner.
- **Data:** the generator produced 30,034 bookings and 403,204 positions in 15 s, with zero mismatches, unbalanced
  transactions, unpaid bookings or orphans.

**Limits of that check:**
- pgBackRest itself could not be installed in the development sandbox, so a stand-in archived the WAL. The real
  archive-push, backup and restore are part of the staging recovery gate.
- The API was not part of the check.
