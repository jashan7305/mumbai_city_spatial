-- =====================================================================
-- 02  AREA QUERIES: which places lie inside a Mumbai area polygon?
-- Uses real OSM polygons: the suburb "Bandra West" (place=suburb) and the
-- official BMC administrative wards (boundary=administrative, admin_level=10).
-- K/W Ward = Andheri West / Vile Parle West / Juhu; K/E Ward = Andheri East.
-- Containment is computed spatially, never by matching address strings.
-- =====================================================================

\echo '== Q2.1  Restaurants inside Bandra West (ST_Within point-in-polygon)'
SELECT p.id, p.name, p.subcategory AS cuisine
FROM spatial_data.places p
JOIN spatial_data.areas a ON ST_Within(p.geom, a.geom)
WHERE a.area_type = 'locality' AND a.name = 'Bandra West'
  AND p.category = 'restaurant'
ORDER BY p.name NULLS LAST, p.id
LIMIT 25;

\echo '== Q2.2  Hospitals in Andheri West (inside the K/W Ward polygon)'
SELECT p.id, p.name
FROM spatial_data.places p
JOIN spatial_data.administrative_areas w ON ST_Within(p.geom, w.geom)
WHERE w.name = 'K/W Ward' AND p.category = 'hospital'
ORDER BY p.name NULLS LAST, p.id
LIMIT 25;

\echo '== Q2.3  Number of schools, hospitals and restaurants in Andheri East (K/E Ward)'
SELECT p.category, count(*) AS places
FROM spatial_data.places p
JOIN spatial_data.administrative_areas w ON ST_Within(p.geom, w.geom)
WHERE w.name = 'K/E Ward' AND p.category IN ('school','hospital','restaurant')
GROUP BY p.category
ORDER BY p.category;

\echo '== Q2.4  Everything inside Bandra West, by category (top 15)'
SELECT p.category, count(*) AS places
FROM spatial_data.places p
JOIN spatial_data.areas a ON ST_Within(p.geom, a.geom)
WHERE a.area_type = 'locality' AND a.name = 'Bandra West'
GROUP BY p.category
ORDER BY places DESC, p.category
LIMIT 15;

\echo '== Q2.5  Hospitals per square km in each BMC ward (spatial aggregation)'
SELECT w.name AS ward,
       count(p.id) AS hospitals,
       round((ST_Area(w.geom::geography) / 1e6)::numeric, 1) AS area_km2,
       round((count(p.id) / (ST_Area(w.geom::geography) / 1e6))::numeric, 2) AS hospitals_per_km2
FROM spatial_data.administrative_areas w
LEFT JOIN spatial_data.places p
       ON p.category = 'hospital' AND ST_Within(p.geom, w.geom)
WHERE w.admin_level = '10' AND w.name LIKE '%Ward'
GROUP BY w.id, w.name, w.geom
ORDER BY hospitals_per_km2 DESC;

\echo '== Q2.6  ST_Within vs ST_Contains vs ST_Covers for Mumbai City District'
-- For points strictly inside a polygon all three agree. They differ only for
-- points lying exactly on the boundary (see queries/09_edge_cases.sql).
SELECT a.name,
       count(*) FILTER (WHERE ST_Within(p.geom, a.geom))   AS within,
       count(*) FILTER (WHERE ST_Contains(a.geom, p.geom)) AS contains,
       count(*) FILTER (WHERE ST_Covers(a.geom, p.geom))   AS covers
FROM spatial_data.administrative_areas a
JOIN spatial_data.places p ON ST_Intersects(a.geom, p.geom)
WHERE a.name = 'Mumbai City District'
GROUP BY a.name;
