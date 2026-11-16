"""
Assigns physical units (e.g. ICA_12) to the compositions of a model result.

The model decides the ordered composition of every trip. Julia also writes the file UnitFlows, which
states for every position of every trip where its unit comes from and where it goes:
- continue:  stays on the train at a connection
- link:      moves directly to another train over a GGV link
- stored:    the whole train stays on the track and continues as a later train
- depot_in:  goes to the station inventory, available from ReadyTime
- depot_out: comes from the station inventory, must be there at ReadyTime at the latest

So the only choice left here is which unit of the inventory is taken. The units start at the stations of the
model's start inventory (night capacity + extra units). The inventory is processed in the same order as in
the model (ReadyTime, arrivals before departures), so a unit is always available if the model is feasible.
"""

from __future__ import annotations

import glob
import os
import re
from collections import defaultdict, deque
from datetime import datetime

import pandas as pd

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ANALYSIS_DIR = os.path.join(PROJECT_ROOT, "Results", "Analysis")
BASE_DAY_FILE = os.path.join(PROJECT_ROOT, "Data", "Base Day TUE.xlsx")

TRANSFER_KINDS = ("continue", "link", "stored")


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

def find_result(scenario: str | None = None, timestamp: str | None = None) -> tuple[str, str]:
    """
    Returns (scenario, timestamp) of the newest result in Results/Analysis that has a UnitFlows file.
    Scenario and/or timestamp can be fixed.
    """
    pattern = os.path.join(ANALYSIS_DIR, f"UnitFlows_{scenario or '*'}_{timestamp or '*'}.csv")
    candidates = []
    for path in glob.glob(pattern):
        match = re.match(r"UnitFlows_(.+)_(\d{4}-\d{2}-\d{2}_\d{6})\.csv$", os.path.basename(path))
        if match:
            candidates.append((match.group(2), match.group(1)))
    if not candidates:
        raise FileNotFoundError(
            f"No UnitFlows file found for {pattern}. Results solved before 2026-11-16 need "
            "Models/Export_unitFlows.jl first."
        )
    ts, scen = max(candidates)
    return scen, ts


def _read_optional(path: str, **kwargs) -> pd.DataFrame | None:
    return pd.read_csv(path, **kwargs) if os.path.exists(path) else None


def read_summary_figures(path: str) -> dict:
    """Reads the 'Key figures' and settings ('- key: value') of a Summary file."""
    figures = {}
    if not os.path.exists(path):
        return figures
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            match = re.match(r"^\s*-?\s*([A-Za-z_]+)\s*:?\s+(.+?)\s*$", line)
            if match and not line.startswith("Data") and "value" not in line:
                figures[match.group(1)] = match.group(2)
    return figures


def load_result(scenario: str, timestamp: str) -> dict:
    """Reads all files of one model result."""
    def path(prefix, ext="csv"):
        return os.path.join(ANALYSIS_DIR, f"{prefix}_{scenario}_{timestamp}.{ext}")

    str_cols = {"TrainId": str, "OrderedComposition": str, "GGVId": str, "TrainA": str, "TrainB": str}
    return {
        "scenario": scenario,
        "timestamp": timestamp,
        "comp": pd.read_csv(path("CompAssignments"), dtype=str_cols),
        "flows": pd.read_csv(path("UnitFlows")),
        "inventory": pd.read_csv(path("Inventory")),
        "links": _read_optional(path("GGVLinks"), dtype=str_cols),
        "stored": _read_optional(path("StoredTrains"), dtype=str_cols),
        "summary": read_summary_figures(path("Summary", "txt")),
    }


# ---------------------------------------------------------------------------
# Assignment
# ---------------------------------------------------------------------------

def _create_start_units(inventory: pd.DataFrame) -> tuple[dict, dict]:
    """
    Creates the units of the start inventory, numbered per type in the order of the stations.
    Returns pools {(station, type): deque of unit ids} and home station per unit.
    """
    pools = defaultdict(deque)
    home = {}
    counter = defaultdict(int)
    for row in inventory.sort_values(["Type", "Station"]).itertuples():
        for _ in range(int(row.StartInventory)):
            counter[row.Type] += 1
            uid = f"{row.Type}_{counter[row.Type]}"
            pools[(row.Station, row.Type)].append(uid)
            home[uid] = row.Station
    return pools, home


