using CSV, XLSX
include("functions.jl")


# construct file paths to XML files
parent_dir = dirname(dirname(@__FILE__))
file_path_passenger = normpath(joinpath(parent_dir, "Data", "Passagertal_02062026.xml"))
file_path_timetable = normpath(joinpath(parent_dir, "Data", "DLK_Timetable.xml"))
file_path_infrastructure = normpath(joinpath(parent_dir, "Data", "dlkinfra_IF-26_20260121081306.xml"))

df_passenger = parse_passenger_xml(file_path_passenger, save_to_csv = true, filename = "passenger_data.csv")
df_timetable = parse_timetable_xml(file_path_timetable, save_to_csv = true, filename = "timetable_data.csv")
df_infra = parse_infrastructure_xml(file_path_infrastructure, save_to_csv = true, filename = "infrastructure_data.csv")

df_new = merge_data(df_timetable, df_passenger, df_infra, save_to_csv = true, filename = "merged_data.csv")

df_connections = build_connections(df_new, save_to_csv = true, filename = "connections.csv")

# stations_abbrev = extract_station_names(joinpath(parent_dir, "Data", "Station Abbreviation.xlsx"), save_to_csv = true, filename = "StationAbbreviation.csv")
# routes = build_route_map(df_timetable, save_to_csv = true, filename = "train_routes.csv")

# println(first(df_new, 5))
#println(first(routes, 5))

# Save the routes DataFrame to a CSV file
# CSV.write("timetable_routes.csv", routes)
# Convert routes to a proper DataFrame format for CSV export

