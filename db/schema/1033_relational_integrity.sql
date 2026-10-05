-- 1033: relational integrity (database design v3.0, aligned with study v2.7)
-- Relationship rules that every table now follows (checked by db/tests):
--   1. every table has a primary key;
--   2. every reference to another row is a foreign key, except where the column comment says why not:
--      "Polymorphic:" (type + id pair), "External:" (identifier issued outside the platform) or
--      "No FK:" (append-only logs kept after the referenced row is gone, partitioned telemetry);
--   3. every foreign key has an index led by its columns, so joins and parent deletes never scan the child,
--      except references to fixed lookup tables (ref.*) and actor columns (created_by, approved_by, ...);
--   4. ON DELETE CASCADE is used only from a parent to the rows that are part of it (composition);
--      everything else is RESTRICT/NO ACTION, records that carry money or legal effect are never deleted.

-- 1. Primary key for accounting periods (the unique (company, period) index stays the business key)
ALTER TABLE acct.gl_period ADD COLUMN IF NOT EXISTS id bigint GENERATED ALWAYS AS IDENTITY;
DO $$ BEGIN
  ALTER TABLE acct.gl_period ADD CONSTRAINT gl_period_pkey PRIMARY KEY (id);
EXCEPTION WHEN invalid_table_definition OR duplicate_object THEN NULL; END $$;

-- 2. References that were plain columns
DO $$ BEGIN
  ALTER TABLE ops.seat_segment ADD CONSTRAINT seat_segment_lock_user_fk
    FOREIGN KEY (lock_user_id) REFERENCES iam.app_user(id) ON DELETE SET NULL NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE ops.presence_beacon ADD CONSTRAINT presence_beacon_key_fk
    FOREIGN KEY (key_id) REFERENCES sec.key_registry(key_ref) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE sales.shuttle_pass ADD CONSTRAINT shuttle_pass_qr_key_fk
    FOREIGN KEY (qr_key_id) REFERENCES sec.key_registry(key_ref) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- Validate where existing rows allow it (rows written before this version are reported, never rewritten)
DO $$
DECLARE c record;
BEGIN
  FOR c IN SELECT conrelid::regclass AS tbl, conname FROM pg_constraint
            WHERE conname IN ('seat_segment_lock_user_fk', 'presence_beacon_key_fk', 'shuttle_pass_qr_key_fk') AND NOT convalidated LOOP
    BEGIN
      EXECUTE format('ALTER TABLE %s VALIDATE CONSTRAINT %I', c.tbl, c.conname);
    EXCEPTION WHEN foreign_key_violation THEN
      RAISE WARNING '% on % left NOT VALID: existing rows reference missing keys', c.conname, c.tbl;
    END;
  END LOOP;
END $$;
CREATE INDEX IF NOT EXISTS seat_segment_lock_user_fkx ON ops.seat_segment (lock_user_id) WHERE lock_user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS presence_beacon_key_fkx ON ops.presence_beacon (key_id);
CREATE INDEX IF NOT EXISTS shuttle_pass_qr_key_fkx ON sales.shuttle_pass (qr_key_id) WHERE qr_key_id IS NOT NULL;

-- 3. Polymorphic references: (type, id) pairs, indexed together
CREATE INDEX IF NOT EXISTS sales_invoice_source_id_poly ON acct.sales_invoice (source_type, source_id);
CREATE INDEX IF NOT EXISTS tax_collection_no_file_source_id_poly ON acct.tax_collection_no_file (source_type, source_id);
CREATE INDEX IF NOT EXISTS usage_event_ref_id_poly ON bill.usage_event (ref_type, ref_id);
CREATE INDEX IF NOT EXISTS manifest_discrepancy_subject_id_poly ON brd.manifest_discrepancy (subject_type, subject_id);
CREATE INDEX IF NOT EXISTS manifest_response_subject_id_poly ON brd.manifest_response (subject_type, subject_id);
CREATE INDEX IF NOT EXISTS authority_order_target_id_poly ON sec.authority_order (target_type, target_id);
CREATE INDEX IF NOT EXISTS fraud_case_subject_id_poly ON sec.fraud_case (subject_type, subject_id);
CREATE INDEX IF NOT EXISTS screening_request_subject_id_poly ON sec.screening_request (subject_type, subject_id);
CREATE INDEX IF NOT EXISTS screening_request_context_id_poly ON sec.screening_request (context_type, context_id);
CREATE INDEX IF NOT EXISTS outbox_event_aggregate_id_poly ON sys.outbox_event (aggregate_type, aggregate_id);
CREATE INDEX IF NOT EXISTS sync_item_local_id_poly ON acct.sync_item (item_type, local_id);

-- 4. Why each remaining reference column has no foreign key
COMMENT ON COLUMN acct.account_mapping.external_id IS 'External: identifier of the record in the external accounting system';
COMMENT ON COLUMN acct.account_mapping.local_id IS 'Polymorphic: the row named by (local_type, local_id); integrity is kept by the service that writes it';
COMMENT ON COLUMN acct.einvoice_document.source_id IS 'Polymorphic: the row named by (source_type, source_id); integrity is kept by the service that writes it';
COMMENT ON COLUMN acct.journal_entry.source_id IS 'Polymorphic: the row named by (source_type, source_id); integrity is kept by the service that writes it';
COMMENT ON COLUMN acct.sales_invoice.source_id IS 'Polymorphic: the row named by (source_type, source_id); integrity is kept by the service that writes it';
COMMENT ON COLUMN acct.sync_item.external_id IS 'External: identifier returned by the external accounting system';
COMMENT ON COLUMN acct.sync_item.local_id IS 'Polymorphic: the row named by (item_type, local_id); integrity is kept by the service that writes it';
COMMENT ON COLUMN acct.tax_collection_no_file.source_id IS 'Polymorphic: the row named by (source_type, source_id); integrity is kept by the service that writes it';
COMMENT ON COLUMN audit.activity_log.api_client_id IS 'No FK: append-only log row kept after the referenced row is gone; partitioned and written at high volume';
COMMENT ON COLUMN audit.activity_log.company_id IS 'No FK: append-only log row kept after the referenced row is gone; partitioned and written at high volume';
COMMENT ON COLUMN audit.activity_log.object_id IS 'No FK: append-only log row kept after the referenced row is gone; partitioned and written at high volume';
COMMENT ON COLUMN audit.activity_log.request_id IS 'No FK: append-only log row kept after the referenced row is gone; partitioned and written at high volume';
COMMENT ON COLUMN audit.activity_log.session_id IS 'No FK: append-only log row kept after the referenced row is gone; partitioned and written at high volume';
COMMENT ON COLUMN audit.activity_log.user_id IS 'No FK: append-only log row kept after the referenced row is gone; partitioned and written at high volume';
COMMENT ON COLUMN audit.auth_event.api_client_id IS 'No FK: append-only log row kept after the referenced row is gone; partitioned and written at high volume';
COMMENT ON COLUMN audit.auth_event.api_key_id IS 'No FK: append-only log row kept after the referenced row is gone; partitioned and written at high volume';
COMMENT ON COLUMN audit.auth_event.company_id IS 'No FK: append-only log row kept after the referenced row is gone; partitioned and written at high volume';
COMMENT ON COLUMN audit.auth_event.device_id IS 'No FK: append-only log row kept after the referenced row is gone; partitioned and written at high volume';
COMMENT ON COLUMN audit.auth_event.request_id IS 'No FK: append-only log row kept after the referenced row is gone; partitioned and written at high volume';
COMMENT ON COLUMN audit.auth_event.session_id IS 'No FK: append-only log row kept after the referenced row is gone; partitioned and written at high volume';
COMMENT ON COLUMN audit.auth_event.user_id IS 'No FK: append-only log row kept after the referenced row is gone; partitioned and written at high volume';
COMMENT ON COLUMN audit.data_access_log.api_client_id IS 'No FK: append-only log row kept after the referenced row is gone; partitioned and written at high volume';
COMMENT ON COLUMN audit.data_access_log.company_id IS 'No FK: append-only log row kept after the referenced row is gone; partitioned and written at high volume';
COMMENT ON COLUMN audit.data_access_log.object_id IS 'No FK: append-only log row kept after the referenced row is gone; partitioned and written at high volume';
COMMENT ON COLUMN audit.data_access_log.request_id IS 'No FK: append-only log row kept after the referenced row is gone; partitioned and written at high volume';
COMMENT ON COLUMN audit.data_access_log.user_id IS 'No FK: append-only log row kept after the referenced row is gone; partitioned and written at high volume';
COMMENT ON COLUMN audit.log_seal.from_id IS 'No FK: first/last id of the sealed block of log rows (ranges over several log tables)';
COMMENT ON COLUMN audit.log_seal.to_id IS 'No FK: first/last id of the sealed block of log rows (ranges over several log tables)';
COMMENT ON COLUMN audit.row_change.api_client_id IS 'No FK: append-only log row kept after the referenced row is gone; partitioned and written at high volume';
COMMENT ON COLUMN audit.row_change.company_id IS 'No FK: append-only log row kept after the referenced row is gone; partitioned and written at high volume';
COMMENT ON COLUMN audit.row_change.request_id IS 'No FK: append-only log row kept after the referenced row is gone; partitioned and written at high volume';
COMMENT ON COLUMN audit.row_change.user_id IS 'No FK: append-only log row kept after the referenced row is gone; partitioned and written at high volume';
COMMENT ON COLUMN bill.usage_event.ref_id IS 'Polymorphic: the row named by (ref_type, ref_id); integrity is kept by the service that writes it';
COMMENT ON COLUMN brd.manifest_discrepancy.subject_id IS 'Polymorphic: the row named by (subject_type, subject_id); integrity is kept by the service that writes it';
COMMENT ON COLUMN brd.manifest_response.subject_id IS 'Polymorphic: the row named by (subject_type, subject_id); integrity is kept by the service that writes it';
COMMENT ON COLUMN fin.ledger_txn.ref_id IS 'Polymorphic: the row named by (ref_type, ref_id); integrity is kept by the service that writes it';
COMMENT ON COLUMN fin.payment_notification.event_id IS 'External: event identifier issued by the payment gateway (deduplication key)';
COMMENT ON COLUMN fin.price_allocation.subject_id IS 'Polymorphic: the row named by (subject_type, subject_id); integrity is kept by the service that writes it';
COMMENT ON COLUMN fleet.license_record.subject_id IS 'Polymorphic: the row named by (subject_type, subject_id); integrity is kept by the service that writes it';
COMMENT ON COLUMN iam.document.owner_id IS 'Polymorphic: the row named by (owner_type, owner_id); integrity is kept by the service that writes it';
COMMENT ON COLUMN iam.verification.subject_id IS 'Polymorphic: the row named by (subject_type, subject_id); integrity is kept by the service that writes it';
COMMENT ON COLUMN ops.geo_event.driver_user_id IS 'No FK: append-only log row kept after the referenced row is gone; partitioned and written at high volume';
COMMENT ON COLUMN ops.geo_event.trip_id IS 'No FK: append-only log row kept after the referenced row is gone; partitioned and written at high volume';
COMMENT ON COLUMN ops.geo_event.vehicle_id IS 'No FK: append-only log row kept after the referenced row is gone; partitioned and written at high volume';
COMMENT ON COLUMN sales.boarding_event.device_scan_id IS 'External: identifier generated on the scanning device for offline replay';
COMMENT ON COLUMN sales.external_mapping.external_id IS 'External: identifier of the record at the supplier';
COMMENT ON COLUMN sales.external_mapping.local_id IS 'Polymorphic: the row named by (local_type, local_id); integrity is kept by the service that writes it';
COMMENT ON COLUMN sec.authority_order.target_id IS 'Polymorphic: the row named by (target_type, target_id); integrity is kept by the service that writes it';
COMMENT ON COLUMN sec.document_signature.doc_ref_id IS 'Polymorphic: the row named by (doc_type, doc_ref_id); integrity is kept by the service that writes it';
COMMENT ON COLUMN sec.fraud_case.subject_id IS 'Polymorphic: the row named by (subject_type, subject_id); integrity is kept by the service that writes it';
COMMENT ON COLUMN sec.risk_assessment.subject_id IS 'Polymorphic: the row named by (subject_type, subject_id); integrity is kept by the service that writes it';
COMMENT ON COLUMN sec.screening_request.context_id IS 'Polymorphic: the row named by (context_type, context_id); integrity is kept by the service that writes it';
COMMENT ON COLUMN sec.screening_request.subject_id IS 'Polymorphic: the row named by (subject_type, subject_id); integrity is kept by the service that writes it';
COMMENT ON COLUMN sec.security_event.api_client_id IS 'No FK: append-only log row kept after the referenced row is gone; partitioned and written at high volume';
COMMENT ON COLUMN sec.security_event.correlation_id IS 'External: correlation identifier shared by the events of one incident';
COMMENT ON COLUMN sec.security_event.user_id IS 'No FK: append-only log row kept after the referenced row is gone; partitioned and written at high volume';
COMMENT ON COLUMN sec.tamper_event.api_client_id IS 'No FK: append-only log row kept after the referenced row is gone; partitioned and written at high volume';
COMMENT ON COLUMN sec.tamper_event.user_id IS 'No FK: append-only log row kept after the referenced row is gone; partitioned and written at high volume';
COMMENT ON COLUMN sec.verification_job.subject_id IS 'Polymorphic: the row named by (subject_type, subject_id); integrity is kept by the service that writes it';
COMMENT ON COLUMN sys.outbox_event.aggregate_id IS 'Polymorphic: the row named by (aggregate_type, aggregate_id); integrity is kept by the service that writes it';
COMMENT ON COLUMN sys.outbox_event.company_id IS 'No FK: append-only log row kept after the referenced row is gone; partitioned and written at high volume';

