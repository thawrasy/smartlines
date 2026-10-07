# Integrity audit: response to the strategic database review and its relationship audit register

The strategic review assessed the Analysis and Design Study v2.9 and the Database Design v3.3. Its audit register
classified all 1,304 relationships of version 3.3 and flagged 136 for review; the review itself raised 4 critical,
7 high and 5 medium findings. The register was built from the documents and says so: where executable behaviour was
not visible, a relationship was marked for verification rather than as a defect. This file records that verification
against the built database, what was changed and the test that proves it. The changes are in
`db/schema/1040_integrity_audit.sql` (migration 1.22.0), one change to the seat hold in
`backend/app/modules/sales/repository.py`, and the design document v3.4.

Verification on a fresh build: 209 database checks (`db/tests/run.sh`, 21 of them new) and 175 API tests
(`backend/tests`, 4 new in `test_integrity_audit.py`), all passing; the demo data seeds against the new rules.

## Why the proposed SQL was not applied as written

The register's proposed SQL was reconciled with the executable schema first, as the register itself asks. Applied
verbatim, three of its templates would have broken correct behaviour:

- **Vehicles are leased between companies** (`fleet.vehicle_lease`). A composite key `(vehicle_id, company_id)` on
  trips, incidents, inspections, fuel cards and loads would refuse every leased vehicle. The guard accepts the owner or
  a company with an active lease (`fleet.vehicle_usable_by`).
- **A scan of a ticket presented on the wrong trip is recorded on purpose** (`result = 'WRONG_TRIP'`): it is the
  evidence of a refused boarding. A composite key on `sales.boarding_event (ticket_id, trip_id)` would make that
  evidence impossible to keep. The guard refuses any other result for another trip's ticket.
- **A service partner is a company of its own.** In `ptn.fuel_session` and `ptn.partner_sale` the row's
  `company_id` is the carrier that pays and `partner_id` the station that sells; they differ by design.

Where every column is NOT NULL and there is one parent, the rule is a composite foreign key (it holds for COPY as for
INSERT and no trigger setting switches it off). Where the rule has an exception, or the parent may be a shared platform
row without a company, it is a trigger: row level, BEFORE INSERT OR UPDATE, enabled, not deferrable.

## Findings of the review

| # | Finding | Result | Evidence |
| --- | --- | --- | --- |
| C-01 | Seat lock source of truth | No in-memory lock exists: the hold is one atomic UPDATE of `ops.seat_segment`. The 1013 table comment that said otherwise was wrong and is corrected; `ops.seat_lock` is an audit trail. The hold now locks rows in a fixed seat and segment order | DB: "the seat hold has one record"; API: 36 overlapping requests, multi-seat holds in opposite orders |
| C-02 | KMS/HSM | Operational: plan phase 1, gate G1. The API already refuses to start without keys outside the sandbox (1039) | go-live checklist |
| C-03 | Cross-entity integrity | Composite keys for ticket/booking/trip, ticket/passenger/booking and seat/ticket/trip; guards for boarding scans, manifest persons, cargo legs, payment wallets and fare brands | one DB test per rule |
| C-04 | RLS and connection pooling | Already safe: `sys.set_context` uses transaction-local settings and every request is one transaction. Now proven | API: one physical connection serves A, nobody, B, a failing request, nobody; 200 interleaved requests |
| H-01 | References without a foreign key | 14 of the 25 polymorphic pairs are backed by real typed keys (1039); their comments now say so. The rest are integration mappings, event metadata (ledger and outbox references, whose truth is the entries and the aggregate) and append-only logs kept after the referenced row is gone | appendix C of the design |
| H-02 | Company wallet uniqueness | One COMPANY wallet per company and currency (`wallet_company_currency_uq`); cash and expense wallets stay per owner party | DB test |
| H-03 | v2.8 / v2.9 traceability | The design document still cited v2.8 in its introduction; regenerated as v3.4 against v2.9 | design v3.4 |
| H-04 | Capacity | Operational: load, stress, soak and spike tests in plan phase 4, gate G4 | go-live checklist |
| H-05 | Disaster recovery | Operational: restore and failover drills in plan phases 1, 4 and 6, followed by ledger reconciliation | go-live checklist |
| H-06 | Integration failure | Duplicate and replayed events are tested (1039); timeouts, partial success and wrong references are tested per adapter as each is connected (plan phase 3) | plan |
| H-07 | Dependency graph | `sys.v_schema_dependency`; the build fails when a new pair of schemas depends on each other outside the reviewed baseline of 21 pairs | DB test |
| M-01 | Database standards | `docs/database/STANDARDS.md` | |
| M-02 | JSONB policy | No policy, key or index uses a JSONB field (checked by the build); `sys.v_jsonb_inventory` lists every JSONB column | DB test |
| M-03 | Analytics isolation | Read replica for reports (1039); CDC and a warehouse when reporting load requires it | study 16.28 |
| M-04 | Concurrency testing | From 20 holds on one seat to overlapping segments, multi-seat holds in opposite orders and concurrent wallet bookings | API tests |
| M-05 | Migration governance | Migration checklist in `STANDARDS.md`; upgrade equals fresh build in CI | CI |

