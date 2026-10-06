-- =====================================================================
-- 1037: row-level security for the tables that still relied on the application layer alone
--   An audit of release 1.19.0 found 140 tables without RLS. This file covers every one whose owner is clear
--   from its own columns or its parent row:
--     platform-only   governance registers, screening, watchlists, fraud and break-glass records
--     catalogs        everyone reads, only the platform writes (reference lists, tax schemes, providers)
--     booking rows    passengers, tickets, allocations and refunds follow the visibility of their booking
--     company rows    rows carrying the owning company
--     trip operations crew, live positions, changes and stop events: the trip's company and the platform
--   Left to the application on purpose (documented in docs/architecture/ARCHITECTURE.md, section 4.2a):
--     sign-in tables (iam.app_user, sessions, tokens, MFA factors) read before a context exists, public timetable
--     rows of published trips (stops, segments, fares), append-only ledgers guarded by grants and triggers,
--     ratings shown on public trip pages, and SOS events that a passenger raises on any trip.
-- =====================================================================

-- ------------------------------ platform-only
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'gov.data_inventory','gov.feature_compliance_review','gov.obligation_register','gov.partner_dpa','gov.policy_authority',
    'gov.privacy_incident','sec.access_review','sec.blocklist_entry','sec.break_glass_log','sec.fraud_case','sec.risk_assessment',
    'sec.screening_request','sec.screening_result','sec.watchlist_entry','fin.bank_reconciliation','crm.ai_policy']
  LOOP
    CONTINUE WHEN to_regclass(t) IS NULL;
    PERFORM sys.rls_platform(t);
  END LOOP;
END $$;

-- ------------------------------ catalogs
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'ref.city','ref.country','ref.currency','ref.exchange_rate','ref.locale','ref.translation','iam.permission',
    'acct.tax_authority','pricing.jurisdiction','pricing.tax_scheme','pricing.tax_rule','crm.notification_template',
    'fin.payment_provider','net.compliance_profile','gov.policy_domain']
  LOOP
    CONTINUE WHEN to_regclass(t) IS NULL;
    PERFORM sys.rls_catalog(t);
  END LOOP;
END $$;

-- ------------------------------ rows of a booking
SELECT sys.rls_parent('sales.passenger', 'booking_id', 'sales.booking');
SELECT sys.rls_parent('sales.ticket', 'booking_id', 'sales.booking');
SELECT sys.rls_parent('sales.refund_request', 'booking_id', 'sales.booking');
SELECT sys.rls_parent('sales.passenger_compensation', 'booking_id', 'sales.booking');
SELECT sys.rls_parent('fin.price_allocation', 'booking_id', 'sales.booking');
SELECT sys.rls_parent('fin.price_allocation_line', 'allocation_id', 'fin.price_allocation');
SELECT sys.rls_parent('sales.campaign_redemption', 'booking_id', 'sales.booking');

-- ------------------------------ payments: the payer, the selling agency, whoever sees the booking, and the platform
SELECT sys.rls('fin.payment', 'sys.ctx_is_platform() OR payer_party_id = sys.ctx_party_id()'
  || ' OR (agency_company_id IS NOT NULL AND sys.ctx_scope() = ''AGENCY'' AND agency_company_id = sys.ctx_company_id())'
  || ' OR (booking_id IS NOT NULL AND EXISTS (SELECT 1 FROM sales.booking b WHERE b.id = payment.booking_id))');

-- ------------------------------ rows of one company
SELECT sys.rls_tenant('acct.gl_period');
SELECT sys.rls_tenant('net.carrier_code');
SELECT sys.rls_tenant('gov.policy_change');
SELECT sys.rls_tenant('iam.beneficial_owner');
SELECT sys.rls('crm.ai_conversation', 'sys.tenant_visible(company_id) OR party_id = sys.ctx_party_id()');
SELECT sys.rls_split('sec.key_registry', 'company_id IS NULL OR sys.tenant_visible(company_id)', 'sys.ctx_is_platform()');
SELECT sys.rls_split('pricing.campaign', 'company_id IS NULL OR sys.tenant_visible(company_id)', 'sys.tenant_visible(company_id)');
SELECT sys.rls_split('pricing.pricing_modifier', 'company_id IS NULL OR sys.tenant_visible(company_id)', 'sys.tenant_visible(company_id)');
SELECT sys.rls_split('pricing.fare_brand', 'company_id IS NULL OR sys.tenant_visible(company_id)', 'sys.tenant_visible(company_id)');
SELECT sys.rls_split('pricing.fare_table', 'company_id IS NULL OR sys.tenant_visible(company_id)', 'sys.tenant_visible(company_id)');
SELECT sys.rls_split('iam.role', 'company_id IS NULL OR sys.tenant_visible(company_id)', 'sys.tenant_visible(company_id)');

-- ------------------------------ private operations of a trip
SELECT sys.rls_trip('ops.crew_assignment', 'party_id = sys.ctx_party_id()');
SELECT sys.rls_trip('ops.trip_change');
SELECT sys.rls_trip('ops.trip_stop_event');
SELECT sys.rls_trip('ops.tracking_alert');
SELECT sys.rls_trip('ops.vehicle_swap');
SELECT sys.rls_trip('sec.manifest_submission');

INSERT INTO sys.schema_migration (version, description)
SELECT '1.20.0', 'Row-level security for governance, catalog, booking, company and trip operation tables'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.20.0');
