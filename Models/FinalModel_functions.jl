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
Builds the GGV links: units of trip A must continue directly on trip B.

Train A either ends at the station or continues and leaves units behind (uncoupling), train B either
starts at the station or continues and takes units (coupling). The sides of the composition a block of
units can leave A and join B follow from the shunting rule of a continuing train. A train that ends or
starts can use both sides.

# Arguments
- `timetable::DataFrame`: Timetable with an `Index` and a `GGVId` column
- `connections::DataFrame`: Connections from `build_trip_connections`
- `connection_codes::Vector{String}`: Shunt code of every connection
- `shunt_rules::Dict`: Shunting rules per shunt code
- `turning_stations::Set{String}`: Stations where trains reverse

# Returns
- `Vector{NamedTuple}`: One entry per link
"""
function build_ggv_links(timetable, connections, connection_codes, shunt_rules, turning_stations)
    conn_by_trip_in = Dict(connections.TripIn[n] => n for n in 1:nrow(connections))
    conn_by_trip_out = Dict(connections.TripOut[n] => n for n in 1:nrow(connections))

    links = NamedTuple[]
    for (a, b) in find_ggv_trip_links(timetable)
        conn_out = get(conn_by_trip_in, a, 0)
        conn_in = get(conn_by_trip_out, b, 0)
        station = timetable.ToStation[a]

        source_sides = [:front, :rear]
        if conn_out != 0
            rule = shunt_rules[connection_codes[conn_out]]
            source_sides = [side for (side, limit) in ((:front, rule.uncouple_front), (:rear, rule.uncouple_rear)) if limit > 0]
        end

        dest_sides = [:front, :rear]
        if conn_in != 0
            rule = shunt_rules[connection_codes[conn_in]]
            # coupling is defined in arrival direction, after turning the front of the train becomes the rear
            front, rear = rule.turn ? (:rear, :front) : (:front, :rear)
            dest_sides = [side for (side, limit) in ((front, rule.couple_front), (rear, rule.couple_rear)) if limit > 0]
        end

        push!(links, (a_trip = a, b_trip = b, station = station, conn_out = conn_out, conn_in = conn_in,
                      source_sides = source_sides, dest_sides = dest_sides, turn = station in turning_stations))
    end
    return links
end


"""
Reads and prepares all data needed for the model.

# Arguments
- `execution_file::String`: Timetable file in the DataManipulated folder
- `add_mtrain_candidates::Bool`: If true, candidate material trains are added (see `generate_M_train_candidates`)
- `mtrain_settings::NamedTuple`: Keyword arguments for `generate_M_train_candidates`
- `joint_shunting::Bool`: If true, shunting is allowed at the joints inside a merged TrainId (connections
  without a shunt code). If false, the composition cannot change there (old behaviour)

