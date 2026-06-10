using CSV, DataFrames

project_root = dirname(@__DIR__)
include(joinpath(project_root, "Models", "CompositionModel_functions.jl"))
file_path_BASEDAY = normpath(joinpath(parent_dir, "Data", "Base Day TUE.xlsx"))

# TODO: Change the file name of the composition solution here
solution = "CompAssignments_UnitPreservation_2026-06-10_161902.csv"

model = split(solution, "_")[2]
result_path = normpath(joinpath(project_root, "Results", solution))
df = CSV.read(result_path, DataFrame)


# assign units specifically
results_df, summary = assign_unit_ids(df, file_path_BASEDAY, solution, file_title=String(model))