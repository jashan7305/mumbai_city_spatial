#!/usr/bin/env bash
# Stop and delete the project-local PostgreSQL cluster (data/pgdata) so that
# ./scripts/build_all.sh can recreate it, e.g. after it was created with a
# PostgreSQL version that has no PostGIS. Only data/pgdata and
# data/postgresql.log are removed: the OSM extract, SQL files, queries and
# results/ are kept, and no other PostgreSQL server or database is touched.
#   ./scripts/reset_database.sh          (asks for confirmation)
#   ./scripts/reset_database.sh --yes
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PGDATA="${PROJECT_ROOT}/data/pgdata"

if [[ "${DB_EXTERNAL:-0}" == "1" ]]; then
  printf 'The database is managed by the external PostgreSQL service; use docker compose down -v to reset it.\n'
  exit 0
fi

if [[ ! -d "$PGDATA" ]]; then
  printf 'Nothing to reset: %s does not exist.\n' "$PGDATA"
  exit 0
fi
OLD_VERSION="$(cat "${PGDATA}/PG_VERSION" 2>/dev/null || echo unknown)"

if [[ "${1:-}" != "--yes" ]]; then
  printf 'This deletes the project database cluster %s (PostgreSQL %s).\n' "$PGDATA" "$OLD_VERSION"
  printf 'It is rebuilt from data/raw/mumbai.osm.pbf by ./scripts/build_all.sh.\n'
  read -r -p 'Type yes to continue: ' answer
  [[ "$answer" == "yes" ]] || { printf 'Cancelled.\n'; exit 1; }
fi

as_server_user() {
  if [[ "$(id -u)" == "0" ]]; then runuser -u postgres -- "$@"; else "$@"; fi
}

# Stop the cluster if it is running, using pg_ctl of the version that created it.
if [[ -f "${PGDATA}/postmaster.pid" ]]; then
  STOPPED=""
  for bin in "$(brew --prefix "postgresql@${OLD_VERSION}" 2>/dev/null || true)/bin" \
             "/usr/lib/postgresql/${OLD_VERSION}/bin" \
             "/Applications/Postgres.app/Contents/Versions/${OLD_VERSION}/bin" \
             "$(pg_config --bindir 2>/dev/null || true)"; do
    if [[ -x "${bin}/pg_ctl" ]] && as_server_user "${bin}/pg_ctl" -D "$PGDATA" -m fast stop >/dev/null 2>&1; then
      STOPPED=yes; break
    fi
  done
  if [[ -z "$STOPPED" ]]; then
    # Fall back to the postmaster PID recorded in the data directory.
    PID="$(head -n 1 "${PGDATA}/postmaster.pid")"
    if [[ "$PID" =~ ^[0-9]+$ ]] && kill -0 "$PID" 2>/dev/null; then
      kill -TERM "$PID"
      for _ in $(seq 1 30); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
      STOPPED=yes
    fi
  fi
  if [[ -n "$STOPPED" ]]; then
    printf 'Stopped the project PostgreSQL %s cluster.\n' "$OLD_VERSION"
  fi
fi

rm -rf "$PGDATA" "${PROJECT_ROOT}/data/postgresql.log" "${PROJECT_ROOT}/data/port"
printf 'Removed %s. Now run ./scripts/build_all.sh\n' "$PGDATA"
