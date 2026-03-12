using DataFrames

project_root = dirname(@__DIR__)
include(joinpath(project_root, "DataTransformationScripts", "functions.jl"))

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

    # Filter timetable data to only include trips that start and end at these stations
    new_timetable_data = filter(row -> (row.FromStation in neighbors) && (row.ToStation in neighbors), timetable_data)
    new_connections = filter(row -> (row.FromStation in neighbors) && (row.ToStation in neighbors), connections)
    
    println("Filtered timetable consists of ", length(neighbors), " stations (before: ", length(total_stations), "), and ", nrow(new_timetable_data), " trips (before: ", nrow(timetable_data), ").\n")
    return new_timetable_data, new_connections
end

function get_coupling_matrices(compositions, unit_names)
    # 1. Pre-calculate the counts of each unit in each composition
    # This creates a nested lookup: counts_per_comp["ICA-ERF"]["ICA"] = 1
    counts_per_comp = Dict(
        ci => Dict(mi => count(==(m), split(c, "-")) for (mi, m) in enumerate(unit_names))
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