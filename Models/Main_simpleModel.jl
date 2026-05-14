using CSV
using DataFrames
using JuMP
using Gurobi
using XLSX
import Dates


project_root = dirname(@__DIR__)

include(joinpath(project_root, "DataTransformationScripts", "DataManipulation_functions.jl"))
include(joinpath(project_root, "Models", "CompositionModel_functions.jl"))

# Read merged data from CSV
timetable_data = CSV.read(joinpath(project_root, "DataManipulated", "aggregated_trips_with_terminals.csv"), DataFrame)
connections = build_connections(timetable_data)

# Read specific sheets from Excel file
excel_file = XLSX.readxlsx(joinpath(project_root, "Data", "Base Day TUE.xlsx"))
RS_Data = DataFrame(XLSX.gettable(excel_file["Rolling Stock"]))
compositions_raw = DataFrame(XLSX.gettable(excel_file["Composition groups"], header=false))[!, 1]
night_capacity = DataFrame(XLSX.gettable(excel_file["Night capacity"]))
night_capacity_dict = Dict(
    (row.Station, row."Rolling stock types") => (row."Start Limit (count)", row."End Limit (count)") 
    for row in eachrow(night_capacity)
)

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
J = nrow(timetable_data)
N = nrow(connections)
S = length(stations)

actual_connections = [n for n in 1:N if connections[n, "FromStation"] != "Start" && connections[n, "ToStation"] != "End"]

# Create unique composition names by sorting the units in the composition (e.g., "ICA-ERF" and "ERF-ICA" both become "1xERF, 1xICA")
# and get the counts of each unit in each composition
compositions, comp_number = get_normalized_compositions(compositions_raw, RS_Data.Name)

C = length(compositions)

empty_comp_idx = findfirst(==( "empty"), compositions)

# Get coupling and decoupling matrices [1:M, 1:C, 1:C]
coupled_dict, decoupled_dict = get_coupling_matrices(comp_number, RS_Data.Name)

# Get composition costs per kilometer [1:C]
comp_costs, comp_seats = get_composition_details(compositions, RS_Data[!, ["Kilometer costs", "Seats"]], comp_number)

# define indices of compositions that contain only electrified units -> they are not allowed for trips that require non-electrified rolling stock
electrified_comps = [c for c in 1:C if any((RS_Data.Electrified[m] == 1) && (comp_number[c, m] > 0) for m in 1:M)]

# define penalty parameters for coupling and decoupling (example: 100 per unit)
coupling_penalty = 100
end_of_day_penalty = 10000
extra_unit_penalty = 10000

timetable_data.Index = 1:J

# -----------------------------------------------------------
# CREATE MODEL
# -----------------------------------------------------------
model = Model(Gurobi.Optimizer)

# ----------- Variables -----------

# y[c, j] = 1 if trip j is served by composition c
@variable(model, y[c=1:C, j=1:J], Bin)

# x[c1, c2, n] = 1 if composition c1 and composition c2 are used for connection n 
@variable(model, x[c1=1:C, c2=1:C, n=1:N], Bin)

# v1[m, n] defines how many units of type m are coupled in connection n, v2 for decoupling
@variable(model, v1[m=1:M, n=1:N] >= 0)
@variable(model, v2[m=1:M, n=1:N] >= 0)

# storage[m, n] - non-negative number of units of type m stored at the station of connection n (after coupling and decoupling)
@variable(model, storage[m=1:M, n=1:N] >= 0)

# balance_shortage[m, s] - number of units of type m that are too little at station s at the end of the day compared to the start (overnight requirement)
@variable(model, balance_shortage[m=1:M, s=1:S] >= 0)
# balance_excess[m, s] - number of units of type m that are too much at station s at the end of the day compared to the start (overnight requirement)
@variable(model, balance_excess[m=1:M, s=1:S] >= 0)

# extra_units[m, s] - number of units of type m that additionally start at station s on top of night capacity
@variable(model, extra_units[m=1:M, s=1:S] >= 0)

# ----------- Objective -----------
# Minimize total cost (km_costs * distance)
@objective(model, Min, sum(y[c,j] * comp_costs[c] * timetable_data.Distance_KM[j] for c in 1:C, j in 1:J) # distance costs for each composition used
    + sum((v1[m, n] + v2[m, n]) * coupling_penalty for m in 1:M, n in actual_connections) # make coupling/decoupling less attractive
    + sum((balance_shortage[m, s] + balance_excess[m, s]) * end_of_day_penalty for m in 1:M, s in 1:S)
    + sum(extra_units[m, s] * extra_unit_penalty for m in 1:M, s in 1:S)
)

# Fix composition empty_comp_idx (empty) for trips starting at "Start" or ending at "End"
for j in 1:J
    if timetable_data.FromStation[j] == "Start" || timetable_data.ToStation[j] == "End"
        fix(y[empty_comp_idx, j], 1; force=true)
        for c in 1:C
            if c != empty_comp_idx
                fix(y[c, j], 0; force=true)
            end
        end
    else
        fix(y[empty_comp_idx, j], 0; force=true)
    end
