-- =====================================================================
-- 09  EDGE CASES (14 focused cases) against the real Mumbai data
-- Each case states the input and what the result means.
-- =====================================================================

\echo '== E1  No results within radius: 1 km around a point in the Arabian Sea (72.70, 19.00)'
SELECT count(*) AS places_within_1km
FROM spatial_data.places p
WHERE ST_DWithin(p.geom::geography, ST_SetSRID(ST_MakePoint(72.70, 19.00), 4326)::geography, 1000);

\echo '== E2  Radius = 0 at an arbitrary coordinate: only an identical point could match'
SELECT count(*) AS places_at_distance_0
FROM spatial_data.places p
WHERE ST_DWithin(p.geom::geography, ST_SetSRID(ST_MakePoint(72.8777, 19.0760), 4326)::geography, 0);

\echo '== E3  Radius = 0 at the exact location of an existing hospital (Nanavati Hospital, Mumbai)'
-- The query location is copied from the stored point, so distance is exactly 0.
SELECT p.id, p.name, p.category,
       ST_Distance(p.geom::geography, h.geom::geography) AS distance_m
FROM spatial_data.places h
JOIN spatial_data.places p ON ST_DWithin(p.geom::geography, h.geom::geography, 0)
WHERE h.category = 'hospital' AND h.name = 'Nanavati Hospital, Mumbai'
ORDER BY p.id;

\echo '== E4  Very large radius (100 km): every place in the extract is returned'
SELECT (SELECT count(*) FROM spatial_data.places) AS total_places,
       count(*) AS places_within_100km
FROM spatial_data.places p
WHERE ST_DWithin(p.geom::geography, ST_SetSRID(ST_MakePoint(72.8777, 19.0760), 4326)::geography, 100000);

\echo '== E5  Negative radius: PostGIS returns false (no error), even for an identical point'
SELECT ST_DWithin(ST_SetSRID(ST_MakePoint(72.8777, 19.0760), 4326)::geography,
                  ST_SetSRID(ST_MakePoint(72.8777, 19.0760), 4326)::geography, -1) AS within_minus_1m;

\echo '== E6  Out-of-range coordinates: geography silently COERCES them (watch the NOTICE)'
-- Longitude 200 becomes -160 and latitude 95 becomes 85, so validate input first.
SELECT ST_AsText(ST_SetSRID(ST_MakePoint(200, 19.0760), 4326)::geography) AS lon_200_becomes,
       ST_AsText(ST_SetSRID(ST_MakePoint(72.8777, 95), 4326)::geography)  AS lat_95_becomes;
\echo '   Safe pattern: validate the range before running the spatial query'
SELECT v.lon, v.lat,
       (v.lon BETWEEN -180 AND 180 AND v.lat BETWEEN -90 AND 90) AS valid_wgs84,
       CASE WHEN v.lon BETWEEN -180 AND 180 AND v.lat BETWEEN -90 AND 90 THEN
            (SELECT count(*) FROM spatial_data.places p
             WHERE ST_DWithin(p.geom::geography,
                              ST_SetSRID(ST_MakePoint(v.lon, v.lat), 4326)::geography, 1000))
       END AS places_within_1km
FROM (VALUES (72.8777::float8, 19.0760::float8), (200, 19.0760), (72.8777, 95)) AS v(lon, lat);

\echo '== E7  Swapped longitude/latitude: ST_MakePoint(lat, lon) puts the point in the Arctic'
SELECT p.name AS "nearest hospital to POINT(19.0760 72.8777)",
       round((ST_Distance(p.geom::geography,
             ST_SetSRID(ST_MakePoint(19.0760, 72.8777), 4326)::geography) / 1000)::numeric) AS distance_km
FROM spatial_data.places p
WHERE p.category = 'hospital'
ORDER BY p.geom::geography <-> ST_SetSRID(ST_MakePoint(19.0760, 72.8777), 4326)::geography
LIMIT 1;

\echo '== E8  Location outside the extract (Pune, 73.8567 18.5204): KNN has no distance limit'
SELECT p.name AS nearest_hospital_in_database,
       round((ST_Distance(p.geom::geography,
             ST_SetSRID(ST_MakePoint(73.8567, 18.5204), 4326)::geography) / 1000)::numeric, 1) AS distance_km