# Returns
- `NamedTuple` with the timetable, connections, compositions and all parameters of the model
"""
function load_model_data(execution_file; add_mtrain_candidates = false, mtrain_settings = (;), joint_shunting = true)
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
    shunt_rules = get_shunt_rules(shunting_operations)
    # connections without a shunt code: no coupling or decoupling (only used if joint_shunting = false)
    get!(shunt_rules, "None", (couple_front = 0, uncouple_front = 0, couple_rear = 0, uncouple_rear = 0, turn = false))

    # Connections without a shunt code are the points where two original trains were merged into one TrainId.
    # They still work separately, and shunting is always allowed where a train ends or starts.
    # Trains only reverse there if the station is a turning station according to the "Trip cutpoints" sheet.
    turning_stations = Set(string(row."Cut station") for row in eachrow(cutpoints) if shunt_rules[string(row."Shunt code")].turn)
    free_rule(turn) = (couple_front = 4, uncouple_front = 4, couple_rear = 4, uncouple_rear = 4, turn = turn)
    shunt_rules["Free"] = free_rule(false)
    shunt_rules["FreeTurn"] = free_rule(true)
    free_pairs = Dict(code => [(c1, c2) for c1 in 1:C, c2 in 1:C if is_feasible_shunt(comp_units[c1], comp_units[c2], shunt_rules[code])]
                      for code in ("Free", "FreeTurn"))
    for n in 1:nrow(connections)
        if joint_shunting && connection_codes[n] == "None"
            connection_codes[n] = connections.ConnectionStation[n] in turning_stations ? "FreeTurn" : "Free"
            feasible_pairs[n] = free_pairs[connection_codes[n]]
        end
    end
    x_index = [(c1, c2, n) for n in 1:nrow(connections) for (c1, c2) in feasible_pairs[n]]

    ggv_links = hasproperty(timetable, :GGVId) ?
        build_ggv_links(timetable, connections, connection_codes, shunt_rules, turning_stations) : NamedTuple[]

    # Stored trains: the shunt code that applies when a train starts from a composition standing on the track.
    # The code of the "Trip cutpoints" sheet for this train and station, otherwise the standard turning pattern.
    setting(name) = settings_sheet[findfirst(row -> isequal(settings_sheet[row, 1], name), 1:size(settings_sheet, 1)), 2]
    min_turnaround = Int(setting("Standard turning"))
    standard_pattern = string(setting("Standard turning pattern"))
    station_codes = Dict((string(row.TrainSystem), string(row."Cut station")) => string(row."Shunt code") for row in eachrow(cutpoints))
    function start_code(j)
        number = tryparse(Int, first(split(timetable.TrainId[j], "_")))
        system = number === nothing ? nothing : get_train_system(number, timetable.TrainCategory[j], system_mapping)
        return get(station_codes, (system, timetable.FromStation[j]), standard_pattern)
    end
    storage_codes = Dict(j => start_code(j) for j in first_trips)

    # storage_compatible[code][c1] - compositions a train can start with if composition c1 is standing on the track.
    # Coupling only as far as the shunt code allows, decoupling is never possible.
    storage_compatible = Dict(code => Dict(c1 => [c2 for c2 in 1:C if c2 != empty_comp_idx
                                                  && length(comp_units[c2]) >= length(comp_units[c1])
                                                  && is_feasible_shunt(comp_units[c1], comp_units[c2], shunt_rules[code])]
                                           for c1 in 1:C if c1 != empty_comp_idx)
                              for code in unique(values(storage_codes)))

    # Transitions without coupling or decoupling: identical composition, or exactly reversed if the train turns
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
        shunt_rules = shunt_rules,
        turning_stations = turning_stations,
        x_index = x_index,
        no_change_pairs = no_change_pairs,
        ggv_links = ggv_links,
        min_turnaround = min_turnaround,
        storage_codes = storage_codes,
        storage_compatible = storage_compatible,
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
Adds the GGV links to the model: every link moves one ordered block of units directly from train A to train B.

The block is at the front or rear of train A and at the front or rear of train B, in the same order
(reversed at a turning station). If several links use the same train, every link needs its own side of
the train, so a 1:2 split needs at least 2 units on the incoming train and a 2:1 merge at least 2 units
on the departing train.

# Arguments
- `model::Model`: The model, containing `y`
- `d::NamedTuple`: Output of `load_model_data`
- `event_units::Function`: (m, kind, idx) -> units of type m leaving or joining a train at an event

# Returns
- `transfer::Matrix{AffExpr}`: [m, l] units of type m moving directly over link l
- `link_events::Dict`: (event kind, event index) -> links using this event
"""
function add_ggv_links!(model, d, event_units)
    y = model[:y]
    links = d.ggv_links
    L = length(links)
    end_block(units, p, side) = side == :front ? units[1:p] : units[end-p+1:end]

    # All ordered blocks of units that can be at the front or rear of a composition
    blocks = unique(vcat([[end_block(units, p, side) for p in 1:length(units), side in (:front, :rear)][:] for units in d.comp_units]...))

    allowed_comps(j) = [c for c in 1:d.C if c != d.empty_comp_idx && (d.timetable.Electrified[j] || !(c in d.electrified_comps))]
    matching_comps(comps, block, side) = [c for c in comps if length(d.comp_units[c]) >= length(block) && end_block(d.comp_units[c], length(block), side) == block]

    # ggv_index[i] = (link, block, side at train A, side at train B)
    ggv_index = Tuple{Int, Vector{String}, Symbol, Symbol}[]
    from_side = Dict{Tuple{Int, Vector{String}, Symbol}, Vector{Int}}()
    to_side = Dict{Tuple{Int, Vector{String}, Symbol}, Vector{Int}}()
    for (l, link) in enumerate(links)
        comps_a, comps_b = allowed_comps(link.a_trip), allowed_comps(link.b_trip)
        options = 0
        for block in blocks, side_a in link.source_sides, side_b in link.dest_sides
            if !isempty(matching_comps(comps_a, block, side_a)) && !isempty(matching_comps(comps_b, link.turn ? reverse(block) : block, side_b))
                push!(ggv_index, (l, block, side_a, side_b))
                options += 1
                push!(get!(from_side, (l, block, side_a), Int[]), length(ggv_index))
                push!(get!(to_side, (l, block, side_b), Int[]), length(ggv_index))
            end
        end
        options > 0 || error("GGV link from trip $(link.a_trip) to trip $(link.b_trip) at $(link.station) has no feasible block of units.")
    end

    # ggv_block[i] = 1 if the option ggv_index[i] is used
    @variable(model, ggv_block[eachindex(ggv_index)], Bin)
    model[:ggv_index] = ggv_index

    # Every link is required and uses exactly one option
    options_of = [Int[] for l in 1:L]
    for (i, (l, _, _, _)) in enumerate(ggv_index)
        push!(options_of[l], i)
    end
    @constraint(model, [l=1:L], sum(ggv_block[i] for i in options_of[l]) == 1)

    # The block must be at this side of the composition of train A and train B
    for ((l, block, side), options) in from_side
        comps = matching_comps(allowed_comps(links[l].a_trip), block, side)
        @constraint(model, sum(ggv_block[i] for i in options) <= sum(y[c, links[l].a_trip] for c in comps))
    end
    for ((l, block, side), options) in to_side
        target = links[l].turn ? reverse(block) : block
        comps = matching_comps(allowed_comps(links[l].b_trip), target, side)
        @constraint(model, sum(ggv_block[i] for i in options) <= sum(y[c, links[l].b_trip] for c in comps))
    end

    # transfer[m, l] - units of type m moving directly over link l
    transfer = [AffExpr(0.0) for m in 1:d.M, l in 1:L]
    for (i, (l, block, _, _)) in enumerate(ggv_index), m in 1:d.M
        add_to_expression!(transfer[m, l], count(==(d.unit_names[m]), block), ggv_block[i])
    end
    model[:ggv_transfer] = transfer

    # link_events[(kind, idx)] - links that use this event of the inventory
    link_events = Dict{Tuple{Symbol, Int}, Vector{Int}}()
    for (l, link) in enumerate(links)
        push!(get!(link_events, link.conn_out == 0 ? (:end, link.a_trip) : (:decouple, link.conn_out), Int[]), l)
        push!(get!(link_events, link.conn_in == 0 ? (:start, link.b_trip) : (:couple, link.conn_in), Int[]), l)
    end

    for ((kind, idx), event_links) in link_events
        # A train cannot give or take more units than leave or join it at this event
        for m in 1:d.M
            @constraint(model, sum(transfer[m, l] for l in event_links) <= event_units(m, kind, idx))
        end
        # Every link of this event needs its own side of the train
        if length(event_links) > 1
            position = kind in (:end, :decouple) ? 3 : 4
            for side in (:front, :rear)
                options = [i for l in event_links for i in options_of[l] if ggv_index[i][position] == side]
                isempty(options) || @constraint(model, sum(ggv_block[i] for i in options) <= 1)
            end
        end
    end

    return transfer, link_events