def assign_units(comp: pd.DataFrame, flows: pd.DataFrame, inventory: pd.DataFrame, pick: str = "fifo") -> dict:
    """
    Gives every position of every trip a unit id.

    # Arguments
    - comp: CompAssignments of the result
    - flows: UnitFlows of the result
    - inventory: Inventory of the result (StartInventory per station and type)
    - pick: "fifo" takes the unit that is available the longest, "lifo" the one that arrived last

    # Returns
    dict with
    - unit_of: {(trip, position): unit id}
    - end_pools: {(station, type): [unit ids]} units in the inventory at the end of the day
    - home: {unit id: start station}
    - errors: list of problems (empty if the result could be followed completely)
    """
    pools, home = _create_start_units(inventory)
    errors = []

    source = {}  # (trip, pos) -> (trip, pos) the unit comes from directly
    for row in flows[flows.Kind.isin(TRANSFER_KINDS)].itertuples():
        source[(row.ToTrip, row.ToPos)] = (row.FromTrip, row.FromPos)

    unit_of = {}

    def resolve(trip, pos):
        chain = []
        key = (trip, pos)
        while key not in unit_of:
            if key not in source:
                raise KeyError(key)
            chain.append(key)
            key = source[key]
        for k in chain:
            unit_of[k] = unit_of[key]
        return unit_of[key]

    # inventory events in model order: ReadyTime, arrivals (depot_in) before departures (depot_out)
    depot = flows[flows.Kind.isin(["depot_in", "depot_out"])].copy()
    depot["Order"] = (depot.Kind == "depot_out").astype(int)
    depot = depot.sort_values(["ReadyTime", "Order", "Time", "FromTrip", "FromPos", "ToTrip", "ToPos"])

    extra_counter = defaultdict(int)
    for row in depot.itertuples():
        key = (row.Station, row.Type)
        if row.Kind == "depot_in":
            try:
                pools[key].append(resolve(row.FromTrip, row.FromPos))
            except KeyError as exc:
                errors.append(f"Unit on trip {row.FromTrip}, position {row.FromPos} has no source ({exc}).")
        else:
            if pools[key]:
                uid = pools[key].popleft() if pick == "fifo" else pools[key].pop()
            else:
                extra_counter[row.Type] += 1
                uid = f"{row.Type}_MISSING{extra_counter[row.Type]}"
                home[uid] = row.Station
                errors.append(f"No {row.Type} available at {row.Station} at {row.ReadyTime} for trip {row.ToTrip} "
                              f"(inventory would become negative), {uid} created.")
            unit_of[(row.ToTrip, row.ToPos)] = uid

    # positions only reached by transfers (e.g. after a depot_out that came later in the sort order)
    for trip, n_units in zip(comp.TripId, comp.OrderedComposition.str.count("-") + 1):
        for pos in range(1, n_units + 1):
            if (trip, pos) not in unit_of:
                try:
                    resolve(trip, pos)
                except KeyError:
                    errors.append(f"Trip {trip}, position {pos} has no unit.")

    return {"unit_of": unit_of, "end_pools": {k: list(v) for k, v in pools.items()}, "home": home, "errors": errors}


def build_assignment_table(comp: pd.DataFrame, flows: pd.DataFrame, result: dict) -> pd.DataFrame:
    """One row per trip and position, positions counted from the front of the train in driving direction."""
    how = {}
    for row in flows.itertuples():
        if row.Kind != "depot_in":
            how[(row.ToTrip, row.ToPos)] = (row.Kind, row.FromTrip)
    train_of = dict(zip(comp.TripId, comp.TrainId))

    rows = []
    for trip in comp.itertuples(index=False):
        for pos, utype in enumerate(trip.OrderedComposition.split("-"), start=1):
            kind, from_trip = how.get((trip.TripId, pos), ("?", 0))
            row = trip._asdict()
            row.update(
                Position=pos,
                UnitSpecificId=result["unit_of"].get((trip.TripId, pos), "?"),
                Type=utype,
                Source={"depot_out": "depot"}.get(kind, kind),
                SourceTrainId=train_of.get(from_trip, "") if kind in TRANSFER_KINDS else "",
            )
            rows.append(row)
    table = pd.DataFrame(rows)
    return table.sort_values(["UnitSpecificId", "Departure", "Position"]).reset_index(drop=True)


