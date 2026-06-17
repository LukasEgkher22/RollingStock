import pandas as pd
import os
from datetime import datetime
from io import StringIO

def _parse_composition(comp_string):
    """
    Parses composition strings into a flat list of individual rolling stock unit types.
    e.g., "2xICA, 1xERF" -> ["ICA", "ICA", "ERF"]
    """
    s = str(comp_string)
    segments = s.split(',')
    final_types = []
    
    for segment in segments:
        clean_segment = segment.strip()
        if not clean_segment:
            continue
            
        if 'x' in clean_segment:
            parts = clean_segment.split('x')
            try:
                count = int(parts[0].strip())
                type_name = parts[1].strip()
                for _ in range(count):
                    final_types.append(type_name)
            except (ValueError, IndexError):
                # Fallback if string format is weird
                final_types.append(clean_segment)
        else:
            final_types.append(clean_segment)
            
    return final_types

def calculate_totals(result_df, rs_details):
    """
    Calculates total unit costs and kilometer costs based on rolling stock metadata.
    """
    total_unit_cost = 0.0
    total_km_cost = 0.0
    
    if result_df.empty:
        return 0.0, 0.0

    # Extract TypeName from UnitSpecificId (e.g., "ICA_1" -> "ICA")
    temp_df = result_df.copy()
    temp_df['TypeName'] = temp_df['UnitSpecificId'].apply(lambda x: x.split('_')[0])
    unique_types = temp_df['TypeName'].unique()
    
    for t in unique_types:
        # Filter RS_Details for the specific type
        # Assuming RS_Details has columns 'Name', 'Unit cost', and 'Kilometer costs'
        row = rs_details[rs_details['Name'] == t]
        if row.empty:
            continue
            
        u_cost_per_unit = row.iloc[0]['Unit cost']
        km_cost_per_km = row.iloc[0]['Kilometer costs']
        
        # Calculate unique units of this type
        type_units = temp_df[temp_df['TypeName'] == t]
        unit_count = type_units['UnitSpecificId'].nunique()
        
        # Calculate total distance for this type
        total_dist = type_units['Distance'].sum()
        
        total_unit_cost += unit_count * u_cost_per_unit
        total_km_cost += total_dist * km_cost_per_km
        
    return total_unit_cost, total_km_cost

def assign_unit_ids(df, file_path_BASEDAY, solution, file_title="TrainModel"):
    """
    Simulates the assignment of physical rolling stock units to scheduled trips.
    """
    timestamp = datetime.now().strftime("%Y-%m-%d_%H%M%S")
    summary_filename = f"UnitSummary_{file_title}_{timestamp}.txt"
    result_filename = f"UnitAssignment_{file_title}_{timestamp}"
    
    # Read Rolling Stock data from Excel
    rs_data = pd.read_excel(file_path_BASEDAY, sheet_name="Rolling Stock")
    
    # Setup Data
    working_df = df.sort_values(by='Departure').copy()
    has_ggv = "GGVId" in working_df.columns
    
    # Unit Tracker: UID -> {"station": str, "time": int, "tid": str, "gid": str}
    unit_registry = {}
    unit_counters = {}
    unit_start_locations = {}
    assigned_rows_list = []

    for _, row in working_df.iterrows():
        tid = str(row['TrainId'])
        gid = str(row['GGVId']) if has_ggv else "-1"
        st = str(row['FromStation'])
        dep = int(row['Departure'])
        needed_types = _parse_composition(row['Composition'])
        
        trip_units = []
        
        for utype in needed_types:
            # Find candidate units of this type currently at this station and ready
            candidates = []
            for uid, status in unit_registry.items():
                if uid.startswith(f"{utype}_") and status['station'] == st and status['time'] <= dep:
                    candidates.append(uid)
            
            chosen_uid = ""
            
            if candidates:
                # PRIORITY 1: Same TrainId (Continuity)
                match = next((u for u in candidates if unit_registry[u]['tid'] == tid), None)
                
                # PRIORITY 2: Same GGVId
                if match is None and gid != "-1":
                    match = next((u for u in candidates if unit_registry[u]['gid'] == gid), None)
                
                # PRIORITY 3: Longest waiting unit (Earliest availability)
                if match is None:
                    # Sort by availability time
                    candidates.sort(key=lambda u: unit_registry[u]['time'])
                    match = candidates[0]
                
                chosen_uid = match
            else:
                # PRIORITY 4: Spawn New
                unit_counters[utype] = unit_counters.get(utype, 0) + 1
                chosen_uid = f"{utype}_{unit_counters[utype]}"
                unit_start_locations[chosen_uid] = st
            
            # Update Registry: Unit is now busy. 
            # Set station to "TRANSIT" temporarily to avoid simultaneous trip conflicts
            unit_registry[chosen_uid] = {
                "station": "TRANSIT", 
                "time": int(row['Arrival']), 
                "tid": tid, 
                "gid": gid
            }
            trip_units.append(chosen_uid)
        
        # After assigning all units for trip, finalize arrival at ToStation
        for uid in trip_units:
            status = unit_registry[uid]
            unit_registry[uid]['station'] = str(row['ToStation'])
            
            # Create output row
            new_row_dict = row.to_dict()
            if 'Composition' in new_row_dict:
                del new_row_dict['Composition']
            new_row_dict['UnitSpecificId'] = uid
            assigned_rows_list.append(new_row_dict)

    # 4. Finalization
    result_df = pd.DataFrame(assigned_rows_list)
    
    # 5. Summary Generation
    summary_io = StringIO()
    summary_io.write(f"--- Unit Assignment Summary: {file_title} ---\n")
    summary_io.write(f"Generated: {timestamp}\n")
    summary_io.write(f"From Composition Solution: {solution}\n\n")

    total_unit_cost, total_km_cost = calculate_totals(result_df, rs_data)
    total_costs = total_unit_cost + total_km_cost
    
    summary_io.write(f"Total unit cost: {total_unit_cost}\n")
    summary_io.write(f"Total kilometer cost: {total_km_cost}\n")
    summary_io.write(f"Total costs: {total_costs}\n\n")

    total_units = 0
    for utype in sorted(unit_counters.keys()):
        count = unit_counters[utype]
        summary_io.write(f"Type {utype}: {count} units\n")
        total_units += count

    summary_io.write(f"TOTAL UNIQUE UNITS: {total_units}\n")
    summary_io.write("\n[Initial Deployment]\n")
    for uid in sorted(unit_start_locations.keys()):
        summary_io.write(f"{uid} starts at {unit_start_locations[uid]}\n")
    
    summary_text = summary_io.getvalue()

    # 6. File Writing
    if not os.path.exists("Results"):
        os.makedirs("Results")
        
    result_df = result_df.sort_values(by=['UnitSpecificId', 'Departure'])
    result_df.to_csv(os.path.join("Results", result_filename + ".csv"), index=False)
    
    with open(os.path.join("Results", summary_filename), "w") as f:
        f.write(summary_text)

    print(f"Files generated: {result_filename}, {summary_filename}")
    return result_df, unit_counters, result_filename