end


"""
Adds stored trains to the model: a whole train stays on the track after its last trip and a later train
starts from it, without any reallocation time.

There is one pool per station and composition. A train ending at the station can enter the pool, a train
starting at the station can take a composition from the pool. Coupling depends on the shunt code of the
starting train (`storage_compatible`), decoupling is never possible. Trains that give or take units over a
GGV link cannot be stored or start from a stored composition.

A stored train is available `d.min_turnaround` minutes after its arrival and must leave within
`max_storage_time` minutes. Longer gaps are excluded if all units of the composition could also pass the
depot in that time, since storing has no advantage then. This reduces the model without losing solutions.
Within a pool all trains can stay equally long, so taking the longest standing train first is always
possible if a feasible pairing exists. The cumulative constraints below are therefore sufficient and the
pairs of trains do not have to be modelled.

# Arguments
- `model::Model`: The model, containing `y`
- `d::NamedTuple`: Output of `load_model_data`
- `link_events::Dict`: Output of `add_ggv_links!`
- `max_storage_time::Int`: Maximum time (in minutes) between arrival and departure of a stored train

# Returns
- `stored_flow::Dict`: (event kind, trip, m) -> units of type m entering or leaving the pool at this event
"""
function add_stored_trains!(model, d, link_events, max_storage_time)
    y = model[:y]
    tt = d.timetable
    allowed(j, c) = c != d.empty_comp_idx && (tt.Electrified[j] || !(c in d.electrified_comps))
    station_idx = Dict(s => i for (i, s) in enumerate(d.stations))

    # longest useful storage time of composition c at a station
    function storage_limit(station, c)
        s = station_idx[station]
        depot_time = maximum(d.realloc_uncouple[m, s] + d.realloc_couple[m, s] for m in 1:d.M if d.comp_number[c, m] > 0)
        return min(max_storage_time, depot_time - 1)
    end
    limits = Dict((s, c) => storage_limit(s, c) for s in d.stations for c in 1:d.C if c != d.empty_comp_idx)
    in_window(a, b, c) = d.min_turnaround <= tt.DepartureFromStation[b] - tt.ArrivalToStation[a] <= limits[(tt.ToStation[a], c)]

    arrivals = [j for j in d.last_trips if !haskey(link_events, (:end, j))]
    departures = [j for j in d.first_trips if !haskey(link_events, (:start, j))]

    # A departure can use composition c if it is allowed on the arriving train and leads to an allowed composition
    can_use(a, b, c) = allowed(a, c) && tt.ToStation[a] == tt.FromStation[b] && in_window(a, b, c) &&
                       any(allowed(b, c2) for c2 in d.storage_compatible[d.storage_codes[b]][c])

    comps = [c for c in 1:d.C if c != d.empty_comp_idx]
    in_index = [(j, c) for j in arrivals for c in comps if any(can_use(j, b, c) for b in departures)]
    out_index = [(j, c) for j in departures for c in comps if any(can_use(a, j, c) for a in arrivals)]

    @variable(model, stored_in[in_index], Bin)   # train j enters the pool of composition c
    @variable(model, stored_out[out_index], Bin) # train j starts from a stored composition c
    model[:stored_in_index] = in_index
    model[:stored_out_index] = out_index

    for (j, c) in in_index
        @constraint(model, stored_in[(j, c)] <= y[c, j])
    end

    for j in unique(first.(out_index))
        used = [c for (b, c) in out_index if b == j]
        @constraint(model, sum(stored_out[(j, c)] for c in used) <= 1)
        for c in used
            code = d.storage_codes[j]
            @constraint(model, stored_out[(j, c)] <= sum(y[c2, j] for c2 in d.storage_compatible[code][c] if allowed(j, c2)))
        end
    end

    # Pool of every station and composition
    pools = Dict{Tuple{String, Int}, Tuple{Vector{Int}, Vector{Int}}}()
    for (j, c) in in_index
        push!(get!(pools, (tt.ToStation[j], c), (Int[], Int[]))[1], j)
    end
    for (j, c) in out_index
        push!(get!(pools, (tt.FromStation[j], c), (Int[], Int[]))[2], j)
    end
    for ((station, c), (in_trips, out_trips)) in pools
        # a train can only start from a composition that has been standing for the minimum turnaround time
        for b in out_trips
            @constraint(model,
                sum(stored_out[(j, c)] for j in out_trips if tt.DepartureFromStation[j] <= tt.DepartureFromStation[b]) <=
                sum(AffExpr(0.0) + stored_in[(a, c)] for a in in_trips if tt.ArrivalToStation[a] + d.min_turnaround <= tt.DepartureFromStation[b]; init = AffExpr(0.0)))
        end
        # every stored composition has to leave within the storage limit
        for a in in_trips
            @constraint(model,
                sum(stored_in[(j, c)] for j in in_trips if tt.ArrivalToStation[j] <= tt.ArrivalToStation[a]) <=
                sum(AffExpr(0.0) + stored_out[(b, c)] for b in out_trips if tt.DepartureFromStation[b] <= tt.ArrivalToStation[a] + limits[(station, c)]; init = AffExpr(0.0)))
        end
    end

    stored_flow = Dict{Tuple{Symbol, Int, Int}, AffExpr}()
    for (j, c) in in_index, m in 1:d.M
        add_to_expression!(get!(stored_flow, (:end, j, m), AffExpr(0.0)), d.comp_number[c, m], stored_in[(j, c)])
    end
    for (j, c) in out_index, m in 1:d.M
        add_to_expression!(get!(stored_flow, (:start, j, m), AffExpr(0.0)), d.comp_number[c, m], stored_out[(j, c)])
    end
    return stored_flow
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
- `ggv_constraints::Bool`: If true, every GGV link must carry at least one unit directly from train A to
  train B (see `add_ggv_links!`). These units do not pass the inventory, so they do not wait for reallocation
