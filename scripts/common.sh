#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${PROJECT_ROOT}/config/project.env"

# Always target the configured project database. Credentials may come from
# PGPASSWORD or ~/.pgpass, never from repository files.
# Host/port are the project's own, never inherited from the shell. If DB_PORT
# was taken by another server, start_database.sh picked a free port and saved
# it in data/port; every script then uses that port.
PORT_FILE="${PROJECT_ROOT}/data/port"
export PGHOST="$DB_HOST"
if [[ "${DB_EXTERNAL:-0}" != "1" && -s "$PORT_FILE" ]]; then
  PGPORT="$(cat "$PORT_FILE")"
else
  PGPORT="$DB_PORT"
fi
export PGPORT
export PGUSER="${PGUSER:-${DB_USER:-$(id -un)}}"
export PGSSLMODE="${PGSSLMODE:-$DB_SSLMODE}"
export PGDATABASE="$DB_NAME"
[[ "$DB_NAME" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || { printf 'Invalid database name\n' >&2; exit 1; }
export OSM_FILE="${PROJECT_ROOT}/${DATASET_PATH}"

# A Docker Compose database is an external PostgreSQL service, so the app
# container only needs client binaries. The native workflow below still
# selects a local PostgreSQL installation that has PostGIS and pg_ctl.
if [[ "${DB_EXTERNAL:-0}" == "1" ]]; then
  PSQL_PATH="${PSQL_BIN:-$(command -v psql || true)}"
  [[ -n "$PSQL_PATH" && -x "$PSQL_PATH" ]] || {
    printf 'PostgreSQL client tools are required when DB_EXTERNAL=1.\n' >&2
    exit 1
  }
  PG_BIN="${PG_BIN:-$(dirname "$PSQL_PATH")}"
else
  # Locate PostgreSQL server binaries that have PostGIS installed. Several
  # PostgreSQL versions can coexist (e.g. Homebrew postgresql@14 on PATH while
  # Homebrew's postgis is built for postgresql@18), so check each candidate.
  pg_has_postgis() {
    [[ -x "$1/pg_ctl" && -x "$1/pg_config" ]] &&
      [[ -f "$("$1/pg_config" --sharedir 2>/dev/null)/extension/postgis.control" ]]
  }
  if [[ -z "${PG_BIN:-}" ]]; then
    PG_CANDIDATES=()
    if command -v brew >/dev/null 2>&1; then
      for v in 18 17 16 15 14; do
        PG_CANDIDATES+=("$(brew --prefix "postgresql@${v}" 2>/dev/null || true)/bin")
      done
    fi
    PG_CANDIDATES+=(/Applications/Postgres.app/Contents/Versions/latest/bin)
    DEBIAN_BINS=(/usr/lib/postgresql/*/bin)
    for ((i = ${#DEBIAN_BINS[@]} - 1; i >= 0; i--)); do PG_CANDIDATES+=("${DEBIAN_BINS[i]}"); done
    PG_CANDIDATES+=("$(pg_config --bindir 2>/dev/null || true)")
    for candidate in "${PG_CANDIDATES[@]}"; do
      if pg_has_postgis "$candidate"; then PG_BIN="$candidate"; break; fi
    done
    if [[ -z "${PG_BIN:-}" ]]; then
      printf 'No PostgreSQL installation with PostGIS was found.\n' >&2
      for candidate in "${PG_CANDIDATES[@]}"; do
        [[ -x "${candidate}/pg_ctl" ]] && printf '  found without PostGIS: %s\n' "$candidate" >&2
      done
      printf 'Install both, e.g. macOS: brew install postgresql@18 postgis\n' >&2
      printf '                   Ubuntu: sudo apt-get install postgresql postgis\n' >&2
      printf 'or set PG_BIN to the bin directory of a PostgreSQL that has PostGIS.\n' >&2
      exit 1
    fi
  fi
  [[ -x "${PG_BIN}/pg_ctl" ]] || { printf 'PG_BIN=%s has no pg_ctl.\n' "$PG_BIN" >&2; exit 1; }
fi
export PG_BIN
export PSQL_BIN="${PSQL_BIN:-${PG_BIN}/psql}"
export CREATEDB_BIN="${CREATEDB_BIN:-${PG_BIN}/createdb}"
export PG_ISREADY_BIN="${PG_ISREADY_BIN:-${PG_BIN}/pg_isready}"
psql_project() {
  "$PSQL_BIN" -X -v ON_ERROR_STOP=1 --dbname="$DB_NAME" "$@"
}
