using CSV, DataFrames

project_root = dirname(@__DIR__)
include(joinpath(project_root, "Models", "CompositionModel_functions.jl"))



model = "SimpleModel"
result_path = normpath(joinpath(project_root, "Results", "CompAssignments_SimpleModel_2026-06-05_205646.csv"))
df = CSV.read(result_path, DataFrame)


# assign units specifically
results_df, summary = assign_unit_ids(df, file_title=model)