- `main_unit_type::Bool`: Old GGV rule: all trips of the same GGVId (or TrainId) must contain the same
  main unit type. Material trains are excluded
- `max_storage_time`: If set, whole trains can stay on the track for at most this many minutes and continue
  as a later train without reallocation time (see `add_stored_trains!`). If `nothing`, this is not possible
- `max_extra_units`, `max_relocations`, `max_new_mtrains`: Optional upper bounds (epsilon constraints)
- `km_buff`, `v_penalty`, `mtrain_penalty`: Weights inside the operating cost objective

# Returns
- `model::Model`
"""
function build_model(data; solver = "Gurobi", mip_gap = 0.005, time_limit = 3600,
                     parking = :fixed, demand_factor = 1.0, realloc_train_ends = true, ggv_constraints = false,
                     main_unit_type = false, max_storage_time = nothing,
                     max_extra_units = nothing, max_relocations = nothing, max_new_mtrains = nothing,
                     km_buff = 0.001, v_penalty = 100, mtrain_penalty = 100)
    d = data
    C, M, J, N, S = d.C, d.M, d.J, d.N, d.S
    tt = d.timetable
    station_idx = Dict(s => i for (i, s) in enumerate(d.stations))

    model = create_model(solver; mip_gap = mip_gap, time_limit = time_limit)
    model[:realloc_train_ends] = realloc_train_ends # needed for the unit flows in write_results

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

    # Number of units of type m leaving (:end, :decouple) or joining (:start, :couple) a train at an event
    function event_units(m, kind, idx)
        kind in (:start, :end) && return units(m, idx)
        return kind == :couple ? v1[m, idx] : v2[m, idx]
    end

    # G. GGV links: units moving directly between two trains
    if ggv_constraints
        isempty(d.ggv_links) && error("ggv_constraints = true, but the timetable has no GGV links.")
        transfer, link_events = add_ggv_links!(model, d, event_units)
    else
        transfer = zeros(AffExpr, M, 0)
        link_events = Dict{Tuple{Symbol, Int}, Vector{Int}}()
    end

    # G2. Old GGV rule: trips of the same group must contain the same main unit type
    if main_unit_type
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

    # H. Whole trains staying on the track and continuing as a later train
    stored_flow = max_storage_time === nothing ? Dict{Tuple{Symbol, Int, Int}, AffExpr}() :
                  add_stored_trains!(model, d, link_events, max_storage_time)

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
                # units moving directly to or from another train and stored trains never enter the inventory
                via_inventory = event_units(m, kind, idx) - sum(transfer[m, l] for l in get(link_events, (kind, idx), Int[]); init = AffExpr(0.0)) -
                                get(stored_flow, (kind, idx, m), AffExpr(0.0))
                flow = kind in (:start, :couple) ? -via_inventory : via_inventory
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
Builds the table of the used GGV links (one row per link with its block and sides).

# Arguments
- `d::NamedTuple`: Output of `load_model_data`
- `trip_comp::Vector{Int}`: Composition index of every trip
- `links_used::Vector`: (l, block, side_a, side_b) of every used link option

# Returns
- `DataFrame`
"""
function ggv_links_table(d, trip_comp, links_used)
    tt = d.timetable
    kind(link) = string(link.conn_out == 0 ? "A ends" : "A continues", ", ", link.conn_in == 0 ? "B starts" : "B continues")
    table = DataFrame(
        GGVId = String[], TrainA = String[], TrainB = String[], Station = String[], FromStationA = String[], ToStationB = String[],
        ArrivalA = Int[], DepartureB = Int[], Gap = Int[], Kind = String[], ShuntCode = String[], CompositionA = String[], CompositionB = String[],
        Block = String[], SideA = String[], SideB = String[], Turn = Bool[]
    )
    for u in links_used
        link = d.ggv_links[u.l]
        a, b = link.a_trip, link.b_trip
        code = link.conn_out != 0 ? d.connection_codes[link.conn_out] : link.conn_in != 0 ? d.connection_codes[link.conn_in] : "-"
        push!(table, (tt.GGVId[a], tt.TrainId[a], tt.TrainId[b], link.station, tt.FromStation[a], tt.ToStation[b],
                      tt.ArrivalToStation[a], tt.DepartureFromStation[b], tt.DepartureFromStation[b] - tt.ArrivalToStation[a],
                      kind(link), code, d.compositions[trip_comp[a]], d.compositions[trip_comp[b]], join(u.block, "-"),
                      string(u.side_a), string(u.side_b), link.turn))
    end
    sort!(table, [:Station, :ArrivalA])
    return table
