using CSV, DataFrames



project_root = dirname(@__DIR__)

# Read merged data from CSV
timetable_data = CSV.read(joinpath(project_root, "DataManipulated", "train_routes.csv"), DataFrame)
timetable_data = filter(row -> row.TrainCategory != "M", timetable_data)

# 2. Parse route strings into clean Vectors of Strings
# We strip the brackets and split by " - "
timetable_data.Route = map(timetable_data.Route) do r
    split(strip(r, ['[', ']']), " - ")
end

# 3. Create a helper column that is the reverse of the route
# We join the array into a string so it's easy to compare/join
timetable_data.RouteStr = [join(r, " - ") for r in timetable_data.Route]
timetable_data.ReverseRouteStr = [join(reverse(r), " - ") for r in timetable_data.Route]

# 4. Self-join to find pairs
# We match where the Route of Train A equals the Reverse Route of Train B
pairs = innerjoin(
    timetable_data[:, [:TrainID, :RouteStr]], 
    timetable_data[:, [:TrainID, :ReverseRouteStr]], 
    on = :RouteStr => :ReverseRouteStr,
    renamecols = "_A" => "_B"
)

# 5. Filter out duplicates and self-matches
# (e.g., if a train is its own reverse, or to avoid getting both (A, B) and (B, A))
unique_pairs = filter(row -> row.TrainID_A < row.TrainID_B, pairs)

# Result
display(unique_pairs[:, [:TrainID_A, :TrainID_B]])