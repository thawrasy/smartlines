# Expert review of October 2026: stage C

Stage C is the one-to-three-month work of the review: rules that keep the code and the database honest as they grow.
Each item below is in the code, checked on every push, and documented. The review found three defects along the way
and they are fixed (section 2). Section 3 says what each item leaves for later.

## 1. What changed

| # | Item | Change | Where | Checked by |
|---|---|---|---|---|
| C1 | Narrower grants for the application role | `masslak_app` held DELETE on almost every table, and row-level security alone limited what a delete reached. It now deletes from 36 tables only, each listed with its reason in `sys.app_delete_grant`. Three are deleted by the code itself (second factors, push tokens, family travel rules), and 33 are lists the module screens edit line by line. DELETE is revoked everywhere else. `sys.grant_rw` no longer grants it, and a business record is cancelled, closed or archived, never deleted | `db/schema/1059_app_delete_grants.sql` | 2 database checks (the exact set; a business record cannot be deleted); `test_code_rules.py::test_every_delete_in_the_code_has_its_grant` finds every `DELETE FROM` in the code and every module list with deletes |
| C2 | Governance of `system_scope` | Each of the 80 functions that act as the platform inside the caller's transaction (82 uses) is listed with the number of uses and the reason in `backend/tests/governance_registry.py`. A new use, a moved one or a removed one fails CI until a reviewer updates the registry. At run time each entry is counted under its calling function as `masslak_system_scope_total{site}` | `governance_registry.py`, `test_code_rules.py`, `app/db.py`, `app/metrics.py` | `test_every_system_scope_use_is_reviewed`, `test_each_system_scope_use_is_counted_by_its_site` |
| C3 | Release manifest | Every build and upgrade records the release version, the commit, the number of applied schema files and one hash over them in `sys.release_manifest`; a run that changes nothing adds no row. `db/upgrade.sh` refuses to run (exit code 4, nothing applied) when the record of applied files no longer matches the last manifest. Reports and exports name the release they were made from (`source_version`, which named release 1.21.0 whatever the schema was), and the scrape exposes `masslak_release_info` and the alert `ReleaseRecordChanged`. Images and archives carry the commit (`MASSLAK_RELEASE_COMMIT`, the `RELEASE` file) | `db/schema/1058_release_manifest.sql`, `db/build.sh`, `db/upgrade.sh`, `app/release.py`, reports, `Dockerfile`, `deploy/` | 5 database checks; a CI step removes a row by hand and expects exit 4; promtool test |
| C4 | CI rule for deferred balances | Shared wallets (escrow, company, platform) store a balance that lags their newest entries. The application reads `fin.wallet_balance(id)` or `ledger.counted()`, and each direct read of `fin.wallet.balance` or of a raw wallet row is listed in the registry with the reason its balance is exact (passenger, family and counter cash wallets) | `governance_registry.py`, `test_code_rules.py` | `test_stored_wallet_balances_are_read_only_where_exact`, `test_the_rules_catch_what_they_are_for` |
| C5 | An owner for every invariant | 28 business rules, each with its owner: the database (17), the application (5) or both (6). Each names the triggers, constraints, functions and code that keep it and the tests that prove it. The matrix is `docs/database/invariants.json`, rendered as [INVARIANTS.md](../database/INVARIANTS.md). A test checks every name against the built database, the code and the test files, so a renamed trigger or a removed test shows | `docs/database/invariants.json`, `db/tools/gen_invariants.py` | `test_invariants.py` (6 tests) |
| C6 | Supply chain | Every base image is pinned by digest (11 images, 14 references) and every CI action by commit (16 references). `scripts/pin_images.py` checks this on every push, and `--update` moves the pins for review. CI builds an SPDX bill of materials of the image. A tag `v*` publishes the release archive with its bill of materials, checksums and keyless Sigstore signatures (`release.yml`). `deploy/verify-release.sh` checks them before an archive is extracted. The Prometheus download in CI is checked against its published checksum | `scripts/pin_images.py`, `.github/workflows/`, `deploy/verify-release.sh`, `deploy/update.sh`, `deploy/install.sh` | `pin_images.py` in CI; the verification script tested on a good and a tampered archive |
| C7 | Finer monitoring | Lock waits are now named by table (`masslak_lock_waiting{table}`, `masslak_lock_wait_seconds_max{table}`; a row lock counts on the table of its row). Every partitioned table reports how far ahead its partitions go and the rows in its default partition. The API reports how long requests wait for a database connection (`masslak_db_pool_acquire_seconds`). New alerts: `LockWaitsOnTable`, `PoolWaits`, `PartitionsRunningOut`, `RowsInDefaultPartition`. Trigger and function cost has been measured since the architecture review (`masslak_db_function_seconds_total`) | `db/schema/1060_monitoring_detail.sql`, `app/db.py`, `app/metrics.py`, `deploy/monitoring/` | 2 database checks; `test_monitoring_detail.py` makes a real lock wait and reads it from the scrape; promtool tests (36 rules) |
| C8 | Payment options in the mobile app | The passenger app offers the wallet, pay later at the counter, and any open card, instalment or financing provider, under the switches of the `APP` channel. A reservation shows its pay-by time and how to pay, opens the provider's page, refreshes on return and can be cancelled. App bookings are recorded on `APP_ANDROID` or `APP_IOS` (they were recorded as `WEB`) | `mobile/src/app/(passenger)/trip`, `booking`, `trips.tsx`, `mobile/src/platform/payments.ts`, `app/deps.py`, `routers/bookings.py` | `test_the_apps_book_on_their_own_channel`; mobile type check, unit tests and bundle |