end


"""
Resolves which positions of a composition stay on the train when `units_from` becomes `units_to` with a shunting rule.

Positions count from the front of the train in its driving direction. Uses the same operations as
`is_feasible_shunt`: no change, coupling at the front or rear, decoupling at the front or rear (in arrival
direction), and reversing the train afterwards if the rule turns.

# Returns
- `Vector` of options `(kept, released, added)`: `kept` are pairs (position in `units_from` => position in `units_to`),
  `released` the positions of `units_from` that leave the train, `added` the positions of `units_to` that join it
"""
function shunt_options(units_from, units_to, rule)
    n_from, n_to = length(units_from), length(units_to)
    target = rule.turn ? reverse(units_to) : units_to
    to_pos(t) = rule.turn ? n_to - t + 1 : t # position in arrival direction -> position in the departing composition
    k = n_to - n_from
    options = []
    if target == units_from
        push!(options, ([i => to_pos(i) for i in 1:n_from], Int[], Int[]))
    elseif k > 0
        k <= rule.couple_front && target[k+1:end] == units_from &&
            push!(options, ([i => to_pos(i + k) for i in 1:n_from], Int[], sort(to_pos.(1:k))))
        k <= rule.couple_rear && target[1:n_from] == units_from &&
            push!(options, ([i => to_pos(i) for i in 1:n_from], Int[], sort(to_pos.(n_from+1:n_to))))
    elseif k < 0
        -k <= rule.uncouple_front && units_from[-k+1:end] == target &&
            push!(options, ([i => to_pos(i + k) for i in -k+1:n_from], collect(1:-k), Int[]))
        -k <= rule.uncouple_rear && units_from[1:n_to] == target &&
            push!(options, ([i => to_pos(i) for i in 1:n_to], collect(n_to+1:n_from), Int[]))
    end
    return options
