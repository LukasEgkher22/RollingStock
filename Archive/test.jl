using DataFrames
using CSV
using XLSX

project_root = dirname(@__DIR__)

result = CSV.read(joinpath(project_root, "results_composition_assignments.csv"), DataFrame)
filtered_result = filter(
	row -> occursin("FA/86", string(coalesce(row.FromStation, ""))) ||
		   occursin("FA/86", string(coalesce(row.ToStation, ""))),
	result,
)
sorted_result = sort(filtered_result, :Departure)
CSV.write(joinpath(project_root, "results_composition_assignments_sorted.csv"), sorted_result)




