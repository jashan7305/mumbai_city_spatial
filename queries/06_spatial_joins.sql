-- =====================================================================
-- 06  SPATIAL JOINS: joining two datasets by location, not by a key
-- Metre thresholds use ::geography (indexed by the *_geog_gist_idx indexes);
-- containment uses geometry (indexed by the *_geom_gist_idx indexes).
-- One station building in OSM has no name tag; it is labelled by its OSM id.
-- =====================================================================

\echo '== Q6.1  Hospitals within 1 km of each railway station (top 15 stations)'
SELECT COALESCE(s.name, '(unnamed: ' || s.osm_type || '/' || s.osm_id || ')') AS station, count(h.id) AS hospitals_within_1km,
       round(min(ST_Distance(s.geom::geography, h.geom::geography))::numeric, 1) AS closest_m
FROM spatial_data.railway_stations s
JOIN spatial_data.places h
  ON h.category = 'hospital'
 AND ST_DWithin(h.geom::geography, s.geom::geography, 1000)
GROUP BY s.id, s.name, s.osm_type, s.osm_id
ORDER BY hospitals_within_1km DESC, s.name
LIMIT 15;

\echo '== Q6.2  Restaurants within 500 m of railway stations (top 15 stations)'
SELECT COALESCE(s.name, '(unnamed: ' || s.osm_type || '/' || s.osm_id || ')') AS station, count(r.id) AS restaurants_within_500m
FROM spatial_data.railway_stations s
JOIN spatial_data.places r
  ON r.category = 'restaurant'
 AND ST_DWithin(r.geom::geography, s.geom::geography, 500)
GROUP BY s.id, s.name, s.osm_type, s.osm_id
ORDER BY restaurants_within_500m DESC, s.name
LIMIT 15;

\echo '== Q6.3  Hospitals within 100 m of a major road vs. not (motorway/trunk/primary/secondary)'
SELECT EXISTS (
         SELECT 1 FROM spatial_data.major_roads r
         WHERE ST_DWithin(h.geom::geography, r.geom::geography, 100)
       ) AS within_100m_of_major_road,
       count(*) AS hospitals
FROM spatial_data.places h
WHERE h.category = 'hospital'
GROUP BY 1
ORDER BY 1 DESC;

\echo '== Q6.4  Examples: named hospitals and the major road they are next to (<= 30 m)'
SELECT DISTINCT ON (h.id) h.name AS hospital, r.name AS road, r.road_type,
       round(ST_Distance(h.geom::geography, r.geom::geography)::numeric, 1) AS distance_m
FROM spatial_data.places h
JOIN spatial_data.major_roads r
  ON ST_DWithin(h.geom::geography, r.geom::geography, 30)
WHERE h.category = 'hospital' AND h.name IS NOT NULL AND r.name IS NOT NULL
ORDER BY h.id, distance_m
LIMIT 15;

\echo '== Q6.5  Schools, hospitals and restaurants inside every BMC ward (point-in-polygon join)'
SELECT w.name AS ward,
       count(*) FILTER (WHERE p.category = 'school')     AS schools,
       count(*) FILTER (WHERE p.category = 'hospital')   AS hospitals,
       count(*) FILTER (WHERE p.category = 'restaurant') AS restaurants
FROM spatial_data.administrative_areas w
JOIN spatial_data.places p
  ON p.category IN ('school','hospital','restaurant')
 AND ST_Within(p.geom, w.geom)
WHERE w.admin_level = '10' AND w.name LIKE '%Ward'
GROUP BY w.name
ORDER BY w.name;

\echo '== Q6.6  Buildings (polygons) inside Bandra West: count and footprint area'
SELECT count(*) AS buildings,
       round((sum(ST_Area(b.geom::geography)) / 1e6)::numeric, 3) AS footprint_km2,
       round((ST_Area(a.geom::geography) / 1e6)::numeric, 3)      AS suburb_km2
FROM spatial_data.areas a
JOIN spatial_data.buildings b ON ST_Within(b.geom, a.geom)
WHERE a.area_type = 'locality' AND a.name = 'Bandra West'
GROUP BY a.geom;
