import argparse
import csv
from collections import defaultdict
from pathlib import Path
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
from matplotlib.patches import Patch

# ===========================================================================
# FONT SETTINGS - Adjust these values to change the look
# ===========================================================================
FS_TITLE   = 16    # Main title at the top
FS_STATION = 12    # Station names on the left (Y-axis)
FS_TIME_X  = 11    # Time labels on the bottom/top (X-axis)
FS_UNIT_ID = 10    # UnitSpecificIds next to the arrows
FS_NODE_T  = 9     # Small times at each station stop
FS_LEGEND  = 10    # The Train ID legend on the right
# ===========================================================================

# Layout Constants
ROW_HEIGHT = 1.8   # Vertical distance between station rows

_PALETTES = [
    ("#F5A623", "#8B4513"), ("#7B68EE", "#3A007D"), ("#4CAF50", "#1B5E20"),
    ("#E57373", "#B71C1C"), ("#29B6F6", "#01579B"), ("#FFF176", "#827717"),
    ("#80CBC4", "#004D40"), ("#BA68C8", "#4A148C"), ("#FF8A65", "#BF360C"),
]

def format_minutes(total_minutes: float) -> str:
    h, m = divmod(int(total_minutes) % 1440, 60)
    return f"{h:02d}:{m:02d}"

def render_standard_view(rows: list[dict], target_station: str, output_path: Path, time_offset: int):
    # 1. Filter for the target station
    filtered = [r for r in rows if r["FromStation"].strip() == target_station or r["ToStation"].strip() == target_station]
    if not filtered:
        print(f"No data for station: {target_station}")
        return

    # 2. Group by Trip (handling multiple units on one train)
    trips = defaultdict(list)
    for r in filtered:
        key = (r["TrainId"], r["FromStation"], r["ToStation"], r["Departure"], r["Arrival"])
        uid = ""#r.get("UnitSpecificId", r.get("Unit", "??")).strip()
        if uid not in trips[key]:
            trips[key].append(uid)

    # 3. Y-Axis: Stations
    involved_stations = sorted({k[1] for k in trips.keys()} | {k[2] for k in trips.keys()})
    n_stations = len(involved_stations)
    station_to_y = {stat: i * ROW_HEIGHT for i, stat in enumerate(involved_stations)}

    # 4. X-Axis: Time
    all_times = []
    for k in trips.keys():
        all_times.extend([int(k[3]) - time_offset, int(k[4]) - time_offset])
    t_min, t_max = min(all_times), max(all_times)
    t_span = max(1, t_max - t_min)

    # 5. FIGURE SIZING (Normal Frame)
    # Width proportional to time (approx 1 inch per hour)
    fig_w = max(12, t_span / 60) 
    # Height proportional to number of stations
    fig_h = max(4, n_stations * 1.2)
    
    fig, ax = plt.subplots(figsize=(fig_w, fig_h), constrained_layout=True)

    # 6. Plot movements
    train_ids = sorted({k[0] for k in trips.keys()})
    colors = {tid: _PALETTES[i % len(_PALETTES)][0] for i, tid in enumerate(train_ids)}

    for (tid, f_s, t_s, dep, arr), unit_list in trips.items():
        t0, t1 = int(dep) - time_offset, int(arr) - time_offset
        y0, y1 = station_to_y[f_s], station_to_y[t_s]
        c = colors[tid]

        # Movement Arrow
        ax.annotate("", xy=(t1, y1), xytext=(t0, y0),
                    arrowprops=dict(arrowstyle="->", color=c, lw=2.5, mutation_scale=15, shrinkA=0, shrinkB=0),
                    zorder=3)

        # Unit Labels (Stacked vertically)
        mid_x, mid_y = (t0 + t1) / 2, (y0 + y1) / 2
        ax.text(mid_x, mid_y, "\n".join(unit_list), color=c, 
                fontsize=FS_UNIT_ID, fontweight="bold", ha="center", va="center", 
                bbox=dict(facecolor='white', alpha=0.8, edgecolor='none', pad=2), zorder=5)

        # Small stop times
        ax.text(t0, y0 - 0.2, format_minutes(t0 + time_offset), fontsize=FS_NODE_T, ha="center", color="#444444")
        ax.text(t1, y1 + 0.2, format_minutes(t1 + time_offset), fontsize=FS_NODE_T, ha="center", color="#444444")

    # 7. Axis Styling
    ax.set_xlim(t_min - t_span * 0.03, t_max + t_span * 0.03)
    # Tight vertical limits to remove excess space
    ax.set_ylim(-0.5, (n_stations - 1) * ROW_HEIGHT + 0.5)
    
    ax.set_yticks([i * ROW_HEIGHT for i in range(n_stations)])
    ax.set_yticklabels(involved_stations, fontsize=FS_STATION, fontweight="bold")
    
    # Horizontal grid lines for stations
    for i in range(n_stations):
        ax.axhline(i * ROW_HEIGHT, color="#cccccc", linestyle="-", linewidth=0.8, zorder=1)

    # Time Ticks
    ax.xaxis.set_major_locator(ticker.MultipleLocator(60))
    ax.xaxis.set_major_formatter(ticker.FuncFormatter(lambda x, _: format_minutes(x + time_offset)))
    ax.xaxis.set_ticks_position("both")
    ax.tick_params(axis="x", which="both", labelsize=FS_TIME_X, top=True, bottom=True, labeltop=True, labelbottom=True)
    ax.grid(which="major", axis="x", linestyle="--", alpha=0.3)

    ax.set_title(f"Station Perspective: {target_station}", fontsize=FS_TITLE, fontweight="bold", pad=25)
    
    # Legend
    legend_handles = [Patch(facecolor=color, label=f"Train {tid}") for tid, color in colors.items()]
    ax.legend(handles=legend_handles, title="Train IDs", loc="upper left", bbox_to_anchor=(1.01, 1), fontsize=FS_LEGEND)

    # Output
    output_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(output_path, dpi=200, bbox_inches="tight")
    plt.close(fig)
    print(f"Standard diagram saved to: {output_path}")

def main():
    script_dir = Path(__file__).resolve().parent
    results_dir = script_dir.parent / "Results"
    default_csv = results_dir / "UnitAssignment_UnitPreservation_2026-06-18_143808_processed.csv"
    
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, default=default_csv)
    parser.add_argument("--station", type=str, default="VO/86")
    parser.add_argument("--offset", type=int, default=0)
    args = parser.parse_args()

    safe_name = args.station.replace("/", "_").replace("\\", "_")
    output_file = script_dir / f"station_normal_{safe_name}.png"

    try:
        with args.input.open(newline="", encoding="utf-8") as f:
            rows = list(csv.DictReader(f))
        render_standard_view(rows, args.station, output_file, args.offset)
    except FileNotFoundError:
        print(f"Error: Could not find CSV file at {args.input}")

if __name__ == "__main__":
    main()