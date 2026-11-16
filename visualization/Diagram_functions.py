"""
Diagrams to analyse a solution with its unit assignment (run them with Main_diagrams.py).

Input: the files of one result in Results/Analysis (CompAssignments, UnitAssignment, UnitTimeline, UnitFlows,
Inventory, GGVLinks). UnitAssignment and UnitTimeline are written by Models/Main_assignUnits.py.

Diagrams:
- train:   compositions of a train (TrainId) or of all trains of a GGV group (GGVId), one lane per position,
           front of the train at the top. Shows the unit order and where units are coupled, decoupled or linked.
- unit:    day plan of one or more units: trips, time on the train, GGV links, stored trains, depot
- fleet:   overview of all units of a type (or all units) over the day
- station: units available in the station inventory over the day, per unit type (after reallocation times)
"""

from __future__ import annotations

import glob
import os
import re
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
import pandas as pd
from matplotlib.patches import Patch, Rectangle

PROJECT_ROOT = Path(__file__).resolve().parent.parent
ANALYSIS_DIR = PROJECT_ROOT / "Results" / "Analysis"
OUTPUT_DIR = Path(__file__).resolve().parent / "Output"

# ---------------------------------------------------------------------------
# Style (sizes for a 16:9 slide)
# ---------------------------------------------------------------------------
FIG_WIDTH = 16
DPI = 200
FS = {"title": 15, "label": 11, "small": 9, "tiny": 7, "axis": 11, "legend": 10}

TYPE_COLORS = {  # fixed colour per unit type, the same in every diagram
    "ICA": "#4C78A8", "ERF": "#F58518", "MGA": "#54A24B", "ICU": "#B279A2",
    "EB4DD": "#E45756", "EB5DD": "#9D755D", "EB15Talgo": "#72B7B2",
}
ACTIVITY_COLORS = {"on_train": "#BBBBBB", "ggv_link": "#F2A900", "stored": "#7E57C2", "depot": "#EEEEEE"}
UNIT_PALETTE = list(plt.get_cmap("tab20").colors)


def type_color(unit_type: str) -> str:
    if unit_type not in TYPE_COLORS:
        TYPE_COLORS[unit_type] = UNIT_PALETTE[len(TYPE_COLORS) % len(UNIT_PALETTE)]
    return TYPE_COLORS[unit_type]


def unit_type(unit_id: str) -> str:
    return unit_id.split("_")[0]


def unit_sort_key(unit_id: str):
    """ICA_2 before ICA_10."""
    base, _, number = unit_id.partition("_")
    return (base, int(number) if number.isdigit() else 10**9, number)


def format_minutes(total_minutes: float, _=None) -> str:
    h, m = divmod(int(round(total_minutes)), 60)
    return f"{h:02d}:{m:02d}" if h < 24 else f"{h - 24:02d}:{m:02d}+1"


def safe_name(text: str) -> str:
    return re.sub(r"[^\w\-]+", "_", text).strip("_")


def style_time_axis(ax, t_min: float, t_max: float) -> None:
    span = max(1, t_max - t_min)
    major = 30 if span <= 240 else 60 if span <= 720 else 120
    ax.set_xlim(t_min - span * 0.02, t_max + span * 0.02)
    ax.xaxis.set_major_locator(ticker.MultipleLocator(major))
    ax.xaxis.set_minor_locator(ticker.MultipleLocator(major / 4))
    ax.xaxis.set_major_formatter(ticker.FuncFormatter(format_minutes))
    ax.tick_params(axis="x", labelsize=FS["axis"])
    ax.grid(which="major", axis="x", linestyle="--", linewidth=0.5, alpha=0.5, zorder=0)
    ax.grid(which="minor", axis="x", linestyle=":", linewidth=0.3, alpha=0.3, zorder=0)


