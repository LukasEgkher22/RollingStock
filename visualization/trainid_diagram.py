"""
trainid_diagram.py
==================
Renders a railway timetable Gantt chart from an RSP output CSV.

Layout (matching industry-style train diagrams):
  - One horizontal lane per rolling-stock unit
  - Each trip segment is a coloured rectangle spanning departure->arrival
  - Station codes + times are annotated below each stop marker
  - A thin accent stripe runs along the top of every bar

X-axis : clock time (HH:MM, derived from integer minutes in the CSV)
Y-axis : one row per unit, labelled inside the bar

Usage
-----
    python trainid_diagram.py                                # uses defaults below
    python trainid_diagram.py --input my.csv --output my.png
    python trainid_diagram.py --train-id 6                  # outputs solution_trainid_6.png
    python trainid_diagram.py --time-offset 240             # minute that maps to 00:00
"""

from __future__ import annotations

import argparse
import csv
from collections import defaultdict
from pathlib import Path

import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
from matplotlib.patches import FancyBboxPatch, Patch


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    script_dir = Path(__file__).resolve().parent
    default_input  = script_dir / "TrainID_simple_test#1.csv"

    parser = argparse.ArgumentParser(
        description="Render a railway timetable Gantt chart."
    )
    parser.add_argument("--input",       type=Path, default=default_input)
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Output image path. If omitted, the filename includes TrainId when filtered.",
    )
    parser.add_argument("--train-id",    type=str,  default="",
                        help="Filter to a single TrainId value.")
    parser.add_argument("--time-offset", type=int,  default=0,
                        help="Subtract this many minutes so the x-axis starts at 00:00. "
                             "E.g. pass 240 if minute 240 in the data means 04:00.")
    parser.add_argument("--dpi",         type=int,  default=200)
    return parser.parse_args()


def resolve_output_path(script_dir: Path, output_arg: Path | None, train_id: str) -> Path:
    if output_arg is not None:
        return output_arg
    return script_dir / f"solution_trainid_{train_id}.png"


def get_single_train_id(rows: list[dict]) -> str:
    train_ids = sorted({row["TrainId"].strip() for row in rows if row.get("TrainId", "").strip()})
    if not train_ids:
        raise ValueError("No TrainId values found in input rows.")
    if len(train_ids) > 1:
        raise ValueError(
            "Multiple TrainId values found. Use --train-id to select one specific TrainId."
        )
    return train_ids[0]


# ---------------------------------------------------------------------------
# I/O
# ---------------------------------------------------------------------------

