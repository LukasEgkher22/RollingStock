using DataFrames

project_root = dirname(@__DIR__)
include(joinpath(project_root, "DataTransformationScripts", "functions.jl"))

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
Calculates coupling and decoupling matrices for rolling stock compositions.

This function analyzes the differences in unit composition between source and destination 
compositions, determining which units need to be coupled (added) and which need to be 
decoupled (removed) for each transition.

# Arguments
- `compositions::Vector`: A vector of composition identifiers, where each composition is 
  represented as a dash-separated string of unit names (e.g., "ICA-ERF-ICA")
- `unit_names::Vector`: A vector of unit names corresponding to the rolling stock types

# Returns
- `counts_per_comp::Dict`: A nested dictionary mapping (composition_index => (unit_index => count))
  that stores the quantity of each unit type in each composition
- `coupled::Dict{Tuple{Int, Int, Int}, Int}`: A dictionary with keys (unit, from_composition, to_composition)
  storing the number of units to couple (add) during composition transitions
- `decoupled::Dict{Tuple{Int, Int, Int}, Int}`: A dictionary with keys (unit, from_composition, to_composition)
  storing the number of units to decouple (remove) during composition transitions
"""
function get_coupling_matrices(compositions, unit_names)
    # 1. Pre-calculate the counts of each unit in each composition
    # This creates a nested lookup: counts_per_comp["ICA-ERF"]["ICA"] = 1
    counts_per_comp = Dict(
        ci => Dict(mi => (m == "start_end" ? 0 : count(==(m), split(c, "-"))) for (mi, m) in enumerate(unit_names))
        for (ci, c) in enumerate(compositions)
    )
    
    # 2. Initialize the dictionaries for results
    # Key format: (unit_name, composition_from, composition_to)
    coupled = Dict{Tuple{Int, Int, Int}, Int}()
    decoupled = Dict{Tuple{Int, Int, Int}, Int}()
    
    # 3. Fill the dictionaries
    for m in 1:length(unit_names)
        for c_from in 1:length(compositions)
            for c_to in 1:length(compositions)
                # Calculate the change in number of units
                diff = counts_per_comp[c_to][m] - counts_per_comp[c_from][m]
                
                # Assign to the correct dictionary
                coupled[(m, c_from, c_to)] = max(0, diff)
                decoupled[(m, c_from, c_to)] = max(0, -diff)
            end
        end
    end
    
    return counts_per_comp, coupled, decoupled
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
        cost = sum(counts_per_comp[c][m] * RS_Details[!, "Kilometer costs"][m] for m in 1:nrow(RS_Details))
        comp_costs[c] = cost

        # Calculate the seats for this composition
        seats = sum(counts_per_comp[c][m] * RS_Details[!, "Seats"][m] for m in 1:nrow(RS_Details))
        comp_seats[c] = seats
    end
    
    return comp_costs, comp_seats
end