def process_unit_swaps(df, filename):
    # 1. Sort by Departure to ensure we process chronologically
    df = df.sort_values(by='Departure').reset_index(drop=True)
    
    # 2. Extract Type (everything before the _)
    df['UnitType'] = df['UnitSpecificId'].apply(lambda x: x.split('_')[0])
    
    # Get unique TripIds in chronological order
    unique_trips = df['TripId'].unique()
    for current_trip_id in unique_trips:
        # Get all rows for the current trip (Incoming Trip A)
        trip_a = df[df['TripId'] == current_trip_id]
        arrival_time = trip_a['Arrival'].max()
        to_station = trip_a['ToStation'].iloc[0]
        ggv_a = trip_a['GGVId'].iloc[0] if 'GGVId' in trip_a.columns else "-1"
        train_id_a = trip_a['TrainId'].iloc[0]
        
        # 3. Find the "following" trip (Trip B)
        # Condition: Different TripId, Same GGV (or TrainId if GGV -1), FromStation == ToStation
        if ggv_a != "-1":
            mask_b = (df['TripId'] != current_trip_id) & \
                     (df['GGVId'] == ggv_a) & \
                     (df['FromStation'] == to_station)
        else:
            mask_b = (df['TripId'] != current_trip_id) & \
                     (df['TrainId'] == train_id_a) & \
                     (df['FromStation'] == to_station)
        
        following_trips = df[mask_b]
        
        if following_trips.empty:
            continue
        # Get the specific TripId that follows immediately
        next_trip_id = following_trips['TripId'].iloc[0]
        trip_b = df[df['TripId'] == next_trip_id]
        
        # 4. Compare Units by Type
        types_involved = set(trip_a['UnitType']).union(set(trip_b['UnitType']))
        
        for u_type in types_involved:
            units_in = set(trip_a[trip_a['UnitType'] == u_type]['UnitSpecificId'])
            units_out = set(trip_b[trip_b['UnitType'] == u_type]['UnitSpecificId'])

            # Incoming but not outgoing
            lost_units = list(units_in - units_out)
            # Outgoing but didn't come in
            gained_units = list(units_out - units_in)
            
            # 5. If there is a mismatch, perform the swap for all future trips
            # Zip them to swap 1-for-1
            for old_id, new_id in zip(lost_units, gained_units):
                # Target: All rows starting from the current arrival time
                
                future_mask = df['Departure'] >= arrival_time
                print(f"At {to_station} (Trip {current_trip_id}->{next_trip_id}): Swapping {old_id} with {new_id} for future trips.")
                
                # Logical swap in the whole future dataset
                # We use a temporary placeholder to avoid overwriting
                idx_old = df.index[future_mask & (df['UnitSpecificId'] == old_id)]
                idx_new = df.index[future_mask & (df['UnitSpecificId'] == new_id)]
                
                df.loc[idx_old, 'UnitSpecificId'] = "TEMP_PLACEHOLDER"
                df.loc[idx_new, 'UnitSpecificId'] = old_id
                df.loc[df['UnitSpecificId'] == "TEMP_PLACEHOLDER", 'UnitSpecificId'] = new_id
                
                print(f"At {to_station} (Trip {current_trip_id}->{next_trip_id}): Swapped {new_id} with {old_id} for future trips.")
    
    df = df.sort_values(by=['UnitSpecificId', 'Departure'])
    df.to_csv(os.path.join("Results", filename + "_processed.csv"), index=False)

    return df.drop(columns=['UnitType'])
