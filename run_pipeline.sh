#!/usr/bin/env bash
# run_pipeline.sh
# Single entry point for the waterway gap analysis pipeline.
#
# Usage:
#   bash run_pipeline.sh --name <slug> --bbox "<S> <W> <N> <E>"
#                        [--threshold N] [--cell-size M] [--skip-download]
#                        [--osm-file <path>]
#
# Example:
#   bash run_pipeline.sh --name siquijor --bbox "9.0 123.4 9.4 123.8"
#   bash run_pipeline.sh --name leyte --bbox "10.0 124.0 11.5 125.5"
#   bash run_pipeline.sh --name catanduanes --bbox "13.4791 123.9807 14.1459 124.4971" \
#     --osm-file /path/to/philippines-latest.osm.pbf

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Defaults ──────────────────────────────────────────────────────────────────
NAME=""
BBOX=""
THRESHOLD=200
CELL_SIZE=200
SKIP_DOWNLOAD=false
OSM_FILE=""

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)       NAME="$2";       shift 2 ;;
        --bbox)       BBOX="$2";       shift 2 ;;
        --threshold)  THRESHOLD="$2";  shift 2 ;;
        --cell-size)  CELL_SIZE="$2";  shift 2 ;;
        --skip-download) SKIP_DOWNLOAD=true; shift ;;
        --osm-file)   OSM_FILE="$2";   shift 2 ;;
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
export NAME
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
    if [[ -n "${OSM_FILE}" ]]; then
        # Pre-create GPKG placeholder so 00_download.sh skips the Overpass OSM step.
        # The conversion block below will overwrite it with the real data.
        mkdir -p "${SCRIPT_DIR}/data/osm"
        touch "${SCRIPT_DIR}/data/osm/waterways_${NAME}.gpkg"
    fi
    bash "${SCRIPT_DIR}/00_download.sh" --name "${NAME}" --bbox "${BBOX}"
else
    echo ""
    echo "==> [1/3] Skipping download (--skip-download)"
fi

# ── OSM file conversion (when --osm-file is provided) ─────────────────────────
if [[ -n "${OSM_FILE}" ]]; then
    echo ""
    echo "==> Converting OSM file to GPKG: ${OSM_FILE}"
    OUT_GPKG="${SCRIPT_DIR}/data/osm/waterways_${NAME}.gpkg"
    mkdir -p "${SCRIPT_DIR}/data/osm"
    if [[ "${OSM_FILE}" == *.pbf ]]; then
        osmium tags-filter "${OSM_FILE}" w/waterway=river,stream,canal,drain,ditch \
            -o /tmp/ww_filtered.osm.pbf --overwrite
        ogr2ogr -f GPKG "${OUT_GPKG}" /tmp/ww_filtered.osm.pbf lines \
            -nln waterways \
            -where "waterway IN ('river','stream','canal','drain','ditch')" \
            -spat "${BBOX_W}" "${BBOX_S}" "${BBOX_E}" "${BBOX_N}" -overwrite
    else
        # .gpkg / .shp / .geojson
        ogr2ogr -f GPKG "${OUT_GPKG}" "${OSM_FILE}" \
            -nln waterways \
            -where "waterway IN ('river','stream','canal','drain','ditch')" \
            -spat "${BBOX_W}" "${BBOX_S}" "${BBOX_E}" "${BBOX_N}" -overwrite
    fi
    echo "==> OSM GPKG written: ${OUT_GPKG}"
fi

# ── OSM named lakes from PBF ──────────────────────────────────────────────────
LAKES_GPKG="${SCRIPT_DIR}/data/osm/lakes_${NAME}.gpkg"
if [[ -n "${OSM_FILE}" && ! -f "${LAKES_GPKG}" ]]; then
    echo ""
    echo "==> Extracting named lakes from OSM file: ${OSM_FILE}"
    if [[ "${OSM_FILE}" == *.pbf ]]; then
        osmium tags-filter "${OSM_FILE}" wr/natural=water \
            -o /tmp/water_filtered.osm.pbf --overwrite
        ogr2ogr -f GPKG "${LAKES_GPKG}" /tmp/water_filtered.osm.pbf multipolygons \
            -nln lakes \
            -where "natural = 'water' AND name IS NOT NULL AND (other_tags LIKE '%\"water\"=>\"lake\"%' OR other_tags LIKE '%\"water\"=>\"reservoir\"%' OR other_tags LIKE '%\"water\"=>\"lagoon\"%' OR other_tags LIKE '%\"wikidata\"%')" \
            -spat "${BBOX_W}" "${BBOX_S}" "${BBOX_E}" "${BBOX_N}" -overwrite 2>/dev/null || true
    fi
    echo "==> OSM lakes GPKG written: ${LAKES_GPKG}"
fi
# Validate: remove empty GPKG (no layers → v.import fails)
if [[ -f "${LAKES_GPKG}" ]]; then
    _lake_feat=$(ogrinfo -al -so "${LAKES_GPKG}" 2>/dev/null | awk '/Feature Count/{sum+=$3} END{print sum+0}')
    if [[ "${_lake_feat}" -eq 0 ]]; then
        echo "==> No named lakes found in bbox; removing empty GPKG"
        rm -f "${LAKES_GPKG}"
        LAKES_GPKG=""
    else
        echo "==> ${_lake_feat} named lake feature(s) found"
    fi
fi
export LAKES_GPKG

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
