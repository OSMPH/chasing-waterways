#!/usr/bin/env bash
# 00_setup.sh — Install dependencies for the waterway gap analysis pipeline.
# Safe to run multiple times.

set -euo pipefail

echo "==> Installing brew packages …"
for pkg in osmium-tool tippecanoe; do
    if arch -arm64 brew list "$pkg" &>/dev/null; then
        echo "    $pkg already installed, skipping"
    else
        arch -arm64 brew install "$pkg"
    fi
done

echo "==> Installing Python geo packages …"
pip3 install --quiet geopandas rasterio shapely pandas numpy pyproj boto3

echo "==> Checking ogr2ogr …"
ogr2ogr --version | head -1

echo "==> Checking GRASS …"
GRASS=/Applications/GRASS-8.4.app/Contents/Resources/bin/grass
"${GRASS}" --version 2>&1 | head -2

echo ""
echo "All dependencies installed."
echo "Next step: bash 00_download.sh"
