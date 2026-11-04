using CSV
using DataFrames
using JuMP
import Gurobi
import HiGHS
using XLSX
using Statistics
import Dates

include(joinpath(@__DIR__, "CompositionModel_functions.jl"))

# -----------------------------------------------------------
# DATA
# -----------------------------------------------------------

"""
Links the trips of every train in chronological order.

Instead of artificial "Start" and "End" trips, every train has a first trip (units leave the depot
at its FromStation) and a last trip (units enter the depot at its ToStation). Two consecutive trips
of the same train form a connection, where coupling or decoupling can happen.

# Arguments
- `timetable::DataFrame`: Timetable with an `Index` column

# Returns
- `connections::DataFrame`: One row per connection, including the incoming (`TripIn`) and
  outgoing (`TripOut`) trip index
- `first_trips::Vector{Int}`: Index of the first trip of every train
- `last_trips::Vector{Int}`: Index of the last trip of every train
"""
function build_trip_connections(timetable)
    connections = DataFrame(
        TrainId = String[], FromStation = String[], ConnectionStation = String[], ToStation = String[],
        ArrivalAtConnection = Int[], DepartureFromConnection = Int[], TripIn = Int[], TripOut = Int[]
    )
    first_trips = Int[]
    last_trips = Int[]

    for g in groupby(timetable, :TrainId)
        trips = sort(g, :DepartureFromStation).Index
        push!(first_trips, trips[1])

        for i in 1:(length(trips) - 1)
            j_in, j_out = trips[i], trips[i+1]
            if timetable.ToStation[j_in] != timetable.FromStation[j_out]
                # the train does not continue from the same station -> treat as two separate rotations
                println("Warning: TrainId $(timetable.TrainId[j_in]) jumps from $(timetable.ToStation[j_in]) to $(timetable.FromStation[j_out]).")
                push!(last_trips, j_in)
                push!(first_trips, j_out)
                continue
            end
            push!(connections, (
                TrainId = timetable.TrainId[j_in],
                FromStation = timetable.FromStation[j_in],
                ConnectionStation = timetable.ToStation[j_in],
                ToStation = timetable.ToStation[j_out],
                ArrivalAtConnection = timetable.ArrivalToStation[j_in],
                DepartureFromConnection = timetable.DepartureFromStation[j_out],
                TripIn = j_in,
                TripOut = j_out
            ))
        end
        push!(last_trips, trips[end])
    end

    return connections, first_trips, last_trips
end


"""
Generates candidate material (empty) trains to reposition units during the day.

For every station pair that is already driven in the timetable, the median travel time and distance
are used to create one candidate trip every `interval` minutes within `window`. A candidate is only
used if the model assigns a composition to it (otherwise it stays "empty").

# Arguments
- `timetable::DataFrame`: The timetable (used to get travel times, distances and electrification)
- `interval::Int`: Minutes between two candidates on the same station pair
- `window::Tuple{Int, Int}`: First and last departure time (minutes after midnight)
- `station_pairs`: Optional vector of (FromStation, ToStation) tuples to restrict the candidates

# Returns
- `DataFrame`: Candidate trips with the same columns as the timetable
"""
function generate_M_train_candidates(timetable; interval = 60, window = (300, 1380), station_pairs = nothing)
    pairs = combine(groupby(timetable, [:FromStation, :ToStation]),
        [:DepartureFromStation, :ArrivalToStation] => ((d, a) -> round(Int, median(a .- d))) => :TravelTime,
        :Distance_KM => median => :Distance_KM,
        :Electrified => all => :Electrified # only electrified if every trip on this pair is electrified
    )
    if station_pairs !== nothing
        filter!(row -> (row.FromStation, row.ToStation) in station_pairs, pairs)
    end

    candidates = DataFrame()
    k = 0
    for row in eachrow(pairs), t in window[1]:interval:window[2]
        k += 1
        candidate = (
            TrainCategory = "M",
            TrainId = "MC$k",
            FromStation = row.FromStation,
            DepartureFromStation = t,
            ToStation = row.ToStation,
            ArrivalToStation = t + row.TravelTime,
            Demand = 0,
            Distance_KM = row.Distance_KM,
            Electrified = row.Electrified
        )
        if hasproperty(timetable, :GGVId)
            candidate = merge(candidate, (GGVId = "-1",))
        end
        push!(candidates, candidate)
    end

    println("Generated $(nrow(candidates)) material train candidates on $(nrow(pairs)) station pairs.")
    return candidates
