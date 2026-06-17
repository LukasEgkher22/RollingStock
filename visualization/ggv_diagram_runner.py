"""
ggv_diagram_runner.py
=====================
Given a GGV value (e.g. "112_2312_412"), splits it by "_" to extract the related
Train IDs, filters the source CSV to those IDs, and generates a diagram for each
one using either trainid_diagram.py or unit_diagram.py.

Examples:
    python ggv_diagram_runner.py
    python ggv_diagram_runner.py --source my.csv --script trainid --ggv 112_2312_412
    python ggv_diagram_runner.py --source my.csv --script unit --ggv 1221_2219_2221_4821
    python ggv_diagram_runner.py --source my.csv --script trainid --ggv 112_2312_412 --filtered-output filtered.csv
"""

from __future__ import annotations

import argparse
import csv
import io
import sys
from contextlib import redirect_stdout
from pathlib import Path


# ---------------------------------------------------------------------------
# Hardcoded Settings
# ---------------------------------------------------------------------------
# Edit these values to run without CLI flags.
HARDCODED_SOURCE_CSV = "UnitAssignment_GGV_2026-06-15_160425.csv"  # Set to the CSV containing TrainId/Departure/Arrival columns.
HARDCODED_SCRIPT = "unit"            # "trainid" or "unit"
HARDCODED_GGV = "132_2332_4132_432"         # GGV value to split and use as filter, e.g. "112_2312_412"
HARDCODED_FILTERED_OUTPUT = ""          # Empty -> do not persist filtered CSV
HARDCODED_CHART_OUTPUT = ""             # Empty -> let target script choose output name
HARDCODED_TIME_OFFSET = 0
AUTO_PICK_LATEST_CSV = True             # Used only when --source and HARDCODED_SOURCE_CSV are empty.
AUTO_PICK_EXCLUDE_PREFIXES = ("solution_", "ggv_", "aggregated_trips_")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Split a GGV value by '_' into Train IDs, filter a CSV to those IDs, "
            "and generate a diagram for each using trainid_diagram.py or unit_diagram.py."
        )
    )
    parser.add_argument(
        "--source",
        type=Path,
        default=None,
        help="Input CSV to filter.",
    )
    parser.add_argument(
        "--script",
        choices=("trainid", "unit"),
        required=False,
        help="Which diagram script to run (trainid or unit).",
    )
    parser.add_argument(
        "--ggv",
        type=str,
        required=False,
        help="GGV value to split by '_', e.g. '112_2312_412'.",
    )
    parser.add_argument(
        "--filtered-output",
        type=Path,
        default=None,
        help="Optional output path for the filtered CSV (a suffix per Train ID is appended when multiple).",
    )
    parser.add_argument(
        "--chart-output",
        type=Path,
        default=None,
        help="Optional output path for the chart PNG (a suffix per Train ID is appended when multiple).",
    )
    parser.add_argument(
        "--time-offset",
        type=int,
        default=0,
        help="Pass-through time offset for the diagram scripts.",
    )
    return parser.parse_args()


# ---------------------------------------------------------------------------
# CSV helpers (shared with diagram_runner.py)
# ---------------------------------------------------------------------------

