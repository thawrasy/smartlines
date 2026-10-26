-- =====================================================================
-- 1139: the scheduler sees the schedules of companies (independent review, round 8, T-07)
--   The worker runs due schedules in the SYSTEM context and then each one with its owner's rights (scheduler.py).
--   The policy of rpt.report_schedule (1034) let the platform see only platform schedules (company_id IS NULL), and
--   SYSTEM counts as the platform: a company's scheduled report was never picked up, so it was never sent. The test
--   written to measure the scheduler's coverage found it. Now the SYSTEM context sees every schedule; platform staff
--   still see only the platform's, and a company member only their own.
-- =====================================================================

SELECT sys.rls('rpt.report_schedule',
  'sys.ctx_scope() = ''SYSTEM'' OR (sys.ctx_is_platform() AND company_id IS NULL) '
  || 'OR (company_id = sys.ctx_company_id() AND owner_user_id = sys.ctx_user_id())');
COMMENT ON POLICY isolation ON rpt.report_schedule IS
  'The scheduler (SYSTEM) sees every schedule; platform staff the platform''s; a company member their own (1139)';
