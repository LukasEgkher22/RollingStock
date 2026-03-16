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

timetable_data = add_terminal_rows(timetable_data)

# define connections variable (Two trips are connected if FirstTrip.ToStation == SecondTrip.FromStation and FirstTrip.TrainId == SecondTrip.TrainId)
connections = build_connections(timetable_data)

if use_smaller_dataset
    start_station = ["AR/86"]
    bad_stations = Set(["GP/86", "HP/86", "SNO/86", "OD/86", "TL/86", "KD/86", "LK/86", "ADF/80", "HMB/80", "PA/86", "RQ/86", "ASW/80", "AB/86", "HN/86", "HA/86", "LG/86", "BR/86"])

    timetable_data, connections = get_smaller_df(start_station, bad_stations, timetable_data, connections)
end

# timetable_data = timetable_data[1:50, :]
# println("Reduced timetable again to ", nrow(timetable_data), " trips.\n")

# Read specific sheets from Excel file
excel_file = XLSX.readxlsx(joinpath(project_root, "Data", "Base Day TUE.xlsx"))
RS_Data = DataFrame(XLSX.gettable(excel_file["Rolling Stock"]))
night_capacity = DataFrame(XLSX.gettable(excel_file["Night capacity"]))
compositions = DataFrame(XLSX.gettable(excel_file["Composition groups"], header=false))[!, 1]
push!(compositions, "start_end")

RS_Data.Name = push!(RS_Data.Name, "start_end")
RS_Data[!, "Kilometer costs"] = push!(RS_Data[!, "Kilometer costs"], 0)
RS_Data[!, "Seats"] = push!(RS_Data[!, "Seats"], 0)
RS_Data[!, "Unit cost"] = push!(RS_Data[!, "Unit cost"], 0)
RS_Data[!, "Availability"] = push!(RS_Data[!, "Availability"], 10000)

# Access columns from rolling_stock_data
# RS_Data[!, ["Name", "Seats", "Kilometer costs", "Unit cost", "Availability", "Electrified"]]

# Get unique stations from timetable
stations = unique(timetable_data.FromStation ∪ timetable_data.ToStation)

# define number of types and units
M = nrow(RS_Data)
C = length(compositions)
n_trips = nrow(timetable_data)
N = nrow(connections)
S = length(stations)
time = unique(vcat(timetable_data.DepartureFromStation, timetable_data.ArrivalToStation))
T = length(time)

# Get composition counts [1:C, 1:M], coupling and decoupling matrices [1:M, 1:C, 1:C]
comp_number, coupled_dict, decoupled_dict = get_coupling_matrices(compositions, RS_Data.Name)

# Get composition costs per kilometer [1:C]
comp_costs, comp_seats = get_composition_details(compositions, RS_Data[!, ["Kilometer costs", "Seats"]], comp_number)


# check comp_number
# for c in 1:C
#     println("Composition ", c, ": ", compositions[c, 1])
#     for m in 1:M 
#         if comp_number[c][m] > 0 println(RS_Data.Name[m], ": ", comp_number[c][m], " units") end
#     end
# end

# check coupled_dict and uncoupled_dict
# c1 = 36
# c2 = 8
# println("Decoupling/Coupling check:\nFrom composition: ", compositions[c1], "\nTo composition: ", compositions[c2])
# for m in 1:M
#     if coupled_dict[(m, c1, c2)] > 0
#         println("Coupled ", coupled_dict[(m, c1, c2)], " unit of type ", RS_Data.Name[m])
#     end
#     if decoupled_dict[(m, c1, c2)] > 0
#         println("Decoupled ", decoupled_dict[(m, c1, c2)], " unit of type ", RS_Data.Name[m])
#     end
# end
# print("\n")

# # Check composition costs
# for c in 1:C
#     println("Composition ", c, ": ", compositions[c, 1], " - Cost per km: ", comp_costs[c], " - Seats: ", comp_seats[c])
# end

# define penalty parameters for coupling and decoupling (example: 100 per unit)
coupling_penalty = 10
decoupling_penalty = 10

timetable_data.Index = 1:n_trips
# print(timetable_data)

# -----------------------------------------------------------
# CREATE MODEL
# -----------------------------------------------------------
model = Model(Gurobi.Optimizer)

# --- 1. Variables ---

# y[c, j] = 1 if trip j is served by composition c
@variable(model, y[c=1:C, j=1:n_trips], Bin)

# x[c1, c2, n] = 1 if composition c1 and composition c2 are used for connection n 
@variable(model, x[c1=1:C, c2=1:C, n=1:N], Bin)

# v1[m, n] defines how many units of type m are coupled in connection n, v2 for decoupling
@variable(model, v1[m=1:M, n=1:N] >= 0)
@variable(model, v2[m=1:M, n=1:N] >= 0)

# storage[m, n, t] - non-negative number of units of type m stored at station s at time t
@variable(model, storage[m=1:M, s=1:S, t=1:T] >= 0)

# s_start[m, s] number of train units of type m starting at station s
@variable(model, s_start[m=1:M, s=1:S] >= 0)

# Objective: Minimize total cost (km_costs * distance)
# TODO: add an estimate for unit costs
@objective(model, Min, sum(y[c,j] * comp_costs[c] * timetable_data.Distance_KM[j] for c in 1:C, j in 1:n_trips) # distance costs for each composition used
    + sum(v1[m, n] * coupling_penalty for m in 1:M, n in 1:N)   # make coupling/decoupling less attractive
    + sum(v2[m, n] * decoupling_penalty for m in 1:M, n in 1:N)
    + sum(sum(s_start[m, s] for s in 1:S) * RS_Data[!, "Unit cost"][m] for m in 1:M) # unit cost for each unit that starts
)

