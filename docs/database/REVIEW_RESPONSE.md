# Response to the Database Architecture Review v1.0

The review (Masslak_Database_Architecture_Review_AR_v1.0) assessed the Analysis and Design Study v2.8 and the Database
Design v3.2 without access to the repository. This file answers each finding against the built system: what already
existed, what was changed, and the automated test that proves it. The changes are in `db/schema/1039_review_hardening.sql`
(migration 1.21.0), the API, the study v2.9 (sections 16.27 and 16.28) and the design document v3.3.

A second, strategic review and its relationship audit register followed; `INTEGRITY_AUDIT.md` answers it (file 1040,
design v3.4).

Verification on a fresh build: 188 database checks (`db/tests/run.sh`, 47 of them new) and 171 API tests
(`backend/tests`, 7 new in `test_review_hardening.py`), all passing.

## Findings

| # | Finding | Before | Change | Evidence |
| --- | --- | --- | --- | --- |
| 3.1 P0 | No proof of the real build | SQL, tests and generators were in the repository, not in the review pack | `sys.v_security_inventory` (class, owner path, RLS, owner, privileges per table); `sys.table_class` refreshed by every build; design v3.3 regenerated from the built database | tests "every table has a data class", "every table has row-level security" |
| 3.2 P0 | 83 tables without RLS | 349 of 432 tables had RLS; sign-in tables, ledger, trip timetable rows and authority tables relied on grants | RLS on all 445 tables; data classes; reporting role loses access to restricted tables; RLS forced on credentials, factors, biometrics; sign-in in a narrow `AUTH` scope; anonymous sessions no longer see `iam.user_session` | isolation sweep over every table with a company column; "anonymous request reads no accounts"; "sign-in scope reads accounts and nothing else"; "application cannot switch row security off"; API test `test_sign_in_runs_in_the_narrow_auth_scope` |
| 3.3 P0 | Polymorphic references | (type, id) pairs on documents, verifications, screening, risk, authority orders | A real foreign key per type behind 14 pairs, set by a trigger, at most one per row (`sys.typed_reference`); free-text types closed by CHECK lists. Audit, outbox and ledger references stay metadata | "a document of a vehicle carries a real foreign key"; "cannot point to a vehicle that does not exist" |
| 3.4 P0 | Ownership not explicit | Policies inherited from parents | Every private table has an owner path in `sys.table_class`; 80 parent references checked to stay in one company (`TENANT_MISMATCH`) | "every private table has a documented owner path"; "a trip cannot run on another company's route" |
| 3.5 P0 | Ledger limits | Balanced per transaction at commit, one currency per transaction, immutable rows, unique idempotency key | Reversal mirrors the original (deferred), one reversal per transaction with a reason, no reversal of a reversal, posting batches with control totals, provider events post once (`source_event_id`), balance changes only through entries, daily reconciliation with an alert; the balance and integrity triggers now run as owner | tests for mirror, reason, replay, direct balance write, multi-currency, reconciliation |
| 3.6 P0 | Separate ledger database vs one database | The study mentioned a separate ledger in the growth phase | Decision: the ledger stays in schema `fin` of the same PostgreSQL database and is written in the booking's local transaction; a separate system only after a revisited decision with a saga (study 16.28) | study v2.9 16.28; design v3.3 |
| 3.7 P1 | Tracking retention strategy | Monthly partitions and functions existed, nothing ran them | `sys.run_maintenance()`: partitions three months ahead, positions dropped after `gov.data_inventory` retention unless a legal hold covers the dataset, expired holds released, ledger reconciled; worker runs it daily (`--maintenance` for cron) | "position partitions exist months ahead"; API test `test_daily_maintenance_reconciles_the_ledger` |
| 3.8 P1 | Seat model under failure | One row per seat and segment, atomic hold; the study still spoke of Redis | PostgreSQL declared the only seat record (study 16.28); a sold segment must match its ticket; a passenger may only take a free seat or free their own hold; `version` column; expired holds cleared | "a ticket only takes the segments it covers"; "a passenger cannot free a sold seat"; "only the sale marks a seat sold"; API test: 20 concurrent holds, one winner |
| 3.9 P1 | CHECK lists vs reference tables | Mixed | `sys.v_check_inventory` sorts every CHECK into lifecycle or business list; `ref.seed_version` records version, hash and approval of reference sets | views in the schema |
| 3.10 P1 | All phases in one database | Feature flags in the application only | Restrictive `module_gate` policy on every table of a phase schema: closed to all but the platform while its switch is off (`sys.module_gate`) | "a company reads nothing of a module that is off", "nor writes to it", "the platform still prepares it" |
| 3.11 P1 | ABAC | RBAC plus RLS | `iam.role_scope`, `iam.user_station_scope`, `sec.authority_scope`, `gov.data_purpose`; `sec.authorize()` records every restricted read with purpose, reason and policy version; used for authority manifest reads and payout IBAN reveals (`backend/app/policy.py`) | "a read without a reason is refused", "allowed and refused decisions are both recorded" |
| 3.12 P1 | Keys | Key references, rotation states, a development fallback | Key version and envelope fields, one active key per purpose and class, no new data under a non-active key, the API refuses to start outside the sandbox without real keys, `python -m app.tools.rekey` re-encrypts after rotation | "nothing new is encrypted under a decrypt-only key", "one active key per purpose"; API tests for the start guard and the rotation tool |
| 3.13 P1 | Operational vs analytical data | One pool | Optional read replica for reports (`MASSLAK_REPORTS_DATABASE_URL`); every report states `data_as_of`, source release, time zone and currency | API test `test_reports_say_what_moment_and_release_they_reflect` |
| 3.14 P1 | Semantic constraints | Several rules in the application only | Ownership ≤ 100%, lap infants per adult, infant date of birth, document per age band, stops in order, pair fares on existing stops, capacity within the vehicle, licence valid and line permit active at publication, permit activation inside validity, manifest version chain, delivery only to the route's authority, four-eyes before an authority delivery | one test per rule |
| 3.15 P1 | Retention and erasure | Erasure in the application | `gov.retention_policy`, `gov.legal_hold` (released by a second officer), retention columns on people and documents, `gov.erase_party()` pseudonymises, keeps financial, tax and manifest rows and refuses under a hold; the privacy console now uses it | "refused while a legal hold covers the person", "identity is gone, the bookings stay" |
| 3.16 P2 | MVP scope | — | Releases 1A, 1B, 2, 3 are mapped to module switches in `sys.module_gate`; dormant modules are closed at the database | `sys.module_gate` |

