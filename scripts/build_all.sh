#!/usr/bin/env bash
# Full, idempotent build: database -> Mumbai extract -> import -> schema -> indexes -> query outputs.
set -euo pipefail
DIR="$(dirname "$0")"
"$DIR/setup_database.sh"
"$DIR/download_data.sh"
"$DIR/import_osm.sh"
"$DIR/create_schema.sh"
"$DIR/create_indexes.sh"
"$DIR/run_queries.sh"
