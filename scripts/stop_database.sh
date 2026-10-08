#!/usr/bin/env bash
# Stop the project-local PostgreSQL cluster (other PostgreSQL services are untouched).
set -euo pipefail
source "$(dirname "$0")/common.sh"
PGDATA="${PROJECT_ROOT}/data/pgdata"
if [[ "$(id -u)" == "0" ]]; then runuser -u postgres -- "${PG_BIN}/pg_ctl" -D "$PGDATA" stop
else "${PG_BIN}/pg_ctl" -D "$PGDATA" stop; fi
