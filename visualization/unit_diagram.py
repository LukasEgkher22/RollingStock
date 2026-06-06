"""
unit_diagram.py
===============
Renders a Gantt-style railway timetable for a specific unit, split by TrainId.

Layout:
  - One horizontal lane per TrainId
  - Each segment is a colored bar from Departure to Arrival
  - Station and time labels are shown below each lane's stops
    - Visual styling matches trainid_diagram.py

Usage:
    python unit_diagram.py
    python unit_diagram.py --unit ICU_1                # outputs solution_unit_ICU_1.png
    python unit_diagram.py --input Unit_Filt_simple_test#1.csv --output my.png
"""

from __future__ import annotations

import argparse
import csv
from collections import defaultdict
from pathlib import Path

import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
from matplotlib.patches import FancyBboxPatch


# Layout constants (in data-row units)
ROW_H = 1.0
BAR_H = 0.52
ACCENT_H = 0.10
BAR_BOTTOM = 0.30
LABEL_GAP = 0.04
LINE_H = 0.13

_PALETTES = [
    ("#F5A623", "#8B4513"),
    ("#7B68EE", "#3A007D"),
    ("#4CAF50", "#1B5E20"),
    ("#E57373", "#B71C1C"),
    ("#29B6F6", "#01579B"),
    ("#FFF176", "#827717"),
    ("#80CBC4", "#004D40"),
]


def parse_args() -> argparse.Namespace:
    script_dir = Path(__file__).resolve().parent
    default_input = script_dir / "Unit_Filt_simple_test#1.csv"

    parser = argparse.ArgumentParser(
        description="Render a unit-centric Gantt chart split by TrainId lanes."
    )
    parser.add_argument("--input", type=Path, default=default_input, help="Input CSV path.")
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Output image path. If omitted, the filename includes Unit when filtered.",
    )
    parser.add_argument("--unit", type=str, default="", help="Filter to one unit value, e.g. ICU_1.")
    parser.add_argument(
        "--time-offset",
        type=int,
        default=0,
        help="Subtract this many minutes so x-axis starts at 00:00.",
    )
    parser.add_argument("--dpi", type=int, default=200, help="Output image DPI.")
    return parser.parse_args()


def resolve_output_path(script_dir: Path, output_arg: Path | None, unit_label: str) -> Path:
    if output_arg is not None:
        return output_arg
    safe_unit = unit_label.replace("/", "_").replace("\\", "_").replace(" ", "_")
    return script_dir / f"solution_unit_{safe_unit}.png"