def build_unit_timeline(assignment: pd.DataFrame, flows: pd.DataFrame, result: dict) -> pd.DataFrame:
    """
    Day plan of every unit: trips and what happens in between.
    Activities: trip, on_train (stays coupled at a connection), ggv_link, stored, depot.
    For depot, ReadyFrom/ReadyUntil are the times the unit is available in the inventory.
    """
    ready_in = {(r.FromTrip, r.FromPos): r.ReadyTime for r in flows[flows.Kind == "depot_in"].itertuples()}
    ready_out = {(r.ToTrip, r.ToPos): r.ReadyTime for r in flows[flows.Kind == "depot_out"].itertuples()}
    gap_activity = {"continue": "on_train", "link": "ggv_link", "stored": "stored", "depot": "depot"}

    rows = []
    for uid, trips in assignment.groupby("UnitSpecificId", sort=True):
        trips = trips.sort_values("Departure")
        utype = trips.Type.iloc[0]
        previous = None
        for trip in trips.itertuples():
            if previous is None:
                rows.append(dict(Unit=uid, Type=utype, Activity="depot", Station=result["home"].get(uid, trip.FromStation),
                                 ToStation=trip.FromStation, Start=None, End=trip.Departure, TrainId="", TripId=None,
                                 Position=None, ReadyFrom=None, ReadyUntil=ready_out.get((trip.TripId, trip.Position))))
            else:
                rows.append(dict(Unit=uid, Type=utype, Activity=gap_activity.get(trip.Source, trip.Source),
                                 Station=previous.ToStation, ToStation=trip.FromStation, Start=previous.Arrival,
                                 End=trip.Departure, TrainId="", TripId=None, Position=None,
                                 ReadyFrom=ready_in.get((previous.TripId, previous.Position)),
                                 ReadyUntil=ready_out.get((trip.TripId, trip.Position))))
            rows.append(dict(Unit=uid, Type=utype, Activity="trip", Station=trip.FromStation, ToStation=trip.ToStation,
                             Start=trip.Departure, End=trip.Arrival, TrainId=trip.TrainId, TripId=trip.TripId,
                             Position=trip.Position, ReadyFrom=None, ReadyUntil=None))
            previous = trip
        rows.append(dict(Unit=uid, Type=utype, Activity="depot", Station=previous.ToStation, ToStation=previous.ToStation,
                         Start=previous.Arrival, End=None, TrainId="", TripId=None, Position=None,
                         ReadyFrom=ready_in.get((previous.TripId, previous.Position)), ReadyUntil=None))

    # units that never leave the depot
    used = set(assignment.UnitSpecificId)
    for uid, station in result["home"].items():
        if uid not in used:
            rows.append(dict(Unit=uid, Type=uid.split("_")[0], Activity="depot", Station=station, ToStation=station,
                             Start=None, End=None, TrainId="", TripId=None, Position=None, ReadyFrom=None, ReadyUntil=None))
    timeline = pd.DataFrame(rows)
    for col in ["Start", "End", "TripId", "Position", "ReadyFrom", "ReadyUntil"]:
        timeline[col] = timeline[col].astype("Int64")
    return timeline


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

def _trip_of(comp, train_id, station, time, at_arrival):
    col_station, col_time = ("ToStation", "Arrival") if at_arrival else ("FromStation", "Departure")
    hit = comp[(comp.TrainId == str(train_id)) & (comp[col_station] == station) & (comp[col_time] == time)]
    return None if hit.empty else int(hit.TripId.iloc[0])


