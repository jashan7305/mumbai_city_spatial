# Spatial Query Processing on Mumbai OpenStreetMap Data Using PostgreSQL/PostGIS

Short title: **Mumbai Spatial Database Query System**

A spatial database built from real OpenStreetMap (OSM) data for Mumbai, and a
library of SQL/PostGIS queries that demonstrate spatial data types, spatial
relationships, distance and nearest-neighbour search, spatial joins and spatial
indexing. The deliverable is the database plus the queries and their real
outputs. There is no application, API or dashboard; everything runs through
`psql` (or pgAdmin/QGIS if you prefer). An optional, read-only local web page
(section 14) can run the same query files from a browser, and has a live SQL
console for typing new read-only PostGIS queries during a demonstration.

## 1. Objective

Store Mumbai's real geographic data (points of interest, roads, railways,
buildings, parks and administrative boundaries) in a spatial database, and
answer location-based questions with SQL, for example:

- Which hospitals are in Andheri West? Which restaurants are in Bandra West?
- Which hospitals are within 2 km of a given coordinate?
- What is the nearest hospital, and what are the 5 nearest restaurants?
- Which ATMs are within 500 m of Andheri station?
- Which restaurants are within 500 m of railway stations?
- How does a GiST spatial index change the query plan?

**Why a spatial database?** These questions are about *location* (containment,
distance, adjacency, nearest neighbours), not about keys. A spatial database
stores geometry as a column type, evaluates spatial predicates in SQL, and
indexes geometry so the questions are answered efficiently.

**Why OpenStreetMap?** OSM is real, openly licensed (ODbL), and contains the
three basic geometry kinds (points, lines and polygons), with rich but
heterogeneous tags. That heterogeneity is part of real spatial data handling.

**Why Mumbai?** One dense metropolitan area gives meaningful local queries
(stations, wards, hospitals and restaurants) while staying small: the extract
is 20 MB and the database is about 255 MB.

**Why PostgreSQL/PostGIS?** PostGIS adds the `geometry`/`geography` types,
hundreds of OGC/SQL-MM spatial functions (`ST_Within`, `ST_DWithin`,
`ST_Distance`, ...), the KNN operator `<->`, and GiST spatial indexes, all
inside a full SQL database with a cost-based planner and `EXPLAIN ANALYZE`.

## 2. Dataset

