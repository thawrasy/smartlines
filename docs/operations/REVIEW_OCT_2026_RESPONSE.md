# Response to the reviews of October 2026 (release 1.49.0)

Two reviews of release 1.48.0 were assessed against the code. The first is a technical and operational review with
26 findings (C-01 to M-14). The second is a security and architecture review in 17 topics. The assessment found:

* 21 findings confirmed;
* 4 partly accurate (the defect is real but narrower than described, or described in the wrong place);
* 1 already fixed (M-10);
* 3 further issues found while checking (additions 1 to 3).

The work is in three packages. This page records each finding, what changed, the test that proves the change, and
what remains open.

Status values: **fixed** (in this release, with its test; packages 1 and 2), **package 3** (availability, supply
chain, improvements), **outside code** (needs staging or a third party; these are the open launch gates).

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
| H-07 | Monitoring, alerting and virus scanning ran on staging only; the second site was not scraped | The profile runs Prometheus with the alert rules, Alertmanager, node_exporter, the PgBouncer exporter, Grafana (local address only) and ClamAV. The second site's node_exporter is scraped when declared (`MASSLAK_SITE_B_METRICS`). The install refuses placeholder alert receivers. `deploy/monitoring/alert-drill.sh` sends a synthetic page and checks Alertmanager delivered it without failure. New alerts: `ScrapeTargetDown`, `SiteBWatchdogMissing`, `DiskSpaceLow`, `MemoryLow`; staging gets node_exporter too | CI: the drill reaches the receiver (`/page`), every target is up; promtool tests |
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

| Ref | Finding | Verdict | Plan |
|---|---|---|---|
| H-01 | The standard deployment puts the primary and the replica on one host; the Patroni files are not wired into the installer | Confirmed (the recovery time is 30 minutes, not 60 seconds; one minute is the Patroni failover only) | A production layout the installer requires: two synchronous hosts, etcd, HAProxy, second site; a failover drill under load on staging |
| H-04 | With S3 storage the backup does not record object versions | Partly accurate (the joint restore drill exists for local storage) | A bucket version marker in the backup record, Versioning and Object Lock required, a joint restore drill |
| H-08 | The signature covers the source archive; the image is built locally and its digest is not signed | Confirmed | One image built in CI, pushed to a registry, its digest signed (cosign) with SBOM and provenance; the installer refuses an unsigned image; pip hashes |
| M-03 | Rate limits for public search and partner keys are per process | Confirmed | Shared limits in the database or a distributed firewall, tested with several servers |
| M-04 | The encrypted file is written before its row and not removed on refusal or rollback | Confirmed | Compensating delete, and a sweep for objects no row points to |
| M-08 | Rows leave the default partition in one transaction | Partly accurate (only after a backlog) | Batches above a threshold, measured on a production-sized copy |
| M-11 | 29 advisories in the mobile app's dependencies | Confirmed | An Expo-compatible upgrade plan, each advisory classed as build or runtime, a CI rule that refuses unclassed high ones |
| M-13 | The password deny list is short | Confirmed | A larger list of common passwords, or a k-anonymity check where the law allows it |
| M-14 | The mobile package has no `type: module`; not tested on real devices | Confirmed | EAS builds and a device matrix (install, offline, biometric lock) |

## 4. Already fixed, or not a defect

| Ref | Finding | Verdict |
|---|---|---|
| M-10 | The architecture document gave 432 tables and 24 schemas | Fixed in 1.48.0. It now gives 26 schemas and 504 tables (files 000 to 1082), as the generated `db/README.md` does |
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
| Modules writing other modules' tables | Ownership documented; no automatic check yet, package 3 |
| Performance, launch gates, scores | Accurate |

## 5. Outside the code

These need staging or a third party. They are the launch gates that are already open:

* failover and restore drills on staging;
* the independent penetration test;
* the capacity test;
* device tests;
* a live payment provider.

## 6. Test results

| Suite | Package 1 | Package 2 |
|---|---|---|
| Database checks (`db/tests/run_tests.sql`) | 508 passed | 509 passed |
| API tests on a new database | 461 passed, 7 skipped | 490 passed, 14 skipped (7 of them the telemetry tests, which CI runs against their own database) |
| Telemetry tests | 7 passed | (CI) |
| Alert rules (promtool) | Valid, tests pass | 71 rules valid, tests pass |
| ruff, bandit | Clean | Clean |
| OpenAPI baseline | No breaking change | No breaking change |
| Generated documents, schema dependencies | Up to date | Up to date |

Package 2 was also exercised locally on the database containers: TLS only, the replica streaming over TLS, PgBouncer
checking certificates both ways, the warehouse login refused, archiving to object storage over TLS, Vault through a
proxy with its own authority, and the alert drill reaching a receiver. The images themselves are built and run end to
end in the CI job **Production installation**.
