#!/usr/bin/env bash
# export_tiles.sh
# Merge completed run stream vectors, generate MBTiles, and optionally upload
# to Mapbox via the Tilesets CLI.
#
# Usage:
#   bash export_tiles.sh [--upload] [--tileset <username.tileset-id>]
#                        [--registry areas_registry.json] [--auto]
#
# Environment:
#   MAPBOX_ACCESS_TOKEN  — required when --upload is passed
#   MAPBOX_USERNAME      — required when --upload is passed (for source upload)
#
# Examples:
#   bash export_tiles.sh
#   MAPBOX_ACCESS_TOKEN=pk.xxx MAPBOX_USERNAME=myuser \
#     bash export_tiles.sh --upload --tileset myuser.streams-ph

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Defaults ──────────────────────────────────────────────────────────────────
REGISTRY="${SCRIPT_DIR}/areas_registry.json"
UPLOAD=false
TILESET_ID=""
AUTO_DISCOVER=false
OUTPUT_TILES="${SCRIPT_DIR}/output/tiles"
COMBINED="/tmp/streams_combined.geojson"
AREAS_TSV=$(mktemp /tmp/areas_XXXXXX)  # name\tdir\tW\tS\tE\tN

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --upload)    UPLOAD=true;          shift ;;
        --tileset)   TILESET_ID="$2";      shift 2 ;;
        --registry)  REGISTRY="$2";        shift 2 ;;
        --auto)      AUTO_DISCOVER=true;   shift ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ "${UPLOAD}" == "true" ]]; then
    if [[ -z "${MAPBOX_ACCESS_TOKEN:-}" ]]; then
        echo "Error: MAPBOX_ACCESS_TOKEN env var required for --upload" >&2
        exit 1
    fi
    if [[ -z "${MAPBOX_USERNAME:-}" ]]; then
        echo "Error: MAPBOX_USERNAME env var required for --upload" >&2
        exit 1
    fi
    if [[ -z "${TILESET_ID}" ]]; then
        echo "Error: --tileset <username.tileset-id> required for --upload" >&2
        exit 1
    fi
fi

# ── Check dependencies ────────────────────────────────────────────────────────
for cmd in ogr2ogr tippecanoe python3; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: '$cmd' not found in PATH" >&2
        exit 1
    fi
done

if [[ "${UPLOAD}" == "true" ]] && ! command -v curl &>/dev/null; then
    echo "Error: 'curl' not found in PATH" >&2
    exit 1
fi

# ── Build area list → AREAS_TSV ───────────────────────────────────────────────
if [[ -f "${REGISTRY}" ]]; then
    python3 - <<PYEOF >> "${AREAS_TSV}"
import json
with open('${REGISTRY}') as f:
    reg = json.load(f)
for name, v in reg.items():
    b = v['bbox']  # [W, S, E, N]
    print(f"{name}\t{v['dir']}\t{b[0]}\t{b[1]}\t{b[2]}\t{b[3]}")
PYEOF
else
    echo "Warning: registry not found at ${REGISTRY}" >&2
fi

if [[ "${AUTO_DISCOVER}" == "true" ]]; then
    for meta in "${SCRIPT_DIR}/output/"*/metadata.json; do
        [[ -f "$meta" ]] || continue
        dir="$(basename "$(dirname "$meta")")"
        python3 - <<PYEOF >> "${AREAS_TSV}"
import json
with open('${meta}') as f:
    m = json.load(f)
name = m['name']
b = m['bbox']  # [W, S, E, N]
# Only add if not already in TSV (dedup by name handled below)
print(f"{name}\t${dir}\t{b[0]}\t{b[1]}\t{b[2]}\t{b[3]}")
PYEOF
    done
fi

# Dedup by name — keep first occurrence (registry wins over auto-discovered)
DEDUPED=$(mktemp /tmp/areas_dedup_XXXXXX.tsv)
awk -F'\t' '!seen[$1]++' "${AREAS_TSV}" > "${DEDUPED}"
mv "${DEDUPED}" "${AREAS_TSV}"

