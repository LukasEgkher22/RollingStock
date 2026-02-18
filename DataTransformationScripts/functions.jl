using EzXML
using DataFrames


"""
Reads the passenger XML file.

Arguments
- `file_path::AbstractString`: Path to the passenger XML file to parse.
- `save_to_csv::Bool`: Whether to save the resulting DataFrame to a CSV file
- `filename::String`: The path/name for the CSV file if saving

Returns
- `DataFrame` with columns:
    - `TrainCategory::String`
    - `TrainId::String`
    - `DayType::String`
    - `PassengerNum::Int` — parsed integer value of the <PassengerNumber> element
    - `FromStation::String` — the `ShortName` attribute of the <FromStation> sub-element
    - 'FromCountry::String' — the `CountryCode` attribute of the <FromStation> sub-element (optional)
    - `ToStation::String` — the `ShortName` attribute of the <ToStation> sub-element
    - 'ToCountry::String' — the `CountryCode` attribute of the <ToStation> sub-element (optional)
"""

function parse_passenger_xml(file_path::AbstractString; save_to_csv::Bool = false, filename::String = "passenger_data.csv")
    doc = readxml(file_path)

    # Define namespace map
    ns = ["tns" => "http://trafik.dsb.dk/passengernumbers"]
    
    data_rows = []

    # Find all PassengerNumber elements
    for node in findall("//tns:PassengerNumber", root(doc), ns)
        row = (
            TrainCategory = node["TrainCategory"],
            TrainId       = node["TrainNumber"],
            DayType       = node["DayType"],
            PassengerNum  = parse(Int, node["PassengerNumber"]),
            
            # get data from sub-elements
            FromStation   = findfirst("tns:FromStation", node, ns)["ShortName"],
            #FromCountry   = findfirst("tns:FromStation", node, ns)["CountryCode"],
            ToStation     = findfirst("tns:ToStation", node, ns)["ShortName"],
            #ToCountry     = findfirst("tns:ToStation", node, ns)["CountryCode"]
        )
        push!(data_rows, row)
    end
    
    df = DataFrame(data_rows)
    
    if save_to_csv
        CSV.write(filename, df)
        println("Passenger data saved to $filename")
    end
    
    return df
end


"""
Reads the timetable XML file and processes train entries to create a DataFrame containing 
segments between consecutive stop points. Each row represents a journey segment from one stop to the 
next, including relevant train and timing information.

# Arguments
- `file_path::AbstractString`: Path to the timetable XML file to parse
- `target_date::Union{AbstractString, Nothing}`: Optional date filter in "YYYY-MM-DD" format. If provided, only trains with a matching service start date will be included. If `nothing`, no date filtering is applied.
- `save_to_csv::Bool`: Whether to save the resulting DataFrame to a CSV file
- `filename::String`: The path/name for the CSV file if saving

# Returns
- `DataFrame`: A DataFrame with columns:
  - `TrainCategory::String`: The train category extracted from the trainID (e.g., "EX" from "DSB-EX-1199")
  - `TrainID::String`: The train identifier (e.g., "1199" from "DSB-EX-1199")
  - `FromStation::String`: The departure station code (posID without country code suffix)
  - `Departure::String`: The departure time from the source station
  - `ToStation::String`: The arrival station code (posID without country code suffix)
  - `Arrival::String`: The arrival time at the destination station

# Details
- Parses the trainID attribute in the format "OPERATOR-CATEGORY-TRAINID" (e.g., "DSB-EX-1199")
- Removes country code suffixes from station identifiers (e.g., "/86" from posID)
- Creates segments by pairing consecutive "stop" entries within each train
- Handles cases where trainID components may be missing by using "Unknown" as fallback
"""
function parse_timetable_xml(file_path::AbstractString, target_date::Union{AbstractString, Nothing} = "2026-06-02"; save_to_csv::Bool = false, filename::String = "timetable_data.csv")
    doc = readxml(file_path)
    data_rows = []

    # Iterate through each <train> element
    for train_node in findall("//train", root(doc))

        # Date filter since timetable xml file contains also the 3rd of June
        if !isnothing(target_date)
            service_node = findfirst(".//service", train_node)
            
            # If date doesn't match, or service info is missing, skip this train
            if isnothing(service_node) || service_node["startdate"] != target_date
                continue 
            end
        end
        
        # Extract Train Category and TrainID from the trainID attribute
        # Based on: "DSB-category-trainid", Example: "DSB-EX-1199"
        full_id = train_node["trainID"]
        parts = split(full_id, "-")
        train_category = length(parts) >= 2 ? parts[2] : "Unknown"
        train_id_val   = length(parts) >= 3 ? parts[3] : "Unknown"

        # Find all <entry> tags within this train that are of type "stop"
        # We use .//entry to search within the current train node
        stop_entries = findall(".//entry[@type='stop']", train_node)

        # Create segments by pairing consecutive stops
        for i in 1:(length(stop_entries) - 1)
            from_node = stop_entries[i]
            to_node   = stop_entries[i+1]

            # Extract and clean posID (remove /86 country code)
            from_st_raw = from_node["posID"]
            to_st_raw   = to_node["posID"]
            
            from_st = split(from_st_raw, "/")[1]
            to_st   = split(to_st_raw, "/")[1]

            # Create the row
            row = (
                TrainCategory = String(train_category),
                TrainID       = String(train_id_val),
                FromStation   = String(from_st),
                Departure     = from_node["departure"],
                ToStation     = String(to_st),
                Arrival       = to_node["arrival"]
            )
            push!(data_rows, row)
        end
    end

    df = DataFrame(data_rows)
    
    if save_to_csv
        CSV.write(filename, df)
        println("Timetable data saved to $filename")
    end

    return df
