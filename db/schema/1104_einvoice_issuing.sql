-- =====================================================================
-- Masslak - 1104: e-invoices are issued for paid sales (a gap found by the review of the use cases, October 2026)
--
-- The e-invoice core existed (080_acct.sql: issuing units with a counter that is never reset and the last hash,
-- documents and lines that freeze once finalized, acct.finalize_einvoice giving the gapless number and the chained
-- hash) but nothing issued a document. The worker now does it (backend/app/modules/einvoice/service.py), every minute:
--   * a paid booking gets an invoice from each seller that has an active issuing unit and a tax profile valid now:
--     the carrier for the tickets, the platform for its booking fee;
--   * a refunded booking gets a credit note against each invoice, for what was refunded of that seller's lines;
--   * the hash covers the document's content, its number and the previous document's hash; it is signed (Ed25519,
--     its own key) and the QR code carries the seller, tax number, time, totals, hash and signature (TLV, base64).
-- Anyone can check a document at GET /api/verify/einvoice/{uuid}. acct.einvoice_chain_breaks counts, per unit, the
-- documents whose previous hash is not the hash of the document before them (0 is expected; for monitoring).
-- =====================================================================

INSERT INTO sys.setting (key, value, scope, description) VALUES
  ('einvoice.tax_rate_pct', '0'::jsonb, 'PLATFORM',
   'Tax included in prices, in percent, split out on e-invoice lines; 0 issues them out of scope of tax (1104)'),
  ('einvoice.issue_window_days', '30'::jsonb, 'PLATFORM',
   'How far back the worker looks for paid or refunded bookings without their e-invoice or credit note (1104)')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION acct.einvoice_chain_breaks(p_unit_id bigint) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT count(*) FROM acct.einvoice_document d
    LEFT JOIN acct.einvoice_document p ON p.unit_id = d.unit_id AND p.counter_value = d.counter_value - 1
   WHERE d.unit_id = p_unit_id AND d.counter_value IS NOT NULL
     AND d.previous_hash IS DISTINCT FROM CASE WHEN d.counter_value = 1 THEN '0' ELSE p.hash END
$$;
REVOKE ALL ON FUNCTION acct.einvoice_chain_breaks(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION acct.einvoice_chain_breaks(bigint) TO masslak_app;
COMMENT ON FUNCTION acct.einvoice_chain_breaks IS 'Documents of a unit whose previous hash is not the hash of the document numbered before them (1104)';

CREATE INDEX IF NOT EXISTS einvoice_unit_counter_idx ON acct.einvoice_document (unit_id, counter_value) WHERE counter_value IS NOT NULL;
