# Response to the reviews of October 2026 (release 1.49.0)

Two reviews of release 1.48.0 were assessed against the code. The first is a technical and operational review with
26 findings (C-01 to M-14). The second is a security and architecture review in 17 topics. The assessment found:

* 21 findings confirmed;
* 4 partly accurate (the defect is real but narrower than described, or described in the wrong place);
* 1 already fixed (M-10);
* 3 further issues found while checking (additions 1 to 3).

The work is in three packages. This page records each finding, what changed, the test that proves the change, and
what remains open.

Status values: **fixed** (in this release, with its test; packages 1, 2 and 3), **outside code** (needs staging or a
third party; these are the open launch gates).

## 1. Package 1: what was fixed

| Ref | Finding | What changed | Proof |
|---|---|---|---|
| C-01 | The isolation context could be forged. `sys.set_context` wrote whatever company and scope it received, and the policies read settings any connection can change: one `set_config('app.scope', 'PLATFORM', true)` in a statement showed every company's rows | Schema 1080 makes `sys.set_context` verify a ticket: an HMAC-SHA256 of the context and its time, under a key derived from the signing secret, held in `sys.context_key`, which only the owner reads. It refuses a missing ticket, an unknown key, a ticket more than five minutes off, or a ticket made for another context. `set_config` and temporary objects are withdrawn from PUBLIC, so no statement the API runs can rewrite the context or the transaction flags. `/api/ready` reports `context: false` when the database lacks the API's key or the withdrawal was lost | `test_verified_context.py` (3 tests as the API's own login, including the reviewers' reproduction); `db/tests` section 1080 (16 checks); `test_review_stage_a.py` (readiness) |
| C-02 | The telemetry database's writer could drop partitions through `tel.upkeep`, was handed the legal hold as a parameter, and could read every company's positions | The API's login `masslak_tel` may only append, plus `SELECT` on the three columns its conflict clause needs (event id, time, trust). It cannot run `tel.upkeep` or read positions. A separate upkeep login, `masslak_tel_upkeep`, with its own password, is held by the worker only. The hold and a minimum retention (`tel.policy`, 7 days by default) live in the telemetry database, never in a parameter. Without the upkeep login the worker only creates partitions ahead and logs an error | `test_telemetry.py::test_the_api_login_appends_only_and_cannot_destroy_or_read_the_history`, `::test_the_upkeep_follows_the_primary_respects_a_hold_and_never_goes_below_the_floor`, `::test_the_worker_drops_only_through_its_own_login` |
| Addition 3 | The telemetry writer held `SELECT` it did not need | Withdrawn with C-02, except for the three columns above | As C-02 |
| M-06 | Log redaction covered the message and its arguments, but not the text of an exception | A redacting formatter covers exception and stack text in text and JSON logs, and string fields in JSON logs | `test_audit_pipeline.py::test_an_exception_in_a_log_line_is_redacted_too` |
| M-02 | A refresh token was checked and rotated in two transactions, without a conditional update | One transaction locks the session (`FOR UPDATE`) and rotates with `WHERE refresh_hash = <the token presented>`. If the token was rotated less than 20 seconds earlier from the same device, the client gets 409 `REFRESH_RACE` and the session stays. Any other reuse revokes the session (`REFRESH_REUSE`) | `test_mobile.py::test_two_refreshes_racing_with_one_token_rotate_it_once`, `::test_refresh_rotates_and_detects_a_stolen_refresh_token` |
| M-01 | The return address after a payment was built from the Host header the client sent | `public_base()` returns the configured `MASSLAK_PUBLIC_URL`; only a sandbox server keeps its own address. Payments and bookings use it | `test_review_oct_2026.py::test_the_return_address_is_the_platforms_not_the_host_header` |
| M-05 | The generic resource engine returned every non-binary column | Every view drops columns whose names mark a credential (`SECRET_COLUMN`: encrypted, blind index, secret, password, token, OTP, TOTP, recovery codes, API or private key, wrapped key, nonce, PIN), whatever columns a table gains later. A resource may also name the columns it shows (`Resource.detail`) | `test_review_oct_2026.py::test_no_record_view_returns_a_credential` checks every resource against the live schema |
| M-12 | The sandbox payment simulator worked without a session; the payment's id was enough to confirm it | The simulator needs a signed-in user who is the payer or the paying agency; anyone else gets 404 | `test_review_oct_2026.py::test_only_the_payer_opens_the_sandbox_simulator` |
| Addition 1, M-09 | Nineteen SECURITY DEFINER functions searched temporary objects first. `audit.tg_capture_change` read `pg_class` by its bare name. Creating objects in `public` was not withdrawn explicitly | Schema 1081 ends every SECURITY DEFINER function's `search_path` with `pg_temp`, withdraws `CREATE` on `public`, and adds `sys.definer_path_gaps()`, which must stay empty. 1080 already withdrew temporary objects from the application | `db/tests` section 1081 |

### What remains of C-01

The ticket closes the path the reviewers showed: SQL that runs inside the API's own statements. One path remains. A
person who holds the API login's password, and can reach the database, could type `SET app.scope = ...` as a
statement of their own. PostgreSQL lets every login set custom settings, and only a server extension can forbid
that.

Package 2 narrows this path from the network side:

* in the production profile the database accepts the API's login only over TLS, with scram, from the container
  network it is attached to;
* the password reaches only the containers that use it, never the whole `deploy/.env` (H-05, H-06).

What still remains is a person who holds the password and runs code inside that network. Hosts of their own for the
database (H-01, package 3) narrow it further. RUNBOOKS.md, section 30, describes this limit.

