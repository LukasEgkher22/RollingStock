import argparse
import csv
from collections import defaultdict
from pathlib import Path
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
from matplotlib.patches import Patch

# ---------------------------------------------------------------------------
# Styling Constants
# ---------------------------------------------------------------------------
ROW_H = 2.5  # Vertical distance between stations
_PALETTES = [
    ("#F5A623", "#8B4513"), ("#7B68EE", "#3A007D"), ("#4CAF50", "#1B5E20"),
    ("#E57373", "#B71C1C"), ("#29B6F6", "#01579B"), ("#FFF176", "#827717"),
    ("#80CBC4", "#004D40"), ("#BA68C8", "#4A148C"), ("#FF8A65", "#BF360C"),
]

def format_minutes(total_minutes: float) -> str:
    h, m = divmod(int(total_minutes) % 1440, 60)
    return f"{h:02d}:{m:02d}"

# ---------------------------------------------------------------------------
# Data Processing
# ---------------------------------------------------------------------------

def render_station_arrows(rows: list[dict], target_station: str, output_path: Path, time_offset: int):
    # 1. Filter rows involving target station
    filtered = [
        r for r in rows 
        if r["FromStation"].strip() == target_station or r["ToStation"].strip() == target_station
    ]

    if not filtered:
        print(f"Error: No data found for station '{target_station}'")
        return

    # 2. Group by "Trip" to handle multiple UnitSpecificIds on the same train
    # Key = (TrainId, FromStation, ToStation, Departure, Arrival)
    trips = defaultdict(list)
    for r in filtered:
        key = (r["TrainId"], r["FromStation"], r["ToStation"], r["Departure"], r["Arrival"])
        # Use UnitSpecificId if available, else fallback to Unit
        unit_id = r.get("UnitSpecificId", r.get("Unit", "??")).strip()
        if unit_id not in trips[key]:
            trips[key].append(unit_id)

    # 3. Setup Y-axis (Involved Stations)
    involved_stations = sorted({k[1] for k in trips.keys()} | {k[2] for k in trips.keys()})
    station_to_y = {stat: i * ROW_H for i, stat in enumerate(involved_stations)}
    n_stations = len(involved_stations)

    # 4. Color Palette by TrainId
    unique_trains = sorted({k[0] for k in trips.keys()})
    train_colors = {tid: _PALETTES[i % len(_PALETTES)][0] for i, tid in enumerate(unique_trains)}

    # 5. Calculate X-axis Bounds
    all_times = []
    for k in trips.keys():
        all_times.extend([int(k[3]) - time_offset, int(k[4]) - time_offset])
    t_min, t_max = min(all_times), max(all_times)
    t_span = max(1, t_max - t_min)

    # 6. Plotting
    fig_w = max(14, t_span / 10)
    fig_h = max(6, n_stations * 1.8)
    fig, ax = plt.subplots(figsize=(fig_w, fig_h), constrained_layout=True)

    for (tid, from_s, to_s, dep_raw, arr_raw), unit_list in trips.items():
        t_dep = int(dep_raw) - time_offset
        t_arr = int(arr_raw) - time_offset
        y_from = station_to_y[from_s]
        y_to = station_to_y[to_s]
        color = train_colors[tid]

        # Draw Movement Arrow
        ax.annotate(
            "", xy=(t_arr, y_to), xytext=(t_dep, y_from),
            arrowprops=dict(arrowstyle="->", color=color, lw=2.5, mutation_scale=15, shrinkA=0, shrinkB=0),
            zorder=3
        )

        # Labels: Stacked UnitSpecificIds
        # Join list with newlines to place them below each other
        label_text = "\n".join(unit_list)
        
        mid_x = (t_dep + t_arr) / 2
        mid_y = (y_from + y_to) / 2
        
        ax.text(
            mid_x, mid_y, label_text,
            color=color, fontsize=8.5, fontweight="bold",
            ha="center", va="center",
            # White bbox to prevent overlap confusion
            bbox=dict(facecolor='white', alpha=0.8, edgecolor='none', pad=2),
            zorder=5
        )

        # Time labels near the stations
        ax.text(t_dep, y_from - 0.25, format_minutes(t_dep + time_offset), 
                fontsize=7, ha="center", color="#666666", zorder=4)
        ax.text(t_arr, y_to + 0.25, format_minutes(t_arr + time_offset), 
                fontsize=7, ha="center", color="#666666", zorder=4)

    # 7. Axes & Grid
    ax.set_xlim(t_min - t_span * 0.05, t_max + t_span * 0.05)
    ax.set_ylim(-ROW_H/2, (n_stations - 1) * ROW_H + ROW_H/2)
    
    ax.set_yticks([i * ROW_H for i in range(n_stations)])
    ax.set_yticklabels(involved_stations, fontsize=11, fontweight="bold")
    
    for i in range(n_stations):
        ax.axhline(i * ROW_H, color="#dddddd", linestyle="-", linewidth=0.8, zorder=1)

    ax.xaxis.set_major_locator(ticker.MultipleLocator(30))
    ax.xaxis.set_major_formatter(ticker.FuncFormatter(lambda x, _: format_minutes(x + time_offset)))
    ax.xaxis.set_ticks_position("both")
    ax.tick_params(axis="x", which="both", top=True, bottom=True, labeltop=True, labelbottom=True)
    ax.grid(which="major", axis="x", linestyle="--", alpha=0.3)

    title = f"Station View: {target_station}"
    ax.set_title(title, fontsize=14, fontweight="bold", pad=30)
    
    # Legend
    legend_handles = [Patch(facecolor=color, label=f"Train {tid}") for tid, color in train_colors.items()]
    ax.legend(handles=legend_handles, title="Train IDs", loc="upper left", bbox_to_anchor=(1.02, 1))

    output_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(output_path, dpi=200, bbox_inches="tight")
    plt.close(fig)
    print(f"Success! Diagram with stacked units saved to: {output_path}")

# ---------------------------------------------------------------------------
# Main Entry
# ---------------------------------------------------------------------------

def main():
    script_dir = Path(__file__).resolve().parent
    results_dir = script_dir.parent / "Results"
    
    # Default filename provided in your prompt
    default_csv = results_dir / "UnitAssignment_SimpleModel_2026-06-18_122537_processed.csv"
    
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, default=default_csv)
    parser.add_argument("--station", type=str, default="KD/86")
    parser.add_argument("--offset", type=int, default=0)
    args = parser.parse_args()

    # Handle the / in KD/86 for the file name
    safe_station = args.station.replace("/", "_").replace("\\", "_")
    output_file = script_dir / f"station_stacked_{safe_station}.png"

    try:
        rows = []
        with args.input.open(newline="", encoding="utf-8") as f:
            rows = list(csv.DictReader(f))
        
        render_station_arrows(rows, args.station, output_file, args.offset)
    except FileNotFoundError:
        print(f"Error: Could not find CSV at {args.input}")

if __name__ == "__main__":
    main()