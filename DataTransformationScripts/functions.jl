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
Reads the timetable XML file and saves a DataFrame from it.

# Arguments
- `file_path::AbstractString`: Path to the timetable XML file to parse
- `target_date::Union{AbstractString, Nothing}`: Optional date filter in "YYYY-MM-DD" format. If provided, only trains with a matching service start date will be included. If `nothing`, no date filtering is applied.
- `save_to_csv::Bool`: Whether to save the resulting DataFrame to a CSV file
- `filename::String`: The path/name for the CSV file if saving

# Returns

    - `TrainCategory::String`: The train category extracted from the trainID (e.g., "EX" from "DSB-EX-1199")
    - `TrainID::String`: The train identifier (e.g., "1199" from "DSB-EX-1199")
    - `Station::String`: The station code (posID without country code suffix)
    - `Arrival::String`: The arrival time at the station
    - `Departure::String`: The departure time from the station
    - `Type::String`: The entry type (e.g., "stop", "pass")

# Details
- Parses the trainID attribute in the format "OPERATOR-CATEGORY-TRAINID" (e.g., "DSB-EX-1199")
- Removes country code suffixes from station identifiers (e.g., "/86" from posID)
- Handles cases where trainID components may be missing by using "Unknown" as fallback
"""
function parse_timetable_xml(file_path::AbstractString, target_date::Union{AbstractString, Nothing} = "2026-06-02"; save_to_csv::Bool = false, filename::String = "timetable_data.csv")
    doc = readxml(file_path)
    data_rows = []

    # Iterate through each <train> element
    for train_node in findall("//train", root(doc))
        
        # Date Filter Logic
        # The <service> tag is nested: train -> timetableentries -> entry -> composition -> service
        if !isnothing(target_date)
            service_node = findfirst(".//service", train_node)
            
            if isnothing(service_node) || service_node["startdate"] != target_date
                continue 
            end
        end
        
        # Extract Train Metadata
        full_id = train_node["trainID"]
        parts = split(full_id, "-")
        # Example: DSB-EX-1198 -> parts[2]="EX", parts[3]="1198"
        train_category = length(parts) >= 2 ? parts[2] : "Unknown"
        train_id_val   = length(parts) >= 3 ? parts[3] : "Unknown"

        # Find ALL entries that have a 'type' attribute (skipping the header entry)
        entries = findall(".//entry[@type]", train_node)

        for entry_node in entries
            # Extract posID and strip the country suffix (e.g., "HMB/80" -> "HMB")
            st_raw = haskey(entry_node, "posID") ? entry_node["posID"] : ""
            st = split(st_raw, "/")[1]

            # Create the row using haskey/get logic to prevent errors if attributes are missing
            row = (
                TrainCategory = String(train_category),
                TrainId       = String(train_id_val),
                Station       = String(st),
                Arrival       = haskey(entry_node, "arrival") ? entry_node["arrival"] : "",
                Departure     = haskey(entry_node, "departure") ? entry_node["departure"] : "",
                Type          = haskey(entry_node, "type") ? entry_node["type"] : ""
            )
            push!(data_rows, row)
        end
    end

    if isempty(data_rows)
        return DataFrame()
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
    for (key, subdf) in pairs(groupby(df_timetable, [:TrainCategory, :TrainId]))
        if isempty(subdf) continue end
        
        # Filter to only include stops and collect stations in order
        stops = filter(row -> row.Type == "stop", subdf)
        if isempty(stops) continue end
        
        path = stops.Station
        route_map[(String(key.TrainCategory), String(key.TrainId))] = path
    end

    if save_to_csv
        # Create a DataFrame for saving with specific formatting
        csv_df = DataFrame()
        
        csv_df[!, "TrainCategory"] = [
            k[1] for k in keys(route_map)
        ]
        csv_df[!, "TrainId"] = [
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
"""
Merge timetable data with passenger demand information by mapping passenger segments to individual stop-to-stop legs.

This function performs a three-step process:
1. Consolidates passenger demand data by skipping intermediate "pass" stations, creating merged segments from stop to stop stations only.
2. Maps these consolidated segments to individual stop-to-stop legs defined in the timetable.
3. Distributes passenger demand across all intermediate legs within a segment.

