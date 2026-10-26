-- =====================================================================
-- 1152: WhatsApp codes open at launch (owner's decision on N36)
--   The platform registers a WhatsApp Business account on its business number, so second-factor codes by WhatsApp are
--   open from the launch; the delivery is checked while the release packages are finished. A method open in the policy
--   is still offered only when the server delivers on it (MASSLAK_NOTIFY_WHATSAPP=cloud). Text messages stay closed
--   until an SMS provider is contracted.
-- =====================================================================
UPDATE sys.setting
   SET value = jsonb_set(value, '{methods}',
                 (SELECT jsonb_agg(m ORDER BY array_position(ARRAY['TOTP','EMAIL','TELEGRAM','WHATSAPP','SMS'], m))
                    FROM (SELECT DISTINCT m FROM jsonb_array_elements_text(value -> 'methods') m
                          UNION SELECT 'WHATSAPP') s)),
       description = 'Two-factor sign-in: the methods open (TOTP, EMAIL, TELEGRAM, WHATSAPP; SMS once a provider is contracted), the portals that must use one, and the message code limits (1075, 1151, 1152)'
 WHERE key = 'auth.mfa' AND NOT (value -> 'methods' ? 'WHATSAPP');
