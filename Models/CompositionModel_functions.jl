using DataFrames

project_root = dirname(@__DIR__)
include(joinpath(project_root, "DataTransformationScripts", "DataManipulation_functions.jl"))

"""
This function `get_smaller_df` filters train network data to a subset of stations and their connections:

**Key steps:**
1. Loads train routes from a CSV file and parses route strings into arrays
2. Uses a breadth-first search (via `to_explore` set) to find all neighbor stations connected to initial stations, excluding `bad_stations`
3. Builds a `neighbors` set containing all reachable stations, plus "Start" and "End" special stations
4. Filters both the timetable and connections DataFrames to only include trips between stations in the `neighbors` set
5. Prints summary statistics showing the reduction in stations and trips

**Parameters:**
- `to_explore`: Initial set of stations to explore
- `bad_stations`: Stations to exclude from traversal
- `timetable_data`: Full timetable DataFrame to filter
- `connections`: Full connections DataFrame to filter

**Returns:** Filtered `new_timetable_data` and `new_connections` DataFrames
"""

function get_smaller_df(to_explore, bad_stations, timetable_data, connections)
    # Read train routes and filter for routes left of Odense (OD)
    train_routes = CSV.read(joinpath(project_root, "DataManipulated", "train_routes.csv"), DataFrame)
    train_routes.Route = [split(str, r",\s*") for str in train_routes.Route]

    neighbors = Set{String}()
    
    while !isempty(to_explore)
        current = pop!(to_explore)
        if current in neighbors
            continue
        end
        
        new_neighbors = get_neighbor_stations(train_routes, current, bad_stations ∪ neighbors)
        push!(neighbors, current)
        union!(to_explore, new_neighbors)
    end

    total_stations = Set{String}()
    for route in train_routes.Route
        union!(total_stations, route)
    end

    push!(neighbors, "Start")
    push!(neighbors, "End")

    # Filter timetable data to only include trips that start and end at these stations
    new_timetable_data = filter(row -> (row.FromStation in neighbors) && (row.ToStation in neighbors), timetable_data)
    new_connections = filter(row -> (row.FromStation in neighbors) && (row.ToStation in neighbors), connections)
    
    println("Filtered timetable consists of ", length(neighbors), " stations (before: ", length(total_stations), "), and ", nrow(new_timetable_data), " trips (before: ", nrow(timetable_data), ").\n")
    return new_timetable_data, new_connections
end


"""
Generates a nested dictionary representing the count of each unit type within every composition.

This function builds a lookup structure that maps composition indices to a sub-dictionary 
of unit type indices and their respective counts. It parses composition strings by 
splitting them (using the "-" delimiter) and specifically handles the "empty" unit 
identifier by assigning it a count of zero.

# Arguments
- `compositions::Vector{String}`: A vector of composition strings (e.g., ["ICA-ERF", "ERF"])
- `unit_names::Vector{String}`: A vector of available unit type names

# Returns
- `Dict{Int, Dict{Int, Int}}`: A nested dictionary where the outer key is the composition 
  index and the inner key is the unit type index, mapping to the integer count of that unit.
"""
function get_comp_counts(compositions, unit_names)
  # This creates a nested lookup: counts_per_comp["ICA-ERF"]["ICA"] = 1
    return Dict(
        ci => Dict(mi => (m == "empty" ? 0 : count(==(m), split(c, "-"))) for (mi, m) in enumerate(unit_names))
        for (ci, c) in enumerate(compositions)
    )
end

