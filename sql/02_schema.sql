-- Clean Mumbai model over classic osm2pgsql output (--hstore-all).
-- Run in a transaction with scripts/create_schema.sh. Raw geometries remain
-- untouched in EPSG:3857; project geometries are transformed to EPSG:4326.
DROP VIEW IF EXISTS spatial_data.railway_stations;
DROP VIEW IF EXISTS spatial_data.metro_monorail_stations;
DROP VIEW IF EXISTS spatial_data.major_roads;
DROP VIEW IF EXISTS spatial_data.administrative_areas;
DROP VIEW IF EXISTS spatial_data.buildings;
DROP TABLE IF EXISTS spatial_data.places;
DROP TABLE IF EXISTS spatial_data.roads;
DROP TABLE IF EXISTS spatial_data.areas;

CREATE TABLE spatial_data.areas (
    id BIGSERIAL PRIMARY KEY,
    osm_id BIGINT NOT NULL,
    osm_type TEXT NOT NULL CHECK (osm_type IN ('way','relation')),
    name TEXT,
    area_type TEXT NOT NULL,
    subcategory TEXT,
    admin_level TEXT,
    tags HSTORE NOT NULL,
    geom geometry(MultiPolygon,4326) NOT NULL
);

-- A classic import can split a relation into multiple polygon rows. Collect
-- its pieces into one OSM feature; source relation IDs are negative.
-- osm2pgsql 1.x stores a per-piece 'way_area' inside tags, so it is removed
-- before grouping (it is derived, not an OSM tag).
INSERT INTO spatial_data.areas (osm_id,osm_type,name,area_type,subcategory,admin_level,tags,geom)
SELECT osm_id, CASE WHEN osm_id < 0 THEN 'relation' ELSE 'way' END,
       max(name),
       CASE
         WHEN tags->'boundary'='administrative' THEN 'administrative'
         WHEN tags ? 'boundary' THEN 'boundary'
         WHEN tags ? 'place' THEN 'locality'
         WHEN tags ? 'building' THEN 'building'
         WHEN tags->'leisure'='park' THEN 'park'
         WHEN tags ? 'landuse' THEN 'landuse'
         WHEN tags->'natural'='water' OR tags ? 'water' THEN 'water'
         WHEN tags ? 'leisure' THEN 'leisure'
         WHEN tags ? 'amenity' THEN 'amenity'
         WHEN tags ? 'natural' THEN 'natural'
         ELSE 'other'
       END,
       COALESCE(tags->'place',tags->'building',tags->'leisure',tags->'landuse',
                tags->'water',tags->'amenity',tags->'natural',tags->'boundary'),
       tags->'admin_level', tags,
       ST_Multi(ST_CollectionExtract(ST_UnaryUnion(ST_Collect(ST_Transform(way,4326))),3))::geometry(MultiPolygon,4326)
FROM (SELECT osm_id, name, tags - 'way_area'::text AS tags, way
      FROM raw_osm.planet_osm_polygon) raw
WHERE way IS NOT NULL AND NOT ST_IsEmpty(way)
GROUP BY osm_id,tags
ORDER BY osm_id;

CREATE TABLE spatial_data.places (
    id BIGSERIAL PRIMARY KEY,
    osm_type TEXT NOT NULL CHECK (osm_type IN ('node','way','relation')),
    osm_id BIGINT NOT NULL,
    name TEXT,
    category TEXT NOT NULL,
    subcategory TEXT,
    tag_key TEXT NOT NULL,
    location_method TEXT NOT NULL CHECK (location_method IN ('osm_node','point_on_surface')),
    tags HSTORE NOT NULL,
    geom geometry(Point,4326) NOT NULL,
    UNIQUE (osm_type,osm_id)
);

-- Include POIs mapped as nodes AND POIs mapped as buildings/area features.
-- PointOnSurface is explicitly labelled, not presented as an original OSM node.
WITH source AS (
    SELECT 'node'::text osm_type, p.osm_id, p.name, p.tags,
           'osm_node'::text location_method, ST_Transform(p.way,4326) geom
    FROM raw_osm.planet_osm_point p
    WHERE p.way IS NOT NULL AND NOT ST_IsEmpty(p.way)
    UNION ALL
    SELECT a.osm_type, abs(a.osm_id), a.name, a.tags,
           'point_on_surface', ST_PointOnSurface(a.geom)
    FROM spatial_data.areas a
), classified AS (
    SELECT *,
       CASE
         WHEN tags->'railway' IN ('station','halt') OR
              (tags->'public_transport'='station' AND tags->'train'='yes') THEN 'railway_station'
         WHEN tags ? 'amenity' THEN tags->'amenity'
         WHEN tags ? 'healthcare' THEN tags->'healthcare'
         WHEN tags ? 'shop' THEN tags->'shop'
         WHEN tags ? 'tourism' THEN tags->'tourism'
         WHEN tags ? 'place' AND name IS NOT NULL THEN 'locality'
         ELSE NULL
       END category,
       CASE
         WHEN tags->'railway' IN ('station','halt') OR
              (tags->'public_transport'='station' AND tags->'train'='yes') THEN 'railway'
         WHEN tags ? 'amenity' THEN 'amenity'
         WHEN tags ? 'healthcare' THEN 'healthcare'
         WHEN tags ? 'shop' THEN 'shop'
         WHEN tags ? 'tourism' THEN 'tourism'
         WHEN tags ? 'place' THEN 'place'
       END tag_key
    FROM source
)
INSERT INTO spatial_data.places (osm_type,osm_id,name,category,subcategory,tag_key,location_method,tags,geom)
SELECT osm_type,osm_id,name,category,
       CASE WHEN category='railway_station' THEN tags->'station'
            WHEN category='locality' THEN tags->'place'
            ELSE COALESCE(tags->'cuisine',tags->'healthcare:speciality',tags->'beauty') END,
       tag_key,location_method,tags,geom::geometry(Point,4326)