-- 5. Indexes for foreign keys (660); each named <table>_<columns>_fkx
CREATE INDEX IF NOT EXISTS accounting_connection_company_id_fkx ON acct.accounting_connection (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS cash_box_account_id_fkx ON acct.cash_box (account_id);  -- -> acct.gl_account
CREATE INDEX IF NOT EXISTS cash_box_company_id_fkx ON acct.cash_box (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS cash_box_owner_party_id_fkx ON acct.cash_box (owner_party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS cash_box_station_id_fkx ON acct.cash_box (station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS cash_payment_account_id_fkx ON acct.cash_payment (account_id);  -- -> acct.gl_account
CREATE INDEX IF NOT EXISTS cash_payment_bank_account_id_fkx ON acct.cash_payment (bank_account_id);  -- -> iam.bank_account
CREATE INDEX IF NOT EXISTS cash_payment_cash_session_id_fkx ON acct.cash_payment (cash_session_id);  -- -> acct.cash_session
CREATE INDEX IF NOT EXISTS cash_payment_journal_entry_id_fkx ON acct.cash_payment (journal_entry_id);  -- -> acct.journal_entry
CREATE INDEX IF NOT EXISTS cash_payment_party_id_fkx ON acct.cash_payment (party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS cash_payment_wallet_id_fkx ON acct.cash_payment (wallet_id);  -- -> fin.wallet
CREATE INDEX IF NOT EXISTS cash_receipt_bank_account_id_fkx ON acct.cash_receipt (bank_account_id);  -- -> iam.bank_account
CREATE INDEX IF NOT EXISTS cash_receipt_cash_session_id_fkx ON acct.cash_receipt (cash_session_id);  -- -> acct.cash_session
CREATE INDEX IF NOT EXISTS cash_receipt_invoice_id_fkx ON acct.cash_receipt (invoice_id);  -- -> acct.sales_invoice
CREATE INDEX IF NOT EXISTS cash_receipt_journal_entry_id_fkx ON acct.cash_receipt (journal_entry_id);  -- -> acct.journal_entry
CREATE INDEX IF NOT EXISTS cash_receipt_party_id_fkx ON acct.cash_receipt (party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS cash_receipt_wallet_id_fkx ON acct.cash_receipt (wallet_id);  -- -> fin.wallet
CREATE INDEX IF NOT EXISTS cash_session_handed_over_to_fkx ON acct.cash_session (handed_over_to);  -- -> iam.app_user
CREATE INDEX IF NOT EXISTS cost_center_company_id_fkx ON acct.cost_center (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS cost_center_route_id_fkx ON acct.cost_center (route_id);  -- -> net.route
CREATE INDEX IF NOT EXISTS cost_center_station_id_fkx ON acct.cost_center (station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS cost_center_trip_id_fkx ON acct.cost_center (trip_id);  -- -> ops.trip
CREATE INDEX IF NOT EXISTS credit_note_einvoice_document_id_fkx ON acct.credit_note (einvoice_document_id);  -- -> acct.einvoice_document
CREATE INDEX IF NOT EXISTS credit_note_invoice_id_fkx ON acct.credit_note (invoice_id);  -- -> acct.sales_invoice
CREATE INDEX IF NOT EXISTS einvoice_activation_authority_id_fkx ON acct.einvoice_activation (authority_id);  -- -> acct.tax_authority
CREATE INDEX IF NOT EXISTS einvoice_document_buyer_party_id_fkx ON acct.einvoice_document (buyer_party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS einvoice_document_company_id_fkx ON acct.einvoice_document (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS einvoice_document_original_doc_id_fkx ON acct.einvoice_document (original_doc_id);  -- -> acct.einvoice_document
CREATE INDEX IF NOT EXISTS einvoice_document_pdf_file_id_fkx ON acct.einvoice_document (pdf_file_id);  -- -> ref.file_object
CREATE INDEX IF NOT EXISTS einvoice_document_seller_profile_id_fkx ON acct.einvoice_document (seller_profile_id);  -- -> acct.tax_profile
CREATE INDEX IF NOT EXISTS einvoice_document_xml_file_id_fkx ON acct.einvoice_document (xml_file_id);  -- -> ref.file_object
CREATE INDEX IF NOT EXISTS einvoice_line_allocation_line_id_fkx ON acct.einvoice_line (allocation_line_id);  -- -> fin.price_allocation_line
CREATE INDEX IF NOT EXISTS einvoice_line_tax_scheme_id_fkx ON acct.einvoice_line (tax_scheme_id);  -- -> pricing.tax_scheme
CREATE INDEX IF NOT EXISTS einvoice_submission_stamped_xml_file_id_fkx ON acct.einvoice_submission (stamped_xml_file_id);  -- -> ref.file_object
CREATE INDEX IF NOT EXISTS einvoice_unit_profile_id_fkx ON acct.einvoice_unit (profile_id);  -- -> acct.tax_profile
CREATE INDEX IF NOT EXISTS einvoice_unit_signing_key_id_fkx ON acct.einvoice_unit (signing_key_id);  -- -> sec.key_registry
CREATE INDEX IF NOT EXISTS export_batch_company_id_fkx ON acct.export_batch (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS export_batch_file_id_fkx ON acct.export_batch (file_id);  -- -> ref.file_object
CREATE INDEX IF NOT EXISTS gl_account_company_id_fkx ON acct.gl_account (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS gl_account_parent_id_fkx ON acct.gl_account (parent_id);  -- -> acct.gl_account
CREATE INDEX IF NOT EXISTS gl_period_company_id_fkx ON acct.gl_period (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS journal_entry_company_id_fkx ON acct.journal_entry (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS journal_entry_posting_rule_id_fkx ON acct.journal_entry (posting_rule_id);  -- -> acct.posting_rule
CREATE INDEX IF NOT EXISTS journal_entry_reversed_by_id_fkx ON acct.journal_entry (reversed_by_id);  -- -> acct.journal_entry
CREATE INDEX IF NOT EXISTS journal_line_cost_center_id_fkx ON acct.journal_line (cost_center_id);  -- -> acct.cost_center
CREATE INDEX IF NOT EXISTS journal_line_party_id_fkx ON acct.journal_line (party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS sales_invoice_customer_party_id_fkx ON acct.sales_invoice (customer_party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS sales_invoice_einvoice_document_id_fkx ON acct.sales_invoice (einvoice_document_id);  -- -> acct.einvoice_document
CREATE INDEX IF NOT EXISTS sales_invoice_journal_entry_id_fkx ON acct.sales_invoice (journal_entry_id);  -- -> acct.journal_entry
CREATE INDEX IF NOT EXISTS sales_invoice_line_account_id_fkx ON acct.sales_invoice_line (account_id);  -- -> acct.gl_account
CREATE INDEX IF NOT EXISTS sales_invoice_line_cost_center_id_fkx ON acct.sales_invoice_line (cost_center_id);  -- -> acct.cost_center
CREATE INDEX IF NOT EXISTS sales_invoice_line_tax_code_id_fkx ON acct.sales_invoice_line (tax_code_id);  -- -> acct.tax_code
CREATE INDEX IF NOT EXISTS sync_conflict_item_id_fkx ON acct.sync_conflict (item_id);  -- -> acct.sync_item
CREATE INDEX IF NOT EXISTS sync_item_job_id_fkx ON acct.sync_item (job_id);  -- -> acct.sync_job
CREATE INDEX IF NOT EXISTS tax_code_account_id_fkx ON acct.tax_code (account_id);  -- -> acct.gl_account
CREATE INDEX IF NOT EXISTS tax_code_tax_rule_id_fkx ON acct.tax_code (tax_rule_id);  -- -> pricing.tax_rule
CREATE INDEX IF NOT EXISTS tax_collection_no_file_payer_party_id_fkx ON acct.tax_collection_no_file (payer_party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS tax_collection_no_file_remitted_payment_id_fkx ON acct.tax_collection_no_file (remitted_payment_id);  -- -> acct.tax_payment
CREATE INDEX IF NOT EXISTS tax_collection_no_file_tax_scheme_id_fkx ON acct.tax_collection_no_file (tax_scheme_id);  -- -> pricing.tax_scheme
CREATE INDEX IF NOT EXISTS tax_payment_authority_id_fkx ON acct.tax_payment (authority_id);  -- -> acct.tax_authority
CREATE INDEX IF NOT EXISTS tax_payment_ledger_txn_id_fkx ON acct.tax_payment (ledger_txn_id);  -- -> fin.ledger_txn
CREATE INDEX IF NOT EXISTS tax_payment_profile_id_fkx ON acct.tax_payment (profile_id);  -- -> acct.tax_profile
CREATE INDEX IF NOT EXISTS tax_payment_tax_return_id_fkx ON acct.tax_payment (tax_return_id);  -- -> acct.tax_return
CREATE INDEX IF NOT EXISTS tax_payment_tax_scheme_id_fkx ON acct.tax_payment (tax_scheme_id);  -- -> pricing.tax_scheme
CREATE INDEX IF NOT EXISTS tax_profile_authority_id_fkx ON acct.tax_profile (authority_id);  -- -> acct.tax_authority
CREATE INDEX IF NOT EXISTS tax_profile_field_authority_id_fkx ON acct.tax_profile_field (authority_id);  -- -> acct.tax_authority
CREATE INDEX IF NOT EXISTS tax_profile_value_field_id_fkx ON acct.tax_profile_value (field_id);  -- -> acct.tax_profile_field
CREATE INDEX IF NOT EXISTS tax_registration_profile_id_fkx ON acct.tax_registration (profile_id);  -- -> acct.tax_profile
CREATE INDEX IF NOT EXISTS tax_registration_tax_scheme_id_fkx ON acct.tax_registration (tax_scheme_id);  -- -> pricing.tax_scheme
CREATE INDEX IF NOT EXISTS tax_return_authority_id_fkx ON acct.tax_return (authority_id);  -- -> acct.tax_authority
CREATE INDEX IF NOT EXISTS tax_return_tax_scheme_id_fkx ON acct.tax_return (tax_scheme_id);  -- -> pricing.tax_scheme
CREATE INDEX IF NOT EXISTS log_seal_key_id_fkx ON audit.log_seal (key_id);  -- -> sec.key_registry
CREATE INDEX IF NOT EXISTS billed_usage_company_id_fkx ON bill.billed_usage (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS billed_usage_invoice_id_fkx ON bill.billed_usage (invoice_id);  -- -> bill.carrier_invoice
CREATE INDEX IF NOT EXISTS carrier_agreement_company_id_fkx ON bill.carrier_agreement (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS carrier_invoice_einvoice_document_id_fkx ON bill.carrier_invoice (einvoice_document_id);  -- -> acct.einvoice_document
CREATE INDEX IF NOT EXISTS carrier_invoice_ledger_txn_id_fkx ON bill.carrier_invoice (ledger_txn_id);  -- -> fin.ledger_txn
CREATE INDEX IF NOT EXISTS carrier_invoice_subscription_id_fkx ON bill.carrier_invoice (subscription_id);  -- -> bill.company_subscription
CREATE INDEX IF NOT EXISTS company_subscription_agreement_id_fkx ON bill.company_subscription (agreement_id);  -- -> bill.carrier_agreement
CREATE INDEX IF NOT EXISTS company_subscription_plan_id_fkx ON bill.company_subscription (plan_id);  -- -> bill.plan
CREATE INDEX IF NOT EXISTS border_point_authority_id_fkx ON brd.border_point (authority_id);  -- -> sec.authority_profile
CREATE INDEX IF NOT EXISTS border_point_counterpart_station_id_fkx ON brd.border_point (counterpart_station_id);  -- -> brd.border_point
CREATE INDEX IF NOT EXISTS crossing_profile_authority_id_fkx ON brd.crossing_profile (authority_id);  -- -> sec.authority_profile
CREATE INDEX IF NOT EXISTS manifest_border_point_id_fkx ON brd.manifest (border_point_id);  -- -> brd.border_point
CREATE INDEX IF NOT EXISTS manifest_crossing_plan_id_fkx ON brd.manifest (crossing_plan_id);  -- -> ops.trip_crossing_plan
CREATE INDEX IF NOT EXISTS manifest_profile_id_fkx ON brd.manifest (profile_id);  -- -> brd.crossing_profile
CREATE INDEX IF NOT EXISTS manifest_submission_id_fkx ON brd.manifest (submission_id);  -- -> sec.manifest_submission
CREATE INDEX IF NOT EXISTS manifest_cargo_leg_id_fkx ON brd.manifest_cargo (leg_id);  -- -> ship.shipment_leg
CREATE INDEX IF NOT EXISTS manifest_cargo_manifest_id_fkx ON brd.manifest_cargo (manifest_id);  -- -> brd.manifest
CREATE INDEX IF NOT EXISTS manifest_cargo_shipment_id_fkx ON brd.manifest_cargo (shipment_id);  -- -> ship.shipment
CREATE INDEX IF NOT EXISTS manifest_discrepancy_manifest_id_fkx ON brd.manifest_discrepancy (manifest_id);  -- -> brd.manifest
CREATE INDEX IF NOT EXISTS manifest_person_crew_party_id_fkx ON brd.manifest_person (crew_party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS manifest_person_disembark_station_id_fkx ON brd.manifest_person (disembark_station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS manifest_person_embark_station_id_fkx ON brd.manifest_person (embark_station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS manifest_person_enc_key_id_fkx ON brd.manifest_person (enc_key_id);  -- -> sec.key_registry
CREATE INDEX IF NOT EXISTS manifest_person_syria_entry_point_id_fkx ON brd.manifest_person (syria_entry_point_id);  -- -> brd.border_point
CREATE INDEX IF NOT EXISTS manifest_person_syria_exit_point_id_fkx ON brd.manifest_person (syria_exit_point_id);  -- -> brd.border_point
CREATE INDEX IF NOT EXISTS manifest_person_ticket_id_fkx ON brd.manifest_person (ticket_id);  -- -> sales.ticket
CREATE INDEX IF NOT EXISTS manifest_response_manifest_id_fkx ON brd.manifest_response (manifest_id);  -- -> brd.manifest
CREATE INDEX IF NOT EXISTS manifest_vehicle_trailer_id_fkx ON brd.manifest_vehicle (trailer_id);  -- -> fleet.trailer
CREATE INDEX IF NOT EXISTS manifest_vehicle_vehicle_id_fkx ON brd.manifest_vehicle (vehicle_id);  -- -> fleet.vehicle
CREATE INDEX IF NOT EXISTS ai_conversation_company_id_fkx ON crm.ai_conversation (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS ai_conversation_escalated_case_id_fkx ON crm.ai_conversation (escalated_case_id);  -- -> crm.case
CREATE INDEX IF NOT EXISTS ai_conversation_party_id_fkx ON crm.ai_conversation (party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS ai_message_conversation_id_fkx ON crm.ai_message (conversation_id);  -- -> crm.ai_conversation
CREATE INDEX IF NOT EXISTS ai_tool_call_conversation_id_fkx ON crm.ai_tool_call (conversation_id);  -- -> crm.ai_conversation
CREATE INDEX IF NOT EXISTS ai_tool_call_tool_fkx ON crm.ai_tool_call (tool);  -- -> crm.ai_policy
CREATE INDEX IF NOT EXISTS call_agent_id_fkx ON crm.call (agent_id);  -- -> crm.call_agent
CREATE INDEX IF NOT EXISTS call_ai_conversation_id_fkx ON crm.call (ai_conversation_id);  -- -> crm.ai_conversation
CREATE INDEX IF NOT EXISTS call_case_id_fkx ON crm.call (case_id);  -- -> crm.case
CREATE INDEX IF NOT EXISTS call_company_id_fkx ON crm.call (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS call_party_id_fkx ON crm.call (party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS call_queue_id_fkx ON crm.call (queue_id);  -- -> crm.call_queue
CREATE INDEX IF NOT EXISTS call_recording_file_id_fkx ON crm.call (recording_file_id);  -- -> ref.file_object
CREATE INDEX IF NOT EXISTS call_transcript_file_id_fkx ON crm.call (transcript_file_id);  -- -> ref.file_object
CREATE INDEX IF NOT EXISTS call_agent_skill_skill_code_fkx ON crm.call_agent_skill (skill_code);  -- -> crm.call_skill
CREATE INDEX IF NOT EXISTS call_qa_call_id_fkx ON crm.call_qa (call_id);  -- -> crm.call
CREATE INDEX IF NOT EXISTS call_queue_skill_skill_code_fkx ON crm.call_queue_skill (skill_code);  -- -> crm.call_skill
CREATE INDEX IF NOT EXISTS callback_request_assigned_agent_id_fkx ON crm.callback_request (assigned_agent_id);  -- -> crm.call_agent
CREATE INDEX IF NOT EXISTS callback_request_call_id_fkx ON crm.callback_request (call_id);  -- -> crm.call
CREATE INDEX IF NOT EXISTS case_assigned_to_fkx ON crm.case (assigned_to);  -- -> iam.app_user
CREATE INDEX IF NOT EXISTS case_booking_id_fkx ON crm.case (booking_id);  -- -> sales.booking
CREATE INDEX IF NOT EXISTS case_company_id_fkx ON crm.case (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS case_party_id_fkx ON crm.case (party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS case_payout_ledger_txn_id_fkx ON crm.case (payout_ledger_txn_id);  -- -> fin.ledger_txn
CREATE INDEX IF NOT EXISTS case_trip_id_fkx ON crm.case (trip_id);  -- -> ops.trip
CREATE INDEX IF NOT EXISTS case_event_case_id_fkx ON crm.case_event (case_id);  -- -> crm.case
CREATE INDEX IF NOT EXISTS case_event_file_id_fkx ON crm.case_event (file_id);  -- -> ref.file_object
CREATE INDEX IF NOT EXISTS notification_booking_id_fkx ON crm.notification (booking_id);  -- -> sales.booking
CREATE INDEX IF NOT EXISTS notification_charged_company_id_fkx ON crm.notification (charged_company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS notification_party_id_fkx ON crm.notification (party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS notification_trip_id_fkx ON crm.notification (trip_id);  -- -> ops.trip
CREATE INDEX IF NOT EXISTS trip_rating_party_id_fkx ON crm.trip_rating (party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS trip_rating_trip_id_fkx ON crm.trip_rating (trip_id);  -- -> ops.trip
CREATE INDEX IF NOT EXISTS attendance_event_received_by_party_id_fkx ON ctr.attendance_event (received_by_party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS attendance_event_rider_id_fkx ON ctr.attendance_event (rider_id);  -- -> ctr.contract_rider
CREATE INDEX IF NOT EXISTS authorized_receiver_party_id_fkx ON ctr.authorized_receiver (party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS contract_rider_dropoff_station_id_fkx ON ctr.contract_rider (dropoff_station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS contract_rider_guardian_party_id_fkx ON ctr.contract_rider (guardian_party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS contract_rider_passenger_party_id_fkx ON ctr.contract_rider (passenger_party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS contract_rider_pickup_station_id_fkx ON ctr.contract_rider (pickup_station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS contract_route_attendant_party_id_fkx ON ctr.contract_route (attendant_party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS contract_route_contract_id_fkx ON ctr.contract_route (contract_id);  -- -> ctr.service_contract
CREATE INDEX IF NOT EXISTS contract_route_driver_party_id_fkx ON ctr.contract_route (driver_party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS contract_route_route_id_fkx ON ctr.contract_route (route_id);  -- -> net.route
CREATE INDEX IF NOT EXISTS contract_route_vehicle_id_fkx ON ctr.contract_route (vehicle_id);  -- -> fleet.vehicle
CREATE INDEX IF NOT EXISTS service_contract_carrier_company_id_fkx ON ctr.service_contract (carrier_company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS service_contract_client_company_id_fkx ON ctr.service_contract (client_company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS service_contract_client_party_id_fkx ON ctr.service_contract (client_party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS bank_transfer_topup_ledger_txn_id_fkx ON fin.bank_transfer_topup (ledger_txn_id);  -- -> fin.ledger_txn
CREATE INDEX IF NOT EXISTS bank_transfer_topup_wallet_id_fkx ON fin.bank_transfer_topup (wallet_id);  -- -> fin.wallet
CREATE INDEX IF NOT EXISTS cash_remittance_company_id_fkx ON fin.cash_remittance (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS cash_remittance_ledger_txn_id_fkx ON fin.cash_remittance (ledger_txn_id);  -- -> fin.ledger_txn
CREATE INDEX IF NOT EXISTS deposit_placement_account_id_fkx ON fin.deposit_placement (account_id);  -- -> fin.float_account
CREATE INDEX IF NOT EXISTS float_account_ledger_wallet_id_fkx ON fin.float_account (ledger_wallet_id);  -- -> fin.wallet
CREATE INDEX IF NOT EXISTS ledger_txn_reverses_txn_id_fkx ON fin.ledger_txn (reverses_txn_id);  -- -> fin.ledger_txn
CREATE INDEX IF NOT EXISTS payment_ledger_txn_id_fkx ON fin.payment (ledger_txn_id);  -- -> fin.ledger_txn
CREATE INDEX IF NOT EXISTS payment_payer_party_id_fkx ON fin.payment (payer_party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS payment_wallet_id_fkx ON fin.payment (wallet_id);  -- -> fin.wallet
CREATE INDEX IF NOT EXISTS payment_notification_payment_id_fkx ON fin.payment_notification (payment_id);  -- -> fin.payment
CREATE INDEX IF NOT EXISTS payment_provider_clearing_wallet_id_fkx ON fin.payment_provider (clearing_wallet_id);  -- -> fin.wallet
CREATE INDEX IF NOT EXISTS payout_bank_account_id_fkx ON fin.payout (bank_account_id);  -- -> iam.bank_account
CREATE INDEX IF NOT EXISTS payout_ledger_txn_id_fkx ON fin.payout (ledger_txn_id);  -- -> fin.ledger_txn
CREATE INDEX IF NOT EXISTS payout_settlement_batch_id_fkx ON fin.payout (settlement_batch_id);  -- -> fin.settlement_batch
CREATE INDEX IF NOT EXISTS price_allocation_booking_id_fkx ON fin.price_allocation (booking_id);  -- -> sales.booking
CREATE INDEX IF NOT EXISTS price_allocation_template_id_fkx ON fin.price_allocation (template_id);  -- -> pricing.allocation_template
CREATE INDEX IF NOT EXISTS price_allocation_line_beneficiary_party_id_fkx ON fin.price_allocation_line (beneficiary_party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS price_allocation_line_commission_scheme_id_fkx ON fin.price_allocation_line (commission_scheme_id);  -- -> pricing.commission_scheme
CREATE INDEX IF NOT EXISTS price_allocation_line_parent_line_id_fkx ON fin.price_allocation_line (parent_line_id);  -- -> fin.price_allocation_line
CREATE INDEX IF NOT EXISTS price_allocation_line_sponsor_account_id_fkx ON fin.price_allocation_line (sponsor_account_id);  -- -> pricing.sponsor_account
CREATE INDEX IF NOT EXISTS price_allocation_line_tax_scheme_id_fkx ON fin.price_allocation_line (tax_scheme_id);  -- -> pricing.tax_scheme
CREATE INDEX IF NOT EXISTS price_allocation_line_wallet_id_fkx ON fin.price_allocation_line (wallet_id);  -- -> fin.wallet
CREATE INDEX IF NOT EXISTS settlement_line_batch_id_fkx ON fin.settlement_line (batch_id);  -- -> fin.settlement_batch
CREATE INDEX IF NOT EXISTS settlement_line_trip_id_fkx ON fin.settlement_line (trip_id);  -- -> ops.trip
CREATE INDEX IF NOT EXISTS tax_ledger_allocation_line_id_fkx ON fin.tax_ledger (allocation_line_id);  -- -> fin.price_allocation_line
CREATE INDEX IF NOT EXISTS tax_ledger_company_id_fkx ON fin.tax_ledger (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS tax_ledger_jurisdiction_id_fkx ON fin.tax_ledger (jurisdiction_id);  -- -> pricing.jurisdiction
CREATE INDEX IF NOT EXISTS withdrawal_request_bank_account_id_fkx ON fin.withdrawal_request (bank_account_id);  -- -> iam.bank_account
CREATE INDEX IF NOT EXISTS withdrawal_request_company_id_fkx ON fin.withdrawal_request (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS withdrawal_request_ledger_txn_id_fkx ON fin.withdrawal_request (ledger_txn_id);  -- -> fin.ledger_txn
CREATE INDEX IF NOT EXISTS boarding_validator_company_id_fkx ON fleet.boarding_validator (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS boarding_validator_vehicle_id_fkx ON fleet.boarding_validator (vehicle_id);  -- -> fleet.vehicle
CREATE INDEX IF NOT EXISTS crew_profile_company_id_fkx ON fleet.crew_profile (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS driving_hours_log_company_id_fkx ON fleet.driving_hours_log (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS driving_hours_log_trip_id_fkx ON fleet.driving_hours_log (trip_id);  -- -> ops.trip
CREATE INDEX IF NOT EXISTS field_check_log_inspector_user_id_fkx ON fleet.field_check_log (inspector_user_id);  -- -> iam.app_user
CREATE INDEX IF NOT EXISTS field_check_log_vehicle_id_fkx ON fleet.field_check_log (vehicle_id);  -- -> fleet.vehicle
CREATE INDEX IF NOT EXISTS insurance_claim_company_id_fkx ON fleet.insurance_claim (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS insurance_claim_policy_id_fkx ON fleet.insurance_claim (policy_id);  -- -> fleet.insurance_policy
CREATE INDEX IF NOT EXISTS insurance_policy_document_id_fkx ON fleet.insurance_policy (document_id);  -- -> iam.document
CREATE INDEX IF NOT EXISTS insurance_policy_insurer_party_id_fkx ON fleet.insurance_policy (insurer_party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS insurance_policy_license_record_id_fkx ON fleet.insurance_policy (license_record_id);  -- -> fleet.license_record
CREATE INDEX IF NOT EXISTS insurance_policy_vehicle_id_fkx ON fleet.insurance_policy (vehicle_id);  -- -> fleet.vehicle
CREATE INDEX IF NOT EXISTS license_change_request_document_id_fkx ON fleet.license_change_request (document_id);  -- -> iam.document
CREATE INDEX IF NOT EXISTS license_change_request_license_record_id_fkx ON fleet.license_change_request (license_record_id);  -- -> fleet.license_record
CREATE INDEX IF NOT EXISTS license_record_company_id_fkx ON fleet.license_record (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS license_record_document_id_fkx ON fleet.license_record (document_id);  -- -> iam.document
CREATE INDEX IF NOT EXISTS license_record_last_change_request_id_fkx ON fleet.license_record (last_change_request_id);  -- -> fleet.license_change_request
CREATE INDEX IF NOT EXISTS seat_price_rule_company_id_fkx ON fleet.seat_price_rule (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS seat_price_rule_seat_layout_id_fkx ON fleet.seat_price_rule (seat_layout_id);  -- -> fleet.seat_layout
CREATE INDEX IF NOT EXISTS seat_price_rule_vehicle_id_fkx ON fleet.seat_price_rule (vehicle_id);  -- -> fleet.vehicle
CREATE INDEX IF NOT EXISTS trailer_company_id_fkx ON fleet.trailer (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS trailer_owner_party_id_fkx ON fleet.trailer (owner_party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS truck_combination_company_id_fkx ON fleet.truck_combination (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS truck_combination_driver_party_id_fkx ON fleet.truck_combination (driver_party_id);  -- -> fleet.crew_profile
CREATE INDEX IF NOT EXISTS vehicle_owner_party_id_fkx ON fleet.vehicle (owner_party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS vehicle_seat_layout_id_fkx ON fleet.vehicle (seat_layout_id);  -- -> fleet.seat_layout
CREATE INDEX IF NOT EXISTS vehicle_fuel_profile_company_id_fkx ON fleet.vehicle_fuel_profile (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS vehicle_lease_document_id_fkx ON fleet.vehicle_lease (document_id);  -- -> iam.document
CREATE INDEX IF NOT EXISTS vehicle_lease_lessee_company_id_fkx ON fleet.vehicle_lease (lessee_company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS vehicle_lease_owner_party_id_fkx ON fleet.vehicle_lease (owner_party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS vehicle_service_status_company_id_fkx ON fleet.vehicle_service_status (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS vehicle_service_status_incident_id_fkx ON fleet.vehicle_service_status (incident_id);  -- -> ops.incident
CREATE INDEX IF NOT EXISTS vehicle_service_status_release_evidence_id_fkx ON fleet.vehicle_service_status (release_evidence_id);  -- -> ref.file_object
CREATE INDEX IF NOT EXISTS vehicle_status_history_incident_id_fkx ON fleet.vehicle_status_history (incident_id);  -- -> ops.incident
CREATE INDEX IF NOT EXISTS vehicle_status_history_release_document_id_fkx ON fleet.vehicle_status_history (release_document_id);  -- -> iam.document
CREATE INDEX IF NOT EXISTS container_owner_party_id_fkx ON frt.container (owner_party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS detention_claim_contract_id_fkx ON frt.detention_claim (contract_id);  -- -> frt.freight_contract
CREATE INDEX IF NOT EXISTS detention_claim_leg_id_fkx ON frt.detention_claim (leg_id);  -- -> ship.shipment_leg
CREATE INDEX IF NOT EXISTS detention_claim_station_id_fkx ON frt.detention_claim (station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS escort_assignment_escort_party_id_fkx ON frt.escort_assignment (escort_party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS escort_assignment_leg_id_fkx ON frt.escort_assignment (leg_id);  -- -> ship.shipment_leg
CREATE INDEX IF NOT EXISTS freight_bid_carrier_company_id_fkx ON frt.freight_bid (carrier_company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS freight_bid_truck_vehicle_id_fkx ON frt.freight_bid (truck_vehicle_id);  -- -> fleet.truck_unit
CREATE INDEX IF NOT EXISTS freight_claim_case_id_fkx ON frt.freight_claim (case_id);  -- -> crm.case
CREATE INDEX IF NOT EXISTS freight_claim_contract_id_fkx ON frt.freight_claim (contract_id);  -- -> frt.freight_contract
CREATE INDEX IF NOT EXISTS freight_claim_leg_id_fkx ON frt.freight_claim (leg_id);  -- -> ship.shipment_leg
CREATE INDEX IF NOT EXISTS freight_contract_accepted_bid_id_fkx ON frt.freight_contract (accepted_bid_id);  -- -> frt.freight_bid
CREATE INDEX IF NOT EXISTS freight_contract_carrier_company_id_fkx ON frt.freight_contract (carrier_company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS freight_document_contract_id_fkx ON frt.freight_document (contract_id);  -- -> frt.freight_contract
CREATE INDEX IF NOT EXISTS freight_document_file_id_fkx ON frt.freight_document (file_id);  -- -> ref.file_object
CREATE INDEX IF NOT EXISTS freight_document_leg_id_fkx ON frt.freight_document (leg_id);  -- -> ship.shipment_leg
CREATE INDEX IF NOT EXISTS freight_request_dest_address_id_fkx ON frt.freight_request (dest_address_id);  -- -> ship.address
CREATE INDEX IF NOT EXISTS freight_request_dest_station_id_fkx ON frt.freight_request (dest_station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS freight_request_origin_address_id_fkx ON frt.freight_request (origin_address_id);  -- -> ship.address
CREATE INDEX IF NOT EXISTS freight_request_origin_station_id_fkx ON frt.freight_request (origin_station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS freight_request_shipper_company_id_fkx ON frt.freight_request (shipper_company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS freight_request_shipper_party_id_fkx ON frt.freight_request (shipper_party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS gate_event_appointment_id_fkx ON frt.gate_event (appointment_id);  -- -> frt.port_appointment
CREATE INDEX IF NOT EXISTS gate_event_port_station_id_fkx ON frt.gate_event (port_station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS gate_event_truck_vehicle_id_fkx ON frt.gate_event (truck_vehicle_id);  -- -> fleet.truck_unit
CREATE INDEX IF NOT EXISTS handover_event_from_company_id_fkx ON frt.handover_event (from_company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS handover_event_from_signature_file_id_fkx ON frt.handover_event (from_signature_file_id);  -- -> ref.file_object
CREATE INDEX IF NOT EXISTS handover_event_leg_id_fkx ON frt.handover_event (leg_id);  -- -> ship.shipment_leg
CREATE INDEX IF NOT EXISTS handover_event_next_leg_id_fkx ON frt.handover_event (next_leg_id);  -- -> ship.shipment_leg
CREATE INDEX IF NOT EXISTS handover_event_station_id_fkx ON frt.handover_event (station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS handover_event_to_company_id_fkx ON frt.handover_event (to_company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS handover_event_to_signature_file_id_fkx ON frt.handover_event (to_signature_file_id);  -- -> ref.file_object
CREATE INDEX IF NOT EXISTS leg_container_container_id_fkx ON frt.leg_container (container_id);  -- -> frt.container
CREATE INDEX IF NOT EXISTS port_appointment_leg_id_fkx ON frt.port_appointment (leg_id);  -- -> ship.shipment_leg
CREATE INDEX IF NOT EXISTS port_appointment_port_station_id_fkx ON frt.port_appointment (port_station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS port_appointment_truck_vehicle_id_fkx ON frt.port_appointment (truck_vehicle_id);  -- -> fleet.truck_unit
CREATE INDEX IF NOT EXISTS transit_declaration_corridor_id_fkx ON frt.transit_declaration (corridor_id);  -- -> net.corridor
CREATE INDEX IF NOT EXISTS transit_declaration_entry_station_id_fkx ON frt.transit_declaration (entry_station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS transit_declaration_exit_station_id_fkx ON frt.transit_declaration (exit_station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS transit_declaration_leg_id_fkx ON frt.transit_declaration (leg_id);  -- -> ship.shipment_leg
CREATE INDEX IF NOT EXISTS weighbridge_reading_leg_id_fkx ON frt.weighbridge_reading (leg_id);  -- -> ship.shipment_leg
CREATE INDEX IF NOT EXISTS weighbridge_reading_station_id_fkx ON frt.weighbridge_reading (station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS weighbridge_reading_vehicle_id_fkx ON frt.weighbridge_reading (vehicle_id);  -- -> fleet.vehicle
CREATE INDEX IF NOT EXISTS feature_compliance_review_dpia_file_id_fkx ON gov.feature_compliance_review (dpia_file_id);  -- -> ref.file_object
CREATE INDEX IF NOT EXISTS obligation_register_evidence_file_id_fkx ON gov.obligation_register (evidence_file_id);  -- -> ref.file_object
CREATE INDEX IF NOT EXISTS obligation_register_owner_user_id_fkx ON gov.obligation_register (owner_user_id);  -- -> iam.app_user
CREATE INDEX IF NOT EXISTS partner_dpa_file_id_fkx ON gov.partner_dpa (file_id);  -- -> ref.file_object
CREATE INDEX IF NOT EXISTS partner_dpa_partner_party_id_fkx ON gov.partner_dpa (partner_party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS policy_change_company_id_fkx ON gov.policy_change (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS policy_change_domain_code_fkx ON gov.policy_change (domain_code);  -- -> gov.policy_domain
CREATE INDEX IF NOT EXISTS privacy_incident_security_event_id_fkx ON gov.privacy_incident (security_event_id);  -- -> sec.security_event
CREATE INDEX IF NOT EXISTS subject_request_user_id_fkx ON gov.subject_request (user_id);  -- -> iam.app_user
CREATE INDEX IF NOT EXISTS api_client_company_id_fkx ON iam.api_client (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS api_client_owner_party_id_fkx ON iam.api_client (owner_party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS api_key_api_client_id_fkx ON iam.api_key (api_client_id);  -- -> iam.api_client
CREATE INDEX IF NOT EXISTS auth_token_user_id_fkx ON iam.auth_token (user_id);  -- -> iam.app_user
CREATE INDEX IF NOT EXISTS bank_account_enc_key_id_fkx ON iam.bank_account (enc_key_id);  -- -> sec.key_registry
CREATE INDEX IF NOT EXISTS beneficial_owner_party_id_fkx ON iam.beneficial_owner (party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS biometric_template_enc_key_id_fkx ON iam.biometric_template (enc_key_id);  -- -> sec.key_registry
CREATE INDEX IF NOT EXISTS company_payout_bank_account_id_fkx ON iam.company (payout_bank_account_id);  -- -> iam.bank_account
CREATE INDEX IF NOT EXISTS company_member_role_id_fkx ON iam.company_member (role_id);  -- -> iam.role
CREATE INDEX IF NOT EXISTS device_permission_state_user_id_fkx ON iam.device_permission_state (user_id);  -- -> iam.app_user
CREATE INDEX IF NOT EXISTS document_enc_key_id_fkx ON iam.document (enc_key_id);  -- -> sec.key_registry
CREATE INDEX IF NOT EXISTS document_file_id_fkx ON iam.document (file_id);  -- -> ref.file_object
CREATE INDEX IF NOT EXISTS gov_identity_link_provider_id_fkx ON iam.gov_identity_link (provider_id);  -- -> iam.identity_provider
CREATE INDEX IF NOT EXISTS mfa_factor_enc_key_id_fkx ON iam.mfa_factor (enc_key_id);  -- -> sec.key_registry
CREATE INDEX IF NOT EXISTS party_enc_key_id_fkx ON iam.party (enc_key_id);  -- -> sec.key_registry
CREATE INDEX IF NOT EXISTS role_company_id_fkx ON iam.role (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS role_permission_permission_code_fkx ON iam.role_permission (permission_code);  -- -> iam.permission
CREATE INDEX IF NOT EXISTS user_role_role_id_fkx ON iam.user_role (role_id);  -- -> iam.role
CREATE INDEX IF NOT EXISTS user_session_company_id_fkx ON iam.user_session (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS user_session_device_id_fkx ON iam.user_session (device_id);  -- -> iam.device
CREATE INDEX IF NOT EXISTS verification_provider_id_fkx ON iam.verification (provider_id);  -- -> iam.identity_provider
CREATE INDEX IF NOT EXISTS approved_rest_stop_station_id_fkx ON net.approved_rest_stop (station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS geofence_station_id_fkx ON net.geofence (station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS line_fare_from_station_id_fkx ON net.line_fare (from_station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS line_fare_to_station_id_fkx ON net.line_fare (to_station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS line_permit_company_id_fkx ON net.line_permit (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS line_stop_station_id_fkx ON net.line_stop (station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS line_version_approval_user_id_fkx ON net.line_version_approval (user_id);  -- -> iam.app_user
CREATE INDEX IF NOT EXISTS route_dest_station_id_fkx ON net.route (dest_station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS route_origin_station_id_fkx ON net.route (origin_station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS route_stop_station_id_fkx ON net.route_stop (station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS service_number_route_id_fkx ON net.service_number (route_id);  -- -> net.route
CREATE INDEX IF NOT EXISTS station_compliance_profile_id_fkx ON net.station (compliance_profile_id);  -- -> net.compliance_profile
CREATE INDEX IF NOT EXISTS station_owner_company_id_fkx ON net.station (owner_company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS station_contact_station_id_fkx ON net.station_contact (station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS station_display_gate_id_fkx ON net.station_display (gate_id);  -- -> net.station_gate
CREATE INDEX IF NOT EXISTS station_display_station_id_fkx ON net.station_display (station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS timetable_template_company_id_fkx ON net.timetable_template (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS timetable_template_line_id_fkx ON net.timetable_template (line_id);  -- -> net.line
CREATE INDEX IF NOT EXISTS crossing_event_station_id_fkx ON ops.crossing_event (station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS driver_notice_trip_id_fkx ON ops.driver_notice (trip_id);  -- -> ops.trip
CREATE INDEX IF NOT EXISTS incident_company_id_fkx ON ops.incident (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS incident_driver_party_id_fkx ON ops.incident (driver_party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS incident_trip_id_fkx ON ops.incident (trip_id);  -- -> ops.trip
CREATE INDEX IF NOT EXISTS incident_vehicle_id_fkx ON ops.incident (vehicle_id);  -- -> fleet.vehicle
CREATE INDEX IF NOT EXISTS incident_evidence_file_id_fkx ON ops.incident_evidence (file_id);  -- -> ref.file_object
CREATE INDEX IF NOT EXISTS incident_evidence_incident_id_fkx ON ops.incident_evidence (incident_id);  -- -> ops.incident
CREATE INDEX IF NOT EXISTS permission_event_device_id_fkx ON ops.permission_event (device_id);  -- -> iam.device
CREATE INDEX IF NOT EXISTS permission_event_user_id_fkx ON ops.permission_event (user_id);  -- -> iam.app_user
CREATE INDEX IF NOT EXISTS presence_beacon_vehicle_id_fkx ON ops.presence_beacon (vehicle_id);  -- -> fleet.vehicle
CREATE INDEX IF NOT EXISTS ride_segment_charge_ledger_txn_id_fkx ON ops.ride_segment_charge (ledger_txn_id);  -- -> fin.ledger_txn
CREATE INDEX IF NOT EXISTS seat_lock_user_id_fkx ON ops.seat_lock (user_id);  -- -> iam.app_user
CREATE INDEX IF NOT EXISTS seat_segment_ticket_id_fkx ON ops.seat_segment (ticket_id);  -- -> sales.ticket
CREATE INDEX IF NOT EXISTS shuttle_ride_alight_station_id_fkx ON ops.shuttle_ride (alight_station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS shuttle_ride_board_station_id_fkx ON ops.shuttle_ride (board_station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS shuttle_ride_boarding_event_id_fkx ON ops.shuttle_ride (boarding_event_id);  -- -> sales.boarding_event
CREATE INDEX IF NOT EXISTS shuttle_ride_line_id_fkx ON ops.shuttle_ride (line_id);  -- -> net.line
CREATE INDEX IF NOT EXISTS shuttle_ride_tariff_id_fkx ON ops.shuttle_ride (tariff_id);  -- -> net.line_tariff
CREATE INDEX IF NOT EXISTS shuttle_ride_wallet_id_fkx ON ops.shuttle_ride (wallet_id);  -- -> fin.wallet
CREATE INDEX IF NOT EXISTS tracking_state_driver_user_id_fkx ON ops.tracking_state (driver_user_id);  -- -> iam.app_user
CREATE INDEX IF NOT EXISTS trip_corridor_id_fkx ON ops.trip (corridor_id);  -- -> net.corridor
CREATE INDEX IF NOT EXISTS trip_line_version_id_fkx ON ops.trip (line_version_id);  -- -> net.line_version
CREATE INDEX IF NOT EXISTS trip_service_number_id_fkx ON ops.trip (service_number_id);  -- -> net.service_number
CREATE INDEX IF NOT EXISTS trip_template_id_fkx ON ops.trip (template_id);  -- -> ops.trip_template
CREATE INDEX IF NOT EXISTS trip_change_trip_id_fkx ON ops.trip_change (trip_id);  -- -> ops.trip
CREATE INDEX IF NOT EXISTS trip_crossing_plan_entry_station_id_fkx ON ops.trip_crossing_plan (entry_station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS trip_crossing_plan_exit_station_id_fkx ON ops.trip_crossing_plan (exit_station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS trip_disruption_incident_id_fkx ON ops.trip_disruption (incident_id);  -- -> ops.incident
CREATE INDEX IF NOT EXISTS trip_disruption_partner_company_id_fkx ON ops.trip_disruption (partner_company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS trip_disruption_replacement_vehicle_id_fkx ON ops.trip_disruption (replacement_vehicle_id);  -- -> fleet.vehicle
CREATE INDEX IF NOT EXISTS trip_disruption_trip_id_fkx ON ops.trip_disruption (trip_id);  -- -> ops.trip
CREATE INDEX IF NOT EXISTS trip_stop_gate_id_fkx ON ops.trip_stop (gate_id);  -- -> net.station_gate
CREATE INDEX IF NOT EXISTS trip_stop_station_id_fkx ON ops.trip_stop (station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS trip_stop_event_trip_id_fkx ON ops.trip_stop_event (trip_id);  -- -> ops.trip
CREATE INDEX IF NOT EXISTS trip_stop_event_trip_id_seq_fkx ON ops.trip_stop_event (trip_id,seq);  -- -> ops.trip_stop
CREATE INDEX IF NOT EXISTS trip_template_company_id_fkx ON ops.trip_template (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS trip_template_default_vehicle_id_fkx ON ops.trip_template (default_vehicle_id);  -- -> fleet.vehicle
CREATE INDEX IF NOT EXISTS trip_template_route_id_fkx ON ops.trip_template (route_id);  -- -> net.route
CREATE INDEX IF NOT EXISTS trip_template_service_number_id_fkx ON ops.trip_template (service_number_id);  -- -> net.service_number
CREATE INDEX IF NOT EXISTS vehicle_swap_from_vehicle_id_fkx ON ops.vehicle_swap (from_vehicle_id);  -- -> fleet.vehicle
CREATE INDEX IF NOT EXISTS vehicle_swap_to_vehicle_id_fkx ON ops.vehicle_swap (to_vehicle_id);  -- -> fleet.vehicle
CREATE INDEX IF NOT EXISTS vehicle_swap_trip_id_fkx ON ops.vehicle_swap (trip_id);  -- -> ops.trip
CREATE INDEX IF NOT EXISTS award_seat_rule_company_id_fkx ON pricing.award_seat_rule (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS award_seat_rule_line_id_fkx ON pricing.award_seat_rule (line_id);  -- -> net.line
CREATE INDEX IF NOT EXISTS award_seat_rule_route_id_fkx ON pricing.award_seat_rule (route_id);  -- -> net.route
CREATE INDEX IF NOT EXISTS bin_range_bank_party_id_fkx ON pricing.bin_range (bank_party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS campaign_company_id_fkx ON pricing.campaign (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS campaign_sponsor_account_id_fkx ON pricing.campaign (sponsor_account_id);  -- -> pricing.sponsor_account
CREATE INDEX IF NOT EXISTS fare_brand_company_id_fkx ON pricing.fare_brand (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS fare_table_company_id_fkx ON pricing.fare_table (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS fare_table_route_id_fkx ON pricing.fare_table (route_id);  -- -> net.route
CREATE INDEX IF NOT EXISTS fare_table_item_from_station_id_fkx ON pricing.fare_table_item (from_station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS fare_table_item_to_station_id_fkx ON pricing.fare_table_item (to_station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS jurisdiction_parent_id_fkx ON pricing.jurisdiction (parent_id);  -- -> pricing.jurisdiction
CREATE INDEX IF NOT EXISTS loyalty_partner_party_id_fkx ON pricing.loyalty_partner (party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS loyalty_partner_service_partner_id_fkx ON pricing.loyalty_partner (service_partner_id);  -- -> ptn.partner
CREATE INDEX IF NOT EXISTS loyalty_rule_program_id_fkx ON pricing.loyalty_rule (program_id);  -- -> pricing.loyalty_program
CREATE INDEX IF NOT EXISTS override_policy_company_id_fkx ON pricing.override_policy (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS override_policy_user_id_fkx ON pricing.override_policy (user_id);  -- -> iam.app_user
CREATE INDEX IF NOT EXISTS partner_redemption_loyalty_partner_id_fkx ON pricing.partner_redemption (loyalty_partner_id);  -- -> pricing.loyalty_partner
CREATE INDEX IF NOT EXISTS partner_redemption_partner_sale_id_fkx ON pricing.partner_redemption (partner_sale_id);  -- -> ptn.partner_sale
CREATE INDEX IF NOT EXISTS partner_redemption_token_id_fkx ON pricing.partner_redemption (token_id);  -- -> pricing.redemption_token
CREATE INDEX IF NOT EXISTS partner_redemption_voucher_id_fkx ON pricing.partner_redemption (voucher_id);  -- -> pricing.reward_voucher
CREATE INDEX IF NOT EXISTS points_account_party_id_fkx ON pricing.points_account (party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS points_account_tier_id_fkx ON pricing.points_account (tier_id);  -- -> pricing.loyalty_tier
CREATE INDEX IF NOT EXISTS points_ledger_booking_id_fkx ON pricing.points_ledger (booking_id);  -- -> sales.booking
CREATE INDEX IF NOT EXISTS points_ledger_reverses_id_fkx ON pricing.points_ledger (reverses_id);  -- -> pricing.points_ledger
CREATE INDEX IF NOT EXISTS points_ledger_rule_id_fkx ON pricing.points_ledger (rule_id);  -- -> pricing.loyalty_rule
CREATE INDEX IF NOT EXISTS points_liability_issuer_party_id_fkx ON pricing.points_liability (issuer_party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS points_transfer_account_id_fkx ON pricing.points_transfer (account_id);  -- -> pricing.points_account
CREATE INDEX IF NOT EXISTS points_transfer_loyalty_partner_id_fkx ON pricing.points_transfer (loyalty_partner_id);  -- -> pricing.loyalty_partner
CREATE INDEX IF NOT EXISTS points_transfer_points_ledger_id_fkx ON pricing.points_transfer (points_ledger_id);  -- -> pricing.points_ledger
CREATE INDEX IF NOT EXISTS pricing_modifier_company_id_fkx ON pricing.pricing_modifier (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS promo_code_campaign_id_fkx ON pricing.promo_code (campaign_id);  -- -> pricing.campaign
CREATE INDEX IF NOT EXISTS promo_code_owner_party_id_fkx ON pricing.promo_code (owner_party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS rate_band_commission_rule_id_fkx ON pricing.rate_band (commission_rule_id);  -- -> pricing.commission_rule
CREATE INDEX IF NOT EXISTS rate_band_tax_rule_id_fkx ON pricing.rate_band (tax_rule_id);  -- -> pricing.tax_rule
CREATE INDEX IF NOT EXISTS redemption_token_channel_code_fkx ON pricing.redemption_token (channel_code);  -- -> pricing.redemption_channel
CREATE INDEX IF NOT EXISTS redemption_token_user_id_fkx ON pricing.redemption_token (user_id);  -- -> iam.app_user
CREATE INDEX IF NOT EXISTS reward_catalog_loyalty_partner_id_fkx ON pricing.reward_catalog (loyalty_partner_id);  -- -> pricing.loyalty_partner
CREATE INDEX IF NOT EXISTS reward_catalog_program_id_fkx ON pricing.reward_catalog (program_id);  -- -> pricing.loyalty_program
CREATE INDEX IF NOT EXISTS reward_voucher_catalog_id_fkx ON pricing.reward_voucher (catalog_id);  -- -> pricing.reward_catalog
CREATE INDEX IF NOT EXISTS reward_voucher_loyalty_partner_id_fkx ON pricing.reward_voucher (loyalty_partner_id);  -- -> pricing.loyalty_partner
CREATE INDEX IF NOT EXISTS reward_voucher_points_ledger_id_fkx ON pricing.reward_voucher (points_ledger_id);  -- -> pricing.points_ledger
CREATE INDEX IF NOT EXISTS reward_voucher_user_id_fkx ON pricing.reward_voucher (user_id);  -- -> iam.app_user
CREATE INDEX IF NOT EXISTS sponsor_account_wallet_id_fkx ON pricing.sponsor_account (wallet_id);  -- -> fin.wallet
CREATE INDEX IF NOT EXISTS tax_scheme_jurisdiction_id_fkx ON pricing.tax_scheme (jurisdiction_id);  -- -> pricing.jurisdiction
CREATE INDEX IF NOT EXISTS tax_scheme_payable_to_party_id_fkx ON pricing.tax_scheme (payable_to_party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS fuel_anomaly_session_id_fkx ON ptn.fuel_anomaly (session_id);  -- -> ptn.fuel_session
CREATE INDEX IF NOT EXISTS fuel_card_company_id_fkx ON ptn.fuel_card (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS fuel_card_driver_party_id_fkx ON ptn.fuel_card (driver_party_id);  -- -> fleet.crew_profile
CREATE INDEX IF NOT EXISTS fuel_card_vehicle_id_fkx ON ptn.fuel_card (vehicle_id);  -- -> fleet.vehicle
CREATE INDEX IF NOT EXISTS fuel_session_company_id_fkx ON ptn.fuel_session (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS fuel_session_driver_party_id_fkx ON ptn.fuel_session (driver_party_id);  -- -> fleet.crew_profile
CREATE INDEX IF NOT EXISTS fuel_session_fuel_card_id_fkx ON ptn.fuel_session (fuel_card_id);  -- -> ptn.fuel_card
CREATE INDEX IF NOT EXISTS fuel_session_partner_id_fkx ON ptn.fuel_session (partner_id);  -- -> ptn.partner
CREATE INDEX IF NOT EXISTS fuel_session_station_employee_id_fkx ON ptn.fuel_session (station_employee_id);  -- -> ptn.station_employee
CREATE INDEX IF NOT EXISTS fuel_session_trip_id_fkx ON ptn.fuel_session (trip_id);  -- -> ops.trip
CREATE INDEX IF NOT EXISTS fuel_session_vehicle_id_fkx ON ptn.fuel_session (vehicle_id);  -- -> fleet.vehicle
CREATE INDEX IF NOT EXISTS odometer_reading_photo_file_id_fkx ON ptn.odometer_reading (photo_file_id);  -- -> ref.file_object
CREATE INDEX IF NOT EXISTS odometer_reading_session_id_fkx ON ptn.odometer_reading (session_id);  -- -> ptn.fuel_session
CREATE INDEX IF NOT EXISTS partner_station_id_fkx ON ptn.partner (station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS partner_menu_item_partner_id_fkx ON ptn.partner_menu_item (partner_id);  -- -> ptn.partner
CREATE INDEX IF NOT EXISTS partner_order_partner_id_fkx ON ptn.partner_order (partner_id);  -- -> ptn.partner
CREATE INDEX IF NOT EXISTS partner_order_trip_id_fkx ON ptn.partner_order (trip_id);  -- -> ops.trip
CREATE INDEX IF NOT EXISTS partner_order_user_id_fkx ON ptn.partner_order (user_id);  -- -> iam.app_user
CREATE INDEX IF NOT EXISTS partner_order_item_menu_item_id_fkx ON ptn.partner_order_item (menu_item_id);  -- -> ptn.partner_menu_item
CREATE INDEX IF NOT EXISTS partner_sale_company_id_fkx ON ptn.partner_sale (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS partner_sale_driver_party_id_fkx ON ptn.partner_sale (driver_party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS partner_sale_ledger_txn_id_fkx ON ptn.partner_sale (ledger_txn_id);  -- -> fin.ledger_txn
CREATE INDEX IF NOT EXISTS partner_sale_trip_id_fkx ON ptn.partner_sale (trip_id);  -- -> ops.trip
CREATE INDEX IF NOT EXISTS partner_sale_user_id_fkx ON ptn.partner_sale (user_id);  -- -> iam.app_user
CREATE INDEX IF NOT EXISTS partner_sale_vehicle_id_fkx ON ptn.partner_sale (vehicle_id);  -- -> fleet.vehicle
CREATE INDEX IF NOT EXISTS partner_settlement_ledger_txn_id_fkx ON ptn.partner_settlement (ledger_txn_id);  -- -> fin.ledger_txn
CREATE INDEX IF NOT EXISTS rest_stop_rating_trip_id_fkx ON ptn.rest_stop_rating (trip_id);  -- -> ops.trip
CREATE INDEX IF NOT EXISTS rest_stop_rating_user_id_fkx ON ptn.rest_stop_rating (user_id);  -- -> iam.app_user
CREATE INDEX IF NOT EXISTS station_employee_user_id_fkx ON ptn.station_employee (user_id);  -- -> iam.app_user
CREATE INDEX IF NOT EXISTS coach_layout_fare_class_id_fkx ON rail.coach_layout (fare_class_id);  -- -> rail.fare_class
CREATE INDEX IF NOT EXISTS coach_layout_seat_layout_id_fkx ON rail.coach_layout (seat_layout_id);  -- -> fleet.seat_layout
CREATE INDEX IF NOT EXISTS journey_dest_station_id_fkx ON rail.journey (dest_station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS journey_origin_station_id_fkx ON rail.journey (origin_station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS journey_party_id_fkx ON rail.journey (party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS journey_leg_trip_id_fkx ON rail.journey_leg (trip_id);  -- -> ops.trip
CREATE INDEX IF NOT EXISTS train_composition_coach_layout_id_fkx ON rail.train_composition (coach_layout_id);  -- -> rail.coach_layout
CREATE INDEX IF NOT EXISTS file_object_company_id_fkx ON ref.file_object (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS file_object_enc_key_id_fkx ON ref.file_object (enc_key_id);  -- -> sec.key_registry
CREATE INDEX IF NOT EXISTS contract_driver_party_id_fkx ON rent.contract_driver (party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS deposit_hold_case_id_fkx ON rent.deposit_hold (case_id);  -- -> crm.case
CREATE INDEX IF NOT EXISTS deposit_hold_contract_id_fkx ON rent.deposit_hold (contract_id);  -- -> rent.rental_contract
CREATE INDEX IF NOT EXISTS deposit_hold_wallet_id_fkx ON rent.deposit_hold (wallet_id);  -- -> fin.wallet
CREATE INDEX IF NOT EXISTS rental_booking_company_id_fkx ON rent.rental_booking (company_id);  -- -> rent.rental_company
CREATE INDEX IF NOT EXISTS rental_booking_pickup_branch_id_fkx ON rent.rental_booking (pickup_branch_id);  -- -> rent.rental_branch
CREATE INDEX IF NOT EXISTS rental_booking_rate_id_fkx ON rent.rental_booking (rate_id);  -- -> rent.rental_rate
CREATE INDEX IF NOT EXISTS rental_booking_rental_class_fkx ON rent.rental_booking (rental_class);  -- -> rent.rental_vehicle_class
CREATE INDEX IF NOT EXISTS rental_booking_renter_party_id_fkx ON rent.rental_booking (renter_party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS rental_booking_return_branch_id_fkx ON rent.rental_booking (return_branch_id);  -- -> rent.rental_branch
CREATE INDEX IF NOT EXISTS rental_booking_addon_addon_id_fkx ON rent.rental_booking_addon (addon_id);  -- -> rent.rental_addon
CREATE INDEX IF NOT EXISTS rental_branch_station_id_fkx ON rent.rental_branch (station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS rental_contract_signature_file_id_fkx ON rent.rental_contract (signature_file_id);  -- -> ref.file_object
CREATE INDEX IF NOT EXISTS rental_contract_vehicle_id_fkx ON rent.rental_contract (vehicle_id);  -- -> rent.rental_fleet
CREATE INDEX IF NOT EXISTS rental_fleet_company_id_fkx ON rent.rental_fleet (company_id);  -- -> rent.rental_company
CREATE INDEX IF NOT EXISTS rental_fleet_home_branch_id_fkx ON rent.rental_fleet (home_branch_id);  -- -> rent.rental_branch
CREATE INDEX IF NOT EXISTS rental_fleet_rental_class_fkx ON rent.rental_fleet (rental_class);  -- -> rent.rental_vehicle_class
CREATE INDEX IF NOT EXISTS rental_inspection_inspector_user_id_fkx ON rent.rental_inspection (inspector_user_id);  -- -> iam.app_user
CREATE INDEX IF NOT EXISTS rental_rate_branch_id_fkx ON rent.rental_rate (branch_id);  -- -> rent.rental_branch
CREATE INDEX IF NOT EXISTS rental_rate_company_id_fkx ON rent.rental_rate (company_id);  -- -> rent.rental_company
CREATE INDEX IF NOT EXISTS rental_rate_rental_class_fkx ON rent.rental_rate (rental_class);  -- -> rent.rental_vehicle_class
CREATE INDEX IF NOT EXISTS renter_rule_rental_class_fkx ON rent.renter_rule (rental_class);  -- -> rent.rental_vehicle_class
CREATE INDEX IF NOT EXISTS telematics_device_company_id_fkx ON rent.telematics_device (company_id);  -- -> rent.rental_company
CREATE INDEX IF NOT EXISTS vehicle_trip_log_contract_id_fkx ON rent.vehicle_trip_log (contract_id);  -- -> rent.rental_contract
CREATE INDEX IF NOT EXISTS vehicle_trip_log_device_id_fkx ON rent.vehicle_trip_log (device_id);  -- -> rent.telematics_device
CREATE INDEX IF NOT EXISTS vehicle_trip_log_vehicle_id_fkx ON rent.vehicle_trip_log (vehicle_id);  -- -> fleet.vehicle
CREATE INDEX IF NOT EXISTS boarding_event_device_id_fkx ON sales.boarding_event (device_id);  -- -> iam.device
CREATE INDEX IF NOT EXISTS boarding_event_nfc_card_id_fkx ON sales.boarding_event (nfc_card_id);  -- -> sales.nfc_card
CREATE INDEX IF NOT EXISTS boarding_event_ticket_id_fkx ON sales.boarding_event (ticket_id);  -- -> sales.ticket
CREATE INDEX IF NOT EXISTS boarding_event_validator_id_fkx ON sales.boarding_event (validator_id);  -- -> fleet.boarding_validator
CREATE INDEX IF NOT EXISTS boarding_event_vehicle_tag_id_fkx ON sales.boarding_event (vehicle_tag_id);  -- -> fleet.vehicle_qr_tag
CREATE INDEX IF NOT EXISTS booking_booker_user_id_fkx ON sales.booking (booker_user_id);  -- -> iam.app_user
CREATE INDEX IF NOT EXISTS booking_channel_id_fkx ON sales.booking (channel_id);  -- -> sales.channel
CREATE INDEX IF NOT EXISTS booking_price_allocation_id_fkx ON sales.booking (price_allocation_id);  -- -> fin.price_allocation
CREATE INDEX IF NOT EXISTS campaign_redemption_booking_id_fkx ON sales.campaign_redemption (booking_id);  -- -> sales.booking
CREATE INDEX IF NOT EXISTS campaign_redemption_party_id_fkx ON sales.campaign_redemption (party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS campaign_redemption_promo_code_id_fkx ON sales.campaign_redemption (promo_code_id);  -- -> pricing.promo_code
CREATE INDEX IF NOT EXISTS channel_api_client_id_fkx ON sales.channel (api_client_id);  -- -> iam.api_client
CREATE INDEX IF NOT EXISTS channel_party_id_fkx ON sales.channel (party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS channel_agreement_commission_scheme_id_fkx ON sales.channel_agreement (commission_scheme_id);  -- -> pricing.commission_scheme
CREATE INDEX IF NOT EXISTS channel_agreement_company_id_fkx ON sales.channel_agreement (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS channel_inventory_rule_channel_id_fkx ON sales.channel_inventory_rule (channel_id);  -- -> sales.channel
CREATE INDEX IF NOT EXISTS channel_inventory_rule_company_id_fkx ON sales.channel_inventory_rule (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS channel_inventory_rule_route_id_fkx ON sales.channel_inventory_rule (route_id);  -- -> net.route
CREATE INDEX IF NOT EXISTS channel_memo_channel_id_fkx ON sales.channel_memo (channel_id);  -- -> sales.channel
CREATE INDEX IF NOT EXISTS channel_memo_statement_id_fkx ON sales.channel_memo (statement_id);  -- -> sales.channel_statement
CREATE INDEX IF NOT EXISTS channel_statement_ledger_txn_id_fkx ON sales.channel_statement (ledger_txn_id);  -- -> fin.ledger_txn
CREATE INDEX IF NOT EXISTS channel_statement_line_booking_id_fkx ON sales.channel_statement_line (booking_id);  -- -> sales.booking
CREATE INDEX IF NOT EXISTS inspection_check_boarding_event_id_fkx ON sales.inspection_check (boarding_event_id);  -- -> sales.boarding_event
CREATE INDEX IF NOT EXISTS inspection_check_company_id_fkx ON sales.inspection_check (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS inspection_check_inspector_party_id_fkx ON sales.inspection_check (inspector_party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS inspection_check_trip_id_fkx ON sales.inspection_check (trip_id);  -- -> ops.trip
CREATE INDEX IF NOT EXISTS inspection_check_vehicle_id_fkx ON sales.inspection_check (vehicle_id);  -- -> fleet.vehicle
CREATE INDEX IF NOT EXISTS nfc_card_party_id_fkx ON sales.nfc_card (party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS nfc_card_wallet_id_fkx ON sales.nfc_card (wallet_id);  -- -> fin.wallet
CREATE INDEX IF NOT EXISTS passenger_enc_key_id_fkx ON sales.passenger (enc_key_id);  -- -> sec.key_registry
CREATE INDEX IF NOT EXISTS passenger_party_id_fkx ON sales.passenger (party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS passenger_compensation_booking_id_fkx ON sales.passenger_compensation (booking_id);  -- -> sales.booking
CREATE INDEX IF NOT EXISTS passenger_compensation_charged_to_company_id_fkx ON sales.passenger_compensation (charged_to_company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS passenger_compensation_credit_note_id_fkx ON sales.passenger_compensation (credit_note_id);  -- -> acct.einvoice_document
CREATE INDEX IF NOT EXISTS passenger_compensation_trip_disruption_id_fkx ON sales.passenger_compensation (trip_disruption_id);  -- -> ops.trip_disruption
CREATE INDEX IF NOT EXISTS refund_request_booking_id_fkx ON sales.refund_request (booking_id);  -- -> sales.booking
CREATE INDEX IF NOT EXISTS refund_request_credit_note_id_fkx ON sales.refund_request (credit_note_id);  -- -> acct.einvoice_document
CREATE INDEX IF NOT EXISTS refund_request_ticket_id_fkx ON sales.refund_request (ticket_id);  -- -> sales.ticket
CREATE INDEX IF NOT EXISTS shuttle_pass_nfc_card_id_fkx ON sales.shuttle_pass (nfc_card_id);  -- -> sales.nfc_card
CREATE INDEX IF NOT EXISTS shuttle_pass_subscription_id_fkx ON sales.shuttle_pass (subscription_id);  -- -> sales.subscription
CREATE INDEX IF NOT EXISTS subscription_company_id_fkx ON sales.subscription (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS subscription_ledger_txn_id_fkx ON sales.subscription (ledger_txn_id);  -- -> fin.ledger_txn
CREATE INDEX IF NOT EXISTS subscription_party_id_fkx ON sales.subscription (party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS subscription_plan_id_fkx ON sales.subscription (plan_id);  -- -> sales.subscription_plan
CREATE INDEX IF NOT EXISTS subscription_wallet_id_fkx ON sales.subscription (wallet_id);  -- -> fin.wallet
CREATE INDEX IF NOT EXISTS subscription_plan_line_id_fkx ON sales.subscription_plan (line_id);  -- -> net.line
CREATE INDEX IF NOT EXISTS subscription_plan_zone_id_fkx ON sales.subscription_plan (zone_id);  -- -> sales.shuttle_zone
CREATE INDEX IF NOT EXISTS supplier_source_company_id_fkx ON sales.supplier_source (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS ticket_fare_brand_code_fkx ON sales.ticket (fare_brand_code);  -- -> pricing.fare_brand
CREATE INDEX IF NOT EXISTS ticket_passenger_id_fkx ON sales.ticket (passenger_id);  -- -> sales.passenger
CREATE INDEX IF NOT EXISTS ticket_qr_key_id_fkx ON sales.ticket (qr_key_id);  -- -> sec.key_registry
CREATE INDEX IF NOT EXISTS ticket_doc_enc_key_id_fkx ON sales.ticket_doc (enc_key_id);  -- -> sec.key_registry
CREATE INDEX IF NOT EXISTS ticket_doc_entry_rule_id_fkx ON sales.ticket_doc (entry_rule_id);  -- -> sales.entry_rule
CREATE INDEX IF NOT EXISTS waitlist_entry_booking_id_fkx ON sales.waitlist_entry (booking_id);  -- -> sales.booking
CREATE INDEX IF NOT EXISTS waitlist_entry_party_id_fkx ON sales.waitlist_entry (party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS access_review_role_id_fkx ON sec.access_review (role_id);  -- -> iam.role
CREATE INDEX IF NOT EXISTS access_review_user_id_fkx ON sec.access_review (user_id);  -- -> iam.app_user
CREATE INDEX IF NOT EXISTS authority_alert_authority_id_fkx ON sec.authority_alert (authority_id);  -- -> sec.authority_profile
CREATE INDEX IF NOT EXISTS authority_alert_evidence_file_id_fkx ON sec.authority_alert (evidence_file_id);  -- -> ref.file_object
CREATE INDEX IF NOT EXISTS authority_alert_trip_id_fkx ON sec.authority_alert (trip_id);  -- -> ops.trip
CREATE INDEX IF NOT EXISTS authority_alert_vehicle_id_fkx ON sec.authority_alert (vehicle_id);  -- -> fleet.vehicle
CREATE INDEX IF NOT EXISTS authority_data_request_authority_id_fkx ON sec.authority_data_request (authority_id);  -- -> sec.authority_profile
CREATE INDEX IF NOT EXISTS authority_policy_authority_id_fkx ON sec.authority_policy (authority_id);  -- -> sec.authority_profile
CREATE INDEX IF NOT EXISTS document_signature_file_id_fkx ON sec.document_signature (file_id);  -- -> ref.file_object
CREATE INDEX IF NOT EXISTS document_signature_key_id_fkx ON sec.document_signature (key_id);  -- -> sec.key_registry
CREATE INDEX IF NOT EXISTS fraud_case_assigned_to_fkx ON sec.fraud_case (assigned_to);  -- -> iam.app_user
CREATE INDEX IF NOT EXISTS ip_rule_api_client_id_fkx ON sec.ip_rule (api_client_id);  -- -> iam.api_client
CREATE INDEX IF NOT EXISTS key_registry_company_id_fkx ON sec.key_registry (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS manifest_submission_authority_id_fkx ON sec.manifest_submission (authority_id);  -- -> sec.authority_profile
CREATE INDEX IF NOT EXISTS manifest_submission_payload_file_id_fkx ON sec.manifest_submission (payload_file_id);  -- -> ref.file_object
CREATE INDEX IF NOT EXISTS screening_request_authority_id_fkx ON sec.screening_request (authority_id);  -- -> sec.authority_profile
CREATE INDEX IF NOT EXISTS security_event_ip_rule_id_fkx ON sec.security_event (ip_rule_id);  -- -> sec.ip_rule
CREATE INDEX IF NOT EXISTS sos_event_incident_id_fkx ON sec.sos_event (incident_id);  -- -> ops.incident
CREATE INDEX IF NOT EXISTS sos_event_trip_id_fkx ON sec.sos_event (trip_id);  -- -> ops.trip
CREATE INDEX IF NOT EXISTS verification_job_adapter_id_fkx ON sec.verification_job (adapter_id);  -- -> sec.gov_adapter_config
CREATE INDEX IF NOT EXISTS verification_job_verification_id_fkx ON sec.verification_job (verification_id);  -- -> iam.verification
CREATE INDEX IF NOT EXISTS watchlist_entry_authority_id_fkx ON sec.watchlist_entry (authority_id);  -- -> sec.authority_profile
CREATE INDEX IF NOT EXISTS access_point_partner_party_id_fkx ON ship.access_point (partner_party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS address_geo_zone_id_fkx ON ship.address (geo_zone_id);  -- -> ship.geo_zone
CREATE INDEX IF NOT EXISTS address_party_id_fkx ON ship.address (party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS capacity_booking_buyer_company_id_fkx ON ship.capacity_booking (buyer_company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS capacity_booking_load_id_fkx ON ship.capacity_booking (load_id);  -- -> ship.load
CREATE INDEX IF NOT EXISTS capacity_booking_route_id_fkx ON ship.capacity_booking (route_id);  -- -> net.route
CREATE INDEX IF NOT EXISTS capacity_booking_seller_company_id_fkx ON ship.capacity_booking (seller_company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS capacity_booking_trip_id_fkx ON ship.capacity_booking (trip_id);  -- -> ops.trip
CREATE INDEX IF NOT EXISTS cargo_claim_case_id_fkx ON ship.cargo_claim (case_id);  -- -> crm.case
CREATE INDEX IF NOT EXISTS cargo_claim_liable_leg_id_fkx ON ship.cargo_claim (liable_leg_id);  -- -> ship.shipment_leg
CREATE INDEX IF NOT EXISTS cargo_claim_shipment_id_fkx ON ship.cargo_claim (shipment_id);  -- -> ship.shipment
CREATE INDEX IF NOT EXISTS cargo_rate_card_company_id_fkx ON ship.cargo_rate_card (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS cargo_rate_card_route_id_fkx ON ship.cargo_rate_card (route_id);  -- -> net.route
CREATE INDEX IF NOT EXISTS cargo_rate_card_service_id_fkx ON ship.cargo_rate_card (service_id);  -- -> ship.service_product
CREATE INDEX IF NOT EXISTS carrier_scorecard_access_point_id_fkx ON ship.carrier_scorecard (access_point_id);  -- -> ship.access_point
CREATE INDEX IF NOT EXISTS cod_collection_ledger_txn_id_fkx ON ship.cod_collection (ledger_txn_id);  -- -> fin.ledger_txn
CREATE INDEX IF NOT EXISTS courier_assignment_pickup_request_id_fkx ON ship.courier_assignment (pickup_request_id);  -- -> ship.pickup_request
CREATE INDEX IF NOT EXISTS courier_assignment_shipment_id_fkx ON ship.courier_assignment (shipment_id);  -- -> ship.shipment
CREATE INDEX IF NOT EXISTS courier_route_company_id_fkx ON ship.courier_route (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS courier_route_courier_user_id_fkx ON ship.courier_route (courier_user_id);  -- -> iam.app_user
CREATE INDEX IF NOT EXISTS courier_route_hub_id_fkx ON ship.courier_route (hub_id);  -- -> ship.hub
CREATE INDEX IF NOT EXISTS courier_route_vehicle_id_fkx ON ship.courier_route (vehicle_id);  -- -> fleet.vehicle
CREATE INDEX IF NOT EXISTS custody_transfer_from_party_id_fkx ON ship.custody_transfer (from_party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS custody_transfer_shipment_id_fkx ON ship.custody_transfer (shipment_id);  -- -> ship.shipment
CREATE INDEX IF NOT EXISTS custody_transfer_signature_file_id_fkx ON ship.custody_transfer (signature_file_id);  -- -> ref.file_object
CREATE INDEX IF NOT EXISTS custody_transfer_to_party_id_fkx ON ship.custody_transfer (to_party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS custody_transfer_unit_id_fkx ON ship.custody_transfer (unit_id);  -- -> ship.handling_unit
CREATE INDEX IF NOT EXISTS delivery_attempt_courier_user_id_fkx ON ship.delivery_attempt (courier_user_id);  -- -> iam.app_user
CREATE INDEX IF NOT EXISTS delivery_preference_party_id_fkx ON ship.delivery_preference (party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS delivery_preference_shipment_id_fkx ON ship.delivery_preference (shipment_id);  -- -> ship.shipment
CREATE INDEX IF NOT EXISTS delivery_proof_attempt_id_fkx ON ship.delivery_proof (attempt_id);  -- -> ship.delivery_attempt
CREATE INDEX IF NOT EXISTS delivery_proof_evidence_file_id_fkx ON ship.delivery_proof (evidence_file_id);  -- -> ref.file_object
CREATE INDEX IF NOT EXISTS geo_zone_servicing_hub_id_fkx ON ship.geo_zone (servicing_hub_id);  -- -> ship.hub
CREATE INDEX IF NOT EXISTS guarantee_claim_chargeback_leg_id_fkx ON ship.guarantee_claim (chargeback_leg_id);  -- -> ship.shipment_leg
CREATE INDEX IF NOT EXISTS guarantee_claim_ledger_txn_id_fkx ON ship.guarantee_claim (ledger_txn_id);  -- -> fin.ledger_txn
CREATE INDEX IF NOT EXISTS handling_unit_company_id_fkx ON ship.handling_unit (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS handling_unit_current_station_id_fkx ON ship.handling_unit (current_station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS handling_unit_parent_unit_id_fkx ON ship.handling_unit (parent_unit_id);  -- -> ship.handling_unit
CREATE INDEX IF NOT EXISTS handling_unit_item_shipment_id_fkx ON ship.handling_unit_item (shipment_id);  -- -> ship.shipment
CREATE INDEX IF NOT EXISTS handling_unit_item_unit_id_fkx ON ship.handling_unit_item (unit_id);  -- -> ship.handling_unit
CREATE INDEX IF NOT EXISTS hub_company_id_fkx ON ship.hub (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS integration_message_payload_file_id_fkx ON ship.integration_message (payload_file_id);  -- -> ref.file_object
CREATE INDEX IF NOT EXISTS integration_message_shipment_id_fkx ON ship.integration_message (shipment_id);  -- -> ship.shipment
CREATE INDEX IF NOT EXISTS integration_partner_api_client_id_fkx ON ship.integration_partner (api_client_id);  -- -> iam.api_client
CREATE INDEX IF NOT EXISTS linehaul_schedule_carrier_company_id_fkx ON ship.linehaul_schedule (carrier_company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS linehaul_schedule_dest_hub_id_fkx ON ship.linehaul_schedule (dest_hub_id);  -- -> ship.hub
CREATE INDEX IF NOT EXISTS linehaul_schedule_origin_hub_id_fkx ON ship.linehaul_schedule (origin_hub_id);  -- -> ship.hub
CREATE INDEX IF NOT EXISTS load_company_id_fkx ON ship.load (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS load_dest_hub_id_fkx ON ship.load (dest_hub_id);  -- -> ship.hub
CREATE INDEX IF NOT EXISTS load_origin_hub_id_fkx ON ship.load (origin_hub_id);  -- -> ship.hub
CREATE INDEX IF NOT EXISTS load_truck_combination_id_fkx ON ship.load (truck_combination_id);  -- -> fleet.truck_combination
CREATE INDEX IF NOT EXISTS load_vehicle_id_fkx ON ship.load (vehicle_id);  -- -> fleet.vehicle
CREATE INDEX IF NOT EXISTS load_plan_handling_unit_id_fkx ON ship.load_plan (handling_unit_id);  -- -> ship.handling_unit
CREATE INDEX IF NOT EXISTS load_stop_station_id_fkx ON ship.load_stop (station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS locker_compartment_shipment_id_fkx ON ship.locker_compartment (shipment_id);  -- -> ship.shipment
CREATE INDEX IF NOT EXISTS partner_command_payload_file_id_fkx ON ship.partner_command (payload_file_id);  -- -> ref.file_object
CREATE INDEX IF NOT EXISTS partner_command_shipment_id_fkx ON ship.partner_command (shipment_id);  -- -> ship.shipment
CREATE INDEX IF NOT EXISTS partner_contract_partner_id_fkx ON ship.partner_contract (partner_id);  -- -> ship.integration_partner
CREATE INDEX IF NOT EXISTS partner_settlement_ledger_txn_id_fkx ON ship.partner_settlement (ledger_txn_id);  -- -> fin.ledger_txn
CREATE INDEX IF NOT EXISTS pickup_request_address_id_fkx ON ship.pickup_request (address_id);  -- -> ship.address
CREATE INDEX IF NOT EXISTS pickup_request_company_id_fkx ON ship.pickup_request (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS pickup_request_courier_route_id_fkx ON ship.pickup_request (courier_route_id);  -- -> ship.courier_route
CREATE INDEX IF NOT EXISTS pickup_request_shipper_party_id_fkx ON ship.pickup_request (shipper_party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS pricing_agreement_account_id_fkx ON ship.pricing_agreement (account_id);  -- -> ship.shipper_account
CREATE INDEX IF NOT EXISTS pricing_agreement_company_id_fkx ON ship.pricing_agreement (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS pricing_zone_chart_dest_zone_id_fkx ON ship.pricing_zone_chart (dest_zone_id);  -- -> ship.geo_zone
CREATE INDEX IF NOT EXISTS rate_table_company_id_fkx ON ship.rate_table (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS rate_table_service_id_fkx ON ship.rate_table (service_id);  -- -> ship.service_product
CREATE INDEX IF NOT EXISTS return_authorization_merchant_account_id_fkx ON ship.return_authorization (merchant_account_id);  -- -> ship.shipper_account
CREATE INDEX IF NOT EXISTS return_authorization_original_shipment_id_fkx ON ship.return_authorization (original_shipment_id);  -- -> ship.shipment
CREATE INDEX IF NOT EXISTS routing_rule_company_id_fkx ON ship.routing_rule (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS routing_rule_dest_zone_id_fkx ON ship.routing_rule (dest_zone_id);  -- -> ship.geo_zone
CREATE INDEX IF NOT EXISTS routing_rule_origin_zone_id_fkx ON ship.routing_rule (origin_zone_id);  -- -> ship.geo_zone
CREATE INDEX IF NOT EXISTS routing_rule_service_id_fkx ON ship.routing_rule (service_id);  -- -> ship.service_product
CREATE INDEX IF NOT EXISTS service_option_surcharge_id_fkx ON ship.service_option (surcharge_id);  -- -> ship.surcharge_definition
CREATE INDEX IF NOT EXISTS shipment_dest_address_id_fkx ON ship.shipment (dest_address_id);  -- -> ship.address
CREATE INDEX IF NOT EXISTS shipment_dest_station_id_fkx ON ship.shipment (dest_station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS shipment_origin_address_id_fkx ON ship.shipment (origin_address_id);  -- -> ship.address
CREATE INDEX IF NOT EXISTS shipment_origin_station_id_fkx ON ship.shipment (origin_station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS shipment_payer_account_id_fkx ON ship.shipment (payer_account_id);  -- -> ship.shipper_account
CREATE INDEX IF NOT EXISTS shipment_service_id_fkx ON ship.shipment (service_id);  -- -> ship.service_product
CREATE INDEX IF NOT EXISTS shipment_shipper_account_id_fkx ON ship.shipment (shipper_account_id);  -- -> ship.shipper_account
CREATE INDEX IF NOT EXISTS shipment_leg_carrier_company_id_fkx ON ship.shipment_leg (carrier_company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS shipment_leg_courier_route_id_fkx ON ship.shipment_leg (courier_route_id);  -- -> ship.courier_route
CREATE INDEX IF NOT EXISTS shipment_leg_from_station_id_fkx ON ship.shipment_leg (from_station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS shipment_leg_load_id_fkx ON ship.shipment_leg (load_id);  -- -> ship.load
CREATE INDEX IF NOT EXISTS shipment_leg_to_station_id_fkx ON ship.shipment_leg (to_station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS shipment_leg_trip_id_fkx ON ship.shipment_leg (trip_id);  -- -> ops.trip
CREATE INDEX IF NOT EXISTS shipment_option_option_id_fkx ON ship.shipment_option (option_id);  -- -> ship.service_option
CREATE INDEX IF NOT EXISTS shipment_party_address_id_fkx ON ship.shipment_party (address_id);  -- -> ship.address
CREATE INDEX IF NOT EXISTS shipment_party_enc_key_id_fkx ON ship.shipment_party (enc_key_id);  -- -> sec.key_registry
CREATE INDEX IF NOT EXISTS shipment_party_party_id_fkx ON ship.shipment_party (party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS shipment_reference_parcel_id_fkx ON ship.shipment_reference (parcel_id);  -- -> ship.parcel
CREATE INDEX IF NOT EXISTS shipment_reference_shipment_id_fkx ON ship.shipment_reference (shipment_id);  -- -> ship.shipment
CREATE INDEX IF NOT EXISTS shipper_account_company_id_fkx ON ship.shipper_account (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS shipper_account_party_id_fkx ON ship.shipper_account (party_id);  -- -> iam.party
CREATE INDEX IF NOT EXISTS shipper_account_pricing_agreement_id_fkx ON ship.shipper_account (pricing_agreement_id);  -- -> ship.pricing_agreement
CREATE INDEX IF NOT EXISTS shipper_account_wallet_id_fkx ON ship.shipper_account (wallet_id);  -- -> fin.wallet
CREATE INDEX IF NOT EXISTS sort_window_hub_id_fkx ON ship.sort_window (hub_id);  -- -> ship.hub
CREATE INDEX IF NOT EXISTS tracking_event_actor_user_id_fkx ON ship.tracking_event (actor_user_id);  -- -> iam.app_user
CREATE INDEX IF NOT EXISTS tracking_event_device_id_fkx ON ship.tracking_event (device_id);  -- -> iam.device
CREATE INDEX IF NOT EXISTS tracking_event_leg_id_fkx ON ship.tracking_event (leg_id);  -- -> ship.shipment_leg
CREATE INDEX IF NOT EXISTS tracking_event_load_id_fkx ON ship.tracking_event (load_id);  -- -> ship.load
CREATE INDEX IF NOT EXISTS tracking_event_station_id_fkx ON ship.tracking_event (station_id);  -- -> net.station
CREATE INDEX IF NOT EXISTS tracking_event_unit_id_fkx ON ship.tracking_event (unit_id);  -- -> ship.handling_unit
CREATE INDEX IF NOT EXISTS transit_time_matrix_dest_zone_id_fkx ON ship.transit_time_matrix (dest_zone_id);  -- -> ship.geo_zone
CREATE INDEX IF NOT EXISTS transit_time_matrix_service_id_fkx ON ship.transit_time_matrix (service_id);  -- -> ship.service_product
CREATE INDEX IF NOT EXISTS weight_audit_device_id_fkx ON ship.weight_audit (device_id);  -- -> iam.device
CREATE INDEX IF NOT EXISTS weight_audit_parcel_id_fkx ON ship.weight_audit (parcel_id);  -- -> ship.parcel
CREATE INDEX IF NOT EXISTS weight_audit_photo_file_id_fkx ON ship.weight_audit (photo_file_id);  -- -> ref.file_object
CREATE INDEX IF NOT EXISTS webhook_delivery_outbox_event_id_fkx ON sys.webhook_delivery (outbox_event_id);  -- -> sys.outbox_event
CREATE INDEX IF NOT EXISTS webhook_endpoint_api_client_id_fkx ON sys.webhook_endpoint (api_client_id);  -- -> iam.api_client
CREATE INDEX IF NOT EXISTS webhook_endpoint_enc_key_id_fkx ON sys.webhook_endpoint (enc_key_id);  -- -> sec.key_registry
CREATE INDEX IF NOT EXISTS dispatch_offer_shift_id_fkx ON taxi.dispatch_offer (shift_id);  -- -> taxi.taxi_shift
CREATE INDEX IF NOT EXISTS ride_ledger_txn_id_fkx ON taxi.ride (ledger_txn_id);  -- -> fin.ledger_txn
CREATE INDEX IF NOT EXISTS ride_rider_user_id_fkx ON taxi.ride (rider_user_id);  -- -> iam.app_user
CREATE INDEX IF NOT EXISTS ride_shift_id_fkx ON taxi.ride (shift_id);  -- -> taxi.taxi_shift
CREATE INDEX IF NOT EXISTS ride_tariff_id_fkx ON taxi.ride (tariff_id);  -- -> taxi.meter_tariff
CREATE INDEX IF NOT EXISTS ride_trip_id_fkx ON taxi.ride (trip_id);  -- -> ops.trip
CREATE INDEX IF NOT EXISTS ride_request_rider_user_id_fkx ON taxi.ride_request (rider_user_id);  -- -> iam.app_user
CREATE INDEX IF NOT EXISTS taxi_permit_company_id_fkx ON taxi.taxi_permit (company_id);  -- -> iam.company
CREATE INDEX IF NOT EXISTS taxi_permit_office_id_fkx ON taxi.taxi_permit (office_id);  -- -> taxi.taxi_office
CREATE INDEX IF NOT EXISTS taxi_shift_permit_id_fkx ON taxi.taxi_shift (permit_id);  -- -> taxi.taxi_permit

INSERT INTO sys.schema_migration (version, description)
SELECT '1.16.0', 'Relational integrity: primary keys, missing foreign keys, foreign key indexes, documented polymorphic references'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.16.0');
