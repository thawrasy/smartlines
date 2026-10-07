-- =====================================================================
-- 1041: the database divided by project phase (study v2.9 section 22, roadmap phases 0 to 15)
--   The database stays one PostgreSQL database built from one chain of files (study decision D-6, review 3.10):
--   splitting it physically would add cross-database transactions to the booking and money paths. The split is
--   logical and checked: every table belongs to the phase that brings it into use, and a table never needs a row of
--   a later phase. A column of an earlier table may point to a later one only if it is optional: these are the
--   readiness columns the study builds in Phase 1 so later phases need no rebuilding (decision 88).
--
--   A  The phases and the release split of Phase 1 (1A before 1B, as the architecture review decided)
--   B  The phase of every table, with its module (the ERD group of the design document)
--   C  Views: tables per phase, and references that point to a later phase
--   D  Module switches carry the study's phase numbers
--   db/tests checks that every table has a phase and that no required reference points to a later phase.
-- =====================================================================

-- =====================================================================
-- A  Phases
-- =====================================================================
CREATE TABLE IF NOT EXISTS sys.project_phase (
  code        text PRIMARY KEY,
  ordinal     numeric(4,1) NOT NULL UNIQUE,
  name        text NOT NULL,
  study_ref   text NOT NULL,
  scope       text NOT NULL
);
COMMENT ON TABLE sys.project_phase IS 'Project phases of the study roadmap (22); Phase 1 split into releases 1A and 1B (review decision 3)';

INSERT INTO sys.project_phase (code, ordinal, name, study_ref, scope) VALUES
  ('1A',  1.0, 'Release 1A: core booking', '22.2 a-c, review decision 3',
   'Companies, users and permissions, fleet and seats, stations, routes and trips, search, seat holds, bookings and tickets, external or cash payment, the price allocation of every sale, promo codes, notifications and cases, audit and governance, manual manifests'),
  ('1B',  1.5, 'Release 1B: money and operations', '22.2 c-e, review decision 3',
   'Licensed wallet partner, top-ups, refunds, settlement and payouts, taxes and e-invoicing, simplified accounting, carrier billing, core loyalty, family accounts, driver app operations (stop events, delays, incidents, SOS), routed manifests and authority requests, reports'),
  ('ERP', 1.8, 'Accounting connectors', '22 (ERP connectors), 13.10', 'Odoo, Zoho and Al-Ameen first, then Microsoft, SAP and Oracle on request; file export ships with 1B'),
  ('2',   2.0, 'Phase 2: shuttle', '7.13, 4.15', 'Approved lines and tariffs, shuttle rides, subscriptions and passes, QR and NFC validators, standing capacity, the AI assistant and the contact center'),
  ('3',   3.0, 'Phase 3: shipments and consignments', '9', 'Parcels, cargo capacity, B2B booking, COD, courier companies, sorting hubs, local truck loads, unified tracking, shipping partners'),
  ('4',   4.0, 'Phase 4: international', '11, 4.10', 'Border points, travel documents and entry rules, security screening and watchlists, exchange rates'),
  ('5',   5.0, 'Phase 5: government integration', '8, 14.2', 'Government identity links, automatic verification, adapters to government systems, authority alerts'),
  ('6',   6.0, 'Phase 6: border systems', '11', 'Manifest submission to border systems, biometrics'),
  ('7',   7.0, 'Phase 7: tracking and stations', '7.8, 4.11', 'GPS tracking, tracking alerts and route adherence, station gates and displays, geofences'),
  ('8',   8.0, 'Phase 8: trucks and transit', '10', 'Freight requests, bids and contracts, containers, ports, transit declarations, escorts, freight claims, cargo manifests'),
  ('9',   9.0, 'Phase 9: intermediary platforms and partners', '14.7-14.11, 5.13', 'Distribution channels and their statements, fuel and rest-stop partners, loyalty partners and rewards, card and sponsor campaigns'),
  ('10', 10.0, 'Phase 10: rail', '14.8', 'Fare classes, coaches, train compositions and through journeys'),
  ('11', 11.0, 'Phase 11: taxi', '21.1', 'Taxi offices, permits, meters, shifts, requests and dispatch'),
  ('12', 12.0, 'Phase 12: car rental', '21.2', 'Rental companies, branches, fleet, rates, bookings, contracts, deposits and telematics'),
  ('13', 13.0, 'Phase 13: transit passengers', 'D.1', 'Transit corridors, approved rest stops, crossing plans, crossing events and head-count reconciliation'),
  ('14', 14.0, 'Phase 14: contracted transport', 'D.2', 'Contracts with schools, universities and employers, their routes, riders, receivers, attendance and invoices'),
  ('15', 15.0, 'Phase 15: transit trucks', 'D.3', 'Cargo categories with hazard and refrigeration flags; no table of its own')
