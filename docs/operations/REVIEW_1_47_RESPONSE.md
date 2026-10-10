# Response to the reviews of release 1.47.0 (release 1.48.0)

Three reviews of release 1.47.0 (commit 2cb00a3) were assessed against the code: an engineering review with 56 risk
cards (R-01 to R-56), technical guidance on performance and a plan for performance and reliability. Every card was
checked in the code; none was contradicted. This page records what changed in release 1.48.0, package by package,
with the test that proves each change. The owner's decisions on the five open questions are in section 9.

## 1. Package A: what had to be fixed at once

| Ref | Finding | What changed | Proof |
|---|---|---|---|
| R-48 | The field key parser split each entry at its last `=`, and every base64 key the installer writes ends with one: a production server could not start, a test server failed at its first encryption | Entries are split at the first `=` (a key reference has none) | `test_crypto.py::test_keys_as_the_installer_writes_them` (failed before the fix); CI job **Production installation**: installs without `--demo`, enrols two-factor sign-in (encrypts), restarts the API and signs in again (decrypts) |
| R-26 | Demo data, with its shared published password, loaded whenever `MASSLAK_SEED_DEMO=true` | `deploy/migrate.sh` refuses it unless `MASSLAK_SANDBOX=true` on a development or staging server; `seed_demo.py` refuses a database marked production | CI job **Production installation** runs the migration with `MASSLAK_SEED_DEMO=true` and expects a refusal and no demo account |
| R-27 | The message log (`log`), with addresses and texts in plain files, was the default and allowed in production | New mode `off` (nothing sent, in-app only); unset means `off` outside the sandbox; the API and the worker refuse to start with `log` outside it; the installer writes `off` for production | `test_review_1_47.py::test_message_log_is_refused_outside_the_sandbox`; the production CI job |
| R-29 | `MASSLAK_KMS_PROVIDER=local` keeps the key encryption key in the environment, and was accepted in production | Refused unless the server is a sandbox, development or staging (`MASSLAK_ENVIRONMENT`) | `test_review_1_47.py::test_local_key_wrapper_is_for_test_servers_only` |
| R-30 | A live API key worked on a sandbox server | Refused there (`API_KEY_LIVE_ONLY`), as test keys are refused in production | `app/modules/integration/auth.py` |
| R-25 | Every staff member of a company, and every platform account, could read the company's licences and insurance papers | Listing and reading take the permission that files them (`company.staff`, `vehicle.manage` or `company.billing`); on the platform, the reviewers' `company.approve`; the menu follows | `test_documents.py::test_reading_documents_takes_the_permission_that_files_them`, `test_review_1_47.py::test_document_access_needs_the_filing_or_review_permission` |
| R-18 | A notice with a bad signature took the provider's event id, so the real notice that followed was taken for a replay | 1073: the event id is unique among signed notices only; unsigned notices are kept and counted per provider | `test_payments.py::test_an_unsigned_copy_cannot_take_the_event_id_first`; DB checks |
| R-19 | A wallet code confirmation compared the amount, not the currency | One check, `notice_matches`, for signed notices and codes alike; a provider answer without an amount waits for the signed notice | `test_review_1_47.py` (two tests) |
| R-24 | Statement amounts were multiplied by 100 and their commas dropped: `1.234,50` was read wrong, three-decimal currencies too | Read with the decimal mark finance chooses for the file; the other mark may only group thousands; minor units from the currency; more decimals than the currency has is refused, never rounded | `test_review_1_47.py` (20 cases), `test_payments.py::test_statement_with_decimal_commas` |
| R-49 | The release workflow published on a tag whether or not CI passed | The release workflow runs the whole CI on the tagged commit first and publishes only after it. Seen on v1.48.0: the first run failed one CI job and nothing was signed or attached; the files came only from the run in which every job passed | `.github/workflows/release.yml`; `evidence/release_verification_v1.48.0_2026-10-10.json` |
| R-53 | Serious accessibility findings did not fail the check | Critical and serious findings both fail it | `frontend/e2e/ui-checks.mjs` |
| R-50 | The client contract test passed silently on a copy without the mobile sources | A missing client source fails the test unless named in `MASSLAK_CONTRACT_WITHOUT` (then it is reported as skipped) | `test_api_contract.py::test_both_clients_are_checked` |

