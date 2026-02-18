# load external functions
include("functions.jl")

# Define set of target stations for filtering 
# TODO: Figure out which stations are in Zealand
#target_stations = Set(["AR", "SD", "HS"])
target_stations = empty(Set{String}())

# construct file path to XML
parent_dir = dirname(dirname(@__FILE__))
file_path = normpath(joinpath(parent_dir, "Data", "Passagertal_02062026.xml"))

df = parse_passenger_xml(file_path)

# Keep rows where BOTH (From and To) stations are in the defined set
if !isempty(target_stations)
    filtered_df = filter(row -> 
        row.FromStation in target_stations && 
        row.ToStation in target_stations, 
        df
    )
else
    println("No target stations defined, skipping filtering.")
    filtered_df = df # if set is empty => no filtering applied
end

# analyse dataframe
println("Number of rows: ", size(filtered_df, 1))
# println(filtered_df)
#println("Unique TrainCategories: ", length(unique(filtered_df.TrainCategory)))
#println(unique(filtered_df.TrainCategory))     # "L", "IC", "RØ", "EJ", "EX", "RR", "RV"
#println("Unique Operators: ", length(unique(filtered_df.Operator)))
#println(unique(filtered_df.Operator))          # only DSB
#println("Unique DayTypes: ", length(unique(filtered_df.DayType)))
#println(unique(filtered_df.DayType))           # 2 or 3 

# create routes
routes_df = aggregate_train_routes(filtered_df)

# analyze routes
println("Number of routes: ", size(routes_df, 1))
println(first(routes_df, 8))
#println(first(filter(row -> !occursin("L", row.TrainCategory), routes_df), 8))
#println("\nRoutes from OD to CPH:")
#od_cph = filter(row -> row.StartStation == "OD" && row.EndStation == "CPH", routes_df)
#println(od_cph)