ON CONFLICT (code) DO UPDATE SET ordinal = EXCLUDED.ordinal, name = EXCLUDED.name, study_ref = EXCLUDED.study_ref, scope = EXCLUDED.scope;

-- =====================================================================
-- B  The phase of every table
-- =====================================================================
CREATE TABLE IF NOT EXISTS sys.table_phase (
  table_name  text PRIMARY KEY,
  phase_code  text NOT NULL REFERENCES sys.project_phase (code),
  module      text NOT NULL CHECK (module ~ '^E[0-9]{2}$')
);
CREATE INDEX IF NOT EXISTS table_phase_phase_code_fkx ON sys.table_phase (phase_code);
COMMENT ON TABLE sys.table_phase IS 'The phase that brings each table into use, and its module (ERD group of the design document)';
COMMENT ON COLUMN sys.table_phase.table_name IS 'No FK: schema-qualified name of a catalog table, checked by db/tests';

INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES
  -- 1A: 136 tables
  ('audit.activity_log','1A','E25'), ('audit.auth_event','1A','E25'), ('audit.data_access_log','1A','E25'),
  ('audit.log_seal','1A','E25'), ('audit.row_change','1A','E25'), ('brd.manifest','1A','E34'),
  ('brd.manifest_person','1A','E34'), ('brd.manifest_vehicle','1A','E34'), ('crm.case','1A','E22'),
  ('crm.case_event','1A','E22'), ('crm.notification','1A','E22'), ('crm.notification_template','1A','E22'),
  ('crm.trip_rating','1A','E22'), ('fin.cash_remittance','1A','E16'), ('fin.ledger_entry','1A','E16'),
  ('fin.ledger_txn','1A','E16'), ('fin.payment','1A','E16'), ('fin.payment_notification','1A','E16'),
  ('fin.payment_provider','1A','E16'), ('fin.posting_batch','1A','E16'), ('fin.price_allocation','1A','E17'),
  ('fin.price_allocation_line','1A','E17'), ('fin.wallet','1A','E16'), ('fin.wallet_reconciliation','1A','E16'),
  ('fleet.crew_profile','1A','E07'), ('fleet.insurance_policy','1A','E06'),
  ('fleet.license_change_request','1A','E07'), ('fleet.license_record','1A','E07'), ('fleet.seat_layout','1A','E06'),
  ('fleet.seat_layout_seat','1A','E06'), ('fleet.seat_price_rule','1A','E06'), ('fleet.vehicle','1A','E06'),
  ('fleet.vehicle_lease','1A','E06'), ('fleet.vehicle_service_status','1A','E06'),
  ('fleet.vehicle_status_history','1A','E06'), ('gov.consent','1A','E26'), ('gov.data_inventory','1A','E26'),
  ('gov.data_purpose','1A','E26'), ('gov.erasure_log','1A','E26'), ('gov.feature_compliance_review','1A','E26'),
  ('gov.legal_hold','1A','E26'), ('gov.obligation_register','1A','E26'), ('gov.policy_authority','1A','E26'),
  ('gov.policy_change','1A','E26'), ('gov.policy_domain','1A','E26'), ('gov.privacy_incident','1A','E26'),
  ('gov.retention_policy','1A','E26'), ('gov.subject_request','1A','E26'), ('iam.app_user','1A','E01'),
  ('iam.auth_token','1A','E02'), ('iam.beneficial_owner','1A','E01'), ('iam.company','1A','E01'),
  ('iam.company_member','1A','E01'), ('iam.device','1A','E02'), ('iam.device_permission_state','1A','E02'),
  ('iam.document','1A','E01'), ('iam.identity_provider','1A','E02'), ('iam.mfa_factor','1A','E02'),
  ('iam.party','1A','E01'), ('iam.party_role','1A','E01'), ('iam.permission','1A','E01'),
  ('iam.push_token','1A','E02'), ('iam.role','1A','E01'), ('iam.role_permission','1A','E01'),
  ('iam.role_scope','1A','E01'), ('iam.user_role','1A','E01'), ('iam.user_session','1A','E02'),
  ('iam.user_station_scope','1A','E01'), ('iam.verification','1A','E01'), ('net.carrier_code','1A','E04'),
  ('net.code_reservation','1A','E04'), ('net.compliance_profile','1A','E04'), ('net.route','1A','E04'),
  ('net.route_stop','1A','E04'), ('net.service_number','1A','E04'), ('net.station','1A','E04'),
  ('net.station_contact','1A','E04'), ('ops.crew_assignment','1A','E08'), ('ops.family_zone','1A','E08'),
  ('ops.seat_lock','1A','E08'), ('ops.seat_segment','1A','E08'), ('ops.trip','1A','E08'),
  ('ops.trip_change','1A','E08'), ('ops.trip_pair_fare','1A','E08'), ('ops.trip_stop','1A','E08'),
  ('ops.trip_template','1A','E08'), ('ops.vehicle_swap','1A','E08'), ('pricing.allocation_template','1A','E13'),
  ('pricing.allocation_template_line','1A','E13'), ('pricing.campaign','1A','E14'),
  ('pricing.cancellation_policy','1A','E13'), ('pricing.category_fare_rule','1A','E39'),
  ('pricing.commission_rule','1A','E13'), ('pricing.commission_scheme','1A','E13'),
  ('pricing.fare_brand','1A','E13'), ('pricing.fare_table','1A','E13'), ('pricing.fare_table_item','1A','E13'),
  ('pricing.override_policy','1A','E14'), ('pricing.passenger_age_band','1A','E39'),
  ('pricing.pricing_modifier','1A','E13'), ('pricing.promo_code','1A','E14'), ('ref.city','1A','E03'),
  ('ref.country','1A','E03'), ('ref.currency','1A','E03'), ('ref.file_object','1A','E03'), ('ref.locale','1A','E03'),
  ('ref.party_role_type','1A','E01'), ('ref.seed_version','1A','E03'), ('ref.station_subtype','1A','E03'),
  ('ref.translation','1A','E03'), ('ref.trip_type','1A','E03'), ('ref.vehicle_class','1A','E03'),
  ('sales.boarding_event','1A','E11'), ('sales.booking','1A','E11'), ('sales.campaign_redemption','1A','E11'),
  ('sales.channel','1A','E12'), ('sales.passenger','1A','E11'), ('sales.ticket','1A','E11'),
  ('sales.waitlist_entry','1A','E11'), ('sec.access_review','1A','E25'), ('sec.blocklist_entry','1A','E25'),
  ('sec.break_glass_log','1A','E25'), ('sec.ip_rule','1A','E25'), ('sec.key_registry','1A','E25'),
  ('sec.policy_decision','1A','E25'), ('sec.security_event','1A','E25'), ('sec.tamper_event','1A','E25'),
  ('sys.company_setting','1A','E03'), ('sys.module_gate','1A','E03'), ('sys.outbox_event','1A','E03'),
  ('sys.project_phase','1A','E03'), ('sys.schema_file','1A','E03'), ('sys.schema_migration','1A','E03'),
  ('sys.setting','1A','E03'), ('sys.table_class','1A','E03'), ('sys.table_phase','1A','E03'),
  -- 1B: 104 tables
  ('acct.cash_box','1B','E19'), ('acct.cash_payment','1B','E19'), ('acct.cash_receipt','1B','E19'),
  ('acct.cash_session','1B','E19'), ('acct.cost_center','1B','E19'), ('acct.credit_note','1B','E19'),
  ('acct.einvoice_activation','1B','E20'), ('acct.einvoice_document','1B','E20'), ('acct.einvoice_line','1B','E20'),
  ('acct.einvoice_submission','1B','E20'), ('acct.einvoice_template','1B','E20'), ('acct.einvoice_unit','1B','E20'),
  ('acct.export_batch','1B','E21'), ('acct.gl_account','1B','E19'), ('acct.gl_period','1B','E19'),
  ('acct.journal_entry','1B','E19'), ('acct.journal_line','1B','E19'), ('acct.posting_rule','1B','E19'),
  ('acct.sales_invoice','1B','E19'), ('acct.sales_invoice_line','1B','E19'), ('acct.tax_authority','1B','E20'),
  ('acct.tax_code','1B','E19'), ('acct.tax_collection_no_file','1B','E20'), ('acct.tax_payment','1B','E20'),
  ('acct.tax_profile','1B','E20'), ('acct.tax_profile_field','1B','E20'), ('acct.tax_profile_value','1B','E20'),
  ('acct.tax_registration','1B','E20'), ('acct.tax_return','1B','E20'), ('acct.tax_return_line','1B','E20'),
  ('bill.billed_usage','1B','E18'), ('bill.carrier_agreement','1B','E18'), ('bill.carrier_invoice','1B','E18'),
  ('bill.carrier_invoice_line','1B','E18'), ('bill.company_subscription','1B','E18'), ('bill.plan','1B','E18'),
  ('bill.usage_event','1B','E18'), ('brd.manifest_delivery','1B','E34'), ('brd.manifest_discrepancy','1B','E34'),
  ('brd.manifest_response','1B','E34'), ('brd.manifest_route','1B','E34'), ('fin.bank_reconciliation','1B','E17'),
  ('fin.bank_statement_import','1B','E16'), ('fin.bank_statement_line','1B','E16'),
  ('fin.bank_transfer_topup','1B','E16'), ('fin.deposit_placement','1B','E17'), ('fin.float_account','1B','E17'),
  ('fin.float_report','1B','E17'), ('fin.payment_refund','1B','E16'), ('fin.payout','1B','E17'),
  ('fin.payout_schedule','1B','E17'), ('fin.settlement_batch','1B','E17'), ('fin.settlement_line','1B','E17'),
  ('fin.tax_ledger','1B','E17'), ('fin.withdrawal_request','1B','E16'), ('fleet.driving_hours_log','1B','E07'),
  ('fleet.field_check_log','1B','E07'), ('fleet.insurance_claim','1B','E06'), ('gov.partner_dpa','1B','E26'),
  ('iam.api_client','1B','E02'), ('iam.api_key','1B','E02'), ('iam.api_usage_daily','1B','E02'),
  ('iam.bank_account','1B','E01'), ('iam.family','1B','E39'), ('iam.family_link_request','1B','E39'),
  ('iam.family_member','1B','E39'), ('iam.family_spend','1B','E39'), ('iam.family_travel_rule','1B','E39'),
  ('ops.driver_notice','1B','E09'), ('ops.incident','1B','E09'), ('ops.incident_evidence','1B','E09'),
  ('ops.trip_delay','1B','E08'), ('ops.trip_disruption','1B','E09'), ('ops.trip_stop_event','1B','E08'),
  ('pricing.award_seat_rule','1B','E15'), ('pricing.family_offer','1B','E39'), ('pricing.jurisdiction','1B','E13'),
  ('pricing.loyalty_program','1B','E15'), ('pricing.loyalty_rule','1B','E15'), ('pricing.loyalty_tier','1B','E15'),
  ('pricing.points_account','1B','E15'), ('pricing.points_ledger','1B','E15'),
  ('pricing.points_liability','1B','E15'), ('pricing.rate_band','1B','E13'), ('pricing.tax_rule','1B','E13'),
  ('pricing.tax_scheme','1B','E13'), ('rpt.report_definition','1B','E38'), ('rpt.report_run','1B','E38'),
  ('rpt.report_schedule','1B','E38'), ('sales.agency_agreement','1B','E12'), ('sales.inspection_check','1B','E11'),
  ('sales.passenger_compensation','1B','E11'), ('sales.refund_request','1B','E11'),
  ('sec.authority_data_request','1B','E24'), ('sec.authority_order','1B','E24'), ('sec.authority_policy','1B','E24'),
  ('sec.authority_profile','1B','E24'), ('sec.authority_scope','1B','E24'), ('sec.document_signature','1B','E25'),
  ('sec.fraud_case','1B','E25'), ('sec.risk_assessment','1B','E25'), ('sec.sos_event','1B','E24'),
  ('sys.webhook_delivery','1B','E03'), ('sys.webhook_endpoint','1B','E03'),
  -- ERP: 5 tables
  ('acct.account_mapping','ERP','E21'), ('acct.accounting_connection','ERP','E21'),
  ('acct.sync_conflict','ERP','E21'), ('acct.sync_item','ERP','E21'), ('acct.sync_job','ERP','E21'),
  -- 2: 34 tables
  ('crm.ai_conversation','2','E22'), ('crm.ai_eval_case','2','E22'), ('crm.ai_message','2','E22'),
  ('crm.ai_policy','2','E22'), ('crm.ai_tool_call','2','E22'), ('crm.call','2','E23'), ('crm.call_agent','2','E23'),
  ('crm.call_agent_skill','2','E23'), ('crm.call_event','2','E23'), ('crm.call_qa','2','E23'),
  ('crm.call_queue','2','E23'), ('crm.call_queue_skill','2','E23'), ('crm.call_skill','2','E23'),
  ('crm.callback_request','2','E23'), ('fleet.boarding_validator','2','E06'), ('fleet.vehicle_qr_tag','2','E06'),
  ('net.line','2','E05'), ('net.line_fare','2','E05'), ('net.line_permit','2','E05'), ('net.line_stop','2','E05'),
  ('net.line_tariff','2','E05'), ('net.line_version','2','E05'), ('net.line_version_approval','2','E05'),
  ('net.timetable_template','2','E05'), ('ops.presence_beacon','2','E10'), ('ops.proximity_sample','2','E10'),
  ('ops.ride_segment_charge','2','E10'), ('ops.shuttle_ride','2','E10'), ('ops.standing_segment','2','E08'),
  ('sales.nfc_card','2','E10'), ('sales.shuttle_pass','2','E10'), ('sales.shuttle_zone','2','E10'),
  ('sales.subscription','2','E10'), ('sales.subscription_plan','2','E10'),
  -- 3: 59 tables
  ('fleet.trailer','3','E07'), ('fleet.truck_combination','3','E07'), ('fleet.truck_unit','3','E07'),
  ('ref.cargo_category','3','E03'), ('ship.access_point','3','E30'), ('ship.address','3','E29'),
  ('ship.capacity_booking','3','E29'), ('ship.cargo_claim','3','E31'), ('ship.cargo_rate_card','3','E28'),
  ('ship.carrier_scorecard','3','E31'), ('ship.cod_collection','3','E31'), ('ship.courier_assignment','3','E30'),
  ('ship.courier_route','3','E30'), ('ship.custody_transfer','3','E29'), ('ship.delivery_attempt','3','E31'),
  ('ship.delivery_preference','3','E31'), ('ship.delivery_proof','3','E31'), ('ship.fuel_surcharge_index','3','E28'),
  ('ship.geo_zone','3','E28'), ('ship.guarantee_claim','3','E31'), ('ship.handling_unit','3','E30'),
  ('ship.handling_unit_item','3','E30'), ('ship.hub','3','E30'), ('ship.integration_message','3','E32'),
  ('ship.integration_partner','3','E32'), ('ship.linehaul_schedule','3','E30'), ('ship.load','3','E30'),
  ('ship.load_plan','3','E30'), ('ship.load_stop','3','E30'), ('ship.locker_compartment','3','E30'),
  ('ship.parcel','3','E29'), ('ship.partner_command','3','E32'), ('ship.partner_contract','3','E32'),
  ('ship.partner_pre_alert','3','E32'), ('ship.partner_reconciliation','3','E32'),
  ('ship.partner_settlement','3','E32'), ('ship.partner_status_map','3','E32'), ('ship.pickup_request','3','E30'),
  ('ship.pricing_agreement','3','E29'), ('ship.pricing_zone_chart','3','E28'), ('ship.prohibited_item','3','E28'),
  ('ship.rate_table','3','E28'), ('ship.rate_table_entry','3','E28'), ('ship.return_authorization','3','E31'),
  ('ship.routing_rule','3','E28'), ('ship.service_option','3','E28'), ('ship.service_product','3','E28'),
  ('ship.shipment','3','E29'), ('ship.shipment_leg','3','E29'), ('ship.shipment_option','3','E29'),
  ('ship.shipment_party','3','E29'), ('ship.shipment_reference','3','E32'), ('ship.shipper_account','3','E29'),
  ('ship.sort_window','3','E30'), ('ship.surcharge_definition','3','E28'), ('ship.tracking_event','3','E29'),
  ('ship.transit_time_matrix','3','E28'), ('ship.trip_cargo_capacity','3','E29'), ('ship.weight_audit','3','E31'),
  -- 4: 8 tables
  ('brd.border_point','4','E34'), ('brd.crossing_profile','4','E34'), ('ref.exchange_rate','4','E03'),
  ('sales.entry_rule','4','E11'), ('sales.ticket_doc','4','E11'), ('sec.screening_request','4','E24'),
  ('sec.screening_result','4','E24'), ('sec.watchlist_entry','4','E24'),
  -- 5: 5 tables
  ('iam.gov_identity_link','5','E02'), ('ops.incident_external_link','5','E09'), ('sec.authority_alert','5','E24'),
  ('sec.gov_adapter_config','5','E24'), ('sec.verification_job','5','E24'),
  -- 6: 2 tables
  ('iam.biometric_template','6','E02'), ('sec.manifest_submission','6','E24'),
  -- 7: 8 tables
  ('net.geofence','7','E04'), ('net.station_display','7','E04'), ('net.station_gate','7','E04'),
  ('ops.geo_event','7','E09'), ('ops.permission_event','7','E09'), ('ops.route_adherence_event','7','E09'),
  ('ops.tracking_alert','7','E09'), ('ops.tracking_state','7','E09'),
  -- 8: 15 tables
  ('brd.manifest_cargo','8','E34'), ('frt.container','8','E33'), ('frt.detention_claim','8','E33'),
  ('frt.escort_assignment','8','E33'), ('frt.freight_bid','8','E33'), ('frt.freight_claim','8','E33'),
  ('frt.freight_contract','8','E33'), ('frt.freight_document','8','E33'), ('frt.freight_request','8','E33'),
  ('frt.gate_event','8','E33'), ('frt.handover_event','8','E33'), ('frt.leg_container','8','E33'),
  ('frt.port_appointment','8','E33'), ('frt.transit_declaration','8','E33'), ('frt.weighbridge_reading','8','E33'),
  -- 9: 33 tables
  ('fleet.vehicle_fuel_profile','9','E06'), ('pricing.bin_range','9','E14'), ('pricing.loyalty_partner','9','E15'),
  ('pricing.partner_redemption','9','E15'), ('pricing.points_transfer','9','E15'),
  ('pricing.redemption_channel','9','E15'), ('pricing.redemption_token','9','E15'),
  ('pricing.reward_catalog','9','E15'), ('pricing.reward_voucher','9','E15'), ('pricing.sponsor_account','9','E14'),
  ('ptn.fuel_anomaly','9','E27'), ('ptn.fuel_card','9','E27'), ('ptn.fuel_price','9','E27'),
  ('ptn.fuel_session','9','E27'), ('ptn.odometer_reading','9','E27'), ('ptn.partner','9','E27'),
  ('ptn.partner_contract','9','E27'), ('ptn.partner_menu_item','9','E27'), ('ptn.partner_order','9','E27'),
  ('ptn.partner_order_item','9','E27'), ('ptn.partner_sale','9','E27'), ('ptn.partner_settlement','9','E27'),
  ('ptn.rest_stop_rating','9','E27'), ('ptn.station_employee','9','E27'), ('sales.channel_agreement','9','E12'),
  ('sales.channel_api_profile','9','E12'), ('sales.channel_booking_ref','9','E12'),
  ('sales.channel_inventory_rule','9','E12'), ('sales.channel_memo','9','E12'),
  ('sales.channel_statement','9','E12'), ('sales.channel_statement_line','9','E12'),
  ('sales.external_mapping','9','E12'), ('sales.supplier_source','9','E12'),
  -- 10: 5 tables
  ('rail.coach_layout','10','E36'), ('rail.fare_class','10','E36'), ('rail.journey','10','E36'),
  ('rail.journey_leg','10','E36'), ('rail.train_composition','10','E36'),
  -- 11: 7 tables
  ('taxi.dispatch_offer','11','E36'), ('taxi.meter_tariff','11','E36'), ('taxi.ride','11','E36'),
  ('taxi.ride_request','11','E36'), ('taxi.taxi_office','11','E36'), ('taxi.taxi_permit','11','E36'),
  ('taxi.taxi_shift','11','E36'),
  -- 12: 15 tables
  ('rent.contract_driver','12','E37'), ('rent.deposit_hold','12','E37'), ('rent.rental_addon','12','E37'),
  ('rent.rental_booking','12','E37'), ('rent.rental_booking_addon','12','E37'), ('rent.rental_branch','12','E37'),
  ('rent.rental_company','12','E37'), ('rent.rental_contract','12','E37'), ('rent.rental_fleet','12','E37'),
  ('rent.rental_inspection','12','E37'), ('rent.rental_rate','12','E37'), ('rent.rental_vehicle_class','12','E37'),
  ('rent.renter_rule','12','E37'), ('rent.telematics_device','12','E37'), ('rent.vehicle_trip_log','12','E37'),
  -- 13: 5 tables
  ('net.approved_rest_stop','13','E04'), ('net.corridor','13','E04'), ('ops.crossing_event','13','E09'),
  ('ops.transit_reconciliation','13','E09'), ('ops.trip_crossing_plan','13','E09'),
  -- 14: 6 tables
  ('ctr.attendance_event','14','E35'), ('ctr.authorized_receiver','14','E35'), ('ctr.contract_invoice','14','E35'),
  ('ctr.contract_rider','14','E35'), ('ctr.contract_route','14','E35'), ('ctr.service_contract','14','E35')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;