### Upgrading a server to 1.48.0

* A test server that ran with `MASSLAK_FIELD_KEYS` emptied as a work-around keeps it empty: what it encrypted
  meanwhile is sealed under keys derived from its signing secret, which real keys under the same references would not
  open. A production server starts with the keys its installation generated.
* A server outside the sandbox with `MASSLAK_NOTIFY_EMAIL=log` or `MASSLAK_NOTIFY_SMS=log` no longer starts: set
  `smtp` / `http` with their gateways, or `off`.
* A server outside the sandbox with `MASSLAK_KMS_PROVIDER=local` no longer starts unless `MASSLAK_ENVIRONMENT` is
  `development` or `staging`.
* Existing providers whose old fee setting said the payer bears the fee get a fee rule from it (1074) and start charging
  it: check the Payment fees tab after the upgrade.
* A credit from a bank statement now waits for one finance reviewer other than the importer (the default matrix);
  set the BANK_CREDIT policy to no level to keep the old behaviour, which the reviews advise against.
* Withdrawals approved by two people are paid out by a third: a server with only two finance officers sets a higher
  second-approval limit or adds a treasurer.

## 2. Package B: money boundaries, fees and approvals

| Ref | Finding | What changed | Proof |
|---|---|---|---|
| R-16 | A payment was started at the provider before its row existed here, inside the transaction, with a blocking call on the event loop | Three steps: the payment is recorded and committed (stage CREATED); the provider is called with no transaction open, in a thread, under a merchant reference fixed by the payment; its answer is recorded under the row's lock: PROVIDER_UNKNOWN when none came, and repeating the request asks again with the same reference. The same for reservations and wallet codes | `test_money_boundaries.py::test_a_payment_is_kept_when_the_provider_does_not_answer`, `::test_a_refused_start_fails_the_payment` |
| R-17 | A refund was sent under a reference built from an uncommitted row; a failure after the provider accepted could refund twice | The refund holds its amount in the wallet when asked, is sent under `RFD…` fixed by its row, posted only when the provider accepted, sent again (same reference) after an unknown outcome by the worker or by finance, released after a refusal | `::test_a_refund_is_held_sent_once_and_posted_only_when_accepted`, `::test_a_refused_refund_releases_the_hold`; DB trigger: a final refund never changes |
| R-20, decision 4 | Fee and rounding policy outside the ledger | Fee rules per way of paying, currency, customer and period: percentage, fixed, both or none; floor, cap, rounding step and direction; paid by the customer by default and shown before paying (quote), asked from the provider with the amount, posted to platform revenue; or borne by Masslak and recorded as absorbed | `::test_fee_rules_are_shown_charged_and_posted`, `::test_a_fee_the_platform_bears_is_not_asked_from_the_payer`; DB checks |
| R-21 | Two remittances confirmed at once could exceed what the carrier owed | The carrier's cash wallet is locked before what it owes is read again | `app/modules/cash/service.py` |
| R-22 | The approver of a withdrawal could also pay it out | Refused in the code and by a constraint (1074) | `test_payouts.py` (the approvers are refused, a treasurer pays) |
| R-23, decision 5 | One person imported a statement and credited wallets from it | The approval matrix: per kind of decision, 0 to 5 levels, each decided by the holders of a permission or only by named people, from an amount; a statement credit and a refund wait for it; the database refuses a requester deciding, two levels by one person, levels out of order, a person not named or without the permission | `::test_the_matrix_takes_its_levels_in_order_from_the_named_people`, `::test_a_rejection_releases_the_refund`, `::test_the_matrix_refuses_people_who_could_never_decide`, `test_payments.py` (statement credits approved by another officer); DB checks |
| Guidance 1.3 | No circuit breaker on outside services | Per provider: open after five unanswered calls, closed by the next answer; counted, and alert PaymentProviderCircuitOpen | `::test_the_circuit_opens_after_unanswered_calls_and_closes_on_an_answer`; promtool |

New alerts with their tests: RefundOutcomeUnknown, PaymentProviderCircuitOpen, ApprovalsWaiting, UnsignedNoticesBurst
(RUNBOOKS.md, section 25).

## 3. Package C: sign-in, bookings and operations