"""
Identifies unique train compositions and maps them to unit count signatures.

This function aggregates raw composition strings into a set of unique, normalized definitions. 
It creates a "signature" (a vector of counts) for every unique combination of unit types, 
ensuring that different orderings of the same units are treated as the same composition. 
It also handles "empty" states and produces a matrix for mathematical modeling.

# Arguments
- `compositions_raw::Vector{String}`: A list of raw composition strings (e.g., ["ICA-ERF", "ERF-ICA"])
- `unit_names::Vector{String}`: A list of all possible unit type identifiers

# Returns
- `compositions::Vector{String}`: A sorted list of unique, pretty-formatted composition 
  labels (e.g., ["1xERF, 1xICA"])
- `counts_matrix::Matrix{Int}`: A 2D matrix where `counts_matrix[c, m]` is the number of 
  units of type `m` present in composition `c`
"""
function get_normalized_compositions(compositions_raw, unit_names)
    # 1. Use a Dictionary to store unique unit-count vectors as keys
    # Map: Vector{Int} (unit counts) => String (Pretty Name)
    unique_map = Dict{Vector{Int}, String}()

    for raw_name in compositions_raw
        # Count occurrences of each unit type for this raw composition string
        # We handle "empty" by setting its count to 0 in the matrix
        parts = split(raw_name, "-")
        signature = [u == "empty" ? 0 : count(==(u), parts) for u in unit_names]

        # If we haven't seen this combination of units before, create a name for it
        if !haskey(unique_map, signature)
            if all(signature .== 0) || raw_name == "empty"
                unique_map[signature] = "empty"
            else
                # Create a name like "1xERF, 1xICA"
                # We sort the labels so that order doesn't matter
                labels = ["$(signature[i])x$(unit_names[i])" 
                          for i in eachindex(unit_names) 
                          if signature[i] > 0 && unit_names[i] != "empty"]
                unique_map[signature] = join(sort(labels), ", ")
            end
        end
    end

    # 2. Extract unique signatures and sort them to keep indexing consistent
    # Sorting by the Pretty Name (String)
    sorted_signatures = sort(collect(keys(unique_map)), by = sig -> unique_map[sig])
    
    # 3. Create the outputs
    compositions = [unique_map[sig] for sig in sorted_signatures]
    
    C = length(compositions)
    M = length(unit_names)
    
    # Initialize a 2D Matrix of integers [C rows, M columns]
    counts_matrix = zeros(Int, C, M)
    for c in 1:C
        counts_matrix[c, :] = sorted_signatures[c]
    end

    return compositions, counts_matrix
end

"""
Computes the required coupling and decoupling actions for transitions between compositions.

This function determines the net change in unit counts for each rolling stock type when 
transitioning from one composition state to another. It is used to model the operational 
logic of adding (coupling) or removing (decoupling) units at stations.

# Arguments
- `counts_per_comp::Matrix{Int}`: The signature matrix from `get_normalized_compositions` 
  mapping composition indices to unit counts
- `unit_names::Vector{String}`: A list of all possible unit type identifiers

# Returns
- `coupled::Dict{Tuple{Int, Int, Int}, Int}`: A dictionary mapping `(unit_idx, from_comp, to_comp)` 
  to the number of units added during the transition
- `decoupled::Dict{Tuple{Int, Int, Int}, Int}`: A dictionary mapping `(unit_idx, from_comp, to_comp)` 
  to the number of units removed during the transition
"""
function get_coupling_matrices(counts_per_comp, unit_names)
    # Initialize the dictionaries for results
    # Key format: (unit_name, composition_from, composition_to)
    coupled = Dict{Tuple{Int, Int, Int}, Int}()
    decoupled = Dict{Tuple{Int, Int, Int}, Int}()
    
    # 3. Fill the dictionaries
    for m in 1:length(unit_names)
        for c_from in 1:size(counts_per_comp, 1)
            for c_to in 1:size(counts_per_comp, 1)
                # Calculate the change in number of units
                diff = counts_per_comp[c_to, m] - counts_per_comp[c_from, m]
                
                # Assign to the correct dictionary
                coupled[(m, c_from, c_to)] = max(0, diff)
                decoupled[(m, c_from, c_to)] = max(0, -diff)
            end
        end
    end
    
    return coupled, decoupled
end


"""
Determines which composition transitions are operationally feasible.

A transition from composition `c_from` to `c_to` is feasible if it consists of either only
coupling or only decoupling (or no change at all). Mixed transitions, where some units are
coupled and others decoupled in the same connection, are not allowed.

# Arguments
- `counts_per_comp::Matrix{Int}`: The signature matrix from `get_normalized_compositions`
  mapping composition indices to unit counts

# Returns
- `feasible::Matrix{Bool}`: A matrix where `feasible[c_from, c_to]` is true if the transition
  is allowed
"""
function get_feasible_transitions(counts_per_comp)
    C = size(counts_per_comp, 1)
    feasible = falses(C, C)

    for c_from in 1:C, c_to in 1:C
        diff = counts_per_comp[c_to, :] .- counts_per_comp[c_from, :]
        # only coupling (all diffs >= 0) or only decoupling (all diffs <= 0)
        feasible[c_from, c_to] = all(diff .>= 0) || all(diff .<= 0)
    end

    return feasible
end