end


"""
Determines the physical flow of every unit position in the solution, as input for the unit assignment.

Every position of every trip gets exactly one source and one destination:
- `continue`: the unit stays on the train at a connection
- `link`: the unit moves directly to another train over a GGV link
- `stored`: the whole train stays on the track and continues as a later train
- `depot_in` / `depot_out`: the unit goes to / comes from the station inventory

For `depot_in`, `ReadyTime` is the time the unit is available in the inventory, for `depot_out` the time it must
be in the inventory at the latest. These are the same times the model uses for the inventory (reallocation times).
Where more than one shunting operation fits the compositions, the one that matches the GGV link blocks is chosen.
If no operation matches, a warning is printed and the link takes units of the same type that leave the train.

# Arguments
- `d::NamedTuple`: Output of `load_model_data`
- `trip_comp::Vector{Int}`: Composition index of every trip
- `links_used::Vector`: (l, block, side_a, side_b) of every used GGV link option
- `stored_pairs::Vector{Tuple{Int, Int}}`: (arriving trip, departing trip) of every stored train
- `realloc_train_ends::Bool`: Same setting as in `build_model`

# Returns
- `DataFrame` with one row per unit position movement
"""
function get_unit_flows(d, trip_comp, links_used, stored_pairs; realloc_train_ends)
    tt = d.timetable
    station_idx = Dict(s => i for (i, s) in enumerate(d.stations))
    m_idx = Dict(name => m for (m, name) in enumerate(d.unit_names))
    units(j) = d.comp_units[trip_comp[j]]
    side_positions(n, p, side) = side == :front ? collect(1:p) : collect(n-p+1:n)
    uncouple_time(m, s, at_end) = at_end && !realloc_train_ends ? 0 : d.realloc_uncouple[m, s]
    couple_time(m, s, at_start) = at_start && !realloc_train_ends ? 0 : d.realloc_couple[m, s]

    flows = DataFrame(Kind = String[], Station = String[], Type = String[], FromTrip = Int[], FromPos = Int[],
                      ToTrip = Int[], ToPos = Int[], Time = Int[], ReadyTime = Int[])
    # positions of every trip that leave it at its arrival (released) or join it at its departure (added)
    released = Dict{Int, Vector{Int}}()
    added = Dict{Int, Vector{Int}}()
    warnings = String[]

    # Links per trip: blocks at the arrival of trip a and the departure of trip b
    link_pos = Dict{Int, Tuple{Vector{Int}, Vector{Int}}}() # index in links_used -> (positions in a, positions in b)
    for (i, u) in enumerate(links_used)
        link = d.ggv_links[u.l]
        p = length(u.block)
        pos_a = side_positions(length(units(link.a_trip)), p, u.side_a)
        pos_b = side_positions(length(units(link.b_trip)), p, u.side_b)
        link_pos[i] = (pos_a, link.turn ? reverse(pos_b) : pos_b)
    end
    links_out = Dict{Int, Vector{Int}}() # trip a -> links
    links_in = Dict{Int, Vector{Int}}()  # trip b -> links
    for (i, u) in enumerate(links_used)
        push!(get!(links_out, d.ggv_links[u.l].a_trip, Int[]), i)
        push!(get!(links_in, d.ggv_links[u.l].b_trip, Int[]), i)
    end
    block_a(j) = Set(vcat(Int[], [link_pos[i][1] for i in get(links_out, j, Int[])]...))
    block_b(j) = Set(vcat(Int[], [link_pos[i][2] for i in get(links_in, j, Int[])]...))

    # Connections: units staying on the train
    for n in 1:d.N
        j_in, j_out = d.connections.TripIn[n], d.connections.TripOut[n]
        options = shunt_options(units(j_in), units(j_out), d.shunt_rules[d.connection_codes[n]])
        if isempty(options)
            error("Connection $n (TrainId $(tt.TrainId[j_in]) at $(d.connections.ConnectionStation[n])): no shunting operation turns " *
                  "$(join(units(j_in), "-")) into $(join(units(j_out), "-")) with code $(d.connection_codes[n]).")
        end
        fits(o) = issubset(block_a(j_in), Set(o[2])) && issubset(block_b(j_out), Set(o[3]))
        chosen = something(findfirst(fits, options), 1)
        kept, rel, add = options[chosen]
        released[j_in] = rel
        added[j_out] = add
        for (from, to) in kept
            push!(flows, ("continue", tt.ToStation[j_in], units(j_in)[from], j_in, from, j_out, to,
                          tt.ArrivalToStation[j_in], tt.DepartureFromStation[j_out]))
        end
    end

    # Stored trains: all units of the stored train continue, extra units can only be coupled
    stored_a = Set(first.(stored_pairs))
    stored_b = Set(last.(stored_pairs))
    for (a, b) in stored_pairs
        options = [o for o in shunt_options(units(a), units(b), d.shunt_rules[d.storage_codes[b]]) if isempty(o[2])]
        if isempty(options)
            error("Stored train $(tt.TrainId[a]) -> $(tt.TrainId[b]) at $(tt.ToStation[a]): $(join(units(a), "-")) cannot become $(join(units(b), "-")).")
        end
        kept, _, add = options[1]
        released[a] = Int[]
        added[b] = add
        for (from, to) in kept
            push!(flows, ("stored", tt.ToStation[a], units(a)[from], a, from, b, to, tt.ArrivalToStation[a], tt.DepartureFromStation[b]))
        end
    end
    for j in d.last_trips
        j in stored_a || (released[j] = collect(1:length(units(j))))
    end
    for j in d.first_trips
        j in stored_b || (added[j] = collect(1:length(units(j))))
    end

    # GGV links: the block moves directly from train A to train B
    used_a = Dict{Int, Set{Int}}()
    used_b = Dict{Int, Set{Int}}()
    for (i, u) in enumerate(links_used)
        link = d.ggv_links[u.l]
        a, b = link.a_trip, link.b_trip
        pos_a, pos_b = link_pos[i]
        # the block must leave train A and join train B, otherwise take units of the same type that do
        function repair(pos, free, unit_list, used, label)
            all(p -> p in free && !(p in used), pos) && return pos
            push!(warnings, "GGV link $(tt.TrainId[a]) -> $(tt.TrainId[b]) at $(link.station): block $(join(u.block, "-")) is not at the " *
                            "$label side where units leave/join the train, units of the same type are used instead.")
            new_pos = Int[]
            for p in pos
                q = findfirst(q -> q in free && !(q in used) && !(q in new_pos) && unit_list[q] == unit_list[p], eachindex(unit_list))
                q === nothing && error("GGV link $(tt.TrainId[a]) -> $(tt.TrainId[b]): no free unit of type $(unit_list[p]).")
                push!(new_pos, q)
            end
            return new_pos
        end
        pos_a = repair(pos_a, released[a], units(a), get!(used_a, a, Set{Int}()), "A")
        pos_b = repair(pos_b, added[b], units(b), get!(used_b, b, Set{Int}()), "B")
        union!(used_a[a], pos_a)
        union!(used_b[b], pos_b)
        for (pa, pb) in zip(pos_a, pos_b)
            units(a)[pa] == units(b)[pb] || push!(warnings, "GGV link $(tt.TrainId[a]) -> $(tt.TrainId[b]): type $(units(a)[pa]) on train A becomes $(units(b)[pb]) on train B.")
            push!(flows, ("link", link.station, units(a)[pa], a, pa, b, pb, tt.ArrivalToStation[a], tt.DepartureFromStation[b]))
        end
    end

    # All other units go to or come from the station inventory
    last_set, first_set = Set(d.last_trips), Set(d.first_trips)
    for (j, positions) in released, p in positions
        p in get(used_a, j, Set{Int}()) && continue
        s, m = station_idx[tt.ToStation[j]], m_idx[units(j)[p]]
        push!(flows, ("depot_in", tt.ToStation[j], units(j)[p], j, p, 0, 0, tt.ArrivalToStation[j],
                      tt.ArrivalToStation[j] + uncouple_time(m, s, j in last_set)))
    end
    for (j, positions) in added, p in positions
        p in get(used_b, j, Set{Int}()) && continue
        s, m = station_idx[tt.FromStation[j]], m_idx[units(j)[p]]
        push!(flows, ("depot_out", tt.FromStation[j], units(j)[p], 0, 0, j, p, tt.DepartureFromStation[j],
                      tt.DepartureFromStation[j] - couple_time(m, s, j in first_set)))
    end

    foreach(w -> println("Warning: ", w), unique(warnings))
    sort!(flows, [:Time, :Kind, :FromTrip, :ToTrip, :FromPos, :ToPos])
    return flows
