include(joinpath(@__DIR__, "FinalModel_functions.jl"))

# -----------------------------------------------------------
# SETTINGS
# -----------------------------------------------------------
# Question: can extra units be avoided if units are parked at other depots overnight?
# The fleet size stays the same, but the start positions are free (within the parking capacity of the depots).
# Every unit that is parked at another depot than in the "Night capacity" sheet counts as a relocation.

solver = "Gurobi"
mip_gap = 0.005
time_limit = 1800   # in seconds, per lexicographic stage

execution_file = "aggregated_trips.csv"
ggv_constraints = false
demand_factor = 1.0

# Trade-off analysis: extra units needed if at most r units may be relocated (r = 0, 1, ... up to the optimum)
run_tradeoff = true
max_tradeoff_points = 10

# -----------------------------------------------------------
# RUN
# -----------------------------------------------------------
data = load_model_data(execution_file)
settings = (solver = solver, mip_gap = mip_gap, time_limit = time_limit, ggv_constraints = ggv_constraints, demand_factor = demand_factor)
results = DataFrame()

# 1. Reference: units start at the stations of the night capacity sheet
push!(results, run_scenario("Base"; data, execution_file, stages = ["balance", "extra_units", "operating"],
                            parking = :fixed, settings...); cols = :union)

# 2. Free parking: as few extra units as possible, then as few relocations as possible, then the cheapest operation
free = run_scenario("FreeParking"; data, execution_file, stages = ["balance", "extra_units", "relocations", "operating"],
                    parking = :free, settings...)
push!(results, free; cols = :union)

# 3. Trade-off: how many extra units are needed if at most r units are parked somewhere else
if run_tradeoff && haskey(free, :Relocations)
    for r in 0:min(free.Relocations - 1, max_tradeoff_points - 1)
        push!(results, run_scenario("FreeParking_max$(r)reloc"; data, execution_file,
                                    stages = ["balance", "extra_units", "relocations", "operating"],
                                    parking = :free, max_relocations = r, settings...); cols = :union)
    end
end

println("\n--- PARKING ANALYSIS ---")
show(results, allcols = true)
CSV.write(joinpath(project_root, "Results", "Analysis", "Comparison_Parking_$(Dates.format(Dates.now(), "yyyy-mm-dd_HHMMSS")).csv"), results)
