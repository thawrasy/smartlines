-- =====================================================================
-- 1072: trip ratings are seen by the rater, the rated carrier and the platform only (code review of October 2026)
-- =====================================================================
-- 1039 gave crm.trip_rating a read policy of true, as if ratings were a public catalog: every company and every
-- signed-in passenger could read every rating, with the ticket, the rater (party_id) and the comment, so a carrier
-- saw its competitors' ratings and who had travelled with them. The company isolation test missed it while no rating
-- existed when it ran. Nothing publishes ratings to the public; the carrier reads its own (read-only, the operator
-- portal), the platform moderates them, and the passenger sees and writes their own.
SELECT sys.rls_split('crm.trip_rating',
                     'sys.tenant_visible(company_id) OR party_id = sys.ctx_party_id()',
                     'sys.ctx_is_platform() OR party_id = sys.ctx_party_id()');
COMMENT ON POLICY split_read ON crm.trip_rating IS 'The rated carrier, the platform and the rater (1072); ratings are not public';
SELECT sys.refresh_table_class();
