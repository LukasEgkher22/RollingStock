using EzXML
using DataFrames
using Printf


"""
Reads the passenger XML file

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
            FromStation   = findfirst("tns:FromStation", node, ns)["ShortName"] * "/" * findfirst("tns:FromStation", node, ns)["CountryCode"],
            ToStation     = findfirst("tns:ToStation", node, ns)["ShortName"] * "/" * findfirst("tns:ToStation", node, ns)["CountryCode"],
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

            # Create the row using haskey/get logic to prevent errors if attributes are missing
            row = (
                TrainCategory = String(train_category),
                TrainId       = String(train_id_val),
                Station       = haskey(entry_node, "posID") ? entry_node["posID"] : "",
                Arrival       = (haskey(entry_node, "arrivalDay") && haskey(entry_node, "arrival")) ?
                                (entry_node["arrivalDay"] == "1" ? add_24h_offset(entry_node["arrival"]) : entry_node["arrival"]) : "",
                Departure     = (haskey(entry_node, "departureDay") && haskey(entry_node, "departure")) ?
                                (entry_node["departureDay"] == "1" ? add_24h_offset(entry_node["departure"]) : entry_node["departure"]) : "",
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
    # Store actual vectors in the dictionary for programmatic use
    route_map = Dict{Tuple{String, String}, Vector{String}}()
    
    for (key, subdf) in pairs(groupby(df_timetable, [:TrainCategory, :TrainId]))
        if isempty(subdf) continue end
        
        # Filter for stops and extract the Station column
        stops = filter(row -> row.Type == "stop", subdf)
        if isempty(stops) continue end
        
        # Convert keys and values to strings safely
        cat = string(key.TrainCategory)
        id = string(key.TrainId)
        path = Vector{String}(stops.Station)
        
        route_map[(cat, id)] = path
    end

    if save_to_csv
        # Create a formatted DataFrame for CSV export
        csv_df = DataFrame(
            TrainCategory = [k[1] for k in keys(route_map)],
            TrainId = [k[2] for k in keys(route_map)],
            # Join the vector into a simple string for the CSV column
            Route = [join(v, ", ") for v in values(route_map)]
        )
        
        CSV.write(filename, csv_df)
        println("Route map saved to $filename")
    end

    return route_map
end



"""
Parses the infrastructure XML, 
and stores km distance and electrification status.
"""
function parse_infrastructure_xml(file_path::AbstractString; save_to_csv::Bool = false, filename::String = "infrastructure_data.csv")
    # Load the XML file
    xml_doc = readxml(file_path)
    root_node = root(xml_doc)
    
    route_dict = Dict{Tuple{String, String}, NamedTuple{(:km, :electrified), Tuple{Float64, Bool}}}()
    
    # Iterate through all <linesegment> elements
    for segment in findall("//linesegment", root_node)
        # Extract Distance
        km_val = parse(Float64, segment["kmvalue"])
        
        # Extract Electrification (convert "true"/"false" string to Bool)
        is_electrified = haskey(segment, "electrified") ? lowercase(segment["electrified"]) == "true" : false
        
        # Extract and Clean station IDs
        stations = findall("./stationref", segment)
        if length(stations) >= 2
            id1 = stations[1]["stationid"]
            id2 = stations[2]["stationid"]
            
            # Sort IDs alphabetically so (A, B) is the same as (B, A)
            route_key = id1 < id2 ? (id1, id2) : (id2, id1)
            
            # Store both values in the dictionary only if the key doesn't exist
            if !haskey(route_dict, route_key)
                route_dict[route_key] = (km = km_val, electrified = is_electrified)
            end
        end
    end
    
    # Handle CSV Export
    if save_to_csv
        export_df = DataFrame(
            Station_A = [k[1] for k in keys(route_dict)],
            Station_B = [k[2] for k in keys(route_dict)],
            Distance_KM = [v.km for v in values(route_dict)],
            Electrified = [v.electrified for v in values(route_dict)]
        )
        sort!(export_df, :Station_A)
        CSV.write(filename, export_df)
        println("Data saved to $filename")
    end
    
    return route_dict
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

function merge_data(df_timetable::DataFrame, df_passenger::DataFrame, df_infrastructure::Dict; save_to_csv::Bool = false, filename::String = "merged_data.csv")
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
                    demand = max(demand, next_demand)  # Optionally take the max demand to be conservative
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

            # Get infrastructure data for this leg
             # 2. AGGREGATE INFRASTRUCTURE DATA
            # We look at every single step in the timetable between idx_start and idx_end
            total_distance = 0.0
            is_fully_electrified = true
            segment_found_count = 0
            required_segments = idx_end - idx_start

            for j in idx_start:(idx_end - 1)
                st_a = train_tt.Station[j]
                st_b = train_tt.Station[j+1]
                
                # Sort keys to match Dict format
                route_key = st_a < st_b ? (st_a, st_b) : (st_b, st_a)
                
                if haskey(df_infrastructure, route_key)
                    infra = df_infrastructure[route_key]
                    total_distance += infra.km
                    # If any single part is NOT electrified, the whole leg is not
                    is_fully_electrified = is_fully_electrified && infra.electrified
                    segment_found_count += 1
                else
                    @warn "Missing infrastructure data for segment: $st_a to $st_b"
                    is_fully_electrified = false
                end
            end

            # If no segments were found, ensure distance is 0 and electrified is false
            if segment_found_count == 0
                is_fully_electrified = false
            end

            push!(results, (
                TrainCategory        = t_cat,
                TrainId              = t_id,
                FromStation          = train_tt.Station[idx_start],
                DepartureFromStation = train_tt.Departure[idx_start],
                ToStation            = train_tt.Station[idx_end],
                ArrivalToStation     = train_tt.Arrival[idx_end],
                Demand               = leg_demand,
                Distance_KM          = round(total_distance, digits = 1),
                Electrified          = is_fully_electrified
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



"""
Extract station names from an Excel file and optionally save to CSV.

