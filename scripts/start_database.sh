#!/usr/bin/env bash
# Start the isolated, project-local PostgreSQL cluster (data/pgdata). Any other
# PostgreSQL server or database on the machine is left untouched.
#
# Handled automatically:
#  - data/pgdata missing, half-created, or created by another PostgreSQL
#    version (e.g. one without PostGIS): it only holds rebuildable project
#    data, so it is recreated (build_all.sh then re-imports the extract);
#  - the configured port is used by another server: the next free port is
#    chosen and remembered in data/port.
set -euo pipefail
source "$(dirname "$0")/common.sh"

PG_CTL="${PG_BIN}/pg_ctl"
INITDB="${PG_BIN}/initdb"
PGDATA="${PROJECT_ROOT}/data/pgdata"
LOGFILE="${PROJECT_ROOT}/data/postgresql.log"
mkdir -p "${PROJECT_ROOT}/data"

# PostgreSQL refuses to run as root; in that case run the server as `postgres`.
as_server_user() {
  if [[ "$(id -u)" == "0" ]]; then runuser -u postgres -- "$@"; else "$@"; fi
}

PG_MAJOR="$("${PG_BIN}/pg_config" --version | sed -E 's/^PostgreSQL ([0-9]+).*/\1/')"

# 1. Recreate data/pgdata if it does not belong to this PostgreSQL version.
if [[ -d "$PGDATA" ]]; then
  OLD_VERSION="$(cat "${PGDATA}/PG_VERSION" 2>/dev/null || true)"
  if [[ -z "$OLD_VERSION" ]]; then
    printf 'data/pgdata is incomplete; recreating it.\n'
    "$(dirname "$0")/reset_database.sh" --yes >/dev/null
  elif [[ "$OLD_VERSION" != "$PG_MAJOR" ]]; then
    printf 'data/pgdata was created by PostgreSQL %s; recreating it for PostgreSQL %s\n' "$OLD_VERSION" "$PG_MAJOR"
    printf '(PostGIS is installed for %s). It only holds rebuildable project data.\n' "$PG_MAJOR"
    "$(dirname "$0")/reset_database.sh" --yes >/dev/null
  fi
fi

if [[ ! -f "${PGDATA}/PG_VERSION" ]]; then
  mkdir -p "$PGDATA"
  touch "$LOGFILE"
  if [[ "$(id -u)" == "0" ]]; then chown postgres: "$PGDATA" "$LOGFILE"; fi
  chmod 700 "$PGDATA"
  # The superuser is named after PGUSER so local trust connections just work.
  as_server_user "$INITDB" -D "$PGDATA" -U "$PGUSER" --auth=trust --no-locale --encoding=UTF8 >/dev/null
  printf 'Created a new project PostgreSQL %s cluster in data/pgdata.\n' "$PG_MAJOR"
fi

port_in_use() {
  "$PG_ISREADY_BIN" -h "$PGHOST" -p "$1" >/dev/null 2>&1 && return 0
  command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1 && return 0
  return 1
}

describe_server() {  # version and data directory of a foreign server, if readable
  local info
  info="$("$PSQL_BIN" -X -h "$PGHOST" -p "$1" -d postgres -Atc \
          "SELECT current_setting('server_version') || ', data directory ' || current_setting('data_directory')" \
          2>/dev/null || true)"
  [[ -n "$info" ]] && printf ' (PostgreSQL %s)' "$info"
  return 0
}

if as_server_user "$PG_CTL" -D "$PGDATA" status >/dev/null 2>&1; then
  # Already running: use the port it is actually listening on.
  RUNNING_PORT="$(sed -n '4p' "${PGDATA}/postmaster.pid" 2>/dev/null || true)"
  if [[ "$RUNNING_PORT" =~ ^[0-9]+$ ]]; then PGPORT="$RUNNING_PORT"; fi
else
  # 2. Never use another server: if our port is taken, move to a free one.
  if port_in_use "$PGPORT"; then
    TAKEN="$PGPORT"
    printf 'Port %s is used by another server%s.\n' "$TAKEN" "$(describe_server "$TAKEN")"
    for candidate in $(seq $((DB_PORT + 1)) $((DB_PORT + 30))); do
      if ! port_in_use "$candidate"; then PGPORT="$candidate"; break; fi
    done
    if [[ "$PGPORT" == "$TAKEN" ]]; then
      printf 'No free port found between %s and %s.\n' $((DB_PORT + 1)) $((DB_PORT + 30)) >&2
      exit 1
    fi
    printf 'This project will use port %s instead (saved in data/port).\n' "$PGPORT"
  fi

  start_server() {
    as_server_user "$PG_CTL" -D "$PGDATA" -l "$LOGFILE" -w -t 60 \
      -o "-p $PGPORT -h $PGHOST -k /tmp -c shared_buffers=256MB -c work_mem=64MB -c maintenance_work_mem=512MB" \
      start >/dev/null
  }
  if ! start_server; then
    if tail -n 20 "$LOGFILE" 2>/dev/null | grep -q "incompatible with server"; then
      # Data files from another PostgreSQL version: recreate and retry once.
      printf 'data/pgdata is incompatible with PostgreSQL %s; recreating it.\n' "$PG_MAJOR"
      "$(dirname "$0")/reset_database.sh" --yes >/dev/null
      mkdir -p "$PGDATA"; touch "$LOGFILE"
      if [[ "$(id -u)" == "0" ]]; then chown postgres: "$PGDATA" "$LOGFILE"; fi
      chmod 700 "$PGDATA"
      as_server_user "$INITDB" -D "$PGDATA" -U "$PGUSER" --auth=trust --no-locale --encoding=UTF8 >/dev/null
      start_server || { printf 'Could not start PostgreSQL; last lines of %s:\n' "$LOGFILE" >&2; tail -n 15 "$LOGFILE" >&2; exit 1; }
    else
      printf 'The project PostgreSQL server could not start. Last lines of %s:\n' "$LOGFILE" >&2
      tail -n 15 "$LOGFILE" >&2
      exit 1
    fi
  fi
fi

# Remember the port only when it differs from the configured one.
if [[ "$PGPORT" == "$DB_PORT" ]]; then rm -f "$PORT_FILE"; else echo "$PGPORT" > "$PORT_FILE"; fi

for _ in $(seq 1 30); do
  if "$PG_ISREADY_BIN" -h "$PGHOST" -p "$PGPORT" >/dev/null 2>&1; then
    printf 'Project PostgreSQL %s cluster is accepting connections on %s:%s.\n' "$PG_MAJOR" "$PGHOST" "$PGPORT"
    exit 0
  fi
  sleep 1
done
printf 'Project PostgreSQL cluster did not become ready; inspect %s\n' "$LOGFILE" >&2
exit 1