end


"""
Writes the results of a solved model to `Results/Analysis` and returns the key figures.

Files: CompAssignments (composition per trip), Inventory (start/end/idle units per station and type),
GGVLinks and StoredTrains (if used), UnitFlows (source and destination of every unit position, input of
`Models/Main_assignUnits.py`), MTrains (used candidate material trains) and Summary (settings, stages, key figures).

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
    if hasproperty(tt, :GGVId)
        assignments.GGVId = tt.GGVId[assignments.TripId] # used by the unit assignment
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

    # composition index of every trip (the empty composition for unused material trains)
    trip_comp = [findfirst(c -> value(y[c, j]) > 0.5, 1:C) for j in 1:J]

    # GGV links (to check which connections should be considered a GGV)
    links_used = NamedTuple[]
    if haskey(model, :ggv_index)
        for (i, (l, block, side_a, side_b)) in enumerate(model[:ggv_index])
            value(model[:ggv_block][i]) > 0.5 && push!(links_used, (l = l, block = block, side_a = side_a, side_b = side_b))
        end
        CSV.write(joinpath(out_dir, "GGVLinks_$(scenario)_$(timestamp).csv"), ggv_links_table(d, trip_comp, links_used))
    end

    # Stored trains, paired per station and composition with the longest standing train first
    stored_pairs = Tuple{Int, Int}[]
    if haskey(model, :stored_in_index)
        stored = DataFrame(Station = String[], StoredComposition = String[], TrainA = String[], TrainB = String[], ArrivalA = Int[],
                           DepartureB = Int[], Waiting = Int[], ShuntCode = String[], CompositionB = String[])
        trips_in = [(tt.ToStation[j], c, j) for (j, c) in model[:stored_in_index] if value(model[:stored_in][(j, c)]) > 0.5]
        trips_out = [(tt.FromStation[j], c, j) for (j, c) in model[:stored_out_index] if value(model[:stored_out][(j, c)]) > 0.5]
        for key in unique([(s, c) for (s, c, _) in trips_in])
            arriving = sort([j for (s, c, j) in trips_in if (s, c) == key], by = j -> tt.ArrivalToStation[j])
            departing = sort([j for (s, c, j) in trips_out if (s, c) == key], by = j -> tt.DepartureFromStation[j])
            for (a, b) in zip(arriving, departing)
                push!(stored_pairs, (a, b))
                push!(stored, (key[1], d.compositions[key[2]], tt.TrainId[a], tt.TrainId[b], tt.ArrivalToStation[a], tt.DepartureFromStation[b],
                               tt.DepartureFromStation[b] - tt.ArrivalToStation[a], d.storage_codes[b], d.compositions[trip_comp[b]]))
            end
        end
        sort!(stored, [:Station, :ArrivalA])
        CSV.write(joinpath(out_dir, "StoredTrains_$(scenario)_$(timestamp).csv"), stored)
    end

    # Unit flows: where the unit on every position of every trip comes from (input of the Python unit assignment)
    flows = get_unit_flows(d, trip_comp, links_used, stored_pairs; realloc_train_ends = model[:realloc_train_ends])
    CSV.write(joinpath(out_dir, "UnitFlows_$(scenario)_$(timestamp).csv"), flows)

    # Used candidate material trains
    mtrains = filter(row -> row.IsCandidate, assignments)
    if !isempty(mtrains)
        CSV.write(joinpath(out_dir, "MTrains_$(scenario)_$(timestamp).csv"), mtrains)
    end

    # Key figures
    kpis = (
        Scenario = scenario,
        # OPTIMAL only if every stage is, a later stage is only optimal given the result of the earlier ones
        Status = isempty(stage_results) ? "NOT SOLVED" : first(vcat(filter(!=("OPTIMAL"), stage_results.Status), "OPTIMAL")),
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
- `add_mtrain_candidates`, `mtrain_settings`, `joint_shunting`: See `load_model_data`
- `model_settings...`: Keyword arguments for `build_model`

# Returns
- `NamedTuple` with the key figures (see `write_results`)
"""
function run_scenario(scenario; execution_file, stages, add_mtrain_candidates = false, mtrain_settings = (;),
                      joint_shunting = true, data = nothing, model_settings...)
    if data === nothing
        data = load_model_data(execution_file; add_mtrain_candidates = add_mtrain_candidates, mtrain_settings = mtrain_settings,
                                joint_shunting = joint_shunting)
    end
    model = build_model(data; model_settings...)
    stage_results = solve_lexicographic!(model, stages)

    if !has_values(model)
        println("Scenario $scenario: no solution found.")
        return (Scenario = scenario, Status = isempty(stage_results) ? "NOT SOLVED" : stage_results.Status[end])
    end

    settings = merge((stages = join(stages, " > "), add_mtrain_candidates = add_mtrain_candidates, joint_shunting = joint_shunting), values(model_settings))
    return write_results(model, data, scenario, stage_results; settings = settings)
end
