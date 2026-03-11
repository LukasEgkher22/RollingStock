using CSV
using DataFrames
using JuMP
using Gurobi
using XLSX


project_root = dirname(@__DIR__)

include(joinpath(project_root, "DataTransformationScripts", "functions.jl"))
include(joinpath(project_root, "Models", "CompositionModel_functions.jl"))

# parameters
use_smaller_dataset = true

# Read merged data from CSV
timetable_data = CSV.read(joinpath(project_root, "DataManipulated", "merged_data.csv"), DataFrame)

if use_smaller_dataset
    # Read train routes and filter for routes left of Odense (OD)
    train_routes = CSV.read(joinpath(project_root, "DataManipulated", "train_routes.csv"), DataFrame)
    train_routes.Route = [split(str, r",\s*") for str in train_routes.Route]

    neighbors = Set{String}()
    
    to_explore = ["AR/86"]
    bad_stations = Set(["GP/86", "HP/86", "SNO/86", "OD/86", "TL/86", "KD/86", "LK/86", "ADF/80", "HMB/80", "PA/86", "RQ/86", "ASW/80", "AB/86", "HN/86", "HA/86", "LG/86", "BR/86"])

    while !isempty(to_explore)
        current = pop!(to_explore)
        if current in neighbors
            continue
        end
        
        new_neighbors = get_neighbor_stations(train_routes, current, bad_stations ∪ neighbors)
        push!(neighbors, current)
        union!(to_explore, new_neighbors)
    end

    unique_stations = Set{String}()
    for route in train_routes.Route
        union!(unique_stations, route)
    end

    # Filter timetable data to only include trips that start or end at these stations
    timetable_data = filter(row -> (row.FromStation in neighbors) || (row.ToStation in neighbors), timetable_data)
    println("Filtered timetable has ", nrow(timetable_data), " trips.")
end

timetable_data = timetable_data[1:50, :]
print("\nFiltered timetable has ", nrow(timetable_data), " trips.\n")


# Read specific sheets from Excel file
excel_file = XLSX.readxlsx(joinpath(project_root, "Data", "Base Day TUE.xlsx"))
rolling_stock_data = DataFrame(XLSX.gettable(excel_file["Rolling Stock"]))
night_capacity = DataFrame(XLSX.gettable(excel_file["Night capacity"]))
compositions = DataFrame(XLSX.gettable(excel_file["Composition groups"], header=false))

# Access columns from rolling_stock_data
Unit_name = rolling_stock_data.Name
Unit_seats = rolling_stock_data.Seats
Unit_km_costs = rolling_stock_data[!, "Kilometer costs"]
Unit_costs = rolling_stock_data[!, "Unit cost"]
Unit_availability = rolling_stock_data.Availability
Unit_electrified = rolling_stock_data.Electrified

# define number of types and units
M = nrow(rolling_stock_data)
C = nrow(compositions)
P = length(Unit_name)

# Get coupling and decoupling matrices
CompNumber, coupled_dict, decoupled_dict = get_coupling_matrices(compositions, Unit_name)

# define more sets

# Get unique stations from timetable
stations = unique(timetable_data.FromStation ∪ timetable_data.ToStation)

n_trips = nrow(timetable_data)
timetable_data.Index = 1:n_trips
# print(timetable_data)

# -----------------------------------------------------------
# CREATE MODEL
# -----------------------------------------------------------
model = Model(Gurobi.Optimizer)

# --- 1. Variables ---

# y[c, j] = 1 if trip j is served by composition c
@variable(model, y[c=1:C, j=1:n_trips], Bin)



# # x[m, n, j] = 1 if unit n of type m performs trip j
# @variable(model, x[m=1:M, n=1:N[m], j=1:n_trips], Bin)

# # s_start[m, n, s] = 1 if unit (m,n) starts the day at station s
# @variable(model, s_start[m=1:M, n=1:N[m], s=stations], Bin)

# # s_end[m, n, s] = 1 if unit (m,n) ends the day at station s
# @variable(model, s_end[m=1:M, n=1:N[m], s=stations], Bin)

