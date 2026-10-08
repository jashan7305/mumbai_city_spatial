-- =====================================================================
-- 04  NEAREST-NEIGHBOUR (KNN) QUERIES with the PostGIS <-> operator
--
-- ORDER BY geom::geography <-> point::geography LIMIT k lets the GiST index
-- places_geog_gist_idx return candidates in distance order (metres, measured
-- on a sphere), so only about k index entries are visited instead of the
-- whole table. Using geography (not 4326 degrees) keeps the ordering correct:
-- at Mumbai's latitude 1 degree of longitude is ~5% shorter than 1 degree of
-- latitude, so degree-based ordering could rank neighbours wrongly.
--
-- Precision note: geography <-> ranks by distance on a sphere, while
-- ST_Distance(geography) reports the more accurate spheroid distance. The two
-- differ by <0.5%, so neighbours ~1 m apart can swap; Q4.2/Q4.3 therefore take
-- the k KNN candidates and re-sort them by the reported spheroid distance.
--
-- Reference point: lon 72.8777, lat 19.0760 (user-chosen, not an OSM feature).
-- =====================================================================

\echo '== Q4.1  The single nearest hospital to (72.8777, 19.0760)'
SELECT p.id, p.name,
       round(ST_Distance(p.geom::geography,
             ST_SetSRID(ST_MakePoint(72.8777, 19.0760), 4326)::geography)::numeric, 1) AS distance_m
FROM spatial_data.places p
WHERE p.category = 'hospital'
ORDER BY p.geom::geography <-> ST_SetSRID(ST_MakePoint(72.8777, 19.0760), 4326)::geography, p.id
LIMIT 1;

\echo '== Q4.2  The 5 nearest restaurants'
SELECT * FROM (
    SELECT p.id, p.name, p.subcategory AS cuisine,
           round(ST_Distance(p.geom::geography,
                 ST_SetSRID(ST_MakePoint(72.8777, 19.0760), 4326)::geography)::numeric, 1) AS distance_m
    FROM spatial_data.places p
    WHERE p.category = 'restaurant'
    ORDER BY p.geom::geography <-> ST_SetSRID(ST_MakePoint(72.8777, 19.0760), 4326)::geography, p.id
    LIMIT 5
) knn ORDER BY distance_m, id;

\echo '== Q4.3  The 10 nearest hospitals'
SELECT * FROM (
    SELECT p.id, p.name,
           round(ST_Distance(p.geom::geography,
                 ST_SetSRID(ST_MakePoint(72.8777, 19.0760), 4326)::geography)::numeric, 1) AS distance_m
    FROM spatial_data.places p
    WHERE p.category = 'hospital'
    ORDER BY p.geom::geography <-> ST_SetSRID(ST_MakePoint(72.8777, 19.0760), 4326)::geography, p.id
    LIMIT 10
) knn ORDER BY distance_m, id;

\echo '== Q4.4  Nearest railway station to the point'
SELECT s.id, s.name,
       round(ST_Distance(s.geom::geography,
             ST_SetSRID(ST_MakePoint(72.8777, 19.0760), 4326)::geography)::numeric, 1) AS distance_m
FROM spatial_data.railway_stations s
ORDER BY s.geom::geography <-> ST_SetSRID(ST_MakePoint(72.8777, 19.0760), 4326)::geography, s.id
LIMIT 1;

\echo '== Q4.5  KNN join: nearest hospital to every Western Line station from Churchgate to Bandra'
-- LATERAL runs one indexed KNN search per station. Dadar appears twice because
-- OSM maps the Western-line and Central-line Dadar stations as separate nodes.
SELECT s.id AS station_id, s.name AS station, h.name AS nearest_hospital, h.distance_m
FROM spatial_data.railway_stations s
CROSS JOIN LATERAL (
    SELECT p.name,
           round(ST_Distance(p.geom::geography, s.geom::geography)::numeric, 1) AS distance_m
    FROM spatial_data.places p
    WHERE p.category = 'hospital'
    ORDER BY p.geom::geography <-> s.geom::geography, p.id
    LIMIT 1
) h
WHERE s.name IN ('Churchgate','Marine Lines','Charni Road','Grant Road','Mumbai Central',
                 'Mahalaxmi','Lower Parel','Prabhadevi','Dadar','Matunga Road',
                 'Mahim Junction','Bandra')
ORDER BY ST_Y(s.geom), s.name;
