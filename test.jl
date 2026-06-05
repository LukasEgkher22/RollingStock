using CSV
using DataFrames

function get_duplicate_origin_ids(file_path::String)
    # 1. Load the CSV into a DataFrame
    df = CSV.read(file_path, DataFrame)

    # 2. Group by OriginTrainId
    # 3. Calculate the count of unique TrainIds and (optional) list them
    summary = combine(groupby(df, :OriginTrainId)) do subdf
        unique_ids = unique(subdf.TrainId)
        (
            unique_train_count = length(unique_ids),
            involved_train_ids = join(unique_ids, ", ") # Added so you can see which IDs they are
        )
    end

    # 4. Filter for those appearing in 2 or more different TrainIds
    duplicates = filter(row -> row.unique_train_count >= 2, summary)

    # Sort by highest unique_train_count first, then OriginTrainId ascending
    sort!(duplicates, [:unique_train_count, :OriginTrainId], rev=[true, false])

    return duplicates
end

function get_station_departures(file_path::String, station_name::String)
    # 1. Load the data
    df = CSV.read(file_path, DataFrame)
    
    # 2. Filter for trips involving this station and containing ICA
    station_df = filter(row -> (row.FromStation == station_name || row.ToStation == station_name) && 
                               contains(string(row.Composition), "ICA"), df)
    
    # 3. Sort by Departure time to track the chronological flow
    sorted_df = sort(station_df, :Departure)
    
    # 4. Calculate ICA counts and running balance
    ica_balance = Int[]
    current_inventory = 0
    
    for row in eachrow(sorted_df)
        # Helper to count ICA units in the composition (handles "2xICA", etc.)
        num_ica = count_unit_occurrence(row.Composition, "ICA")
        
        if row.FromStation == station_name
            # Units are leaving the station
            current_inventory -= num_ica
        end
        
        if row.ToStation == station_name
            # Units are arriving at the station
            current_inventory += num_ica
        end
        
        push!(ica_balance, current_inventory)
    end
    
    # Add the result as a new column
    sorted_df.ICA_Inventory_Change = ica_balance
    
    return sorted_df
end

"""
Helper function to extract the count of a specific unit type from a composition string.
Handles formats like "ICA", "2xICA", or "1xERF, 2xICA".
"""
function count_unit_occurrence(comp_string, target_unit)
    s = string(comp_string)
    total_count = 0
    
    # Split by comma in case of multiple types: "1xERF, 2xICA"
    segments = split(s, ',')
    
    for segment in segments
        clean_segment = strip(segment)
        if contains(clean_segment, target_unit)
            if contains(clean_segment, 'x')
                # Extract number from "2xICA"
                parts = split(clean_segment, 'x')
                count_val = parse(Int, strip(parts[1]))
                total_count += count_val
            else
                # Just "ICA" implies 1 unit
                total_count += 1
            end
        end
    end
    return total_count
end

# Example usage:
departures = get_station_departures("CompAssignments_simpleModel_2026-06-05_20-12-55.csv", "HG/86")
println(departures)

# Usage:
# result = get_duplicate_origin_ids("GGV_dummies.csv")
# println(result)