### Cost

Checking the ticket adds about 55 µs to each transaction, measured on the development server.

### Upgrading a server to 1.49.0

* `deploy/migrate.sh` writes the context key on every start, deriving it from `MASSLAK_SIGNING_SECRET` with
  `python -m app.tools.context_key`. The migration and the API must use the same `deploy/.env`.
* The withdrawal of `set_config` and temporary objects needs a superuser. The migration runs as one, and says it
  again on every start (`db/create_login_roles.sql`), because a database that `deploy/restore.sh` creates anew has
  PostgreSQL's defaults back. The warehouse login keeps `set_config`, which logical replication calls when it
  connects (RUNBOOKS.md, section 30).
* A server with the telemetry database must set `MASSLAK_TELEMETRY_UPKEEP_PASSWORD` in `deploy/.env` (the overlay
  refuses to start without it).
* Requests that a 1.48.0 process serves between the migration and its restart are refused. A server that must not
  refuse them opens a short window before the update (docs/database/MIGRATION_PLANS.md, release 1.49.0).
* Rolling back to 1.48.0 needs a window for contexts without a ticket, opened by a superuser for at most a day, with a
  reason (`sys.context_unsigned_window`). While it is open, `/api/ready` of a 1.49.0 server reports not ready.
* The API's and the audit login's `jit` setting is off. The asyncpg driver set it per connection through
  `set_config`, which is now withdrawn.

## 2. Package 2: a production profile that refuses an incomplete setup

A production server now installs and updates only in the production profile (`deploy/production`,
docs/operations/PRODUCTION_PROFILE.md). Each part is checked before the server changes anything:

* the host preflight checks what `deploy/.env` declares;
* the migration's preflight checks the database itself, before any schema change;
* the API and the worker check their own environment and connections when they start.

The CI job **Production installation** first shows an incomplete setup refused. It then installs the profile against
stand-ins for the key service, object storage and the alert receivers (`deploy/production/ci`), and checks each item
on the running stack.

| Ref | Finding | What changed | Proof |
|---|---|---|---|
| H-02 | WAL archiving off in the standard command; the check passed when it was off; the update only warned | The production database image archives every WAL segment with pgBackRest, every minute at least. Before any migration, the preflight runs pgBackRest's own check from inside the database container (through `COPY ... FROM PROGRAM`), which archives a segment now. It refuses a repository on this host (it must be object storage, sftp or a repository host), archiving off, or another archive command. After an update, an archive that does not work fails the update | `test_production_profile.py` (each gap named); CI: installation (`production preflight passed`), `check-archive.sh`, a full pgBackRest backup into the repository, encrypted |
| H-03 | The update accepted a backup kept on the server only | On a production server the update stops, before anything changes, when the backup was not copied off the server. Elsewhere it stays a warning | CI: an update with an unreachable off-site destination is refused and the running version keeps serving; a complete update then goes through |
| H-05 | PostgreSQL connections were not required to use TLS | An internal certificate authority (`deploy/production/init.sh`) issues the certificates. The database, its replica and PgBouncer serve TLS 1.3 only. `pg_hba.conf` is written at each start and accepts nothing on the network but `hostssl` with scram, from the container network. Every client checks the certificate (`sslmode=verify-full`): the API, PgBouncer, the replica's stream, the migration and the exporter. The API and the worker refuse to start with a connection that does not | CI: no unencrypted network connection, the replica streams over TLS, a plain connection is refused, a client that does not check the name is refused by its own check; `test_production_profile.py` |
| H-06 | `deploy/.env`, with every secret, went whole to migrate, app and worker; the key service was optional | `deploy/env-split.sh` writes one environment file per container: the API and the worker never receive the owner's, replication, warehouse, backup or pgBackRest secrets, nor, in production, any data key. The key service is required in production: the first migration wraps every data key with Vault (`python -m app.tools.keys bootstrap`), adopting keys `deploy/.env` still gives, and the API opens them at start. Vault is reached through the egress proxy, which lets through exactly its host and port. The API and the worker refuse to start with an owner secret, a raw key or no key service in their environment | `test_production_profile.py` (env split, adoption against the database, a sealed key never replaced, start refused); CI: keys wrapped (`kms_key_id`), the API's environment clean, start refused three ways, the proxy allows Vault's port only, two-factor enrolment encrypted and read again by a new process |
| H-07 | Monitoring, alerting and virus scanning ran on staging only; the second site was not scraped | The profile runs Prometheus with the alert rules, Alertmanager, node_exporter, the PgBouncer exporter, Grafana (local address only) and ClamAV. The second site's node_exporter is scraped when declared (`MASSLAK_SITE_B_METRICS`). The install refuses placeholder alert receivers. `deploy/monitoring/alert-drill.sh` sends a synthetic page and checks that the page receiver accepted it, from Alertmanager's request counters per receiver (the first version, found weak in CI, counted attempts of every receiver, so the minute heartbeat could pass for the page). New alerts: `ScrapeTargetDown`, `SiteBWatchdogMissing`, `DiskSpaceLow`, `MemoryLow`; staging gets node_exporter too | CI: the drill reaches the receiver (`/page`), every target is up; promtool tests |
| Addition 2 | No `absent()` rule: a vital metric that stopped arriving silenced its alert | `MetricsMissing` watches 48 metrics the alerts rest on and names the one missing; Alertmanager holds it back while `DatabaseDown` explains it | promtool test (one metric missing names it); CI: no metric missing on the installed stack. On its first run in CI the rule found a real gap: the upkeep's age carried a label named `job`, which Prometheus renames on every scrape, so `MaintenanceStale` could never fire. The API now publishes it as `task` (`masslak_job_last_success_age_seconds{task="maintenance"}`), and a promtool test checks the alert on the series as a scrape stores it |
| H-09 | 1046 added the contact constraints NOT VALID and treated a failed validation as a warning | Schema 1082: `db/build.sh` and `db/upgrade.sh` end by validating every NOT VALID constraint, each in its own transaction; one that old rows break stays NOT VALID, is named, and `/api/ready` reports `"constraints": false` until the rows are fixed | `test_review_oct_2026.py::test_a_constraint_left_not_valid_is_validated_or_keeps_the_server_not_ready`; `db/tests` section 1082; CI schema job (the next upgrade validates one) |
| H-10 | The CDC login has REPLICATION and BYPASSRLS | It signs in only from `MASSLAK_WAREHOUSE_ADDRESS`, over TLS, with a client certificate issued to `masslak_cdc`, and is refused anywhere else. The production database image has no decoding plugin but pgoutput (`test_decoding` removed). Password rotation is a runbook step (RUNBOOKS.md, section 31) | CI: the warehouse login refused from the container network, a slot with `test_decoding` refused; `test_production_profile.py` (first matching line followed) |
| M-07 | `MASSLAK_SCHEMA_DRIFT=warn` skipped the drift check with no production guard | `db/upgrade.sh` refuses it (exit 5) when the environment or the database itself declares the server production | CI schema job and production job |

