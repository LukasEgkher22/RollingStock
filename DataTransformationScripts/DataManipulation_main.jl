using CSV, XLSX
include("DataManipulation_functions.jl")

# add (empty) trips for start and end stations
add_terminal_trips = true

# construct file paths to XML/XLSX files
parent_dir = dirname(dirname(@__FILE__))
file_path_passenger = normpath(joinpath(parent_dir, "Data", "Passagertal_02062026.xml"))
file_path_timetable = normpath(joinpath(parent_dir, "Data", "DLK_Timetable.xml"))
file_path_infrastructure = normpath(joinpath(parent_dir, "Data", "dlkinfra_IF-26_20260121081306.xml"))
file_path_station_abbrev = normpath(joinpath(parent_dir, "Data", "Station Abbreviation.xlsx"))
file_path_BASEDAY = normpath(joinpath(parent_dir, "Data", "Base Day TUE.xlsx"))

# read in the data and save to CSV for easier access in the future
df_passenger = parse_passenger_xml(file_path_passenger)
df_timetable = parse_timetable_xml(file_path_timetable)
df_infra = parse_infrastructure_xml(file_path_infrastructure)
stations_abbrev = extract_station_names(file_path_station_abbrev)

# MANIPULATION of data based on needs
# creates the main DataFrame with all relevant information for the model
df_new = merge_data(df_timetable, df_passenger, df_infra)

result = aggregate_train_trips(df_new, file_path_BASEDAY)

if add_terminal_trips
    # df_new = add_terminal_rows(df_new, save_to_csv = true, filename = "merged_data_with_terminals.csv")
    result = add_terminal_rows(result, save_to_csv = true, filename = "aggregated_trips_with_terminals_including_Mtrains.csv")
end

# builds the routes DataFrame from the timetable data
# routes = build_route_map(df_timetable, save_to_csv = true, filename = "train_routes.csv")

# builds the connections DataFrame from the merged data
# df_connections = build_connections(df_new, save_to_csv = true, filename = "connections.csv")

# println(first(df_new, 5))
# println(first(routes, 5))
# println(first(df_connections, 5))

