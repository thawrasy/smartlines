# Closing the launch gates before the pilot

Plan of 9 October 2026. The pilot (releases 1A and 1B in selected cities, `INFRASTRUCTURE_REQUIREMENTS.md`) starts once
the eight launch gates of [LAUNCH_GATES.md](LAUNCH_GATES.md) are passed on staging (gate 2 and gate 6: production).
Gate 9 (AI and contact centre) stays not applicable while that phase is closed.

By the register's own rule a gate passes only on evidence from staging or production, signed by its approver. The
development team cannot pass a gate; it can make each gate one command, rehearse it, and fix what the rehearsals find.
That is done (section 2). What remains needs servers, contracts and people (section 3).

## 1. Where each gate stands

| # | Gate | Tool ready | Rehearsed here (development) | What closes it | Who runs / approves |
|---|---|---|---|---|---|
| 1 | Recovery | `gate_run.py recovery` | Passed with real pgBackRest: 25.5 s of writes lost, usable after 7.3 s, every check passed | the same on staging, from the staging repository to a new host | staging firm / platform owner and DBA |
| 2 | Egress | `gate_run.py egress` | in CI on every push (the compose stack) | run on production with the real allowlist | operations lead / security lead |
| 3 | Capacity | `gate_run.py capacity` | burst at 240/s and a soak, development host (stage B) | 1x, 2x passing and 5x recorded, and an 8-hour soak, on staging hardware | staging firm / operations lead |
| 4 | Migrations | `gate_run.py migrations` | Upgrade from 1055 to 1066 under traffic with 200,000 rows a table: 6.9 s, longest exclusive lock 0.19 s, traffic p99 8.1 ms, no errors. The first run found the 1063 regression (section 2) | the same on staging at production size | staging firm / DBA |
| 5 | Monitoring | `gate_run.py alert` | API stopped: `DatabaseDown` fired after its 2-minute hold, acknowledged with a silence naming the runbook, cleared once the API was back. Acknowledged by the person rehearsing, so it proves the tooling, not the rota | a real on-call engineer acknowledges within 15 minutes and follows the runbook | operations lead / platform owner |
| 6 | Audit archive | `gate_run.py audit-archive` | export, signatures and chain verified; no bucket here | the bucket with object lock in a separate account, a past export retrieved and verified, the custodian's receipt | security lead / platform owner |
| 7 | File scanning | `gate_run.py file-scanning` | Passed with a real ClamAV: clean file scanned by ClamAV and served, EICAR refused by the API and named by ClamAV, a file uploaded while ClamAV was down held and released 48 s after it came back | the same on staging with ClamAV's own signatures | staging firm / security lead |
| 8 | Security testing | template (`launch_gates.py template 8`) | — | the external firm's report and retest; every critical and high finding fixed or accepted in writing | external firm / security lead and owner |

Every run writes its evidence into `docs/operations/evidence/`, under the environment the database itself declares
(`MASSLAK_ENVIRONMENT`, recorded by the migration as `deploy.environment`), with the release and commit measured.
`python3 db/tools/launch_gates.py check` judges the files; a development file can never pass a gate.

## 2. Rehearsals and what they found

Run on 9 October 2026 against release 1.44.0 and, for gate 4, the fix that followed (1.45.0); the files are
development evidence.

- **Gate 1:** primary with pgBackRest 2.50 (encrypted repository, `archive_timeout` 60 s), killed without warning
  while writing 10 rows a second, restored with `pgbackrest restore` onto a second server. 1,211 of 1,455
  acknowledged rows were kept: 25.5 s of writes lost (target 60 s), usable 7.3 s after the loss (target 30 min);
  wallets, ledger, orphans, audit seals and schema hash all checked.
