#!/usr/bin/env bash
# run_pipeline.sh
# Single entry point for the waterway gap analysis pipeline.
#
# Usage:
#   bash run_pipeline.sh --name <slug> --bbox "<S> <W> <N> <E>"
#                        [--threshold N] [--cell-size M] [--skip-download]
#
# Example:
#   bash run_pipeline.sh --name siquijor --bbox "9.0 123.4 9.4 123.8"
#   bash run_pipeline.sh --name leyte --bbox "10.0 124.0 11.5 125.5"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Defaults ──────────────────────────────────────────────────────────────────
NAME=""
BBOX=""
THRESHOLD=200
CELL_SIZE=200
SKIP_DOWNLOAD=false

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)       NAME="$2";       shift 2 ;;
        --bbox)       BBOX="$2";       shift 2 ;;
        --threshold)  THRESHOLD="$2";  shift 2 ;;
        --cell-size)  CELL_SIZE="$2";  shift 2 ;;
        --skip-download) SKIP_DOWNLOAD=true; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "${NAME}" || -z "${BBOX}" ]]; then
    echo "Usage: bash run_pipeline.sh --name <slug> --bbox \"<S> <W> <N> <E>\"" >&2
    exit 1
fi

# ── Parse bbox ────────────────────────────────────────────────────────────────
read -r BBOX_S BBOX_W BBOX_N BBOX_E <<< "${BBOX}"

# ── Compute UTM zone from center longitude ────────────────────────────────────
read -r UTM_ZONE GRASS_EPSG <<< "$(python3 - <<PYEOF
import math
center_lon = ($BBOX_W + $BBOX_E) / 2
zone = int(math.floor((center_lon + 180) / 6) + 1)
epsg = 32600 + zone  # N hemisphere
print(zone, epsg)
PYEOF
)"

echo "==> Name:       ${NAME}"
echo "==> BBox:       S=${BBOX_S} W=${BBOX_W} N=${BBOX_N} E=${BBOX_E}"
echo "==> UTM zone:   ${UTM_ZONE}  (EPSG:${GRASS_EPSG})"
echo "==> Threshold:  ${THRESHOLD} cells"
echo "==> Cell size:  ${CELL_SIZE} m"

# ── Set env vars for downstream scripts ───────────────────────────────────────
export GRASS_LOCATION="ph_utm${UTM_ZONE}n"
export GRASS_EPSG="${GRASS_EPSG}"
export SRTM_DIR_OVERRIDE="${SCRIPT_DIR}/data/srtm"
export OSM_WATERWAYS_PATH="${SCRIPT_DIR}/data/osm/waterways_${NAME}.gpkg"
export OUTPUT_DIR_OVERRIDE="${SCRIPT_DIR}/output/${NAME}"
export BBOX_S BBOX_W BBOX_N BBOX_E

mkdir -p "${OUTPUT_DIR_OVERRIDE}"

# ── Step 1: Download ──────────────────────────────────────────────────────────
if [[ "${SKIP_DOWNLOAD}" == "false" ]]; then
    echo ""
    echo "==> [1/3] Downloading data …"
    bash "${SCRIPT_DIR}/00_download.sh" --name "${NAME}" --bbox "${BBOX}"
else
    echo ""
    echo "==> [1/3] Skipping download (--skip-download)"
fi

# ── Step 2: GRASS hydrology ───────────────────────────────────────────────────
echo ""
echo "==> [2/3] Running GRASS hydrology pipeline …"
bash "${SCRIPT_DIR}/01_grass_hydro.sh" "${THRESHOLD}" "${CELL_SIZE}"

# ── Step 3: Python gap analysis ───────────────────────────────────────────────
echo ""
echo "==> [3/3] Computing gap scores …"
python3 "${SCRIPT_DIR}/02_grid_analysis.py" --output-dir "${OUTPUT_DIR_OVERRIDE}"

echo ""
echo "==> Pipeline complete."
echo "    Output: ${OUTPUT_DIR_OVERRIDE}/gap_analysis.geojson"
