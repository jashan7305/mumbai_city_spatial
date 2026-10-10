#!/usr/bin/env bash
set -euo pipefail

# run_web.sh contains the project's normal idempotent database build logic.
# DB_EXTERNAL makes its database helper wait for the Compose PostGIS service
# instead of starting a second PostgreSQL cluster inside this container.
exec /app/scripts/run_web.sh
