#!/usr/bin/env bash
# 00_download.sh
# Downloads input data for any area by bounding box.
#
# Usage:
#   bash 00_download.sh --name <slug> --bbox "<S> <W> <N> <E>"
#
# Downloads:
#   data/srtm/<tile>.tif            Copernicus DEM 30m tiles (shared cache)
#   data/osm/waterways_<name>.gpkg  OSM waterway lines
#   data/boundary/<name>.geojson    Admin boundary (best-effort)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Arg parsing ───────────────────────────────────────────────────────────────
NAME=""
BBOX=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name) NAME="$2"; shift 2 ;;
        --bbox) BBOX="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "${NAME}" || -z "${BBOX}" ]]; then
    echo "Usage: bash 00_download.sh --name <slug> --bbox \"<S> <W> <N> <E>\"" >&2
    exit 1
fi

read -r BBOX_S BBOX_W BBOX_N BBOX_E <<< "${BBOX}"

SRTM_DIR="${SCRIPT_DIR}/data/srtm"
BOUNDARY_DIR="${SCRIPT_DIR}/data/boundary"
OSM_DIR="${SCRIPT_DIR}/data/osm"

mkdir -p "${SRTM_DIR}" "${BOUNDARY_DIR}" "${OSM_DIR}"

# ── 1. Copernicus DEM 30m tiles ───────────────────────────────────────────────
# One tile per integer-degree cell; compute all tiles that intersect the bbox.
echo "==> Computing required Copernicus DEM tiles …"

python3 - <<PYEOF
import math, subprocess, os, sys

bbox_s, bbox_w, bbox_n, bbox_e = $BBOX_S, $BBOX_W, $BBOX_N, $BBOX_E

lat_min = math.floor(bbox_s)
lat_max = math.floor(bbox_n)
lon_min = math.floor(bbox_w)
lon_max = math.floor(bbox_e)

tiles = []
for lat in range(lat_min, lat_max + 1):
    for lon in range(lon_min, lon_max + 1):
        ns = "N" if lat >= 0 else "S"
        ew = "E" if lon >= 0 else "W"
        lat_abs = abs(lat)
        lon_abs = abs(lon)
        tile_id = f"{ns}{lat_abs:02d}{ew}{lon_abs:03d}"
        folder = f"Copernicus_DSM_COG_10_{ns}{lat_abs:02d}_00_{ew}{lon_abs:03d}_00_DEM"
        url = f"https://copernicus-dem-30m.s3.amazonaws.com/{folder}/{folder}.tif"
        out_path = os.path.join("${SRTM_DIR}", f"{tile_id}.tif")
        tiles.append((tile_id, url, out_path))

print(f"Tiles needed: {[t[0] for t in tiles]}")

for tile_id, url, out_path in tiles:
    if os.path.exists(out_path):
        print(f"  already exists: {out_path}")
        continue
    print(f"  downloading {tile_id} …")
    result = subprocess.run(
        ["curl", "-L", "--progress-bar", "-o", out_path, url],
        check=False
    )
    if result.returncode != 0:
        print(f"ERROR: Failed to download {tile_id}", file=sys.stderr)
        sys.exit(1)
    print(f"    saved → {out_path}")
PYEOF

