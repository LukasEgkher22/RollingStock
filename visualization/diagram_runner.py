"""
diagram_runner.py
=================
Filter a CSV by TrainId or Unit, save a compatible filtered CSV, and generate
the matching chart by calling either trainid_diagram.py or unit_diagram.py.

Examples:
    python diagram_runner.py
    python diagram_runner.py --source my.csv --script trainid --value 6
    python diagram_runner.py --source my.csv --script unit --value ICU_1
    python diagram_runner.py --source my.csv --script trainid --value all
    python diagram_runner.py --source Unit_Filt_simple_test#1.csv --script unit --value ICU_1
"""

from __future__ import annotations

import argparse
import csv
import subprocess
import sys
import tempfile
from pathlib import Path


# ---------------------------------------------------------------------------
# Hardcoded Runner Settings
# ---------------------------------------------------------------------------
# Edit these values to run without CLI flags.
HARDCODED_SOURCE_CSV = "UnitAssignment_UnitPreservation_2026-06-10_174213.csv"                    # Optional fixed CSV filename. Empty -> auto-pick newest CSV.
HARDCODED_SCRIPT = "trainid"                  # "trainid" or "unit"
HARDCODED_VALUE = "6"                  # TrainId/Unit value, or "all" for every unique value
HARDCODED_FILTERED_OUTPUT = ""             # Empty -> do not persist filtered CSV
HARDCODED_CHART_OUTPUT = ""                # Empty -> let target script choose output name
HARDCODED_TIME_OFFSET = 0
AUTO_PICK_LATEST_CSV = True                # Used only when --source and HARDCODED_SOURCE_CSV are empty.
AUTO_PICK_EXCLUDE_PREFIXES = ("solution_",)


def parse_args() -> argparse.Namespace:
    script_dir = Path(__file__).resolve().parent
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
        choices=("trainid", "unit"),
        required=False,
        help="Which diagram script to run.",
    )
    parser.add_argument(
        "--value",
        type=str,
        required=False,
        help="Filter value used by the selected script (TrainId for trainid, Unit for unit).",
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

    # Normalize alternate unit headers to 'Unit' for compatibility.
    if "Unit" not in fieldnames and "unit" in fieldnames:
        fieldnames = ["Unit" if name == "unit" else name for name in fieldnames]
        for row in rows:
            if "unit" in row:
                row["Unit"] = row.pop("unit")

    if "Unit" not in fieldnames and "UnitSpecificId" in fieldnames:
        fieldnames = ["Unit" if name == "UnitSpecificId" else name for name in fieldnames]
        for row in rows:
            if "UnitSpecificId" in row:
                row["Unit"] = row.pop("UnitSpecificId")

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
        hardcoded_path = script_dir / HARDCODED_SOURCE_CSV
        if hardcoded_path.exists():
            return hardcoded_path
        print(
            f"Warning: HARDCODED_SOURCE_CSV not found: {hardcoded_path}. "
            "Falling back to auto-pick."
        )

    if AUTO_PICK_LATEST_CSV:
        candidates = [
            path
            for path in script_dir.glob("*.csv")
            if path.is_file() and not path.name.startswith(AUTO_PICK_EXCLUDE_PREFIXES)
        ]
        if candidates:
            return max(candidates, key=lambda path: path.stat().st_mtime)

    raise FileNotFoundError(
        "No source CSV resolved. Set --source, or set HARDCODED_SOURCE_CSV, "
        "or enable AUTO_PICK_LATEST_CSV with at least one CSV file present."
    )


def run_chart(script_dir: Path, mode: str, value: str, filtered_csv: Path, chart_output: Path | None, time_offset: int) -> None:
    if mode == "trainid":
        script = script_dir / "trainid_diagram.py"
        command = [
            sys.executable,
            str(script),
            "--input",
            str(filtered_csv),
            "--train-id",
            value,
            "--time-offset",
            str(time_offset),
        ]
    else:
        script = script_dir / "unit_diagram.py"
        command = [
            sys.executable,
            str(script),
            "--input",
            str(filtered_csv),
            "--unit",
            value,
            "--time-offset",
            str(time_offset),
        ]

    if chart_output is not None:
        command.extend(["--output", str(chart_output)])

    subprocess.run(command, check=True)


def main() -> None:
    args = parse_args()
    script_dir = Path(__file__).resolve().parent

    source_csv = resolve_source_csv(script_dir, args.source)
    script_choice = args.script if args.script else HARDCODED_SCRIPT
    value = args.value.strip() if args.value else HARDCODED_VALUE.strip()
    if script_choice not in {"trainid", "unit"}:
        raise ValueError("Script must be 'trainid' or 'unit'.")
    if not value:
        raise ValueError("Filter value is empty. Set --value or HARDCODED_VALUE.")

    filtered_output_arg = args.filtered_output
    if filtered_output_arg is None and HARDCODED_FILTERED_OUTPUT:
        filtered_output_arg = script_dir / HARDCODED_FILTERED_OUTPUT

    chart_output_arg = args.chart_output
    if chart_output_arg is None and HARDCODED_CHART_OUTPUT:
        chart_output_arg = script_dir / HARDCODED_CHART_OUTPUT

    time_offset = args.time_offset if args.time_offset != 0 else HARDCODED_TIME_OFFSET

    if not source_csv.exists():
        raise FileNotFoundError(
            f"Source CSV not found: {source_csv}. Set --source or update HARDCODED_SOURCE_CSV."
        )

    rows, fieldnames = read_rows(source_csv)
    if not rows:
        raise ValueError("Source CSV has no data rows.")

    mode = "trainid" if script_choice == "trainid" else "unit"

    ensure_columns(mode, fieldnames)
    target_values = collect_target_values(rows, mode, value)
    run_all = len(target_values) > 1

    for target_value in target_values:
        filtered_rows = filter_rows(rows, mode, target_value)
        if not filtered_rows:
            continue

        filtered_output = with_value_suffix(filtered_output_arg, target_value) if run_all else filtered_output_arg
        chart_output = with_value_suffix(chart_output_arg, target_value) if run_all else chart_output_arg
        temp_path: Path | None = None

        try:
            if filtered_output is not None:
                write_filtered(filtered_output, fieldnames, filtered_rows)
                csv_for_chart = filtered_output
            else:
                with tempfile.NamedTemporaryFile(
                    mode="w",
                    newline="",
                    encoding="utf-8",
                    suffix=".csv",
                    delete=False,
                ) as temp_file:
                    temp_path = Path(temp_file.name)
                write_filtered(temp_path, fieldnames, filtered_rows)
                csv_for_chart = temp_path

            run_chart(
                script_dir=script_dir,
                mode=mode,
                value=target_value,
                filtered_csv=csv_for_chart,
                chart_output=chart_output,
                time_offset=time_offset,
            )
        finally:
            if temp_path is not None and temp_path.exists():
                temp_path.unlink()


if __name__ == "__main__":
    main()