end


"""
Determines the reallocation times of every unit type at every station from the "Reallocation" and "Settings" sheets.

For every combination the first available value is used: the entry of this type at this station,
the wildcard entry ("*") of this station, the default of the settings sheet.

# Arguments
- `reallocation::DataFrame`: The "Reallocation" sheet
- `settings::Matrix`: The raw "Settings" sheet (name in the first column, value in the second column)
- `unit_names::Vector{String}`: Names of the unit types
- `stations::Vector{String}`: Names of the stations

# Returns
- `realloc_couple::Matrix{Int}`: [m, s] minutes a unit must be in the depot before it can be coupled
- `realloc_uncouple::Matrix{Int}`: [m, s] minutes after uncoupling before a unit is available in the depot
"""
function get_reallocation_times(reallocation, settings, unit_names, stations)
    setting(name) = settings[findfirst(row -> isequal(settings[row, 1], name), 1:size(settings, 1)), 2]
    default_couple = Int(setting("Default reallocation coupling"))
    default_uncouple = Int(setting("Default reallocation uncoupling"))

    entries = Dict((string(row.Station), string(row."Rolling Stock type")) =>
                   (Int(row."Reallocation coupling"), Int(row."Reallocation uncoupling")) for row in eachrow(reallocation))

    realloc_couple = fill(default_couple, length(unit_names), length(stations))
    realloc_uncouple = fill(default_uncouple, length(unit_names), length(stations))
    for (m, unit) in enumerate(unit_names), (s, station) in enumerate(stations)
        times = get(entries, (station, unit), get(entries, (station, "*"), nothing))
        if times !== nothing
            realloc_couple[m, s], realloc_uncouple[m, s] = times
        end
    end
    return realloc_couple, realloc_uncouple
end