if [[ ! -s "${AREAS_TSV}" ]]; then
    echo "Error: no areas found in registry or via --auto" >&2
    exit 1
fi

mkdir -p "${OUTPUT_TILES}"
rm -f /tmp/streams_*.geojson "${COMBINED}"

# ── Step 1 — Per-area: reproject + clip + tag ─────────────────────────────────
echo ""
echo "==> Step 1/3 — Exporting per-area stream vectors"

EXPORTED_LIST=$(mktemp /tmp/exported_XXXXXX)

while IFS=$'\t' read -r name dir w s e n; do
    gpkg="${SCRIPT_DIR}/output/${dir}/streams_wgs84.gpkg"
    out="/tmp/streams_${name}.geojson"

    if [[ ! -f "${gpkg}" ]]; then
        echo "    [skip] ${name}: streams_wgs84.gpkg not found at output/${dir}/"
        continue
    fi

    echo "    [clip] ${name} (bbox: W=${w} S=${s} E=${e} N=${n})"
    # To include more attributes, add columns to the SELECT (available: length, gradient, horton, shreve, …)
    SQL="SELECT geom, strahler, '${name}' AS source_area FROM streams_lines"
    # 0.02° buffer keeps full stream geometry for grid cells at area boundaries
    ogr2ogr \
        -f GeoJSON \
        -spat "$(echo "${w} - 0.02" | bc)" "$(echo "${s} - 0.02" | bc)" \
              "$(echo "${e} + 0.02" | bc)" "$(echo "${n} + 0.02" | bc)" \
        -sql "${SQL}" \
        "${out}" \
        "${gpkg}" 2>/dev/null

    feat_count=$(python3 -c "
import json
with open('${out}') as f:
    d = json.load(f)
print(len(d.get('features', [])))
" 2>/dev/null || echo 0)

    if [[ "${feat_count}" -eq 0 ]]; then
        echo "    [skip] ${name}: 0 features after clip"
        rm -f "${out}"
        continue
    fi

    echo "           ${feat_count} features"
    echo "${out}" >> "${EXPORTED_LIST}"
done < "${AREAS_TSV}"

if [[ ! -s "${EXPORTED_LIST}" ]]; then
    echo "Error: no areas exported successfully" >&2
    exit 1
fi

# ── Step 2 — Merge all per-area GeoJSONs ─────────────────────────────────────
echo ""
exported_count=$(wc -l < "${EXPORTED_LIST}" | tr -d ' ')
echo "==> Step 2/3 — Merging ${exported_count} area(s) into combined GeoJSON"

first=true
while IFS= read -r f; do
    if [[ "${first}" == "true" ]]; then
        ogr2ogr -f GeoJSON "${COMBINED}" "${f}"
        first=false
    else
        ogr2ogr -f GeoJSON -update -append "${COMBINED}" "${f}"
    fi
done < "${EXPORTED_LIST}"

total=$(python3 -c "
import json
with open('${COMBINED}') as f:
    d = json.load(f)
# Drop degenerate linestrings (< 2 coords) — Mapbox upload rejects them
before = len(d.get('features', []))
d['features'] = [
    f for f in d['features']
    if f.get('geometry') and len(f['geometry'].get('coordinates', [])) >= 2
]
after = len(d['features'])
if before != after:
    with open('${COMBINED}', 'w') as out:
        json.dump(d, out)
    print(f'{after} (dropped {before - after} degenerate)')
else:
    print(after)
" 2>/dev/null || echo "?")
echo "    Total features: ${total}"

# ── Step 3 — tippecanoe → MBTiles + line-delimited GeoJSON ───────────────────
MBTILES="${OUTPUT_TILES}/streams_ph.mbtiles"
COMBINED_LD="${OUTPUT_TILES}/streams_ph.geojsonl"
echo ""
echo "==> Step 3/3 — Generating MBTiles + line-delimited GeoJSON"

tippecanoe \
    -o "${MBTILES}" \
    -Z 8 -z 14 \
    -l streams \
    --drop-densest-as-needed \
    --force \
    "${COMBINED}"

python3 -c "
import json
with open('${COMBINED}') as f:
    d = json.load(f)
with open('${COMBINED_LD}', 'w') as out:
    for feat in d['features']:
        out.write(json.dumps(feat) + '\n')
"

echo "    MBTiles written:  ${MBTILES}"
echo "    GeoJSONL written: ${COMBINED_LD}"

# ── Step 4 — Upload (if --upload) ─────────────────────────────────────────────
if [[ "${UPLOAD}" == "true" ]]; then
    echo ""
    echo "==> Step 4 — Uploading to Mapbox tileset: ${TILESET_ID}"
    TOKEN="${MAPBOX_ACCESS_TOKEN}"
    SOURCE_NAME="streams-ph-source"
    API="https://api.mapbox.com"

    CURL_BODY=$(mktemp /tmp/curl_body_XXXXXX)

    # Use the Uploads API (works for any tileset, incl. Studio-created ones)
    # Step 4a — Get temporary S3 staging credentials
    echo "    Getting S3 staging credentials …"
    STATUS=$(curl -sS -w "%{http_code}" -o "${CURL_BODY}" -X POST \
        "${API}/uploads/v1/${MAPBOX_USERNAME}/credentials?access_token=${TOKEN}")
    if [[ "${STATUS}" != "200" ]]; then
        echo "Error: credentials request failed (HTTP ${STATUS}): $(cat ${CURL_BODY})" >&2; exit 1
    fi

    # Step 4b — Upload MBTiles to S3 using temp credentials
    echo "    Uploading MBTiles to S3 staging …"
    python3 - <<PYEOF
import json, sys
try:
    import boto3
except ImportError:
    print("Error: boto3 not installed. Run: pip3 install boto3", file=sys.stderr)
    sys.exit(1)
with open('${CURL_BODY}') as f:
    creds = json.load(f)
s3 = boto3.client('s3',
    aws_access_key_id=creds['accessKeyId'],
    aws_secret_access_key=creds['secretAccessKey'],
    aws_session_token=creds['sessionToken'],
    region_name='us-east-1')
s3.upload_file('${MBTILES}', creds['bucket'], creds['key'])
print(f"    Staged: s3://{creds['bucket']}/{creds['key']}")
with open('${CURL_BODY}', 'w') as f:
    json.dump({'url': f"s3://{creds['bucket']}/{creds['key']}"}, f)
PYEOF

    # Step 4c — Register the upload with Mapbox
    echo "    Registering upload …"
    S3_URL=$(python3 -c "import json; print(json.load(open('${CURL_BODY}'))['url'])")
    STATUS=$(curl -sS -w "%{http_code}" -o "${CURL_BODY}" -X POST \
        "${API}/uploads/v1/${MAPBOX_USERNAME}?access_token=${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"url\":\"${S3_URL}\",\"tileset\":\"${TILESET_ID}\",\"name\":\"Philippines Modeled Streams\"}")
    if [[ "${STATUS}" != "201" ]]; then
        echo "Error: upload registration failed (HTTP ${STATUS}): $(cat ${CURL_BODY})" >&2; exit 1
    fi
    echo "    Upload registered (HTTP ${STATUS}) — processing in background"
    echo "    View at: https://studio.mapbox.com/tilesets/${TILESET_ID}"
    rm -f "${CURL_BODY}"
fi

# ── Cleanup ───────────────────────────────────────────────────────────────────
rm -f "${AREAS_TSV}" "${EXPORTED_LIST}"

echo ""
echo "==> Done."
echo "    MBTiles: ${MBTILES}"
if [[ "${UPLOAD}" == "false" ]]; then
    echo "    To upload: MAPBOX_ACCESS_TOKEN=pk.xxx MAPBOX_USERNAME=myuser \\"
    echo "      bash export_tiles.sh --upload --tileset myuser.streams-ph"
fi
