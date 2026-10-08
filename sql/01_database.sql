-- Safe, idempotent database prerequisites for mumbai_spatial_db.
-- Only the project database named by the caller is changed; nothing is dropped.
CREATE EXTENSION IF NOT EXISTS postgis;   -- geometry/geography types, ST_* functions, GiST support
CREATE EXTENSION IF NOT EXISTS hstore;    -- osm2pgsql stores all OSM tags as hstore (--hstore-all)

CREATE SCHEMA IF NOT EXISTS raw_osm;       -- untouched osm2pgsql output (EPSG:3857)
CREATE SCHEMA IF NOT EXISTS spatial_data;  -- clean project-facing tables/views (EPSG:4326)

COMMENT ON SCHEMA raw_osm IS 'Mumbai OSM extract imported with osm2pgsql (classic pgsql output, EPSG:3857).';
COMMENT ON SCHEMA spatial_data IS 'Clean Mumbai places, roads/railways and areas for spatial SQL demonstrations (EPSG:4326).';