"""
Reads and prepares all data needed for the model.

# Arguments
- `execution_file::String`: Timetable file in the DataManipulated folder
- `add_mtrain_candidates::Bool`: If true, candidate material trains are added (see `generate_M_train_candidates`)
- `mtrain_settings::NamedTuple`: Keyword arguments for `generate_M_train_candidates`

# Returns
- `NamedTuple` with the timetable, connections, compositions and all parameters of the model
"""
function load_model_data(execution_file; add_mtrain_candidates = false, mtrain_settings = (;))
    timetable = CSV.read(joinpath(project_root, "DataManipulated", execution_file), DataFrame)
    for col in [:TrainCategory, :TrainId, :FromStation, :ToStation]
        timetable[!, col] = string.(timetable[!, col])
    end
    if hasproperty(timetable, :GGVId)
        timetable.GGVId = string.(timetable.GGVId)
    end
    timetable.IsCandidate = falses(nrow(timetable))

    if add_mtrain_candidates
        candidates = generate_M_train_candidates(timetable; mtrain_settings...)
        candidates.IsCandidate = trues(nrow(candidates))
        timetable = vcat(timetable, candidates)
    end

    sort!(timetable, [:TrainId, :DepartureFromStation])
    timetable.Index = 1:nrow(timetable)

    connections, first_trips, last_trips = build_trip_connections(timetable)

    # Read specific sheets from Excel file
    excel_file = XLSX.readxlsx(joinpath(project_root, "Data", "Base Day TUE.xlsx"))
    RS_Data = DataFrame(XLSX.gettable(excel_file["Rolling Stock"]))
    compositions_raw = DataFrame(XLSX.gettable(excel_file["Composition groups"], header=false))[!, 1]
    night_capacity = DataFrame(XLSX.gettable(excel_file["Night capacity"]))
    cutpoints = DataFrame(XLSX.gettable(excel_file["Trip cutpoints"]))
    shunting_operations = DataFrame(XLSX.gettable(excel_file["Shunting operations"]))
    system_mapping = DataFrame(XLSX.gettable(excel_file["Train system mapping"]))
    reallocation = DataFrame(XLSX.gettable(excel_file["Reallocation"]))
    settings_sheet = XLSX.getdata(excel_file["Settings"])

    # "empty" composition: a material train that is not used
    push!(compositions_raw, "empty")
    unit_names = String.(RS_Data.Name)

    compositions, comp_units, comp_number = get_ordered_compositions(compositions_raw, unit_names)
    empty_comp_idx = findfirst(==("empty"), compositions)
    C = length(compositions)
    M = length(unit_names)

    # Normalized composition names (e.g. "1xERF, 1xICA") for the output, so the visualization scripts keep working
    normalized_names = [c == empty_comp_idx ? "empty" :
        join(sort(["$(comp_number[c, m])x$(unit_names[m])" for m in 1:M if comp_number[c, m] > 0]), ", ")
        for c in 1:C]

    coupled_dict, decoupled_dict = get_coupling_matrices(comp_number, unit_names)
    comp_costs, comp_seats = get_composition_details(compositions, RS_Data[!, ["Kilometer costs", "Seats"]], comp_number)

    # compositions containing electric units are not allowed on non-electrified trips
    electrified_comps = [c for c in 1:C if any((RS_Data.Electrified[m] == 1) && (comp_number[c, m] > 0) for m in 1:M)]

    # Feasible transitions (c1, c2) per connection based on the shunt code of the connection station
    feasible_pairs, connection_codes = get_feasible_transitions_per_connection(
        connections, timetable, comp_units, cutpoints, shunting_operations, system_mapping
    )
    x_index = [(c1, c2, n) for n in 1:nrow(connections) for (c1, c2) in feasible_pairs[n]]

    # Transitions without coupling or decoupling: identical composition, or exactly reversed if the train turns
    shunt_rules = get_shunt_rules(shunting_operations)
    turns(n) = haskey(shunt_rules, connection_codes[n]) && shunt_rules[connection_codes[n]].turn
    no_change_pairs = [[(c1, c2) for (c1, c2) in feasible_pairs[n]
                        if comp_units[c2] == (turns(n) ? reverse(comp_units[c1]) : comp_units[c1])]
                       for n in 1:nrow(connections)]

    # Stations: all timetable stations and all depots from the night capacity sheet
    depot_stations = unique(string.(night_capacity.Station))
    stations = sort(unique(vcat(timetable.FromStation, timetable.ToStation, depot_stations)))
    S = length(stations)

    realloc_couple, realloc_uncouple = get_reallocation_times(reallocation, settings_sheet, unit_names, stations)

    # night_start[m, s] - number of units of type m parked at station s at the start of the day
    # parking_meters[m, s] - maximum train length (in meters) of type m that can be parked at station s
    night_start = zeros(Int, M, S)
    parking_meters = zeros(Float64, M, S)
    for row in eachrow(night_capacity)
        m = findfirst(==(string(row."Rolling stock types")), unit_names)
        s = findfirst(==(string(row.Station)), stations)
        (m === nothing || s === nothing) && continue
        night_start[m, s] = row."Start Limit (count)"
        parking_meters[m, s] = row."Start Limit (meters)"
    end

    return (
        execution_file = execution_file,
        timetable = timetable,
        connections = connections,
        first_trips = first_trips,
        last_trips = last_trips,
        RS_Data = RS_Data,
        unit_names = unit_names,
        compositions = compositions,
        comp_units = comp_units,
        comp_number = comp_number,
        normalized_names = normalized_names,
        empty_comp_idx = empty_comp_idx,
        coupled_dict = coupled_dict,
        decoupled_dict = decoupled_dict,
        comp_costs = comp_costs,
        comp_seats = comp_seats,
        electrified_comps = electrified_comps,
        feasible_pairs = feasible_pairs,
        connection_codes = connection_codes,
        x_index = x_index,
        no_change_pairs = no_change_pairs,
        stations = stations,
        depot_stations = depot_stations,
        night_start = night_start,
        parking_meters = parking_meters,
        realloc_couple = realloc_couple,
        realloc_uncouple = realloc_uncouple,
        candidate_trips = findall(timetable.IsCandidate),
        C = C, M = M, J = nrow(timetable), N = nrow(connections), S = S
    )
end


# -----------------------------------------------------------
# MODEL
# -----------------------------------------------------------

"""
Creates an empty JuMP model with the chosen solver ("Gurobi" or "HiGHS").
"""
function create_model(solver; mip_gap = 0.005, time_limit = 3600)
    if solver == "Gurobi"
        model = Model(Gurobi.Optimizer)
        set_optimizer_attribute(model, "MIPGap", mip_gap)
        set_optimizer_attribute(model, "TimeLimit", time_limit)
    elseif solver == "HiGHS"
        model = Model(HiGHS.Optimizer)
        set_optimizer_attribute(model, "mip_rel_gap", mip_gap)
        set_optimizer_attribute(model, "time_limit", Float64(time_limit))
    else
        error("Unknown solver: $solver")
    end
    return model
