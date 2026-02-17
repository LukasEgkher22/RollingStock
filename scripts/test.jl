# load external functions
include("functions.jl")

# construct file path to XML
parent_dir = dirname(dirname(@__FILE__))
file_path = normpath(joinpath(parent_dir, "Data", "Passagertal_02062026.xml"))

df = parse_passenger_xml(file_path)

# Define set of target stations for filtering 
# TODO: Figure out which stations are in Zealand
target_stations = Set(["AR", "SD", "HS"])

# Keep rows where BOTH (From and To) stations are in the defined set
filtered_df = filter(row -> 
    row.FromStation in target_stations && 
    row.ToStation in target_stations, 
    df
)

# display dataframe
println(filtered_df)

final_df = aggregate_train_routes(filtered_df)

# show routes
println(final_df)