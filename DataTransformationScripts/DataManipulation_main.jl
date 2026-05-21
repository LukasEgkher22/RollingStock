using CSV, XLSX, DataFrames
include("DataManipulation_functions.jl")

# add (empty) trips for start and end stations
use_M_trains = true
compile_data = true

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

# ----------- 
# MANIPULATION of data based on needs
# -----------
if compile_data
    filename_add = use_M_trains ? "_Mtrains" : ""
    # creates the main DataFrame with all relevant information for the model
    df_new = merge_data(df_timetable, df_passenger, df_infra, add_Mtrains = use_M_trains, save_to_csv = true, filename = "merged_data$(filename_add).csv")

    # shortens the DataFrame by only keeping stations where composition changes are possible and the start/end stations
    result = aggregate_train_trips(df_new, file_path_BASEDAY, save_to_csv = true, filename = "aggregated_trips$(filename_add).csv")

    # adds rows for the start and end stations of each trip
    result_with_terminals = add_terminal_rows(result, save_to_csv = true, filename = "aggregated_trips_with_terminals$(filename_add).csv")
else
    result_with_terminals = CSV.read(normpath(joinpath(parent_dir, "DataManipulated", "aggregated_trips_with_terminals.csv")), DataFrame)
end


create_GGV_dummies(result_with_terminals, save_to_csv = true, filename = "GGV_dummies.csv")

# builds the routes DataFrame from the timetable data
build_route_map(result_with_terminals, save_to_csv = true, filename = "train_routes_aggregated.csv")

# println(first(df_new, 5))
# println(first(routes, 5))
# println(first(df_connections, 5))