# Arguments
- `path::String`: Path to the Excel file.
- `save_to_csv::Bool`: If true, save the resulting DataFrame to CSV file. Default is false.
- `filename::String`: Name of the output CSV file. Default is "station_names.csv".

# Returns
- `DataFrame`: Table with columns "Abbreviations" and "Long Name".
"""
function extract_station_names(path::String; save_to_csv::Bool = false, filename::String = "station_names.csv")
    # Open the excel file
    xf = XLSX.readxlsx(path)
    sheet = xf[1] 
    data = XLSX.gettable(sheet) |> DataFrame
    
    # Select the 2nd and 3rd columns by index and clean the station names
    df = data[:, [2, 3]]
    df[:, 1] = map(name -> occursin("/", name) ? name : name * "/86", df[:, 1]) # add danish suffix, if no suffix is given
    rename!(df, [1 => "Abbreviations", 2 => "Long Name"])
    
    if save_to_csv
        sort!(df, :Abbreviations)
        CSV.write(filename, df)
        println("Saved to $filename")
    end
    
    return df
end



"""
Find adjacent stations to a given station across all routes.

Returns a set of neighboring stations that directly precede or follow the start_station
in any route, excluding stations marked as bad.

# Arguments
- `routes_df`: DataFrame containing route information
- `start_station`: Station identifier to find neighbors for
- `bad_stations`: Set of station identifiers to exclude from results

# Returns
- `Set{String}`: Set of valid neighboring station identifiers
"""
function get_neighbor_stations(routes_df, start_station, bad_stations = Set{String}())
    neighbors = Set{String}()
    
    # Find all stations adjacent to start_station
    for route in routes_df.Route
        idx = findfirst(isequal(start_station), route)
        if idx !== nothing
            # Check left neighbor
            if idx > 1
                left_neighbor = route[idx - 1]
                if !(left_neighbor in bad_stations)
                    push!(neighbors, left_neighbor)
                end
            end
            # Check right neighbor
            if idx < length(route)
                right_neighbor = route[idx + 1]
                if !(right_neighbor in bad_stations)
                    push!(neighbors, right_neighbor)
                end
            end
        end
    end
    
    return neighbors
end


"""
Add 24 hours to a given time string, effectively shifting it to the next day.

# Arguments
- `time_str::String`: A time string in the format "HH:MM:SS" or "HH:MM". Empty strings are handled gracefully.

# Returns
- `String`: The adjusted time string with 24 hours added, formatted as "HH:MM:SS" with leading zeros for single-digit components.
"""

function add_24h_offset(time_str::String)
    parts = split(time_str, ":")
    h = parse(Int, parts[1]) + 24
    m = parse(Int, parts[2])
    # Use existing seconds if available, otherwise "00"
    s = length(parts) >= 3 ? parse(Int, parts[3]) : 0
    return @sprintf("%02d:%02d:%02d", h, m, s)
end