# Arguments
- `df_timetable::DataFrame`: Timetable data containing columns `TrainCategory`, `TrainId`, `Station`, `Type` ("stop" or "pass"), `Departure`, and `Arrival`.
- `df_passenger::DataFrame`: Passenger demand data containing columns `TrainCategory`, `TrainId`, `FromStation`, `ToStation`, and `PassengerNum`.
- `save_to_csv::Bool = false`: If true, saves the merged result to a CSV file.
- `filename::String = "merged_data.csv"`: Output filename when `save_to_csv` is true.

# Returns
- `DataFrame`: A dataframe with columns `TrainCategory`, `TrainId`, `FromStation`, `DepartureFromStation`, `ToStation`, `ArrivalToStation`, and `Demand`, containing one row per stop-to-stop leg with assigned passenger demand.

# Notes
- Issues a warning if passenger demand changes at pass stations (data inconsistency).
- Segments with stations not found in the timetable are filtered out.
"""

function merge_timetable_with_demand(df_timetable::DataFrame, df_passenger::DataFrame; save_to_csv::Bool = false, filename::String = "merged_data.csv")
    # Clean types
    tt = copy(df_timetable)
    ps = copy(df_passenger)
    tt.TrainId = string.(tt.TrainId)
    ps.TrainId = string.(ps.TrainId)

    results = []

    # Group by Train
    gdf_tt = groupby(tt, [:TrainCategory, :TrainId])

    for train_tt in gdf_tt
        t_cat = string(train_tt.TrainCategory[1])
        t_id  = string(train_tt.TrainId[1])

        # Filter passenger data for this train
        train_ps = ps[(ps.TrainCategory .== t_cat) .& (ps.TrainId .== t_id), :]
        if isempty(train_ps) continue end

        # Map for station info: Name -> (Index, Type)
        st_info = Dict(row.Station => (i, row.Type) for (i, row) in enumerate(eachrow(train_tt)))

        # --- STEP A: Consolidate Section Loads into Stop-to-Stop Segments ---
        # transform A-B(30), B-D(30) [where B is pass] into A-D(30) and give a warning if demand changes at B
        cleaned_segments = []
        i = 1
        while i <= nrow(train_ps)
            from_st = string(train_ps[i, :FromStation])
            to_st   = string(train_ps[i, :ToStation])
            demand  = train_ps[i, :PassengerNum]

            # Chain rows as long as the 'to_st' is a "stop" station
            while i < nrow(train_ps) && get(st_info, to_st, (0, "stop"))[2] == "pass"
                i += 1
                next_demand = train_ps[i, :PassengerNum]
                
                if next_demand != demand
                    @warn "Demand changed from $demand to $next_demand at pass station '$to_st' (Train $t_id)."
                end
                
                to_st = string(train_ps[i, :ToStation])
            end
            
            # Store the cleaned segment with its timetable indices
            idx_f = get(st_info, from_st, (0, ""))[1]
            idx_t = get(st_info, to_st, (0, ""))[1]
            
            if idx_f != 0 && idx_t != 0
                push!(cleaned_segments, (f_idx=idx_f, t_idx=idx_t, demand=demand))
            end
            i += 1
        end

        # --- STEP B: Map to Timetable Stop-to-Stop Legs ---
        # If tt has stops A, B, C, D and cleaned_ps has A-D(30) create rows for A-B(30), B-C(30), C-D(30)
        stop_indices = findall(x -> x == "stop", train_tt.Type)
        
        for k in 1:(length(stop_indices) - 1)
            idx_start = stop_indices[k]
            idx_end   = stop_indices[k+1]
            
            # Find which cleaned segment covers this specific stop-to-stop leg
            leg_demand = 0
            for seg in cleaned_segments
                if seg.f_idx <= idx_start && seg.t_idx >= idx_end
                    leg_demand = seg.demand
                    break 
                end
            end

            push!(results, (
                TrainCategory        = t_cat,
                TrainId              = t_id,
                FromStation          = train_tt.Station[idx_start],
                DepartureFromStation = train_tt.Departure[idx_start],
                ToStation            = train_tt.Station[idx_end],
                ArrivalToStation     = train_tt.Arrival[idx_end],
                Demand               = leg_demand
            ))
        end
    end

    df_merged = DataFrame(results)

    if save_to_csv
        CSV.write(filename, df_merged)
        println("Merged data saved to $filename")
    end

    return df_merged
end