"""
Builds composition definitions where the order of the units matters.

In contrast to `get_normalized_compositions`, "ICA-ERF" and "ERF-ICA" are kept as two different
compositions. The units are listed from the front to the rear of the train in driving direction.

# Arguments
- `compositions_raw::Vector{String}`: A list of raw composition strings (e.g., ["ICA-ERF", "ERF-ICA"])
- `unit_names::Vector{String}`: A list of all possible unit type identifiers

# Returns
- `compositions::Vector{String}`: A list of unique composition strings
- `comp_units::Vector{Vector{String}}`: The ordered units of each composition (empty for "empty")
- `counts_matrix::Matrix{Int}`: A 2D matrix where `counts_matrix[c, m]` is the number of
  units of type `m` present in composition `c`
"""
function get_ordered_compositions(compositions_raw, unit_names)
    compositions = unique(String.(compositions_raw))
    comp_units = [c == "empty" ? String[] : String.(split(c, "-")) for c in compositions]
    counts_matrix = [count(==(u), units) for units in comp_units, u in unit_names]

    return compositions, comp_units, counts_matrix
end


"""
Finds the train system (e.g. "IC100") of a train based on its category and train number.

# Arguments
- `train_id::Int`: The train number
- `category::String`: The train category (e.g. "IC"), needed since number ranges overlap between categories
- `system_mapping::DataFrame`: The "Train system mapping" sheet

# Returns
- `String` with the system name, or `nothing` if no system matches
"""
function get_train_system(train_id, category, system_mapping)
    for row in eachrow(system_mapping)
        if string(row.Category) == category && row."From number" <= train_id <= row."To number"
            return string(row."System name")
        end
    end
    return nothing
end


"""
Checks if composition `units_from` can be turned into `units_to` with a given shunting operation.

Only one operation is allowed per connection: coupling at the front, coupling at the rear,
decoupling at the front, decoupling at the rear, or no change. The operation is applied in the
arrival direction. If the train turns (e.g. shunt code "Vka"), the composition is reversed
afterwards, so the front becomes the rear.

# Arguments
- `units_from::Vector{String}`: Ordered units of the arriving composition
- `units_to::Vector{String}`: Ordered units of the departing composition
- `rule::NamedTuple`: Shunting rule from `get_shunt_rules`

# Returns
- `Bool`: true if the transition is feasible
"""
function is_feasible_shunt(units_from, units_to, rule)
    # departing composition seen in the arrival direction
    target = rule.turn ? reverse(units_to) : units_to
    n_from = length(units_from)
    n_to = length(units_to)
    k = n_to - n_from

    if target == units_from
        return true
    elseif k > 0 # coupling k units
        return (k <= rule.couple_front && target[k+1:end] == units_from) ||
               (k <= rule.couple_rear && target[1:n_from] == units_from)
    elseif k < 0 # decoupling -k units
        return (-k <= rule.uncouple_front && units_from[-k+1:end] == target) ||
               (-k <= rule.uncouple_rear && units_from[1:n_to] == target)
    end
    return false
end


"""
Reads the shunting rules (max. units coupled/decoupled at front/rear, turning) for each shunt code.

# Arguments
- `shunting_operations::DataFrame`: The "Shunting operations" sheet

# Returns
- `Dict{String, NamedTuple}`: Maps shunt code to its rule
"""
function get_shunt_rules(shunting_operations)
    return Dict(
        string(row."Shunt code") => (
            couple_front = Int(row."Couple front"),
            uncouple_front = Int(row."Uncouple front"),
            couple_rear = Int(row."Couple rear"),
            uncouple_rear = Int(row."Uncouple rear"),
            turn = Bool(row."Turn 1st outgoing")
        )
        for row in eachrow(shunting_operations)
    )
end