FROM spatial_data.places p
WHERE p.category = 'hospital'
ORDER BY p.geom::geography <-> ST_SetSRID(ST_MakePoint(73.8567, 18.5204), 4326)::geography
LIMIT 1;
\echo '   Bounded version (KNN + ST_DWithin 5 km) correctly returns nothing'
SELECT count(*) AS hospitals_within_5km_of_pune
FROM spatial_data.places p
WHERE p.category = 'hospital'
  AND ST_DWithin(p.geom::geography, ST_SetSRID(ST_MakePoint(73.8567, 18.5204), 4326)::geography, 5000);

\echo '== E9  NULL geometry: none stored (NOT NULL constraint); NULL input yields NULL / no rows'
SELECT (SELECT count(*) FROM spatial_data.places WHERE geom IS NULL) AS null_place_geoms,
       (SELECT count(*) FROM spatial_data.roads  WHERE geom IS NULL) AS null_road_geoms,
       (SELECT count(*) FROM spatial_data.areas  WHERE geom IS NULL) AS null_area_geoms,
       ST_Distance(NULL::geography, ST_SetSRID(ST_MakePoint(72.8777, 19.0760), 4326)::geography) AS distance_to_null,
       (SELECT count(*) FROM spatial_data.places p
        WHERE ST_DWithin(p.geom::geography, NULL::geography, 1000)) AS rows_matching_null_point;

\echo '== E10 EMPTY geometry: POINT EMPTY is never within any distance'
SELECT ST_IsEmpty('POINT EMPTY'::geometry) AS is_empty,
       ST_Distance('SRID=4326;POINT EMPTY'::geography,
                   ST_SetSRID(ST_MakePoint(72.8777, 19.0760), 4326)::geography) AS distance,
       (SELECT count(*) FROM spatial_data.places p
        WHERE ST_DWithin(p.geom::geography, 'SRID=4326;POINT EMPTY'::geography, 100000)) AS matches;

\echo '== E11 Empty result category: a category absent from Mumbai OSM (casino) vs a present one'
SELECT c.category, count(p.id) AS places
FROM (VALUES ('casino'), ('hospital')) AS c(category)
LEFT JOIN spatial_data.places p ON p.category = c.category
GROUP BY c.category
ORDER BY c.category;

\echo '== E12 Point exactly on a polygon vertex (first vertex of H/W Ward)'
-- Boundary points are NOT within/contained, but ARE covered/intersecting/touching.
WITH w AS (SELECT geom FROM spatial_data.administrative_areas WHERE name = 'H/W Ward'),
     v AS (SELECT ST_PointN(ST_ExteriorRing(ST_GeometryN(geom, 1)), 1) AS pt FROM w)
SELECT ST_AsText(v.pt, 6) AS vertex,
       ST_Within(v.pt, w.geom)     AS within,
       ST_Contains(w.geom, v.pt)   AS contains,
       ST_Covers(w.geom, v.pt)     AS covers,
       ST_Intersects(w.geom, v.pt) AS intersects,
       ST_Touches(w.geom, v.pt)    AS touches
FROM w, v;

\echo '== E13 Point on the shared border of two wards (a vertex common to H/W and H/E)'
-- Strict containment assigns it to neither ward; ST_Covers assigns it to both.
WITH hw AS (SELECT geom FROM spatial_data.administrative_areas WHERE name = 'H/W Ward'),
     he AS (SELECT geom FROM spatial_data.administrative_areas WHERE name = 'H/E Ward'),
     shared AS (
       SELECT a.pt FROM (SELECT (ST_DumpPoints(geom)).geom AS pt FROM hw) a
       JOIN (SELECT (ST_DumpPoints(geom)).geom AS pt FROM he) b ON ST_Equals(a.pt, b.pt)
       ORDER BY ST_X(a.pt), ST_Y(a.pt) LIMIT 1)
SELECT w.name AS ward, ST_AsText(s.pt, 6) AS shared_vertex,
       ST_Contains(w.geom, s.pt) AS contains, ST_Covers(w.geom, s.pt) AS covers
FROM shared s
JOIN spatial_data.administrative_areas w
  ON w.admin_level = '10' AND ST_Intersects(w.geom, s.pt)
ORDER BY w.name;

\echo '== E14 Real data on a boundary: OSM places lying exactly on the Mumbai City District edge'
SELECT p.id, p.name, p.category,
       ST_Contains(d.geom, p.geom) AS contains, ST_Covers(d.geom, p.geom) AS covers
FROM spatial_data.administrative_areas d
JOIN spatial_data.places p ON ST_Covers(d.geom, p.geom) AND NOT ST_Contains(d.geom, p.geom)
WHERE d.name = 'Mumbai City District'
ORDER BY p.id;
