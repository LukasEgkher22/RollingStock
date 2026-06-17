import pandas as pd
import os
from AssignUnits_functions import assign_unit_ids, process_unit_swaps

# TODO: Change the file name of the composition solution here
solution = "CompAssignments_SimpleModel_2026-06-10_095111.csv"

# Path Setup
current_dir = os.path.dirname(os.path.abspath(__file__))
project_root = os.path.dirname(current_dir)

model_name = solution.split("_")[1] 
file_path_BASEDAY = os.path.normpath(os.path.join(project_root, "Data", "Base Day TUE.xlsx"))
result_path = os.path.normpath(os.path.join(project_root, "Results", solution))
df = pd.read_csv(result_path)

# Run assignment logic
results_df, summary, filename = assign_unit_ids(
    df, 
    file_path_BASEDAY, 
    solution, 
    file_title=str(model_name)
)

# Perform swaps
final_df = process_unit_swaps(results_df, filename)