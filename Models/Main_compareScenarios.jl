include(joinpath(@__DIR__, "FinalModel_functions.jl"))

# -----------------------------------------------------------
# SETTINGS
# -----------------------------------------------------------
# Compares all measures to reduce extra units in one table:
# Base, free parking positions, additional material trains, and both combined.

solver = "Gurobi"
mip_gap = 0.005
time_limit = 1800   # in seconds, per lexicographic stage

execution_file = "aggregated_trips.csv"
ggv_constraints = false
demand_factor = 1.0

mtrain_settings = (interval = 60, window = (300, 1380), station_pairs = nothing)
mtrain_penalty = 100

# -----------------------------------------------------------
# RUN
# -----------------------------------------------------------
settings = (solver = solver, mip_gap = mip_gap, time_limit = time_limit, ggv_constraints = ggv_constraints,
            demand_factor = demand_factor, mtrain_penalty = mtrain_penalty)
data = load_model_data(execution_file)
data_mtrains = load_model_data(execution_file; add_mtrain_candidates = true, mtrain_settings = mtrain_settings)

scenarios = [
    ("Base",                data,         :fixed, ["balance", "extra_units", "operating"]),
    ("FreeParking",         data,         :free,  ["balance", "extra_units", "relocations", "operating"]),
    ("MTrains",             data_mtrains, :fixed, ["balance", "extra_units", "new_mtrains", "operating"]),
    ("FreeParking+MTrains", data_mtrains, :free,  ["balance", "extra_units", "relocations", "new_mtrains", "operating"]),
]

results = DataFrame()
for (name, scenario_data, parking, stages) in scenarios
    push!(results, run_scenario(name; data = scenario_data, execution_file, stages, parking,
                                add_mtrain_candidates = !isempty(scenario_data.candidate_trips), settings...); cols = :union)
end

println("\n--- SCENARIO COMPARISON ---")
show(results, allcols = true)
CSV.write(joinpath(project_root, "Results", "Analysis", "Comparison_Scenarios_$(Dates.format(Dates.now(), "yyyy-mm-dd_HHMMSS")).csv"), results)
