using CSV
include("functions.jl")


# construct file paths to XML files
parent_dir = dirname(dirname(@__FILE__))
file_path_passenger = normpath(joinpath(parent_dir, "Data", "Passagertal_02062026.xml"))
file_path_timetable = normpath(joinpath(parent_dir, "Data", "DLK_Timetable.xml"))

df_passenger = parse_passenger_xml(file_path_passenger)
df_timetable = parse_timetable_xml(file_path_timetable)

routes = build_route_map(df_timetable)

df_new = merge_timetable_with_demand(df_timetable, df_passenger, save_to_csv = true, filename = "merged_timetable_passenger.csv")

println(first(df_new, 5))
#println(first(routes, 5))

# Save the routes DataFrame to a CSV file
# CSV.write("timetable_routes.csv", routes)
# Convert routes to a proper DataFrame format for CSV export