SELECT sys.rls_catalog('sys.project_phase');
SELECT sys.rls_catalog('sys.table_phase');
GRANT SELECT ON sys.project_phase, sys.table_phase TO masslak_app, masslak_readonly;

-- =====================================================================
-- C  Views
-- =====================================================================
CREATE OR REPLACE VIEW sys.v_phase_summary AS
SELECT p.code, p.ordinal, p.name, count(t.table_name) AS tables,
       array_agg(DISTINCT split_part(t.table_name, '.', 1) ORDER BY split_part(t.table_name, '.', 1)) FILTER (WHERE t.table_name IS NOT NULL) AS schemas,
       array_agg(DISTINCT t.module ORDER BY t.module) FILTER (WHERE t.table_name IS NOT NULL) AS modules
  FROM sys.project_phase p LEFT JOIN sys.table_phase t ON t.phase_code = p.code
 GROUP BY p.code, p.ordinal, p.name;
COMMENT ON VIEW sys.v_phase_summary IS 'Tables, schemas and modules brought into use by each phase';

-- A foreign key from a table of an earlier phase to a table of a later one. Allowed only when optional: the earlier
-- phase runs with the column empty until the later phase fills it.
CREATE OR REPLACE VIEW sys.v_phase_forward_reference AS
SELECT c.conname, c.conrelid::regclass::text AS from_table, fp.phase_code AS from_phase,
       c.confrelid::regclass::text AS to_table, tp.phase_code AS to_phase,
       (SELECT string_agg(a.attname, ', ' ORDER BY a.attnum) FROM pg_attribute a WHERE a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)) AS columns,
       (SELECT bool_and(a.attnotnull) FROM pg_attribute a WHERE a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)) AS required
  FROM pg_constraint c
  JOIN pg_class cc ON cc.oid = c.conrelid JOIN pg_namespace cn ON cn.oid = cc.relnamespace
  JOIN pg_class pc ON pc.oid = c.confrelid JOIN pg_namespace pn ON pn.oid = pc.relnamespace
  JOIN sys.table_phase fp ON fp.table_name = cn.nspname || '.' || cc.relname
  JOIN sys.table_phase tp ON tp.table_name = pn.nspname || '.' || pc.relname
  JOIN sys.project_phase f ON f.code = fp.phase_code
  JOIN sys.project_phase t ON t.code = tp.phase_code
 WHERE c.contype = 'f' AND f.ordinal < t.ordinal;
