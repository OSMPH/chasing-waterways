#!/usr/bin/env bash
# 01_grass_hydro.sh
# Full waterway gap analysis pipeline — all spatial work in GRASS GIS.
# GRASS location: UTM Zone 51N (EPSG:32651) for metric accuracy.
#
# Inputs:
#   data/srtm/*.tif              SRTM 30m tiles (WGS84)
#   data/osm/waterways_*.gpkg    OSM waterway lines
#
# Outputs:
#   output/accum.tif             flow accumulation raster
#   output/streams.gpkg          modeled stream network
#   output/grid.gpkg             100m grid cells (land only)
#   output/modeled_by_cell.csv   modeled stream length per cell
#   output/osm_by_cell.csv       OSM waterway length per cell
#
# Usage:
#   bash 01_grass_hydro.sh [THRESHOLD] [CELL_SIZE_M]
#   Defaults: THRESHOLD=200, CELL_SIZE=100

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SRTM_DIR_OVERRIDE:-${SCRIPT_DIR}/data/srtm}"
MAPSET="PERMANENT"
THRESHOLD="${1:-200}"
CELL_SIZE="${2:-200}"

# Overridable via environment variables (for different areas)
LOCATION="${GRASS_LOCATION:-ph_utm51n}"
GRASS_EPSG="${GRASS_EPSG:-32651}"
OSM_WATERWAYS="${OSM_WATERWAYS_PATH:-${SCRIPT_DIR}/data/osm/waterways_siquijor.gpkg}"
OUTPUT_DIR="${OUTPUT_DIR_OVERRIDE:-${SCRIPT_DIR}/output}"
GRASS_DB="${GRASS_DB_OVERRIDE:-${SCRIPT_DIR}/grass}"
STREAM_MEXP="${STREAM_MEXP:-0}"
USE_CARVE="${USE_CARVE:-false}"
CARVE_WIDTH="${CARVE_WIDTH:-90}"
CARVE_DEPTH="${CARVE_DEPTH:-5.0}"

GRASS_BIN="/Applications/GRASS-8.4.app/Contents/Resources/bin/grass"
if [[ ! -x "${GRASS_BIN}" ]]; then
    GRASS_BIN=$(command -v grass84 || command -v grass82 || command -v grass || true)
fi
if [[ -z "${GRASS_BIN}" || ! -x "${GRASS_BIN}" ]]; then
    echo "ERROR: GRASS GIS not found." >&2; exit 1
fi

echo "==> GRASS:      ${GRASS_BIN}"
echo "==> Threshold:  ${THRESHOLD} cells"
echo "==> Cell size:  ${CELL_SIZE} m"
echo "==> Output:     ${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"

# ── Tile list ─────────────────────────────────────────────────────────────────
if [[ -n "${BBOX_S:-}" && -n "${BBOX_W:-}" && -n "${BBOX_N:-}" && -n "${BBOX_E:-}" ]]; then
    _tile_list=$(python3 - <<PYEOF
import math, os, sys
data_dir = "${DATA_DIR}"
for lat in range(math.floor(${BBOX_S}), math.floor(${BBOX_N}) + 1):
    for lon in range(math.floor(${BBOX_W}), math.floor(${BBOX_E}) + 1):
        ns = "N" if lat >= 0 else "S"
        ew = "E" if lon >= 0 else "W"
        fname = f"{ns}{abs(lat):02d}{ew}{abs(lon):03d}.tif"
        path = os.path.join(data_dir, fname)
        if os.path.exists(path):
            print(path)
        else:
            print(f"WARNING: expected tile not found: {path}", file=sys.stderr)
PYEOF
)
    IFS=$'\n' read -r -d '' -a TILES <<< "${_tile_list}"$'\0' || true
