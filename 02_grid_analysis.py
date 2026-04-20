#!/usr/bin/env python3
"""
02_grid_analysis.py
Compute waterway gap delta scores from GRASS outputs.

Reads:
  output/grid.gpkg             grid cells with GRASS 'cat' column (UTM)
  output/modeled_by_cell.csv   modeled stream length per cell (pipe-separated)
  output/osm_by_cell.csv       OSM waterway length per cell (pipe-separated)

Writes:
  output/gap_analysis.geojson  grid cells with delta scores (WGS84)
"""

import logging
import sys
from pathlib import Path

import geopandas as gpd
import pandas as pd

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s",
                    datefmt="%H:%M:%S")
log = logging.getLogger(__name__)

PRIORITY_BINS   = [float("-inf"), 0.5, 1.0, float("inf")]  # delta_density bins
PRIORITY_LABELS = ["low", "medium", "high"]
MIN_STRAHLER    = 3  # strahler 1–2 visible in tiles; task grid starts at order-3+
COVERAGE_CAP    = 0.4  # osm/modeled > this → "low" (stream already well-mapped)


def coastal_independent_cats(streams_path: Path, grid: gpd.GeoDataFrame) -> set:
    """Return grid cell cat values containing coastal-independent strahler ≤2 streams.

    A strahler ≤2 stream is coastal-independent if walking next_stream reaches an outlet
    (next_stream == -1) without passing through a strahler ≥3 segment.
    Falls back to empty set if streams_wgs84.gpkg is absent.
    """
    if not streams_path.exists():
        log.warning("streams_wgs84.gpkg not found at %s — skipping coastal-independent CI classification", streams_path)
        return set()

    streams = gpd.read_file(streams_path, on_invalid="ignore")
    streams = streams[~streams.geometry.isna() & streams.geometry.is_valid]
    strahler_map = dict(zip(streams["stream"], streams["strahler"]))
    next_map     = dict(zip(streams["stream"], streams["next_stream"]))

    def trace(start_id):
        cur     = int(next_map.get(start_id, -1))
        visited = {start_id}
        for _ in range(200):
            if cur == -1 or cur not in strahler_map:
                return "coastal_independent"
            if strahler_map[cur] >= 3:
                return "headwater"
            if cur in visited:
                return "headwater"
            visited.add(cur)
            cur = int(next_map.get(cur, -1))
        return "headwater"

    s12 = streams[streams["strahler"] <= 2].copy()
    s12["classification"] = s12["stream"].apply(trace)

    grid_for_join = grid[["cat", "geometry"]].rename(columns={"cat": "cell_cat"})
    s12_utm = s12.to_crs(grid.crs)
    joined = gpd.sjoin(
        s12_utm[["stream", "classification", "geometry"]],
        grid_for_join, how="left", predicate="intersects"
    )

    ci_cats = (
        joined[joined["classification"] == "coastal_independent"]["cell_cat"]
        .dropna().astype(int).unique()
    )
    n_ci = len(ci_cats)
    log.info("  coastal-independent strahler 1-2 cells: %d", n_ci)
    return set(ci_cats)


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", default=None,
                        help="Directory containing GRASS outputs (default: ./output)")
    args = parser.parse_args()

    script_dir  = Path(__file__).parent
    output_dir  = Path(args.output_dir) if args.output_dir else script_dir / "output"

    grid_path     = output_dir / "grid.gpkg"
    modeled_path  = output_dir / "modeled_by_cell.csv"
    osm_path      = output_dir / "osm_by_cell.csv"
    out_path      = output_dir / "gap_analysis.geojson"

    for p in (grid_path, modeled_path, osm_path):
        if not p.exists():
            log.error("Missing input: %s — run 01_grass_hydro.sh first", p)
            sys.exit(1)

    # ── Load grid ────────────────────────────────────────────────────────────
    log.info("Loading grid …")
    grid = gpd.read_file(grid_path)
    log.info("  %d cells, CRS: %s", len(grid), grid.crs)

    # GRASS exports the category column as 'cat'
    if "cat" not in grid.columns:
        log.error("No 'cat' column in grid.gpkg. Columns: %s", list(grid.columns))
        sys.exit(1)
    grid["cat"] = grid["cat"].astype(int)

    # ── Load aggregated lengths from GRASS ───────────────────────────────────
    def read_csv(path: Path, value_col: str) -> pd.DataFrame:
        df = pd.read_csv(path, sep="|")
        df.columns = [c.strip().lower() for c in df.columns]
        # GRASS db.select column names: b_cat, total_m
        df = df.rename(columns={"b_cat": "cat", "total_m": value_col})
        df["cat"] = df["cat"].astype(int)
        df[value_col] = pd.to_numeric(df[value_col], errors="coerce").fillna(0)
        keep = ["cat", value_col]
        if "max_strahler" in df.columns:
            df["max_strahler"] = pd.to_numeric(df["max_strahler"], errors="coerce").fillna(1).astype(int)
            keep.append("max_strahler")
        return df[keep]

    log.info("Loading modeled lengths …")
    modeled = read_csv(modeled_path, "modeled_length_m")
    log.info("  %d cells have modeled streams", len(modeled))

    log.info("Loading OSM lengths …")
    osm = read_csv(osm_path, "osm_length_m")
    log.info("  %d cells have OSM waterways", len(osm))

    # ── Merge ────────────────────────────────────────────────────────────────
    grid = grid.merge(modeled, on="cat", how="left")
    grid = grid.merge(osm,     on="cat", how="left")
    grid["modeled_length_m"] = grid["modeled_length_m"].fillna(0)
    grid["osm_length_m"]     = grid["osm_length_m"].fillna(0)
    if "max_strahler" in grid.columns:
        grid["max_strahler"] = grid["max_strahler"].fillna(1).astype(int)

    # ── Delta ────────────────────────────────────────────────────────────────
    grid["delta_m"]        = (grid["modeled_length_m"] - grid["osm_length_m"]).clip(lower=0)
    grid["cell_area_m2"]   = grid.geometry.area.round(1)
    grid["cell_side_m"]    = grid["cell_area_m2"] ** 0.5
    grid["delta_density"]  = (grid["delta_m"] / grid["cell_side_m"]).fillna(0)
    grid["coverage_ratio"] = (
        grid["osm_length_m"] / grid["modeled_length_m"].replace(0, float("nan"))
    ).fillna(0).round(3)

    grid["priority"] = pd.cut(
        grid["delta_density"], bins=PRIORITY_BINS, labels=PRIORITY_LABELS
    ).astype(str).replace("nan", "low")

    # Coverage gate: already well-mapped cells → "low"
    grid.loc[grid["coverage_ratio"] > COVERAGE_CAP, "priority"] = "low"

    # ── Filter, reproject, export ─────────────────────────────────────────────
    streams_path = output_dir / "streams_wgs84.gpkg"
    ci_cats = coastal_independent_cats(streams_path, grid) if "max_strahler" in grid.columns else set()

    mask = grid["delta_m"] > 0
    if "max_strahler" in grid.columns:
        mask &= (
            (grid["max_strahler"] >= MIN_STRAHLER) |
            ((grid["max_strahler"] <= 2) & grid["cat"].isin(ci_cats))
        )
    output = grid[mask].copy()
    log.info("Cells with delta > 0: %d / %d", len(output), len(grid))

    for col in ["modeled_length_m", "osm_length_m", "delta_m", "delta_density"]:
        output[col] = output[col].round(3)

    extra_cols = ["max_strahler"] if "max_strahler" in output.columns else []
    output = output[["cat", "modeled_length_m", "osm_length_m", "delta_m",
                      "delta_density", "coverage_ratio", "cell_area_m2", "cell_side_m",
                      "priority"] + extra_cols + ["geometry"]]
    output = output.to_crs("EPSG:4326")
    output.to_file(str(out_path), driver="GeoJSON")

    log.info("Written → %s", out_path)
    log.info("Priority distribution: %s", output["priority"].value_counts().to_dict())
    log.info("delta_m — min: %.1f  median: %.1f  max: %.1f",
             output["delta_m"].min(), output["delta_m"].median(), output["delta_m"].max())


if __name__ == "__main__":
    main()