## 2. Defects found and fixed

- **The regulator saw too little money in escrow (found by the C4 rule).** The regulator's dashboard summed the stored
  balance of the escrow wallets. Escrow is a shared wallet whose stored balance lags its entries, so the figure left
  out the newest bookings. It now sums `fin.wallet_balance(id)`.
- **A refund was checked against a lagging balance (found by the C4 rule).** The refund check read the payer's wallet
  row directly; it now goes through `ledger.counted()`, which gives the full balance for any kind of wallet.
- **App bookings counted as website bookings (found while building C8).** Every passenger booking was recorded on the
  `WEB` channel and checked against the website's switches, so an option closed for the apps only stayed open in them.
  The support module had the same problem: it read a header the apps never send. Both now use one rule
  (`deps.sales_channel`).
- **A test that depended on the hour (found by the full run).** The financing test assumed that the first bookable
  trip leaves within 48 hours. After midnight in Damascus it does not, and the test failed. The test now sets the
  cutoff from the trip's own departure time.

## 3. What each item leaves for later

- **C1** is the first step: DELETE only. Next, UPDATE limited to the columns each module changes, and INSERT only
  where the application writes, starting with the ledger and the audit tables. The same registry pattern applies.
- **C2:** 80 functions still use the system scope. The registry makes each one visible and reasoned; reducing them
  (for example, policies that let a carrier's counter read its own trips' bookings directly) is ongoing work.
- **C6:** servers build the image from the signed source, so the image itself is not signed or pushed to a
  registry. When the deployment moves to pulling images, sign them with the same workflow and verify by digest
  before `compose up`. Python and npm dependencies are pinned by version and lock file, not yet by hash.
- **C7:** PostgreSQL keeps no per-table history of lock waits, so the metrics are what waits now, sampled at each
  scrape. A history needs `log_lock_waits` sent to the log pipeline (stage D, telemetry cluster).
- **C8:** the provider's page opens in the phone's browser and returns to the website's booking page; the app reads
  the booking again when it comes back to the front. An in-app browser session with a return link into the app
  needs the Expo web-browser module, a separate dependency update.

## 4. Tests

- Database: 408 checks pass on a fresh build (9 new: narrower grants 2, release manifest 5, finer monitoring 2).
- API and unit tests: 331 pass and 5 are skipped (external proxy) on a fresh database. New files: `test_code_rules.py` (5), `test_invariants.py` (6),
  `test_monitoring_detail.py` (2); `test_payment_options.py` has one more.
- CI steps: pinned images and actions, the upgrade refused on a hand-changed record, the bill of materials, promtool
  with tests for the four new alerts and `ReleaseRecordChanged`.
- Mobile: type check, unit tests and an Android bundle of the passenger app.
- Data dictionary, ERD and README figures regenerated from a fresh build: 485 tables, 408 checks.