# Fix composition 36 (start_end) for trips starting at "Start" or ending at "End"
for j in 1:n_trips
    if timetable_data.FromStation[j] == "Start" || timetable_data.ToStation[j] == "End"
        fix(y[36, j], 1; force=true)
    end
end

# # C. Global Station Balance (Type-based overnight requirement)
# # "The number of units of type m starting at s must equal the number ending at s"
# # for m in 1:M, s in stations
# #     @constraint(model, 
# #         sum(s_start[m, n, s] for n in 1:N[m]) == 
# #         sum(s_end[m, n, s] for n in 1:N[m])
# #     )
# # end

# Demand Coverage
for j in 1:n_trips
    @constraint(model, sum(y[c, j] * comp_seats[c] for c in 1:C) >= timetable_data.Demand[j])
end

# Each trip must have EXACTLY one composition assigned
for j in 1:n_trips
    @constraint(model, sum(y[c, j] for c in 1:C) == 1)
end

# Each connection must have EXACTLY one composition transition assigned
for n in 1:N
    @constraint(model, sum(x[c1, c2, n] for c1 in 1:C, c2 in 1:C) == 1)
end

# Define how many units of each type are decoupled and coupled in a connection
for m in 1:M, n in 1:N
    @constraint(model, v1[m, n] == sum(coupled_dict[(m, c1, c2)] * x[c1, c2, n] for c1 in 1:C, c2 in 1:C))
    @constraint(model, v2[m, n] == sum(decoupled_dict[(m, c1, c2)] * x[c1, c2, n] for c1 in 1:C, c2 in 1:C))
end

# define storage variable
for m in 1:M, s in 1:S, t in 1:T
    earlier_connections = [n for n in 1:N if (connections[n, "DepartureFromConnection"] <= time[t]) && (connections[n, "ConnectionStation"] == stations[s])]
    @constraint(model, storage[m, s, t] == s_start[m, s] + sum(v2[m, n] - v1[m, n] for n in earlier_connections))
end

# for each trip j, if composition c is assigned, then the required units must be available at the departure station at the departure time
# for j in 1:n_trips, c in 1:C
#     departure_time = timetable_data.DepartureFromStation[j]
#     departure_station = timetable_data.FromStation[j]
#     required_units = comp_number[c]
    
#     # Find the time index for the departure time
#     t_idx = findfirst(==(departure_time), time)
#     s_idx = findfirst(==(departure_station), stations)
    
#     if t_idx !== nothing && s_idx !== nothing
#         for m in 1:M
#             @constraint(model, storage[m, s_idx, t_idx] >= required_units[m] * y[c, j])
#         end
#     end
# end

# model capacity constraint per type over s_start variable
for m in 1:M
    @constraint(model, sum(s_start[m, s] for s in 1:S) <= RS_Data.Availability[m])
end

# Solve the model
optimize!(model)

# Print results
println("\n--- OPTIMIZATION RESULTS ---")
println("Status: ", termination_status(model))

if termination_status(model) == OPTIMAL
    println("Total Cost: \$", round(objective_value(model), digits=2))

    println("\n--- COMPOSITION ASSIGNMENTS ---")
    # Collect assignments
    assignments = DataFrame(
        TripId = Int[],
        TrainId = Int[],
        FromStation = String[],
        ToStation = String[],
        Departure = String[],
        Arrival = String[],
        Demand = Int[],
        Composition = String[]
    )

    for j in 1:n_trips
        assigned_comps = [c for c in 1:C if value(y[c, j]) > 0.5]
        for c in assigned_comps
            push!(assignments, (
                TripId = j,
                TrainId = timetable_data.TrainId[j],
                FromStation = timetable_data.FromStation[j],
                ToStation = timetable_data.ToStation[j],
                Departure = timetable_data.DepartureFromStation[j],
                Arrival = timetable_data.ArrivalToStation[j],
                Demand = timetable_data.Demand[j],
                Composition = string(compositions[c])
            ))
            # println("Trip $j (", timetable_data.FromStation[j], " -> ", timetable_data.ToStation[j], 
            #         ", Depart: ", timetable_data.DepartureFromStation[j], 
            #         ", Arrive: ", timetable_data.ArrivalToStation[j], 
            #         ", TrainId: ", timetable_data.TrainId[j], 
            #         ", Demand: ", timetable_data.Demand[j], 
            #         ") is served by Composition $c (", compositions[c], ")")
        end
    end

    # Group by TrainId, sort by earliest departure, and save to CSV
    grouped = groupby(assignments, :TrainId)
    ordered_assignments = DataFrame()
    for g in grouped
        sorted_g = sort(g, :Departure)
        append!(ordered_assignments, sorted_g)
    end
    CSV.write(joinpath(project_root, "results_composition_assignments.csv"), ordered_assignments)

    println("\n--- STARTING TRAINS AT STATIONS ---")
    for m in 1:M
        for s in 1:S
            n_start = value(s_start[m, s])
            if n_start > 0.5
                println("Type: ", RS_Data.Name[m], " starts ", round(n_start), " trains at station ", stations[s])
            end
        end
    end
else
    println("No optimal solution found.")
end