def read_rows(path: Path) -> tuple[list[dict], list[str]]:
    with path.open(newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        rows = list(reader)
        fieldnames = list(reader.fieldnames or [])

    # Always prefer UnitSpecificId for unit-based plotting when available.
    if "UnitSpecificId" in fieldnames:
        if "Unit" in fieldnames:
            for row in rows:
                row["Unit"] = row.get("UnitSpecificId", row.get("Unit", ""))
        else:
            fieldnames = ["Unit" if name == "UnitSpecificId" else name for name in fieldnames]
            for row in rows:
                if "UnitSpecificId" in row:
                    row["Unit"] = row.pop("UnitSpecificId")

    if "Unit" not in fieldnames and "unit" in fieldnames:
        fieldnames = ["Unit" if name == "unit" else name for name in fieldnames]
        for row in rows:
            if "unit" in row:
                row["Unit"] = row.pop("unit")

    # If still no Unit column, fall back to Composition so trainid_diagram.py can group rows.
    if "Unit" not in fieldnames and "Composition" in fieldnames:
        fieldnames = fieldnames + ["Unit"]
        for row in rows:
            row["Unit"] = row.get("Composition", "Unknown")

    return rows, fieldnames


def sanitize(value: str) -> str:
    return value.replace("/", "_").replace("\\", "_").replace(" ", "_")


def ensure_columns(mode: str, fieldnames: list[str]) -> None:
    required = {"TrainId", "Departure", "Arrival", "FromStation", "ToStation"}
    if mode == "unit":
        required.add("Unit")
    missing = sorted(required - set(fieldnames))
    if missing:
        raise ValueError(
            "Input CSV is not compatible with trainid_diagram.py/unit_diagram.py. "
            f"Missing columns: {', '.join(missing)}"
        )


def filter_rows(rows: list[dict], mode: str, value: str) -> list[dict]:
    if mode == "trainid":
        return [row for row in rows if row.get("TrainId", "").strip() == value.strip()]
    return [row for row in rows if row.get("Unit", "").strip() == value.strip()]


def collect_units_for_train_ids(rows: list[dict], train_ids: list[str]) -> list[str]:
    train_id_set = {value.strip() for value in train_ids if value.strip()}
    units: list[str] = []
    seen: set[str] = set()
    for row in rows:
        row_train_id = row.get("TrainId", "").strip()
        unit = row.get("Unit", "").strip()
        if row_train_id in train_id_set and unit and unit not in seen:
            seen.add(unit)
            units.append(unit)
    return units


def with_value_suffix(path: Path | None, value: str) -> Path | None:
    if path is None:
        return None
    safe = sanitize(value)
    return path.with_name(f"{path.stem}_{safe}{path.suffix}")


def write_filtered(path: Path, fieldnames: list[str], rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def resolve_source_csv(script_dir: Path, source_arg: Path | None) -> Path:
    if source_arg is not None:
        return source_arg

    if HARDCODED_SOURCE_CSV.strip():
        return script_dir / HARDCODED_SOURCE_CSV

    if AUTO_PICK_LATEST_CSV:
        candidates = [
            path
            for path in script_dir.glob("*.csv")
            if path.is_file() and not any(path.name.startswith(p) for p in AUTO_PICK_EXCLUDE_PREFIXES)
        ]
        if candidates:
            return max(candidates, key=lambda path: path.stat().st_mtime)

    raise FileNotFoundError(
        "No source CSV resolved. Set --source, or set HARDCODED_SOURCE_CSV, "
        "or enable AUTO_PICK_LATEST_CSV with at least one CSV file present."
    )


# ---------------------------------------------------------------------------
# GGV-specific logic
# ---------------------------------------------------------------------------

def split_ggv(ggv: str) -> list[str]:
    """Split a GGV string like '112_2312_412' into raw parts ['112', '2312', '412']."""
    parts = [part.strip() for part in ggv.split("_") if part.strip()]
    if not parts:
        raise ValueError(f"GGV value '{ggv}' produced no Train IDs after splitting by '_'.")
    return parts


def resolve_train_ids_from_ggv(ggv: str, available_train_ids: set[str]) -> list[str]:
    """
    Resolve TrainId candidates from a GGV string using only contiguous combinations.

    Example: 112_2312_412 checks contiguous candidates like:
      112, 2312, 412, 112_2312, 2312_412, 112_2312_412
    but never non-contiguous combinations like 112_412.
    """
    parts = split_ggv(ggv)

    resolved: list[str] = []
    seen: set[str] = set()

    # Check longer contiguous windows first, then shorter ones.
    for window_len in range(len(parts), 0, -1):
        for start_idx in range(0, len(parts) - window_len + 1):
            candidate = "_".join(parts[start_idx:start_idx + window_len])
            if candidate in available_train_ids and candidate not in seen:
                seen.add(candidate)
                resolved.append(candidate)

    if resolved:
        return resolved

    # Backward-compatible fallback if nothing matches available TrainIds.
    return parts


def compact_ggv(ggv: str) -> str:
    """Return GGV digits without underscores, e.g. 112_2312_412 -> 1122312412."""
    return "".join(part.strip() for part in ggv.split("_") if part.strip())


def spaced_ggv(ggv: str) -> str:
    """Return GGV parts separated by spaces, e.g. 112_2312_412 -> 112 2312 412."""
    return " ".join(part.strip() for part in ggv.split("_") if part.strip())


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    args = parse_args()
    script_dir = Path(__file__).resolve().parent

    source_csv = resolve_source_csv(script_dir, args.source)
    script_choice = args.script if args.script else HARDCODED_SCRIPT
    ggv = args.ggv.strip() if args.ggv else HARDCODED_GGV.strip()

    if script_choice not in {"trainid", "unit"}:
        raise ValueError("Script must be 'trainid' or 'unit'.")
    if not ggv:
        raise ValueError("GGV value is empty. Set --ggv or HARDCODED_GGV.")

    if not source_csv.exists():
        raise FileNotFoundError(
            f"Source CSV not found: {source_csv}. Set --source or update HARDCODED_SOURCE_CSV."
        )

    filtered_output_arg = args.filtered_output
    if filtered_output_arg is None and HARDCODED_FILTERED_OUTPUT:
        filtered_output_arg = script_dir / HARDCODED_FILTERED_OUTPUT

    chart_output_arg = args.chart_output
    if chart_output_arg is None and HARDCODED_CHART_OUTPUT:
        chart_output_arg = script_dir / HARDCODED_CHART_OUTPUT

    time_offset = args.time_offset if args.time_offset != 0 else HARDCODED_TIME_OFFSET

    rows, fieldnames = read_rows(source_csv)
    if not rows:
        raise ValueError("Source CSV has no data rows.")

    available_train_ids = {row.get("TrainId", "").strip() for row in rows if row.get("TrainId", "").strip()}
    train_ids = resolve_train_ids_from_ggv(ggv, available_train_ids)

    mode = script_choice
    ensure_columns(mode, fieldnames)

    if mode == "trainid":
        # TrainId mode: combine rows directly by TrainId from the GGV.
        all_rows: list[dict] = []
        for train_id in train_ids:
            filtered_rows = filter_rows(rows, mode, train_id)
            if filtered_rows:
                all_rows.extend(filtered_rows)

        if not all_rows:
            raise ValueError("No rows found for any Train ID in this GGV.")
    else:
        # Unit mode: map GGV TrainIds -> all used Units, then plot all those units together.
        units = collect_units_for_train_ids(rows, train_ids)
        if not units:
            raise ValueError("No units found for the Train IDs in this GGV.")

        train_id_set = {value.strip() for value in train_ids if value.strip()}
        all_rows = []
        for unit in units:
            unit_rows = filter_rows(rows, "unit", unit)
            if unit_rows:
                # Keep only rows where the TrainId belongs to the selected GGV.
                ggv_unit_rows = [
                    row for row in unit_rows
                    if row.get("TrainId", "").strip() in train_id_set
                ]
                all_rows.extend(ggv_unit_rows)

        if not all_rows:
            raise ValueError("No rows found for the units derived from this GGV.")

    if filtered_output_arg is not None:
        write_filtered(filtered_output_arg, fieldnames, all_rows)

    mode_label = "trainid" if mode == "trainid" else "units"
    ggv_spaced = spaced_ggv(ggv)
    chart_title = f"GGV \"{ggv_spaced}\" - {mode_label}"
    # Windows filenames cannot contain double quotes, so brackets are used in the default file path.
    output_path = chart_output_arg or (script_dir / f"GGV [{ggv_spaced}].png")

    # Import render directly so all train IDs appear in one single plot.
    if str(script_dir) not in sys.path:
        sys.path.insert(0, str(script_dir))

    if mode == "trainid":
        from trainid_diagram import render
        with redirect_stdout(io.StringIO()):
            render(all_rows, output_path, time_offset, 200, ggv, chart_title=chart_title)
    else:
        # In unit mode, plot lanes by Unit (UnitSpecificId-derived) rather than by TrainId.
        from trainid_diagram import render
        with redirect_stdout(io.StringIO()):
            render(
                all_rows,
                output_path,
                time_offset,
                200,
                f"units_{ggv}",
                chart_title=chart_title,
                color_by_train_id=True,
                show_color_legend=True,
                color_legend_title="Train IDs",
            )


if __name__ == "__main__":
    main()