| Item | Value |
|---|---|
| Source | Official OpenStreetMap planet snapshot published by the OpenStreetMap Foundation on the AWS Open Data Registry |
| File | `s3://osm-pds/2026/planet-260928.osm.pbf` (https://osm-pds.s3.amazonaws.com/2026/planet-260928.osm.pbf, 95,121,754,261 bytes, published MD5 `3b704522e01272f5a6078ec93b275b64`) |
| Data date | Planet of 2026-09-28; newest object timestamp in the extract 2026-09-27T07:42:34Z |
| Mumbai box | `72.75,18.85,73.05,19.30` (west, south, east, north; EPSG:4326) |
| Result | `data/raw/mumbai.osm.pbf`: 20,265,365 bytes, SHA-256 `c9472282b7a0cf978b3f7db1fde094b07ccd60e3a310599cd05d6b38bf0160dc` |
| Contents | 1,855,618 nodes, 292,081 ways, 3,427 relations |
| Licence | © OpenStreetMap contributors, ODbL 1.0 (https://www.openstreetmap.org/copyright) |

**Geographic coverage.** The box covers Greater Mumbai (the Mumbai City and
Mumbai Suburban districts, from Colaba to Dahisar and Mulund) with a small
margin. That margin includes parts of Thane, Mira-Bhayander and Navi Mumbai.
Boundary relations and ways that cross the box are kept complete, so the
Mumbai district, zone and ward polygons are whole. Query Q1.11 separates
records inside Greater Mumbai proper from the margin. For example, 931 of
the 1,243 hospitals lie inside the two Mumbai districts.

**Why not Geofabrik/BBBike?** Geofabrik has no Mumbai-only extract. The build
environment for this project also could not reach Geofabrik, BBBike, Overpass
or the OSM mirrors (HTTP 403 from the network policy). The only reachable source
was the official planet file on AWS, so the Mumbai extract was cut from it
(below). The final 20 MB extract is committed in `data/raw/`, so a fresh
clone builds against exactly this snapshot without downloading anything.

### Extraction method (`scripts/download_data.sh`)

The 95 GB planet is never stored. Only the clip is written to disk:

1. **Stage 1, streaming.** The planet is fetched with parallel HTTP range
   requests (6 × 128 MB chunks, reassembled strictly in order, at most ~3 GB
   on disk at a time). It is piped once through
   `osmium extract --strategy simple --bbox 72.50,18.70,73.30,19.50` into a
   31 MB buffer file. In this environment the stream took about 18 minutes.
2. **Stage 2, clip.**
   `osmium extract --strategy smart -S types=multipolygon,boundary --bbox 72.75,18.85,73.05,19.30`
   cuts the Mumbai box from the buffer. It keeps every way and
   multipolygon/boundary relation that touches the box complete.

If you have direct internet access, any PBF covering the Mumbai box (for
example a Geofabrik India or Western Zone extract) can be saved as
`data/raw/mumbai_buffer.osm.pbf`. Stage 1 is then skipped. Note that a
different snapshot gives slightly different counts.

## 3. Requirements and installation

Tested with: Ubuntu 24.04, PostgreSQL 16.15, PostGIS 3.4.2, osm2pgsql 1.11.0,
osmium-tool 1.16.0. macOS/Homebrew is also supported by the scripts. No Python
is needed.

```bash
./scripts/install_dependencies.sh     # apt (Ubuntu/Debian) or Homebrew (macOS)
```

## 4. Database setup

The project runs its **own** PostgreSQL cluster in `data/pgdata` on
`127.0.0.1:5433`, so any other PostgreSQL service or database on the machine
is never touched.

| Setting | Value (`config/project.env`) |
|---|---|
| Database | `mumbai_spatial_db` |
| Host / port | `127.0.0.1` / `5433` |
| User | the current OS user (override with `DB_USER` or `PGUSER`) |
| Authentication | trust on localhost (isolated development cluster) |

When the scripts run as root, the server process runs as the `postgres` OS user
(PostgreSQL refuses to run as root).

**Which PostgreSQL is used.** The scripts pick the first PostgreSQL
installation that **has PostGIS**. They check, in order: Homebrew
`postgresql@18`/`17`/`16`/`15`/`14`, Postgres.app, `/usr/lib/postgresql/*`,
then `pg_config` on PATH. Another PostgreSQL on PATH without PostGIS is
skipped, for example Homebrew `postgresql@14`, since Homebrew's `postgis` is
built for newer versions. To force a choice, set `PG_BIN`, e.g.
`export PG_BIN="$(brew --prefix postgresql@18)/bin"`.

**Handled automatically by `start_database.sh`.** Every script that needs
the database uses `start_database.sh`, including `build_all.sh` and
`run_web.sh`. It handles these cases itself:

- **`data/pgdata` belongs to the wrong PostgreSQL version, or is incomplete.**
  Examples: `could not open extension control file …/postgis.control`, or
  `database files are incompatible with server … PG_CONTROL_VERSION`. The
  folder is recreated with the PostgreSQL that has PostGIS. It only holds
  rebuildable project data; nothing outside `data/pgdata` is touched.
- **Another server already listens on port 5433.** Examples: `Address already
  in use`, or a cluster started from another copy of this project. That
  server is never used. The project moves to the next free port (5434, …)
  and remembers it in `data/port`, so every script, `psql.sh` and the web
  page use it.
- **The server cannot start for another reason.** The last lines of
  `data/postgresql.log` are printed.

`run_web.sh` also builds the database first if it has not been built yet.
To start completely fresh at any time:

```bash
./scripts/reset_database.sh --yes   # removes only data/pgdata (and data/port)
./scripts/build_all.sh
```

## 5. Build (from a clean terminal)

```bash
cd mumbai_city_spatial
./scripts/install_dependencies.sh   # once per machine
./scripts/build_all.sh              # about 20 s when data/raw/mumbai.osm.pbf is present
```

`build_all.sh` runs these idempotent steps, which can also be run one at a time:

| Step | Script | What it does |
|---|---|---|
| 1 | `setup_database.sh` | starts the project cluster, creates `mumbai_spatial_db`, enables `postgis` and `hstore`, creates schemas (`sql/01_database.sql`) |
| 2 | `download_data.sh` | produces `data/raw/mumbai.osm.pbf` (skipped if present; `--replace` rebuilds it) |
| 3 | `import_osm.sh` | osm2pgsql classic import (`--slim --drop --hstore-all`) into schema `raw_osm` (skipped if done; `--replace` re-imports) |
| 4 | `create_schema.sh` | builds the clean tables and views in `spatial_data` (`sql/02_schema.sql`) |
| 5 | `create_indexes.sh` | GiST and B-tree indexes plus `ANALYZE` (`sql/03_indexes.sql`) |
| 6 | `run_queries.sh` | runs every file in `queries/` and saves the real output to `results/` |

Other helpers: `./scripts/psql.sh` opens psql on the project database, and
`./scripts/stop_database.sh` stops the project cluster. After a reboot, run
`./scripts/start_database.sh` (or `setup_database.sh`) again.
`./scripts/run_web.sh` starts the optional web page (section 14).

## 6. Schema

```
mumbai_spatial_db
├── raw_osm        osm2pgsql output, untouched (EPSG:3857)
│     planet_osm_point (61,387)  planet_osm_line (99,851)
│     planet_osm_polygon (193,551)  planet_osm_roads (11,400)
└── spatial_data   clean project-facing model (EPSG:4326)
      places   (table)  18,517 POINT
      roads    (table)  92,238 LINESTRING
      areas    (table) 193,370 MULTIPOLYGON
      railway_stations, metro_monorail_stations, major_roads,
      administrative_areas, buildings   (views)
```

| Table | Columns | Content |
|---|---|---|
| `spatial_data.places` | `id, osm_type, osm_id, name, category, subcategory, tag_key, location_method, tags (hstore), geom geometry(Point,4326)` | POIs mapped as OSM nodes, plus POIs mapped as building/area polygons represented by `ST_PointOnSurface` (`location_method='point_on_surface'`: 3,946 of 18,517). `category` is the real `amenity`/`healthcare`/`shop`/`tourism` value; `railway_station` and `locality` are the two normalized categories. `tags` keeps every OSM tag, including `addr:*`, `cuisine`, `opening_hours` and `stars`. |
| `spatial_data.roads` | `id, osm_id, name, line_type (road/railway/waterway), road_type, tags, geom geometry(LineString,4326)` | 88,389 road, 2,488 railway and 1,361 waterway segments (osm2pgsql splits long ways into segments). |
| `spatial_data.areas` | `id, osm_id, osm_type, name, area_type, subcategory, admin_level, tags, geom geometry(MultiPolygon,4326)` | One row per OSM polygon feature; the pieces of a relation are merged. Area types: 174,306 buildings, 9,196 land use, 1,614 parks, 853 water, 2,005 other leisure, 1,463 natural, 1,670 amenity, 301 localities, 42 administrative, 18 other boundaries, 1,902 other. |

| View | Definition | Rows |
|---|---|---|
| `railway_stations` | `railway=station/halt`, excluding metro/monorail | 84 (suburban and mainline stations from Churchgate to Dahisar and Mulund, including Navi Mumbai and Thane stations inside the box) |
| `metro_monorail_stations` | `station=subway/monorail` | 117 |
| `major_roads` | motorway/trunk/primary/secondary and their links | 8,749 |
| `administrative_areas` | `boundary=administrative` | 42 |
| `buildings` | areas with a `building` tag | 174,309 |

**Administrative areas actually present:** Mumbai City District and Mumbai
Suburban District (admin_level 5); Mumbai Zone 1–6 (level 9); the 24 BMC wards
A, B, C, D, E, F/N, F/S, G/N, G/S, H/E, H/W, K/E, K/W, L, M/E, M/W, N, P/N, P/S,
R/C, R/N, R/S, S and T, plus Ambu Island (level 10); and neighbouring Thane,
Navi Mumbai, Mira-Bhayander, Panvel, Dombivali, Bhiwandi-Nizampur, and the
Thane, Panvel and Uran subdistricts. Neighbourhood names map to BMC wards: H/W
Ward = Bandra West, K/W Ward = Andheri West / Vile Parle West / Juhu,
K/E Ward = Andheri East. OSM also has a separate `place=suburb` polygon named
**Bandra West** (7.2 km²), which the area queries use.

## 7. Spatial data types and SRIDs

| | SRID | Units | Why |
|---|---|---|---|
| Source (`raw_osm.*.way`) | **3857** (Web Mercator, osm2pgsql default) | Mercator metres, distorted (×1.06 at Mumbai's latitude) | osm2pgsql default; never used for measurement |
| Project (`spatial_data.*.geom`) | **4326** (WGS84 lon/lat) | degrees | readable coordinates; standard for exchange; transformed with `ST_Transform(way, 4326)` |
| Measurements | `geom::geography` | **metres** on the WGS84 spheroid | correct distances and radii without choosing a projection |

Degrees are never treated as metres. Every radius and distance in the queries
uses `::geography`. Q3.6 shows the difference: Churchgate to Mumbai CSMT is
0.009964 "degrees" on geometry, 1,063.3 m on geography, and 1,063.6 m in the
UTM 43N projection. `ST_MakePoint` takes **(longitude, latitude)**; E7 shows
what happens when they are swapped.

Geometry types: points are `POINT`; roads, railways and waterways are
`LINESTRING`; buildings, parks, land use, water and administrative areas are
`MULTIPOLYGON`. All geometries are non-NULL and non-empty, and every
administrative polygon is valid (`ST_IsValid`).

## 8. Spatial indexes (`sql/03_indexes.sql`)

| Index | Type | Used for |
|---|---|---|
| `places_geom_gist_idx` on `places(geom)` | GiST | point-in-polygon (`ST_Within`/`ST_Contains`/`ST_Covers`/`ST_Intersects`) |
| `places_geog_gist_idx` on `places((geom::geography))` | GiST (expression) | `ST_DWithin(..., metres)` and KNN `<->` in metres |
| `roads_geom_gist_idx`, `roads_geog_gist_idx` | GiST | road/railway intersections and distance-to-road |
| `areas_geom_gist_idx` | GiST | polygon-polygon relationships |
| `places_category_idx`, `roads_type_idx`, `roads_name_idx`, `areas_type_name_idx` | B-tree | attribute filters (category, road type, area name) |

A GiST index stores bounding boxes in an R-tree-like hierarchy. A spatial
predicate is evaluated in two steps. First, a fast **filter** step uses the
index to find rows whose box overlaps the query box (`&&`, `@`, or
`_st_expand` for a radius). Second, an exact **refinement** step runs the
real predicate (`ST_DWithin`, `ST_Within`) on those candidates only. For KNN,
the index returns rows in increasing distance order, so `ORDER BY <-> LIMIT k`
stops after about k rows.

## 9. Query library (`queries/`)

| File | Demonstrates |
|---|---|
| `01_basic_queries.sql` | data validation: geometry types/SRIDs, categories present, hospitals, restaurants, stations, schools, road types, admin areas, rating attributes, Greater Mumbai vs margin, hotel stars |
| `02_area_queries.sql` | restaurants in Bandra West, hospitals in Andheri West (K/W Ward), counts per ward, `ST_Within` vs `ST_Contains` vs `ST_Covers` |
| `03_distance_queries.sql` | hospitals within 2 km, restaurants within 1 km, schools within 3 km, ATMs within 500 m of Andheri station, places within 300 m, degrees vs metres |
| `04_nearest_queries.sql` | nearest hospital, 5 nearest restaurants, 10 nearest hospitals, nearest station, KNN `LATERAL` join per station |
| `05_relationships.sql` | `ST_Within`, `ST_Contains`, `ST_Covers`, `ST_Intersects`, `ST_Crosses`, `ST_Touches`, `ST_Overlaps`, `ST_Disjoint` on wards, districts, stations, railways and roads |
| `06_spatial_joins.sql` | hospitals near stations, restaurants within 500 m of stations, hospitals near major roads, schools/hospitals/restaurants per ward, buildings in Bandra West |
| `07_combined_queries.sql` | 5 nearest restaurants inside Bandra West to Bandra station; hospitals within 2 km of stations in K/W Ward; restaurants within 200 m of Linking Road ordered by distance; ward plus radius filter; nearest 5-star hotels |
| `08_performance.sql` | GiST index list and sizes; `EXPLAIN (ANALYZE, BUFFERS)` for radius, KNN, point-in-polygon and spatial join; the same join with index scans disabled |
| `09_edge_cases.sql` | 14 edge cases (section 11) |

Every query runs directly. Query points are written as literals, for example
`ST_SetSRID(ST_MakePoint(72.8777, 19.0760), 4326)`, a user-chosen coordinate
in Kurla West that is **not** an OSM feature. Edit the literals to try other
locations.

### Executing and inspecting

```bash
./scripts/psql.sh -f queries/03_distance_queries.sql   # run one file
./scripts/run_queries.sh                               # run all, write results/NN_*.txt
./scripts/psql.sh                                      # interactive psql
```

`results/` contains the **actual** output of every query file from the build
of this snapshot. Nothing there is hand-written. Timings in
`results/08_performance.txt` are real but vary from run to run.

### Example queries and real results

Hospitals within 2 km of a point (Q3.1, 28 rows):

```sql
SELECT p.id, p.name,
       round(ST_Distance(p.geom::geography,
             ST_SetSRID(ST_MakePoint(72.8777, 19.0760), 4326)::geography)::numeric, 1) AS distance_m
FROM spatial_data.places p
WHERE p.category = 'hospital'
  AND ST_DWithin(p.geom::geography,
                 ST_SetSRID(ST_MakePoint(72.8777, 19.0760), 4326)::geography, 2000)
ORDER BY distance_m, p.id;
```
```
  id   |          name           | distance_m
 15453 | New Noor Hospital       |       39.4
  6754 | Habib Hospital          |      354.6
  6747 | Muskaan Hospital        |      387.1   ... (28 rows)
```

The 5 nearest restaurants with KNN (Q4.2):

```sql
SELECT p.id, p.name, round(ST_Distance(p.geom::geography,
       ST_SetSRID(ST_MakePoint(72.8777, 19.0760), 4326)::geography)::numeric, 1) AS distance_m
FROM spatial_data.places p
WHERE p.category = 'restaurant'
ORDER BY p.geom::geography <-> ST_SetSRID(ST_MakePoint(72.8777, 19.0760), 4326)::geography
LIMIT 5;
```
```
 Karizma Dhaba 119.5 | Deluxe Restaurant 405.2 | Istanbul Darbar 416.6 | Sahara 468.9 | Skyway 628.2
```

Restaurants inside Bandra West (Q2.1/Q2.4): 104 restaurants lie inside the
Bandra West suburb polygon. ATMs within 500 m of Andheri station (Q3.4):
4 ATMs (Indian Bank 110.8 m, an unnamed ATM 129.1 m, State Bank of India
202.3 m, an unnamed ATM 291.5 m). The 5 nearest restaurants inside Bandra West
to Bandra station (Q7.1): New Riyaz Restaurant 162.3 m, Sai Sagar 289.8 m,
Lucky 290.5 m, Deepa Bar and Restaurant 397.3 m, Gokul Refreshments 559.0 m.

### "Famous" places

OSM has no popularity, review or "famous" attribute, so the project does not
rank places by fame. Q1.10 checks this. Only 2 of 1,140 restaurants have a
rating-like tag (`stars`), 536 have `cuisine`, 232 have `opening_hours`. The
only defensible ranking attribute found is the hotel star classification
(`stars=*`, 20 hotels, Q1.12/Q7.5), which is official star rating, not
popularity. Restaurant queries therefore use area, radius, nearest-neighbour
and the real `cuisine` tag.

## 10. EXPLAIN ANALYZE and the spatial index (`queries/08_performance.sql`)

```bash
./scripts/psql.sh -f queries/08_performance.sql
```

Plans recorded in `results/08_performance.txt` (times from that run; they vary between runs):

| Query | Plan node | Execution time |
|---|---|---|
| Restaurants within 1 km | `BitmapAnd` of `Bitmap Index Scan on places_geog_gist_idx` (`&& _st_expand(…,1000)`) and `places_category_idx` | 7.1 ms (176 index candidates → 9 rows) |
| 5 nearest hospitals | `Index Scan using places_geog_gist_idx`, `Order By: (geom::geography <-> …)` under `Limit` | 0.3 ms (54 rows visited) |
| Places in K/W Ward | `Index Scan using places_geom_gist_idx`, `Index Cond: (geom @ areas.geom)` then `st_within` | 3.4 ms |
| Restaurants within 500 m of every station (spatial join) | `Nested Loop` with inner `Index Scan using places_geog_gist_idx` (84 loops) | **4.3 ms** |
| Same join, `enable_indexscan/bitmapscan = off` | `Nested Loop` over two `Seq Scan`s, `Rows Removed by Join Filter: 95529` | **147.4 ms** |

Without the index, every one of the 84 stations is compared with every one of
the 1,140 restaurants (95,760 exact distance computations). With the index,
each station only checks the few restaurants whose bounding box falls within
500 m. The comparison uses `SET LOCAL` inside a rolled-back transaction, so no
setting changes permanently.

## 11. Edge cases (`queries/09_edge_cases.sql`)

| # | Case | Real result |
|---|---|---|
| E1 | 1 km around a point in the Arabian Sea | 0 places |
| E2 | radius 0 at an arbitrary coordinate | 0 places |
| E3 | radius 0 at an existing hospital's exact location | exactly that hospital, distance 0 |
| E4 | 100 km radius | all 18,517 places |
| E5 | negative radius | `false`, no error, even for identical points |
| E6 | out-of-range lon 200 / lat 95 | **silently coerced** to (-160, 19.076) and (72.8777, 85) with only a NOTICE; the query shows a validate-first pattern |
| E7 | lon/lat swapped | nearest "hospital" is 6,819 km away (the point lands in the Arctic) |
| E8 | point outside the extract (Pune) | KNN still returns a hospital 99.1 km away; adding `ST_DWithin` bounds it to 0 |
| E9 | NULL geometry | none stored (NOT NULL); NULL input gives NULL distance and 0 rows |
| E10 | `POINT EMPTY` | distance NULL, 0 matches |
| E11 | absent category (`casino`) | 0 rows (vs 1,243 hospitals) |
| E12 | point on a polygon vertex | within/contains = false; covers/intersects/touches = true |
| E13 | vertex shared by H/W and H/E wards | contained by neither ward, covered by both |
| E14 | real OSM data on a boundary | 3 Gateway of India ferry terminals lie exactly on the Mumbai City District coastline: covered but not contained |

## 12. Limitations

- OSM is volunteer-mapped. Coverage varies, and some tags are inconsistent.
  For example, some clinics are tagged `amenity=hospital`, and a few places
  are mapped twice (once as a node, once as a building). Counts describe OSM,
  not an official register.
- The extract is a rectangle, so it also contains parts of neighbouring
  cities (see Q1.11).
- osm2pgsql's classic output splits long lines into segments, so a named road
  is many rows. Q7.3 merges them with `ST_Union` when needed.
- Mapped-area POIs are represented by `ST_PointOnSurface`, which is labelled
  in `location_method`.
- `geography` KNN (`<->`) orders by spherical distance, while `ST_Distance`
  reports spheroidal distance (difference < 0.5%). Q4.2 and Q4.3 re-sort the
  k candidates by the reported distance.
- `EXPLAIN ANALYZE` timings depend on the machine and cache state.

## 13. Reproducibility

- Pinned source file (`PLANET_URL`) and bounding boxes are in `config/project.env`.
- The resulting extract is committed with its SHA-256 (section 2), and
  `download_data.sh --replace` regenerates it.
- All build steps are idempotent scripts. A clean rebuild (cluster deleted,
  `./scripts/build_all.sh`) was run and verified for this README, and every
  command shown above was executed.
- To optionally inspect the data visually in QGIS, add a PostGIS connection to
  `127.0.0.1:5433 / mumbai_spatial_db` and load the `spatial_data` tables.

## 14. Optional local web page (`frontend/`)

A thin demonstration layer over the database. The page has three clearly
separated sections, each in its own coloured box:

- **A. Search around a location:** enter your own latitude and longitude.
- **B. Predefined project queries:** the tested queries from `queries/`,
  run exactly as written.
- **C. Live SQL query console:** type or edit any read-only
  PostgreSQL/PostGIS query and run it live against `mumbai_spatial_db`.

None of them adds spatial logic of its own; all spatial work is done by
PostGIS in the database.

### A. Search around a location

Enter any **latitude and longitude**, or fill them from one of the 84
railway stations or with the browser's "Use my location". Then choose:

- **Category:** any category, or one of the real `places.category` values
  with at least 20 records.
- **Search type:** "Nearest N" (KNN `<->`) or "All within radius"
  (`ST_DWithin`, metres).

The results table shows name, category, distance in metres and coordinates.
The status box shows the row count, the execution time and which BMC ward
the point lies in (`ST_Covers`). A note appears if the point is outside the
Mumbai data area.

The exact SQL that ran is shown under "SQL that was executed" and can be
opened in the live console (C) for editing. The inputs are validated
(latitude −90..90, longitude −180..180, radius 1–50,000 m, N 1–500,
category from the list), and the query runs through the same read-only
connection as the other sections. Defaults reproduce the project results,
e.g. the nearest hospital to 19.0760, 72.8777 is New Noor Hospital at
39.4 m, and Andheri station + `atm` + 500 m gives the 4 ATMs of Q3.4.

**Start it**

```bash
./scripts/build_all.sh   # only if the database has not been built yet
./scripts/run_web.sh     # then open http://127.0.0.1:5050  (Ctrl+C stops it)
```

### B. Predefined project queries

The predefined mode is a convenience for running the **existing** query files
from a browser and viewing the results as HTML tables. It adds no new spatial logic:
`frontend/app.py` reads `queries/NN_*.sql` at start-up, splits each file at its
`\echo '== <id> <title>'` headings, and executes those SQL blocks as written.
The `.txt` outputs in `results/` remain the reference record.

**Technology:** Python 3 + Flask (backend), plain HTML/CSS/JavaScript (page),
psycopg 3 (PostgreSQL driver). `run_web.sh` installs Flask and psycopg into
`frontend/.venv` on first start; no other tools are needed.

**Steps**

1. Build the database once if you have not: `./scripts/build_all.sh`
2. Start the page: `./scripts/run_web.sh`. This starts the project database
   if needed, (re)creates the read-only role, and starts the server.
3. Open **http://127.0.0.1:5050** in a browser. Set `WEB_PORT` to use another
   port; 5000 is avoided because macOS uses it for AirPlay.
4. Select a query from the dropdown (all 68 queries of files 01–09, grouped by file).
5. Enter parameters if the query has any (see below).
6. Click **Run Query**. Rows appear as tables. A query with several result
   sets, such as a count followed by a list, shows several tables, and
   `EXPLAIN ANALYZE` plans appear line by line. PostgreSQL NOTICEs and errors
   are shown on the page. Stop the server with Ctrl+C.

**Parameters.** Running a query with its default values gives exactly the
saved output. For all 62 non-timing queries the web results were checked
cell by cell against `results/*.txt` and are identical. A few queries accept
parameters, which replace specific literals in their SQL with bound values:

| Query | Parameters (defaults = the values in the file) |
|---|---|
| Q3.1, Q3.2, Q3.3, Q3.5 (radius queries) | latitude, longitude, radius in metres |
| Q4.1–Q4.4 (nearest hospital/restaurants/station) | latitude, longitude |
| Q7.4 (ward + radius) | latitude, longitude, radius in metres |
| Q3.4 (ATMs near a station) | railway station (list from the database), radius in metres |
| Q2.2, Q2.3 (places in a BMC ward) | ward (list from the database) |

Inputs are validated: latitude must be in −90..90, longitude in −180..180,
and the radius in 0..100,000 m. Ward and station must be names that exist in
the database. Invalid or missing input returns an error message and is never
sent to PostgreSQL.

**Read-only by design**

- In this mode the browser sends only a query id and parameter values,
  never SQL. Unknown ids are rejected. (The live console in C sends SQL text,
  which is validated as described below.)
- The app connects as the role `mumbai_web`
  (`sql/04_web_readonly_role.sql`). That role has only SELECT privileges,
  defaults to read-only transactions with a 30 s statement timeout, and every
  request is rolled back. `DELETE`, `CREATE` and `DROP` attempted as this role
  fail.
- Credentials never reach the browser. The server uses the local
  trust-authenticated connection, and it listens on 127.0.0.1 only.

### C. Live SQL console

Write any read-only PostgreSQL/PostGIS query in the editor and click **Run
Query** (or press Ctrl+Enter). The query is executed **at that moment** on
`mumbai_spatial_db`; nothing is cached or precomputed. For example, change
`LIMIT 20` to `LIMIT 50`, or `'hospital'` to `'restaurant'`, run again, and
the result changes accordingly. The page shows:

- whether the query succeeded or failed;
- the number of rows returned;
- the execution time;
- the result table.

`EXPLAIN` / `EXPLAIN ANALYZE` output is shown as a preformatted plan. PostgreSQL
errors are shown as psql would show them: the message, the line and a caret
at the error position, and any hint.

- **Sample SQL:** eight editable examples, each with a "Load into editor"
  button: hospitals; restaurants; places within 1 km (`ST_DWithin` +
  `ST_Distance`); the 5 nearest hospitals (`<->`); hospitals inside a BMC ward
  (`ST_Within`); ATMs within 500 m of a station; restaurants per ward; and
  `EXPLAIN ANALYZE` showing the GiST index. **Open in live console** copies
  the selected predefined query into the editor.
- **"What can I query?"** lists the tables and views with their real
  columns and row counts (read from the database at start-up), common
  `places.category` values, and one-line explanations of the main PostGIS
  functions and the `<->` operator.
- **Large results:** at most 1,000 rows are displayed, but the reported row
  count is the true total (for example 193,370 for `SELECT * FROM spatial_data.areas`).
  Geometry columns are shown readably: points as `POINT(lon lat)`, other
  shapes by type (use `ST_AsText(geom)` for full coordinates).

**Allowed:** one statement that is `SELECT`, `WITH … SELECT`, `VALUES`/`TABLE`,
or `EXPLAIN [ANALYZE] …` of such a query, using any read-only function
(`ST_DWithin`, `ST_Distance`, `ST_Within`, `ST_Contains`, `ST_Intersects`,
`ST_Covers`, and so on).

**Blocked (validated in the backend before execution, `frontend/live_sql.py`):**

- **Write and DDL keywords:** `INSERT`, `UPDATE`, `DELETE`, `MERGE`,
  `TRUNCATE`, `COPY`, `SELECT … INTO`, `CREATE`, `ALTER`, `DROP`, `GRANT`,
  `REVOKE`.
- **Transaction and session control:** `BEGIN`, `COMMIT`, `ROLLBACK`, `SET`,
  `RESET`, `LOCK`.
- **Admin and procedural commands:** `VACUUM`, `ANALYZE` (except in
  `EXPLAIN ANALYZE`), `CALL`, `DO`, `EXECUTE`, `PREPARE`, and others.
- **Side-effect functions:** `set_config`, `pg_sleep`, file, large-object
  and advisory-lock functions, `nextval`/`setval`.
- **Structure:** multiple statements, `EXPLAIN` of a non-SELECT, and
  dollar-quoted strings.

Keywords are matched as whole words outside string literals, quoted
identifiers and comments. So `SELECT 'DELETE me'` is fine, while
`WITH d AS (DELETE …) SELECT …` is rejected.

**Database-level protection, independent of the validator.** The console
uses the same read-only role `mumbai_web` (SELECT-only privileges, read-only
transactions, 30 s statement timeout) and rolls back every request. In
addition, PostgreSQL itself refuses more than one statement per request:
`SELECT` runs through a server-side cursor (`DECLARE … CURSOR`, which also
rejects data-modifying `WITH` clauses), and `EXPLAIN` runs as a prepared
statement. A runaway query, such as a three-way cross join, is cancelled
after 30 s with a clear message.

**Tested live** through the HTTP endpoint and in a real browser:
- **Basic queries:** a basic `SELECT`; hospitals and restaurants (`LIMIT 20`
  changed to `LIMIT 50` and `'hospital'` to `'restaurant'` in the editor).
- **Spatial queries:** `ST_DWithin`; `ST_Distance`; `<->` KNN; a ward
  `ST_Within` join.
- **EXPLAIN:** `EXPLAIN ANALYZE` (the plan shows `Index Scan using
  places_geog_gist_idx`).
- **Errors and rejections:** invalid SQL and unknown columns (PostgreSQL
  error shown); `INSERT`/`UPDATE`/`DELETE`/`DROP`/`TRUNCATE`/`ALTER`/`BEGIN`
  and bypass attempts (all rejected).
- **Result sizes:** a zero-row result; a many-row result (18,517 places).
- **Unchanged data:** after all tests the table still has 18,517 places.
- **Same numbers as the project:** the sample queries reproduce the project
  results, for example the nearest hospital is 39.4 m away, H/W Ward
  contains 34 hospitals, and there are 4 ATMs near Andheri.

Data © OpenStreetMap contributors, available under the Open Database License (ODbL 1.0).