## Acceptance matrix (review section 6)

| Test | Where |
| --- | --- |
| Tenant isolation sweep | `db/tests/run_tests.sql` sweep; `backend/tests/test_isolation.py` |
| RLS bypass | runtime roles own nothing and cannot bypass; the application cannot disable RLS |
| Seat contention | `test_seat_contention_one_seat_one_winner` (20 parallel holds) |
| Redis loss | not applicable: no seat is held outside PostgreSQL |
| Payment replay | duplicate provider event; partner credit replay (`test_partner_credits_a_wallet_once`) |
| Payment reordering | provider notifications are idempotent per payment; the state machine refuses invalid transitions |
| Ledger imbalance | rejected at commit |
| Multi-currency | rejected |
| Refund crash | refunds post one balanced transaction; a reversal mirrors exactly once |
| Document access | refused and recorded without a reason |
| Authority scope | authority B never receives authority A's delivery |
| Manifest retry | version chain; delivery idempotent per manifest version and authority |
| License expiry race | publication refused when a licence ends before departure |
| Tracking burst | partitions ahead; retention by partition, never by row deletes |
| Restore | ledger reconciliation after restore (`fin.reconcile_wallets`); see operations below |
| Erasure request | pseudonymisation with financial rows kept |
| Migration rollback | each upgrade file runs in its own transaction and is idempotent (`db/upgrade.sh`) |
| Feature flag safety | module gate |
| API idempotency | booking replay returns the same booking (`test_booking_paid_from_wallet_is_idempotent_and_balanced`) |

## Decisions asked for (review section 8)

1. **Wallet:** the platform operates wallets through a licensed bank or wallet partner; it never holds customer money
   itself (float accounts are partner accounts).
2. **Ledger location:** schema `fin` in the same database, local transactions (study 16.28).
3. **MVP:** Release 1A (companies, fleet, stations, routes, trips, search and ticket, external or cash payment, basic
   audit, manual manifest), then 1B (licensed wallet, settlement, refunds, taxes, full RLS tests, driver app).
4. **Owners:** `sys.table_class` lists every table; the schema owner of each domain is the module owner in the study.
5. **Sources of truth:** booking and seats in `sales`/`ops`, payment in `fin.payment`, settlement in `fin.settlement_*`,
   accounting in `acct`, manifests in `brd` — all in one PostgreSQL database.
6. **Retention:** `gov.retention_policy` and `gov.data_inventory`; final periods by legal advisors per country pack.
7. **Authority data requests:** platform officers with `sec.authority_scope`, approved by a second officer.
8. **KMS/HSM, PITR and DR:** required before the pilot carries real personal or payment data.
9. **Internal wallet from day one:** no; external or cash payment first (Release 1A).
10. **API compatibility:** `/api/v1` is versioned; breaking changes go to `/api/v2` with a deprecation period.

## Still operational, not code

These cannot be closed inside the repository and stay on the go-live checklist: provisioning the KMS or Vault and
injecting the keys, a load, stress and soak test on production-sized hardware, a backup, restore and PITR drill with the
reconciliation run afterwards, an independent penetration test, and UAT with two or three carriers on two or three
routes.
