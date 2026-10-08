-- =====================================================================
-- 1057: expert review of October 2026, stage B (docs/operations/REVIEW_STAGE_B.md)
--   a. ageing of the cash carriers owe from counter sales: what is owed, split by how long it has been owed
--      (first in, first out: set-offs, remittances and cash refunds pay the oldest sales first)
--   b. finance metrics for monitoring: cash owed, cash overdue, carriers near their limit
--   c. how stale a report read from the replica may be: financial reports are refused past their limit,
--      others are served with a warning
-- =====================================================================

-- ------------------------------------------------------------------ a. cash ageing
CREATE OR REPLACE FUNCTION fin.cash_aging(p_as_of timestamptz DEFAULT now(), p_currency char(3) DEFAULT 'SYP')
RETURNS TABLE (company_id bigint, owed bigint, credit_limit bigint, days_0_7 bigint, days_8_30 bigint, days_31_60 bigint,
               days_61_90 bigint, days_over_90 bigint, overdue bigint, oldest_unpaid_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  WITH w AS (                                  -- each carrier's cash wallet and what it owed at the moment asked
    SELECT w.id, w.owner_party_id AS company_id,
           greatest(0, coalesce(sum(CASE e.direction WHEN 'DR' THEN e.amount ELSE -e.amount END), 0))::bigint AS owed
      FROM fin.wallet w LEFT JOIN fin.ledger_entry e ON e.wallet_id = w.id AND e.created_at <= p_as_of
     WHERE w.wallet_type = 'CASH_COLLECT' AND w.currency = p_currency
       AND (sys.ctx_is_platform() OR w.owner_party_id = sys.ctx_company_id())
     GROUP BY w.id, w.owner_party_id),
  sales AS (                                   -- cash taken in, newest first, with the running total
    SELECT w.company_id, w.owed, e.amount, e.created_at,
           sum(e.amount) OVER (PARTITION BY w.id ORDER BY e.created_at DESC, e.id DESC) AS upto
      FROM w JOIN fin.ledger_entry e ON e.wallet_id = w.id AND e.direction = 'DR' AND e.created_at <= p_as_of
     WHERE w.owed > 0),
  unpaid AS (                                  -- what is owed is made of the newest sales; older ones are paid
    SELECT s.company_id, s.created_at, least(s.amount, s.owed - (s.upto - s.amount)) AS part
      FROM sales s WHERE s.upto - s.amount < s.owed)
  SELECT w.company_id, w.owed, fin.cash_limit(w.company_id),
         coalesce(sum(u.part) FILTER (WHERE p_as_of - u.created_at <= interval '7 days'), 0)::bigint,
         coalesce(sum(u.part) FILTER (WHERE p_as_of - u.created_at > interval '7 days' AND p_as_of - u.created_at <= interval '30 days'), 0)::bigint,
         coalesce(sum(u.part) FILTER (WHERE p_as_of - u.created_at > interval '30 days' AND p_as_of - u.created_at <= interval '60 days'), 0)::bigint,
         coalesce(sum(u.part) FILTER (WHERE p_as_of - u.created_at > interval '60 days' AND p_as_of - u.created_at <= interval '90 days'), 0)::bigint,
         coalesce(sum(u.part) FILTER (WHERE p_as_of - u.created_at > interval '90 days'), 0)::bigint,
         coalesce(sum(u.part) FILTER (WHERE p_as_of - u.created_at > interval '30 days'), 0)::bigint,
         min(u.created_at)
    FROM w LEFT JOIN unpaid u ON u.company_id = w.company_id
   GROUP BY w.company_id, w.owed
$$;
COMMENT ON FUNCTION fin.cash_aging IS 'Cash each carrier owes from counter sales by age: 0-7, 8-30, 31-60, 61-90 and over 90 days, oldest sales paid first; a carrier sees only its own (review stage B, 1057)';
REVOKE EXECUTE ON FUNCTION fin.cash_aging(timestamptz, char) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fin.cash_aging(timestamptz, char) TO masslak_app, masslak_readonly;

-- ------------------------------------------------------------------ b. finance metrics for monitoring
CREATE OR REPLACE FUNCTION sys.finance_metrics() RETURNS TABLE (metric text, labels jsonb, value double precision)
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  RETURN QUERY
    WITH a AS MATERIALIZED (SELECT * FROM fin.cash_aging()),      -- the ageing is computed once per scrape
         t AS (SELECT coalesce(sum(owed), 0)::float8 AS owed, coalesce(sum(overdue), 0)::float8 AS overdue,
                      count(*) FILTER (WHERE overdue > 0)::float8 AS overdue_carriers,
                      count(*) FILTER (WHERE credit_limit > 0 AND owed >= 0.9 * credit_limit)::float8 AS near_limit FROM a)
    SELECT x.metric, '{}'::jsonb, x.value FROM t, LATERAL (VALUES
      ('masslak_cash_owed_minor'::text, t.owed), ('masslak_cash_overdue_minor', t.overdue),
      ('masslak_cash_overdue_carriers', t.overdue_carriers), ('masslak_cash_near_limit_carriers', t.near_limit)) AS x(metric, value);
END $$;
REVOKE ALL ON FUNCTION sys.finance_metrics() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sys.finance_metrics() TO masslak_app, masslak_readonly;
COMMENT ON FUNCTION sys.finance_metrics IS 'Finance metrics for the monitoring scrape: cash owed and overdue from counter sales (review stage B, 1057)';

-- ------------------------------------------------------------------ c. replica lag allowed for reports
INSERT INTO sys.setting (key, value, description) VALUES
  ('reports.replica_lag', '{"financial_max_seconds": 60, "operational_max_seconds": 300, "analytical_max_seconds": 3600}',
   'How far behind the primary the reports replica may be: a financial report is refused past its limit, other reports are served with a warning (review stage B)')
ON CONFLICT (key) DO NOTHING;

INSERT INTO sys.schema_migration (version, description)
SELECT '1.38.0', 'Expert review stage B: cash ageing, finance metrics, replica lag limits for reports'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.38.0');
