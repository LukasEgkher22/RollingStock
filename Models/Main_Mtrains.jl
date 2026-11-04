include(joinpath(@__DIR__, "FinalModel_functions.jl"))

# -----------------------------------------------------------
# SETTINGS
# -----------------------------------------------------------
# Question: can extra units be avoided if additional material (empty) trains reposition units during the day?
# Candidate material trains are generated on every station pair that is already driven in the timetable,
# with the median travel time and distance of that pair. The model decides which candidates are used.

solver = "Gurobi"
mip_gap = 0.005
time_limit = 1800   # in seconds, per lexicographic stage

execution_file = "aggregated_trips.csv"
ggv_constraints = false
demand_factor = 1.0

# candidate material trains: one every `interval` minutes between the departure times in `window`
# station_pairs = nothing uses all pairs, e.g. [("KD/86", "FA/86"), ("FA/86", "KD/86")] restricts them
mtrain_settings = (interval = 60, window = (300, 1380), station_pairs = nothing)
mtrain_penalty = 100 # cost per used material train inside the operating objective

# Trade-off analysis: extra units needed if at most k new material trains may be used
run_tradeoff = true
max_tradeoff_points = 10

# -----------------------------------------------------------
# RUN
# -----------------------------------------------------------
settings = (solver = solver, mip_gap = mip_gap, time_limit = time_limit, ggv_constraints = ggv_constraints,
            demand_factor = demand_factor, mtrain_penalty = mtrain_penalty)
results = DataFrame()

# 1. Reference: only the material trains of the timetable
push!(results, run_scenario("Base"; execution_file, stages = ["balance", "extra_units", "operating"], settings...); cols = :union)

# 2. With candidate material trains: as few extra units as possible, then as few new material trains as possible
data = load_model_data(execution_file; add_mtrain_candidates = true, mtrain_settings = mtrain_settings)
stages = ["balance", "extra_units", "new_mtrains", "operating"]
with_mtrains = run_scenario("MTrains"; data, execution_file, stages, add_mtrain_candidates = true, settings...)
push!(results, with_mtrains; cols = :union)

# 3. Trade-off: how many extra units are needed if at most k new material trains are used
if run_tradeoff && haskey(with_mtrains, :NewMTrains)
    for k in 0:min(with_mtrains.NewMTrains - 1, max_tradeoff_points - 1)
        push!(results, run_scenario("MTrains_max$(k)"; data, execution_file, stages, add_mtrain_candidates = true,
                                    max_new_mtrains = k, settings...); cols = :union)
    end
end

println("\n--- MATERIAL TRAIN ANALYSIS ---")
show(results, allcols = true)
CSV.write(joinpath(project_root, "Results", "Analysis", "Comparison_MTrains_$(Dates.format(Dates.now(), "yyyy-mm-dd_HHMMSS")).csv"), results)
