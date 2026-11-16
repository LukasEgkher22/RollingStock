include(joinpath(@__DIR__, "FinalModel_functions.jl"))

# -----------------------------------------------------------
# SETTINGS
# -----------------------------------------------------------
solver = "Gurobi"   # "Gurobi" (needs a license) or "HiGHS" (free)
mip_gap = 0.005     # 0.5% optimality gap
time_limit = 1800   # in seconds, per lexicographic stage

# for the GGV model see Main_GGV.jl
execution_file = "aggregated_trips.csv"
ggv_constraints = false
demand_factor = 1.0 # required seats = demand_factor * demand

# Lexicographic objective, in order of priority:
# 1. units     - as few balance issues (inventory at the end of the day differs from the start)
#                and extra units (on top of the fleet) as possible, both weighted equally
#                (operating costs are included with a small weight to guide the solver)
# 2. operating - km costs + coupling/decoupling penalty
stages = ["units", "operating"]

# Reallocation times of the "Reallocation" sheet only apply to coupling/decoupling at a connection.
# Simplification: units of a train that starts or ends at a station are moved without any waiting time.
realloc_train_ends = false

# -----------------------------------------------------------
# RUN
# -----------------------------------------------------------
kpis = run_scenario("Base"; execution_file, stages, solver, mip_gap, time_limit, ggv_constraints, demand_factor,
                    parking = :fixed, realloc_train_ends)
