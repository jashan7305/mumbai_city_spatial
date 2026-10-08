-- =====================================================================
-- 08  SPATIAL INDEX DEMONSTRATION with EXPLAIN ANALYZE
-- Four representative queries are shown with the GiST indexes in place, then
-- one is repeated with index scans disabled (SET LOCAL inside a transaction
-- that is rolled back, so no server setting changes permanently).
-- Timings are real measurements from this machine and vary between runs.
-- =====================================================================

\echo '== Q8.0  Spatial (GiST) indexes and their sizes'
SELECT c.relname AS index_name, t.relname AS table_name, am.amname AS method,
       pg_get_indexdef(c.oid) AS definition,
       pg_size_pretty(pg_relation_size(c.oid)) AS size
FROM pg_index i
JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_class t ON t.oid = i.indrelid
JOIN pg_am am   ON am.oid = c.relam
JOIN pg_namespace n ON n.oid = t.relnamespace
WHERE n.nspname = 'spatial_data' AND am.amname = 'gist'
ORDER BY t.relname, c.relname;

\echo '== Q8.1  Radius query: restaurants within 1 km (ST_DWithin on geography)'
-- Expect: Bitmap/Index Scan on places_geog_gist_idx with an && _st_expand(...) condition.
EXPLAIN (ANALYZE, BUFFERS)
SELECT p.id, p.name
FROM spatial_data.places p
WHERE p.category = 'restaurant'
  AND ST_DWithin(p.geom::geography,
                 ST_SetSRID(ST_MakePoint(72.8777, 19.0760), 4326)::geography, 1000);

\echo '== Q8.2  KNN query: 5 nearest hospitals (ORDER BY <-> LIMIT 5)'
-- Expect: Index Scan using places_geog_gist_idx with "Order By: (... <-> ...)".
EXPLAIN (ANALYZE, BUFFERS)
SELECT p.id, p.name
FROM spatial_data.places p
WHERE p.category = 'hospital'
ORDER BY p.geom::geography <-> ST_SetSRID(ST_MakePoint(72.8777, 19.0760), 4326)::geography
LIMIT 5;

\echo '== Q8.3  Point-in-polygon: places inside the K/W Ward polygon (ST_Within)'
-- Expect: Index Scan on places_geom_gist_idx with (geom @ w.geom) bounding-box condition.
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM spatial_data.administrative_areas w
JOIN spatial_data.places p ON ST_Within(p.geom, w.geom)
WHERE w.name = 'K/W Ward';

\echo '== Q8.4  Spatial join: restaurants within 500 m of every railway station'
-- Expect: Nested Loop, inner Index Scan on places_geog_gist_idx once per station.
EXPLAIN (ANALYZE, BUFFERS)
SELECT s.id, count(r.id)
FROM spatial_data.railway_stations s
JOIN spatial_data.places r
  ON r.category = 'restaurant'
 AND ST_DWithin(r.geom::geography, s.geom::geography, 500)
GROUP BY s.id;

\echo '== Q8.5  The same spatial join WITHOUT index scans (controlled comparison)'
-- Only for this transaction: the planner must use sequential scans, so every
-- station is compared with every restaurant.
BEGIN;
SET LOCAL enable_indexscan = off;
SET LOCAL enable_bitmapscan = off;
EXPLAIN (ANALYZE, BUFFERS)
SELECT s.id, count(r.id)
FROM spatial_data.railway_stations s
JOIN spatial_data.places r
  ON r.category = 'restaurant'
 AND ST_DWithin(r.geom::geography, s.geom::geography, 500)
GROUP BY s.id;
ROLLBACK;
