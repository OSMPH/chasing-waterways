# Chasing Waterways

Identify unmapped waterways in the Philippines by comparing terrain-modeled stream networks (derived from a 30m DEM) against existing OpenStreetMap data. Output is a prioritized grid of cells where OSM coverage lags the terrain model — ready for import into [MapRoulette](https://maproulette.org) or the [HOT Tasking Manager](https://tasks.hotosm.org).

## How it works

1. **Download** — fetch Copernicus DEM 30m tiles, OSM waterways, and named lake polygons for the target area via Overpass API (or a local file via `--osm-file`).
2. **Model streams** — run a hydrological analysis in GRASS GIS using single-flow-direction (D8) routing (flow accumulation → stream extraction → Strahler order). Named lakes (≥ 1 km²) are masked out before watershed analysis so DEM streams are not routed through large water bodies. Optionally, OSM waterways are burned into the DEM (`--carve`) before watershed analysis so the modeled network follows known channels.
3. **Overlay** — intersect modeled streams and OSM waterways with a 200 m grid; compute total mapped length per cell.
4. **Score gaps** — compute `delta_m = modeled_length − osm_length` per cell; assign priority (low / medium / high) based on gap density and OSM coverage ratio. Cells with `max_strahler ≥ 3` are always included. Strahler 1–2 cells are included if they are coastal-independent (drain directly to sea without joining a higher-order network).
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
| `--osm-file` | off | Path to local OSM file (`.pbf`, `.gpkg`, `.shp`, `.geojson`); skips Overpass |
| `--carve` | off | Burn OSM waterways into DEM before watershed analysis; improves alignment of modeled streams with mapped channels |
| `--carve-width` | 90 | Width of carved channel in metres (should be ≥ 30 — one DEM pixel) |
| `--carve-depth` | 5.0 | Depth of carved channel in metres |
| `--mexp` | 0 | Montgomery–Foufoula–Georgiou exponent for `r.stream.extract`; 0 disables (standard flow accumulation threshold) |

### Examples

```bash
# First run — downloads everything
bash run_pipeline.sh --name siquijor --bbox "9.0 123.4 9.4 123.8"

# Re-run after tweaking threshold, skip re-download
bash run_pipeline.sh --name siquijor --bbox "9.0 123.4 9.4 123.8" --threshold 500 --skip-download

# Different island
bash run_pipeline.sh --name catanduanes --bbox "13.4791 123.9807 14.1459 124.4971"

# Large area — use Geofabrik PBF instead of Overpass (avoids timeout)
bash run_pipeline.sh --name luzon --bbox "13.5 119.5 18.7 122.5" \
  --osm-file /path/to/philippines-latest.osm.pbf

# PBF + skip DEM re-download if tiles already cached
bash run_pipeline.sh --name luzon --bbox "13.5 119.5 18.7 122.5" \
  --osm-file /path/to/philippines-latest.osm.pbf --skip-download

# Recommended for Philippines runs: OSM stream burning
bash run_pipeline.sh --name ilocos-norte --bbox "17.675 120.339 18.680 120.987" \
  --osm-file philippines-latest.osm.pbf --skip-download --cell-size 500 \
  --carve
```

Output is written to `output/<name>/gap_analysis.geojson`.

## Output fields

| Field | Description |
|---|---|
| `cat` | GRASS grid cell ID |
| `modeled_length_m` | Total DEM-modeled stream length in cell (m) |
| `osm_length_m` | Total OSM-mapped waterway length in cell (m) |
| `delta_m` | Gap in metres (`modeled − osm`, clipped to 0) |
| `delta_density` | `delta_m / cell_side_m` — scale-invariant gap density (same value in 200 m or 500 m cells for equal gap length) |
| `cell_area_m2` | Cell area (m²) — partial for edge cells |
| `max_strahler` | Highest Strahler stream order in cell |
| `priority` | `low` / `medium` / `high` |

### Priority logic

Cells appear in the output if `delta_m > 0` and either:
- `max_strahler ≥ 3`, or
- `max_strahler ≤ 2` and the cell is **coastal-independent** — strahler 1–2 streams whose downstream path reaches the sea without passing through a strahler ≥ 3 segment (complete small drainages, not headwaters feeding a larger network).

Priority is assigned in two steps:

**Step 1 — coverage gate** (already-mapped streams):
If `coverage_ratio > 0.4` → priority = **low**

**Step 2 — gap density** (applied to remaining cells):

| `delta_density` | Priority |
|---|---|
| 0 – 0.5 | low |
| 0.5 – 1.0 | medium |
| > 1.0 | high |

Calibrated against MapRoulette review ground truth (n=6,576 non-skipped reviews across Ilocos Norte, Siquijor, and Basilan). Coverage gate Youden-optimal at cap=0.3 (J=0.48); current cap=0.4 is conservative but stable across OSM-dense and OSM-sparse areas.

## Tile export (Mapbox)

After one or more pipeline runs complete, use `export_tiles.sh` to merge all area stream vectors into a single MBTiles file and optionally publish it to a Mapbox tileset.

### Setup (one-time, included in `00_setup.sh`)

```bash
arch -arm64 brew install tippecanoe
pip3 install mapbox-tilesets
```

### Register completed areas

Edit `areas_registry.json` to add each completed run:

```json
{
  "siquijor":     { "dir": "siquijor",           "bbox": [123.4, 9.0, 123.8, 9.4] },
  "catanduanes":  { "dir": "catanduanes",         "bbox": [123.9807, 13.4791, 124.4971, 14.1459] }
}
```

- **`dir`** — subfolder under `output/` containing `streams_wgs84.gpkg`
- **`bbox`** — `[W, S, E, N]` used to clip streams before merging; prevents overlap at area boundaries

Each pipeline run also writes `output/<name>/metadata.json`. Pass `--auto` to discover these automatically without editing the registry.

### Run

```bash
# Dry run — produces output/tiles/streams_ph.mbtiles
bash export_tiles.sh

# Upload to Mapbox
MAPBOX_ACCESS_TOKEN=pk.xxx MAPBOX_USERNAME=myuser \
  bash export_tiles.sh --upload --tileset myuser.streams-ph
```

| Option | Description |
|---|---|
| `--upload` | Upload to Mapbox after generating MBTiles |
| `--tileset` | Mapbox tileset ID (required with `--upload`) |
| `--registry` | Path to registry JSON (default: `areas_registry.json`) |
| `--auto` | Auto-discover completed runs via `output/*/metadata.json` |

Tiles are generated at zoom 8–14. Each feature carries `strahler` and `source_area` attributes for use in Mapbox style rules. To include additional attributes (e.g. `length`, `gradient`), edit the `SQL=` line in `export_tiles.sh`.

### Folder structure (updated)

```
├── export_tiles.sh        tile export + Mapbox upload
├── areas_registry.json    area slug → output dir + bbox
└── output/
    ├── <name>/
    │   ├── streams_wgs84.gpkg   WGS84 stream lines (written by pipeline)
    │   ├── metadata.json        run metadata for auto-discovery
    │   └── gap_analysis.geojson
    └── tiles/
        └── streams_ph.mbtiles  merged tile output
```

## OSM waterway types included

`river`, `stream`, `canal`, `drain`, `ditch`, `tidal_channel`

## Folder structure

```
.
├── run_pipeline.sh        entry point
├── 00_setup.sh            one-time dependency install
├── 00_download.sh         download DEM tiles + OSM data for any bbox
├── 01_grass_hydro.sh      GRASS GIS spatial pipeline
├── 02_grid_analysis.py    gap scoring and GeoJSON export
├── export_tiles.sh        merge streams → MBTiles → Mapbox upload
├── areas_registry.json    area slug → output dir + bbox for tile export
├── data/
│   ├── srtm/              Copernicus DEM 30m tiles (shared cache, gitignored)
│   ├── osm/               OSM waterway + lake files per area (gitignored)
│   └── boundary/          Admin boundaries (gitignored)
└── output/
    ├── <name>/            Per-area outputs
    │   ├── gap_analysis.geojson
    │   ├── streams_wgs84.gpkg
    │   └── metadata.json
    └── tiles/
        └── streams_ph.mbtiles
```

The `grass/` GRASS database is created at runtime and is gitignored.

## Notes

- DEM tiles are cached in `data/srtm/` and reused across runs. Multiple areas in the same UTM zone share tiles without conflict.
- When invoked via `run_pipeline.sh`, only the tiles that cover the target bbox are imported. The GRASS computational region is then clipped to the bbox + 5 km buffer, so grid cells and stream analysis are confined to the target area rather than the full tile extent.
- Stream threshold of 200 cells ≈ 0.18 km² contributing area. Increase to 500–1000 for noisier/flatter terrain.
- Copernicus DEM 30m is available from a public AWS S3 bucket — no authentication required.
- For large areas (e.g. whole Philippines), Overpass times out. Download `philippines-latest.osm.pbf` from [Geofabrik](https://download.geofabrik.de/asia/philippines.html) and pass it via `--osm-file`; the pipeline filters and clips it automatically.
- Named lake polygons (`lakes_<name>.gpkg`) are re-extracted from the PBF on every run when `--osm-file` is provided. If no named lakes exist in the bbox the step is silently skipped.
- `--carve` burns OSM waterways into the DEM before watershed analysis using `r.carve`. This improves main-stem alignment significantly on flat/coastal terrain. Width must be ≥ 30 m (one DEM pixel) to have any effect; the default 90 m (3 pixels) gives reliable results.
- `--carve` is off by default so existing single-island runs reproduce unchanged results.
