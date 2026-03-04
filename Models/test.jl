using DataFrames
using CSV
using XLSX

include(joinpath(dirname(@__DIR__), "DataTransformationScripts", "functions.jl"))
project_root = dirname(@__DIR__)

abbrev = CSV.read(joinpath(project_root, "DataManipulated", "StationAbbreviation.csv"), DataFrame)


# Iteratively find all connected neighbors
train_routes = CSV.read(joinpath(project_root, "DataManipulated", "train_routes.csv"), DataFrame)
train_routes.Route = [split(str, r",\s*") for str in train_routes.Route]

neighbors = Set{String}()
to_explore = ["AR"]
bad_stations = Set(["GP", "HP", "SNO", "OD", "TL", "KD", "LK", "ADF", "HMB", "PA", "RQ", "ASW", "AB", "HN", "HA", "LG", "BR"])


while !isempty(to_explore)
    current = pop!(to_explore)
    if current in neighbors
        continue
    end
    
    new_neighbors = get_neighbor_stations(train_routes, current, bad_stations ∪ neighbors)
    push!(neighbors, current)
    union!(to_explore, new_neighbors)
end

display(sort(collect(neighbors)))
for station in sort(collect(neighbors))
    name = abbrev[abbrev.Abbreviations .== station, "Long Name"][1]
    println("$station: $name")
end

unique_stations = Set{String}()
for route in train_routes.Route
    union!(unique_stations, route)
end
print("Number of stations: ", length(neighbors), "\n")
println("\nNumber of unique stations: ", length(unique_stations))