end


"""
Builds the rolling stock composition model without artificial "Start"/"End" trips.

Units are taken from the station inventory when a train starts or units are coupled, and returned
to the inventory when a train ends or units are decoupled. The inventory of every station is tracked
event by event over the day and must never become negative. At the end of the day the inventory
should be the same as at the start (cyclic day), deviations are measured by `shortage`/`excess`.

The model contains the following objective expressions, which can be combined lexicographically
(see `solve_lexicographic!`): `obj_units` (= `obj_balance` + `obj_extra_units`), `obj_balance`,
`obj_extra_units`, `obj_relocations`, `obj_new_mtrains`, `obj_operating` (and `obj_km`, `obj_shunting` for reporting).

# Arguments
- `data::NamedTuple`: Output of `load_model_data`
- `solver`, `mip_gap`, `time_limit`: Solver settings
- `parking::Symbol`: `:fixed` (units start at the stations of the night capacity sheet) or `:free`
  (the units of the fleet can be parked at any depot station, every moved unit counts as a relocation)
- `demand_factor::Float64`: Required seats = demand_factor * demand
- `realloc_train_ends::Bool`: If true, the reallocation times also apply when a train starts or ends at
  a station, otherwise only to coupling and decoupling at a connection
- `ggv_constraints::Bool`: If true, trips of the same GGVId (or TrainId) need the same main unit type
- `max_extra_units`, `max_relocations`, `max_new_mtrains`: Optional upper bounds (epsilon constraints)
- `km_buff`, `v_penalty`, `mtrain_penalty`: Weights inside the operating cost objective

# Returns
- `model::Model`
"""
function build_model(data; solver = "Gurobi", mip_gap = 0.005, time_limit = 3600,
                     parking = :fixed, demand_factor = 1.0, realloc_train_ends = true, ggv_constraints = false,
                     max_extra_units = nothing, max_relocations = nothing, max_new_mtrains = nothing,
                     km_buff = 0.001, v_penalty = 100, mtrain_penalty = 100)
    d = data
    C, M, J, N, S = d.C, d.M, d.J, d.N, d.S
    tt = d.timetable
    station_idx = Dict(s => i for (i, s) in enumerate(d.stations))

    model = create_model(solver; mip_gap = mip_gap, time_limit = time_limit)

    # ----------- Variables -----------

    # y[c, j] = 1 if trip j is served by composition c
    @variable(model, y[c=1:C, j=1:J], Bin)

    # x[(c1, c2, n)] = 1 if composition c1 arrives and composition c2 departs in connection n
    # only defined for feasible transitions (c1, c2) of connection n
    @variable(model, x[d.x_index], Bin)

    # extra_units[m, s] - units of type m needed on top of the fleet, starting at station s
    @variable(model, extra_units[m=1:M, s=1:S] >= 0, Int)

    # shortage/excess[m, s] - difference between the inventory at the end and at the start of the day
    @variable(model, shortage[m=1:M, s=1:S] >= 0)
    @variable(model, excess[m=1:M, s=1:S] >= 0)

    # ----------- Expressions -----------

    # v1[m, n] number of units of type m coupled in connection n, v2 decoupled
    @expression(model, v1[m=1:M, n=1:N], sum(d.coupled_dict[(m, c1, c2)] * x[(c1, c2, n)] for (c1, c2) in d.feasible_pairs[n]))
    @expression(model, v2[m=1:M, n=1:N], sum(d.decoupled_dict[(m, c1, c2)] * x[(c1, c2, n)] for (c1, c2) in d.feasible_pairs[n]))

    # shunting[n] = 1 if coupling or decoupling happens in connection n
    # exactly one x is 1 per connection, so shunting happens if it is not one of the no-change transitions
    @expression(model, shunting[n=1:N], 1 - sum(x[(c1, c2, n)] for (c1, c2) in d.no_change_pairs[n]))

    # start_inv[m, s] - units of type m parked at station s at the start of the day
    if parking == :fixed
        @expression(model, start_inv[m=1:M, s=1:S], d.night_start[m, s] + extra_units[m, s])
        @expression(model, obj_relocations, AffExpr(0.0))
    elseif parking == :free
        # reloc_in/out[m, s] - units of type m that are parked at another depot than in the night capacity sheet
        @variable(model, reloc_in[m=1:M, s=1:S] >= 0, Int)
        @variable(model, reloc_out[m=1:M, s=1:S] >= 0, Int)
        @expression(model, start_inv[m=1:M, s=1:S], d.night_start[m, s] + extra_units[m, s] + reloc_in[m, s] - reloc_out[m, s])
        @expression(model, obj_relocations, sum(reloc_in))

        for m in 1:M
            # the fleet size stays the same, units are only parked somewhere else
            @constraint(model, sum(reloc_in[m, s] for s in 1:S) == sum(reloc_out[m, s] for s in 1:S))
            for s in 1:S
                @constraint(model, reloc_out[m, s] <= d.night_start[m, s])
                if d.stations[s] in d.depot_stations
                    # parking capacity of the depot in meters
                    @constraint(model, start_inv[m, s] * d.RS_Data.Length[m] <= d.parking_meters[m, s])
                else
                    fix(reloc_in[m, s], 0; force=true) # units can only be parked at depots
                end
            end
        end
    else
        error("Unknown parking option: $parking")
    end

    # ----------- Constraints -----------

    for j in 1:J
        # only material trains are allowed to stay empty (= not used)
        if tt.TrainCategory[j] != "M"
            fix(y[d.empty_comp_idx, j], 0; force=true)
        end
        # compositions with electric units are not allowed on non-electrified trips
        if !tt.Electrified[j]
            for c in d.electrified_comps
                fix(y[c, j], 0; force=true)
            end
        end
    end

    # A. Each trip has exactly one composition
    @constraint(model, [j=1:J], sum(y[c, j] for c in 1:C) == 1)

    # B. The transition of connection n starts with the composition of the incoming trip and ends with the one of the outgoing trip
    for n in 1:N
        j_in = d.connections.TripIn[n]
        j_out = d.connections.TripOut[n]
        for c in 1:C
            @constraint(model, sum(x[(c1, c2, n)] for (c1, c2) in d.feasible_pairs[n] if c1 == c) == y[c, j_in])
            @constraint(model, sum(x[(c1, c2, n)] for (c1, c2) in d.feasible_pairs[n] if c2 == c) == y[c, j_out])
        end
    end

    # D. Demand coverage
    @constraint(model, [j=1:J], sum(y[c, j] * d.comp_seats[c] for c in 1:C) >= demand_factor * tt.Demand[j])

    # E. Station inventory, tracked event by event
    # events at a station: (base time, is inflow, kind, index)
    events = [Tuple{Int, Bool, Symbol, Int}[] for s in 1:S]
    for j in d.first_trips
        push!(events[station_idx[tt.FromStation[j]]], (tt.DepartureFromStation[j], false, :start, j))
    end
    for j in d.last_trips
        push!(events[station_idx[tt.ToStation[j]]], (tt.ArrivalToStation[j], true, :end, j))
    end
    for n in 1:N
        s = station_idx[d.connections.ConnectionStation[n]]
        push!(events[s], (d.connections.ArrivalAtConnection[n], true, :decouple, n))
        push!(events[s], (d.connections.DepartureFromConnection[n], false, :couple, n))
    end

    # The time an event changes the inventory depends on the unit type: decoupled units become available
    # after the uncoupling time, units to be coupled must be in the depot the coupling time before departure
    function effective_time(event, m, s)
        time, is_inflow, kind, _ = event
        kind in (:start, :end) && !realloc_train_ends && return time
        return is_inflow ? time + d.realloc_uncouple[m, s] : time - d.realloc_couple[m, s]
    end

    event_station = vcat([fill(s, length(events[s])) for s in 1:S]...)
    E = length(event_station)

    units(m, j) = sum(d.comp_number[c, m] * y[c, j] for c in 1:C)

    # inv[m, e] - units of type m at the station of event e directly after the event
    # every station has a block of e, within the block the events are in chronological order of type m
    @variable(model, inv[m=1:M, e=1:E] >= 0)
    end_inv = Matrix{AffExpr}(undef, M, S)
    block_start = 0
    for s in 1:S
        for m in 1:M
            # inflows before outflows at the same time
            ordered = sort(events[s], by = ev -> (effective_time(ev, m, s), !ev[2], ev[3], ev[4]))
            previous = AffExpr(0.0) + start_inv[m, s]
            for (k, (_, _, kind, idx)) in enumerate(ordered)
                e = block_start + k
                flow = kind == :start ? -units(m, idx) :
                       kind == :end ? units(m, idx) :
                       kind == :couple ? -v1[m, idx] : v2[m, idx]
                @constraint(model, inv[m, e] == previous + flow)
                previous = AffExpr(0.0) + inv[m, e]
            end
            end_inv[m, s] = previous
        end
        block_start += length(events[s])
    end
    model[:end_inv] = end_inv
    model[:event_station] = event_station

    # F. Cyclic day: the inventory at the end of the day should equal the inventory at the start
    @constraint(model, [m=1:M, s=1:S], end_inv[m, s] - start_inv[m, s] == excess[m, s] - shortage[m, s])

    # G. Main unit type (only for the GGV model): trips of the same group must contain the same main unit type
    if ggv_constraints
        real_trips = [j for j in 1:J if tt.TrainCategory[j] != "M"] # material trains can stay empty
        @variable(model, u[m=1:M, j in real_trips], Bin)
        for j in real_trips
            @constraint(model, sum(u[m, j] for m in 1:M) == 1)
            for m in 1:M
                @constraint(model, u[m, j] <= units(m, j))
            end
        end

        groups = Dict{String, Vector{Int}}()
        for j in real_trips
            key = (hasproperty(tt, :GGVId) && tt.GGVId[j] != "-1") ? tt.GGVId[j] : "SOLO_$(tt.TrainId[j])"
            push!(get!(groups, key, Int[]), j)
        end
        for trip_indices in values(groups)
            sort!(trip_indices, by = j -> tt.DepartureFromStation[j])
            for i in 1:(length(trip_indices) - 1), m in 1:M
                @constraint(model, u[m, trip_indices[i]] == u[m, trip_indices[i+1]])
            end
        end
    end

    # ----------- Objectives -----------
    # material trains that are only candidates count as "new" if they are used
    @expression(model, mtrain_used[j in d.candidate_trips], 1 - y[d.empty_comp_idx, j])

    @expression(model, obj_balance, sum(shortage) + sum(excess))
    @expression(model, obj_extra_units, sum(extra_units))
    # one balance issue is as bad as one extra unit, so they are minimized together with equal weight
    @expression(model, obj_units, obj_balance + obj_extra_units)
    model[:obj_new_mtrains] = obj_new_mtrains = AffExpr(0.0) + sum(mtrain_used[j] for j in d.candidate_trips; init = AffExpr(0.0))
    @expression(model, obj_km, sum(y[c, j] * d.comp_costs[c] * tt.Distance_KM[j] for c in 1:C, j in 1:J))
    model[:obj_shunting] = obj_shunting = AffExpr(0.0) + sum(shunting[n] for n in 1:N; init = AffExpr(0.0))
    @expression(model, obj_operating, km_buff * obj_km + v_penalty * obj_shunting + mtrain_penalty * obj_new_mtrains)

    # Epsilon constraints to analyse trade-offs
    max_extra_units !== nothing && @constraint(model, obj_extra_units <= max_extra_units)
    max_relocations !== nothing && @constraint(model, obj_relocations <= max_relocations)
    max_new_mtrains !== nothing && @constraint(model, obj_new_mtrains <= max_new_mtrains)

    return model
