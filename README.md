# Chasing Waterways

Identify unmapped waterways in the Philippines by comparing terrain-modeled stream networks (derived from a 30m DEM) against existing OpenStreetMap data. Output is a prioritized grid of cells where OSM coverage lags the terrain model — ready for import into [MapRoulette](https://maproulette.org) or the [HOT Tasking Manager](https://tasks.hotosm.org).

## How it works

1. **Download** — fetch Copernicus DEM 30m tiles and OSM waterways for the target area via Overpass API.
2. **Model streams** — run a hydrological analysis in GRASS GIS (flow accumulation → stream extraction → Strahler order).
3. **Overlay** — intersect modeled streams and OSM waterways with a 200 m grid; compute total mapped length per cell.
4. **Score gaps** — compute `delta_m = modeled_length − osm_length` per cell; assign priority (low / medium / high) based on density and stream order.
5. **Export** — write `gap_analysis.geojson` (WGS84) for use in tasking platforms.

## Dependencies

| Tool | Install |
|---|---|
| GRASS GIS 8.4 | [grass.osgeo.org](https://grass.osgeo.org) — macOS app at `/Applications/GRASS-8.4.app` |
| Python 3 | system or pyenv |
| geopandas, pandas | `pip3 install geopandas pandas` |
| GDAL / ogr2ogr | bundled with GRASS or `brew install gdal` |
| osmium-tool | `arch -arm64 brew install osmium-tool` (Apple Silicon) |

Run the one-time setup script to install everything:

```bash
bash 00_setup.sh
```

## Usage

```bash
bash run_pipeline.sh --name <slug> --bbox "<S> <W> <N> <E>" [options]
```

| Option | Default | Description |
|---|---|---|
| `--name` | required | Short slug used for output paths (e.g. `siquijor`) |
| `--bbox` | required | Bounding box as `"S W N E"` in decimal degrees |
| `--threshold` | 200 | Flow accumulation threshold (cells) for stream extraction |
| `--cell-size` | 200 | Grid cell size in metres |
| `--skip-download` | off | Skip download step if data already present |

### Examples

```bash
# First run — downloads everything
bash run_pipeline.sh --name siquijor --bbox "9.0 123.4 9.4 123.8"

# Re-run after tweaking threshold, skip re-download
bash run_pipeline.sh --name siquijor --bbox "9.0 123.4 9.4 123.8" --threshold 500 --skip-download

# Different island
bash run_pipeline.sh --name catanduanes --bbox "13.4791 123.9807 14.1459 124.4971"
```

Output is written to `output/<name>/gap_analysis.geojson`.

## Output fields

| Field | Description |
|---|---|
| `cat` | GRASS grid cell ID |
| `modeled_length_m` | Total DEM-modeled stream length in cell (m) |
| `osm_length_m` | Total OSM-mapped waterway length in cell (m) |
| `delta_m` | Gap in metres (`modeled − osm`, clipped to 0) |
| `delta_density` | `delta_m / cell_area_m²` — comparable across edge cells |
| `cell_area_m2` | Cell area (m²) — partial for edge cells |
| `max_strahler` | Highest Strahler stream order in cell |
| `priority` | `low` / `medium` / `high` |

### Priority logic

| `delta_density` | Priority |
|---|---|
| 0 – 0.002 m/m² | low |
| 0.002 – 0.005 m/m² | medium |
| > 0.005 m/m² | high |

Cells with `max_strahler ≥ 3` and `delta_m > 0` are promoted to **high** regardless of density — significant tributaries are never buried in low/medium.

## OSM waterway types included

`river`, `stream`, `canal`, `drain`, `ditch`

## Folder structure

```
.
├── run_pipeline.sh        entry point
├── 00_setup.sh            one-time dependency install
├── 00_download.sh         download DEM tiles + OSM data for any bbox
├── 01_grass_hydro.sh      GRASS GIS spatial pipeline
├── 02_grid_analysis.py    gap scoring and GeoJSON export
├── data/
│   ├── srtm/              Copernicus DEM 30m tiles (shared cache, gitignored)
│   ├── osm/               OSM waterway files per area (gitignored)
│   └── boundary/          Admin boundaries (gitignored)
└── output/
    └── <name>/            Per-area outputs including gap_analysis.geojson
```

The `grass/` GRASS database is created at runtime and is gitignored.

## Notes

- DEM tiles are cached in `data/srtm/` and reused across runs. Multiple areas in the same UTM zone share tiles without conflict.
- The pipeline processes the full extent of all DEM tiles in `data/srtm/`, not just the target bbox. Cell counts therefore include surrounding land within the same tile(s).
- Stream threshold of 200 cells ≈ 0.18 km² contributing area. Increase to 500–1000 for noisier/flatter terrain.
- Copernicus DEM 30m is available from a public AWS S3 bucket — no authentication required.
