# Business rules and who keeps them

Generated from `invariants.json` by `db/tools/gen_invariants.py`; edit the JSON, not this file.

Who keeps each business rule: the database, the application or both, the objects and functions that keep it, and the tests that prove it (expert review of October 2026, stage C5). backend/tests/test_invariants.py checks every name against the code, the tests and the built database; db/tools/gen_invariants.py renders INVARIANTS.md from this file.

| Owner | Meaning | Rules |
|---|---|---|
| database | the database refuses a breach whatever the caller; the application may check earlier only to give a clearer message | 17 |
| application | only the application can see the rule (it spans a request, a lock or a choice of code); the database supplies figures or records | 5 |
| both | each side keeps its own part, and both parts are tested | 6 |

## Summary

| Rule | Owner | Database tests | API tests |
|---|---|---|---|
| [LEDGER-BALANCED](#ledger-balanced) | database | 1 | 1 |
| [LEDGER-IMMUTABLE](#ledger-immutable) | database | 2 | 0 |
| [LEDGER-IDEMPOTENT](#ledger-idempotent) | database | 1 | 2 |
| [LEDGER-REFERENCE](#ledger-reference) | database | 2 | 0 |
| [WALLET-NOT-NEGATIVE](#wallet-not-negative) | database | 2 | 0 |
| [SHARED-WALLET-NOT-OVERDRAWN](#shared-wallet-not-overdrawn) | database | 2 | 0 |
| [WALLET-FROM-ENTRIES](#wallet-from-entries) | database | 3 | 1 |
| [COUNTED-BALANCE](#counted-balance) | application | 1 | 1 |
| [SEAT-SOLD-ONCE](#seat-sold-once) | database | 4 | 2 |
| [TRIP-CAPACITY](#trip-capacity) | database | 1 | 0 |
| [STATE-TRANSITIONS](#state-transitions) | database | 1 | 0 |
| [BOOKING-IDEMPOTENT](#booking-idempotent) | both | 0 | 1 |
| [REFUND-WITHIN-PAYMENT](#refund-within-payment) | both | 0 | 1 |
| [REFUND-BY-FARE](#refund-by-fare) | application | 0 | 2 |
| [ESCROW-UNTIL-TRIP](#escrow-until-trip) | application | 0 | 1 |
| [OPEN-PAY-OPTION](#open-pay-option) | database | 3 | 1 |
| [RESERVATION-PAY-BY](#reservation-pay-by) | both | 2 | 2 |
| [CASH-LIMIT](#cash-limit) | application | 1 | 1 |
| [REMITTANCE-FOUR-EYES](#remittance-four-eyes) | both | 4 | 1 |
| [WITHDRAWAL-FOUR-EYES](#withdrawal-four-eyes) | both | 1 | 1 |
| [LICENCE-DUAL-CONTROL](#licence-dual-control) | database | 3 | 0 |
| [BREAK-GLASS](#break-glass) | database | 5 | 0 |
| [AUDIT-APPEND-ONLY](#audit-append-only) | database | 3 | 0 |
| [EINVOICE-GAPLESS](#einvoice-gapless) | database | 2 | 0 |
| [TENANT-ISOLATION](#tenant-isolation) | database | 2 | 2 |
| [SYSTEM-SCOPE-REVIEWED](#system-scope-reviewed) | application | 0 | 2 |
| [DELETE-ONLY-WHERE-GRANTED](#delete-only-where-granted) | both | 2 | 1 |
| [RELEASE-MATCHES](#release-matches) | database | 2 | 0 |

## LEDGER-BALANCED

Every ledger transaction balances: its debits equal its credits, checked when the transaction commits.

**Owner:** database. A posting is many rows written by many callers; only a deferred check at commit sees the whole transaction.

| Kept by | Names |
|---|---|
| Database | `trigger fin.ledger_entry.ledger_txn_balanced` |
| Application | `app.ledger:post_txn` |
| Database tests (`db/tests/run_tests.sql`) | Ledger: unbalanced transaction rejected at commit |
| API tests (`backend/`) | `tests/test_e2e.py::test_booking_paid_from_wallet_is_idempotent_and_balanced` |

## LEDGER-IMMUTABLE

Posted entries and transactions never change; a correction is a reversal that mirrors the original amounts and wallets.

**Owner:** database. The ledger is the record of money; no code path, report job or console session may edit it.

| Kept by | Names |
|---|---|
| Database | `trigger fin.ledger_entry.ledger_entry_immutable`<br>`trigger fin.ledger_txn.ledger_txn_immutable`<br>`trigger fin.ledger_txn.ledger_reversal_mirrors` |
| Application | - |
| Database tests (`db/tests/run_tests.sql`) | Ledger: app role cannot update entries<br>Review 3.5: a reversal must mirror the original amounts and wallets |
| API tests (`backend/`) | - |

## LEDGER-IDEMPOTENT

One posting per idempotency key: a retried request cannot post the same money twice.

**Owner:** database. Callers derive the key from the request, so a retry repeats it; the unique key refuses the second posting whoever retries.

| Kept by | Names |
|---|---|
| Database | `constraint fin.ledger_txn.ledger_txn_idempotency_key_key` |
| Application | `app.ledger:post_txn` |
| Database tests (`db/tests/run_tests.sql`) | Ledger: idempotency key prevents double posting |
| API tests (`backend/`) | `tests/test_e2e.py::test_booking_paid_from_wallet_is_idempotent_and_balanced`<br>`tests/test_payments.py::test_refund_goes_back_to_the_card` |

## LEDGER-REFERENCE

A ledger transaction names a row that exists, of a registered kind.

**Owner:** database. The reference is polymorphic, so no foreign key can hold it; a trigger checks the kind and the row.

| Kept by | Names |
|---|---|
| Database | `trigger fin.ledger_txn.ref_type_checked` |
| Application | - |
| Database tests (`db/tests/run_tests.sql`) | Audit T3-04: a ledger transaction cannot name a booking that does not exist<br>Audit T3-04: a ledger transaction cannot name an unregistered kind of row |
| API tests (`backend/`) | - |

## WALLET-NOT-NEGATIVE

A wallet with an exact balance (passenger, family, counter cash) never goes below zero, and its holds stay within its balance.

**Owner:** database. Concurrent payments from one wallet meet at the wallet row; a check constraint refuses the one that would overdraw.

| Kept by | Names |
|---|---|
| Database | `constraint fin.wallet.wallet_balance_not_negative`<br>`constraint fin.wallet.wallet_hold_within_balance` |
| Application | - |
| Database tests (`db/tests/run_tests.sql`) | Ledger: user wallet cannot go negative<br>Scale: a hold within the balance is placed and released |
| API tests (`backend/`) | - |

## SHARED-WALLET-NOT-OVERDRAWN

A shared wallet (escrow, company, platform) cannot pay out more than it holds, counting the entries not yet rolled into its stored balance.

**Owner:** database. Shared wallets skip the row update on credits (DEFERRED); the entry trigger counts the full balance on every debit.

| Kept by | Names |
|---|---|
| Database | `trigger fin.ledger_entry.ledger_entry_apply`<br>`function fin.wallet_balance` |
| Application | - |
| Database tests (`db/tests/run_tests.sql`) | Scale: a shared wallet cannot pay out more than it holds<br>Scale: passenger and family wallets update at once, shared wallets are DEFERRED |
| API tests (`backend/`) | - |

## WALLET-FROM-ENTRIES

A wallet balance changes only through ledger entries and always equals the sum of its entries.

**Owner:** database. The guard refuses a direct balance change; the daily job proves the sums and reports any difference.

| Kept by | Names |
|---|---|
| Database | `trigger fin.wallet.wallet_balance_guard`<br>`function fin.reconcile_wallets` |
| Application | - |
| Database tests (`db/tests/run_tests.sql`) | Review 3.5: a wallet balance never changes without a ledger entry<br>Review 3.5: every wallet balance equals the sum of its entries<br>Scale: every wallet reconciles in both balance modes |
| API tests (`backend/`) | `tests/test_review_hardening.py::test_daily_maintenance_reconciles_the_ledger` |

## COUNTED-BALANCE

The application reads the counted balance of a shared wallet (fin.wallet_balance or ledger.counted), never the stored one that lags.

**Owner:** application. Which figure a query means is a choice in the code; a CI rule lists every direct read with its reason.

| Kept by | Names |
|---|---|
| Database | `function fin.wallet_balance` |
| Application | `app.ledger:counted` |
| Database tests (`db/tests/run_tests.sql`) | Scale: a credit to a shared wallet appends its entry without touching the wallet row, and counts at once |
| API tests (`backend/`) | `tests/test_code_rules.py::test_stored_wallet_balances_are_read_only_where_exact` |

## SEAT-SOLD-ONCE

A seat segment of a trip is held by one person and sold to one ticket of the same trip; only the sale marks it sold.

**Owner:** database. Two buyers of the last seat meet at one row; the key and the guard decide, whatever the application checked before.

| Kept by | Names |
|---|---|
| Database | `constraint ops.seat_segment.seat_segment_pkey`<br>`trigger ops.seat_segment.seat_segment_guard` |
| Application | `app.modules.sales.service:create_booking` |
| Database tests (`db/tests/run_tests.sql`) | Audit F-001: a seat is sold only to a ticket of its own trip (the 1039 seat guard)<br>Seat contention: only the sale, not the passenger, marks a seat sold<br>Seat contention: a passenger cannot free a sold seat<br>Audit C-01: the seat hold has one record, the LOCKED seat segment |
| API tests (`backend/`) | `tests/test_review_hardening.py::test_seat_contention_one_seat_one_winner`<br>`tests/test_e2e.py::test_seat_map_and_hold_conflict` |

## TRIP-CAPACITY

A trip never offers more seats or standing places than its vehicle has.

**Owner:** database. Trips are edited from several screens and imports; the trip trigger compares with the vehicle on every change.

| Kept by | Names |
|---|---|
| Database | `trigger ops.trip.trip_publish_rules` |
| Application | - |
| Database tests (`db/tests/run_tests.sql`) | Review 3.14: a trip never sells more seats than its vehicle has |
| API tests (`backend/`) | - |

## STATE-TRANSITIONS

Bookings, tickets, payments and withdrawals move only along their allowed state transitions.

**Owner:** database. Every module and job changes these states; one trigger per table holds the single list of allowed moves.

| Kept by | Names |
|---|---|
| Database | `trigger sales.booking.booking_transition`<br>`trigger sales.ticket.ticket_transition`<br>`trigger fin.payment.payment_transition`<br>`trigger fin.withdrawal_request.withdrawal_transition` |
| Application | - |
| Database tests (`db/tests/run_tests.sql`) | Booking: invalid state transition rejected |
| API tests (`backend/`) | - |

## BOOKING-IDEMPOTENT

One booking per buyer and idempotency key: a retried purchase returns the first booking and charges once.

**Owner:** both. The database refuses the second booking; the application returns the first one to the retrying client.

| Kept by | Names |
|---|---|
| Database | `constraint sales.booking.booking_booker_party_id_idempotency_key_key` |
| Application | `app.modules.sales.service:create_booking` |
| Database tests (`db/tests/run_tests.sql`) | - |
| API tests (`backend/`) | `tests/test_e2e.py::test_booking_paid_from_wallet_is_idempotent_and_balanced` |

## REFUND-WITHIN-PAYMENT

The refunds of a payment never exceed the amount paid.

**Owner:** both. The application checks first to answer clearly; the constraint refuses a concurrent second refund that passed the check.

| Kept by | Names |
|---|---|
| Database | `constraint fin.payment.payment_refund_within_amount` |
| Application | `app.modules.payments.service:refund` |
| Database tests (`db/tests/run_tests.sql`) | - |
| API tests (`backend/`) | `tests/test_payments.py::test_refund_goes_back_to_the_card` |

## REFUND-BY-FARE

A cancellation refunds what the fare brand allows, from escrow, and the allocation lines follow.

**Owner:** application. The amount depends on the brand, the time before departure and who sold the ticket, worked out in one request.

| Kept by | Names |
|---|---|
| Database | - |
| Application | `app.modules.sales.service:cancel_booking` |
| Database tests (`db/tests/run_tests.sql`) | - |
| API tests (`backend/`) | `tests/test_e2e.py::test_cancel_refund_follows_brand`<br>`tests/test_agency.py::test_cancellation_refunds_the_agency_and_keeps_commission_in_proportion` |

## ESCROW-UNTIL-TRIP

A passenger's money stays in escrow until the trip is completed, then goes to the allocation lines.

**Owner:** application. Completion is a decision of the carrier's staff; the application posts the release in the same transaction.

| Kept by | Names |
|---|---|
| Database | - |
| Application | `app.routers.carrier:complete_trip` |
| Database tests (`db/tests/run_tests.sql`) | - |
| API tests (`backend/`) | `tests/test_e2e.py::test_trip_completion_releases_escrow` |

## OPEN-PAY-OPTION

A booking uses only a way of paying that is open; the last open way cannot be closed, nor the provider an open way relies on switched off.

**Owner:** database. Options are switched by the platform while sales run; the triggers decide on the row being written.

| Kept by | Names |
|---|---|
| Database | `trigger sales.booking.b_booking_pay_option`<br>`trigger fin.payment_method.a_payment_method_rules` |
| Application | - |
| Database tests (`db/tests/run_tests.sql`) | Payment options: a booking cannot use a way of paying that is closed<br>Payment options: the last open way of paying cannot be closed<br>Payment options: the provider an open option relies on cannot be switched off |
| API tests (`backend/`) | `tests/test_payment_options.py::test_closed_option_refuses_bookings` |

## RESERVATION-PAY-BY

A reservation paid later always has a time to be paid by; when it passes unpaid the reservation expires and gives its seats back.

**Owner:** both. The database refuses a reservation without a time and expires due ones; the application's worker runs the expiry every minute.

| Kept by | Names |
|---|---|
| Database | `trigger sales.booking.b_booking_pay_option`<br>`function sales.expire_reservations` |
| Application | `app.modules.notify.worker:main`<br>`app.modules.sales.service:cancel_reserved` |
| Database tests (`db/tests/run_tests.sql`) | Payment options: a reservation always has a time to be paid by<br>Payment options: a reservation not paid in time expires and gives its seat back |
| API tests (`backend/`) | `tests/test_payment_options.py::test_unpaid_reservation_expires_and_frees_its_seats`<br>`tests/test_payment_options.py::test_open_reservations_are_limited_and_cancellable` |

## CASH-LIMIT

A carrier's counter stops selling for cash once the carrier owes its cash limit.

**Owner:** application. A sale writes a booking, tickets and postings; the application takes the carrier's lock and compares with fin.cash_limit before the first row.

| Kept by | Names |
|---|---|
| Database | `function fin.cash_limit` |
| Application | `app.modules.cash.service:_within_limit`<br>`app.modules.cash.service:_lock` |
| Database tests (`db/tests/run_tests.sql`) | Payment options: cash sold at a counter is owed by the carrier, within the default cash limit |
| API tests (`backend/`) | `tests/test_payment_options.py::test_credit_limit_stops_cash_sales` |

## REMITTANCE-FOUR-EYES

A cash remittance is recorded as pending; whoever recorded it does not decide it; a confirmed one carries its ledger posting and a decided one does not change.

**Owner:** both. The database holds the four-eyes rule and the posting link; the application posts the money when finance confirms.

| Kept by | Names |
|---|---|
| Database | `trigger fin.cash_remittance.a_cash_remittance_rules`<br>`constraint fin.cash_remittance.cash_remittance_confirmed` |
| Application | `app.modules.cash.service:decide_remittance` |
| Database tests (`db/tests/run_tests.sql`) | Payment options: a remittance is recorded as pending first<br>Payment options: whoever records a remittance does not confirm or reject it<br>Payment options: a confirmed remittance carries its ledger posting<br>Payment options: a decided remittance does not change |
| API tests (`backend/`) | `tests/test_payment_options.py::test_remittance_needs_a_second_person` |

## WITHDRAWAL-FOUR-EYES

Nobody approves their own withdrawal; above the limit two people approve; a paid withdrawal carries its posting.

**Owner:** both. The database refuses self-approval and a payment without its posting; the application counts approvers against the limit.

| Kept by | Names |
|---|---|
| Database | `trigger fin.withdrawal_request.withdrawal_transition`<br>`constraint fin.withdrawal_request.withdrawal_paid_ck`<br>`constraint fin.withdrawal_request.withdrawal_payer_ck` |
| Application | `app.modules.payouts.service:approve`<br>`app.modules.payouts.service:mark_paid` |
| Database tests (`db/tests/run_tests.sql`) | Payouts: the requester cannot approve their own withdrawal |
| API tests (`backend/`) | `tests/test_payouts.py::test_withdrawal_needs_two_approvers_above_the_limit_and_is_posted_when_paid` |

## LICENCE-DUAL-CONTROL

A locked licence changes only through an approved change request, which its requester cannot approve.

**Owner:** database. Licences decide whether a vehicle may run; the rule holds for screens, imports and console sessions alike.

| Kept by | Names |
|---|---|
| Database | `trigger fleet.license_record.license_locked`<br>`trigger fleet.license_change_request.license_change_four_eyes` |
| Application | - |
| Database tests (`db/tests/run_tests.sql`) | License: locked expiry cannot be edited directly<br>License: change applied only via approved dual-control request<br>License: requester cannot approve own change |
| API tests (`backend/`) | - |

## BREAK-GLASS

Break-glass access needs an approver unless declared an emergency, is time-bound, cannot be extended or deleted, and nobody approves or reviews their own.

**Owner:** database. It is the path around the normal controls, so its rules cannot depend on the code that uses it.

| Kept by | Names |
|---|---|
| Database | `trigger sec.break_glass_log.break_glass_rules`<br>`constraint sec.break_glass_log.break_glass_approved`<br>`constraint sec.break_glass_log.break_glass_window`<br>`constraint sec.break_glass_log.break_glass_reviewer` |
| Application | - |
| Database tests (`db/tests/run_tests.sql`) | Audit T3-03: break-glass needs an approver unless declared an emergency<br>Audit T3-03: nobody approves their own break-glass access<br>Audit T3-03: a break-glass grant cannot be extended<br>Audit T3-03: a break-glass record cannot be deleted<br>Audit T3-03: nobody reviews their own break-glass access |
| API tests (`backend/`) | - |

## AUDIT-APPEND-ONLY

Audit records are appended only and chained by hash; nobody edits or deletes them.

**Owner:** database. The audit trail must hold against the application itself; the triggers refuse changes and seal each record.

| Kept by | Names |
|---|---|
| Database | `trigger audit.row_change.row_change_immutable`<br>`trigger audit.row_change.row_change_hash`<br>`trigger audit.activity_log.activity_immutable`<br>`trigger audit.activity_log.activity_hash`<br>`trigger audit.auth_event.auth_event_immutable` |
| Application | - |
| Database tests (`db/tests/run_tests.sql`) | Audit: app role cannot modify activity log<br>Audit: activity log block sealed with hash chain<br>Audit R-09: the schema change log cannot be edited |
| API tests (`backend/`) | - |

## EINVOICE-GAPLESS

Finalising an e-invoice gives it the next number without a gap and chains its hash; a finalised invoice is not deleted.

**Owner:** database. Gapless numbers need the number and the row in one locked step, which only the finalising function can take.

| Kept by | Names |
|---|---|
| Database | `function acct.finalize_einvoice`<br>`trigger acct.einvoice_document.einvoice_guard` |
| Application | - |
| Database tests (`db/tests/run_tests.sql`) | E-invoice: finalize assigns gapless number<br>E-invoice: cannot be deleted |
| API tests (`backend/`) | - |

## TENANT-ISOLATION

A company never sees or writes another company's private rows, and a row never points at another company's row.

**Owner:** database. Row-level security and the same-company guards apply to every query, including ones the application did not foresee.

| Kept by | Names |
|---|---|
| Database | `trigger sales.booking.same_company_trip_id`<br>`function sys.tg_same_company` |
| Application | `app.db:apply_context` |
| Database tests (`db/tests/run_tests.sql`) | Tenant isolation sweep: carrier A sees no private row of carrier B in any table<br>Audit F-003: tenant guards are row-level, BEFORE INSERT OR UPDATE, enabled and not deferrable |
| API tests (`backend/`) | `tests/test_isolation.py::test_no_company_sees_another_companys_rows`<br>`tests/test_isolation.py::test_no_company_can_hand_its_rows_to_another_company` |

## SYSTEM-SCOPE-REVIEWED

The application steps outside the caller's row-level security only at reviewed places, each with its reason, and every entry is counted.

**Owner:** application. The system scope is a choice in the code; CI compares every use with the registry and the metric shows each one live.

| Kept by | Names |
|---|---|
| Database | - |
| Application | `app.db:system_scope` |
| Database tests (`db/tests/run_tests.sql`) | - |
| API tests (`backend/`) | `tests/test_code_rules.py::test_every_system_scope_use_is_reviewed`<br>`tests/test_code_rules.py::test_each_system_scope_use_is_counted_by_its_site` |

## DELETE-ONLY-WHERE-GRANTED

The application deletes only from the tables listed with a reason; business records are cancelled, closed or archived, never deleted.

**Owner:** both. The database grants DELETE on the listed tables only; CI checks that every delete in the code has its grant.

| Kept by | Names |
|---|---|
| Database | `table sys.app_delete_grant`<br>`function sys.enforce_app_delete_grants` |
| Application | `app.modular.engine:delete_row` |
| Database tests (`db/tests/run_tests.sql`) | Narrower grants: DELETE for the application on exactly the 36 listed tables<br>Narrower grants: the application cannot delete a business record, even one row-level security would show it |
| API tests (`backend/`) | `tests/test_code_rules.py::test_every_delete_in_the_code_has_its_grant` |

## RELEASE-MATCHES

An upgrade starts only when the record of applied schema files still matches the last release manifest.

**Owner:** database. The manifest and its hash live in the database being upgraded; db/upgrade.sh reads them before it applies anything.

| Kept by | Names |
|---|---|
| Database | `table sys.release_manifest`<br>`function sys.current_release`<br>`function sys.record_release` |
| Application | `app.release:current` |
| Database tests (`db/tests/run_tests.sql`) | Release manifest: a file removed from the record by hand no longer matches the manifest (the upgrade refuses)<br>Release manifest: the application reads the release and cannot record one |
| API tests (`backend/`) | - |
