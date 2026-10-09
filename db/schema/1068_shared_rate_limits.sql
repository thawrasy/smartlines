-- =====================================================================
-- 1068: request limits shared by every API process (code review of October 2026, H-01)
-- =====================================================================
-- The limiter kept its token buckets in each process's memory, so two processes per container (and more
-- containers) multiplied every limit, and the sign-in limit was per address only: on mobile networks many
-- subscribers share one public address (carrier-grade NAT), so a busy address could lock out real users.
-- Sign-in, registration and password requests now draw from buckets here, shared by all processes: one per
-- address with a high limit, and one per account identifier with a strict one (applied by the API where it
-- reads the identifier). The table is unlogged: buckets are worth nothing after a crash and need no WAL.

CREATE UNLOGGED TABLE IF NOT EXISTS sec.rate_bucket (
  bucket      text NOT NULL CHECK (bucket ~ '^[a-z_]{1,32}$'),
  key         text NOT NULL CHECK (length(key) BETWEEN 1 AND 100),
  tokens      double precision NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (bucket, key)
);
CREATE INDEX IF NOT EXISTS rate_bucket_idle_idx ON sec.rate_bucket (updated_at);
COMMENT ON TABLE sec.rate_bucket IS 'Token buckets of the shared request limits (1068): an address, or a keyed hash of an account identifier, never the identifier itself';
COMMENT ON COLUMN sec.rate_bucket.key IS 'A client address, or a keyed hash of an account identifier (sec.rate_take)';
ALTER TABLE sec.rate_bucket ENABLE ROW LEVEL SECURITY;
ALTER TABLE sec.rate_bucket FORCE ROW LEVEL SECURITY;
-- no role is granted the table: sec.rate_take is the only way in, and it acts in the platform scope for its own
-- statements only (sign-in calls it from the AUTH scope)
DROP POLICY IF EXISTS platform_only ON sec.rate_bucket;
CREATE POLICY platform_only ON sec.rate_bucket USING (sys.ctx_is_platform()) WITH CHECK (sys.ctx_is_platform());
INSERT INTO sys.table_class (table_name, data_class, tenant_path, note)
VALUES ('sec.rate_bucket', 'PLATFORM_CONFIDENTIAL', NULL, 'written by sec.rate_take only; no role reads it')
ON CONFLICT (table_name) DO UPDATE SET data_class = excluded.data_class, tenant_path = excluded.tenant_path, note = excluded.note;
INSERT INTO sys.table_phase (table_name, phase_code, module) VALUES ('sec.rate_bucket', '1A', 'E25')
ON CONFLICT (table_name) DO UPDATE SET phase_code = EXCLUDED.phase_code, module = EXCLUDED.module;

-- Takes one token from a bucket that refills p_per_minute tokens a minute up to p_per_minute. Returns 0 when the
-- request may go ahead, else the seconds until a token is free. A refused request costs nothing, so a client that
-- keeps knocking is let in again as soon as the bucket has refilled. Concurrent calls on one bucket queue on its row.
CREATE OR REPLACE FUNCTION sec.rate_take(p_bucket text, p_key text, p_per_minute int) RETURNS double precision
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  t timestamptz := clock_timestamp();
  left_over double precision;
  caller_scope text := current_setting('app.scope', true);
BEGIN
  IF p_per_minute IS NULL OR p_per_minute < 1 THEN
    RAISE EXCEPTION 'RATE_LIMIT_INVALID: % tokens a minute', p_per_minute USING ERRCODE = 'P0001';
  END IF;
  PERFORM set_config('app.scope', 'SYSTEM', true);         -- restored below, before returning to the caller
  INSERT INTO sec.rate_bucket AS b (bucket, key, tokens, updated_at) VALUES (p_bucket, p_key, p_per_minute - 1, t)
  ON CONFLICT (bucket, key) DO UPDATE
     SET tokens = least(p_per_minute::double precision,
                        b.tokens + extract(epoch FROM t - b.updated_at) * p_per_minute / 60.0) - 1,
         updated_at = t
  RETURNING b.tokens INTO left_over;
  -- idle buckets are full again and can go; a few calls in a thousand clear a bounded batch
  IF random() < 0.002 THEN
    DELETE FROM sec.rate_bucket WHERE ctid = ANY (ARRAY(
      SELECT ctid FROM sec.rate_bucket WHERE updated_at < t - interval '10 minutes' LIMIT 1000));
  END IF;
  IF left_over < 0 THEN
    UPDATE sec.rate_bucket SET tokens = tokens + 1 WHERE bucket = p_bucket AND key = p_key;
  END IF;
  PERFORM set_config('app.scope', coalesce(caller_scope, ''), true);
  RETURN CASE WHEN left_over >= 0 THEN 0 ELSE -left_over * 60.0 / p_per_minute END;
END $$;
COMMENT ON FUNCTION sec.rate_take(text, text, int) IS 'Shared token bucket (1068): 0 when allowed, else the seconds until the next token';
REVOKE EXECUTE ON FUNCTION sec.rate_take(text, text, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sec.rate_take(text, text, int) TO masslak_app;

INSERT INTO sys.schema_migration (version, description)
SELECT '1.47.0', 'Request limits shared by every API process, per address and per account (code review, October 2026)'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.47.0');
