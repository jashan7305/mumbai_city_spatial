#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
export PGDATABASE="$DB_NAME"
psql_project -f "${PROJECT_ROOT}/sql/01_database.sql"
psql_project -1 -f "${PROJECT_ROOT}/sql/02_schema.sql"
printf 'Mumbai places, roads, areas and views created in spatial_data.\n'
