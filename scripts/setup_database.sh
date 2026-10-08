#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

"$(dirname "$0")/start_database.sh"
source "$(dirname "$0")/common.sh"   # re-read the port start_database.sh chose

if [[ "$("$PSQL_BIN" -X -v ON_ERROR_STOP=1 -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'")" != "1" ]]; then
  "$CREATEDB_BIN" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" "$DB_NAME"
  printf 'Created database %s\n' "$DB_NAME"
else
  printf 'Database %s already exists; leaving it intact.\n' "$DB_NAME"
fi

psql_project -f "${PROJECT_ROOT}/sql/01_database.sql"
printf 'PostGIS, hstore, and project schemas are ready in %s.\n' "$DB_NAME"
