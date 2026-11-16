include(joinpath(@__DIR__, "FinalModel_functions.jl"))

# Writes the UnitFlows file (input of Main_assignUnits.py) for a result that was solved before
# write_results produced it. Nothing is solved again: the compositions, GGV links and stored trains
# are read from the result files, the settings from its Summary file.
# Also rewrites the GGVLinks file of the result with the column Turn.

# Scenario and timestamp of the result, e.g. `julia Models/Export_unitFlows.jl GGV 2026-11-16_162530`
# Without arguments the values below are used.
scenario = length(ARGS) >= 1 ? ARGS[1] : "GGV"
timestamp = length(ARGS) >= 2 ? ARGS[2] : "2026-11-16_162530"

out_dir = joinpath(project_root, "Results", "Analysis")
result_file(prefix) = joinpath(out_dir, "$(prefix)_$(scenario)_$(timestamp).csv")

# Settings of the run from the Summary file
summary = readlines(joinpath(out_dir, "Summary_$(scenario)_$(timestamp).txt"))
setting(name) = begin
    line = findfirst(l -> startswith(strip(l), "- $name:"), summary)
    line === nothing ? nothing : strip(split(summary[line], ":"; limit = 2)[2])
end
data_line = summary[findfirst(l -> startswith(l, "Data:"), summary)]
execution_file = String(match(r"Data: (\S+)", data_line).captures[1])
joint_shunting = setting("joint_shunting") != "false"        # default of load_model_data: true
realloc_train_ends = setting("realloc_train_ends") != "false" # default of build_model: true
setting("add_mtrain_candidates") == "true" && error("Results with material train candidates are not supported, the candidate trips cannot be rebuilt.")

d = load_model_data(execution_file; joint_shunting = joint_shunting)
tt = d.timetable

# Compositions per trip (trips missing in CompAssignments are unused material trains)
assignments = CSV.read(result_file("CompAssignments"), DataFrame; types = Dict(:TrainId => String, :OrderedComposition => String))
trip_comp = fill(d.empty_comp_idx, d.J)
for row in eachrow(assignments)
    j = row.TripId
    (tt.TrainId[j] == row.TrainId && tt.DepartureFromStation[j] == row.Departure) ||
        error("TripId $j does not match the timetable ($(tt.TrainId[j]) at $(tt.DepartureFromStation[j]) instead of $(row.TrainId) at $(row.Departure)). " *
              "Has $execution_file changed since the run?")
    trip_comp[j] = findfirst(==(row.OrderedComposition), d.compositions)
end

# Used GGV links
links_used = NamedTuple[]
if isfile(result_file("GGVLinks"))
    link_rows = CSV.read(result_file("GGVLinks"), DataFrame; types = Dict(:TrainA => String, :TrainB => String, :Block => String))
    for row in eachrow(link_rows)
        l = findfirst(link -> tt.TrainId[link.a_trip] == row.TrainA && tt.TrainId[link.b_trip] == row.TrainB &&
                              link.station == row.Station && tt.ArrivalToStation[link.a_trip] == row.ArrivalA &&
                              tt.DepartureFromStation[link.b_trip] == row.DepartureB, d.ggv_links)
        l === nothing && error("GGV link $(row.TrainA) -> $(row.TrainB) at $(row.Station) not found in the data.")
        push!(links_used, (l = l, block = String.(split(row.Block, "-")), side_a = Symbol(row.SideA), side_b = Symbol(row.SideB)))
    end
    CSV.write(result_file("GGVLinks"), ggv_links_table(d, trip_comp, links_used))
end

# Stored trains
stored_pairs = Tuple{Int, Int}[]
if isfile(result_file("StoredTrains"))
    stored_rows = CSV.read(result_file("StoredTrains"), DataFrame; types = Dict(:TrainA => String, :TrainB => String))
    for row in eachrow(stored_rows)
        a = findfirst(j -> tt.TrainId[j] == row.TrainA && tt.ToStation[j] == row.Station && tt.ArrivalToStation[j] == row.ArrivalA, d.last_trips)
        b = findfirst(j -> tt.TrainId[j] == row.TrainB && tt.FromStation[j] == row.Station && tt.DepartureFromStation[j] == row.DepartureB, d.first_trips)
        (a === nothing || b === nothing) && error("Stored train $(row.TrainA) -> $(row.TrainB) at $(row.Station) not found in the data.")
        push!(stored_pairs, (d.last_trips[a], d.first_trips[b]))
    end
end

flows = get_unit_flows(d, trip_comp, links_used, stored_pairs; realloc_train_ends = realloc_train_ends)
CSV.write(result_file("UnitFlows"), flows)
println("Written: ", result_file("UnitFlows"), " ($(nrow(flows)) rows)")