echo "==> Tile info:"
for f in "${SRTM_DIR}"/*.tif; do
    [[ -f "$f" ]] && gdalinfo "$f" | grep -E "Size is" | head -1 && echo "    $f" || true
done

# ── 2. Admin boundary from Overpass (best-effort) ────────────────────────────
BOUNDARY_OUT="${BOUNDARY_DIR}/${NAME}.geojson"

if [[ -f "${BOUNDARY_OUT}" ]]; then
    echo "==> Boundary already exists: ${BOUNDARY_OUT}"
else
    echo "==> Downloading admin boundary for '${NAME}' from Overpass …"
    OVERPASS_QUERY="[out:json][timeout:60];
relation[\"name\"~\"${NAME}\",i][\"admin_level\"];
out geom;"

    RESPONSE=$(curl -s --data-urlencode "data=${OVERPASS_QUERY}" \
        "https://overpass-api.de/api/interpreter")

    python3 - <<PYEOF
import json, sys

data = json.loads('''${RESPONSE}''')
elements = data.get("elements", [])

if not elements:
    print(f"WARNING: No boundary found for '${NAME}' — continuing without it", file=sys.stderr)
    # Write empty FeatureCollection so we don't re-query
    fc = {"type": "FeatureCollection", "features": []}
    with open("${BOUNDARY_OUT}", "w") as f:
        json.dump(fc, f)
    sys.exit(0)

features = []
for el in elements:
    if el["type"] != "relation":
        continue
    rings = []
    for member in el.get("members", []):
        if member.get("role") in ("outer", "") and "geometry" in member:
            ring = [[c["lon"], c["lat"]] for c in member["geometry"]]
            if ring[0] != ring[-1]:
                ring.append(ring[0])
            rings.append(ring)
    if rings:
        geom = {"type": "Polygon", "coordinates": [rings[0]]} if len(rings) == 1 \
               else {"type": "MultiPolygon", "coordinates": [[r] for r in rings]}
        features.append({
            "type": "Feature",
            "geometry": geom,
            "properties": {"name": el.get("tags", {}).get("name", "${NAME}"),
                           "osm_id": el["id"]}
        })

fc = {"type": "FeatureCollection", "features": features}
with open("${BOUNDARY_OUT}", "w") as f:
    json.dump(fc, f)
print(f"Boundary written: {len(features)} feature(s) → ${BOUNDARY_OUT}")
PYEOF
fi

# ── 3. OSM waterways from Overpass ───────────────────────────────────────────
OSM_GEOJSON="${OSM_DIR}/waterways_${NAME}.geojson"
OSM_GPKG="${OSM_DIR}/waterways_${NAME}.gpkg"

if [[ -f "${OSM_GPKG}" ]]; then
    echo "==> OSM waterways GPKG already exists: ${OSM_GPKG}"
else
    echo "==> Downloading OSM waterways for bbox ${BBOX_S},${BBOX_W},${BBOX_N},${BBOX_E} …"

    WATERWAY_QUERY="[out:json][timeout:90];
(
  way[\"waterway\"~\"^(river|stream|canal|drain|ditch)\$\"]
     (${BBOX_S},${BBOX_W},${BBOX_N},${BBOX_E});
);
out geom;"

    echo "    (POST request to overpass-api.de …)"
    HTTP_CODE=$(curl -s -w "%{http_code}" \
        --data-urlencode "data=${WATERWAY_QUERY}" \
        "https://overpass-api.de/api/interpreter" \
        -o "${OSM_DIR}/waterways_raw.json")

    if [[ "${HTTP_CODE}" != "200" ]]; then
        echo "ERROR: Overpass returned HTTP ${HTTP_CODE}" >&2
        cat "${OSM_DIR}/waterways_raw.json" >&2
        exit 1
    fi

    FILE_SIZE=$(wc -c < "${OSM_DIR}/waterways_raw.json")
    if [[ "${FILE_SIZE}" -lt 10 ]]; then
        echo "ERROR: Overpass response is empty (${FILE_SIZE} bytes)." >&2
        exit 1
    fi
    echo "    response: ${FILE_SIZE} bytes"

    echo "==> Converting to GeoJSON …"
    python3 - <<PYEOF
import json

with open("${OSM_DIR}/waterways_raw.json") as f:
    data = json.load(f)

features = []
for el in data.get("elements", []):
    if el["type"] != "way" or "geometry" not in el:
        continue
    coords = [[c["lon"], c["lat"]] for c in el["geometry"]]
    if len(coords) < 2:
        continue
    tags = el.get("tags", {})
    features.append({
        "type": "Feature",
        "geometry": {"type": "LineString", "coordinates": coords},
        "properties": {
            "osm_id": el["id"],
            "waterway": tags.get("waterway", ""),
            "name": tags.get("name", ""),
        }
    })

fc = {"type": "FeatureCollection", "features": features}
with open("${OSM_GEOJSON}", "w") as f:
    json.dump(fc, f)
print(f"OSM waterways: {len(features)} features → ${OSM_GEOJSON}")
PYEOF

    echo "==> Converting GeoJSON → GPKG …"
    ogr2ogr -f GPKG "${OSM_GPKG}" "${OSM_GEOJSON}" -nln waterways
    echo "    saved → ${OSM_GPKG}"
fi

# ── 4. OSM named water bodies (lakes, reservoirs) ────────────────────────────
LAKES_GPKG="${OSM_DIR}/lakes_${NAME}.gpkg"
if [[ -f "${LAKES_GPKG}" ]]; then
    echo "==> OSM lakes GPKG already exists: ${LAKES_GPKG}"
elif [[ -n "${OSM_FILE:-}" ]]; then
    echo "==> Skipping Overpass lakes download (--osm-file provided; extraction runs in run_pipeline.sh)"
else
    echo "==> Downloading OSM named water bodies for bbox ${BBOX_S},${BBOX_W},${BBOX_N},${BBOX_E} …"
    LAKES_QUERY="[out:geojson][timeout:90];
(
  way[\"natural\"=\"water\"][\"water\"~\"^(lake|reservoir|lagoon)\$\"][\"name\"]
     (${BBOX_S},${BBOX_W},${BBOX_N},${BBOX_E});
  relation[\"natural\"=\"water\"][\"water\"~\"^(lake|reservoir|lagoon)\$\"][\"name\"]
     (${BBOX_S},${BBOX_W},${BBOX_N},${BBOX_E});
);
out geom;"
    TMP_LAKES=$(mktemp /tmp/lakes_XXXXXX.geojson)
    curl -s --retry 3 -d "${LAKES_QUERY}" "https://overpass-api.de/api/interpreter" \
        > "${TMP_LAKES}"
    ogr2ogr -f GPKG "${LAKES_GPKG}" "${TMP_LAKES}" \
        -nln lakes --overwrite 2>/dev/null || true
    rm -f "${TMP_LAKES}"
    echo "==> OSM lakes GPKG written: ${LAKES_GPKG}"
fi

echo ""
echo "==> Download complete."
ls -lh "${SRTM_DIR}"/*.tif 2>/dev/null || true
ls -lh "${BOUNDARY_DIR}/${NAME}.geojson" 2>/dev/null || true
ls -lh "${OSM_GPKG}" 2>/dev/null || true
echo ""
echo "Next step: bash 01_grass_hydro.sh"
