#!/usr/bin/env bash
# Start the local read-only web front end for the query library.
#   ./scripts/run_web.sh      then open http://127.0.0.1:5050
# Starts the project database (building it first if needed). Requires Python 3.
set -euo pipefail
source "$(dirname "$0")/common.sh"

"$(dirname "$0")/start_database.sh"
source "$(dirname "$0")/common.sh"   # re-read the port start_database.sh chose
if [[ "$(psql_project -Atqc "SELECT to_regclass('spatial_data.places') IS NOT NULL" 2>/dev/null || true)" != "t" ]]; then
  printf 'The Mumbai database is not built yet; building it now (about a minute)...\n'
  BUILD_LOG="${PROJECT_ROOT}/data/build.log"
  : > "$BUILD_LOG"
  for step in setup_database download_data import_osm create_schema create_indexes; do
    if ! "$(dirname "$0")/${step}.sh" >>"$BUILD_LOG" 2>&1; then
      printf '%s failed. Last lines of %s:\n' "$step" "$BUILD_LOG" >&2
      tail -n 20 "$BUILD_LOG" >&2
      exit 1
    fi
  done
  printf 'Database built.\n'
  source "$(dirname "$0")/common.sh"
fi

# (Re)create the read-only role and its grants (idempotent).
psql_project -q -f "${PROJECT_ROOT}/sql/04_web_readonly_role.sql"
if [[ "${DB_EXTERNAL:-0}" == "1" && -n "${WEB_DB_PASSWORD:-}" ]]; then
  psql_project -v web_password="$WEB_DB_PASSWORD" -f - <<'SQL'
ALTER ROLE mumbai_web PASSWORD :'web_password';
SQL
fi

if [[ "${DOCKERIZED:-0}" == "1" ]]; then
  PYTHON_BIN="${PYTHON_BIN:-python3}"
else
  VENV="${PROJECT_ROOT}/frontend/.venv"
  if [[ ! -x "${VENV}/bin/python" ]]; then
    python3 -m venv "$VENV"
  fi
  "${VENV}/bin/pip" install -q -r "${PROJECT_ROOT}/frontend/requirements.txt"
  PYTHON_BIN="${VENV}/bin/python"
fi

export PGUSER=mumbai_web            # the app never connects as the superuser
export WEB_PORT="${WEB_PORT:-5050}"
printf 'Open http://127.0.0.1:%s  (Ctrl+C to stop)\n' "$WEB_PORT"
exec "$PYTHON_BIN" "${PROJECT_ROOT}/frontend/app.py"
