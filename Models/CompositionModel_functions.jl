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

function get_comp_counts(compositions, unit_names)
  # This creates a nested lookup: counts_per_comp["ICA-ERF"]["ICA"] = 1
    return Dict(
        ci => Dict(mi => (m == "empty" ? 0 : count(==(m), split(c, "-"))) for (mi, m) in enumerate(unit_names))
        for (ci, c) in enumerate(compositions)
    )
end

"""
    get_normalized_compositions(compositions_raw, unit_names)

Returns:
1. `compositions`: A Vector of unique, normalized composition names (String).
2. `counts_matrix`: A 2D Matrix{Int} where [c, m] is the count of unit type m in composition c.
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
Parses composition strings like "2xICA" or "ICA" into a list of types.
"""
function _parse_composition(comp_string)
    s = string(comp_string)
    # 1. Split by comma first (e.g., "1xERF, 2xICA" -> ["1xERF", " 2xICA"])
    segments = split(s, ',')
    
    final_types = String[]
    
    for segment in segments
        clean_segment = strip(segment) # Remove leading/trailing spaces
        
        if occursin('x', clean_segment)
            # Handle "2xICA"
            parts = split(clean_segment, 'x')
            # The first part is the number, the second is the type
            count_str = strip(parts[1])
            type_name = strip(parts[2])
            
            count = parse(Int, count_str)
            for _ in 1:count
                push!(final_types, type_name)
            end
        elseif clean_segment != ""
            # Handle single units like "ICA"
            push!(final_types, clean_segment)
        end
    end
    return final_types
end


function assign_unit_ids(df::DataFrame; file_title::String = "TrainModel")
    timestamp = Dates.format(Dates.now(), "yyyy-mm-dd_HHMMSS")
    summary_filename = "summary_$(file_title)_$(timestamp).txt"
    result_filename = "UnitAssignment_$(file_title)_$(timestamp).csv"
    
    # Setup Data
    working_df = sort(df, :Departure)
    has_ggv = "GGVId" in names(df)
    
    # Unit Tracker: UID => (Station, AvailableTime, LastTrainId, LastGGVId)
    # This allows us to track exactly where every physical unit is at all times.
    unit_registry = Dict{String, NamedTuple{(:station, :time, :tid, :gid), Tuple{String, Int, String, String}}}()
    
    unit_counters = Dict{String, Int}()
    unit_start_locations = Dict{String, String}()
    assigned_rows = []

    for row in eachrow(working_df)
        tid = string(row.TrainId)
        gid = has_ggv ? string(row.GGVId) : "-1"
        st = string(row.FromStation)
        dep = Int(row.Departure)
        needed_types = _parse_composition(row.Composition)
        
        trip_units = String[]
        
        for utype in needed_types
            # Find candidate units of this type currently at this station and ready
            candidates = String[]
            for (uid, status) in unit_registry
                if startswith(uid, utype * "_") && status.station == st && status.time <= dep
                    push!(candidates, uid)
                end
            end
            
            chosen_uid = ""
            
            if !isempty(candidates)
                # PRIORITY 1: Same TrainId (Continuity)
                idx = findfirst(u -> unit_registry[u].tid == tid, candidates)
                
                # PRIORITY 2: Same GGVId
                if idx === nothing && gid != "-1"
                    idx = findfirst(u -> unit_registry[u].gid == gid, candidates)
                end
                
                # PRIORITY 3: Longest waiting unit (Earliest availability)
                if idx === nothing
                    sort!(candidates, by = u -> unit_registry[u].time)
                    idx = 1
                end
                
                chosen_uid = candidates[idx]
            else
                # PRIORITY 4: Spawn New
                unit_counters[utype] = get(unit_counters, utype, 0) + 1
                chosen_uid = "$(utype)_$(unit_counters[utype])"
                unit_start_locations[chosen_uid] = st
            end
            
            # Update Registry: Unit is now busy until it arrives at ToStation
            # We temporarily set station to "TRANSIT" so it can't be picked up by 
            # another trip starting at the same time (handling the GGV split bug)
            unit_registry[chosen_uid] = (station="TRANSIT", time=Int(row.Arrival), tid=tid, gid=gid)
            push!(trip_units, chosen_uid)
        end
        
        # After assigning all units for this trip, finalize their arrival at the ToStation
        for uid in trip_units
            old_status = unit_registry[uid]
            unit_registry[uid] = (station=string(row.ToStation), time=old_status.time, tid=tid, gid=gid)
            
            # Create output row
            new_row = DataFrame(row)
            new_row.UnitSpecificId .= uid
            push!(assigned_rows, new_row)
        end
    end

    # 4. Finalization
    result_df = vcat(assigned_rows...)
    
    # 5. Summary Generation
    summary_dict = Dict{String, Int}()
    summary_io = IOBuffer()
    println(summary_io, "--- Unit Assignment Summary: $file_title ---")
    println(summary_io, "Generated: $timestamp")
    
    total_units = 0
    for utype in sort(collect(keys(unit_counters)))
        count = unit_counters[utype]
        println(summary_io, "Type $utype: $count units")
        summary_dict[utype] = count
        total_units += count
    end
    println(summary_io, "TOTAL UNIQUE UNITS: $total_units")
    println(summary_io, "\n[Initial Deployment]")
    for uid in sort(collect(keys(unit_start_locations)))
        println(summary_io, "$uid starts at $(unit_start_locations[uid])")
    end
    
    summary_text = String(take!(summary_io))

    # 6. File Writing
    sort!(result_df, [:UnitSpecificId, :Departure])
    CSV.write(result_filename, result_df)
    open(summary_filename, "w") do f write(f, summary_text) end

    println("Files generated: $result_filename, $summary_filename")
    return result_df, summary_dict
end