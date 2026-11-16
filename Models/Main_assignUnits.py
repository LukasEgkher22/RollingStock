from AssignUnits_functions import run_unit_assignment

# Result to assign units to (files in Results/Analysis). None = newest result with a UnitFlows file.
# Results solved before 2026-11-16 have no UnitFlows file yet: run Models/Export_unitFlows.jl for them first.
SCENARIO = None   # e.g. "GGV" or "Base"
TIMESTAMP = None  # e.g. "2026-11-16_162530"

# Which unit is taken from the station inventory: "fifo" (available the longest) or "lifo" (arrived last)
PICK = "fifo"

if __name__ == "__main__":
    run_unit_assignment(SCENARIO, TIMESTAMP, pick=PICK)
