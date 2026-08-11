"""Unified runner for trainid, unit, and ggv diagram generation."""

from __future__ import annotations

import argparse
import csv
import io
import sys
from contextlib import redirect_stdout
from pathlib import Path


# ---------------------------------------------------------------------------
# Hardcoded Runner Settings
# ---------------------------------------------------------------------------
# Edit these values to run without CLI flags.
HARDCODED_SOURCE_CSV = "UnitAssignment_GGV_2026-06-19_115259_processed.csv"                    # Optional fixed CSV filename. Empty -> auto-pick newest CSV.
HARDCODED_SCRIPT = "trainid"                  # "trainid", "unit", or "ggv"
#for below:
#unit=unit_type and number
#trainid=number
#ggv= number_number_... depending on how long the ggv is
HARDCODED_VALUE = "6"                  # unit=unit_type and numberTrainId, Unit, or GGV value depending on script mode
HARDCODED_FILTERED_OUTPUT = ""
HARDCODED_CHART_OUTPUT = ""
HARDCODED_TIME_OFFSET = 0
AUTO_PICK_LATEST_CSV = True
AUTO_PICK_EXCLUDE_PREFIXES = ("solution_",)
DEFAULT_OUTPUT_DIRNAME = "Newest diagram"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Filter data and generate a diagram in one command."
    )
    parser.add_argument(
        "--source",
        type=Path,
        default=None,
        help="Input CSV to filter.",
    )
    parser.add_argument(
        "--script",
        choices=("trainid", "unit", "ggv"),
        required=False,
        help="Which diagram script to run.",
    )
    parser.add_argument(
        "--value",
        type=str,
        required=False,
        help="Filter value used by selected script (TrainId, Unit, or GGV string).",
    )
    parser.add_argument(
        "--filtered-output",
        type=Path,
        default=None,
        help="Optional output path for the filtered CSV.",
    )
    parser.add_argument(
        "--chart-output",
        type=Path,
        default=None,
        help="Optional output path for the chart PNG.",
    )
    parser.add_argument(
        "--time-offset",
        type=int,
        default=0,
        help="Pass-through time offset for the diagram scripts.",
    )
    return parser.parse_args()


