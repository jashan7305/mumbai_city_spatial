#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

if [[ ! -s "$OSM_FILE" ]]; then
  printf 'OSM extract is missing: %s. Run scripts/download_data.sh first.\n' "$OSM_FILE" >&2
  exit 1
fi
if ! command -v osm2pgsql >/dev/null 2>&1; then
  printf 'osm2pgsql is not installed. Run scripts/install_dependencies.sh first.\n' >&2
  exit 1
fi

STYLE=""
for candidate in \
  "$(brew --prefix 2>/dev/null || true)/share/osm2pgsql/default.style" \
  "/usr/share/osm2pgsql/default.style" \
  "/opt/homebrew/share/osm2pgsql/default.style" \
  "/usr/local/share/osm2pgsql/default.style"; do
  if [[ -f "$candidate" ]]; then STYLE="$candidate"; break; fi
done
if [[ -z "$STYLE" ]]; then
  printf 'Could not locate osm2pgsql default.style. Is osm2pgsql installed?\n' >&2
  exit 1
fi

# Skip a completed import unless an explicit replacement is requested.
IMPORTED="$(psql_project -Atqc "SELECT to_regclass('raw_osm.planet_osm_point') IS NOT NULL AND to_regclass('raw_osm.planet_osm_polygon') IS NOT NULL")"
if [[ "$IMPORTED" == "t" && "${1:-}" != "--replace" ]]; then
  printf 'Mumbai raw OSM tables already exist. Use --replace for an intentional reimport.\n'
  exit 0
fi
psql_project -c 'DROP SCHEMA IF EXISTS raw_osm CASCADE; CREATE SCHEMA raw_osm;'

# osm2pgsql 1.8 (included by Debian Bookworm) does not have the newer
# --schema option. PostgreSQL applies this search_path to every connection
# osm2pgsql opens, so its classic output is still created in raw_osm.
IMPORT_PGOPTIONS="${PGOPTIONS:-}"
[[ -n "$IMPORT_PGOPTIONS" ]] && IMPORT_PGOPTIONS+=" "
IMPORT_PGOPTIONS+="-c search_path=raw_osm,public"
PGOPTIONS="$IMPORT_PGOPTIONS" osm2pgsql \
  --create \
  --slim \
  --drop \
  --output=pgsql \
  --style="$STYLE" \
  --hstore-all \
  --cache="$IMPORT_CACHE_MB" \
  --number-processes="$IMPORT_PROCESSES" \
  --database="$DB_NAME" \
  --host="$PGHOST" \
  --port="$PGPORT" \
  --user="$PGUSER" \
  "$OSM_FILE"

printf 'OSM import completed in schema raw_osm.\n'
