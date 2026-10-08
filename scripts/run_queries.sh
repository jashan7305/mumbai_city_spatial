#!/usr/bin/env bash
# Run every query file and save its real output to results/<name>.txt
set -euo pipefail
source "$(dirname "$0")/common.sh"
OUTPUT_DIR="${PROJECT_ROOT}/results"
mkdir -p "$OUTPUT_DIR"
for query in "${PROJECT_ROOT}"/queries/[0-9][0-9]_*.sql; do
  name="$(basename "${query%.sql}")"
  printf 'Running %s\n' "$name"
  psql_project -P pager=off -f "$query" > "${OUTPUT_DIR}/${name}.txt" 2>&1
done
printf 'Actual query output saved under %s\n' "$OUTPUT_DIR"
