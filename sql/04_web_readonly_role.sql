-- Read-only login role used by the local web front end (frontend/app.py).
-- Idempotent; re-run by scripts/run_web.sh because create_schema.sh recreates
-- the spatial_data tables (which drops earlier table grants).
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'mumbai_web') THEN
        CREATE ROLE mumbai_web LOGIN;
    END IF;
END
$$;

-- Every transaction of this role is read-only and time-limited.
ALTER ROLE mumbai_web SET default_transaction_read_only = on;
ALTER ROLE mumbai_web SET statement_timeout = '30s';

-- SELECT only (no write privileges anywhere). raw_osm is readable because
-- query Q1.2 reports the SRID of the raw osm2pgsql import.
GRANT USAGE ON SCHEMA spatial_data, raw_osm TO mumbai_web;
GRANT SELECT ON ALL TABLES IN SCHEMA spatial_data TO mumbai_web;
GRANT SELECT ON ALL TABLES IN SCHEMA raw_osm TO mumbai_web;
