#!/usr/bin/env bash
# psql connected to the project database, e.g.:
#   ./scripts/psql.sh                                  (interactive)
#   ./scripts/psql.sh -f queries/03_distance_queries.sql
set -euo pipefail
source "$(dirname "$0")/common.sh"
psql_project "$@"
