from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
from pathlib import Path

import matplotlib.pyplot as plt
from matplotlib import colormaps
from matplotlib.colors import Normalize
from matplotlib.patches import Patch


@dataclass
class Segment:
    trip_id: int
    train_category: str
    train_id: str
    from_station: str
    to_station: str
    departure: int
    arrival: int
    demand: int
    composition: str

    @property
    def duration(self) -> int:
        return self.arrival - self.departure

    @property
    def route_label(self) -> str:
        return f"{self.from_station}->{self.to_station}"


def parse_args() -> argparse.Namespace:
    script_dir = Path(__file__).resolve().parent
    default_input = script_dir / "CompAssignments_includingMtrains_2026-05-14_15-04-38.csv"
    default_output = script_dir / "train_id_timeline.png"

    parser = argparse.ArgumentParser(
        description="Render a train-ID-based assignment timeline from an RSP output CSV."
    )
    parser.add_argument("--input", type=Path, default=default_input, help="Path to the CSV file.")
    parser.add_argument("--output", type=Path, default=default_output, help="Path to the output image.")
    parser.add_argument(
        "--train-ids",
        type=str,
        default="",
        help="Comma-separated TrainId values to include.",
    )
    parser.add_argument(
        "--category",
        type=str,
        default="",
        help="Only include rows from this TrainCategory.",
    )
    parser.add_argument(
        "--max-trains",
        type=int,
        default=80,
        help="Maximum number of TrainId lanes to plot unless --all-trains is used.",
    )
    parser.add_argument(
        "--all-trains",
        action="store_true",
        help="Plot every TrainId in the filtered dataset.",
    )
    parser.add_argument(
        "--color-by",
        choices=("demand", "category"),
        default="demand",
        help="Choose how bars are colored.",
    )
    parser.add_argument(
        "--annotate-routes",
        action="store_true",
        help="Draw route labels on bars when the plot is small enough.",
    )
    return parser.parse_args()


def load_segments(csv_path: Path) -> list[Segment]:
    with csv_path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        return [
            Segment(
                trip_id=int(row["TripId"]),
                train_category=row["TrainCategory"],
                train_id=row["TrainId"],
                from_station=row["FromStation"],
                to_station=row["ToStation"],
                departure=int(row["Departure"]),
                arrival=int(row["Arrival"]),
                demand=int(row["Demand"]),
                composition=row["Composition"],
            )
            for row in reader
        ]


def filter_segments(
    segments: list[Segment],
    category: str,
    selected_train_ids: set[str],
) -> list[Segment]:
    filtered = segments
    if category:
        filtered = [segment for segment in filtered if segment.train_category == category]
    if selected_train_ids:
        filtered = [segment for segment in filtered if segment.train_id in selected_train_ids]
    return filtered


def select_train_ids(segments: list[Segment], max_trains: int, all_trains: bool) -> list[str]:
    per_train: dict[str, list[Segment]] = {}
    for segment in segments:
        per_train.setdefault(segment.train_id, []).append(segment)

    ordered = sorted(
        per_train,
        key=lambda train_id: (
            min(segment.departure for segment in per_train[train_id]),
            int(train_id),
        ),
    )
    if all_trains:
        return ordered
    return ordered[:max_trains]


def format_minutes(total_minutes: int) -> str:
    hours, minutes = divmod(total_minutes, 60)
    return f"{hours:02d}:{minutes:02d}"


def build_category_palette(segments: list[Segment]) -> dict[str, tuple[float, float, float, float]]:
    categories = sorted({segment.train_category for segment in segments})
    palette = colormaps["tab10"].resampled(max(len(categories), 1))
    return {category: palette(index) for index, category in enumerate(categories)}


