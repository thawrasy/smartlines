# Expert review of October 2026: stage A

In October 2026, three outside reviewers assessed release 1.37.0: an operational review, a technical audit and an
architecture assessment. Each finding was checked against the code and a database built from the release. Stage A
covers the findings that are defects in the code or the deployment scripts: small, local, and needed before any pilot
with real data. Stages B to D cover the launch gates, scale and growth (section 3).

## 1. What changed

| # | Finding (confirmed) | Change | Where | Tests |
|---|---|---|---|---|
| A1 | A server installed by hand could run with the public default signing secret, or an empty one from a copied `.env.example`. The offline ticket key then fell back to a key derived from it, so QR codes, links and ticket credentials could be forged | Outside the sandbox the API and the worker refuse to start when the signing secret is missing, a placeholder, shorter than 32 bytes or not random, or when `MASSLAK_TICKET_SIGNING_KEY` is missing or not 32 bytes of base64. The ticket key has no derived fallback outside the sandbox | `backend/app/security.py` (`require_keys_in_production`), `main.py`, `modules/notify/worker.py` | `test_signing_key_rules`, `test_production_refuses_to_start_with_weak_keys` |
| A2 | The wallet top-up looked up its idempotency key without the payer, so a replay could report another payer's payment status | The lookup is scoped to the payer. Another payer's key ends in `409 ALREADY_EXISTS` and reveals nothing about that payment | `backend/app/routers/wallet.py` | `test_topup_replay_is_scoped_to_the_payer` |
| A3 | `deploy/update.sh` ignored a failed `git pull` (`\|\| true`) and rebuilt whatever was on disk | The code is settled before the backup and the rebuild. The script stops on a failed fetch or pull, a branch that diverged or has local commits, edited tracked files, or a commit other than the approved one (`--sha`, at least 12 characters). It waits for `/api/ready` and records the deployed commit in `deploy/DEPLOYED` | `deploy/update.sh` | `test_update_stops_on_an_unapproved_or_unsettled_checkout` |
| A4 | Backups were encrypted only when `MASSLAK_BACKUP_AGE_RECIPIENT` was set | A production server (`MASSLAK_SANDBOX=false`) refuses to write a backup without an age public key. `install.sh` and `init-env.sh` take `--backup-recipient` | `deploy/backup.sh`, `install.sh`, `init-env.sh`, `.env.example` | `test_backup_refuses_plain_files_on_a_production_server` |
| A5 | A schema file changed after it was applied gave only a warning | `db/upgrade.sh` checks every applied file before applying anything. On a mismatch it stops with exit code 3 and names the files. `MASSLAK_SCHEMA_DRIFT=warn` is for development databases only | `db/upgrade.sh` | CI database job: an edited file stops the upgrade; the override lets it through |
| A6 | `/api/health` answered `ok` without checking anything | `GET /api/ready` checks the database through the application pool, that every schema file shipped with the code is applied, the audit connection and the reports replica. It answers 200 or 503, names only the checks, and caches its answer for 2 s. `/api/health` stays the liveness check | `backend/app/readiness.py`, `routers/public.py`, `db/schema_file.sql` (read grant) | `test_readiness_checks_the_database_and_the_schema`, `test_readiness_fails_while_the_code_is_newer_than_the_schema`, database check "Readiness ...", CI stack job |
| A7 | Only the client pool had a time limit (30 s); the server kept running abandoned statements, and nothing bounded lock waits or idle transactions | The API and audit logins carry `statement_timeout` 30 s, `lock_timeout` 5 s and `idle_in_transaction_session_timeout` 2 min. The reports pool on the replica sets its own 120 s. A request that hits a limit answers `503 SERVICE_BUSY` with `Retry-After: 2` | `db/create_login_roles.sql`, `backend/app/db.py`, `errors.py`, locale files | `test_application_roles_have_time_limits`, `test_a_lock_held_too_long_answers_service_busy`, `test_database_time_limits_map_to_service_busy` |
| A8 | `db/README.md` stated 445 tables, 4,557 columns and 23 schemas; the database has 483, 4,975 and 26 | `db/tools/gen_docs.py` writes the figures table of the README (schemas, tables, partitioned tables, columns, foreign keys, row-level security, policies, triggers, functions, test checks) next to the data dictionary and the ERD. `--check` fails when any of them is out of date | `db/tools/gen_docs.py`, `db/README.md` | CI database job runs `gen_docs.py --check` |

## 2. On an existing server

1. Put an age public key in `MASSLAK_BACKUP_AGE_RECIPIENT` in `deploy/.env` before the next update. Without one,
   the nightly backup and `update.sh` (which backs up first) stop on a production server.
2. Check that `MASSLAK_SIGNING_SECRET` and `MASSLAK_TICKET_SIGNING_KEY` are set. Servers installed with
   `install.sh` or `init-env.sh` already have both. Never replace them on a live server: that invalidates every ticket
   already issued.
3. Update with the approved commit: `sudo ./deploy/update.sh --sha <commit id>`.
4. Point monitoring and any load balancer at `/api/ready`.

## 3. What comes after stage A

Stage B is done as far as code and tooling go; see [REVIEW_STAGE_B.md](REVIEW_STAGE_B.md). Stage C is done as well;
see [REVIEW_STAGE_C.md](REVIEW_STAGE_C.md).

- **Stage B, before general launch:**
  - the nine launch gates of [LAUNCH_GATES.md](LAUNCH_GATES.md);
  - a booking burst test at 240 per second;
  - a soak test of 8 to 24 hours;
  - replica lag thresholds;
  - an ageing report of the cash carriers owe;
  - SSRF and DNS rebinding tests.
- **Stage C, one to three months:**
  - narrower grants for the application role;
  - governance of the `system_scope` uses;
  - a release manifest (the reports' fixed `source_version` included);
  - a CI rule for deferred balances;
  - an owner for every invariant;
  - pinned, signed images with an SBOM;
  - trigger cost metrics;
  - the new payment options in the mobile app.
- **Stage D, three to six months:**
  - per-market time zone and currency;
  - a telemetry cluster;
  - a warehouse fed by change data capture;
  - a company-based sharding study;
  - partitioned bookings;
  - automatic failover and a second site.