def save(fig, path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(path, dpi=DPI, bbox_inches="tight")
    plt.close(fig)
    print(f"Saved {path.relative_to(PROJECT_ROOT)}")
    return path


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

def find_result(tag: str | None = None) -> str:
    """Tag '<scenario>_<timestamp>' of the given or the newest result with a unit assignment."""
    tags = []
    for path in glob.glob(str(ANALYSIS_DIR / "UnitAssignment_*.csv")):
        match = re.match(r"UnitAssignment_(.+_\d{4}-\d{2}-\d{2}_\d{6})\.csv$", os.path.basename(path))
        if match:
            tags.append(match.group(1))
    if tag:
        if tag not in tags:
            raise FileNotFoundError(f"No UnitAssignment_{tag}.csv in {ANALYSIS_DIR}. Run Models/Main_assignUnits.py first.")
        return tag
    if not tags:
        raise FileNotFoundError(f"No UnitAssignment file in {ANALYSIS_DIR}. Run Models/Main_assignUnits.py first.")
    return max(tags, key=lambda t: t[-17:])  # newest timestamp


def load_result(tag: str) -> dict:
    """Reads all files of one result. Missing optional files are None."""
    dtypes = {"TrainId": str, "GGVId": str, "TrainA": str, "TrainB": str, "SourceTrainId": str, "OrderedComposition": str}

    def read(prefix, required=True):
        path = ANALYSIS_DIR / f"{prefix}_{tag}.csv"
        if not path.exists():
            if required:
                raise FileNotFoundError(path)
            return None
        return pd.read_csv(path, dtype=dtypes, keep_default_na=False, na_values=[""])

    data = {
        "tag": tag,
        "comp": read("CompAssignments"),
        "assignment": read("UnitAssignment"),
        "timeline": read("UnitTimeline"),
        "flows": read("UnitFlows"),
        "inventory": read("Inventory"),
        "links": read("GGVLinks", required=False),
    }
    data["assignment"]["SourceTrainId"] = data["assignment"]["SourceTrainId"].fillna("")
    data["output_dir"] = OUTPUT_DIR / tag
    return data


def day_window(data: dict) -> tuple[int, int]:
    comp = data["comp"]
    return int(comp.Departure.min()) - 30, int(comp.Arrival.max()) + 30


# ---------------------------------------------------------------------------
# Train / GGV group: compositions with unit order
# ---------------------------------------------------------------------------

def trains_of(data: dict, value: str) -> tuple[list[str], str]:
    """TrainIds for a TrainId or a GGVId value, and a title."""
    comp = data["comp"]
    if value in set(comp.TrainId):
        return [value], f"Train {value}"
    if "GGVId" in comp.columns and value in set(comp.GGVId):
        group = comp[comp.GGVId == value]
        trains = list(group.groupby("TrainId").Departure.min().sort_values().index)
        return trains, f"GGV group {value.replace('_', ' ')}"
    raise ValueError(f"'{value}' is neither a TrainId nor a GGVId of result {data['tag']}.")


def plot_train(data: dict, value: str) -> Path:
    """
    Compositions of a train or GGV group. One panel per train, one lane per position (front at the top).
    Each block is one unit on one trip, coloured per unit so it can be followed across trains.
    Hatched: the unit came over a GGV link or from a stored train (source train below the unit id).
    """
    trains, title = trains_of(data, value)
    asg = data["assignment"]
    rows = asg[asg.TrainId.isin(trains)]
    units = sorted(rows.UnitSpecificId.unique(), key=unit_sort_key)
    color = {u: UNIT_PALETTE[i % len(UNIT_PALETTE)] for i, u in enumerate(units)}
    t_min, t_max = rows.Departure.min(), rows.Arrival.max()

    lanes = [int(rows[rows.TrainId == t].Position.max()) for t in trains]
    heights = [n + 1.2 for n in lanes]
    fig, axes = plt.subplots(len(trains), 1, figsize=(FIG_WIDTH, max(3.5, sum(heights) * 0.55 + 1)),
                             sharex=True, squeeze=False, gridspec_kw={"height_ratios": heights})
    for ax, train, n_lanes in zip(axes[:, 0], trains, lanes):
        trips = rows[rows.TrainId == train]
        for r in trips.itertuples():
            y = n_lanes - r.Position  # position 1 (front) at the top
            via = r.Source in ("link", "stored")
            ax.add_patch(Rectangle((r.Departure, y + 0.08), r.Arrival - r.Departure, 0.84, facecolor=color[r.UnitSpecificId],
                                   edgecolor="black", linewidth=0.6, hatch="///" if via else None, zorder=3))
            label = r.UnitSpecificId + (f"\nvia {r.SourceTrainId}" if via else "")
            ax.text((r.Departure + r.Arrival) / 2, y + 0.5, label, ha="center", va="center", fontsize=FS["small"],
                    fontweight="bold", zorder=4, clip_on=True,
                    bbox=dict(facecolor="white", alpha=0.8, edgecolor="none", pad=1) if via else None)
        # station and time below every trip boundary
        stops = trips.drop_duplicates("TripId").sort_values("Departure")
        marks = [(s.Departure, s.FromStation) for s in stops.itertuples()] + [(stops.Arrival.iloc[-1], stops.ToStation.iloc[-1])]
        for k, (t, station) in enumerate(marks):
            ax.text(t, -0.15 - 0.45 * (k % 2), f"{station}\n{format_minutes(t)}", ha="center", va="top", fontsize=FS["tiny"])
        ax.set_ylim(-1.1, n_lanes)
        ax.set_yticks([n_lanes - p + 0.5 for p in range(1, n_lanes + 1)])
        ax.set_yticklabels(["front"] + [f"pos {p}" for p in range(2, n_lanes)] + (["rear"] if n_lanes > 1 else []), fontsize=FS["small"])
        ax.set_ylabel(f"Train {train}", fontsize=FS["label"], fontweight="bold")
        style_time_axis(ax, t_min, t_max)
    axes[0, 0].set_title(f"{title} - unit order per trip (hatched: via GGV link / stored train)", fontsize=FS["title"], fontweight="bold")
    axes[0, 0].tick_params(axis="x", labeltop=True)
    return save(fig, data["output_dir"] / f"train_{safe_name(value)}.png")


# ---------------------------------------------------------------------------
# Units: day plan
# ---------------------------------------------------------------------------

def _draw_unit_lane(ax, segments: pd.DataFrame, y: float, day_start: int, day_end: int, labels: bool) -> None:
    """
    Draws one unit. Consecutive trips on the same train and position are drawn as one block (thin lines mark the
    stops), so labels only appear once per train. Labels are left out where the block is too short.
    """
    min_label_width = (day_end - day_start) * 0.035
    segments = segments.reset_index(drop=True)
    blocks = []  # (start, end, TrainId, Position, first station, stop times)
    for s in segments.itertuples():
        start = day_start if pd.isna(s.Start) else s.Start
        end = day_end if pd.isna(s.End) else s.End
        if s.Activity == "trip":
            last = blocks[-1] if blocks else None
            if last and last[2] == s.TrainId and last[3] == s.Position and segments.Activity[s.Index - 1] == "on_train":
                blocks[-1] = (last[0], end, s.TrainId, s.Position, last[4], last[5] + [start])
            else:
                blocks.append((start, end, s.TrainId, s.Position, s.Station, []))
            color = type_color(s.Type)
        else:
            ax.add_patch(Rectangle((start, y + 0.38), end - start, 0.24, facecolor=ACTIVITY_COLORS.get(s.Activity, "#DDDDDD"),
                                   edgecolor="none", zorder=2))
            if labels and s.Activity == "depot" and end - start > min_label_width:
                ax.text((start + end) / 2, y + 0.5, s.Station, ha="center", va="center", fontsize=FS["tiny"], color="#555555", zorder=4)
    for start, end, train, pos, station, stops in blocks:
        ax.add_patch(Rectangle((start, y + 0.15), end - start, 0.7, facecolor=color, edgecolor="black", linewidth=0.5, zorder=3))
        for t in stops:
            ax.plot([t, t], [y + 0.15, y + 0.85], color="black", linewidth=0.4, alpha=0.5, zorder=4)
        if labels and end - start > min_label_width:
            ax.text((start + end) / 2, y + 0.5, f"{train}\n#{int(pos)}", ha="center", va="center",
                    fontsize=FS["tiny"], zorder=4, clip_on=True)
        if labels and end - start > min_label_width / 2:
            ax.text(start, y + 0.12, station, ha="left", va="top", fontsize=FS["tiny"], color="#333333", zorder=5)


def _activity_legend(ax, types) -> None:
    handles = [Patch(facecolor=type_color(t), edgecolor="black", label=f"trip ({t})") for t in sorted(types)]
    handles += [Patch(facecolor=ACTIVITY_COLORS[a], label=label) for a, label in
                [("on_train", "stays on the train"), ("ggv_link", "GGV link"), ("stored", "stored train"), ("depot", "depot")]]
    ax.legend(handles=handles, loc="upper left", bbox_to_anchor=(1.01, 1.0), fontsize=FS["legend"])


def plot_units(data: dict, units: list[str], name: str | None = None) -> Path:
    """Day plan of the given units: one lane per unit, labels with TrainId, position (#) and station."""
    timeline = data["timeline"]
    units = sorted(units, key=unit_sort_key)
    missing = [u for u in units if u not in set(timeline.Unit)]
    if missing:
        raise ValueError(f"Units not in result {data['tag']}: {missing}")
    day_start, day_end = day_window(data)
    fig, ax = plt.subplots(figsize=(FIG_WIDTH, max(2.5, 1.0 * len(units) + 1.5)))
    for i, uid in enumerate(units):
        _draw_unit_lane(ax, timeline[timeline.Unit == uid], len(units) - 1 - i, day_start, day_end, labels=True)
    ax.set_ylim(-0.2, len(units))
    ax.set_yticks([len(units) - 1 - i + 0.5 for i in range(len(units))])
    ax.set_yticklabels(units, fontsize=FS["label"], fontweight="bold")
    style_time_axis(ax, day_start, day_end)
    _activity_legend(ax, {unit_type(u) for u in units})
    trips = timeline[(timeline.Unit.isin(units)) & (timeline.Activity == "trip")]
    ax.set_title(f"Day plan: {', '.join(units) if len(units) <= 4 else name} ({len(trips)} trips)", fontsize=FS["title"], fontweight="bold")
    return save(fig, data["output_dir"] / f"unit_{safe_name(name or '_'.join(units))}.png")


def plot_fleet(data: dict, value: str = "all") -> Path:
    """All units of a type ('ICA') or of the whole fleet ('all'), one thin lane per unit."""
    timeline = data["timeline"]
    units = sorted(timeline.Unit.unique(), key=unit_sort_key)
    if value != "all":
        units = [u for u in units if unit_type(u) == value]
        if not units:
            raise ValueError(f"No units of type '{value}' in result {data['tag']}.")
    day_start, day_end = day_window(data)
    fig, ax = plt.subplots(figsize=(FIG_WIDTH, max(4, 0.17 * len(units) + 1.5)))
    for i, uid in enumerate(units):
        _draw_unit_lane(ax, timeline[timeline.Unit == uid], len(units) - 1 - i, day_start, day_end, labels=False)
    ax.set_ylim(0, len(units))
    ax.set_yticks([len(units) - 1 - i + 0.5 for i in range(len(units))])
    ax.set_yticklabels(units, fontsize=FS["tiny"] if len(units) > 40 else FS["small"])
    style_time_axis(ax, day_start, day_end)
    ax.tick_params(axis="x", labeltop=True, top=True)
    _activity_legend(ax, {unit_type(u) for u in units})
    trips = timeline[(timeline.Unit.isin(units)) & (timeline.Activity == "trip")]
    used = trips.Unit.nunique()
    ax.set_title(f"Fleet {value}: {len(units)} units, {used} used, {len(trips)} unit trips", fontsize=FS["title"], fontweight="bold")
    return save(fig, data["output_dir"] / f"fleet_{safe_name(value)}.png")


# ---------------------------------------------------------------------------
# Station inventory
# ---------------------------------------------------------------------------

def station_inventory(data: dict, station: str) -> dict[str, pd.DataFrame]:
    """
    Available units per type at a station over the day: start inventory, +1 when a unit is available after
    uncoupling (depot_in ReadyTime), -1 when it must be ready for coupling (depot_out ReadyTime).
    Same order as in the model: arrivals before departures at the same time.
    """
    flows, inventory = data["flows"], data["inventory"]
    st = flows[(flows.Station == station) & flows.Kind.isin(["depot_in", "depot_out"])].copy()
    st["Delta"] = st.Kind.map({"depot_in": 1, "depot_out": -1})
    st["Order"] = (st.Kind == "depot_out").astype(int)
    start = inventory[inventory.Station == station].set_index("Type").StartInventory
    result = {}
    for utype in sorted(set(st.Type) | set(start[start > 0].index)):
        events = st[st.Type == utype].sort_values(["ReadyTime", "Order"])
        level = int(start.get(utype, 0))
        times, levels = [], []
        for e in events.itertuples():
            level += e.Delta
            times.append(e.ReadyTime)
            levels.append(level)
        result[utype] = pd.DataFrame({"Time": times, "Units": levels, "Start": int(start.get(utype, 0))})
    return result


def plot_station(data: dict, station: str) -> Path:
    """Units available in the inventory of a station over the day, one panel per unit type."""
    series = station_inventory(data, station)
    if not series:
        raise ValueError(f"No units at station '{station}' in result {data['tag']}.")
    day_start, day_end = day_window(data)
    fig, axes = plt.subplots(len(series), 1, figsize=(FIG_WIDTH, 1.9 * len(series) + 1.2), sharex=True, squeeze=False)
    for ax, (utype, df) in zip(axes[:, 0], series.items()):
        start = df.Start.iloc[0] if len(df) else 0
        times = [day_start] + list(df.Time) + [day_end]
        levels = [start] + list(df.Units) + [df.Units.iloc[-1] if len(df) else start]
        ax.step(times, levels, where="post", color=type_color(utype), linewidth=1.8, zorder=3)
        ax.fill_between(times, levels, step="post", color=type_color(utype), alpha=0.25, zorder=2)
        low = min(levels)
        ax.axhline(low, color="black", linestyle=":", linewidth=0.8)
        ax.set_ylabel(utype, fontsize=FS["label"], fontweight="bold")
        ax.set_ylim(min(0, low) - 0.3, max(levels) + 1)
        ax.yaxis.set_major_locator(ticker.MaxNLocator(integer=True))
        ax.text(1.005, 0.5, f"start {start}\nend {levels[-1]}\nmin {low}", transform=ax.transAxes, fontsize=FS["small"], va="center")
        style_time_axis(ax, day_start, day_end)
    axes[0, 0].set_title(f"Station {station}: units available in the inventory (after reallocation times)",
                         fontsize=FS["title"], fontweight="bold")
    return save(fig, data["output_dir"] / f"station_{safe_name(station)}.png")


# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

def all_values(data: dict, kind: str) -> list[str]:
    """All values of a diagram kind, for value 'all'."""
    if kind == "train":
        return sorted(data["comp"].TrainId.unique())
    if kind == "unit":
        return sorted(data["timeline"].Unit.unique(), key=unit_sort_key)
    if kind == "station":
        return sorted(data["flows"].Station.unique())
    if kind == "ggv":
        return sorted(g for g in data["comp"].GGVId.unique() if g != "-1")
    raise ValueError(kind)


def make_diagram(data: dict, kind: str, value: str) -> list[Path]:
    """
    kind: 'train' (TrainId or GGVId), 'ggv' (GGVId, same as train), 'unit' (one id, several ids separated by
    commas, or a type like 'ICA' for all its units in one diagram), 'fleet' (type or 'all'), 'station' (station).
    value 'all' makes one diagram per train / GGV group / unit / station (not for fleet).
    """
    if value == "all" and kind != "fleet":
        return [p for v in all_values(data, kind) for p in make_diagram(data, kind, v)]
    if kind in ("train", "ggv"):
        return [plot_train(data, value)]
    if kind == "unit":
        units = [u.strip() for u in value.split(",") if u.strip()]
        if len(units) == 1 and "_" not in units[0]:  # a unit type
            units = [u for u in data["timeline"].Unit.unique() if unit_type(u) == units[0]]
            return [plot_units(data, units, name=value)]
        return [plot_units(data, units)]
    if kind == "fleet":
        return [plot_fleet(data, value)]
    if kind == "station":
        return [plot_station(data, value)]
    raise ValueError(f"Unknown diagram '{kind}'. Use train, ggv, unit, fleet or station.")
