using CSV
using DataFrames
using JuMP
using Gurobi
using XLSX
import Dates


project_root = dirname(@__DIR__)

include(joinpath(project_root, "DataTransformationScripts", "DataManipulation_functions.jl"))
include(joinpath(project_root, "Models", "CompositionModel_functions.jl"))

# parameters
use_smaller_dataset = false
filter_on_trainId = false

# Read merged data from CSV
timetable_data = CSV.read(joinpath(project_root, "DataManipulated", "aggregated_trips_with_terminals.csv"), DataFrame)
connections = build_connections(timetable_data)

if use_smaller_dataset
    start_station = ["AR/86"]
    bad_stations = Set(["GP/86", "HP/86", "SNO/86", "OD/86", "TL/86", "KD/86", "LK/86", "ADF/80", "HMB/80", "PA/86", "RQ/86", "ASW/80", "AB/86", "HN/86", "HA/86", "LG/86", "BR/86"])

    timetable_data, connections = get_smaller_df(start_station, bad_stations, timetable_data, connections)
end

if filter_on_trainId
    selected_trainIds = [1199, 181, 100, 10, 101] # example train IDs to keep
    timetable_data = filter(row -> row.TrainId in selected_trainIds, timetable_data)
    connections = filter(row -> row.TrainId in selected_trainIds, connections)
    println("Filtered timetable to ", nrow(timetable_data), " trips with TrainIds in ", selected_trainIds, ".\n")
end


# CSV.write(joinpath(project_root, "timetableForTest.csv"), timetable_data)

# timetable_data = timetable_data[1:50, :]
# println("Reduced timetable again to ", nrow(timetable_data), " trips.\n")

# Read specific sheets from Excel file
excel_file = XLSX.readxlsx(joinpath(project_root, "Data", "Base Day TUE.xlsx"))
RS_Data = DataFrame(XLSX.gettable(excel_file["Rolling Stock"]))
compositions_raw = DataFrame(XLSX.gettable(excel_file["Composition groups"], header=false))[!, 1]
night_capacity = DataFrame(XLSX.gettable(excel_file["Night capacity"]))
night_capacity_dict = Dict(
    (row.Station, row."Rolling stock types") => (row."Start Limit (count)", row."End Limit (count)") 
    for row in eachrow(night_capacity)
)
reallocations = DataFrame(XLSX.gettable(excel_file["Reallocation"]))
reallocation_dict = Dict(
    (row.Station, row."Rolling Stock type") => (row."Reallocation coupling", row."Reallocation uncoupling") 
    for row in eachrow(reallocations)
)
reallocation_default = [0, 60] # default reallocation times (coupling, uncoupling) if not specified for a station and type

# Access columns from rolling_stock_data
# RS_Data[!, ["Name", "Seats", "Kilometer costs", "Unit cost", "Availability", "Electrified"]]

# add an "empty" composition to represent the special composition for trips starting at "Start" or ending at "End"
push!(compositions_raw, "empty")
push!(RS_Data, (
    Name = "empty",
    Description = "empty",
    Carriages = 0,
    Length = 0,
    Seats = 0,
    var"Kilometer costs" = 0,
    var"Unit cost" = 0,
    Availability = 10000,
    Electrified = 1
))

# Get unique stations from timetable
stations = unique(timetable_data.FromStation ∪ timetable_data.ToStation)
station_to_idx = Dict(name => i for (i, name) in enumerate(stations))

# define number of types and units
M = nrow(RS_Data)
n_trips = nrow(timetable_data)
N = nrow(connections)
S = length(stations)
time = unique(vcat(timetable_data.DepartureFromStation, timetable_data.ArrivalToStation))
T = length(time)


compositions, comp_number = get_normalized_compositions(compositions_raw, RS_Data.Name)

C = length(compositions)

empty_comp_idx = findfirst(==( "empty"), compositions)

# Get coupling and decoupling matrices [1:M, 1:C, 1:C]
coupled_dict, decoupled_dict = get_coupling_matrices(comp_number, RS_Data.Name)

