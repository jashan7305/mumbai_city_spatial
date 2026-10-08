#!/usr/bin/env bash
# Installs PostgreSQL + PostGIS, osm2pgsql and osmium-tool.
# Ubuntu/Debian uses apt; macOS uses Homebrew. No Python is needed.
set -euo pipefail
if command -v apt-get >/dev/null 2>&1; then
  SUDO=""; [[ "$(id -u)" == "0" ]] || SUDO="sudo"
  $SUDO apt-get update
  DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y \
    postgresql postgresql-contrib postgis osm2pgsql osmium-tool curl
elif command -v brew >/dev/null 2>&1; then
  HOMEBREW_NO_AUTO_UPDATE=1 brew install postgresql@18 postgis osm2pgsql osmium-tool
else
  printf 'Install PostgreSQL, PostGIS, osm2pgsql and osmium-tool with your package manager.\n' >&2
  exit 1
fi
printf 'PostgreSQL/PostGIS, osm2pgsql and osmium-tool are ready.\n'