- **Gate 7:** API with `MASSLAK_CLAMD` set, the worker running, ClamAV 1.5 with a test signature (the signature
  download is not reachable from this sandbox; staging uses ClamAV's own). Every check passed. The API refuses the
  EICAR file with its own checks before ClamAV is asked, so the runner also streams EICAR to clamd directly and
  requires ClamAV to name it, and requires the clean file to have been scanned by ClamAV.
- **Gate 5:** Prometheus scraping the API, Alertmanager, the `DatabaseDown` rule as shipped. The API was stopped; the
  alert fired 2 min 11 s later (the rule holds for 2 minutes before paging), was acknowledged with an Alertmanager
  silence whose comment names the runbook sections followed, and cleared after the API was started again.
- **Gate 4:** a copy built up to 1055 (the last release before stage C), 200,000 rows in each table the newer files
  touch, upgraded to 1066 while writers and readers ran. First run: 96 errors, the third defect below. After the fix:
  6.9 s, 4.8 MB of WAL, the longest exclusive lock 0.19 s (limit 2 s), traffic p99 8.1 ms during the upgrade (limit
  1 s), no errors before, during or after.
- **Gate 3:** the runner drives the burst and soak tools of stage B, whose development runs are in
  `evidence/burst_dev_2026-10-08.json` and `soak_dev_2026-10-08.json`; section 6 has the runner's own short run,
  which fails here as expected (one API process on a 4-vCPU host) and keeps every correctness check.
- **Gate 6:** the export, its signatures and the hash chain verify. The bucket steps need the real bucket.

**Defects found and fixed:**
- **Files could stay in quarantine for good after a ClamAV outage (gate 7).** Each retry during an outage used up one
  of the file's five scan attempts, so a file uploaded during an outage longer than about five minutes was never
  scanned again, even after ClamAV returned. An outage now uses no attempt; only a file that makes the scan itself
  fail does (`scanner.py`, `test_scanner_outage.py`).
- **After a crash restart, WAL was not archived for several minutes (gate 1).** PostgreSQL's checkpointer, started
  during crash recovery, did not apply `archive_timeout` until its first long sleep ended, so the RPO window grew to
  that sleep. The runbook now makes `pgbackrest check` (which forces a WAL switch) the first step after any restart
  of the primary, and the drill warms up for longer than `archive_timeout` so it measures the real window
  (`gate_run.py` reports a lower bound otherwise).
- **A position without a vehicle was refused (gate 4, a regression of 1063 in release 1.44.0).** The rehearsal's
  traffic writes positions while the migration runs; on a schema-only copy there is no vehicle, and every such insert
  failed with "record prev is not assigned yet" once 1063 was applied. In the API a trip that is neither draft nor
  cancelled always has a vehicle (check on `ops.trip`), so only positions on draft or cancelled trips were affected,
  but the insert must not fail. Fixed by `1066_position_without_vehicle.sql` (release 1.45.0) with a database check;
  the rehearsal now gives its copy one vehicle so its positions look like the API's, and the case without a vehicle
  stays in the database suite. **Release 1.44.0 should not be installed; use 1.45.0.**

## 3. What is needed to close them

**From the owner, before staging can start:**
1. **The staging firm's contract** (owner decision of 8 October 2026: an external firm runs staging and the
   penetration test), with the names of its operators.
2. **Staging servers** as in `INFRASTRUCTURE_REQUIREMENTS.md` section 4.2: primary and standby database (16 vCPU,
   128 GB, raised to 32 vCPU for the 5x test), two application servers, monitoring, a load generator outside the
   network, 2 TB of object storage. Rented by the hour; about two to three weeks.
3. **An on-call rota of at least three engineers** (`STAFFING.md`) and the channel the pages go to (the receiver
   URLs for Alertmanager, `deploy/staging/init-secrets.sh`).
4. **The audit archive bucket**: S3 Object Lock in compliance mode, in a cloud account separate from production, and a
   **custodian** outside the platform team who records the chain tips.
5. **The production allowlist**: the SMS sender, the mail server and, when contracted, the payment providers
   (the pilot runs on cash, so possibly none).
6. **The penetration test firm** (scope: `docs/security/PENETRATION_TEST_SCOPE.md`).
7. **Approvers** for each gate (platform owner, security lead, operations lead, DBA).

**Sequence (about three weeks once the above exist):**

| When | Work | Gates |
|---|---|---|
| Day 1 | Staging up (`STAGING.md`), `MASSLAK_ENVIRONMENT=staging`, first full pgBackRest backup, 1x volume | — |
| Days 2–3 | File scanning; recovery to a new host; migration rehearsal on the 1x copy; alert drill with the on-call engineer | 7, 1, 4, 5 |
| Days 4–8 | Burst at 1x, 2x and 5x (the 5x run on the larger database server); 8 to 24 hours of soak; fixes and re-runs | 3 |
| Weeks 1–3, in parallel | Penetration test, fixes, retest | 8 |
| Before the first passenger | On production: egress with the real allowlist; first audit export to the locked bucket, a past export retrieved, the custodian's receipt | 2, 6 |
| Go/no-go | `launch_gates.py check` shows gates 1–8 passed; approvers sign the register; the owner decides | — |

## 4. Commands for the operators

Run from a checkout of the release on the operator's host, with `pip install -r backend/requirements.txt`.
`<owner-dsn>` is the database owner's connection to the environment being measured.

