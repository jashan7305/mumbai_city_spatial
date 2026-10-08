-- =====================================================================
-- 05  SPATIAL RELATIONSHIPS (DE-9IM predicates) on real Mumbai geometries
-- Only predicates with a meaningful Mumbai use case are shown.
-- H/W Ward = Bandra West; "Bandra West" is also mapped separately in OSM
-- as a place=suburb polygon, which is useful for ST_Overlaps.
-- =====================================================================

\echo '== Q5.1  ST_Within: which BMC wards lie within each district?'
SELECT d.name AS district, count(w.id) AS wards_within,
       string_agg(w.name, ', ' ORDER BY w.name) AS wards
FROM spatial_data.administrative_areas d
JOIN spatial_data.administrative_areas w
  ON w.admin_level = '10' AND ST_Within(w.geom, d.geom)
WHERE d.admin_level = '5'
GROUP BY d.name
ORDER BY d.name;

\echo '== Q5.2  ST_Contains: does Mumbai Suburban District contain these stations?'
SELECT s.name AS station,
       ST_Contains(d.geom, s.geom) AS suburban_district_contains_it
FROM spatial_data.administrative_areas d
CROSS JOIN spatial_data.railway_stations s
WHERE d.name = 'Mumbai Suburban District'
  AND s.name IN ('Churchgate','Dadar','Bandra','Andheri','Borivali','Thane','Vashi')
ORDER BY s.name, s.id;

\echo '== Q5.3  ST_Covers vs ST_Contains: places exactly on a district boundary'
-- ST_Covers counts boundary points, ST_Contains does not.
SELECT d.name,
       count(*) FILTER (WHERE ST_Covers(d.geom, p.geom))   AS covered,
       count(*) FILTER (WHERE ST_Contains(d.geom, p.geom)) AS contained,
       count(*) FILTER (WHERE ST_Covers(d.geom, p.geom) AND NOT ST_Contains(d.geom, p.geom))
           AS on_boundary_only
FROM spatial_data.administrative_areas d
JOIN spatial_data.places p ON ST_Intersects(d.geom, p.geom)
WHERE d.admin_level = '5'
GROUP BY d.name
ORDER BY d.name;

\echo '== Q5.4  ST_Intersects: railway lines that pass through Bandra West'
SELECT r.road_type AS railway_type, count(*) AS segments,
       round(sum(ST_Length(ST_Intersection(r.geom, a.geom)::geography))::numeric) AS length_inside_m
FROM spatial_data.roads r
JOIN spatial_data.areas a
  ON a.area_type = 'locality' AND a.name = 'Bandra West'
 AND ST_Intersects(r.geom, a.geom)
WHERE r.line_type = 'railway'
GROUP BY r.road_type
ORDER BY segments DESC;

\echo '== Q5.5  ST_Crosses: named major roads that cross the H/W Ward (Bandra West) boundary'
SELECT DISTINCT r.name, r.road_type
FROM spatial_data.major_roads r
JOIN spatial_data.administrative_areas w
  ON w.name = 'H/W Ward' AND ST_Crosses(r.geom, w.geom)
WHERE r.name IS NOT NULL
ORDER BY r.name;

\echo '== Q5.6  ST_Touches: wards that share a border with H/W Ward'
-- A shared_border_m of 0 means the wards meet at a single point only.
SELECT b.name AS neighbouring_ward,
       round(ST_Length(ST_Intersection(a.geom, b.geom)::geography)::numeric) AS shared_border_m
FROM spatial_data.administrative_areas a
JOIN spatial_data.administrative_areas b
  ON b.admin_level = '10' AND a.id <> b.id AND ST_Touches(a.geom, b.geom)
WHERE a.name = 'H/W Ward'
ORDER BY shared_border_m DESC;

\echo '== Q5.7  ST_Overlaps: the OSM "Bandra West" suburb polygon vs the BMC wards'
-- The interiors intersect but neither polygon is inside the other, i.e. the
-- community-mapped suburb and the official ward boundary do not coincide.
SELECT w.name AS ward,
       ST_Overlaps(l.geom, w.geom) AS overlaps,
       ST_Within(l.geom, w.geom)   AS suburb_within_ward,
       round((ST_Area(ST_Intersection(l.geom, w.geom)::geography) / 1e6)::numeric, 3) AS shared_km2
FROM spatial_data.areas l
JOIN spatial_data.administrative_areas w
  ON w.admin_level = '10' AND ST_Intersects(l.geom, w.geom)
WHERE l.area_type = 'locality' AND l.name = 'Bandra West'
ORDER BY shared_km2 DESC;

\echo '== Q5.8  ST_Disjoint: wards with no point in common with Mumbai City District'
-- Note: ST_Disjoint cannot use an index (it is the negation of ST_Intersects);
-- here it only compares 25 ward polygons, so this is cheap.
SELECT w.name AS ward, ST_Disjoint(w.geom, d.geom) AS disjoint_from_city_district
FROM spatial_data.administrative_areas w
CROSS JOIN spatial_data.administrative_areas d
WHERE w.admin_level = '10' AND w.name LIKE '%Ward'
  AND d.name = 'Mumbai City District'
ORDER BY disjoint_from_city_district, w.name;
