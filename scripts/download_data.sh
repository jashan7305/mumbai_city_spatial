#!/usr/bin/env bash
# Produce data/raw/mumbai.osm.pbf from the official OSM planet on AWS without
# storing the ~95 GB planet: it is streamed once through `osmium extract`.
#   Stage 1: planet stream -> generous buffer box (simple strategy, one pass)
#   Stage 2: buffer file   -> Mumbai box (smart strategy: complete ways and
#            complete multipolygon/boundary relations)
# If a direct Geofabrik/BBBike download is available to you instead, any PBF
# covering MUMBAI_BBOX can be placed at BUFFER_PATH and stage 1 is skipped.
set -euo pipefail
source "$(dirname "$0")/common.sh"

BUFFER_FILE="${PROJECT_ROOT}/${BUFFER_PATH}"
STREAM_JOBS="${STREAM_JOBS:-6}"          # parallel HTTP range requests
CHUNK_BYTES=$((128 * 1024 * 1024))
MAX_AHEAD=24                             # at most ~3 GB of chunks on disk
mkdir -p "$(dirname "$OSM_FILE")"

# Write the planet to stdout in order. Chunks are fetched in parallel with
# HTTP range requests (each retried independently) and deleted once consumed.
stream_planet() {
  local size n tmp i
  size="$(curl -fsSI "$PLANET_URL" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}')"
  n=$(( (size + CHUNK_BYTES - 1) / CHUNK_BYTES ))
  tmp="$(mktemp -d "${PROJECT_ROOT}/data/raw/stream.XXXX")"
  echo 0 > "${tmp}/consumed"
  printf 'Planet size %s bytes in %s chunks, %s parallel requests\n' "$size" "$n" "$STREAM_JOBS" >&2
  seq 0 $((n - 1)) | xargs -P "$STREAM_JOBS" -I{} bash -c '
      i={}; while (( i - $(cat "$1/consumed") >= $2 )); do sleep 1; done
      start=$(( i * $3 )); end=$(( start + $3 - 1 ))
      curl -fsS --retry 8 --retry-all-errors -r "${start}-${end}" "$4" -o "$1/${i}.part" \
        && mv "$1/${i}.part" "$1/${i}" || { touch "$1/failed"; exit 255; }
    ' _ "$tmp" "$MAX_AHEAD" "$CHUNK_BYTES" "$PLANET_URL" &
  for ((i = 0; i < n; i++)); do
    until [[ -f "${tmp}/${i}" ]]; do
      [[ -f "${tmp}/failed" ]] && { printf 'Chunk download failed\n' >&2; return 1; }
      sleep 0.2
    done
    cat "${tmp}/${i}"; rm -f "${tmp}/${i}"
    echo $((i + 1)) > "${tmp}/consumed.new" && mv "${tmp}/consumed.new" "${tmp}/consumed"
    (( i % 50 == 0 )) && printf 'streamed chunk %s/%s\n' "$i" "$n" >&2
  done
  wait; rm -rf "$tmp"
}

if [[ -s "$OSM_FILE" && "${1:-}" != "--replace" ]]; then
  printf 'Mumbai extract already present: %s (%s bytes; --replace rebuilds it)\n' \
    "${OSM_FILE#"${PROJECT_ROOT}/"}" "$(wc -c < "$OSM_FILE" | tr -d ' ')"
  exit 0
fi
command -v osmium >/dev/null || { printf 'osmium-tool is required. Run scripts/install_dependencies.sh\n' >&2; exit 1; }

if [[ ! -s "$BUFFER_FILE" || "${1:-}" == "--replace" ]]; then
  printf 'Published planet MD5: %s\n' "$(curl -fsS "$PLANET_MD5_URL")"
  printf 'Streaming %s through osmium (buffer box %s). This reads the whole planet once.\n' \
    "$PLANET_URL" "$BUFFER_BBOX"
  stream_planet \
    | osmium extract --bbox "$BUFFER_BBOX" --strategy simple -F pbf - \
        --output "${BUFFER_FILE}.part" --output-format pbf --overwrite
  mv "${BUFFER_FILE}.part" "$BUFFER_FILE"
fi

printf 'Clipping Mumbai box %s with complete ways/relations\n' "$MUMBAI_BBOX"
osmium extract --bbox "$MUMBAI_BBOX" --strategy smart \
  --option types=multipolygon,boundary \
  --set-bounds "$BUFFER_FILE" --output "$OSM_FILE" --overwrite
printf 'Mumbai extract SHA-256: %s\n' "$( (sha256sum "$OSM_FILE" 2>/dev/null || shasum -a 256 "$OSM_FILE") | cut -d ' ' -f 1)"
osmium fileinfo -e "$OSM_FILE" | sed -n '1,40p'