def load_rows(csv_path: Path) -> list[dict]:
    with csv_path.open(newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def format_minutes(total_minutes: float) -> str:
    h, m = divmod(int(total_minutes) % 1440, 60)
    return f"{h:02d}:{m:02d}"


def row_matches_unit(row: dict, unit_query: str) -> bool:
    return row.get("Unit", "").strip() == unit_query.strip()


def _bar_bottom(row_idx: int) -> float:
    return row_idx * ROW_H + BAR_BOTTOM


def _trainid_sort_key(train_id: str) -> tuple[int, int | str]:
    text = train_id.strip()
    if text.isdigit():
        return (0, int(text))
    return (1, text)


def render(
    rows: list[dict],
    output_path: Path,
    time_offset: int,
    dpi: int,
) -> None:
    train_segs: dict[str, list[dict]] = defaultdict(list)
    for row in rows:
        train_segs[row["TrainId"]].append(row)

    # Keep color assignment deterministic: lowest TrainId gets first palette color.
    train_ids = sorted(train_segs, key=_trainid_sort_key)

    n_rows = len(train_ids)
    all_times = [int(r["Departure"]) - time_offset for r in rows] + [
        int(r["Arrival"]) - time_offset for r in rows
    ]
    t_min, t_max = min(all_times), max(all_times)
    t_span = max(1, t_max - t_min)

    fig_w = max(12, t_span / 15)
    fig_h = max(3, n_rows * ROW_H * 1.6 + 1.5)
    fig, ax = plt.subplots(figsize=(fig_w, fig_h), constrained_layout=True)

    for row_idx, train_id in enumerate(train_ids):
        fill_color, accent_color = _PALETTES[row_idx % len(_PALETTES)]
        segments = sorted(train_segs[train_id], key=lambda r: int(r["Departure"]))

        bar_btm = _bar_bottom(row_idx)

        t_first = int(segments[0]["Departure"]) - time_offset
        t_last = int(segments[-1]["Arrival"]) - time_offset

        # Render one task per TrainId using full occupancy window.
        main_bar = FancyBboxPatch(
            (t_first, bar_btm),
            t_last - t_first,
            BAR_H,
            boxstyle="square,pad=0",
            facecolor=fill_color,
            edgecolor="black",
            linewidth=0.6,
            zorder=3,
        )
        ax.add_patch(main_bar)

        top_stripe = FancyBboxPatch(
            (t_first, bar_btm + BAR_H - ACCENT_H),
            t_last - t_first,
            ACCENT_H,
            boxstyle="square,pad=0",
            facecolor=accent_color,
            edgecolor="none",
            zorder=4,
        )
        ax.add_patch(top_stripe)

        ax.text(
            (t_first + t_last) / 2,
            bar_btm + BAR_H / 2 - ACCENT_H / 2,
            f"Train {train_id}",
            ha="center",
            va="center",
            fontsize=9,
            fontweight="bold",
            color="black",
            zorder=5,
            clip_on=True,
        )

        stops: list[tuple[int, str]] = []
        for idx, seg in enumerate(segments):
            dep = int(seg["Departure"]) - time_offset
            stops.append((dep, seg["FromStation"]))
            if idx == len(segments) - 1:
                arr = int(seg["Arrival"]) - time_offset
                stops.append((arr, seg["ToStation"]))

        merged: list[tuple[int, str]] = []
        for t, station in stops:
            if merged and merged[-1][1] == station and abs(merged[-1][0] - t) < 2:
                continue
            merged.append((t, station))

        label_y_station = bar_btm - LABEL_GAP - LINE_H
        label_y_time = bar_btm - LABEL_GAP - 2 * LINE_H

        for t, station in merged:
            ax.plot([t, t], [bar_btm, bar_btm - LABEL_GAP], color="black", linewidth=0.8, zorder=6)
            ax.text(t, label_y_station, station, ha="center", va="top", fontsize=7.5, color="black", zorder=6)
            ax.text(
                t,
                label_y_time,
                format_minutes(t + time_offset),
                ha="center",
                va="top",
                fontsize=7,
                color="#444444",
                zorder=6,
            )

    y_bottom = -0.25
    y_top = n_rows * ROW_H + 0.1
    ax.set_xlim(t_min - t_span * 0.03, t_max + t_span * 0.03)
    ax.set_ylim(y_bottom, y_top)

    ax.set_yticks([])
    ax.yaxis.set_visible(False)

    ax.xaxis.set_major_locator(ticker.MultipleLocator(30))
    ax.xaxis.set_minor_locator(ticker.MultipleLocator(10))
    ax.xaxis.set_major_formatter(ticker.FuncFormatter(lambda x, _: format_minutes(x + time_offset)))
    ax.tick_params(axis="x", which="major", labelsize=9)
    plt.setp(ax.get_xticklabels(), rotation=0)

    ax.grid(which="major", axis="x", linestyle="--", linewidth=0.5, alpha=0.45, zorder=0)
    ax.grid(which="minor", axis="x", linestyle=":", linewidth=0.3, alpha=0.25, zorder=0)

    for row_idx in range(n_rows + 1):
        y = row_idx * ROW_H
        ax.axhline(y, color="#cccccc", linewidth=0.6, zorder=1)

    units = sorted({r["Unit"] for r in rows})
    unit_label = ", ".join(units)
    ax.set_title(
        f"{unit_label} across Train IDs",
        fontsize=12,
        fontweight="bold",
        pad=8,
    )

    ax.xaxis.set_ticks_position("both")
    ax.tick_params(axis="x", which="both", top=True, bottom=True, labeltop=True, labelbottom=True)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(output_path, dpi=dpi, bbox_inches="tight")
    plt.close(fig)
    print(f"Saved diagram to {output_path}")


def main() -> None:
    script_dir = Path(__file__).resolve().parent
    args = parse_args()
    rows = load_rows(args.input)

    required = {"TrainId", "FromStation", "ToStation", "Departure", "Arrival", "Unit"}
    missing = sorted(required - set(rows[0].keys())) if rows else sorted(required)
    if missing:
        raise ValueError(f"CSV missing required columns: {', '.join(missing)}")

    if args.unit:
        rows = [row for row in rows if row_matches_unit(row, args.unit)]
        if not rows:
            raise ValueError(f"No rows found for Unit '{args.unit}'.")

    units = sorted({row["Unit"].strip() for row in rows if row.get("Unit", "").strip()})
    unit_label = ", ".join(units) if units else "unknown_unit"

    output_path = resolve_output_path(script_dir, args.output, unit_label)
    render(rows, output_path, args.time_offset, args.dpi)


if __name__ == "__main__":
    main()
