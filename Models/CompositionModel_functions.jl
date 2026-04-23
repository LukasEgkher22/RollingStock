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