def validate(data: dict, assignment: pd.DataFrame, timeline: pd.DataFrame, result: dict) -> list[tuple[str, bool, str]]:
    """
    Checks the unit assignment against the model result. Returns (check, passed, details) per check.
    """
    comp, flows, inventory = data["comp"], data["flows"], data["inventory"]
    checks = []

    def add(name, problems, ok_text=""):
        checks.append((name, not problems, ok_text if not problems else f"{len(problems)} problems, e.g. " + "; ".join(problems[:3])))

    # 1. Every position has a unit of the right type, every flow position exists
    problems = [f"trip {r.TripId} pos {r.Position}" for r in assignment.itertuples()
                if r.UnitSpecificId == "?" or not str(r.UnitSpecificId).startswith(r.Type + "_")]
    expected = int((comp.OrderedComposition.str.count("-") + 1).sum())
    if len(assignment) != expected:
        problems.append(f"{len(assignment)} assigned positions instead of {expected}")
    add("Every position has a unit of the right type", problems, f"{expected} positions")

    # 2. Every position has exactly one source and one destination in UnitFlows
    to_count = flows[flows.Kind != "depot_in"].groupby(["ToTrip", "ToPos"]).size()
    from_count = flows[flows.Kind != "depot_out"].groupby(["FromTrip", "FromPos"]).size()
    problems = [f"{k} has {v} sources" for k, v in to_count.items() if v != 1] + \
               [f"{k} has {v} destinations" for k, v in from_count.items() if v != 1]
    if len(to_count) != expected or len(from_count) != expected:
        problems.append(f"{len(to_count)} sources / {len(from_count)} destinations for {expected} positions")
    add("UnitFlows: one source and one destination per position", problems)

    # 3. Unit paths: no overlapping trips, next trip starts where the previous ended
    problems = []
    for uid, trips in assignment.sort_values("Departure").groupby("UnitSpecificId"):
        prev = None
        for t in trips.itertuples():
            if prev is not None and (prev.ToStation != t.FromStation or prev.Arrival > t.Departure):
                problems.append(f"{uid}: {prev.TrainId} arrives {prev.ToStation} {prev.Arrival}, "
                                f"next {t.TrainId} departs {t.FromStation} {t.Departure}")
            prev = t
    add("Unit paths are continuous", problems)

    # 4. Reallocation times: a unit leaves the depot only after it became available there
    depot = timeline[(timeline.Activity == "depot") & timeline.ReadyFrom.notna() & timeline.ReadyUntil.notna()]
    problems = [f"{r.Unit} at {r.Station}: available {r.ReadyFrom}, needed {r.ReadyUntil}"
                for r in depot.itertuples() if r.ReadyFrom > r.ReadyUntil]
    add("Reallocation times respected", problems, f"{len(depot)} depot visits during the day")

    # 5. GGV links: the block units move directly from A to B, at the stated sides
    if data["links"] is not None:
        units_on = assignment.groupby("TripId").apply(
            lambda g: list(g.sort_values("Position").UnitSpecificId), include_groups=False).to_dict()
        problems = []
        for link in data["links"].itertuples():
            a = _trip_of(comp, link.TrainA, link.Station, link.ArrivalA, True)
            b = _trip_of(comp, link.TrainB, link.Station, link.DepartureB, False)
            if a is None or b is None:
                problems.append(f"{link.TrainA}->{link.TrainB}: trip not found")
                continue
            p = len(link.Block.split("-"))
            ua, ub = units_on.get(a, []), units_on.get(b, [])
            block_a = ua[:p] if link.SideA == "front" else ua[-p:]
            block_b = ub[:p] if link.SideB == "front" else ub[-p:]
            turn = getattr(link, "Turn", False) in (True, "true", "True")
            if (list(reversed(block_b)) if turn else block_b) != block_a:
                problems.append(f"{link.Station} {link.TrainA}->{link.TrainB}: A {link.SideA} {block_a}, B {link.SideB} {block_b}")
        add("GGV link blocks move directly from A to B", problems, f"{len(data['links'])} links")

    # 6. Stored trains: all units of train A continue on train B
    if data["stored"] is not None:
        units_set = assignment.groupby("TripId").UnitSpecificId.apply(set).to_dict()
        problems = []
        for st in data["stored"].itertuples():
            a = _trip_of(comp, st.TrainA, st.Station, st.ArrivalA, True)
            b = _trip_of(comp, st.TrainB, st.Station, st.DepartureB, False)
            if a is None or b is None or not units_set.get(a, set()) <= units_set.get(b, set()):
                problems.append(f"{st.Station} {st.TrainA}->{st.TrainB}")
        add("Stored trains continue as a whole", problems, f"{len(data['stored'])} stored trains")

    # 7. Start and end inventory per station and type equal the model
    start = assignment.sort_values("Departure").groupby("UnitSpecificId").first()
    first_station = {uid: result["home"][uid] for uid in result["home"]}
    start_count = pd.Series(first_station).groupby(lambda uid: (first_station[uid], uid.split("_")[0])).size()
    end_count = pd.Series({k: len(v) for k, v in result["end_pools"].items() if v})
    problems = []
    for r in inventory.itertuples():
        if start_count.get((r.Station, r.Type), 0) != r.StartInventory:
            problems.append(f"start {r.Station} {r.Type}: {start_count.get((r.Station, r.Type), 0)} vs {r.StartInventory}")
        if end_count.get((r.Station, r.Type), 0) != r.EndInventory:
            problems.append(f"end {r.Station} {r.Type}: {end_count.get((r.Station, r.Type), 0)} vs {r.EndInventory}")
    for (station, utype), units in result["end_pools"].items():
        if units and inventory[(inventory.Station == station) & (inventory.Type == utype)].empty:
            problems.append(f"end {station} {utype}: {len(units)} units, not in the model inventory")
    add("Start and end inventory equal the model", problems, f"{len(start)} units used, {len(result['home'])} in total")

    # 8. Assignment could be followed without missing units
    add("No missing units (inventory never negative)", result["errors"])

    # 9. Shunting operations: connections where units leave or join the train
    conn_pairs = flows.loc[flows.Kind == "continue", ["FromTrip", "ToTrip"]].drop_duplicates()
    leaving = set(flows.loc[flows.Kind.isin(["depot_in", "link"]), "FromTrip"])
    joining = set(flows.loc[flows.Kind.isin(["depot_out", "link"]), "ToTrip"])
    shunting = sum(1 for r in conn_pairs.itertuples() if r.FromTrip in leaving or r.ToTrip in joining)
    model_value = data["summary"].get("ShuntingOps")
    problems = [] if model_value is None or int(model_value) == shunting else [f"{shunting} here, {model_value} in the model"]
    add("Shunting operations equal the model", problems, f"{shunting}")

    return checks