# # use type of train m for trip j
# @variable(model, use_group_12[1:n_trips], Bin) # 1 if trip uses Type 1 or 2
# @variable(model, use_type[3:7, 1:n_trips], Bin) # 1 if trip uses Type m (3,4,5,6,7)

# # Objective: Minimize total cost (km_costs * distance + unit_costs)
# @objective(model, Min, sum(x[m, n, j] * Unit_km_costs[m] * timetable_data.Distance_KM[j] for m in 1:M, n in 1:N[m], j in 1:n_trips)
#                         + sum(Unit_costs[m] * s_start[m, n, s] for m in 1:M, n in 1:N[m], s in stations))

# # --- 2. Constraints ---

# # A. A unit either starts and ends or is not used at all
# for m in 1:M, n in 1:N[m]
#     @constraint(model, sum(s_start[m, n, s] for s in stations) <= 1)
#     @constraint(model, sum(s_end[m, n, s] for s in stations) <= 1)
#     @constraint(model, sum(s_start[m, n, s] for s in stations) == sum(s_end[m, n, s] for s in stations)) # If it starts somewhere, it must end somewhere
# end

# # A.2 Flow conservation at stations (all that arrives or is already there, must also depart, or end there)
# for m in 1:M, s in stations
#     # For each station, the number of units arriving must equal the number departing (flow conservation)
#     @constraint(model, 
#         sum(s_start[m, n, s] for n in 1:N[m]) + 
#         sum(x[m, n, j] for n in 1:N[m], j in 1:n_trips if timetable_data.ToStation[j] == s) ==
#         sum(s_end[m, n, s] for n in 1:N[m]) + 
#         sum(x[m, n, j] for n in 1:N[m], j in 1:n_trips if timetable_data.FromStation[j] == s)
#     )
# end

# # B. Chronology (Preventing "Time Travel")
# # For a specific unit at a specific station, it must have arrived BEFORE it departs.
# for s in stations
#     # Get all events at this station sorted by time
#     deps = filter(r -> r.FromStation == s, timetable_data)
#     arrs = filter(r -> r.ToStation == s, timetable_data)
    
#     events = []
#     for r in eachrow(deps) push!(events, (time=r.DepartureFromStation, type=:dep, index=r.Index)) end
#     for r in eachrow(arrs) push!(events, (time=r.ArrivalToStation, type=:arr, index=r.Index)) end
    
#     # Sort events: Arrivals at the same time as departures are processed FIRST
#     sort!(events, by = x -> (x.time, x.type == :dep))

#     for m in 1:M, n in 1:N[m]
#         for i in 1:length(events)
#             # We look at the "state" of unit (m,n) at station s after event i
#             current_events = events[1:i]
#             arr_so_far = [e.index for e in current_events if e.type == :arr]
#             dep_so_far = [e.index for e in current_events if e.type == :dep]
            
#             # Unit (m,n) is at station s ONLY if it started there or arrived there, 
#             # and hasn't left yet. This value must be 0 or 1.
#             @constraint(model, 
#                 s_start[m, n, s] + 
#                 sum(x[m, n, j] for j in arr_so_far; init=0) - 
#                 sum(x[m, n, j] for j in dep_so_far; init=0) >= 0
#             )
#         end
#     end
# end

# # C. Global Station Balance (Type-based overnight requirement)
# # "The number of units of type m starting at s must equal the number ending at s"
# # for m in 1:M, s in stations
# #     @constraint(model, 
# #         sum(s_start[m, n, s] for n in 1:N[m]) == 
# #         sum(s_end[m, n, s] for n in 1:N[m])
# #     )
# # end

# # D. Demand Coverage (Allows coupling/multiple units)
# for j in 1:n_trips
#     @constraint(model, sum(x[m, n, j] * rolling_stock_data.Seats[m] 
#                            for m in 1:M, n in 1:N[m]) >= timetable_data.Demand[j])
# end