COMMENT ON VIEW sys.v_phase_forward_reference IS 'References from an earlier phase to a later one; each must be optional (readiness columns, study decision 88)';
GRANT SELECT ON sys.v_phase_summary, sys.v_phase_forward_reference TO masslak_app, masslak_auditor, masslak_readonly;

-- =====================================================================
-- D  Module switches carry the study's phase numbers
-- =====================================================================
UPDATE sys.module_gate SET phase = v.phase
  FROM (VALUES ('bill', 'Phase 1B: carrier billing'), ('brd', 'Phase 1A: manifests; 1B: routing to authorities; 4 and 6: borders'),
               ('ctr', 'Phase 14: contracted transport'), ('frt', 'Phase 8: trucks and transit'), ('ptn', 'Phase 9: service partners'),
               ('rail', 'Phase 10: rail'), ('rent', 'Phase 12: car rental'), ('ship', 'Phase 3: shipments and consignments'),
               ('taxi', 'Phase 11: taxi')) AS v(schema_name, phase)
 WHERE sys.module_gate.schema_name = v.schema_name;

INSERT INTO sys.schema_migration (version, description)
SELECT '1.23.0', 'Project phases: the phase of every table, phase views and forward-reference rule'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.23.0');

SELECT sys.refresh_table_class();
