# Readiness audit by phase (October 2026)

Every launch phase of the Analysis and Design Study v3.2 (chapters 21 and 22) and the Database Design and ERD 3.11 was
checked against the built system: each table of a phase was looked for in the API code, in the module screens, and in
the database's own logic (triggers, functions, maintenance). This document records what was found, what schema files
1054 and 1055 (migrations 1.36.0 and 1.36.1) added, the payment options of schema file 1056 (migration 1.37.0), and what
still stands between the system and general launch.

## 1. Method

- Tables per phase come from `sys.table_phase` (481 tables).
- A table counts as **served** when the API reads or writes it: a bespoke endpoint or a module screen (`backend/app/modular/specs`).
- A table counts as **database-only** when only the database writes it (audit trails, closed ledger days, partitions).
- Anything else was a gap and is listed below with what was done about it.

## 2. Gaps found and closed (schema file 1054)

| Area | Phase | Gap before | Now |
|---|---|---|---|
| Complaints, inquiries, claims (7.6) | 1A | No endpoint and no screen; only a count on the regulator dashboard | Passengers open cases on their bookings, follow public replies and rate the answer (web and mobile). Staff handle cases in **Support cases**. The database sets references and service-level dates (`support.sla`), stamps the first response, keeps closed cases closed and hides internal notes from customers. Staff replies reach the customer in the app and by e-mail (`case.replied`). |
| Claims paid under four eyes | 1A/1B | Columns existed, nothing paid | A claim goes to finance with an approved amount and the liable party; the decision is recorded; finance pays it from the carrier's or the platform's wallet; the payer cannot be the approver (API and database). |
| Trip ratings | 1A | No way to rate | Only the traveller or buyer, only after travelling, once per ticket; staff can hide a rating. |
| Trip templates (4.13) | 1A | Every departure created by hand | A recurring template generates the trips of a date range in one step; generating again adds nothing (unique template and departure). |
| Pricing setup (5.6 to 5.8) | 1A/1B | Tax, commission, allocation, cancellation and fare tables had no screen | **Pricing setup** module; schemes and templates are activated by a second person. |
| Loyalty (5.12) | 1B | Programme, tiers and rules had no screen | **Loyalty programme** module; members see their own points. |
| Fleet records | 1A/1B | Insurance, leases, licence changes, seat prices, disruptions, inspections had no screen | **Fleet and trip records** module; licence changes go requester, reviewer, approver (three people, database-enforced). |
| Security console (16.x) | 1A/1B | Blocklist was never consulted; fraud cases, alarms, logs, access reviews, authority requests had no screen | Registration and sign-in refuse blocklisted e-mails, phones and devices (digests only); **Security console** module; authority data requests approved by a second person. |
| Finance controls (6, 13) | 1B | General ledger, tax returns, treasury, closed ledger days had no screen | **Finance controls** module (read-only where the system writes). |
| Data governance (16.13, 16.24) | 1A | Retention, legal holds, privacy incidents, obligations had no screen | **Data governance** module. |
| Reference data | 1A | Currencies, rates and catalogues edited only by schema files | **Reference data** module. |
| School transport (21.3) | SCH | Whole phase: database only | **School transport** module for the platform, operators and guardians: guardians give or refuse consent and report absences (and change nothing else, database-enforced); the operator records attendance and the empty-bus check. |
| Row ownership | 1A | A partner company could edit another carrier's disruption; companies could change who bears a passenger's compensation | Disruptions are written only by the trip's carrier; compensation only by the platform (found by the isolation sweep once the tables had data). |
| Contact centre and AI phase (CS) | CS | The 2.8 feature flags shipped `ai_assistant` on, which opened the whole phase on a fresh install, against launch gate 9 | Schema file 1055 switches both CS switches off unless an approved data protection review exists, and refuses to switch them on before one is recorded with its DPIA file and approver |

## 2a. Payment options (schema file 1056)

Owner decision, October 2026: release 1 must not depend on e-wallet or card providers, which are still scarce in Syria.
Platform administration now opens and closes each way of paying a booking: the wallet, an agency's prepaid balance, cash
at the carrier's counter, reserve online and pay cash at the counter, and (once a provider is contracted) card, instalment
and financing payments. Counter cash is owed by the carrier within a credit limit, set off against its earnings and
remitted under four eyes. Details in [PAYMENT_OPTIONS.md](PAYMENT_OPTIONS.md).