# # E. Symmetry Breaking
# # for each type, unit n can only perform trips if unit n-1 is also performing trips (enforces order of usage)
# for m in 1:M, n in 1:N[m]-1
#     @constraint(model, sum(x[m, n, j] for j in 1:n_trips) >= 
#                        sum(x[m, n+1, j] for j in 1:n_trips))
# end

# # F. Link x and start (if unit does not start, it cannot perform trips
# for m in 1:M, n in 1:N[m]
#     @constraint(model, sum(x[m, n, j] for j in 1:n_trips) <= Unit_availability[m] * sum(s_start[m, n, s] for s in stations)) # Big-M
# end

# # G. Electrified routes can only be served by electric units
# electrified_m = findall(==(1), Unit_electrified)
# non_electrified_tracks = findall(==(false), timetable_data.Electrified)
# for m in electrified_m, j in non_electrified_tracks
#     for n in 1:N[m]
#         fix(x[m, n, j], 0; force=true)
#     end
# end

# # I. Type-based usage constraints
# for j in 1:n_trips
#     # This prevents Type 1/2 and the other types from being used together.
#     @constraint(model, use_group_12[j] + sum(use_type[m, j] for m in 3:7) <= 1)

#     @constraint(model, sum(x[m,n,j] for m in 1:2, n in 1:N[m]) <= 5 * use_group_12[j]) # Type 1 and 2: Max 5 units combined
#     for m in [3,4,6]
#         @constraint(model, sum(x[m,n,j] for n in 1:N[m]) <= 1 * use_type[m, j]) # Type 3, 4 and 6: Max 1 unit each
#     end
#     @constraint(model, sum(x[5,n,j] for n in 1:N[5]) <= 2 * use_type[5, j]) # Type 5: Max 2 units
#     @constraint(model, sum(x[7,n,j] for n in 1:N[7]) <= 4 * use_type[7, j]) # Type 7: Max 4 units
# end

# # Solve the model
# optimize!(model)

# # Print results
# println("\n--- OPTIMIZATION RESULTS ---")
# println("Status: ", termination_status(model))

# if termination_status(model) == OPTIMAL
#     println("Total Cost: \$", round(objective_value(model), digits=2))
    
#     println("\n--- UNIT ROUTING DETAILS ---")
#     for m in 1:M
#         println("\nUnit Type: ", Unit_name[m], " (Seats: ", Unit_seats[m], ")")
#         for n in 1:N[m]
#             assigned_trips = findall(j -> value(x[m, n, j]) > 0.5, 1:n_trips)
#             # for j in assigned_trips
#             #     print("  Value of x[", m, ", ", n, ", ", j, "]: ", [value(x[m, n, j])], "\n")
                
#             # end
#             # for s in stations
#             #     if value(s_start[m, n, s]) > 0.5 || value(s_end[m, n, s]) > 0.5
#             #         print("  Value of s_start[", m, ", ", n, ", ", s, "]: ", [value(s_start[m, n, s])], "\n")
#             #         print("  Value of s_end[", m, ", ", n, ", ", s, "]: ", [value(s_end[m, n, s])], "\n")
#             #     end 
#             # end
            
            
#             if !isempty(assigned_trips)
#                 println("  Unit #$n:")
                
#                 # Starting station
#                 start_station = [s for s in stations if value(s_start[m, n, s]) > 0.5]
#                 if !isempty(start_station)
#                     println("    Start at: ", start_station[1])
#                 end
                
#                 # Trips
#                 for j in sort(assigned_trips, by = i -> timetable_data.DepartureFromStation[i])
#                     trip = timetable_data[j, :]
#                     println("    Trip $j: ", trip.FromStation, " -> ", trip.ToStation, 
#                             " (Depart: ", trip.DepartureFromStation, ", Arrive: ", trip.ArrivalToStation, 
#                             ", TrainId: ", trip.TrainId, ", Demand: ", trip.Demand, ")")
#                 end
                
#                 # Ending station
#                 end_station = [s for s in stations if value(s_end[m, n, s]) > 0.5]
#                 if !isempty(end_station)
#                     println("    End at: ", end_station[1])
#                 end
#             end
#         end
#     end
# else
#     println("No optimal solution found.")
# end