end

"""
Builds a map of train routes.
Arguments:
- `df_timetable`: The parsed timetable DataFrame.
- `save_to_csv`: Boolean, defaults to false.
- `filename`: The path/name for the CSV file if saving.
"""
function build_route_map(df_timetable::DataFrame; save_to_csv::Bool = false, filename::String = "train_routes.csv")
    route_map = Dict{Tuple{String, String}, Vector{String}}()
    
    # Group by train to get the segments in order
    for (key, subdf) in pairs(groupby(df_timetable, [:TrainCategory, :TrainID]))
        if isempty(subdf) continue end
        
        # Collect stations in order: All FromStations + the very last ToStation
        path = copy(subdf.FromStation)
        push!(path, subdf.ToStation[end])
        
        route_map[(String(key.TrainCategory), String(key.TrainID))] = path
    end

    if save_to_csv
        # Create a DataFrame for saving with specific formatting
        csv_df = DataFrame()
        
        csv_df[!, "TrainCategory"] = [
            k[1] for k in keys(route_map)
        ]
        csv_df[!, "TrainID"] = [
            k[2] for k in keys(route_map)
        ]
        
        # Format the Route column: ["ST1", "ST2"] -> [ST1 - ST2]
        csv_df[!, "Route"] = [
            "[" * join(v, " - ") * "]" for v in values(route_map)
        ]
        
        CSV.write(filename, csv_df)
        println("Route map saved to $filename")
    end

    return route_map
end

function merge_timetable_with_demand(df_timetable::DataFrame, df_passenger::DataFrame; save_to_csv::Bool = false, filename::String = "merged_data.csv")
    # 1. Build the map
    routes = build_route_map(df_timetable)
    
    # 2. Add a column for passengers, initialized to 0
    df_timetable.PassengerNum .= 0

    # 3. Iterate through passenger demand
    for p_row in eachrow(df_passenger)
        train_key = (p_row.TrainCategory, p_row.TrainId)
        
        # Check if we even have a timetable for this train
        if haskey(routes, train_key)
            full_path = routes[train_key]
            
            # Find where the passenger stretch starts and ends in the master path
            idx_start = findfirst(==(p_row.FromStation), full_path)
            idx_end   = findfirst(==(p_row.ToStation), full_path)
            
            if isnothing(idx_start) || isnothing(idx_end)
                continue # Station name mismatch
            end
            
            # Apply demand to all timetable segments that fall within this range
            # A segment in df_timetable matches if its FromStation index is >= idx_start
            # and its ToStation index is <= idx_end
            
            mask = (df_timetable.TrainCategory .== p_row.TrainCategory) .& 
                   (df_timetable.TrainID .== p_row.TrainId) .&
                   [let idx_from = findfirst(==(row.FromStation), full_path)
                        idx_to = findfirst(==(row.ToStation), full_path)
                        !isnothing(idx_from) && !isnothing(idx_to) && idx_from >= idx_start && idx_to <= idx_end
                    end
                    for row in eachrow(df_timetable)]
            
            df_timetable[mask, :PassengerNum] .= p_row.PassengerNum
        end
    end
    
    if save_to_csv
        CSV.write(filename, df_timetable)
        println("Merged data saved to $filename")
    end
    
    return df_timetable
end