## 3. Coverage after 1054

| Phase | Tables | Served by the API | Database-only | Left without a screen (reason) |
|---|---:|---:|---:|---|
| 1A core booking | 147 | 124 | 12 | 11: platform internals (`sys.schema_file`, `sys.company_setting`, `iam.auth_token`, `iam.identity_provider`, `iam.role_scope`, device permission states, `ops.seat_lock` audit trail, family zones) and the policy matrix tables, which are read through `gov.policy_*` functions |
| 1B money and operations | 111 | 99 | 3 | 9: e-invoicing templates, units, tax profiles and the tax authority catalogue (waiting for the tax authority's e-invoicing specification), authority policy and scope |
| ERP connectors | 5 | 2 | 2 | 1: account mapping (configured per connector) |
| 2 shuttle | 26 | 24 | 0 | 2: proximity samples and standing segments (written by the boarding validators) |
| 3 shipments | 59 | 59 | 0 | 0 |
| 4 international | 8 | 8 | 0 | 0 |
| 5 government integration | 6 | 5 | 0 | 1: government identity links (filled by the adapters) |
| 6 border systems | 2 | 0 | 0 | 2: manifest submissions and biometric templates (depend on the border authorities' interfaces) |
| 7 tracking and stations | 5 | 4 | 0 | 1: permission events (device telemetry) |
| 8 trucks and transit | 15 | 15 | 0 | 0 |
| 9 intermediaries | 33 | 31 | 0 | 2: fuel profiles, redemption tokens (partner integrations) |
| 10 to 14 | 38 | 38 | 0 | 0 |
| SCH school transport | 11 | 11 | 0 | 0 |
| CS contact centre and AI | 14 | 10 | 0 | 4: AI conversations, messages, tools, policies (launch gate 9: DPIA and threat model sign-off first) |

## 4. Tests

- Database checks: 399 (schema file 1054 adds 22, 1055 adds 4, 1056 adds 17, review stage A adds 1, stage B 5).
- API and unit tests: 317 on a fresh database (`backend/tests/test_launch.py` adds 6, `test_payment_options.py` 14,
  `test_review_stage_a.py` 10, stage B `test_ssrf.py` 48, `test_review_stage_b.py` 8, `test_launch_gates_kit.py` 9), plus the module
  sweep that opens every screen of every portal and the isolation sweeps over every company column.
- Mobile: typecheck and unit tests; web: typecheck and production build.
- Upgrade: a populated 1.35.0 database upgrades to 1.36.0 with every wallet reconciled; a used 1.36.1 database upgrades to
  1.37.0, applies nothing on a second run, and passes the booking, agency, payment, payout and payment-option tests.

## 5. What still stands between the system and general launch

The code defects confirmed by the expert review of October 2026 are closed by stage A
([REVIEW_STAGE_A.md](REVIEW_STAGE_A.md)): signing keys checked at start, top-up replays scoped to the payer, an update
script that stops on unsettled code, encrypted backups required in production, schema drift refused, a readiness
endpoint, time limits on the database role, and generated README figures. Stage B
([REVIEW_STAGE_B.md](REVIEW_STAGE_B.md)) adds the tools that run and judge the launch gates (booking burst, soak,
`launch_gates.py`), report freshness limits, cash ageing and the SSRF tests, and fixes the two defects they found.

The code of releases 1A and 1B is complete. General launch waits on the nine operational gates of
[LAUNCH_GATES.md](LAUNCH_GATES.md), all of which need people and environments outside the code: recovery drill on staging,
the production egress allowlist, capacity at 1x, 2x and 5x on staging hardware, migration rehearsal on a production-size
copy, monitoring with an on-call rota, the audit archive bucket with object lock, ClamAV in production, the external
penetration test, and (for the AI phase only) the DPIA sign-off. Commercial and legal prerequisites (bank agreements,
SMS sender registration, carrier contracts, data-protection registration; a payment provider only for the electronic
options, since cash at the counter needs none) are in
[INFRASTRUCTURE_REQUIREMENTS.md](INFRASTRUCTURE_REQUIREMENTS.md) and [STAFFING.md](STAFFING.md).

The currency was redenominated on 1 January 2026 (100 old pounds = 1 new pound, ISO code unchanged). Amounts in the
platform are stored in minor units of SYP; fares and demo data must be entered in new pounds before launch.