end


"""
Solves the model lexicographically: the objectives are optimized one after another. After each stage,
the reached value is added as an upper bound, so the next objectives cannot make it worse.

All stages except the last one minimize `priority_weight * objective + obj_operating`. The operating costs
are too small to outweigh the objective, but without them the solver has no reason to prefer short
compositions and needs much longer to find a good solution.

# Arguments
- `model::Model`: Model from `build_model`
- `stages::Vector{String}`: Objective names in order of priority, e.g. ["units", "operating"]
  (refers to the expressions `obj_<name>` of the model)
- `tolerance::Float64`: Allowed deterioration of an earlier objective in later stages
- `priority_weight::Float64`: Weight of the objective of a stage against the operating costs

# Returns
- `DataFrame` with the value and bound of the objective solved in every stage (including the operating
  costs, except in the last stage), status and runtime
"""
function solve_lexicographic!(model, stages; tolerance = 1e-6, priority_weight = 1e5)
    stage_results = DataFrame(Stage = Int[], Objective = String[], Value = Float64[], Bound = Float64[], Status = String[], Runtime = Float64[])

    for (k, name) in enumerate(stages)
        expr = model[Symbol("obj_", name)]
        if isempty(expr.terms) # constant objective (e.g. no relocations possible), nothing to optimize
            push!(stage_results, (k, name, expr.constant, expr.constant, "SKIPPED (constant)", 0.0))
            continue
        end

        println("\n=== Stage $k: minimize $name ===")
        @objective(model, Min, k < length(stages) ? priority_weight * expr + model[:obj_operating] : expr)
        optimize!(model)

        status = string(termination_status(model))
        if !has_values(model)
            push!(stage_results, (k, name, NaN, NaN, status, solve_time(model)))
            println("Stage $k ($name) found no solution: $status")
            break
        end

        val = objective_value(model)
        bound = try objective_bound(model) catch; NaN end
        push!(stage_results, (k, name, val, bound, status, solve_time(model)))

        if k < length(stages)
            # keep the reached level and use the solution as a warm start for the next stage
            vars = all_variables(model)
            start = value.(vars)
            reached = value(expr) # without the operating costs
            @constraint(model, expr <= reached + tolerance * max(1.0, abs(reached)))
            set_start_value.(vars, start)
        end
    end

    return stage_results
