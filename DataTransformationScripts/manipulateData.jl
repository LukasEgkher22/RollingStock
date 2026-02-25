using CSV
include("functions.jl")


# construct file paths to XML files
parent_dir = dirname(dirname(@__FILE__))
file_path_passenger = normpath(joinpath(parent_dir, "Data", "Passagertal_02062026.xml"))
file_path_timetable = normpath(joinpath(parent_dir, "Data", "DLK_Timetable.xml"))
file_path_infrastructure = normpath(joinpath(parent_dir, "Data", "dlkinfra_IF-26_20260121081306.xml"))

df_passenger = parse_passenger_xml(file_path_passenger)
df_timetable = parse_timetable_xml(file_path_timetable)
df_infra = parse_infrastructure_xml(file_path_infrastructure)

#routes = build_route_map(df_timetable)

df_new = merge_data(df_timetable, df_passenger, df_infra, save_to_csv = true, filename = "merged_data.csv")

println(first(df_new, 5))
#println(first(routes, 5))

# Save the routes DataFrame to a CSV file
# CSV.write("timetable_routes.csv", routes)
# Convert routes to a proper DataFrame format for CSV export