FROM (
    SELECT DISTINCT ON (osm_type,osm_id) *
    FROM classified
    WHERE NULLIF(category,'') IS NOT NULL
    ORDER BY osm_type,osm_id,location_method
) selected
ORDER BY osm_type,osm_id;

CREATE TABLE spatial_data.roads (
    id BIGSERIAL PRIMARY KEY,
    osm_id BIGINT NOT NULL,
    name TEXT,
    line_type TEXT NOT NULL CHECK (line_type IN ('road','railway','waterway')),
    road_type TEXT NOT NULL,
    tags HSTORE NOT NULL,
    geom geometry(LineString,4326) NOT NULL
);
INSERT INTO spatial_data.roads (osm_id,name,line_type,road_type,tags,geom)
SELECT osm_id,name,
       CASE WHEN tags ? 'highway' THEN 'road'
            WHEN tags ? 'railway' THEN 'railway' ELSE 'waterway' END,
       COALESCE(tags->'highway',tags->'railway',tags->'waterway'), tags,
       ST_Transform(way,4326)::geometry(LineString,4326)
FROM raw_osm.planet_osm_line
WHERE way IS NOT NULL AND NOT ST_IsEmpty(way)
  AND (tags ? 'highway' OR tags ? 'railway' OR tags ? 'waterway')
ORDER BY osm_id;

CREATE VIEW spatial_data.railway_stations AS
SELECT * FROM spatial_data.places
WHERE category='railway_station'
  AND tags->'railway' IN ('station','halt')
  AND COALESCE(tags->'station','') NOT IN ('subway','monorail');
CREATE VIEW spatial_data.metro_monorail_stations AS
SELECT * FROM spatial_data.places
WHERE category='railway_station' AND tags->'station' IN ('subway','monorail');
CREATE VIEW spatial_data.major_roads AS
SELECT * FROM spatial_data.roads WHERE line_type='road'
  AND road_type IN ('motorway','trunk','primary','secondary',
                   'motorway_link','trunk_link','primary_link','secondary_link');
CREATE VIEW spatial_data.administrative_areas AS
SELECT * FROM spatial_data.areas WHERE area_type='administrative';
CREATE VIEW spatial_data.buildings AS
SELECT * FROM spatial_data.areas WHERE tags ? 'building';

COMMENT ON TABLE spatial_data.places IS 'Real Mumbai metropolitan OSM POIs: nodes and labelled representative points for mapped areas.';
COMMENT ON COLUMN spatial_data.places.osm_id IS 'Positive source OSM ID, qualified by osm_type; node/area duplicates are not assumed to be the same business.';
COMMENT ON COLUMN spatial_data.places.category IS 'Actual amenity/healthcare/shop/tourism tag value; railway_station and locality are documented normalized categories.';
COMMENT ON COLUMN spatial_data.places.tag_key IS 'Source OSM key used for categorization.';
COMMENT ON COLUMN spatial_data.places.location_method IS 'osm_node for original point features; point_on_surface for area POIs.';
COMMENT ON COLUMN spatial_data.places.tags IS 'All imported OSM attributes, including address tags where present.';
COMMENT ON COLUMN spatial_data.places.geom IS 'Longitude X, latitude Y in EPSG:4326. Cast to geography for metre distances.';
COMMENT ON TABLE spatial_data.roads IS 'OSM road, railway and waterway segments; one way may produce multiple segments.';
COMMENT ON COLUMN spatial_data.roads.road_type IS 'Actual highway, railway or waterway tag value, distinguished by line_type.';
COMMENT ON TABLE spatial_data.areas IS 'OSM polygon features collected by source ID; no invented administrative boundaries.';
COMMENT ON COLUMN spatial_data.areas.admin_level IS 'Original OSM administrative hierarchy level, stored as text.';
COMMENT ON VIEW spatial_data.railway_stations IS 'Suburban/mainline railway station and halt POIs (excludes metro/monorail and stations under construction).';
COMMENT ON VIEW spatial_data.metro_monorail_stations IS 'Mumbai Metro (station=subway) and Monorail station POIs.';