end


# -----------------------------------------------------------
# RESULTS
# -----------------------------------------------------------

"""
Writes the results of a solved model to `Results/Analysis` and returns the key figures.

Files: CompAssignments (composition per trip), Inventory (start/end/idle units per station and type),
MTrains (used candidate material trains) and Summary (settings, stages, key figures).

# Returns
- `NamedTuple` with the key figures of the scenario (used for comparisons)
"""
function write_results(model, data, scenario, stage_results; settings = (;))
    d = data
    tt = d.timetable
    C, M, J, S = d.C, d.M, d.J, d.S
    out_dir = joinpath(project_root, "Results", "Analysis")
    mkpath(out_dir)
    timestamp = Dates.format(Dates.now(), "yyyy-mm-dd_HHMMSS")
    y = model[:y]

    # Composition per trip
    assignments = DataFrame(
        TripId = Int[], TrainCategory = String[], TrainId = String[], FromStation = String[], ToStation = String[],
        Departure = Int[], Arrival = Int[], Demand = Int[], Electrified = Bool[], Distance = Float64[],
        Composition = String[], OrderedComposition = String[], IsCandidate = Bool[]
    )
    for j in 1:J, c in 1:C
        if c != d.empty_comp_idx && value(y[c, j]) > 0.5
            push!(assignments, (
                TripId = j, TrainCategory = tt.TrainCategory[j], TrainId = tt.TrainId[j],
                FromStation = tt.FromStation[j], ToStation = tt.ToStation[j],
                Departure = tt.DepartureFromStation[j], Arrival = tt.ArrivalToStation[j],
                Demand = tt.Demand[j], Electrified = tt.Electrified[j], Distance = tt.Distance_KM[j],
                Composition = d.normalized_names[c], OrderedComposition = d.compositions[c],
                IsCandidate = tt.IsCandidate[j]
            ))
        end
    end
    sort!(assignments, [:TrainId, :Departure])
    CSV.write(joinpath(out_dir, "CompAssignments_$(scenario)_$(timestamp).csv"), assignments)

    # Inventory per station and type
    # IdleUnits = lowest inventory during the day = units that are never used at that station
    inv = value.(model[:inv])
    start_inv = value.(model[:start_inv])
    end_inv = value.(model[:end_inv])
    event_station = model[:event_station]
    has_reloc = haskey(model, :reloc_in)

    inventory = DataFrame(
        Station = String[], Type = String[], NightCapacity = Int[], ExtraUnits = Int[], RelocatedIn = Int[],
        RelocatedOut = Int[], StartInventory = Int[], EndInventory = Int[], IdleUnits = Int[], Shortage = Int[], Excess = Int[]
    )
    for s in 1:S, m in 1:M
        station_events = findall(==(s), event_station)
        idle = minimum(vcat(start_inv[m, s], [inv[m, e] for e in station_events]))
        row = (
            Station = d.stations[s], Type = d.unit_names[m], NightCapacity = d.night_start[m, s],
            ExtraUnits = round(Int, value(model[:extra_units][m, s])),
            RelocatedIn = has_reloc ? round(Int, value(model[:reloc_in][m, s])) : 0,
            RelocatedOut = has_reloc ? round(Int, value(model[:reloc_out][m, s])) : 0,
            StartInventory = round(Int, start_inv[m, s]), EndInventory = round(Int, end_inv[m, s]),
            IdleUnits = round(Int, idle),
            Shortage = round(Int, value(model[:shortage][m, s])), Excess = round(Int, value(model[:excess][m, s]))
        )
        if any(!=(0), [row.NightCapacity, row.ExtraUnits, row.StartInventory, row.EndInventory, row.Shortage, row.Excess])
            push!(inventory, row)
        end
    end
    CSV.write(joinpath(out_dir, "Inventory_$(scenario)_$(timestamp).csv"), inventory)

    # Used candidate material trains
    mtrains = filter(row -> row.IsCandidate, assignments)
    if !isempty(mtrains)
        CSV.write(joinpath(out_dir, "MTrains_$(scenario)_$(timestamp).csv"), mtrains)
    end

    # Key figures
    kpis = (
        Scenario = scenario,
        Status = isempty(stage_results) ? "NOT SOLVED" : stage_results.Status[end],
        Runtime = round(sum(stage_results.Runtime), digits = 1),
        ExtraUnits = round(Int, value(model[:obj_extra_units])),
        Balance = round(Int, value(model[:obj_balance])),
        Relocations = round(Int, value(model[:obj_relocations])),
        NewMTrains = round(Int, value(model[:obj_new_mtrains])),
        NewMTrainKm = round(sum(mtrains.Distance; init = 0.0), digits = 1),
        KmCost = round(value(model[:obj_km]), digits = 1),
        ShuntingOps = round(Int, value(model[:obj_shunting])),
        IdleUnits = sum(inventory.IdleUnits; init = 0)
    )

    open(joinpath(out_dir, "Summary_$(scenario)_$(timestamp).txt"), "w") do f
        write(f, "------------------------------------------\n")
        write(f, "SCENARIO: $scenario\n")
        write(f, "------------------------------------------\n")
        write(f, "Data: $(d.execution_file) ($(J) trips, $(d.N) connections, $(length(d.candidate_trips)) material train candidates)\n")
        for (key, val) in pairs(settings)
            write(f, "- $key: $val\n")
        end
        write(f, "------------------------------------------\n")
        write(f, "Lexicographic stages:\n")
        for row in eachrow(stage_results)
            write(f, "  $(row.Stage). $(rpad(row.Objective, 12)) value $(round(row.Value, digits = 2)), bound $(round(row.Bound, digits = 2)), $(row.Status), $(round(row.Runtime, digits = 1)) s\n")
        end
        write(f, "------------------------------------------\n")
        write(f, "Key figures:\n")
        for (key, val) in pairs(kpis)
            write(f, "  $(rpad(string(key), 12)) $val\n")
        end
    end

    println("\nResults of scenario $scenario written to $out_dir")
    println(kpis)
    return kpis
