-- =====================================================================
-- 1138: a dead delivery names its destination and its owner (independent review, round 8, T-08)
--   An event that gave up after eight attempts raised an alert (OutboxEventsFailed, WebhookDeliveriesDead) that said how
--   many, not whose: an operator had to search for the partner to call. Now each partner endpoint with a dead delivery
--   in the last 7 days is its own series, labelled with the endpoint, its host, the API client and the company that own
--   it, and the kind of events; a dead outbox event is counted by its event type. The alert then names who to tell, and
--   RUNBOOKS.md (section 33) says who resends what.
--   Labels carry no personal data and no URL path or query (a path can hold a token): only the host.
-- =====================================================================

CREATE OR REPLACE FUNCTION sys.dead_delivery_metrics() RETURNS TABLE (metric text, labels jsonb, value double precision)
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  -- partner endpoints with deliveries that gave up in the last 7 days, one series each, with who owns the endpoint
  RETURN QUERY
  SELECT 'masslak_webhook_dead_by_endpoint'::text,
         jsonb_build_object('endpoint', left(e.uid::text, 8),
                            'host', substring(e.url FROM '^https://([^/:?#]+)'),
                            'kind', e.kind,
                            'client', coalesce(c.name, 'platform integration'),
                            'company', coalesce(cp.name_latin, cp.legal_name, 'platform'),
                            'event_types', (SELECT string_agg(DISTINCT coalesce(d2.event_type, '?'), ',')
                                              FROM sys.webhook_delivery d2
                                             WHERE d2.endpoint_id = e.id AND d2.status = 'DEAD'
                                               AND d2.created_at > now() - interval '7 days')),
         count(d.id)::float8
    FROM sys.webhook_delivery d
    JOIN sys.webhook_endpoint e ON e.id = d.endpoint_id
    LEFT JOIN iam.api_client c ON c.id = e.api_client_id
    LEFT JOIN iam.party cp ON cp.id = c.company_id
   WHERE d.status = 'DEAD' AND d.created_at > now() - interval '7 days'
   GROUP BY e.id, e.uid, e.url, e.kind, c.name, cp.name_latin, cp.legal_name;
  -- outbox events that gave up, by event type (the notification or partner notice that was not sent)
  RETURN QUERY
  SELECT 'masslak_outbox_dead_by_type'::text, jsonb_build_object('event_type', o.event_type), count(*)::float8
    FROM sys.outbox_event o WHERE o.status IN ('DEAD', 'FAILED')
   GROUP BY o.event_type;
END $$;
REVOKE ALL ON FUNCTION sys.dead_delivery_metrics() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sys.dead_delivery_metrics() TO masslak_app, masslak_readonly;
COMMENT ON FUNCTION sys.dead_delivery_metrics() IS
  'Dead webhook deliveries of the last 7 days per endpoint with its host, client and company, and dead outbox events per type (1138)';
