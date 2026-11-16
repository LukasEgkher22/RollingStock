include(joinpath(@__DIR__, "FinalModel_functions.jl"))

# -----------------------------------------------------------
# SETTINGS
# -----------------------------------------------------------
solver = "Gurobi"   # "Gurobi" (needs a license) or "HiGHS" (free)
mip_gap = 0.005     # 0.5% optimality gap
time_limit = 3600   # in seconds, per lexicographic stage

execution_file = "aggregated_trips_merged_GGV.csv"
# -----------------------------------------------------------
# GGV RULES: switch them on one by one to compare with the old model
# Old model (2026-11-08_155120): main_unit_type = true, everything else false / nothing
# -----------------------------------------------------------
main_unit_type = false     # OLD rule: trips of the same GGV group must contain the same main unit type
joint_shunting = true      # NEW: shunting allowed at the joints inside a merged TrainId
ggv_constraints = true     # NEW: every GGV link must carry at least one unit directly from train A to train B
demand_factor = 1.0 # required seats = demand_factor * demand

# Lexicographic objective, in order of priority:
# 1. units     - as few balance issues (inventory at the end of the day differs from the start)
#                and extra units (on top of the fleet) as possible, both weighted equally
#                (operating costs are included with a small weight to guide the solver)
# 2. operating - km costs + coupling/decoupling penalty
stages = ["units", "operating"]

# Units that are used for another train have to wait the decoupling time of the "Reallocation" sheet,
# also if their train ends at the station. Units moving directly over a GGV link do not wait.
realloc_train_ends = false # NEW (true)

# A whole train can stay on the track and continue as a later train without reallocation time.
# Minimum turnaround and standard turning pattern come from the "Settings" sheet. With the standard pattern
# (V) the train turns and no coupling is possible, with a code of the "Trip cutpoints" sheet coupling is
# possible as far as the code allows. Decoupling is never possible.
max_storage_time = nothing # NEW: 120 (in minutes, PLACEHOLDER: not confirmed yet), nothing = no stored trains

# -----------------------------------------------------------
# RUN
# -----------------------------------------------------------
kpis = run_scenario("GGV"; execution_file, stages, solver, mip_gap, time_limit, ggv_constraints, demand_factor,
                    parking = :fixed, realloc_train_ends, max_storage_time, main_unit_type, joint_shunting)
