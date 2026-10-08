-- =====================================================================
-- 03  DISTANCE / NEARBY QUERIES (ST_DWithin, ST_Distance)
--
-- Units: geometries are stored in EPSG:4326 (longitude/latitude DEGREES).
-- Every distance/radius below casts to ::geography, so ST_DWithin radii and
-- ST_Distance results are in METRES on the WGS84 spheroid. The expression
-- index places_geog_gist_idx ON ((geom::geography)) makes these casts indexable.
--
-- Reference point used in this file: lon 72.8777, lat 19.0760 (a user-chosen
-- coordinate in Kurla West / BKC area; it is NOT an OSM feature).
-- Note ST_MakePoint takes (longitude, latitude) -- X first.
-- =====================================================================

\echo '== Q3.1  Hospitals within 2 km of (72.8777, 19.0760), nearest first'
SELECT p.id, p.name,
       round(ST_Distance(p.geom::geography,
             ST_SetSRID(ST_MakePoint(72.8777, 19.0760), 4326)::geography)::numeric, 1) AS distance_m
FROM spatial_data.places p
WHERE p.category = 'hospital'
  AND ST_DWithin(p.geom::geography,
                 ST_SetSRID(ST_MakePoint(72.8777, 19.0760), 4326)::geography, 2000)
ORDER BY distance_m, p.id;

\echo '== Q3.2  Restaurants within 1 km of the same point'
SELECT p.id, p.name, p.subcategory AS cuisine,
       round(ST_Distance(p.geom::geography,
             ST_SetSRID(ST_MakePoint(72.8777, 19.0760), 4326)::geography)::numeric, 1) AS distance_m
FROM spatial_data.places p
WHERE p.category = 'restaurant'
  AND ST_DWithin(p.geom::geography,
                 ST_SetSRID(ST_MakePoint(72.8777, 19.0760), 4326)::geography, 1000)
ORDER BY distance_m, p.id;

\echo '== Q3.3  Schools within 3 km of the same point (count and 10 closest)'
SELECT count(*) AS schools_within_3km
FROM spatial_data.places p
WHERE p.category = 'school'
  AND ST_DWithin(p.geom::geography,
                 ST_SetSRID(ST_MakePoint(72.8777, 19.0760), 4326)::geography, 3000);
SELECT p.id, p.name,
       round(ST_Distance(p.geom::geography,
             ST_SetSRID(ST_MakePoint(72.8777, 19.0760), 4326)::geography)::numeric, 1) AS distance_m
FROM spatial_data.places p
WHERE p.category = 'school'
  AND ST_DWithin(p.geom::geography,
                 ST_SetSRID(ST_MakePoint(72.8777, 19.0760), 4326)::geography, 3000)
ORDER BY distance_m, p.id
LIMIT 10;

\echo '== Q3.4  ATMs within 500 m of Andheri railway station'
SELECT a.id, a.name AS atm, a.tags->'operator' AS operator,
       round(ST_Distance(a.geom::geography, s.geom::geography)::numeric, 1) AS distance_m
FROM spatial_data.railway_stations s
JOIN spatial_data.places a
  ON a.category = 'atm'
 AND ST_DWithin(a.geom::geography, s.geom::geography, 500)
WHERE s.name = 'Andheri'
ORDER BY distance_m, a.id;

\echo '== Q3.5  All places within a 300 m radius of the point, by category'
SELECT p.category, count(*) AS places
FROM spatial_data.places p
WHERE ST_DWithin(p.geom::geography,
                 ST_SetSRID(ST_MakePoint(72.8777, 19.0760), 4326)::geography, 300)
GROUP BY p.category
ORDER BY places DESC, p.category;

\echo '== Q3.6  Why ::geography? Distance between Churchgate and Mumbai CSMT stations'
-- On EPSG:4326 *geometry*, ST_Distance returns degrees, which are not metres
-- (and a degree of longitude is shorter than a degree of latitude here).
SELECT round(ST_Distance(a.geom, b.geom)::numeric, 6)                       AS geometry_distance_degrees,
       round(ST_Distance(a.geom::geography, b.geom::geography)::numeric, 1) AS geography_distance_m,
       round(ST_Distance(ST_Transform(a.geom, 32643),
                         ST_Transform(b.geom, 32643))::numeric, 1)          AS utm43n_distance_m
FROM spatial_data.railway_stations a, spatial_data.railway_stations b
WHERE a.name = 'Churchgate' AND b.name = 'Mumbai CSMT';
