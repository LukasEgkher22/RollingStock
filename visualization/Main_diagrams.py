"""
Makes the diagrams of a result (functions in Diagram_functions.py). Images go to Output/<scenario>_<timestamp>/.

Needs the unit assignment of the result: run Models/Main_assignUnits.py first.

Run with the settings below:            python Main_diagrams.py
Or one diagram from the command line:   python Main_diagrams.py train 10_910 --result GGV_2026-11-16_162530
"""

import argparse

from Diagram_functions import find_result, load_result, make_diagram

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
# Result as "<scenario>_<timestamp>" (files in Results/Analysis). None = newest result with a unit assignment.
RESULT = None

# Diagrams to make: (kind, value)
#   train   - TrainId ("10") or GGVId ("10_910"): unit order per trip, links and stored trains marked
#   unit    - unit id ("ICA_5"), several ids ("ICA_5, ERF_17") or a type ("MGA"): day plan per unit
#   fleet   - unit type ("ICA") or "all": overview of all units over the day
#   station - station ("FA/86"): units available in the inventory over the day, per type
# value "all" makes one diagram per train / GGV group / unit / station (can be many files).
DIAGRAMS = [
    ("train", "10_910"),
    ("unit", "ICA_5"),
    ("fleet", "ICA"),
    ("station", "FA/86"),
]


def main() -> None:
    parser = argparse.ArgumentParser(description="Make diagrams of a result.")
    parser.add_argument("kind", nargs="?", help="train, ggv, unit, fleet or station (default: DIAGRAMS in the script)")
    parser.add_argument("value", nargs="?", help="TrainId, GGVId, unit, type or station")
    parser.add_argument("--result", default=RESULT, help="<scenario>_<timestamp>, default: newest")
    args = parser.parse_args()

    data = load_result(find_result(args.result))
    print(f"Result: {data['tag']}")
    diagrams = [(args.kind, args.value)] if args.kind else DIAGRAMS
    for kind, value in diagrams:
        if value is None:
            parser.error("value is missing")
        try:
            make_diagram(data, kind, value)
        except ValueError as exc:  # e.g. a GGVId that does not exist in a Base result
            print(f"Skipped {kind} {value}: {exc}")


if __name__ == "__main__":
    main()
