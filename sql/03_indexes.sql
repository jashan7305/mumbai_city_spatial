-- Spatial indexes (GiST) and a few attribute (B-tree) indexes.
--
-- * GiST on geom (geometry, EPSG:4326) accelerates topological predicates
--   such as ST_Within / ST_Contains / ST_Covers / ST_Intersects via a
--   bounding-box (&&) filter.
-- * GiST on the expression (geom::geography) accelerates metre-based
--   ST_DWithin(geom::geography, ..., metres) and geography KNN ordering
--   (geom::geography <-> point::geography), without storing a second column.
CREATE INDEX IF NOT EXISTS places_geom_gist_idx ON spatial_data.places USING GIST (geom);
CREATE INDEX IF NOT EXISTS places_geog_gist_idx ON spatial_data.places USING GIST ((geom::geography));
CREATE INDEX IF NOT EXISTS roads_geom_gist_idx  ON spatial_data.roads  USING GIST (geom);
CREATE INDEX IF NOT EXISTS roads_geog_gist_idx  ON spatial_data.roads  USING GIST ((geom::geography));
CREATE INDEX IF NOT EXISTS areas_geom_gist_idx  ON spatial_data.areas  USING GIST (geom);

-- B-tree indexes only where queries filter on attributes.
CREATE INDEX IF NOT EXISTS places_category_idx ON spatial_data.places (category);
CREATE INDEX IF NOT EXISTS roads_type_idx      ON spatial_data.roads (line_type, road_type);
CREATE INDEX IF NOT EXISTS roads_name_idx      ON spatial_data.roads (name);
CREATE INDEX IF NOT EXISTS areas_type_name_idx ON spatial_data.areas (area_type, name);

ANALYZE spatial_data.places;
ANALYZE spatial_data.roads;
ANALYZE spatial_data.areas;