## Findings of the register

| # | Finding | Result |
| --- | --- | --- |
| F-001 | Seat segment trip equals ticket trip | Already refused by the 1039 seat guard; now also the composite key `seat_segment_ticket_trip_fk` |
| F-002 | Ticket, booking, passenger, trip | Composite keys `ticket_booking_trip_fk`, `ticket_passenger_booking_fk` |
| F-003 | Trigger-backed tenant invariants | All 79 present (`same_company_*`, 1039); every guard checked for shape; COPY tested |
| F-004 | Composite tenant references | 40 candidates: 27 tenant guards, 9 vehicle guards (ownership or lease), 3 open by design (service partners), 1 composite key (seat/ticket) |
| F-005 | 67 non-FK references | See H-01 |
| F-006 | Company wallet | See H-02 |
| F-007 | RLS and pooling | See C-04 |
| F-008 | Ledger adversarial tests | Mirror, reason, replay, direct write, multi-currency (1039); concurrent wallet bookings that reconcile (1040) |
| F-009 | DR and PITR | See H-05 |
| F-010 | Capacity | See H-04 |
| F-011 | JSONB | See M-02 |
| F-012 | Analytics | See M-03 |

## The 136 flagged relationships

The other 1,168 relationships were classified correct by the register and are unchanged. Classifications are the
register's, in English: Needs trigger, Needs composite FK, Dangerous, Needs verification.

