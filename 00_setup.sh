#!/usr/bin/env bash
# 00_setup.sh — Install dependencies for the waterway gap analysis pipeline.
# Safe to run multiple times.

set -euo pipefail

echo "==> Installing osmium-tool …"
arch -arm64 brew install osmium-tool

echo "==> Installing Python geo packages …"
pip3 install geopandas rasterio shapely pandas numpy pyproj

echo "==> Checking ogr2ogr …"
ogr2ogr --version | head -1

echo "==> Checking GRASS …"
GRASS=/Applications/GRASS-8.4.app/Contents/Resources/bin/grass
"${GRASS}" --version 2>&1 | head -2

echo ""
echo "All dependencies installed."
echo "Next step: bash 00_download.sh"