"""
Determines the feasible composition transitions (c1, c2) for every connection.

The shunt code of a connection is looked up in the "Trip cutpoints" sheet based on the train
system and the connection station (e.g. "aGk" for trains passing through, "Vka" for reversing
trains). For merged TrainIds (e.g. "11_4011") all parts are checked. Connections from "Start"
or to "End" are not checked, since the incoming or outgoing composition is always empty.
Connections without a shunt code (code "None") do not allow any change of the composition.
If the parts of a merged TrainId give different shunt codes, an error is thrown.

# Arguments
- `connections::DataFrame`: Connections from `build_connections`
- `timetable_data::DataFrame`: Timetable, used to get the train category of each train
- `comp_units::Vector{Vector{String}}`: Ordered units per composition from `get_ordered_compositions`
- `cutpoints::DataFrame`: The "Trip cutpoints" sheet
- `shunting_operations::DataFrame`: The "Shunting operations" sheet
- `system_mapping::DataFrame`: The "Train system mapping" sheet

# Returns
- `feasible_pairs::Vector{Vector{Tuple{Int, Int}}}`: For each connection n, all feasible (c1, c2)
- `connection_codes::Vector{String}`: For each connection n, the shunt code that was used
"""
function get_feasible_transitions_per_connection(connections, timetable_data, comp_units, cutpoints,
                                                 shunting_operations, system_mapping)
    C = length(comp_units)
    empty_idx = findfirst(isempty, comp_units)

    shunt_rules = get_shunt_rules(shunting_operations)
    station_codes = Dict(
        (string(row.TrainSystem), string(row."Cut station")) => string(row."Shunt code")
        for row in eachrow(cutpoints)
    )
    train_category = Dict(string(row.TrainId) => string(row.TrainCategory) for row in eachrow(timetable_data))

    # the feasible transitions only depend on the shunt code, so compute them once per code
    pairs_per_code = Dict(
        code => [(c1, c2) for c1 in 1:C, c2 in 1:C if is_feasible_shunt(comp_units[c1], comp_units[c2], rule)]
        for (code, rule) in shunt_rules
    )

    N = nrow(connections)
    feasible_pairs = Vector{Vector{Tuple{Int, Int}}}(undef, N)
    connection_codes = Vector{String}(undef, N)
    ambiguous_codes = String[]

    for n in 1:N
        if connections[n, "FromStation"] == "Start"
            connection_codes[n] = "Start"
            feasible_pairs[n] = [(empty_idx, c2) for c2 in 1:C]
        elseif connections[n, "ToStation"] == "End"
            connection_codes[n] = "End"
            feasible_pairs[n] = [(c1, empty_idx) for c1 in 1:C]
        else
            # merged TrainIds (e.g. "11_4011") consist of several train numbers, check all of them
            train_id = string(connections[n, "TrainId"])
            station = string(connections[n, "ConnectionStation"])
            codes = String[]
            for part in split(train_id, "_")
                system = get_train_system(parse(Int, part), train_category[train_id], system_mapping)
                haskey(station_codes, (system, station)) && push!(codes, station_codes[(system, station)])
            end
            unique!(codes)

            if isempty(codes)
                # no shunt code for this station and train system -> composition is not allowed to change
                connection_codes[n] = "None"
                feasible_pairs[n] = [(c, c) for c in 1:C]
            elseif length(codes) == 1
                connection_codes[n] = codes[1]
                feasible_pairs[n] = pairs_per_code[codes[1]]
            else
                push!(ambiguous_codes, "connection $n: TrainId $train_id at $station -> shunt codes $codes")
            end
        end
    end

    if !isempty(ambiguous_codes)
        error("$(length(ambiguous_codes)) connections have more than one shunt code in 'Trip cutpoints':\n" *
              join(ambiguous_codes, "\n"))
    end

    return feasible_pairs, connection_codes
end


"""
Calculates operational details for each rolling stock composition.

This function computes aggregated metrics for each composition by summing unit-level 
specifications (costs and seating capacity) weighted by their occurrence in the composition.

# Arguments
- `compositions::Vector`: A vector of composition identifiers
- `RS_Details::DataFrame`: A DataFrame containing unit specifications with columns including
  "Kilometer costs" and "Seats"
- `counts_per_comp::Dict`: A nested dictionary from `get_coupling_matrices()` mapping 
  composition indices to unit counts

# Returns
- `comp_costs::Dict{Int, Int}`: A dictionary mapping composition index to total operating cost
  (sum of per-kilometer costs for all units in the composition)
- `comp_seats::Dict{Int, Int}`: A dictionary mapping composition index to total seating capacity
  (sum of seats for all units in the composition)
"""
function get_composition_details(compositions, RS_Details, counts_per_comp)
    # Initialize the dictionary for composition costs
    comp_costs = Dict{Int, Int}()
    comp_seats = Dict{Int, Int}()
    
    for c in 1:length(compositions)
        # Calculate the cost for this composition
        cost = sum(counts_per_comp[c, m] * RS_Details[!, "Kilometer costs"][m] for m in 1:nrow(RS_Details))
        comp_costs[c] = cost

        # Calculate the seats for this composition
        seats = sum(counts_per_comp[c, m] * RS_Details[!, "Seats"][m] for m in 1:nrow(RS_Details))
        comp_seats[c] = seats
    end
    
    return comp_costs, comp_seats
end


"""
Parses composition strings into a flat list of individual rolling stock unit types.

This helper function deconstructs encoded strings (e.g., "2xICA" or "1xERF, 2xICA") into 
a vector of strings. It handles multipliers specified with 'x' and comma-separated 
multiple unit types.

# Arguments
- `comp_string`: A string or object convertible to a string representing the train 
  configuration (e.g., "2xICA, 1xERF")

# Returns
- `final_types::Vector{String}`: An ordered list of unit type names, where each 
  physical unit is represented as an individual entry (e.g., ["ICA", "ICA", "ERF"])
"""