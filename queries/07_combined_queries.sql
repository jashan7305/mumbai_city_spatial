-- =====================================================================
-- 07  COMBINED QUERIES: attribute filter + area filter + distance + KNN
-- =====================================================================

\echo '== Q7.1  5 nearest restaurants INSIDE Bandra West to Bandra railway station'
-- attribute filter (category) + spatial filter (ST_Within suburb polygon)
-- + KNN ordering (<->) + metre distance (ST_Distance on geography)
SELECT r.id, r.name, r.subcategory AS cuisine,
       round(ST_Distance(r.geom::geography, s.geom::geography)::numeric, 1) AS distance_m
FROM spatial_data.railway_stations s
JOIN spatial_data.areas a
  ON a.area_type = 'locality' AND a.name = 'Bandra West'
JOIN spatial_data.places r
  ON r.category = 'restaurant' AND ST_Within(r.geom, a.geom)
WHERE s.name = 'Bandra'
ORDER BY r.geom::geography <-> s.geom::geography, r.id
LIMIT 5;

\echo '== Q7.2  Hospitals within 2 km of a railway station located in Andheri West (K/W Ward)'
-- Stations are selected by area (ST_Within the ward), hospitals by distance
-- (ST_DWithin 2000 m); each hospital is reported once with its closest station.
SELECT * FROM (
    SELECT DISTINCT ON (h.id)
           h.id, h.name AS hospital, s.name AS closest_station_in_ward,
           round(ST_Distance(h.geom::geography, s.geom::geography)::numeric, 1) AS distance_m
    FROM spatial_data.administrative_areas w
    JOIN spatial_data.railway_stations s ON ST_Within(s.geom, w.geom)
    JOIN spatial_data.places h
      ON h.category = 'hospital'
     AND ST_DWithin(h.geom::geography, s.geom::geography, 2000)
    WHERE w.name = 'K/W Ward' AND h.name IS NOT NULL
    ORDER BY h.id, distance_m
) closest
ORDER BY distance_m, id
LIMIT 20;
\echo '   (total count)'
SELECT count(DISTINCT h.id) AS hospitals_within_2km_of_a_kw_ward_station,
       string_agg(DISTINCT s.name, ', ') AS stations_in_ward
FROM spatial_data.administrative_areas w
JOIN spatial_data.railway_stations s ON ST_Within(s.geom, w.geom)
JOIN spatial_data.places h
  ON h.category = 'hospital'
 AND ST_DWithin(h.geom::geography, s.geom::geography, 2000)
WHERE w.name = 'K/W Ward';

\echo '== Q7.3  Restaurants within 200 m of Linking Road, ordered by distance to the road'
-- The road is many OSM segments; ST_Union merges them into one line first.
WITH linking_road AS (
    SELECT ST_Union(geom) AS geom
    FROM spatial_data.roads
    WHERE line_type = 'road' AND name = 'Linking Road'
)
SELECT p.id, p.name, p.subcategory AS cuisine,
       round(ST_Distance(p.geom::geography, lr.geom::geography)::numeric, 1) AS distance_to_road_m
FROM spatial_data.places p, linking_road lr
WHERE p.category = 'restaurant'
  AND ST_DWithin(p.geom::geography, lr.geom::geography, 200)
ORDER BY distance_to_road_m, p.id;

\echo '== Q7.4  Restaurants within 1 km of the point (72.8777, 19.0760) that are in the same ward as the point'
-- The ward is found with ST_Covers (point-in-polygon, boundary inclusive);
-- the result is the intersection of a ward filter and a radius filter.
SELECT w.name AS ward, p.id, p.name,
       round(ST_Distance(p.geom::geography, pt.g::geography)::numeric, 1) AS distance_m
FROM (SELECT ST_SetSRID(ST_MakePoint(72.8777, 19.0760), 4326) AS g) pt
JOIN spatial_data.administrative_areas w
  ON w.admin_level = '10' AND ST_Covers(w.geom, pt.g)
JOIN spatial_data.places p
  ON p.category = 'restaurant'
 AND ST_Within(p.geom, w.geom)
 AND ST_DWithin(p.geom::geography, pt.g::geography, 1000)
ORDER BY distance_m, p.id;

\echo '== Q7.5  The 3 nearest 5-star hotels (OSM stars=5) to Bandra railway station'
-- attribute filter on an hstore tag + KNN ordering + metre distance
SELECT h.name, h.tags->'stars' AS stars,
       round((ST_Distance(h.geom::geography, s.geom::geography) / 1000)::numeric, 2) AS distance_km
FROM spatial_data.railway_stations s
JOIN spatial_data.places h ON h.category = 'hotel' AND h.tags->'stars' = '5'
WHERE s.name = 'Bandra'
ORDER BY h.geom::geography <-> s.geom::geography, h.id
LIMIT 3;
