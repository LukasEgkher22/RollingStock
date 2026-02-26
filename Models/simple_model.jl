using CSV
using DataFrames
using JuMP
using Gurobi
using HiGHS
using XLSX


project_root = dirname(@__DIR__)

# Read merged data from CSV
timetable_data = CSV.read(joinpath(project_root, "DataManipulated", "merged_data.csv"), DataFrame)

# Filter for trips between specific stations
trainIds = [2981, 2974, 2202, 4219]#, 2200, 2768]
#trainIds = [2202, 4219]
timetable_data = filter(row -> row.TrainId in trainIds, timetable_data)
timetable_data.TripId = 1:nrow(timetable_data)
print(trainIds, " trips: ", nrow(timetable_data), "\n")

# Read specific sheets from Excel file
excel_file = XLSX.readxlsx(joinpath(project_root, "Data", "Base Day TUE.xlsx"))
rolling_stock_data = DataFrame(XLSX.gettable(excel_file["Rolling Stock"]))
night_capacity = DataFrame(XLSX.gettable(excel_file["Night capacity"]))

# Access columns from rolling_stock_data
Unit_name = rolling_stock_data.Name
Unit_seats = rolling_stock_data.Seats
Unit_km_costs = rolling_stock_data[!, "Kilometer costs"]
Unit_costs = rolling_stock_data[!, "Unit cost"]
Unit_availability = rolling_stock_data.Availability
Unit_electrified = rolling_stock_data.Electrified

# define number of types and units
M = nrow(rolling_stock_data)
N = Unit_availability

# Get unique stations from timetable
stations = unique(timetable_data.FromStation)

n_trips = nrow(timetable_data)
print("Number of trips: ", n_trips, "\n")


# -----------------------------------------------------------
# CREATE MODEL
# -----------------------------------------------------------
model = Model(HiGHS.Optimizer)

# --- 1. Variables ---

# x[m, n, j] = 1 if unit n of type m performs trip j
@variable(model, x[m=1:M, n=1:N[m], j=1:n_trips], Bin)

# u[m, n] = 1 if unit n of type m is used at all (for fixed costs)
@variable(model, u[m=1:M, n=1:N[m]], Bin)

# s_start[m, n, s] = 1 if unit (m,n) starts the day at station s
@variable(model, s_start[m=1:M, n=1:N[m], s=stations], Bin)

# s_end[m, n, s] = 1 if unit (m,n) ends the day at station s
@variable(model, s_end[m=1:M, n=1:N[m], s=stations], Bin)


# Objective: Minimize total cost (km_costs * distance + unit_costs)
@objective(model, Min, sum(x[m, n, j] * Unit_km_costs[m] * timetable_data.Distance_KM[j] for m in 1:M, n in 1:N[m], j in 1:n_trips)
                        + sum(Unit_costs[m] * u[m, n] for m in 1:M, n in 1:N[m]))

# --- 2. Constraints ---

# A. Unit Flow & Continuity
for m in 1:M, n in 1:N[m]
    # Each unit starts and ends exactly once
    @constraint(model, sum(s_start[m, n, s] for s in stations) == 1)
    @constraint(model, sum(s_end[m, n, s] for s in stations) == 1)

    for s in stations
        trips_out = findall(timetable_data.FromStation .== s)
        trips_in  = findall(timetable_data.ToStation .== s)

        # Standard Flow Conservation: Start + In (available) == Out + End (used up)
        @constraint(model, 
            s_start[m, n, s] + sum(x[m, n, j] for j in trips_in) == 
            s_end[m, n, s] + sum(x[m, n, j] for j in trips_out)
        )
    end
end

