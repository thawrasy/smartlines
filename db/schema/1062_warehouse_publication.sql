-- =====================================================================
-- 1062: change data capture for the data warehouse (expert review of October 2026, stage D)
--   Heavy analysis belongs in a warehouse, not on the primary or its replica. The primary publishes the facts and
--   dimensions the warehouse needs by logical replication (publication masslak_dw); the warehouse database subscribes
--   and keeps them current within seconds (db/warehouse/build.py, docs/database/WAREHOUSE.md).
--   Only listed columns leave the primary: no names, contact data, identity numbers, payer or booker links, card digits
--   or ledger memos. The replication role masslak_cdc may read exactly those columns and nothing else.
--   Logical decoding needs wal_level = logical on the primary (docker-compose.yml, deploy/pitr); without it the
--   publication exists and stays idle.
-- =====================================================================

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'masslak_cdc') THEN
    -- reads the published columns for the first copy of each table; row security does not hide rows from it, so the
    -- copy is complete, and its column grants keep everything else out of reach
    CREATE ROLE masslak_cdc NOLOGIN REPLICATION BYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'masslak_dw') THEN
    CREATE PUBLICATION masslak_dw WITH (publish = 'insert, update, delete', publish_via_partition_root = true);
  END IF;
END $$;
COMMENT ON ROLE masslak_cdc IS 'Logical replication to the data warehouse: reads only the columns of publication masslak_dw (1062)';

-- The tables and columns the warehouse receives. Keys stay in every list (logical replication needs them).
CREATE OR REPLACE FUNCTION sys.dw_columns() RETURNS TABLE (table_name text, columns text[])
LANGUAGE sql IMMUTABLE AS $$
  VALUES
    ('ref.market',       ARRAY['country_code','time_zone','currency','locale','status','is_default']),
    ('ref.city',         ARRAY['id','code','country_code','name','timezone']),
    ('net.station',      ARRAY['id','code','city_id','country_code','station_class','status']),
    ('net.route',        ARRAY['id','company_id','code','origin_station_id','dest_station_id','service_type','distance_km','status']),
    ('net.carrier_code', ARRAY['id','company_id','code3','status']),
    ('iam.company',      ARRAY['id','company_type','approval_status','created_at']),
    ('sales.channel',    ARRAY['id','code','channel_type']),
    ('ops.trip',         ARRAY['id','company_id','route_id','trip_type','service_type','departure_at','arrival_at','status',
                               'seats_total','segments_count','currency','base_price','created_at']),
    ('sales.booking',    ARRAY['id','trip_id','company_id','channel_id','agency_id','status','pay_method','pay_option',
                               'funding_source','currency','total_amount','confirmed_at','cancelled_at','created_at','updated_at']),
    ('sales.ticket',     ARRAY['id','booking_id','trip_id','from_seq','to_seq','fare_brand_code','fare_amount','seat_surcharge',
                               'baggage_fee','total_amount','status','travel_category','boarded_at','created_at']),
    ('fin.payment',      ARRAY['id','purpose','booking_id','provider_id','method','currency','amount','fee','platform_fee',
                               'refunded_amount','status','created_at','settled_at']),
    ('fin.wallet',       ARRAY['id','company_id','wallet_type','currency','balance_mode','status','created_at']),
    ('fin.ledger_txn',   ARRAY['id','txn_type','currency','ref_type','created_at']),
    ('fin.ledger_entry', ARRAY['id','txn_id','wallet_id','direction','amount','created_at'])
$$;
COMMENT ON FUNCTION sys.dw_columns IS 'The tables and columns published to the data warehouse; no personal data (1062)';

-- Applies sys.dw_columns to the publication and to the replication role's column grants
CREATE OR REPLACE FUNCTION sys.dw_publish() RETURNS integer LANGUAGE plpgsql AS $$
DECLARE r record; tables text := ''; n integer := 0;
BEGIN
  FOR r IN SELECT * FROM sys.dw_columns() ORDER BY 1 LOOP
    tables := tables || CASE WHEN n > 0 THEN ', ' ELSE '' END
              || format('%s (%s)', r.table_name::regclass, array_to_string(ARRAY(SELECT quote_ident(c) FROM unnest(r.columns) c), ', '));
    EXECUTE format('REVOKE ALL ON %s FROM masslak_cdc', r.table_name::regclass);
    EXECUTE format('GRANT SELECT (%s) ON %s TO masslak_cdc',
                   array_to_string(ARRAY(SELECT quote_ident(c) FROM unnest(r.columns) c), ', '), r.table_name::regclass);
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO masslak_cdc', split_part(r.table_name, '.', 1));
    n := n + 1;
  END LOOP;
  EXECUTE 'ALTER PUBLICATION masslak_dw SET TABLE ' || tables;
  RETURN n;
END $$;
COMMENT ON FUNCTION sys.dw_publish IS 'Sets the tables and columns of publication masslak_dw and the grants of masslak_cdc (1062)';
REVOKE ALL ON FUNCTION sys.dw_publish() FROM PUBLIC;
SELECT sys.dw_publish();

-- ------------------------------------------------------------------ monitoring
-- A replication slot keeps WAL until its subscriber has it: a stopped warehouse would fill the primary's disk.
-- max_slot_wal_keep_size caps it; these figures alert well before the cap. A logical slot decoding with any plugin but
-- pgoutput reads every table whatever the publication says (a role with REPLICATION can create one): it is reported
-- at once (alert ReplicationSlotForeignPlugin).
CREATE OR REPLACE FUNCTION sys.replication_metrics() RETURNS TABLE (metric text, labels jsonb, value double precision)
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT x.metric, jsonb_build_object('slot', s.slot_name, 'kind', s.slot_type), x.value
    FROM pg_replication_slots s,
         LATERAL (VALUES
           ('masslak_replication_slot_retained_bytes'::text,
            coalesce(pg_wal_lsn_diff(CASE WHEN pg_is_in_recovery() THEN pg_last_wal_replay_lsn() ELSE pg_current_wal_lsn() END,
                                     coalesce(s.confirmed_flush_lsn, s.restart_lsn)), 0)::float8),
           ('masslak_replication_slot_active', s.active::int::float8),
           ('masslak_replication_slot_foreign_plugin', (s.slot_type = 'logical' AND s.plugin <> 'pgoutput')::int::float8)) AS x(metric, value)
   WHERE s.database = current_database() OR s.database IS NULL
$$;
REVOKE ALL ON FUNCTION sys.replication_metrics() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sys.replication_metrics() TO masslak_app, masslak_readonly;
COMMENT ON FUNCTION sys.replication_metrics IS 'WAL each replication slot holds back and whether its subscriber is connected (1062)';

INSERT INTO sys.schema_migration (version, description)
SELECT '1.41.0', 'Expert review stage D: logical replication of facts and dimensions to the data warehouse, without personal data'
 WHERE NOT EXISTS (SELECT 1 FROM sys.schema_migration WHERE version = '1.41.0');
