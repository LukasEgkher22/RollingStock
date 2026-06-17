using CSV, DataFrames, Dates

project_root = dirname(@__DIR__)
include(joinpath(project_root, "Models", "CompositionModel_functions.jl"))
file_path_BASEDAY = normpath(joinpath(project_root, "Data", "Base Day TUE.xlsx"))

# TODO: Change the file name of the composition solution here
solution = "CompAssignments_GGV_2026-06-17_110857.csv"

model = split(solution, "_")[2]
result_path = normpath(joinpath(project_root, "Results", solution))
reallocation_sheet = "Reallocation"
turnover_rules = create_turnover_dict(file_path_BASEDAY, reallocation_sheet)
df = CSV.read(result_path, DataFrame)


# assign units specifically
results_df, summary = assign_unit_ids(df, file_path_BASEDAY, solution, file_title=String(model))