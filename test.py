import pandas as pd
import os

def summarize_data(df):
    # Determine the departure column
    dep_col = None
    if "DepartureFromStation" in df.columns:
        dep_col = "DepartureFromStation"
    elif "Departure" in df.columns:
        dep_col = "Departure"

    # Determine the arrival column
    arr_col = None
    if "ArrivalToStation" in df.columns:
        arr_col = "ArrivalToStation"
    elif "Arrival" in df.columns:
        arr_col = "Arrival"

    print(f"Rows: {len(df)}")

    if dep_col:
        # .min() automatically skips missing values (NaN) in pandas
        print(f"Earliest departure: {df[dep_col].min()}")
    else:
        print("Earliest departure: column not found")

    if arr_col:
        # .max() automatically skips missing values (NaN) in pandas
        print(f"Latest arrival: {df[arr_col].max()}")
    else:
        print("Latest arrival: column not found")

# Path logic
current_dir = os.path.dirname(os.path.abspath(__file__))

# Note: project_root needs to be defined. 
# Assuming project_root is the current_dir or a parent directory:
project_root = current_dir 

df_path = os.path.normpath(os.path.join(project_root, "DataManipulated", "merged_data.csv"))

# Load and summarize
try:
    # parse_dates=True helps ensure the time columns are treated as timestamps
    df = pd.read_csv(df_path, parse_dates=True)
    summarize_data(df)
except FileNotFoundError:
    print(f"File not found at: {df_path}")