Also found and fixed while testing:

* The database preflight reads `pg_hba.conf` as PostgreSQL does, first matching line first. A generic line placed
  before the warehouse's own lines would let the warehouse in without its certificate, and is named.
* A replica copied before TLS was turned on now streams over TLS from its next start: the connection to the primary
  is given at every start, with the password in a file only postgres reads.

### Upgrading a production server to the profile

PRODUCTION_PROFILE.md, section 4. In short:

1. Prepare the key service, the repository, the off-site copy and the receivers.
2. Run `./deploy/update.sh`. The first run restarts the database with TLS and archiving, then wraps the data keys.
3. Once the API is ready, remove `MASSLAK_FIELD_KEYS` and `MASSLAK_BIDX_KEY` from `deploy/.env`.

## 3. Package 3: availability, supply chain and improvements

The production database now runs on two hosts with automatic failover, and the installer requires it or the owner's
written acceptance of one host. A production server runs only images the release workflow built and signed. Files in
an object store come back to a backup's moment with the database. The CI job **Production with two database hosts**
installs the layout from the bundles on three addresses of one runner and kills the primary under load.

| Ref | Finding | What changed | Proof |
|---|---|---|---|
| H-01 | The standard deployment puts the primary and the replica on one host; the Patroni files were not wired into the installer | `MASSLAK_DB_LAYOUT=ha`: two database hosts under Patroni with a synchronous standby, etcd on both and on the application host, HAProxy on the application host under the names `db` and `db-replica`, so the stack and the operator's scripts are unchanged. `deploy/production/init.sh` issues the cluster's certificate and one bundle per host; `deploy/production/ha/install-db-host.sh` installs a host from its bundle with the signed database image (now carrying Patroni from a hashed lock and HAProxy), schedules the backups on whichever host is the primary, and hands the role over before it restarts a primary. Everything between the members is TLS with the internal authority: replication and rewind (`verify-full`), Patroni's REST API, etcd with client certificates. Zero data loss is applied to the cluster through Patroni's REST API. Both preflights refuse a production server whose database is neither on two hosts with a synchronous standby streaming nor on one host the owner accepted (`MASSLAK_SINGLE_HOST_ACCEPTED`). The second site stays a design with its watchdog, now pointed at the main site's hosts | CI job **Production with two database hosts**: the install refused until both hosts run; TLS everywhere and the synchronous standby checked; a commit waits while the standby is down with zero data loss on; the failover drill (`failover_drill.py`, 20 writes a second, the primary's container killed) asserts no acknowledged write lost, writing back within 60 s and the API ready again (run of `385d7b4`: 895 acknowledged, 0 lost, back in 23.3 s, the API ready again 31 s after the kill); the old primary rejoins by `pg_rewind`; an update of the primary hands the role over first. Locally with the same configuration (native processes): back to writing 25.4 s after the kill, 0 of 298 lost (`evidence/failover_drill_ha_2026-10-10.json`). `test_review_oct_2026_package3.py` (certificate and bundles, refusals, proxies, Patroni settings), `test_production_profile.py` (layout in the preflight) |
| H-04 | With S3 storage the backup did not record object versions | The bucket must keep every version (versioning) and lock them (Object Lock, default retention at least `MASSLAK_BACKUP_KEEP_DAYS`): the migration's preflight refuses otherwise. Each backup records the version and content tag of every file (`python -m app.tools.files_versions manifest`, encrypted with the backup) and fails without it; `deploy/restore.sh` puts those versions back before the file check. Files written after the backup are left to the daily sweep | `test_file_store.py::test_joint_restore_drill_brings_every_file_back_to_the_backups_moment` against SeaweedFS (one file changed, one deleted, one added after the backup; every file of the backup decrypts to its recorded hash), `::test_the_preflight_tells_a_locked_bucket_from_a_plain_one`; `test_production_profile.py` (each gap named) |
| H-08 | The signature covered the source archive; the image was built on the server and its digest was not signed | The release workflow builds the API, egress proxy and database images once, pushes them to the registry, and signs each digest keylessly with its bill of materials (SPDX) and build provenance. `IMAGES`, inside the signed release archive, names them by digest. A production install or update verifies each signature and bill of materials (`deploy/images.sh`, cosign), pulls by digest and never builds; an unsigned or changed image stops it before anything changes. Every Python package of the API image, transitive ones included, is pinned with its hashes (`backend/requirements.lock`, `pip --require-hashes`), as is Patroni's (`patroni.lock`); pip-audit audits both | CI job **Production installation**: the images built, pushed and signed with a key in a local registry, the install verifies and pulls them (`verified masslak-db`, nothing built), and an update naming a changed, unsigned API image is refused while the signed one keeps serving; `test_review_oct_2026_package3.py` (hashes, digests required, never built) |
| M-03 | Rate limits for public search and partner keys were per process | Public search draws from the shared buckets in PostgreSQL per client address, in the round trip that already reads the address rules; each partner key from its own bucket at its own limit (`sec.rate_take`, 1068). Adding servers never raises a limit | `test_shared_limits.py::test_public_and_partner_requests_draw_from_the_shared_buckets`, `::test_two_processes_share_one_bucket` |
| M-04 | The encrypted file was written before its row and not removed on refusal or rollback | A file written before its row is deleted again when the row's transaction does not commit (`db.on_rollback`). `app.tools.files_sweep` deletes files no row points to after 24 hours; the worker runs it daily; it refuses to delete more than 5 % of the files (at least 100), which would mean the store and the database do not belong together | `test_review_oct_2026_package3.py::test_a_file_whose_transaction_rolls_back_is_deleted_again`, `::test_the_sweep_deletes_only_old_files_no_row_points_to`, `::test_the_sweep_refuses_when_most_files_look_unreferenced`; `test_file_store.py::test_the_object_store_lists_and_deletes_for_the_sweep` |
| M-08 | Rows left the default partition in one transaction | Schema 1083: the daily upkeep moves a late period itself only up to 50,000 rows; a larger one stays readable where it is and the worker moves it with `sys.move_default_period()`, one period per transaction, with a short lock wait. Measured: 200,000 rows in 1.8 s, 1,000,000 in 5.9 s per period | `test_review_oct_2026_package3.py::test_the_worker_moves_a_large_late_period_on_its_own`; `db/tests` section 1083 |
| M-11 | 29 advisories in the mobile app's dependencies | They come from four advisories, each classed in `mobile/advisories.json`: braces, node-forge and uuid in build tooling (Metro, the Expo CLI, config plugins), decode-uri-component at runtime under expo-router's query-string 7 (moderate, device-local, accepted until Expo SDK 58 is the stable SDK; the patched release breaks query-string 7). `scripts/mobile_advisories.py` fails CI on an unclassed high or critical advisory, on a runtime one at high or above without a dated acceptance, on an entry past its review date, and on a build-classed package that a bundle carries, read from the source maps of the three apps' exports | CI job **Mobile apps**; `test_review_oct_2026_package3.py::test_every_mobile_advisory_is_classed_and_build_ones_do_not_ship` |
| M-13 | The password deny list was short | 72,957 passwords of 12 characters or more from public leak lists (SecLists, MIT; source in `backend/app/assets/passwords/README.md`), repeated patterns, keyboard and alphabet runs, the platform's name, and the person's own e-mail, name or mobile number (`PASSWORD_TOO_PERSONAL`, translated on the web and in the app), on all six paths that set a password | `test_review_oct_2026_package3.py` (common and patterned passwords, the list's size, personal details, registration) |
| M-14 | The mobile package had no `type: module`; the apps were not tested on real devices | `"type": "module"` (type check, tests and the three exports pass). `mobile/eas.json` has preview and production profiles for each app; the workflow **Mobile builds** runs them on EAS by hand. `MOBILE_DEVICE_MATRIX.md` names the device rows and twelve cases (install, offline ticket, offline boarding, biometric lock, pinning, sign-out wipe ...) and the launch gates require one passing run per row before the stores | `test_review_oct_2026_package3.py::test_the_mobile_apps_build_on_eas_as_modules_and_ci_checks_their_advisories`; the device runs themselves are outside the code (section 5) |

Also found and fixed while testing:

* Patroni's `/replica?lag=30s` check of the earlier HAProxy design read the lag in bytes, so it never excluded a
  lagging standby; the proxy asks `/replica?lag=16MB`.
* A new etcd cluster settles its version only once all three members have run, and until then Patroni falls back to
  an API etcd 3.5 no longer serves: the first database host waits for the second, which the installer now expects.
* The pinned PostGIS image carries an older libexpat than Alpine's current Python is built against; the database
  image upgrades it, and CI builds that image on its own with its full log.
* After a failover the API stayed not ready although bookings were back: readiness, and the API's start, required the
  reports connection to reach a standby, and with none up `db-replica` sends reports to the primary. With two
  database hosts that is accepted (`db.reports_may_reach_the_primary`); the missing standby pages through
  `NoSynchronousStandby` and `NoFailoverCandidate`.

### Upgrading a production server to package 3

1. Choose the layout. Two database hosts: set `MASSLAK_DB_LAYOUT=ha`, `MASSLAK_DB_HOSTS` and `MASSLAK_DB_WITNESS`, run
   `./deploy/install.sh` (it writes the bundles and stops at the preflight), install each host with its bundle, and
   run it again (HIGH_AVAILABILITY.md, Installing it). One host for now: record the owner's acceptance in
   `MASSLAK_SINGLE_HOST_ACCEPTED`; until either is set, the update is refused.
2. Install cosign and update from the signed release archive, whose `IMAGES` names the images (RUNBOOKS.md, section 19).
3. With documents in an object store: a bucket with versioning and Object Lock (RUNBOOKS.md, section 24).

## 4. Already fixed, or not a defect

| Ref | Finding | Verdict |
|---|---|---|
| M-10 | The architecture document gave 432 tables and 24 schemas | Fixed in 1.48.0. It now gives 26 schemas and 504 tables (files 000 to 1083), as the generated `db/README.md` does |
| M-09 (first half) | SECURITY DEFINER functions use `pg_catalog, public` | Partly accurate: `public` holds only PostGIS and nothing the application can create. The real gap was `pg_temp` (addition 1), fixed in 1081 |
| Report 2: context leaking between requests on reused connections | Not present: the context is local to its transaction, which is right with PgBouncer in transaction mode (`test_integrity_audit.py::test_a_pooled_connection_never_carries_a_company_into_the_next_request`). The real risk in this area was forging the context (C-01), fixed |
| Report 2: the client header is not CSRF protection on its own | Partly accurate: it is not alone. The session cookie is `SameSite=Strict` and `HttpOnly`, and no CORS policy allows other origins. The two exempt paths are authenticated: payment notices by HMAC with a timestamp and replay check, `/api/v1/` by API keys |
| Report 2: password policy called on every path | Partly accurate: the list is short (M-13), but all six paths that set a password call `password_problem` |
| Report 2: architecture numbers | As M-10 |

The other topics of report 2 were confirmed and fall under the items above:

| Topic | Where it is handled |
|---|---|
| Stack | Described accurately |
| Internal TLS | H-05 |
| Argon2id cost under sign-in load | Shared sign-in limits; measured in the capacity test, gate 3 |
| Key lifecycle | A full rotate, restore and retire drill is still to be recorded as evidence |
| Sessions and tokens | M-02 |
| Input validation | Ownership proven in the penetration test, gate 8 |
| SYSTEM scope | Governed by the registry |
| BOLA/IDOR | Isolation tests now; penetration test, gate 8 |
| Modules writing other modules' tables | Ownership documented; no automatic check yet |
| Performance, launch gates, scores | Accurate |

## 5. Outside the code

These need staging or a third party. They are the launch gates that are already open:

* failover and restore drills on staging's own hosts (CI runs the failover drill on the installed layout; staging
  repeats it on real machines and a real network);