| Ref | Finding | What changed | Proof |
|---|---|---|---|
| R-31, decision 2 | A new driver signed in without a second factor; the authenticator app was the only method | The platform's policy chooses the methods open (authenticator app, text message, WhatsApp; one or more) and the portals that must use one, drivers included, with limits on message codes; the security console edits it. Message codes are kept only as keyed hashes, expire within minutes, allow five tries and work once; numbers are kept encrypted. Enrolment and the second step work on the website and in the apps | `test_sign_in_and_operations.py` (three tests), DB checks |
| R-07 | Two holds sent together could both pass the per-person seat limit | Counting and locking are one step under a per-person advisory lock | `::test_holds_sent_together_cannot_pass_the_limit` |
| R-08 | The same booking key sent twice at once answered the second with an error | The second request waits for the first and answers with its booking | `::test_the_same_booking_key_sent_together_answers_with_one_booking` |
| R-10 | The boarding stop was stored as sent | It names a stop of the trip, by default the ticket's first; a stop the ticket does not cover is WRONG_STOP; the database refuses both | `::test_a_boarding_names_a_stop_the_ticket_covers`, DB checks, invariant BOARDING-AT-A-STOP-THE-TICKET-COVERS |
| R-09 | An offline scan time came from the device | Besides the day-before-departure bound, it cannot be earlier than the driver's first download of the trip's pack | `::test_an_offline_scan_is_not_older_than_the_pack` |
| R-02 | A long stop of the upkeep left rows of older periods in the default partition | The upkeep starts from the oldest period waiting there | DB check (ten-day stop) |
| R-03 | Positions the telemetry database refused relied on the app sending them again | They wait on the primary and the worker delivers them; alert PositionBacklogGrowing | `::test_positions_wait_on_the_primary_while_the_telemetry_database_is_down`, promtool |
| Report 3 | A wallet opened by two first operations at once failed one of them | Opened with `ON CONFLICT DO NOTHING` and read again | `::test_a_wallet_opened_twice_at_once_is_one_wallet` |

Upgrading to 1.48.0, package C:

