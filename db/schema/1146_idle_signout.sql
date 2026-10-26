-- =====================================================================
-- 1146: signing out an idle session (owner's note, October 2026)
--   A user who does nothing for a while is signed out by the platform, for the platform's safety and the user's: a
--   screen left open in an office or a phone left on a table does not stay signed in. The period is the platform's
--   setting per portal (auth.idle), edited by the security officers; the API ends a session whose last activity is
--   older than its portal's period, and the screens warn a minute before and then sign out by themselves. Requests a
--   screen sends by itself in the background (the notification bell) do not count as activity.
--   Defaults: platform staff and inspectors 15 minutes; carriers, agencies and stations 30; passengers 60; drivers 240,
--   since a driver's app stays open on the road.
-- =====================================================================

INSERT INTO sys.setting (key, value, description) VALUES
  ('auth.idle', jsonb_build_object('minutes', jsonb_build_object(
      'PLATFORM', 15, 'INSPECTOR', 15, 'OPERATOR', 30, 'AGENCY', 30, 'STATION', 30, 'PASSENGER', 60, 'DRIVER', 240)),
   'Idle sign-out: minutes without activity after which a session of each portal ends (1146)')
ON CONFLICT (key) DO NOTHING;

-- the idle period of a portal: the setting, else 30 minutes
CREATE OR REPLACE FUNCTION iam.idle_minutes(p_portal text) RETURNS integer
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce((SELECT (value -> 'minutes' ->> p_portal)::int FROM sys.setting WHERE key = 'auth.idle'), 30)
$$;
REVOKE ALL ON FUNCTION iam.idle_minutes(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION iam.idle_minutes(text) TO masslak_app;
COMMENT ON FUNCTION iam.idle_minutes IS 'Minutes without activity after which a session of the portal ends (auth.idle, 1146)';

-- finding the sessions to end by their last activity
CREATE INDEX IF NOT EXISTS user_session_open_seen_idx ON iam.user_session (last_seen_at) WHERE revoked_at IS NULL;