* the independent penetration test;
* the capacity test;
* the device matrix on real phones (`MOBILE_DEVICE_MATRIX.md`, which needs the Expo account's token and the devices);
* a live payment provider.

## 6. Test results

| Suite | Package 1 | Package 2 | Package 3 |
|---|---|---|---|
| Database checks (`db/tests/run_tests.sql`) | 508 passed | 509 passed | 512 passed |
| API tests on a new database | 461 passed, 7 skipped | 490 passed, 14 skipped (7 of them the telemetry tests, which CI runs against their own database) | 549 passed, 10 skipped (the telemetry tests left out locally; CI runs them against their own database) |
| Telemetry tests | 7 passed | (CI) | (CI) |
| Alert rules (promtool) | Valid, tests pass | 71 rules valid, tests pass | Unchanged |
| ruff, bandit, pip-audit (the API's lock and Patroni's) | Clean | Clean | Clean |
| Mobile: type check, unit tests, three exports, advisories against their register | (CI) | (CI) | Pass |
| OpenAPI baseline | No breaking change | No breaking change | No breaking change |
| Generated documents, schema dependencies | Up to date | Up to date | Up to date |

Package 2 was also exercised locally on the database containers: TLS only, the replica streaming over TLS, PgBouncer
checking certificates both ways, the warehouse login refused, archiving to object storage over TLS, Vault through a
proxy with its own authority, and the alert drill reaching a receiver. The images themselves are built and run end to
end in the CI job **Production installation**.

Package 3's layout with two database hosts was exercised locally with native processes on the same configuration
(etcd with client certificates, Patroni's REST API over HTTPS, HAProxy as `proxy.sh` writes it): the failover drill,
the rejoin by `pg_rewind`, a commit waiting with zero data loss on, and a switchover with `patronictl`. The installed
layout itself, from the signed images and the bundles, runs in the CI job **Production with two database hosts**.

## 7. Reviews of release 1.49.0 (release 1.50.0)

Four reports on release 1.49.0 were assessed against the code:

* **Report A**, an engineering review with twelve findings (F-01 to F-12). All twelve are accurate.
* **Report B**, a generic assessment template. It names no file, line or behaviour of this platform, so there was
  nothing to check or act on.
* **Report C**, a plan to close `SET app.*` and to prove 240 bookings a second. Its diagnosis of the path that remained
  of C-01 is right. Its fix, a context table written by every transaction, was not taken, for three reasons:
  * it adds a row write, and its WAL, to every request;
  * it cannot work on a read-only standby, which serves the reports;
  * the settings guard below closes the same path at its source, at no cost per request.
  Its load-test plan was taken.
* **Report D**, a security and architecture review. Its top item (P0) is the same `SET app.scope` path. It adds key
  management, secrets on command lines, the rollback window, evidence and unpinned images.

| Ref | Finding | What changed | Proof |
|---|---|---|---|
| C-01, the rest (C, D) | A person holding the API login's password could type `SET app.scope = 'PLATFORM'`: PostgreSQL lets any login set a custom setting nobody defined | **The settings guard.** A server module, `db/guard/masslak_guard.c`, is loaded by every database image of the repository (development, production, staging, the hosts with Patroni). It defines the thirteen settings the database trusts with the superuser context: the request context (`app.*`) and the flags of the ledger, requirement, cargo and migration guards. SET, SET LOCAL, RESET, a value in the connection options and `ALTER ROLE ... SET` are then refused to every login but a superuser. The platform's functions that set them are SECURITY DEFINER, owned by the superuser, so they keep working. Reading costs nothing more, and the guard works on a standby and through PgBouncer. Schema 1084 names the list (`sys.guarded_settings()`), reports whether the server enforces it (`sys.guard_status()`), and moves the rows a transaction created to one guarded setting (`app.new_rows`). The production preflight refuses a server without the guard, `/api/ready` reports `settings_guard`, and the alert `SettingsGuardMissing` pages | `test_settings_guard.py`: the three lists are equal, every custom setting the schema reads is on them, and, as the API's own login, each kind of SET is refused while the platform's functions still set them. `db/tests`: the guard section. CI builds the images and checks the settings' context in the schema, API, production, HA and image jobs; the production job also tries the SET through the driver |
| D | The rollback window for unsigned contexts only made the API "not ready" | The alert `ContextUnsignedWindowOpen` pages at once (`sys.security_metrics()`) | `alerts_test.yml` (promtool) |
| F-01 | The in-memory rate limiter could grow past `max_keys` | The cap is hard: idle buckets go first, then the least recently used. An IPv6 client is counted by its /64, everywhere | `test_ratelimit.py` |
| F-02 | The activity log kept the request path, report delivery tokens included | The log keeps the route template. Before routing (a refusal), identifiers and tokens become `*` | `test_review_v149.py::test_the_activity_log_records_the_route_not_the_path` |
| F-03 | Tokens in URLs reach the edge logs | Caddy hides delivery tokens and `token=` values in its access log and in its own log, where errors carry the URI. The verification link stays a GET, because a phone's camera opens it. Its answer shows no name or contact, only what an inspector compares with the printout | `test_review_v149.py::test_caddy_hides_tokens_in_both_of_its_logs`; the CI deployment job reads Caddy's logs after a request with a token |
| F-04, D | No TLS to the telemetry database | Production runs it with the production database image: TLS 1.3, a certificate for `telemetry`, `hostssl` only. The migration, API and worker check it, and the API refuses a telemetry address that does not | `test_production_profile.py` (telemetry tests); the CI production job's TLS step |
| F-05 | The limiter of signed-in requests is per process | Kept, and documented in `ratelimit.py`. Sign-in, public search, verification and partner limits are shared by every process (M-03); the rest is each process's share of the instance's limit | — |
| F-06 | `style-src 'unsafe-inline'` | Removed from every page. The landing pages allow their one stylesheet by its hash, and their two style attributes became classes | `test_review_v149.py::test_no_page_policy_allows_inline_code`. The CI step `csp-check` opens 75 page views of every portal, in both languages, plus the landing pages, with the policy in force, and fails on any violation the browser reports |
| F-07, F-08, F-10, F-12 | Launch gates open; second site not installed; capacity unproven; audit archive | Outside the code: the launch gates (section 5). For F-12, failed audit writes already page (`AuditWriteFailures`) | `LAUNCH_GATES.md` |
| F-09 | The architecture document still said "Not built" for built modules | The status register was checked against the code and corrected, with the modules it lacked | `ARCHITECTURE.md`, section 2 |
| F-10, C | The burst test could not separate what it measured | It now separates: a warm-up whose requests are not counted; the rate arrivals started against the rate bookings completed; the drain after the schedule; the most arrivals in progress. Arrivals spread over `--trips` trips, the busiest tenth taking 70 %. Accounts are made before the burst and can be reused (`--save-accounts`, `--accounts-file`). The default cancellation share is 1.0 in development and 0.1 elsewhere. The report records the build (commit and images), the database's release and whether its schema matches, the host and the dataset. Gate 3 counts only a burst of ten minutes or more after a warm-up, with build and release recorded. The gate runner defaults to a 300 s warm-up and a 900 s window over 128 trips | `test_review_v149.py` (burst tests); `test_launch_gates_kit.py::test_capacity_needs_1x_and_2x_passing_a_5x_run_and_an_8_hour_soak`. A local run: 30 arrivals at 6 a second, 30 booked, drain 0 s; a second run reused the 30 accounts |
| F-11 | Several API hosts need shared file storage | No change. The installer runs one application host, whose processes share the documents volume. A second application host needs the object store (`MASSLAK_FILES_BACKEND=s3`, `.env.example`) | — |
| A | A wrong `MASSLAK_COOKIE_SECURE` passed unnoticed | A production server refuses to start with it false | `test_production_profile.py::test_a_session_cookie_sent_over_plain_http_stops_the_start` |
| D | One signing secret signed QR codes and document tokens directly | Each has keys of its own, and each token names its key: `Q1.<key id>...` and `D2.<key id>...`. The first key listed signs; every key listed verifies, so a rotation overlaps. Production requires keys of their own (`MASSLAK_QR_KEYS`, `MASSLAK_DOCUMENT_KEYS`, made by `deploy/init-env.sh`). Older tokens: rotating codes signed with the secret are refused; printed documents verify until `MASSLAK_LEGACY_DOCUMENT_TOKENS=refuse` (RUNBOOKS.md, section 31). Identifier hashes and family codes stay under the signing secret, because stored hashes would need recomputing; moving them, and the keys into the key service, is the next step | `test_review_v149.py` (token key tests); `test_production_profile.py` |
| D | `deploy/migrate.sh` passed passwords and the context key as psql arguments, visible in the process list | psql reads them from the environment (`\getenv`) | `test_review_v149.py::test_the_migration_passes_no_secret_on_a_command_line`; every CI job that installs |
| D | No test that old Argon2 parameters are upgraded | A sign-in replaces a hash made with other parameters | `test_review_v149.py` (unit and live) |
| D | The failover evidence showed `promote_exit: null` | The evidence names how the standby was promoted (`promotion`: by the cluster manager or by a command) | `HIGH_AVAILABILITY.md`, Measured |
| D | No evidence for release 1.49.0 itself | `evidence/release_verification_v1.49.0_2026-10-10.json`: the workflow runs, the assets and their checksums, the Sigstore identity, the image digests, and the refusal of a tampered archive | the file |
| D | The warehouse and staging images had no fixed tag | The warehouse's jobs run the release's API image (`MASSLAK_IMAGE_TAG`) and refuse to start without it. Staging builds its database image from the repository, the guard included, tagged with the release when given; every image from outside is pinned by digest | `test_review_v149.py::test_no_overlay_runs_an_image_of_unknown_version` |
| — | The load test's accounts were refused since M-13: their password contained the account's name | A password the policy accepts | the local run above |

### Upgrading a server to 1.50.0

1. Production: add `MASSLAK_QR_KEYS` and `MASSLAK_DOCUMENT_KEYS` to `deploy/.env`, each ending with `,s1`, so the codes
   already issued still verify (RUNBOOKS.md, section 31).
2. Run `./deploy/update.sh`. The database restarts once with the release's image, which loads the guard
   (MIGRATION_PLANS.md, release 1.50.0).
3. `/api/ready` shows `"settings_guard": true`.

### Test results (release 1.50.0)

| Suite | Result |
|---|---|
| Database checks (`db/tests/run_tests.sql`) on a server that loads the guard | 541 passed |
| API tests on a new database, with `MASSLAK_GUARD_REQUIRED=1` | 582 passed, 10 skipped (the telemetry tests, which CI runs against their own database), 1 failed: the readiness test did not list the new `settings_guard` check. Fixed; its file and four others run again: 98 passed |
| Content-Security-Policy in a browser | 75 page views, no violation (locally and in CI) |
| Burst test, locally | PASS at 6 a second with a warm-up; the second run reused the 30 saved accounts |
| Alert rules (promtool) | 73 rules valid, tests pass |
| ruff, bandit (CI configuration), language policy | Clean |
| Generated documents, schema dependencies | Up to date |
| CI on c54224a (run 145) | Every job green: schema, API with the browser checks, deployment, both production installations (one host; two database hosts with the failover drill), images, warehouse, mobile, security |

### Started after the third report on release 1.49.0

The third report's claims were checked against the code (its figures and its snippets are paraphrases; its QR window
was 30 seconds where the code uses 90). Three of its items were started:

| Item | What changed | Proof |
|---|---|---|
| Blocklist and invite codes keyed with the signing secret | Login identifiers (blocklist, sign-in limits, failed-sign-in audit) and family invite codes are keyed with `MASSLAK_LOOKUP_KEYS`. New records use the first key; a lookup matches every listed key, so records stored before (keyed with `s1`, the secret) still match. Production requires a key of its own first. The rotation is in RUNBOOKS.md, section 31 | `test_review_v149.py` (lookup digests, rotation, invite codes, blocked values under any key); `test_production_profile.py` |
| Root detection overstated | Documented as a warning, not proof: the Expo call is experimental; the vendor services that would give a second signal, and their privacy cost, are a decision for the owner | MOBILE_DEVICE_MATRIX.md, limits; integrity.ts comment |
| Ticket threat row said 30 seconds | The row now states the behaviour of the code: a web code is valid about three minutes; a mobile credential is valid until six hours after arrival and works from a screenshot until the first boarding. The window and the identity check at boarding are decisions for the owner | ARCHITECTURE.md, the copied-tickets row |

Found while checking: the country and ASN rules of the security console are stored and listed, but the middleware calls
`sec.ip_decision` with the address and the scope only, so they never match. The fix belongs with the decision on the
access policy by country (not started).

### Decisions recorded (10 October 2026)

| Decision | Status |
|---|---|
| Web ticket code: window stays 90 seconds; boarding also checks a photo of each passenger | Decided; the photo capture, its storage and its check are not built yet |
| Photo: who checks it (driver, boarding staff or carrier office), when it is taken, how long it is kept, notice and consent, whether children and family members are included | Open; needs a privacy review first |
| Mobile ticket credential (valid until six hours after arrival): bound to the device, or checked against the photo at boarding | Open |
| Second signal for root detection (Google Play Integrity, Apple App Attest) | Open: sends device data to the vendor |
| Access by country and network provider: the security console's country and provider rules are stored but never match (`sec.ip_decision` gets no country or provider); the fix waits for the data source | Open: choice of geographic data source and licence |
| Access policy for launch (Syria only): exemptions, use of the phone's location, store listing | Open (seven questions in the scenario file) |
| Currency: pricing inside the platform, rates stored with their effective date (`ref.exchange_rate`), later a source for foreign cards, withdrawals in the currencies the settings enable | Direction agreed; launch currencies and the rate source are open |

### Answers of 10 October 2026 (second round)

| Question | Answer | Consequence |
|---|---|---|
| Who checks the boarding photo | The driver, the station officer or the carrier's office | The photo is shown in the driver app and in the carrier's boarding view |
| When it is taken and where it is kept | Taken by the passenger in the passenger app and stored in the profile; compared at boarding with the physical identity document or passport | Stored encrypted with the files key, as company documents are (`crypto.encrypt_bytes`). Comparison is by a person; automatic face matching is not part of this decision and would need its own decision (biometric data) |
| Mobile ticket | Requested from the passenger at each boarding of a scheduled trip and shown at each security check | The ticket is presented live at each boarding, with the photo |
| Second root signal | Approved | Needs a Google Cloud project linked to the Play Console and an Apple developer team with App Attest; the server verifies the attestation. Not built yet |
| Connection needed in the passenger app | Proposal: see below, for approval | Not built yet |
| Access by country | Bookings from outside Syria come in a later stage; payment through a wallet top-up or through the payment gateways linked to the platform | At launch the booking and payment actions need a Syrian location; the rule for a top-up from abroad is to be confirmed |
| Geographic data | Coordinates from the mobile app now; storage and a map or IP provider later, after agreements | See the proposal below |
| Currency | The platform sets the price at first; later a common price source plus a fixed percentage, set on the platform, for buying and selling foreign currency | `ref.exchange_rate` holds one mid rate per pair with its source and date; no buy or sell margin exists yet, and no pricing reads the table today |

**Proposal for the connection of the passenger app (for approval)**
- Needs a connection at the moment: search, booking, seat hold, payment, wallet top-up, cancellation and refund, changes to the profile or the photo, and sign-in.
- Works without a connection: viewing a ticket already bought, with its photo, kept encrypted on the phone; the wallet shows its last balance as read-only.
- Limit without a connection: after 72 hours offline the app asks for a connection before it shows a ticket, because a cancellation or a change may have happened. Each ticket shows the time of its last check.
- Ticket credential: valid from three hours before departure until one hour after arrival (today: six hours after arrival). A screenshot taken earlier does not work, and the boarding photo is the check that stops a copy.
- Driver app: downloads the trip before departure (tickets, photos, manifest and clock offset), boards without a connection, uploads the scans when online; the trip pack expires at the end of the trip plus six hours.

**Proposal for access by country (for approval)**
- At launch: booking, seat hold, payment and top-up need a Syrian location; viewing an existing ticket is allowed from anywhere (so a traveller abroad can still show it at the border).
- The location check uses the Syria boundary bundled in the mobile app, which needs no contract and no provider; the server's IP check needs a source for IP-to-country data, which the provider contract will give. Until that source exists, the server records the country and does not block.
- Exempt from the rule: the payment gateways' callbacks and the partner API (scopes `PAYMENT_WEBHOOK` and `API`). Staff accounts follow the same rule with a named exception list.
- Android location from a mock provider is refused; the check runs at each sign-in and at each sensitive action.

**Currency, proposal:** the platform keeps one mid rate per pair (`ref.exchange_rate`, as now). Buy and sell margins are settings per currency, applied at the quote, and the rate applied is fixed on the transaction (section 12). No migration is needed for the margins.

### Third round of answers (10 October 2026) and what was built

| Question | Answer | Built |
|---|---|---|
| Boarding photo: retention, who uploads for children and family members, when it is taken | Taken when the profile is created. Family photos are uploaded by the head of the family or by the account's creator. A person already linked to a family account cannot open a new account | Not built: the photo, its storage and its check wait for the retention period, which is still open |
| Passenger app connection | Approved as proposed | Ticket credential issued only from three hours before departure until one hour after arrival (was six hours after arrival); saved tickets shown offline for 72 hours after their last check; "connect to show" otherwise. The driver's trip pack and the read-only wallet are not built yet |
| Access by country | Top-up of the wallet from abroad allowed at launch; the app is visible abroad; bookings from abroad come in a later stage | Not built: the booking block needs the IP-to-country source (contract) |
| Mobile ticket | Bound to the passenger's account, not to a device. The tickets appear when the account is opened; requested at each boarding of a scheduled trip and shown at each security check | Account binding is the existing design (the credential is per ticket, the app shows the account's tickets) |
| Currency at launch | The Syrian pound only, under Syrian regulation. Foreign currencies later, when the state or regulation allows | Not built: pricing stays in the pound |

### Fourth round of answers (11 October 2026) and what was built

| Question | Answer | Built |
|---|---|---|
| Closing an account | Keep the data. Closing only deactivates the account; it is reactivated when the customer registers again with the same details | Built (1085). `POST /api/account/deactivate` with the password; refused while the person has confirmed trips that have not left (`UPCOMING_TRIPS`). Status `DEACTIVATED`, every session ends, nothing is deleted. Signing in says the account is closed; `POST /api/auth/reactivate` with the same details restores it. Tests: `test_review_v149.py::test_a_closed_account_keeps_its_data_and_comes_back_with_the_same_details`. The passenger app's screens for closing and reactivation are not built yet |
| Booking from abroad | Not before there is a site and a contract with payment gateways linked to Syrian bank accounts inside Syria | Not built, by decision. The IP-to-country source is still needed for the block (section 7, third round) |
| Top-up from abroad | Allowed. Withdrawal is in Syrian pounds, so the card is charged the same amount in pounds; the exchange rate is set by the card-issuing bank | Not built: the top-up flow follows the payment gateway contract |

Still open: whether erasure requests stay beside closing. Closing keeps the data; erasure is the person's written request for an irreversible pseudonymisation (1039, `gov.erase_party`). The owner has not decided this yet.