def load_rows(csv_path: Path) -> list[dict]:
    with csv_path.open(newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def format_minutes(total_minutes: float) -> str:
    """Convert an integer minute value to HH:MM (wraps at 24 h)."""
    h, m = divmod(int(total_minutes) % 1440, 60)
    return f"{h:02d}:{m:02d}"


# Palette: bar fill colour + accent stripe colour, one pair per unit
_PALETTES = [
    ("#F5A623", "#8B4513"),   # orange  / dark-brown
    ("#7B68EE", "#3A007D"),   # medium-purple / deep purple
    ("#4CAF50", "#1B5E20"),   # green  / dark green
    ("#E57373", "#B71C1C"),   # red    / dark red
    ("#29B6F6", "#01579B"),   # light-blue / navy
    ("#FFF176", "#827717"),   # yellow / olive
    ("#80CBC4", "#004D40"),   # teal   / dark teal
]


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

# Layout constants (in data-row units)
ROW_H       = 1.0    # total height reserved per unit row
BAR_H       = 0.52   # height of the main coloured bar
BAR_BOTTOM  = 0.30   # y-offset of bar bottom within row (leaves room for labels below)
LABEL_GAP   = 0.04   # gap between bar bottom and first label line
LINE_H      = 0.13   # vertical spacing between label lines


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
    train_id_label: str,
    chart_title: str | None = None,
    color_by_train_id: bool = False,
    show_color_legend: bool = False,
    color_legend_title: str = "Items",
) -> None:
    # ---- group by unit, preserve first-departure order ----
    unit_segs: dict[str, list[dict]] = defaultdict(list)
    for row in rows:
        unit_segs[row["Unit"]].append(row)

    units = sorted(unit_segs, key=lambda u: int(min(r["Departure"] for r in unit_segs[u])))

    n_units = len(units)
    all_times = [int(r["Departure"]) - time_offset for r in rows] + \
                [int(r["Arrival"])   - time_offset for r in rows]
    t_min, t_max = min(all_times), max(all_times)
    t_span = t_max - t_min

    # ---- figure size ----
    fig_w = max(12, t_span / 15)          # ~1 px per minute at 15 min/unit-width
    fig_h = max(3,  n_units * ROW_H * 1.6 + 1.5)
    fig, ax = plt.subplots(figsize=(fig_w, fig_h), constrained_layout=True)

    color_keys: list[str]
    if color_by_train_id:
        color_keys = sorted({row["TrainId"].strip() for row in rows if row.get("TrainId", "").strip()}, key=_trainid_sort_key)
    else:
        color_keys = units

    color_palette = {
        key: _PALETTES[index % len(_PALETTES)][0]
        for index, key in enumerate(color_keys)
    }

    for row_idx, unit in enumerate(units):
        fill_color, _accent_color = _PALETTES[row_idx % len(_PALETTES)]
        segments = sorted(unit_segs[unit], key=lambda r: int(r["Departure"]))

        bar_btm = _bar_bottom(row_idx)

        # ---- draw each segment bar ----
        for seg in segments:
            t0 = int(seg["Departure"]) - time_offset
            t1 = int(seg["Arrival"])   - time_offset
            width = t1 - t0
            color_key = seg["TrainId"].strip() if color_by_train_id else unit
            segment_fill = color_palette.get(color_key, fill_color)

            # Main fill
            bar = FancyBboxPatch(
                (t0, bar_btm), width, BAR_H,
                boxstyle="square,pad=0",
                facecolor=segment_fill, edgecolor="black", linewidth=0.6, zorder=3,
            )
            ax.add_patch(bar)

            # Draw unit label in every individual segment block.
            ax.text(
                t0 + width / 2,
                bar_btm + BAR_H / 2,
                unit,
                ha="center", va="center",
                fontsize=9, fontweight="bold", color="black", zorder=5,
                clip_on=True,
            )

        # ---- collect stop events (station, time) for labels below bar ----
        # Each segment contributes its departure stop; the very last segment
        # also contributes its arrival stop.
        stops: list[tuple[int, str, str]] = []   # (time_adj, station, role)
        for idx, seg in enumerate(segments):
            t0 = int(seg["Departure"]) - time_offset
            stops.append((t0, seg["FromStation"], "dep"))
            if idx == len(segments) - 1:
                t1 = int(seg["Arrival"]) - time_offset
                stops.append((t1, seg["ToStation"], "arr"))

        # Merge consecutive duplicate stations (shared stop between two segments)
        merged: list[tuple[int, str]] = []
        for t, station, _role in stops:
            if merged and merged[-1][1] == station and abs(merged[-1][0] - t) < 2:
                pass   # same stop already recorded
            else:
                merged.append((t, station))

        # Draw stop marker and labels
        label_y_station = bar_btm - LABEL_GAP - LINE_H
        label_y_time    = bar_btm - LABEL_GAP - 2 * LINE_H

        for t, station in merged:
            # Small vertical tick from bar bottom down to station label
            ax.plot([t, t], [bar_btm, bar_btm - LABEL_GAP],
                    color="black", linewidth=0.8, zorder=6)
            ax.text(t, label_y_station, station,
                    ha="center", va="top",
                    fontsize=7.5, color="black", zorder=6)
            ax.text(t, label_y_time, format_minutes(t + time_offset),
                    ha="center", va="top",
                    fontsize=7, color="#444444", zorder=6)

    # ---- axes ----
    y_bottom = -0.25
    y_top    = n_units * ROW_H + 0.1
    ax.set_xlim(t_min - t_span * 0.03, t_max + t_span * 0.03)
    ax.set_ylim(y_bottom, y_top)

    # Hide y-axis ticks (labels live inside the bars)
    ax.set_yticks([])
    ax.yaxis.set_visible(False)

    # X-axis: HH:MM ticks every 30 min, minor every 10 min
    ax.xaxis.set_major_locator(ticker.MultipleLocator(30))
    ax.xaxis.set_minor_locator(ticker.MultipleLocator(10))
    ax.xaxis.set_major_formatter(
        ticker.FuncFormatter(lambda x, _: format_minutes(x + time_offset))
    )
    ax.tick_params(axis="x", which="major", labelsize=9)
    plt.setp(ax.get_xticklabels(), rotation=0)

    ax.grid(which="major", axis="x", linestyle="--", linewidth=0.5, alpha=0.45, zorder=0)
    ax.grid(which="minor", axis="x", linestyle=":",  linewidth=0.3, alpha=0.25, zorder=0)

    # Horizontal row separator lines
    for row_idx in range(n_units + 1):
        y = row_idx * ROW_H
        ax.axhline(y, color="#cccccc", linewidth=0.6, zorder=1)

    # Title
    resolved_title = chart_title if chart_title else f"Train ID - {train_id_label}"
    ax.set_title(resolved_title, fontsize=12, fontweight="bold", pad=8)

    if show_color_legend and color_palette:
        legend_handles = [
            Patch(facecolor=color, edgecolor="black", label=label)
            for label, color in color_palette.items()
        ]
        ax.legend(
            handles=legend_handles,
            title=color_legend_title,
            loc="upper left",
            bbox_to_anchor=(1.01, 1.0),
            borderaxespad=0.0,
            fontsize=8,
        )

    # Put x-axis on top as well (mirrors industry diagrams)
    ax.xaxis.set_ticks_position("both")
    ax.tick_params(axis="x", which="both", top=True, bottom=True, labeltop=True, labelbottom=True)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(output_path, dpi=dpi, bbox_inches="tight")
    plt.close(fig)
    print(f"Saved diagram to {output_path}")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    script_dir = Path(__file__).resolve().parent
    args = parse_args()
    rows = load_rows(args.input)

    if args.train_id:
        rows = [r for r in rows if r["TrainId"] == args.train_id]
        if not rows:
            raise ValueError(f"No rows found for TrainId '{args.train_id}'.")

    selected_train_id = args.train_id.strip() if args.train_id else get_single_train_id(rows)
    output_path = resolve_output_path(script_dir, args.output, selected_train_id)
    render(rows, output_path, args.time_offset, args.dpi, selected_train_id)


if __name__ == "__main__":
    main()