# Get composition costs per kilometer [1:C]
comp_costs, comp_seats = get_composition_details(compositions, RS_Data[!, ["Kilometer costs", "Seats"]], comp_number)

# check comp_number
# for c in 1:C
#     println("Composition ", c, ": ", compositions[c, 1])
#     for m in 1:M 
#         if comp_number[c, m] > 0 println(RS_Data.Name[m], ": ", comp_number[c, m], " units") end
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
end_of_day_penalty = 100000
extra_unit_penalty = 100000

timetable_data.Index = 1:n_trips
# print(timetable_data)

# -----------------------------------------------------------
# CREATE MODEL
# -----------------------------------------------------------
model = Model(Gurobi.Optimizer)
# set_silent(model)

# ----------- 1. Variables -----------

# y[c, j] = 1 if trip j is served by composition c
@variable(model, y[c=1:C, j=1:n_trips], Bin)

# x[c1, c2, n] = 1 if composition c1 and composition c2 are used for connection n 
@variable(model, x[c1=1:C, c2=1:C, n=1:N], Bin)

# v1[m, n] defines how many units of type m are coupled in connection n, v2 for decoupling
@variable(model, v1[m=1:M, n=1:N] >= 0)
@variable(model, v2[m=1:M, n=1:N] >= 0)

# storage[m, n, t] - non-negative number of units of type m stored at station s at time t
@variable(model, storage[m=1:M, n=1:N] >= 0)

# less[m, s] - number of units of type m that are less at station s at the end of the day than at the start (overnight requirement)
@variable(model, balance_shortage[m=1:M, s=1:S] >= 0)
# extra[m, s] - number of units of type m that are extra at station s at the end of the day than at the start (overnight requirement)
@variable(model, balance_excess[m=1:M, s=1:S] >= 0)

# extra_units[m, s] - number of units of type m that additionally start at station s on top of night capacity
@variable(model, extra_units[m=1:M, s=1:S] >= 0)

# ----------- Objective -----------
# Minimize total cost (km_costs * distance)
@objective(model, Min, sum(y[c,j] * comp_costs[c] * timetable_data.Distance_KM[j] for c in 1:C, j in 1:n_trips) # distance costs for each composition used
    + sum(v1[m, n] * coupling_penalty for m in 1:M, n in 1:N) # make coupling/decoupling less attractive
    + sum(v2[m, n] * decoupling_penalty for m in 1:M, n in 1:N)
    + sum(balance_shortage[m, s] * end_of_day_penalty for m in 1:M, s in 1:S)
    + sum(balance_excess[m, s] * end_of_day_penalty for m in 1:M, s in 1:S)
    + sum(extra_units[m, s] * extra_unit_penalty for m in 1:M, s in 1:S)
)

# Fix composition (empty) for trips starting at "Start" or ending at "End"
for j in 1:n_trips
    if timetable_data.FromStation[j] == "Start" || timetable_data.ToStation[j] == "End"
        fix(y[empty_comp_idx, j], 1; force=true)
    else
        fix(y[empty_comp_idx, j], 0; force=true)
    end
end

# Fix compositions for trips that do not allow electrified rolling stock
for j in 1:n_trips
    if timetable_data.Electrified[j] == false
        for c in electrified_comps
            fix(y[c, j], 0; force=true)
        end
    end
end

# C. Global Station Balance (Type-based overnight requirement)
for m in 1:M, s in 1:S  # coupled + excess == decoupled + shortage
    @constraint(model, sum(v1[m, n] for n in 1:N if connections[n, "ConnectionStation"] == stations[s]) + balance_excess[m, s] == sum(v2[m, n] for n in 1:N if connections[n, "ConnectionStation"] == stations[s]) + balance_shortage[m, s])
end

# Demand Coverage
for j in 1:n_trips
    @constraint(model, sum(y[c, j] * comp_seats[c] for c in 1:C) >= timetable_data.Demand[j])
end

# Each trip must have EXACTLY one composition assigned
for j in 1:n_trips
    @constraint(model, sum(y[c, j] for c in 1:C) == 1)
end