def read_rows(path: Path) -> tuple[list[dict], list[str]]:
    with path.open(newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        rows = list(reader)
        fieldnames = list(reader.fieldnames or [])

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

    if "Unit" not in fieldnames and "Composition" in fieldnames:
        fieldnames = fieldnames + ["Unit"]
        for row in rows:
            row["Unit"] = row.get("Composition", "Unknown")

    return rows, fieldnames


def sanitize(value: str) -> str:
    return value.replace("/", "_").replace("\\", "_").replace(" ", "_")


def ensure_columns(mode: str, fieldnames: list[str]) -> None:
    required = {"TrainId", "Departure", "Arrival", "FromStation", "ToStation"}
    if mode in {"trainid", "unit", "ggv"}:
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


def collect_target_values(rows: list[dict], mode: str, value: str) -> list[str]:
    if value.lower() != "all":
        return [value]
    field = "TrainId" if mode == "trainid" else "Unit"
    targets = sorted({row.get(field, "").strip() for row in rows if row.get(field, "").strip()})
    if not targets:
        raise ValueError(f"No non-empty {field} values found in source CSV.")
    return targets


def with_value_suffix(path: Path | None, value: str) -> Path | None:
    if path is None:
        return None
    safe = sanitize(value)
    return path.with_name(f"{path.stem}_{safe}{path.suffix}")


def resolve_default_output_dir(script_dir: Path) -> Path:
    output_dir = script_dir / DEFAULT_OUTPUT_DIRNAME
    output_dir.mkdir(parents=True, exist_ok=True)
    return output_dir


def write_filtered(path: Path, fieldnames: list[str], rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def split_ggv(ggv: str) -> list[str]:
    parts = [part.strip() for part in ggv.split("_") if part.strip()]
    if not parts:
        raise ValueError(f"GGV value '{ggv}' produced no Train IDs after splitting by '_'.")
    return parts


def resolve_train_ids_from_ggv(ggv: str, available_train_ids: set[str]) -> list[str]:
    parts = split_ggv(ggv)

    resolved: list[str] = []
    seen: set[str] = set()

    for window_len in range(len(parts), 0, -1):
        for start_idx in range(0, len(parts) - window_len + 1):
            candidate = "_".join(parts[start_idx:start_idx + window_len])
            if candidate in available_train_ids and candidate not in seen:
                seen.add(candidate)
                resolved.append(candidate)

    if resolved:
        return resolved
    return parts


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


def spaced_ggv(ggv: str) -> str:
    return " ".join(part.strip() for part in ggv.split("_") if part.strip())


def resolve_source_csv(script_dir: Path, source_arg: Path | None) -> Path:
    if source_arg is not None:
        if source_arg.is_absolute():
            return source_arg
        relative_candidate = script_dir / source_arg
        if relative_candidate.exists():
            return relative_candidate
        return source_arg

    project_root = script_dir.parent
    results_dir = project_root / "Results"

    if HARDCODED_SOURCE_CSV.strip():
        source_name = Path(HARDCODED_SOURCE_CSV)
        hardcoded_candidates = []
        if source_name.is_absolute():
            hardcoded_candidates.append(source_name)
        else:
            hardcoded_candidates.extend([
                script_dir / source_name,
                results_dir / source_name,
                project_root / source_name,
            ])
        for candidate in hardcoded_candidates:
            if candidate.exists():
                return candidate

    if AUTO_PICK_LATEST_CSV:
        visualization_candidates = [
            path
            for path in script_dir.glob("*.csv")
            if path.is_file() and not path.name.startswith(AUTO_PICK_EXCLUDE_PREFIXES)
        ]
        results_candidates = [
            path
            for path in results_dir.glob("*.csv")
            if path.is_file() and not path.name.startswith(AUTO_PICK_EXCLUDE_PREFIXES)
        ]
        candidates = visualization_candidates + results_candidates
        if candidates:
            return max(candidates, key=lambda path: path.stat().st_mtime)

    raise FileNotFoundError(
        "No source CSV resolved. Set --source, or set HARDCODED_SOURCE_CSV, "
        "or enable AUTO_PICK_LATEST_CSV with at least one CSV file present."
    )


def render_direct_trainid(script_dir: Path, rows: list[dict], output_path: Path, time_offset: int, title_label: str) -> None:
    from trainid_diagram import render
    with redirect_stdout(io.StringIO()):
        render(rows, output_path, time_offset, 200, title_label, chart_title=f"Train ID - {title_label}")


def render_direct_unit(script_dir: Path, rows: list[dict], output_path: Path, time_offset: int) -> None:
    from unit_diagram import render
    with redirect_stdout(io.StringIO()):
        render(rows, output_path, time_offset, 200)


def render_ggv_trainid(script_dir: Path, rows: list[dict], output_path: Path, time_offset: int, ggv: str) -> None:
    from trainid_diagram import render
    chart_title = f'GGV "{spaced_ggv(ggv)}" - trainid'
    with redirect_stdout(io.StringIO()):
        render(rows, output_path, time_offset, 200, ggv, chart_title=chart_title)


def render_ggv_unit(script_dir: Path, rows: list[dict], output_path: Path, time_offset: int, ggv: str) -> None:
    from trainid_diagram import render
    chart_title = f'GGV "{spaced_ggv(ggv)}" - units'
    with redirect_stdout(io.StringIO()):
        render(
            rows,
            output_path,
            time_offset,
            200,
            f"units_{ggv}",
            chart_title=chart_title,
            color_by_train_id=True,
            show_color_legend=True,
            color_legend_title="Train IDs",
        )


def main() -> None:
    args = parse_args()
    script_dir = Path(__file__).resolve().parent

    source_csv = resolve_source_csv(script_dir, args.source)
    script_choice = args.script if args.script else HARDCODED_SCRIPT
    if script_choice not in {"trainid", "unit", "ggv"}:
        raise ValueError("Script must be 'trainid', 'unit', or 'ggv'.")

    value = args.value.strip() if args.value else HARDCODED_VALUE.strip()
    if not value:
        raise ValueError("Filter value is empty. Set --value or HARDCODED_VALUE.")

    filtered_output_arg = args.filtered_output
    if filtered_output_arg is None and HARDCODED_FILTERED_OUTPUT:
        filtered_output_arg = script_dir / HARDCODED_FILTERED_OUTPUT

    chart_output_arg = args.chart_output
    if chart_output_arg is None and HARDCODED_CHART_OUTPUT:
        chart_output_arg = script_dir / HARDCODED_CHART_OUTPUT

    default_output_dir = resolve_default_output_dir(script_dir)

    time_offset = args.time_offset if args.time_offset != 0 else HARDCODED_TIME_OFFSET

    if not source_csv.exists():
        raise FileNotFoundError(
            f"Source CSV not found: {source_csv}. Set --source or update HARDCODED_SOURCE_CSV."
        )

    rows, fieldnames = read_rows(source_csv)
    if not rows:
        raise ValueError("Source CSV has no data rows.")

    mode = script_choice

    ensure_columns(mode, fieldnames)

    if mode == "ggv":
        ggv = value
        available_train_ids = {row.get("TrainId", "").strip() for row in rows if row.get("TrainId", "").strip()}
        train_ids = resolve_train_ids_from_ggv(ggv, available_train_ids)

        units = collect_units_for_train_ids(rows, train_ids)
        if not units:
            raise ValueError("No units found for the Train IDs in this GGV.")

        train_id_set = {value.strip() for value in train_ids if value.strip()}
        all_rows: list[dict] = []
        for unit in units:
            unit_rows = filter_rows(rows, "unit", unit)
            if unit_rows:
                ggv_unit_rows = [row for row in unit_rows if row.get("TrainId", "").strip() in train_id_set]
                all_rows.extend(ggv_unit_rows)

        if not all_rows:
            raise ValueError("No rows found for the units derived from this GGV.")

        if filtered_output_arg is not None:
            write_filtered(filtered_output_arg, fieldnames, all_rows)

        output_path = chart_output_arg or (default_output_dir / f"GGV [{spaced_ggv(ggv)}].png")
        render_ggv_unit(script_dir, all_rows, output_path, time_offset, ggv)
        return

    target_values = collect_target_values(rows, mode, value)
    run_all = len(target_values) > 1

    for target_value in target_values:
        filtered_rows = filter_rows(rows, mode, target_value)
        if not filtered_rows:
            continue

        filtered_output = with_value_suffix(filtered_output_arg, target_value) if run_all else filtered_output_arg
        chart_output = with_value_suffix(chart_output_arg, target_value) if run_all else chart_output_arg

        if filtered_output is not None:
            write_filtered(filtered_output, fieldnames, filtered_rows)

        if mode == "trainid":
            output_path = chart_output or (default_output_dir / f"trainid_{sanitize(target_value)}.png")
            render_direct_trainid(script_dir, filtered_rows, output_path, time_offset, target_value)
        else:
            output_path = chart_output or (default_output_dir / f"unit_{sanitize(target_value)}.png")
            render_direct_unit(script_dir, filtered_rows, output_path, time_offset)


if __name__ == "__main__":
    main()
