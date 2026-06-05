using CSV, DataFrames

project_root = dirname(@__DIR__)
include(joinpath(project_root, "Models", "CompositionModel_functions.jl"))



model = "GGV"
result_path = normpath(joinpath(project_root, "Results", "CompAssignments_includingGGV_2026-06-05_14-55-29.csv"))
df = CSV.read(result_path, DataFrame)


# If your model has GGV logic
results_df, summary = assign_unit_ids(df, file_title=model)