```sh
# Gate 1: kill the primary, restore on a new host from the pgBackRest repository, measure
python3 db/tools/gate_run.py --operator "<name, firm>" recovery --primary <owner-dsn of the primary> \
  --restored <owner-dsn of the new host> --kill "ssh db-a1 sudo systemctl kill -s KILL postgresql@16-main" \
  --restore "ssh db-new sudo /usr/local/bin/masslak-restore-latest"        # pgbackrest restore + start, RUNBOOKS.md 2
# Gate 2 (production)
python3 db/tools/gate_run.py egress --owner-dsn <dsn> --worker-exec "docker compose --env-file deploy/.env exec -T worker" \
  --api-exec "docker compose --env-file deploy/.env exec -T app" --allowed <an allowlisted provider name>
# Gate 3
python3 db/tools/gate_run.py capacity --owner-dsn <dsn> --base https://<staging> --levels 1x,2x,5x --soak-hours 8
# Gate 4: base = the last schema file of the release production runs now
python3 db/tools/gate_run.py migrations --owner-dsn <dsn> --base <prefix> -- -h <db host> -U postgres
# Gate 5: the on-call engineer acknowledges with an Alertmanager silence whose comment names the runbook section
python3 db/tools/gate_run.py alert --owner-dsn <dsn> --alertmanager http://<alertmanager>:9093 --alert DatabaseDown \
  --trigger "docker compose --env-file deploy/.env stop app" --restore "docker compose --env-file deploy/.env start app"
# Gate 6 (production): MASSLAK_AUDIT_DATABASE_URL and MASSLAK_AUDIT_SIGNING_KEY set for the export
python3 db/tools/gate_run.py audit-archive --owner-dsn <dsn> --dir /var/lib/masslak/audit-archive \
  --public-key public.pem --bucket s3://<locked bucket>/audit --custodian-receipt "<where the tip was recorded>"
# Gate 7
python3 db/tools/gate_run.py file-scanning --owner-dsn <dsn> --base https://<staging> --email <carrier staff> --password <...> \
  --clamd-check "docker compose ... exec -T clamav clamdscan --no-summary -" \
  --stop-scanner "docker compose ... stop clamav" --start-scanner "docker compose ... start clamav"
# Then
python3 db/tools/launch_gates.py check
```

## 5. Decision record

| Item | Record |
|---|---|
| Inputs of section 3 provided | (date per item) |
| Gates 1–8 passed on staging / production | (date, approver per gate, in LAUNCH_GATES.md) |
| Go / no-go for the pilot | (decision, date, signatures) |

## 6. Rehearsal log

All on 9 October 2026, development host (4 vCPU), `gate_run.py` with `--evidence` pointed at a scratch directory:
development files cannot pass a gate, so they stay out of `evidence/` and the register is not changed by them.

| Gate | Run | Result | What it showed |
|---|---|---|---|
| 1 | 1 | FAIL (lower bound) | Warm-up of 45 s, shorter than `archive_timeout`: nothing had been archived yet, so the RPO measured was only a lower bound. The runner now fails such a run and warms up for 150 s by default |
| 1 | 2 | FAIL | Run straight after a crash restart: no WAL archived for minutes (section 2, second defect) |
| 1 | 3 | PASS | 25.5 s of writes lost, usable after 7.3 s, every integrity check passed |
| 7 | 1 | PASS (criteria then) | Clean file served through ClamAV; EICAR refused; a file uploaded with ClamAV stopped held, then released 42 s after it came back. EICAR was refused by the API's own checks, which find it anywhere in a file, so ClamAV never saw it: the runner now also asks ClamAV directly |
| 7 | 2 | PASS | The same, plus ClamAV itself naming the EICAR file (`--clamd-check`) and the clean file's scan recorded as `builtin+clamav`; the held file released 48 s after ClamAV came back |
| 6 | 1 | export verified, bucket missing | Export, signature and chain verified; no locked bucket, retrieval or custodian here |
| 5 | 1 | criteria met, not by an on-call engineer | `DatabaseDown` fired 2 min 11 s after the API stopped, acknowledged 5 s later through a silence naming the runbook, resolved after the restart |
| 4 | 1 | FAIL | 96 errors while upgrading 1055 to 1065, all "record prev is not assigned yet" (section 2, third defect) |
| 4 | 2 | FAIL | With 1066 the errors stopped once 1066 was applied but still occurred between 1063 and 1066: the copy had no vehicle, so every position lacked one |
| 4 | 3 | PASS | The copy given one vehicle, as the API's positions have: 1055 to 1066 in 6.9 s, longest exclusive lock 0.19 s, p99 8.1 ms, no errors |
| 3 | 1 (1x, 30 s) | FAIL, as expected here | One API process on the 4-vCPU host reached 200 arrivals a second and 5.4 bookings a second with p95 above 17 s, the limit already measured in stage B. Correctness held under the overload: no seat sold twice, 211 ledger transactions all balanced, 1,787 wallets reconciled, no deadlock, no failed request. It proves the runner, not the capacity: that needs staging hardware |