end

# Fix compositions for trips that do not allow electrified rolling stock
for j in 1:J
    if timetable_data.Electrified[j] == false
        for c in electrified_comps
            fix(y[c, j], 0; force=true)
        end
    end
end

# A. Each trip must have EXACTLY one composition assigned
for j in 1:J
    @constraint(model, sum(y[c, j] for c in 1:C) == 1)
end

# B. If composition c is used for trip j, then the connection variable x must be set to 1 for exactly one of the corresponding connections
for j in 1:J

    # B1. connections n where trip j is the first trip (FromStation) in the connection
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

    # B2. connections n where trip j is the second trip (ToStation) in the connection
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

# C. Define how many units of each type are decoupled and coupled in a connection
for m in 1:M, n in 1:N
    @constraint(model, v1[m, n] == sum(coupled_dict[(m, c1, c2)] * x[c1, c2, n] for c1 in 1:C, c2 in 1:C))
    @constraint(model, v2[m, n] == sum(decoupled_dict[(m, c1, c2)] * x[c1, c2, n] for c1 in 1:C, c2 in 1:C))
end

# D. Demand Coverage
for j in 1:J
    @constraint(model, sum(y[c, j] * comp_seats[c] for c in 1:C) >= timetable_data.Demand[j])
end

# E. Global Station Balance (Type-based overnight requirement)
for m in 1:M, s in 1:S  # coupled + excess == decoupled + shortage
    @constraint(model, sum(v1[m, n] for n in 1:N if connections[n, "ConnectionStation"] == stations[s]) + balance_excess[m, s] == sum(v2[m, n] for n in 1:N if connections[n, "ConnectionStation"] == stations[s]) + balance_shortage[m, s])
end

# F. define storage variable - storage = night_capacity - coupled + uncoupled + extra (allow extra units, if necessary, but expensive)
for n in 1:N
    earlier_connections = [n2 for n2 in 1:N if
        (connections[n2, "ArrivalAtConnection"] <= connections[n, "DepartureFromConnection"])
        && (connections[n2, "ConnectionStation"] == connections[n, "ConnectionStation"])
    ]
    for m in 1:M
        @constraint(model, 
            storage[m, n] == extra_units[m, station_to_idx[connections[n, "ConnectionStation"]]] +
                get(night_capacity_dict, (connections[n, "ConnectionStation"], RS_Data.Name[m]), (0, 0))[1]
                + sum(v2[m, n2] - v1[m, n2] for n2 in earlier_connections)
        )
    end
end

# Solve the model
start_time = Base.time()

optimize!(model)

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
        TrainCategory = String[],
        TrainId = Int[],
        FromStation = String[],
        ToStation = String[],
        Departure = Int[],
        Arrival = Int[],
        Demand = Int[],
        Composition = String[]
    )

    for j in 1:J
        assigned_comps = [c for c in 1:C if value(y[c, j]) > 0.5]
        for c in assigned_comps 
            if c != empty_comp_idx # skip "empty" composition in output
                push!(assignments, (
                    TripId = j,
                    TrainCategory = timetable_data.TrainCategory[j],
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
    end

    # Group by TrainId, sort by earliest departure, and save to CSV
    grouped = groupby(assignments, :TrainId)
    ordered_assignments = DataFrame()
    for g in grouped
        sorted_g = sort(g, :Departure)
        append!(ordered_assignments, sorted_g)
    end

    timestamp = Dates.format(Dates.now(), "yyyy-mm-dd_HH-MM-SS")
    CSV.write(joinpath(project_root, "Results", "CompAssignments_simpleModel_$(timestamp).csv"), ordered_assignments)

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
        CSV.write(joinpath(project_root, "Results", "BalanceIssues_simpleModel_$(timestamp).csv"), balance_df)
    else
        println("No balance issues or extra units needed at the end of the day.")
    end

    # Get MetaData for the solver run
    status = termination_status(model)
    runtime = solve_time(model)
    obj_val = has_values(model) ? objective_value(model) : "No solution"
    bound = try objective_bound(model) catch; "N/A" end
    gap = try relative_optimality_gap(model) catch; "N/A" end

    open(joinpath(project_root, "Results", "Summary_simpleModel_$(timestamp).txt"), "w") do f
        write(f, "------------------------------------------\n")
        write(f, "SOLVER REPORT\n")
        write(f, "------------------------------------------\n")
        write(f, "Status:         $(status)\n")
        write(f, "Runtime:        $(round(runtime, digits=2)) seconds\n")
        write(f, "Objective:      $(obj_val)\n")
        write(f, "Lower Bound:    $(bound)\n")
        write(f, "Optimality Gap: $(gap)\n")
        write(f, "------------------------------------------\n")
    end
end
    
else
    println("No optimal solution found.")
end