else
    TILES=("${DATA_DIR}"/*.tif)
fi
if [[ ${#TILES[@]} -eq 0 || ! -f "${TILES[0]}" ]]; then
    echo "ERROR: No .tif files in ${DATA_DIR}" >&2; exit 1
fi
TILE_COUNT=${#TILES[@]}
TILE_NAMES_CSV=""
for i in "${!TILES[@]}"; do
    TILE_NAMES_CSV="${TILE_NAMES_CSV:+${TILE_NAMES_CSV},}srtm_tile_${i}"
done
echo "==> ${TILE_COUNT} SRTM tile(s)"

# ── Create UTM location if needed ─────────────────────────────────────────────
if [[ ! -d "${GRASS_DB}/${LOCATION}" ]]; then
    echo "==> Creating GRASS location ${LOCATION} (EPSG:${GRASS_EPSG}) …"
    "${GRASS_BIN}" -c epsg:${GRASS_EPSG} "${GRASS_DB}/${LOCATION}" -e
fi

# ── Convert bbox to UTM for GRASS region clip ─────────────────────────────────
if [[ -n "${BBOX_S:-}" && -n "${BBOX_W:-}" && -n "${BBOX_N:-}" && -n "${BBOX_E:-}" ]]; then
    _utm=$(python3 -c "
from pyproj import Transformer
t = Transformer.from_crs('EPSG:4326', 'EPSG:${GRASS_EPSG}', always_xy=True)
w, s = t.transform(${BBOX_W}, ${BBOX_S})
e, n = t.transform(${BBOX_E}, ${BBOX_N})
print(f'{s-5000:.1f} {w-5000:.1f} {n+5000:.1f} {e+5000:.1f}')
")
    read -r UTM_CLIP_S UTM_CLIP_W UTM_CLIP_N UTM_CLIP_E <<< "${_utm}"
    CLIP_TO_BBOX=true
else
    CLIP_TO_BBOX=false
fi

# ── Pre-compute mexp arg for r.stream.extract ─────────────────────────────────
_MEXP_ARG=""
if [[ "${STREAM_MEXP}" != "0" && -n "${STREAM_MEXP}" ]]; then
    _MEXP_ARG="mexp=${STREAM_MEXP}"
fi

# ── Run GRASS batch ───────────────────────────────────────────────────────────
"${GRASS_BIN}" "${GRASS_DB}/${LOCATION}/${MAPSET}" --exec bash <<GRASS_SCRIPT
set -euo pipefail

# ── 1. Import DEM, then derive region from raster ────────────────────────────
echo "--- Importing SRTM tiles (r.import reprojects to UTM) ---"
IDX=0
for TILE in ${TILES[*]}; do
    r.import input="\${TILE}" output="srtm_tile_\${IDX}" \
        resample=bilinear resolution=value resolution_value=30 extent=input --overwrite
    IDX=\$((IDX + 1))
done

echo "--- Mosaic or rename ---"
if [[ ${TILE_COUNT} -gt 1 ]]; then
    g.region raster="${TILE_NAMES_CSV}" res=30
    r.patch input="${TILE_NAMES_CSV}" output=srtm_utm --overwrite
else
    g.rename raster="${TILE_NAMES_CSV},srtm_utm" --overwrite
fi

echo "--- Setting region from DEM extent ---"
g.region raster=srtm_utm res=30

if [[ "${CLIP_TO_BBOX}" == "true" ]]; then
    echo "--- Clipping region to bbox (+ 5 km buffer) ---"
    g.region n=${UTM_CLIP_N} s=${UTM_CLIP_S} e=${UTM_CLIP_E} w=${UTM_CLIP_W} align=srtm_utm
fi

# ── 2. Land mask: elevation > 0 ───────────────────────────────────────────────
echo "--- Building land mask (elev > 0) ---"
r.mapcalc "land_mask = if(srtm_utm > 0, 1, null())" --overwrite

echo "--- Vectorising land mask → land_boundary ---"
r.to.vect input=land_mask output=land_boundary_raw type=area --overwrite

echo "--- Removing offshore patches (keep areas > 10 km²) ---"
v.clean input=land_boundary_raw output=land_boundary \
    tool=rmarea threshold=10000000 --overwrite

# ── 2b. Subtract named OSM lakes from land mask ───────────────────────────────
LAKES_FILE="${LAKES_GPKG:-${SCRIPT_DIR}/data/osm/lakes_${NAME}.gpkg}"
if [[ -f "\${LAKES_FILE}" ]]; then
    echo "--- Importing OSM named lake polygons ---"
    v.import input="\${LAKES_FILE}" output=lake_polygons_raw snap=0.001 --overwrite

    echo "--- Removing small lakes (< 1 km²) ---"
    v.clean input=lake_polygons_raw output=lake_polygons \
        tool=rmarea threshold=1000000 --overwrite

    echo "--- Rasterising lake polygons ---"
    v.to.rast input=lake_polygons output=lake_rast use=val val=1 --overwrite

    echo "--- Removing lake cells from land mask ---"
    r.mapcalc "land_mask = if(isnull(lake_rast), land_mask, null())" --overwrite
    echo "--- Lake mask applied ---"
else
    echo "--- No lake file at \${LAKES_FILE}; skipping lake mask ---"
fi

# ── 2c. Optional: carve OSM waterways into DEM ───────────────────────────────
if [[ "${USE_CARVE}" == "true" ]]; then
    echo "--- [carve] Importing OSM waterways for stream burning ---"
    v.import input="${OSM_WATERWAYS}" output=osm_waterways snap=0.001 --overwrite

    echo "--- [carve] r.carve: burning OSM channels into DEM ---"
    r.carve raster=srtm_utm vector=osm_waterways \
        output=srtm_carved width=${CARVE_WIDTH} depth=${CARVE_DEPTH} -n --overwrite

    echo "--- [carve] Replacing srtm_utm with carved DEM ---"
    g.rename raster=srtm_carved,srtm_utm --overwrite
fi

# ── 3. Apply mask and run hydrology ───────────────────────────────────────────
echo "--- Applying mask ---"
r.mask -r 2>/dev/null || true
r.mask raster=land_mask --overwrite

echo "--- r.watershed (SFD, threshold=${THRESHOLD}) ---"
r.watershed -s \
    elevation=srtm_utm accumulation=accum drainage=drain \
    threshold=${THRESHOLD} --overwrite

echo "--- r.stream.extract ---"
r.stream.extract \
    elevation=srtm_utm \
    accumulation=accum \
    threshold=${THRESHOLD} \
    ${_MEXP_ARG} \
    stream_raster=streams_rast \
    stream_vector=streams_vect \
    direction=drain \
    --overwrite

echo "--- Installing r.stream.order addon (idempotent) ---"
g.extension extension=r.stream.order

echo "--- r.stream.order (annotates streams_vect with strahler column) ---"
r.stream.order \
    stream_rast=streams_rast \
    direction=drain \
    elevation=srtm_utm \
    accumulation=accum \
    stream_vect=streams_vect \
    strahler=strahler_rast \
    --overwrite

echo "--- Extracting lines only from stream vector ---"
v.extract input=streams_vect output=streams_lines_raw type=line --overwrite

echo "--- Smoothing stream lines (Chaiken) ---"
v.generalize input=streams_lines_raw output=streams_lines \
    method=chaiken threshold=60 --overwrite

echo "--- Removing mask ---"
r.mask -r

# ── 4. Build analysis grid ─────────────────────────────────────────────────────
echo "--- Creating ${CELL_SIZE}m grid ---"
v.mkgrid map=grid_full box=${CELL_SIZE},${CELL_SIZE} --overwrite

echo "--- Selecting land cells ---"
v.select ainput=grid_full binput=land_boundary \
    operator=overlap output=grid_land --overwrite

# ── 5. Import OSM waterways (v.import reprojects to UTM) ─────────────────────
if [[ "${USE_CARVE}" != "true" ]]; then
    echo "--- Importing OSM waterways ---"
    v.import input="${OSM_WATERWAYS}" output=osm_waterways snap=0.001 --overwrite
else
    echo "--- OSM waterways already imported by r.carve; skipping ---"
fi

# ── 6. Overlay modeled streams × grid ─────────────────────────────────────────
echo "--- Overlaying modeled streams with grid ---"
v.overlay ainput=streams_lines binput=grid_land \
    operator=and output=streams_cells --overwrite

db.execute sql="ALTER TABLE streams_cells ADD COLUMN seg_len DOUBLE" 2>/dev/null || true
v.to.db map=streams_cells option=length columns=seg_len --overwrite

echo "--- Aggregating modeled lengths per cell ---"
db.select \
    sql="SELECT b_cat, SUM(seg_len) AS total_m, MAX(a_strahler) AS max_strahler FROM streams_cells GROUP BY b_cat" \
    separator=pipe \
    > "${OUTPUT_DIR}/modeled_by_cell.csv"

# ── 7. Overlay OSM waterways × grid ───────────────────────────────────────────
echo "--- Overlaying OSM waterways with grid ---"
v.overlay ainput=osm_waterways binput=grid_land \
    operator=and output=osm_cells --overwrite

db.execute sql="ALTER TABLE osm_cells ADD COLUMN seg_len DOUBLE" 2>/dev/null || true
v.to.db map=osm_cells option=length columns=seg_len --overwrite

echo "--- Aggregating OSM lengths per cell ---"
db.select \
    sql="SELECT b_cat, SUM(seg_len) AS total_m FROM osm_cells GROUP BY b_cat" \
    separator=pipe \
    > "${OUTPUT_DIR}/osm_by_cell.csv"

# ── 8. Export ─────────────────────────────────────────────────────────────────
echo "--- Exporting accum.tif ---"
r.out.gdal input=accum output="${OUTPUT_DIR}/accum.tif" \
    format=GTiff createopt="COMPRESS=LZW,TILED=YES" --overwrite

echo "--- Exporting streams.gpkg ---"
v.out.ogr input=streams_lines output="${OUTPUT_DIR}/streams.gpkg" \
    format=GPKG --overwrite

echo "--- Exporting grid.gpkg ---"
v.out.ogr input=grid_land output="${OUTPUT_DIR}/grid.gpkg" \
    format=GPKG --overwrite

echo ""
echo "--- GRASS complete ---"
echo "    modeled_by_cell.csv  → \$(wc -l < "${OUTPUT_DIR}/modeled_by_cell.csv") rows"
echo "    osm_by_cell.csv      → \$(wc -l < "${OUTPUT_DIR}/osm_by_cell.csv") rows"
GRASS_SCRIPT

echo ""
echo "==> GRASS done. Next step:"
echo "    python3 02_grid_analysis.py"