end


"""
Loads the data, builds and solves one scenario and writes its results.

# Arguments
- `scenario::String`: Name of the scenario (used in the file names)
- `execution_file::String`: Timetable file in the DataManipulated folder
- `stages::Vector{String}`: Lexicographic order of the objectives
- `add_mtrain_candidates`, `mtrain_settings`: See `load_model_data`
- `model_settings...`: Keyword arguments for `build_model`

# Returns
- `NamedTuple` with the key figures (see `write_results`)
"""
function run_scenario(scenario; execution_file, stages, add_mtrain_candidates = false, mtrain_settings = (;),
                      data = nothing, model_settings...)
    if data === nothing
        data = load_model_data(execution_file; add_mtrain_candidates = add_mtrain_candidates, mtrain_settings = mtrain_settings)
    end
    model = build_model(data; model_settings...)
    stage_results = solve_lexicographic!(model, stages)

    if !has_values(model)
        println("Scenario $scenario: no solution found.")
        return (Scenario = scenario, Status = isempty(stage_results) ? "NOT SOLVED" : stage_results.Status[end])
    end

    settings = merge((stages = join(stages, " > "), add_mtrain_candidates = add_mtrain_candidates), values(model_settings))
    return write_results(model, data, scenario, stage_results; settings = settings)
end
