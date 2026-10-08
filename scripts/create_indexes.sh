#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
export PGDATABASE="$DB_NAME"
psql_project -f "${PROJECT_ROOT}/sql/03_indexes.sql"
printf 'Mumbai GiST and B-tree indexes created and analyzed.\n'