# ---------------------------------------------------------------------------
# Costs and output
# ---------------------------------------------------------------------------

def calculate_costs(assignment: pd.DataFrame, n_units_per_type: dict, file_path: str = BASE_DAY_FILE) -> tuple[float, float]:
    """Unit costs (all units of the fleet) and kilometer costs (distance per unit) from the Rolling Stock sheet."""
    rs = pd.read_excel(file_path, sheet_name="Rolling Stock").set_index("Name")
    unit_cost = sum(n * rs.loc[t, "Unit cost"] for t, n in n_units_per_type.items() if t in rs.index)
    km = assignment.groupby("Type").Distance.sum()
    km_cost = sum(dist * rs.loc[t, "Kilometer costs"] for t, dist in km.items() if t in rs.index)
    return unit_cost, km_cost


def run_unit_assignment(scenario: str | None = None, timestamp: str | None = None, pick: str = "fifo") -> dict:
    """
    Assigns units to the newest (or the given) result in Results/Analysis, validates it and writes
    UnitAssignment, UnitTimeline and UnitSummary with the same scenario and timestamp as the result.
    """
    scenario, timestamp = find_result(scenario, timestamp)
    data = load_result(scenario, timestamp)
    result = assign_units(data["comp"], data["flows"], data["inventory"], pick=pick)
    assignment = build_assignment_table(data["comp"], data["flows"], result)
    timeline = build_unit_timeline(assignment, data["flows"], result)
    checks = validate(data, assignment, timeline, result)

    units_per_type = pd.Series(result["home"]).index.str.split("_").str[0].value_counts().sort_index().to_dict()
    unit_cost, km_cost = calculate_costs(assignment, units_per_type)

    trips = timeline[timeline.Activity == "trip"]
    km_per_unit = assignment.groupby("UnitSpecificId").Distance.sum()
    tag = f"{scenario}_{timestamp}"
    assignment.to_csv(os.path.join(ANALYSIS_DIR, f"UnitAssignment_{tag}.csv"), index=False)
    timeline.to_csv(os.path.join(ANALYSIS_DIR, f"UnitTimeline_{tag}.csv"), index=False)

    lines = [
        f"--- Unit assignment: {scenario} {timestamp} ---",
        f"Generated: {datetime.now():%Y-%m-%d %H:%M:%S}",
        f"Choice from the inventory: {pick}",
        "",
        "Checks:",
        *[f"  [{'OK' if ok else 'FAIL'}] {name}" + (f" ({details})" if details else "") for name, ok, details in checks],
        "",
        f"Units in total: {len(result['home'])}, used: {assignment.UnitSpecificId.nunique()}",
        *[f"  {t}: {n}" for t, n in units_per_type.items()],
        f"Unit cost: {unit_cost:,.0f}",
        f"Kilometer cost: {km_cost:,.1f} (model KmCost: {data['summary'].get('KmCost', '-')})",
        "",
        "Unit positions by source:",
        *[f"  {k}: {v}" for k, v in assignment.Source.value_counts().items()],
        "",
        f"Trips per used unit: min {trips.groupby('Unit').size().min()}, max {trips.groupby('Unit').size().max()}",
        f"Km per used unit: min {km_per_unit.min():.0f}, median {km_per_unit.median():.0f}, max {km_per_unit.max():.0f}",
    ]
    summary = "\n".join(lines) + "\n"
    with open(os.path.join(ANALYSIS_DIR, f"UnitSummary_{tag}.txt"), "w", encoding="utf-8") as fh:
        fh.write(summary)
    print(summary)
    print(f"Files written to {ANALYSIS_DIR}: UnitAssignment_{tag}.csv, UnitTimeline_{tag}.csv, UnitSummary_{tag}.txt")
    return {"assignment": assignment, "timeline": timeline, "checks": checks, "result": result}