def render_timeline(
    segments: list[Segment],
    train_ids: list[str],
    output_path: Path,
    color_by: str,
    annotate_routes: bool,
) -> None:
    plotted_segments = [segment for segment in segments if segment.train_id in set(train_ids)]
    if not plotted_segments:
        raise ValueError("No rows left to plot after filtering.")

    min_time = min(segment.departure for segment in plotted_segments)
    max_time = max(segment.arrival for segment in plotted_segments)
    lane_height = 6
    lane_gap = 4
    fig_height = max(8, len(train_ids) * 0.28)
    fig, ax = plt.subplots(figsize=(18, fig_height), constrained_layout=True)

    demand_normalizer = Normalize(
        vmin=min(segment.demand for segment in plotted_segments),
        vmax=max(segment.demand for segment in plotted_segments),
    )
    demand_cmap = colormaps["viridis"]
    category_palette = build_category_palette(plotted_segments)

    train_to_segments: dict[str, list[Segment]] = {train_id: [] for train_id in train_ids}
    for segment in plotted_segments:
        train_to_segments[segment.train_id].append(segment)

    for lane_index, train_id in enumerate(train_ids):
        lane_bottom = lane_index * (lane_height + lane_gap)
        lane_segments = sorted(train_to_segments[train_id], key=lambda segment: segment.departure)

        for segment in lane_segments:
            if color_by == "demand":
                color = demand_cmap(demand_normalizer(segment.demand))
            else:
                color = category_palette[segment.train_category]

            ax.broken_barh(
                [(segment.departure, segment.duration)],
                (lane_bottom, lane_height),
                facecolors=color,
                edgecolors="black",
                linewidth=0.4,
            )

            if annotate_routes and len(train_ids) <= 30 and segment.duration >= 20:
                ax.text(
                    segment.departure + segment.duration / 2,
                    lane_bottom + lane_height / 2,
                    segment.route_label,
                    ha="center",
                    va="center",
                    fontsize=7,
                    color="white",
                )

    y_ticks = [index * (lane_height + lane_gap) + lane_height / 2 for index in range(len(train_ids))]
    ax.set_yticks(y_ticks)
    ax.set_yticklabels(train_ids)
    ax.set_ylim(-lane_gap, len(train_ids) * (lane_height + lane_gap))
    ax.set_xlim(min_time, max_time)
    ax.set_xlabel("Time (minutes)")
    ax.set_ylabel("TrainId")
    ax.set_title(f"Train assignment timeline for {len(train_ids)} TrainId lanes")
    ax.grid(axis="x", linestyle="--", linewidth=0.5, alpha=0.5)

    tick_count = min(16, max(6, (max_time - min_time) // 90))
    tick_positions = [
        min_time + step * (max_time - min_time) / max(tick_count - 1, 1)
        for step in range(tick_count)
    ]
    ax.set_xticks(tick_positions)
    ax.set_xticklabels([format_minutes(int(position)) for position in tick_positions], rotation=30, ha="right")

    if color_by == "demand":
        scalar_mappable = plt.cm.ScalarMappable(norm=demand_normalizer, cmap=demand_cmap)
        colorbar = fig.colorbar(scalar_mappable, ax=ax, pad=0.01)
        colorbar.set_label("Demand")
    else:
        legend_handles = [
            Patch(facecolor=color, edgecolor="black", label=category)
            for category, color in category_palette.items()
        ]
        ax.legend(handles=legend_handles, title="TrainCategory", loc="upper right")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(output_path, dpi=200)
    plt.close(fig)


def main() -> None:
    args = parse_args()
    train_ids_filter = {value.strip() for value in args.train_ids.split(",") if value.strip()}
    segments = load_segments(args.input)
    filtered_segments = filter_segments(segments, args.category, train_ids_filter)
    train_ids = select_train_ids(filtered_segments, args.max_trains, args.all_trains)

    if not train_ids:
        raise ValueError("No TrainId values matched the requested filters.")

    render_timeline(
        segments=filtered_segments,
        train_ids=train_ids,
        output_path=args.output,
        color_by=args.color_by,
        annotate_routes=args.annotate_routes,
    )
    print(f"Saved visualization to {args.output}")


if __name__ == "__main__":
    main()