# If composition c is used for trip j, then the connection variable x must be set to 1 for exactly one of the corresponding connections
for j in 1:n_trips

    # connections n where trip j is the first trip (FromStation) in the connection
    connections_first = [n for n in 1:N if connections[n, "FromStation"] == timetable_data.FromStation[j] && connections[n, "TrainId"] == timetable_data.TrainId[j]]

    if length(connections_first) == 1
        for c in 1:C
            @constraint(model, sum(x[c, c2, n] for c2 in 1:C, n in connections_first) == y[c, j])
        end
    elseif length(connections_first) == 0
        if timetable_data.ToStation[j] != "End"
            println("Warning: Trip $j has no connections where it is the first trip.") 
        end
    else length(connections_first) > 1
        println("Warning: Trip $j has ", length(connections_first), " connections where it is the first trip. Connections: ", connections_first)
    end

    # connections n where trip j is the second trip (ToStation) in the connection
    connections_second = [n for n in 1:N if connections[n, "ToStation"] == timetable_data.ToStation[j] && connections[n, "TrainId"] == timetable_data.TrainId[j]]

    if length(connections_second) == 1
        for c in 1:C
            @constraint(model, sum(x[c1, c, n] for c1 in 1:C, n in connections_second) == y[c, j])
        end
    elseif length(connections_second) == 0
        if timetable_data.FromStation[j] != "Start"
            println("Warning: Trip $j has no connections where it is the second trip.") 
        end
    else length(connections_second) > 1
        println("Warning: Trip $j has ", length(connections_second), " connections where it is the second trip. Connections: ", connections_second)
    end
end

# Define how many units of each type are decoupled and coupled in a connection
for m in 1:M, n in 1:N
    @constraint(model, v1[m, n] == sum(coupled_dict[(m, c1, c2)] * x[c1, c2, n] for c1 in 1:C, c2 in 1:C))
    @constraint(model, v2[m, n] == sum(decoupled_dict[(m, c1, c2)] * x[c1, c2, n] for c1 in 1:C, c2 in 1:C))
end

# define storage variable (allow extra units, if necessary)
for n in 1:N
    for m in 1:M
        earlier_connections_coupled = [n2 for n2 in 1:N if 
            (connections[n2, "ArrivalAtConnection"] + get(reallocation_dict, (connections[n2, "ConnectionStation"], RS_Data.Name[m]), get(reallocation_dict, (connections[n2, "ConnectionStation"], "*"), (0, 0)), reallocation_default))[1] <= connections[n, "DepartureFromConnection"]) 
            && (connections[n2, "ConnectionStation"] == connections[n, "ConnectionStation"])
        ]
        earlier_connections_decoupled = [n2 for n2 in 1:N if 
            (connections[n2, "ArrivalAtConnection"] + get(reallocation_dict, (connections[n2, "ConnectionStation"], RS_Data.Name[m]), get(reallocation_dict, (connections[n2, "ConnectionStation"], "*"), (0, 0)), reallocation_default))[2] <= connections[n, "DepartureFromConnection"]) 
            && (connections[n2, "ConnectionStation"] == connections[n, "ConnectionStation"])
        ]
        @constraint(model, 
            storage[m, n] == extra_units[m, station_to_idx[connections[n, "ConnectionStation"]]] 
            + get(night_capacity_dict, (connections[n, "ConnectionStation"], RS_Data.Name[m]), (0, 0))[1] 
            - sum(v1[m, n2] for n2 in earlier_connections_coupled)
            + sum(v2[m, n2] for n2 in earlier_connections_decoupled)
        )
    end
end

# Solve the model
start_time = Base.time()
done = Ref(false)

runtime_task = @async begin
    while !done[]
        println("Elapsed runtime: ", round(Base.time() - start_time, digits=1), " s")
        sleep(10.0)
    end
end

optimize!(model)
done[] = true
wait(runtime_task)

total_runtime = Base.time() - start_time
println("Solver finished with status $(termination_status(model)) after ", round(total_runtime, digits=2), " s")

