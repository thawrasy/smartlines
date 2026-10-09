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
| R-49 | The release workflow published on a tag whether or not CI passed | The release workflow runs the whole CI on the tagged commit first and publishes only after it | `.github/workflows/release.yml` |
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

