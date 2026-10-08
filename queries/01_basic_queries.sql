-- =====================================================================
-- 01  BASIC QUERIES: what real Mumbai OSM data is in the database?
-- Run: ./scripts/psql.sh -f queries/01_basic_queries.sql
-- =====================================================================

\echo '== Q1.1  Project tables/views: geometry type, SRID and row count'
SELECT 'spatial_data.places' AS relation, GeometryType(geom) AS geometry_type, ST_SRID(geom) AS srid, count(*) AS rows
FROM spatial_data.places GROUP BY 2,3
UNION ALL
SELECT 'spatial_data.roads', GeometryType(geom), ST_SRID(geom), count(*)
FROM spatial_data.roads GROUP BY 2,3
UNION ALL
SELECT 'spatial_data.areas', GeometryType(geom), ST_SRID(geom), count(*)
FROM spatial_data.areas GROUP BY 2,3
ORDER BY 1;

\echo '== Q1.2  SRID of the raw osm2pgsql import (source) vs the clean model'
SELECT 'raw_osm.planet_osm_point' AS relation, Find_SRID('raw_osm','planet_osm_point','way') AS srid
UNION ALL SELECT 'raw_osm.planet_osm_line',    Find_SRID('raw_osm','planet_osm_line','way')
UNION ALL SELECT 'raw_osm.planet_osm_polygon', Find_SRID('raw_osm','planet_osm_polygon','way')
UNION ALL SELECT 'spatial_data.places',        Find_SRID('spatial_data','places','geom');

\echo '== Q1.3  Point-of-interest categories that actually exist (>= 75 records)'
SELECT category, count(*) AS places, count(name) AS named
FROM spatial_data.places
GROUP BY category
HAVING count(*) >= 75
ORDER BY places DESC, category;

\echo '== Q1.4  All hospitals in the Mumbai extract (count, then first 15 by name)'
SELECT count(*) AS hospitals FROM spatial_data.places WHERE category = 'hospital';
SELECT id, name, ST_AsText(geom, 6) AS location_lon_lat
FROM spatial_data.places
WHERE category = 'hospital' AND name IS NOT NULL
ORDER BY name, id
LIMIT 15;

\echo '== Q1.5  Restaurants with their OSM cuisine tag (first 15 by name)'
SELECT count(*) AS restaurants FROM spatial_data.places WHERE category = 'restaurant';
SELECT id, name, subcategory AS cuisine, ST_AsText(geom, 6) AS location_lon_lat
FROM spatial_data.places
WHERE category = 'restaurant' AND name IS NOT NULL
ORDER BY name, id
LIMIT 15;

\echo '== Q1.6  Suburban railway stations (Western/Central/Harbour/Trans-Harbour lines)'
SELECT id, name, round(ST_Y(geom)::numeric, 5) AS lat, round(ST_X(geom)::numeric, 5) AS lon
FROM spatial_data.railway_stations
ORDER BY name, id;

\echo '== Q1.7  Schools (count, then first 15 by name)'
SELECT count(*) AS schools FROM spatial_data.places WHERE category = 'school';
SELECT id, name, ST_AsText(geom, 6) AS location_lon_lat
FROM spatial_data.places
WHERE category = 'school' AND name IS NOT NULL
ORDER BY name, id
LIMIT 15;

\echo '== Q1.8  Road types (OSM highway=*) and their total length in km'
SELECT road_type, count(*) AS segments,
       round((sum(ST_Length(geom::geography)) / 1000)::numeric, 1) AS length_km
FROM spatial_data.roads
WHERE line_type = 'road'
GROUP BY road_type
ORDER BY length_km DESC
LIMIT 15;

\echo '== Q1.9  Administrative areas available (OSM boundary=administrative)'
SELECT name, admin_level,
       round((ST_Area(geom::geography) / 1e6)::numeric, 1) AS area_km2
FROM spatial_data.administrative_areas
ORDER BY admin_level::int, name;

\echo '== Q1.10 Is there a defensible popularity/rating attribute? (no "famous" field in OSM)'
SELECT category,
       count(*) AS places,
       count(*) FILTER (WHERE tags ?| ARRAY['rating','stars','popularity','review']) AS with_rating_like_tag,
       count(*) FILTER (WHERE tags ? 'cuisine')        AS with_cuisine,
       count(*) FILTER (WHERE tags ? 'opening_hours')  AS with_opening_hours,
       count(*) FILTER (WHERE tags ? 'addr:street')    AS with_street_address
FROM spatial_data.places
WHERE category IN ('restaurant','hotel','hospital')
GROUP BY category
ORDER BY category;

\echo '== Q1.11 How much of the extract is Greater Mumbai proper? (Mumbai City + Mumbai Suburban districts)'
-- The extract box also clips parts of Thane, Mira-Bhayander and Navi Mumbai.
SELECT p.category,
       count(*) AS in_extract,
       count(*) FILTER (WHERE EXISTS (
           SELECT 1 FROM spatial_data.administrative_areas d
           WHERE d.admin_level = '5' AND ST_Covers(d.geom, p.geom))) AS in_greater_mumbai
FROM spatial_data.places p
WHERE p.category IN ('hospital','restaurant','school','bank','atm','hotel','pharmacy',
                     'cafe','railway_station','college','police','beauty','hairdresser')
GROUP BY p.category
ORDER BY in_extract DESC;

\echo '== Q1.12 A real (but sparse) ranking attribute: hotels with an OSM stars=* classification'
-- stars=* is the hotel star classification mapped in OSM. Only a few hotels
-- have it, and it is not a popularity measure. Restaurants have no such tag.
SELECT name, tags->'stars' AS stars, ST_AsText(geom, 6) AS location_lon_lat
FROM spatial_data.places
WHERE category = 'hotel' AND tags->'stars' ~ '^[1-7]$'
ORDER BY (tags->'stars')::int DESC, name;