* Drivers, carrier and agency staff and inspectors must use a second factor outside the sandbox by default (the
  policy's required portals). They enrol at their next sign-in. To phase it in, remove portals from the policy first
  and add them back once staff have enrolled.
* Text and WhatsApp codes need their gateways (`MASSLAK_NOTIFY_SMS=http`, `MASSLAK_NOTIFY_WHATSAPP=cloud`); until then
  only the authenticator app is offered. The WhatsApp endpoint is added to the egress allowlist from its URL.
* Driver apps that do not send a boarding stop keep working: the ticket's first stop is used.

New alerts with their tests: PositionBacklogGrowing, MfaCodesFailing (RUNBOOKS.md, section 26).

## 4. Package D: durability, backups, capacity and the second site

| Ref | Finding | What changed | Proof |
|---|---|---|---|
| R-39, decision 1 | "No data loss" depended on a synchronous standby that could silently stop being one | Zero data loss is a setting, `MASSLAK_ZERO_DATA_LOSS` (on in production): every commit waits for a standby, and with none commits wait instead of being confirmed without a copy; off lets the primary confirm alone. Applied by `deploy/durability.sh` (standard stack) or `deploy/ha/durability.sh` (Patroni strict mode) on install and update; the database reports whether commits wait, and alerts page when the setting is on but not in force, or when commits wait for a missing standby | CI job **Production installation**: the replica is synchronous, a commit with the standby stopped does not go through, and goes through once it is back; DB checks; promtool |
| R-41 | Nightly backups stayed on the server they protect | Copied off the server with rclone, checked against the checksums, both copies recorded (1076); alerts BackupStale and BackupOffsiteStale | CI job **Deployment stack**: backup, off-site copy verified, both copies recorded, restore; promtool |
| R-40 | The WAL archive alert fired after 5 + 5 minutes for a 60-second target, and the check after a restart was manual | The alert fires after 90 s + 1 minute; `deploy/pitr/check-archive.sh` switches WAL and waits for it to be archived, run by every update | promtool; `deploy/update.sh` |
| R-46 | The direct audit connections grew with the number of API servers past the primary's limit | The audit and report pools open connections only while used and close them when idle; the audit role is capped at 20 in the database; pool sizes are settings | `CAPACITY_MODEL.md`, section 10; DB check |
| R-43 | The second site had no watchdog | `deploy/ha/site-b-watchdog.sh` with a systemd timer: streaming, replay lag, the main site's reachability from there, as metrics and a message on change; never promotes; alerts SiteBNotStreaming, SiteBLagging, MainSiteUnreachableFromSiteB, SiteBWatchdogStale | promtool |
| R-44 | A restore did not prove the files and the database belong to the same moment | `python -m app.tools.files_check` reads back every file the database refers to, decrypts it and compares size and hash; `restore.sh` runs it and fails on a missing or different file; the runbook restores the bucket to the database's time first | CI job **Deployment stack** (restore) |

Upgrading to 1.48.0, package D:

* Production servers get `MASSLAK_ZERO_DATA_LOSS=on` from the installer. An existing server without the line keeps
  `off` until it is added; add it, then run `./deploy/durability.sh` (it restarts the read replica once so it takes its
  name). With `on`, a stopped replica pauses commits: plan replica maintenance accordingly.
* Set `MASSLAK_BACKUP_OFFSITE` and install rclone (`apt-get install rclone`, then `rclone config`); until then the
  alert BackupOffsiteStale fires and `backup.sh` ends with status 3.
* On the second site: install `deploy/ha/masslak-site-b-watchdog.service` and `.timer`, and let Prometheus scrape the
  node exporter's textfile directory there.

New alerts with their tests: BackupStale, BackupOffsiteStale, ZeroDataLossNotEnforced, CommitsWaitingForStandby,
SiteBNotStreaming, MainSiteUnreachableFromSiteB, SiteBLagging, SiteBWatchdogStale (RUNBOOKS.md, sections 23 and 27).

## 5. Package E: the web interface

| Ref | Finding | What changed | Proof |
|---|---|---|---|
| R-32 | On a phone the account was unreachable and support could disappear | The phone bar shows the account always; family, support and the services sit under a named "More" menu | `frontend/e2e/ui-checks.mjs` (phone views, no serious finding); a browser check of the bar |
| R-33 | A failed load of the travel document rules opened the booking as if there were none | "Not loaded" is kept apart from "no rules": booking waits, with a message and a retry, and what was entered is kept | `pages/passenger/Book.tsx` |
| R-34 | Following a returning payment and cancelling a pending one hid their failures | A failed check or an answer still pending after about 30 s is shown, with the last check time and "Check again"; a cancel shows its error and keeps the payment visible | `pages/passenger/Wallet.tsx` |
| R-35 | Requests had no deadline and were not cancelled when a screen closed | Every request has a deadline (30 s reads, 60 s changes, 3 min uploads) and fails with TIMEOUT, shown with a retry; screens pass a signal that cancels their request when they close; a change is never re-sent by itself | `api.ts`, `components/ui.tsx` (`useLoad`) |
| R-36 | The tracking page said "not found" for any error | Only a 404 says so; a busy or unreachable service says that, with a retry | a browser check |
| R-37 | Dialogs declared `aria-modal` without keeping focus | Focus moves into the dialog, Tab and Shift+Tab stay inside, Escape and the translated close button close it, focus returns to the opener; the title names the dialog | a browser check (30 Tab presses stay inside, focus returns to "New request") |
| R-38 | Support cases opened by mouse only | Each case reference is a button | `pages/passenger/Support.tsx` |
| R-56 | One large script for every visitor | The staff portals load when first opened (one chunk per portal module); the passenger screens stay in the first download | `npm run build`: the portals are separate chunks of 20 to 45 kB |


## 6. Package F: performance evidence, logs and quality gates

| Ref | Finding | What changed | Proof |
|---|---|---|---|
| R-46 (report 3, 3.4) | Report files were built on the request loop, so one large PDF or spreadsheet held up every other request of the process | Files are built in a worker thread, at most `MASSLAK_EXPORT_RENDER_SLOTS` (2) at a time per process; a burst waits up to 15 s and is then answered 503 `EXPORT_BUSY` with `Retry-After` (scheduled reports use the same path) | `test_observability.py::test_report_files_are_built_in_a_thread_and_a_burst_waits_or_is_refused` |
| Report 3, 7.2 | Logs were free text without the request, the route or the release | One JSON object per line outside the sandbox: `ts`, `severity`, `service`, `version`, `environment`, `logger`, `message`, `request_id`, `trace_id`; each API request adds `method`, the route template (never the address with identifiers), `status`, `duration_ms`, `error_code` and where the time went (`pool_wait_ms`, `db_ms`, `db_transactions`, `egress_ms`, `egress_calls`). Personal data is removed before writing (`logredact`) | `test_observability.py` (line format, phases); RUNBOOKS.md, section 28 |
| Report 3, 3.1 and 7.4 | No trace followed a request into its events and outbound calls | The W3C `traceparent` of a request is kept (a new one otherwise), returned on the response, stored on every outbox event it writes (`correlation_id`), used by the worker's lines for those events and sent on every call through the egress proxy | `test_observability.py::test_a_booking_carries_its_trace_into_the_response_and_its_outbox_event` |
| Report 3, 4.1 | Indexes were chosen without statement statistics | `pg_stat_statements` is preloaded by every deployment layout (utility statements left out, slow statements logged without bind values); 1077 reads it only through functions that mask literals: `sys.top_statements` (by total or mean time, calls, disk reads), `sys.statement_metrics` for the monitoring, `sys.reset_statement_stats` for a before-and-after window; the security console's *Slowest statements* page shows them; everything answers empty where the server does not preload it | DB checks (both with and without the extension); `test_observability.py::test_the_security_console_reads_statement_statistics_without_values` |
| R-51 | The contract test compared addresses and methods only, so a removed response field or a changed enum broke clients at run time | `docs/api/openapi-baseline.json` holds the contract of the web/mobile API and the partner API v1 (parameters, request bodies with every enum and limit, success statuses); `docs/api/response-shapes.json` holds the fields and types of the responses the clients depend on, recorded from a running server. CI fails on a removed operation or status, a new required field or parameter, a narrowed request enum, a widened response enum, a tightened limit, a retyped or removed response field. Additions pass; a deliberate break is accepted with a reason recorded in `docs/api/API_CHANGES.md` | `test_api_baseline.py` (the baseline, nine kinds of break named, additions pass, live shapes) |
| R-52 | No coverage measurement or threshold | CI runs the API server and the tests under coverage, combines both, prints the report into the run summary and fails under the minimums of `backend/coverage-thresholds.json`: 84% in total and a minimum for each of 28 modules that move money, sign people in or keep tenants apart. Minimums only go up; an exception names its owner, its reason and its end date, and fails once expired | `test_coverage_gate.py`; first measured run: 87.0% in total |

Upgrading to 1.48.0, package F:

* The database must preload `pg_stat_statements`: the standard stack's `docker-compose.yml` and the replica now do,
  which takes effect when the database container is recreated by `./deploy/update.sh`. A managed server: add it to
  `shared_preload_libraries`, restart, and (if the owner role may not read other roles' statements)
  `GRANT pg_read_all_stats` to it. Until then the page says statistics are off; nothing else changes.
* Log collectors that parsed the old text lines must read JSON now (`MASSLAK_LOG_FORMAT=text` keeps the old format).

## 7. Package G: manifests and parcels

| Ref | Finding | What changed | Proof |
|---|---|---|---|
| R-11 | The carrier could not issue a pre-arrival manifest | `PRE_ARRIVAL` is accepted for international trips; on a domestic trip it is refused with `MANIFEST_TYPE_SCOPE` | `test_manifest_integrity.py` (both cases) |
| R-12 | The border contract (`/api/v1/border/*`) saw only manifests written by hand, never the carrier's live ones | An international manifest whose crossing has an authority is `SUBMITTED` to it at issue. The authority lists, reads (with cargo and the canonical form) and decides it through `/api/v1/border/*`; the decision answers its routed delivery too, and an acknowledgement through `/api/v1/manifests/deliveries` answers the manifest, so the carrier sees one result whichever contract is used | `test_manifest_integrity.py`: trip, passenger with a passport and a parcel all through the APIs, then list, read, verify, acknowledge, and the carrier sees ACKNOWLEDGED (no SQL on the manifest) |
| R-13 | Cargo was never put on a manifest, and cargo rows could be changed after the hash | The issue builds the cargo from every shipment leg on the trip's hold or on a load it pulls; refuses a shipment without a weight (`MANIFEST_CARGO_WEIGHT`); marks the manifest PASSENGER, CARGO or MIXED and routes it by content. The hash covers a canonical form rebuilt from the manifest's own rows (people, vehicle, cargo) and is signed with Ed25519 (key at `/api/public/keys/manifest`, `/verify` for the carrier). Once issued the database refuses any change to the rows and to the header's content (1078); a change is an amendment. The data-management screen shows manifest cargo read-only | DB checks (four refusals, status still moves); `test_manifest_integrity.py` (hash recomputed by the authority from the JSON, signature checked, three refused changes) |
| R-14, decision 3 | A paid parcel had no place on any vehicle | Parcels are booked on a trip's hold: the shipment, its parcel and its leg are written, the hold is checked under its lock (1067), and only then the wallet is charged; a shipment marked guaranteed cannot be committed without a leg holding capacity. Carriers publish tariffs by weight, by volume, by the dearer of the two (both charges shown to the customer), at a fixed price (letters) or by agreement (the customer asks, the carrier offers a price valid for some hours, the customer accepts and pays it); one database function makes every price. Customers see the free hold of each trip. Carrier page *Parcels*, passenger page *Send a parcel* | `test_parcels.py` (quotes for each mode, booking and replay charged once, a full hold refuses before payment, two customers for the last space get one booking, the agreed-price flow); DB checks |

Upgrading to 1.48.0, package G:

* Manifests issued before 1.48.0 keep their status and are not verifiable (`canonical_version` empty); new versions are.
* Carriers set the hold each trip offers (`PUT /api/carrier/trips/{uid}/hold`, never over the vehicle's registered
  cargo capacity) and publish their tariffs before customers can book parcels on their trips. The older station-to-station
  parcel request (`/api/w/parcels`) stays for shipments without a trip; it is not guaranteed and says so.

## 8. Package H: data lifecycle, evidence and the release

| Ref | Finding | What changed | Proof |
|---|---|---|---|
| R-04 | 33 datasets had a lifecycle; most of the ~500 tables were in none | Every table is a dataset or a member of one (1079): the uncovered tables are grouped by schema and sensitivity (a table with names, contacts, dates of birth or documents counts as personal) with a retention, an erasure method and its copies. `gov.lifecycle_gaps()` must be empty: a new table without a dataset, or a personal table placed in a public dataset, fails the database checks in CI. `gov.v_table_lifecycle` shows each table's rules | DB checks (coverage, a probe table reported, a personal table refused in a catalog) |
| R-06 | No production plan for the heavy conversions 1064 and 1070 | `MIGRATION_PLANS.md`: 1064 is measured on a copy and then applied in a sized maintenance window with counts and reconciliation before and after; 1070's move from the default partition is batched above 200,000 rows; both are listed under launch gate 4 at 1x, 2x and 5x volume. The files of this release were rehearsed under load: 7.1 s, longest exclusive lock 0.51 s, no traffic error | `evidence/migration_rehearsal_1.48.0_dev_2026-10-10.json` |
| R-05 | Archiving a closed year was described, not defined | RUNBOOKS.md section 29: scope from the closed ledger, the dependency map from the foreign keys, copy with per-table counts and hashes to an archive database read through its own read-only role, removal only after a signed comparison, ledger totals kept, proof by reconciliation and a restore of the archive | runbook (to rehearse on a copy before the first year is archived) |
| R-45 | Nothing pages when the alerting itself fails | Alert `Watchdog` always fires and goes every minute to a dead man's switch that pages through its own channel when it stops (`deploy/staging/alertmanager.yml`, receiver `deadman`) | promtool test |
| R-42, R-47, R-55 | The production layout, rollback after a migration and the independent proofs are not shown by the repository | Listed with their evidence under the launch gates (`LAUNCH_GATES.md`, "What the reviews of release 1.47.0 add to the gates"); they stay open until run on staging and by the external firm. No development measurement is offered in their place | `LAUNCH_GATES.md` |
| R-54 | The delivered archive could not be verified independently | Release v1.48.0 was published on 10 Oct 2026 from commit 05cc3ee: the release workflow ran every CI job on the tagged commit, then signed the archive, its SPDX bill of materials and `SHA256SUMS` with Sigstore and attached them with their bundles to the GitHub release. Verified with the identity and issuer `deploy/verify-release.sh` requires (`release.yml@refs/tags/v1.48.0`, GitHub Actions): the three signatures, the checksums and the `RELEASE` record (commit 05cc3ee, v1.48.0) pass; an altered archive and another tag's identity are refused. The check ran offline against the trust root of sigstore-python, because the development environment cannot reach cosign or the Sigstore servers; the script itself runs on each server before install (launch gates). Publishing it needed the workflow fixes listed below the table. The package built locally at bd5196d is superseded | `evidence/release_verification_v1.48.0_2026-10-10.json`; https://github.com/thawrasy/smartlines/releases/tag/v1.48.0 |

### Publishing release 1.48.0: what the release workflow needed

Release 1.48.0 was the first tag to go through `.github/workflows/release.yml`, and it was published from the
repository's Releases page. It showed four faults in the workflow, fixed as follows:

| What went wrong | What changed | Commit | Proof |
|---|---|---|---|
| The workflow only started on a tag pushed with git and created the release itself, so a release published from the Releases page would have stopped it (`gh release create` fails when the release exists) | The workflow also starts when a release is published (`release: published`) and from Run workflow on a tag; it adds the signed files to a release that already exists instead of creating one; runs for the same tag replace each other, so the tag push and the release event of one publication give one result. Every path runs on a `v*` tag, so the signature identity that `deploy/verify-release.sh` checks is unchanged | dbeb3cc | `actionlint`; the publishing step run against a stub `gh` with and without an existing release; v1.48.0 published from the page |
| The release notes sent readers to section 4 of the runbooks, where verification is not described | They point at section 19 | dbeb3cc | the notes of v1.48.0 |
| On a tag whose release already existed, CI's image bill of materials step tried to attach its file to that release with CI's read-only token and failed, so the release job did not run (first attempt of v1.48.0, at dbeb3cc) | The step keeps its file with the CI run (`upload-release-assets: false`); the release workflow publishes its own signed files. The release and tag were deleted and published again on 05cc3ee | 05cc3ee | run 38034954628 failed with nothing published; run 38035647487 passed and published |
| A release published from the page with no title kept an empty title (GitHub then shows the last commit message), and empty notes became two blank lines before the verification line | The workflow names such a release `Masslak <tag>` and, when its notes are empty, writes the verification line alone; notes typed on the page are kept with the line after them. v1.48.0 was tagged before this change, so its title and notes were set on the release page | 53049db | `actionlint`; the publishing step run against a stub `gh` for an empty release, a titled release with notes, a release already carrying the line and a tag pushed with git |

The runbook for publishing a release is RUNBOOKS.md section 19.

## 9. The owner's decisions (October 2026)

| Question | Decision | Where it is built |
|---|---|---|
| 1. Data loss when the primary fails | None may be lost; a setting turns zero data loss on or off rather than fixing it in code | `MASSLAK_ZERO_DATA_LOSS` (on in production), `deploy/durability.sh`, alerts `ZeroDataLossNotEnforced` and `CommitsWaitingForStandby` (package D, section 4) |
| 2. Second factor for drivers, carrier and agency staff | Required, by several methods of which one or more can be turned on: text message, authenticator app, WhatsApp | `sys.setting auth.mfa` from the security console's *Two-step sign-in* page: methods open and portals that must use one (package C, section 3) |
| 3. Parcels: guaranteed space or best effort | Parcels are booked with capacity; prices by weight, by volume or both, shown to the customer; letters at a fixed price or a price agreed between carrier and customer | Parcel tariffs and offers, hold capacity taken before payment (package G, section 7) |
| 4. Who pays the payment provider's fee, and how it is rounded | Set by the platform for each customer; by default the customer pays it and sees it before paying; per currency as a percentage, a fixed amount or zero (marketing and offers) | `fin.fee_rule` per way of paying, currency, customer and period, rounded per rule to a step and direction set in that currency (package B, section 2) |
| 5. A second approval before a bank statement amount is credited | An approval matrix with as many levels as the settings say, each naming its approvers | `fin.approval_policy` with levels and named members, checked in the database (package B, section 2) |