| Audit ID | Child | Parent | Register | Severity | Disposition |
| --- | --- | --- | --- | --- | --- |
| FK-0013 | `iam.company_member.role_id` | `iam.role` | Needs trigger | High | Guard present: `same_company_role_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0038 | `iam.document.owner_incident_id` | `ops.incident` | Needs composite FK | High | Tenant guard `same_company_*` (1040); a shared platform row (no company) stays referable. |
| FK-0041 | `iam.document.owner_license_id` | `fleet.license_record` | Needs composite FK | High | Tenant guard `same_company_*` (1040); a shared platform row (no company) stays referable. |
| FK-0044 | `iam.document.owner_vehicle_id` | `fleet.vehicle` | Needs trigger | High | Guard present: `same_company_owner_vehicle_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0114 | `net.service_number.route_id` | `net.route` | Needs trigger | High | Guard present: `same_company_route_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0138 | `fleet.vehicle.seat_layout_id` | `fleet.seat_layout` | Needs trigger | High | Guard present: `same_company_seat_layout_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0144 | `fleet.seat_price_rule.seat_layout_id` | `fleet.seat_layout` | Needs trigger | High | Guard present: `same_company_seat_layout_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0145 | `fleet.seat_price_rule.vehicle_id` | `fleet.vehicle` | Needs trigger | High | Guard present: `same_company_vehicle_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0156 | `fleet.vehicle_service_status.incident_id` | `ops.incident` | Needs trigger | High | Guard present: `same_company_incident_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0159 | `fleet.vehicle_service_status.vehicle_id` | `fleet.vehicle` | Needs trigger | High | Guard present: `same_company_vehicle_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0166 | `fleet.insurance_claim.incident_id` | `ops.incident` | Needs trigger | High | Guard present: `same_company_incident_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0169 | `fleet.boarding_validator.vehicle_id` | `fleet.vehicle` | Needs trigger | High | Guard present: `same_company_vehicle_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0172 | `fleet.vehicle_fuel_profile.vehicle_id` | `fleet.vehicle` | Needs trigger | High | Guard present: `same_company_vehicle_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0176 | `fleet.driving_hours_log.party_id` | `fleet.crew_profile` | Needs composite FK | High | Tenant guard `same_company_*` keyed by `party_id` (1040). |
| FK-0177 | `fleet.driving_hours_log.trip_id` | `ops.trip` | Needs trigger | High | Guard present: `same_company_trip_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0180 | `fleet.license_record.document_id` | `iam.document` | Needs trigger | High | Guard present: `same_company_document_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0183 | `fleet.license_record.subject_partner_id` | `ptn.partner` | Needs composite FK | High | No guard, by design: a partner's licence describes the partner, a company of its own, not the carrier that records it. |
| FK-0185 | `fleet.license_record.subject_trailer_id` | `fleet.trailer` | Needs composite FK | High | Tenant guard `same_company_*` (1040); a shared platform row (no company) stays referable. |
| FK-0186 | `fleet.license_record.subject_vehicle_id` | `fleet.vehicle` | Needs trigger | High | Guard present: `same_company_subject_vehicle_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0200 | `fleet.truck_combination.driver_party_id` | `fleet.crew_profile` | Needs composite FK | High | Tenant guard `same_company_*` keyed by `party_id` (1040). |
| FK-0201 | `fleet.truck_combination.trailer_id` | `fleet.trailer` | Needs trigger | High | Guard present: `same_company_trailer_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0205 | `ops.trip_template.default_vehicle_id` | `fleet.vehicle` | Needs composite FK | High | Vehicle guard `vehicle_of_company_*` (1040): owned or actively leased. A same-company key would refuse leased vehicles. |
| FK-0206 | `ops.trip_template.route_id` | `net.route` | Needs trigger | High | Guard present: `same_company_route_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0207 | `ops.trip_template.service_number_id` | `net.service_number` | Needs trigger | High | Guard present: `same_company_service_number_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0212 | `ops.trip.route_id` | `net.route` | Needs trigger | High | Guard present: `same_company_route_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0213 | `ops.trip.service_number_id` | `net.service_number` | Needs trigger | High | Guard present: `same_company_service_number_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0214 | `ops.trip.template_id` | `ops.trip_template` | Needs trigger | High | Guard present: `same_company_template_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0216 | `ops.trip.vehicle_id` | `fleet.vehicle` | Needs composite FK | High | Vehicle guard `vehicle_of_company_*` (1040): owned or actively leased. A same-company key would refuse leased vehicles. |
| FK-0224 | `ops.seat_segment.ticket_id` | `sales.ticket` | Needs composite FK | High | Composite key `seat_segment_ticket_trip_fk` (1040) and the seat guard `seat_segment_guard` (1039). |
| FK-0225 | `ops.seat_segment.trip_id` | `ops.trip` | Needs verification | High | Composite key `seat_segment_ticket_trip_fk` (1040): a sold segment and its ticket share the trip. |
| FK-0254 | `ops.incident.trip_id` | `ops.trip` | Needs trigger | High | Guard present: `same_company_trip_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0255 | `ops.incident.vehicle_id` | `fleet.vehicle` | Needs composite FK | High | Vehicle guard `vehicle_of_company_*` (1040): owned or actively leased. A same-company key would refuse leased vehicles. |
| FK-0295 | `sales.subscription.family_offer_id` | `pricing.family_offer` | Needs composite FK | High | Tenant guard `same_company_*` (1040); a shared platform row (no company) stays referable. |
| FK-0298 | `sales.subscription.plan_id` | `sales.subscription_plan` | Needs trigger | High | Guard present: `same_company_plan_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0300 | `sales.subscription.wallet_id` | `fin.wallet` | Needs composite FK | High | Tenant guard `same_company_*` (1040); a shared platform row (no company) stays referable. |
| FK-0316 | `sales.booking.trip_id` | `ops.trip` | Needs trigger | High | Guard present: `same_company_trip_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0326 | `sales.ticket.booking_id` | `sales.booking` | Dangerous | Critical | Composite key `ticket_booking_trip_fk` (1040). |
| FK-0327 | `sales.ticket.fare_brand_code` | `pricing.fare_brand` | Dangerous | Critical | Fare brands are platform-wide or a carrier's own: guard `ticket_fare_brand` (1040). |
| FK-0328 | `sales.ticket.passenger_id` | `sales.passenger` | Dangerous | Critical | Composite key `ticket_passenger_booking_fk` (1040). |
| FK-0329 | `sales.ticket.qr_key_id` | `sec.key_registry` | Dangerous | Critical | No defect: a lookup of the encryption key registry, not tenant data; `active_key_only` (1039) refuses retired keys. |
| FK-0330 | `sales.ticket.trip_id` | `ops.trip` | Dangerous | Critical | Held by `ticket_booking_trip_fk` (1040): the ticket's trip is its booking's trip. |
| FK-0331 | `sales.ticket.trip_id, from_seq` | `ops.trip_stop` | Dangerous | Critical | No defect: already the composite key (trip_id, from_seq) to the trip's own stops. |
| FK-0332 | `sales.ticket.trip_id, to_seq` | `ops.trip_stop` | Dangerous | Critical | No defect: already the composite key (trip_id, to_seq) to the trip's own stops. |
| FK-0360 | `sales.inspection_check.trip_id` | `ops.trip` | Needs composite FK | High | Tenant guard `same_company_*` (1040); a shared platform row (no company) stays referable. |
| FK-0361 | `sales.inspection_check.vehicle_id` | `fleet.vehicle` | Needs composite FK | High | Vehicle guard `vehicle_of_company_*` (1040): owned or actively leased. A same-company key would refuse leased vehicles. |
| FK-0385 | `sales.channel_inventory_rule.route_id` | `net.route` | Needs trigger | High | Guard present: `same_company_route_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0406 | `pricing.fare_table.route_id` | `net.route` | Needs trigger | High | Guard present: `same_company_route_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0414 | `pricing.jurisdiction.parent_id` | `pricing.jurisdiction` | Needs trigger | Medium | Platform reference data (no company); guard `jurisdiction_tree` (1040) refuses loops. |
| FK-0477 | `pricing.award_seat_rule.route_id` | `net.route` | Needs trigger | High | Guard present: `same_company_route_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0486 | `fin.ledger_entry.wallet_id` | `fin.wallet` | Needs verification | High | No defect: one currency per transaction, wallets of that currency only, balanced at commit (1039). |
| FK-0493 | `fin.payment.booking_id` | `sales.booking` | Needs verification | High | Open by design: anyone may pay for a booking through a gateway (a parent, an agency). Money is protected by FK-0498. |
| FK-0496 | `fin.payment.payer_party_id` | `iam.party` | Needs verification | High | Guard `payment_wallet_owner` (1040): a payer draws only on their own wallet or their agency's. |
| FK-0498 | `fin.payment.wallet_id` | `fin.wallet` | Needs verification | High | Guard `payment_wallet_owner` (1040). |
| FK-0522 | `fin.withdrawal_request.wallet_id` | `fin.wallet` | Needs trigger | High | Guard present: `same_company_wallet_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0558 | `fin.payout.settlement_batch_id` | `fin.settlement_batch` | Needs trigger | High | Guard present: `same_company_settlement_batch_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0570 | `bill.company_subscription.agreement_id` | `bill.carrier_agreement` | Needs trigger | High | Guard present: `same_company_agreement_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0576 | `bill.carrier_invoice.einvoice_document_id` | `acct.einvoice_document` | Needs composite FK | High | Tenant guard `same_company_*` (1040); a shared platform row (no company) stays referable. |
| FK-0578 | `bill.carrier_invoice.subscription_id` | `bill.company_subscription` | Needs trigger | High | Guard present: `same_company_subscription_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0581 | `bill.billed_usage.invoice_id` | `bill.carrier_invoice` | Needs trigger | High | Guard present: `same_company_invoice_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0582 | `bill.billed_usage.subscription_id` | `bill.company_subscription` | Needs trigger | High | Guard present: `same_company_subscription_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0585 | `acct.gl_account.parent_id` | `acct.gl_account` | Needs trigger | High | Guard present: `same_company_parent_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0592 | `acct.journal_entry.reversed_by_id` | `acct.journal_entry` | Needs trigger | High | Guard present: `journal_guard,same_company_reversed_by_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0600 | `acct.cost_center.route_id` | `net.route` | Needs trigger | High | Guard present: `same_company_route_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0602 | `acct.cost_center.trip_id` | `ops.trip` | Needs trigger | High | Guard present: `same_company_trip_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0603 | `acct.tax_code.account_id` | `acct.gl_account` | Needs trigger | High | Guard present: `same_company_account_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0609 | `acct.sales_invoice.einvoice_document_id` | `acct.einvoice_document` | Needs trigger | High | Guard present: `same_company_einvoice_document_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0610 | `acct.sales_invoice.journal_entry_id` | `acct.journal_entry` | Needs trigger | High | Guard present: `same_company_journal_entry_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0611 | `acct.sales_invoice.source_booking_id` | `sales.booking` | Needs composite FK | High | Tenant guard `same_company_*` (1040); a shared platform row (no company) stays referable. |
| FK-0612 | `acct.sales_invoice.source_shipment_id` | `ship.shipment` | Needs composite FK | High | Tenant guard `same_company_*` (1040); a shared platform row (no company) stays referable. |
| FK-0613 | `acct.sales_invoice.source_subscription_id` | `sales.subscription` | Needs composite FK | High | Tenant guard `same_company_*` (1040); a shared platform row (no company) stays referable. |
| FK-0619 | `acct.credit_note.einvoice_document_id` | `acct.einvoice_document` | Needs trigger | High | Guard present: `same_company_einvoice_document_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0620 | `acct.credit_note.invoice_id` | `acct.sales_invoice` | Needs trigger | High | Guard present: `same_company_invoice_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0621 | `acct.cash_box.account_id` | `acct.gl_account` | Needs trigger | High | Guard present: `same_company_account_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0633 | `acct.cash_receipt.invoice_id` | `acct.sales_invoice` | Needs trigger | High | Guard present: `same_company_invoice_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0634 | `acct.cash_receipt.journal_entry_id` | `acct.journal_entry` | Needs trigger | High | Guard present: `same_company_journal_entry_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0636 | `acct.cash_receipt.wallet_id` | `fin.wallet` | Needs trigger | High | Guard present: `same_company_wallet_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0637 | `acct.cash_payment.account_id` | `acct.gl_account` | Needs trigger | High | Guard present: `same_company_account_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0643 | `acct.cash_payment.journal_entry_id` | `acct.journal_entry` | Needs trigger | High | Guard present: `same_company_journal_entry_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0645 | `acct.cash_payment.wallet_id` | `fin.wallet` | Needs trigger | High | Guard present: `same_company_wallet_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0655 | `acct.einvoice_document.original_doc_id` | `acct.einvoice_document` | Needs trigger | High | Guard present: `same_company_original_doc_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0658 | `acct.einvoice_document.source_booking_id` | `sales.booking` | Needs composite FK | High | Tenant guard `same_company_*` (1040); a shared platform row (no company) stays referable. |
| FK-0660 | `acct.einvoice_document.source_shipment_id` | `ship.shipment` | Needs composite FK | High | Tenant guard `same_company_*` (1040); a shared platform row (no company) stays referable. |
| FK-0661 | `acct.einvoice_document.source_subscription_id` | `sales.subscription` | Needs composite FK | High | Tenant guard `same_company_*` (1040); a shared platform row (no company) stays referable. |
| FK-0704 | `crm.case.booking_id` | `sales.booking` | Needs trigger | High | Guard present: `same_company_booking_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0708 | `crm.case.trip_id` | `ops.trip` | Needs trigger | High | Guard present: `same_company_trip_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0722 | `crm.trip_rating.trip_id` | `ops.trip` | Needs trigger | High | Guard present: `same_company_trip_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0724 | `crm.ai_conversation.escalated_case_id` | `crm.case` | Needs composite FK | High | Tenant guard `same_company_*` (1040); a shared platform row (no company) stays referable. |
| FK-0730 | `crm.call.ai_conversation_id` | `crm.ai_conversation` | Needs composite FK | High | Tenant guard `same_company_*` (1040); a shared platform row (no company) stays referable. |
| FK-0731 | `crm.call.case_id` | `crm.case` | Needs trigger | High | Guard present: `same_company_case_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0863 | `ptn.fuel_card.driver_party_id` | `fleet.crew_profile` | Needs composite FK | High | Tenant guard `same_company_*` keyed by `party_id` (1040). |
| FK-0864 | `ptn.fuel_card.vehicle_id` | `fleet.vehicle` | Needs composite FK | High | Vehicle guard `vehicle_of_company_*` (1040): owned or actively leased. A same-company key would refuse leased vehicles. |
| FK-0866 | `ptn.fuel_session.driver_party_id` | `fleet.crew_profile` | Needs composite FK | High | Tenant guard `same_company_*` keyed by `party_id` (1040). |
| FK-0867 | `ptn.fuel_session.fuel_card_id` | `ptn.fuel_card` | Needs composite FK | High | Tenant guard `same_company_*` (1040); a shared platform row (no company) stays referable. |
| FK-0868 | `ptn.fuel_session.partner_id` | `ptn.partner` | Needs composite FK | High | No guard, by design: a service partner is a company of its own (the station), the row's company is the paying carrier. |
| FK-0870 | `ptn.fuel_session.trip_id` | `ops.trip` | Needs composite FK | High | Tenant guard `same_company_*` (1040); a shared platform row (no company) stays referable. |
| FK-0871 | `ptn.fuel_session.vehicle_id` | `fleet.vehicle` | Needs composite FK | High | Vehicle guard `vehicle_of_company_*` (1040): owned or actively leased. A same-company key would refuse leased vehicles. |
| FK-0890 | `ptn.partner_sale.partner_id` | `ptn.partner` | Needs composite FK | High | No guard, by design: a service partner is a company of its own (the station), the row's company is the paying carrier. |
| FK-0891 | `ptn.partner_sale.session_id` | `ptn.fuel_session` | Needs composite FK | High | Tenant guard `same_company_*` (1040); a shared platform row (no company) stays referable. |
| FK-0892 | `ptn.partner_sale.trip_id` | `ops.trip` | Needs composite FK | High | Tenant guard `same_company_*` (1040); a shared platform row (no company) stays referable. |
| FK-0894 | `ptn.partner_sale.vehicle_id` | `fleet.vehicle` | Needs composite FK | High | Vehicle guard `vehicle_of_company_*` (1040): owned or actively leased. A same-company key would refuse leased vehicles. |
| FK-0917 | `ship.cargo_rate_card.route_id` | `net.route` | Needs trigger | High | Guard present: `same_company_route_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0931 | `ship.shipment.payer_account_id` | `ship.shipper_account` | Needs trigger | High | Guard present: `same_company_payer_account_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0933 | `ship.shipment.shipper_account_id` | `ship.shipper_account` | Needs trigger | High | Guard present: `same_company_shipper_account_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0946 | `ship.shipper_account.pricing_agreement_id` | `ship.pricing_agreement` | Needs trigger | High | Guard present: `same_company_pricing_agreement_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0947 | `ship.shipper_account.wallet_id` | `fin.wallet` | Needs trigger | High | Guard present: `same_company_wallet_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0948 | `ship.pricing_agreement.account_id` | `ship.shipper_account` | Needs trigger | High | Guard present: `same_company_account_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0958 | `ship.shipment_leg.trip_id` | `ops.trip` | Needs verification | High | Guard `leg_trip_carrier` (1040): a cargo leg rides a trip operated by its carrier. |
| FK-0985 | `ship.load.dest_hub_id` | `ship.hub` | Needs trigger | High | Guard present: `same_company_dest_hub_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0986 | `ship.load.origin_hub_id` | `ship.hub` | Needs trigger | High | Guard present: `same_company_origin_hub_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-0987 | `ship.load.trip_id` | `ops.trip` | Needs composite FK | High | Tenant guard `same_company_*` (1040); a shared platform row (no company) stays referable. |
| FK-0988 | `ship.load.truck_combination_id` | `fleet.truck_combination` | Needs composite FK | High | Tenant guard `same_company_*` (1040); a shared platform row (no company) stays referable. |
| FK-0989 | `ship.load.vehicle_id` | `fleet.vehicle` | Needs composite FK | High | Vehicle guard `vehicle_of_company_*` (1040): owned or actively leased. A same-company key would refuse leased vehicles. |
| FK-0996 | `ship.handling_unit.parent_unit_id` | `ship.handling_unit` | Needs trigger | High | Guard present: `same_company_parent_unit_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-1002 | `ship.courier_route.hub_id` | `ship.hub` | Needs trigger | High | Guard present: `same_company_hub_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-1003 | `ship.courier_route.vehicle_id` | `fleet.vehicle` | Needs composite FK | High | Vehicle guard `vehicle_of_company_*` (1040): owned or actively leased. A same-company key would refuse leased vehicles. |
| FK-1009 | `ship.pickup_request.courier_route_id` | `ship.courier_route` | Needs trigger | High | Guard present: `same_company_courier_route_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-1126 | `brd.manifest.supersedes_id` | `brd.manifest` | Needs trigger | Medium | Guard `manifest_chain` (1039): a version supersedes the previous one of the same crossing. |
| FK-1133 | `brd.manifest_person.manifest_id` | `brd.manifest` | Needs verification | High | Guard `manifest_person_trip` (1040). |
| FK-1137 | `brd.manifest_person.ticket_id` | `sales.ticket` | Needs verification | High | Guard `manifest_person_trip` (1040): a manifest lists only tickets of its own trip. |
| FK-1188 | `rail.coach_layout.fare_class_id` | `rail.fare_class` | Needs trigger | High | Guard present: `same_company_fare_class_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-1189 | `rail.coach_layout.seat_layout_id` | `fleet.seat_layout` | Needs composite FK | High | Tenant guard `same_company_*` (1040); a shared platform row (no company) stays referable. |
| FK-1202 | `taxi.taxi_permit.office_id` | `taxi.taxi_office` | Needs trigger | High | Guard present: `same_company_office_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-1203 | `taxi.taxi_permit.vehicle_id` | `fleet.vehicle` | Needs trigger | High | Guard present: `same_company_vehicle_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-1226 | `rent.rental_fleet.home_branch_id` | `rent.rental_branch` | Needs trigger | High | Guard present: `same_company_home_branch_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-1228 | `rent.rental_fleet.vehicle_id` | `fleet.vehicle` | Needs trigger | High | Guard present: `same_company_vehicle_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-1229 | `rent.rental_rate.branch_id` | `rent.rental_branch` | Needs trigger | High | Guard present: `same_company_branch_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-1239 | `rent.rental_booking.pickup_branch_id` | `rent.rental_branch` | Needs trigger | High | Guard present: `same_company_pickup_branch_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-1240 | `rent.rental_booking.rate_id` | `rent.rental_rate` | Needs trigger | High | Guard present: `same_company_rate_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-1243 | `rent.rental_booking.return_branch_id` | `rent.rental_branch` | Needs trigger | High | Guard present: `same_company_return_branch_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-1244 | `rent.rental_booking.vehicle_id` | `rent.rental_fleet` | Needs trigger | High | Guard present: `same_company_vehicle_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-1259 | `rent.telematics_device.vehicle_id` | `fleet.vehicle` | Needs trigger | High | Guard present: `same_company_vehicle_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-1265 | `rpt.report_run.api_client_id` | `iam.api_client` | Needs composite FK | High | Tenant guard `same_company_*` (1040); a shared platform row (no company) stays referable. |
| FK-1267 | `rpt.report_run.definition_id` | `rpt.report_definition` | Needs trigger | High | Guard present: `same_company_definition_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-1270 | `rpt.report_schedule.definition_id` | `rpt.report_definition` | Needs trigger | High | Guard present: `same_company_definition_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-1278 | `pricing.category_fare_rule.route_id` | `net.route` | Needs trigger | High | Guard present: `same_company_route_id` (1039). Covered by the trigger shape sweep and the COPY test. |
| FK-1281 | `pricing.family_offer.route_id` | `net.route` | Needs trigger | High | Guard present: `same_company_route_id` (1039). Covered by the trigger shape sweep and the COPY test. |

## Still operational, not code

Unchanged from the first review: provisioning the KMS or Vault and injecting the keys, load, stress, soak and spike tests
on production-sized hardware, backup, restore, PITR and failover drills with reconciliation afterwards, an independent
penetration test, and UAT with the founding carriers. Each has a gate in the pre-launch plan.
