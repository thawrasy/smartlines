-- =====================================================================
-- 1071: a provider's late confirmation is credited, not lost (code review of October 2026, scenario 5)
-- =====================================================================
-- A payment the platform stopped waiting for (its own expiry, its reservation's expiry, or the payer's cancel) was
-- FAILED for good: when the provider confirmed afterwards that it had taken the money, the notice was recorded as
-- processed and credited nothing, and the reconciliation did not see it either. Such a payment may now still turn
-- SUCCESS: the money reaches the payer's wallet, the booking is confirmed only if it still holds its seats, and finance
-- is told (event payment.captured_late) so it can send the money back to its source when the passenger asks. A payment
-- the provider itself declined, or whose notice named another amount, stays FAILED.
CREATE OR REPLACE FUNCTION fin.tg_payment_transition()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
       (OLD.status = 'PENDING' AND NEW.status IN ('SUCCESS','FAILED')) OR
       (OLD.status = 'SUCCESS' AND NEW.status = 'REFUNDED') OR
       (OLD.status = 'FAILED' AND NEW.status = 'SUCCESS' AND OLD.failure_code IN ('EXPIRED', 'BOOKING_EXPIRED', 'CANCELLED'))) THEN
    RAISE EXCEPTION 'INVALID_TRANSITION: payment % -> %', OLD.status, NEW.status USING ERRCODE = 'P0001';
  END IF;
  IF OLD.status <> 'PENDING' AND (NEW.amount <> OLD.amount OR NEW.currency <> OLD.currency) THEN
    RAISE EXCEPTION 'IMMUTABLE_RECORD: settled payment amount' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $function$;

-- Marked on the payment, so finance sees every late capture (metric masslak_payments_captured_late_total, alert
-- PaymentCapturedLate). The default is a constant: adding the column does not rewrite the table.
ALTER TABLE fin.payment ADD COLUMN IF NOT EXISTS captured_late boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN fin.payment.captured_late IS 'The provider confirmed after the platform had stopped waiting (expired or cancelled here); credited to the wallet (1071)';
CREATE INDEX IF NOT EXISTS payment_captured_late_idx ON fin.payment (id) WHERE captured_late;

CREATE OR REPLACE FUNCTION fin.payment_metrics() RETURNS TABLE (metric text, labels jsonb, value float8)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT 'masslak_payments_captured_late_total'::text, '{}'::jsonb, count(*)::float8 FROM fin.payment WHERE captured_late
$$;
COMMENT ON FUNCTION fin.payment_metrics() IS 'Payments captured by the provider after the platform stopped waiting (1071), for the metrics endpoint';
REVOKE EXECUTE ON FUNCTION fin.payment_metrics() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fin.payment_metrics() TO masslak_app, masslak_readonly;
