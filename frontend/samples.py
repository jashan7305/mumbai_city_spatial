"""Editable starting points for the live SQL console (loaded into the editor)."""

SAMPLES = [
    ("Find hospitals", """\
SELECT name, category
FROM spatial_data.places
WHERE category = 'hospital'
LIMIT 20;"""),

    ("Find restaurants (with OSM cuisine tag)", """\
SELECT name, category, subcategory AS cuisine
FROM spatial_data.places
WHERE category = 'restaurant'
LIMIT 20;"""),

    ("Places within 1 km of a point (ST_DWithin + ST_Distance)", """\
-- geography casts make the radius and the distance METRES
SELECT name, category,
       round(ST_Distance(
           geom::geography,
           ST_SetSRID(ST_Point(72.8777, 19.0760), 4326)::geography
       )::numeric, 1) AS distance_m
FROM spatial_data.places
WHERE ST_DWithin(
    geom::geography,
    ST_SetSRID(ST_Point(72.8777, 19.0760), 4326)::geography,
    1000
)
ORDER BY distance_m;"""),

    ("5 nearest hospitals (KNN <->)", """\
-- <-> orders by distance using the GiST index; LIMIT keeps the k nearest
SELECT name,
       round(ST_Distance(
           geom::geography,
           ST_SetSRID(ST_Point(72.8777, 19.0760), 4326)::geography
       )::numeric, 1) AS distance_m
FROM spatial_data.places
WHERE category = 'hospital'
ORDER BY geom::geography <-> ST_SetSRID(ST_Point(72.8777, 19.0760), 4326)::geography
LIMIT 5;"""),

    ("Hospitals inside a BMC ward (ST_Within)", """\
-- H/W Ward = Bandra West; try 'K/W Ward' (Andheri West) or 'A Ward' (Colaba/Fort)
SELECT p.name, w.name AS ward
FROM spatial_data.places p
JOIN spatial_data.administrative_areas w
  ON ST_Within(p.geom, w.geom)
WHERE w.name = 'H/W Ward'
  AND p.category = 'hospital'
ORDER BY p.name;"""),

    ("ATMs within 500 m of a railway station (spatial join)", """\
SELECT s.name AS station, a.name AS atm,
       round(ST_Distance(a.geom::geography, s.geom::geography)::numeric, 1) AS distance_m
FROM spatial_data.railway_stations s
JOIN spatial_data.places a
  ON a.category = 'atm'
 AND ST_DWithin(a.geom::geography, s.geom::geography, 500)
WHERE s.name = 'Andheri'
ORDER BY distance_m;"""),

    ("Count places per BMC ward (spatial aggregation)", """\
SELECT w.name AS ward, count(p.id) AS restaurants
FROM spatial_data.administrative_areas w
LEFT JOIN spatial_data.places p
  ON p.category = 'restaurant' AND ST_Within(p.geom, w.geom)
WHERE w.admin_level = '10'
GROUP BY w.name
ORDER BY restaurants DESC;"""),

    ("EXPLAIN ANALYZE: is the spatial index used?", """\
EXPLAIN ANALYZE
SELECT name
FROM spatial_data.places
WHERE category = 'hospital'
ORDER BY geom::geography <-> ST_SetSRID(ST_Point(72.8777, 19.0760), 4326)::geography
LIMIT 5;"""),
]