# Print results
println("\n--- OPTIMIZATION RESULTS ---")
println("Status: ", termination_status(model))

if termination_status(model) == OPTIMAL
    println("Total Cost: \$", round(objective_value(model), digits=2))

    # Collect assignments
    assignments = DataFrame(
        TripId = Int[],
        TrainId = Int[],
        FromStation = String[],
        ToStation = String[],
        Departure = Int[],
        Arrival = Int[],
        Demand = Int[],
        Composition = String[]
    )

    for j in 1:n_trips
        assigned_comps = [c for c in 1:C if value(y[c, j]) > 0.5]
        for c in assigned_comps if c != 36 # skip "empty" composition in output
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

    # println("\n--- STARTING TRAINS AT STATIONS ---")
    # for m in 1:M
    #     for s in 1:S
    #         n_start = value(s_start[m, s])
    #         if n_start > 0.5
    #             println("Type: ", RS_Data.Name[m], " starts ", round(n_start), " trains at station ", stations[s])
    #         end
    #     end
    # end

    # println("\n--- COMPOSITION TRANSITIONS ---")
    # for n in 1:N
    #     station = connections[n, "ConnectionStation"]
    #     departure_time = connections[n, "DepartureFromConnection"]
        
    #     assigned_comps = [(c1, c2) for c1 in 1:C, c2 in 1:C if value(x[c1, c2, n]) > 0.5]
        
    #     for (c1, c2) in assigned_comps
    #         for m in 1:M
    #             decoupled = value(v2[m, n])
    #             coupled = value(v1[m, n])
    #             if decoupled > 0.5 || coupled > 0.5
    #                 println("\nStation: $station, Departure: $departure_time")
    #                 println("  Composition before: $(compositions[c1])")
    #                 println("  Composition after: $(compositions[c2])")
    #                 if decoupled > 0.5
    #                     println("    Decoupled: $(round(Int, decoupled)) × $(RS_Data.Name[m])")
    #                 end
    #                 if coupled > 0.5
    #                     println("    Coupled: $(round(Int, coupled)) × $(RS_Data.Name[m])")
    #                 end
    #             end
    #         end
    #     end
    # end

    # STORAGE OUTPUT
    # storage_df = DataFrame(
    #     Type = String[],
    #     Connection = Int[],
    #     Station = String[],
    #     Arrival = Any[],
    #     Units = Int[]
    # )
    # for m in 1:M, n in 1:N
    #     storage_val = value(storage[m, n])
    #     if storage_val > 0.5
    #         push!(storage_df, (
    #             Type = RS_Data.Name[m],
    #             Connection = n,
    #             Station = connections[n, "ConnectionStation"],
    #             Arrival = connections[n, "ArrivalAtConnection"],
    #             Units = round(Int, storage_val)
    #         ))
    #     end
    # end

    # if !isempty(storage_df)
    #     storage_df = sort(storage_df, [:Station, :Arrival])
    #     CSV.write(joinpath(project_root, "results_storage.csv"), storage_df)
    # end

    balance_df = DataFrame(
        Reason = String[],
        Station = String[],
        Type = String[],
        Count = Int[]
    )

    for m in 1:M, s in 1:S
        shortage = value(balance_shortage[m, s])
        excess = value(balance_excess[m, s])
        extra = value(extra_units[m, s])
        
        if shortage > 0.5
            push!(balance_df, (
                Reason = "End-of-day shortage",
                Station = stations[s],
                Type = RS_Data.Name[m],
                Count = round(Int, shortage)
            ))
        end
        if excess > 0.5
            push!(balance_df, (
                Reason = "End-of-day excess",
                Station = stations[s],
                Type = RS_Data.Name[m],
                Count = round(Int, excess)
            ))
        end
        if extra > 0.5
            push!(balance_df, (
                Reason = "Extra units deployed",
                Station = stations[s],
                Type = RS_Data.Name[m],
                Count = round(Int, extra)
            ))
        end
    end

    if !isempty(balance_df)
        CSV.write(joinpath(project_root, "results_balance.csv"), balance_df)
    end
    
else
    println("No optimal solution found.")
end