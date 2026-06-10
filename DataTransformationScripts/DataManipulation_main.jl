using CSV, XLSX, DataFrames
include("DataManipulation_functions.jl")

# add (empty) trips for start and end stations
use_M_trains = true
compile_data = true
additional_M_trains = true
model = additional_M_trains ? "SimpleModel" : ""

# construct file paths to XML/XLSX files
parent_dir = dirname(dirname(@__FILE__))
file_path_passenger = normpath(joinpath(parent_dir, "Data", "Passagertal_02062026.xml"))
file_path_timetable = normpath(joinpath(parent_dir, "Data", "DLK_Timetable.xml"))
file_path_infrastructure = normpath(joinpath(parent_dir, "Data", "dlkinfra_IF-26_20260121081306.xml"))
file_path_station_abbrev = normpath(joinpath(parent_dir, "Data", "Station Abbreviation.xlsx"))
file_path_BASEDAY = normpath(joinpath(parent_dir, "Data", "Base Day TUE.xlsx"))
file_path_additional_trips = normpath(joinpath(parent_dir, "DataManipulated", "additional_M_trains_$model.csv"))

# read in the data and save to CSV for easier access in the future
df_passenger = parse_passenger_xml(file_path_passenger)
df_timetable = parse_timetable_xml(file_path_timetable)
df_infra = parse_infrastructure_xml(file_path_infrastructure)
stations_abbrev = extract_station_names(file_path_station_abbrev)

# ----------- 
# MANIPULATION of data based on needs
# -----------

if compile_data
    # creates the main DataFrame with all relevant information for the model
    df_new = merge_data(df_timetable, df_passenger, df_infra, add_Mtrains = use_M_trains) #, save_to_csv = true, filename = "merged_data.csv")

    # shortens the DataFrame by only keeping stations where composition changes are possible and the start/end stations
    result = aggregate_train_trips(df_new, file_path_BASEDAY, save_to_csv = true, filename = "aggregated_trips.csv")

    if additional_M_trains
        result = add_additional_M_trains(result, file_path_additional_trips)
    end

else
    result = CSV.read(normpath(joinpath(parent_dir, "DataManipulated", "aggregated_trips.csv")), DataFrame)
end

additional_string = additional_M_trains ? "_add" : ""
# add terminals
terminals = add_terminal_rows(result, save_to_csv = true, filename = "aggregated_trips_terminals$(additional_string).csv")

# add ggv and then terminals
result_new = pre_merge_train_ids(result, save_to_csv = true, filename = "aggregated_trips_merged$(additional_string).csv")
if model == "GGV"
    ggv = add_GGV_column(result_new, save_to_csv = true, filename = "aggregated_trips_merged_GGV$(additional_string).csv")
    ggv_terminals = add_terminal_rows(ggv, save_to_csv = true, filename = "aggregated_trips_merged_GGV_terminals$(additional_string).csv")
end

# builds the routes DataFrame from the timetable data
# route = build_route_map(terminals, save_to_csv = true, filename = "train_routes_aggregated.csv")


