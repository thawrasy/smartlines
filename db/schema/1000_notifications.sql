-- =====================================================================
-- 1000: notifications through the transactional outbox (architecture section 3)
--   * Business transactions write sys.outbox_event in the same transaction as the change. A worker claims events
--     with SKIP LOCKED, writes crm.notification rows and sends email or SMS; failures back off and retry.
--   * The database stores the template code and its values, never rendered text: wording lives in the locale
--     files of the backend and the web interface, so data stays language-neutral.
--   * Delivery addresses are stored masked.
-- =====================================================================
CREATE INDEX IF NOT EXISTS outbox_pending_idx ON sys.outbox_event (next_attempt_at) WHERE status = 'PENDING';
CREATE INDEX IF NOT EXISTS notification_user_idx ON crm.notification (user_id, created_at DESC);
ALTER TABLE crm.notification ADD COLUMN IF NOT EXISTS event_uid uuid;
ALTER TABLE crm.notification ADD COLUMN IF NOT EXISTS last_error text;
CREATE UNIQUE INDEX IF NOT EXISTS notification_event_uq ON crm.notification (event_uid, user_id, channel) WHERE event_uid IS NOT NULL;

ALTER TABLE crm.notification ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS notification_owner ON crm.notification;
CREATE POLICY notification_owner ON crm.notification
  USING (sys.ctx_is_platform() OR user_id = sys.ctx_user_id())
  WITH CHECK (sys.ctx_is_platform() OR user_id = sys.ctx_user_id());

-- Outbox rows are written by the application and read by the worker only (system scope)
ALTER TABLE sys.outbox_event ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS outbox_system ON sys.outbox_event;
DROP POLICY IF EXISTS outbox_insert ON sys.outbox_event;
CREATE POLICY outbox_system ON sys.outbox_event USING (sys.ctx_is_platform()) WITH CHECK (sys.ctx_is_platform());
CREATE POLICY outbox_insert ON sys.outbox_event FOR INSERT WITH CHECK (true);

INSERT INTO sys.schema_migration (version, description)
SELECT '1.8.0', 'Notifications through the transactional outbox'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.8.0');