# B. Chronology (Preventing "Time Travel")
# For a specific unit at a specific station, it must have arrived BEFORE it departs.
for s in stations
    # Get all events at this station sorted by time
    deps = filter(r -> r.FromStation == s, timetable_data)
    arrs = filter(r -> r.ToStation == s, timetable_data)
    
    events = []
    for r in eachrow(deps) push!(events, (time=r.DepartureFromStation, type=:dep, id=r.TripId)) end
    for r in eachrow(arrs) push!(events, (time=r.ArrivalToStation, type=:arr, id=r.TripId)) end
    
    # Sort events: Arrivals at the same time as departures are processed FIRST
    sort!(events, by = x -> (x.time, x.type == :dep))

    for m in 1:M, n in 1:N[m]
        for i in 1:length(events)
            # We look at the "state" of unit (m,n) at station s after event i
            current_events = events[1:i]
            arr_so_far = [e.id for e in current_events if e.type == :arr]
            dep_so_far = [e.id for e in current_events if e.type == :dep]
            
            # Unit (m,n) is at station s ONLY if it started there or arrived there, 
            # and hasn't left yet. This value must be 0 or 1.
            @constraint(model, 
                s_start[m, n, s] + 
                sum(x[m, n, j] for j in arr_so_far; init=0) - 
                sum(x[m, n, j] for j in dep_so_far; init=0) >= 0
            )
        end
    end
end

# C. Global Station Balance (Type-based overnight requirement)
# "The number of units of type m starting at s must equal the number ending at s"
for m in 1:M, s in stations
    @constraint(model, 
        sum(s_start[m, n, s] for n in 1:N[m]) == 
        sum(s_end[m, n, s] for n in 1:N[m])
    )
end

# D. Demand Coverage (Allows coupling/multiple units)
for j in 1:n_trips
    @constraint(model, sum(x[m, n, j] * rolling_stock_data.Seats[m] 
                           for m in 1:M, n in 1:N[m]) >= timetable_data.Demand[j])
end

# E. Symmetry Breaking (Crucial)
for m in 1:M, n in 1:N[m]-1
    @constraint(model, sum(x[m, n, j] for j in 1:n_trips) >= 
                       sum(x[m, n+1, j] for j in 1:n_trips))
end

# F. Link x and u (if unit n of type m is used, then u[m,n] = 1)
for m in 1:M, n in 1:N[m]
    @constraint(model, sum(x[m, n, j] for j in 1:n_trips) <= Unit_availability[m] * u[m, n]) # Big-M
end

# G. Electrified routes can only be served by electric units
electrified_m = findall(==(1), Unit_electrified)
non_electrified_tracks = findall(==(false), timetable_data.Electrified)
for m in electrified_m, j in non_electrified_tracks
    for n in 1:N[m]
        fix(x[m, n, j], 0; force=true)
    end
end

# H. Combination of units

# Solve the model
optimize!(model)

# Print results
println("\n--- OPTIMIZATION RESULTS ---")
println("Status: ", termination_status(model))
println("Objective Value: ", objective_value(model))

if termination_status(model) == OPTIMAL
    println("\nOptimal solution found!")
    println("Total Cost: \$", round(objective_value(model), digits=2))
    
    println("\n--- UNIT ROUTING DETAILS ---")
    for m in 1:M
        println("\nUnit Type: ", Unit_name[m], " (Seats: ", seats[m], ")")
        for n in 1:N[m]
            assigned_trips = findall(j -> value(x[m, n, j]) > 0.5, 1:n_trips)
            
            if !isempty(assigned_trips)
                println("  Unit #$n:")
                
                # Starting station
                start_station = [s for s in stations if value(s_start[m, n, s]) > 0.5]
                if !isempty(start_station)
                    println("    Start at: ", start_station[1])
                end
                
                # Trips
                for j in sort(assigned_trips, by = i -> timetable_data.DepartureFromStation[i])
                    trip = timetable_data[j, :]
                    println("    Trip $j: ", trip.FromStation, " -> ", trip.ToStation, 
                            " (Depart: ", trip.DepartureFromStation, ", Arrive: ", trip.ArrivalToStation, 
                            ", Demand: ", trip.Demand, ")")
                end
                
                # Ending station
                end_station = [s for s in stations if value(s_end[m, n, s]) > 0.5]
                if !isempty(end_station)
                    println("    End at: ", end_station[1])
                end
            end
        end
    end
else
    println("No optimal solution found.")
end