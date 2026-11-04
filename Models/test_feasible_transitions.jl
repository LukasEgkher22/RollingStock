using CSV
using DataFrames
using XLSX
using Test

project_root = dirname(@__DIR__)

include(joinpath(project_root, "DataTransformationScripts", "DataManipulation_functions.jl"))
include(joinpath(project_root, "Models", "CompositionModel_functions.jl"))

# -----------------------------------------------------------
# LOAD DATA
# -----------------------------------------------------------
timetable_data = CSV.read(joinpath(project_root, "DataManipulated", "aggregated_trips.csv"), DataFrame)
connections = build_connections(timetable_data)

excel_file = XLSX.readxlsx(joinpath(project_root, "Data", "Base Day TUE.xlsx"))
RS_Data = DataFrame(XLSX.gettable(excel_file["Rolling Stock"]))
compositions_raw = DataFrame(XLSX.gettable(excel_file["Composition groups"], header=false))[!, 1]
cutpoints = DataFrame(XLSX.gettable(excel_file["Trip cutpoints"]))
shunting_operations = DataFrame(XLSX.gettable(excel_file["Shunting operations"]))
system_mapping = DataFrame(XLSX.gettable(excel_file["Train system mapping"]))

push!(compositions_raw, "empty")
unit_names = vcat(String.(RS_Data.Name), "empty")

compositions, comp_units, comp_number = get_ordered_compositions(compositions_raw, unit_names)
comp_idx = Dict(c => i for (i, c) in enumerate(compositions))

# -----------------------------------------------------------
# UNIT TESTS FOR SINGLE TRANSITIONS
# -----------------------------------------------------------
rules = get_shunt_rules(shunting_operations)
feasible(code, from, to) = is_feasible_shunt(comp_units[comp_idx[from]], comp_units[comp_idx[to]], rules[code])

@testset "aGk (passing through: couple front, uncouple rear)" begin
    @test feasible("aGk", "ICA", "ICA")               # no change
    @test feasible("aGk", "ICA", "ERF-ICA")           # couple ERF at the front
    @test !feasible("aGk", "ICA", "ICA-ERF")          # coupling at the rear not allowed
    @test feasible("aGk", "ICA-ERF", "ICA")           # uncouple ERF at the rear
    @test !feasible("aGk", "ICA-ERF", "ERF")          # uncoupling at the front not allowed
    @test !feasible("aGk", "ICA-ERF", "ERF-ICA")      # no turning
    @test !feasible("aGk", "ICA-ERF", "ERF-ERF")      # coupling and decoupling at the same time
    @test feasible("aGk", "empty", "ICA-ICA-ICA-ICA") # up to 4 units
end

@testset "Vka (reversing: couple/uncouple front, then turn)" begin
    @test feasible("Vka", "ICA-ERF", "ERF-ICA")       # only turning
    @test !feasible("Vka", "ICA-ERF", "ICA-ERF")      # must turn
    @test feasible("Vka", "ICA", "ICA-ERF")           # ERF-ICA after coupling at front, then turned
    @test !feasible("Vka", "ICA", "ERF-ICA")          # would be coupling at the rear
    @test feasible("Vka", "ICA-ERF", "ERF")           # uncouple ICA at the front, then turned
    @test !feasible("Vka", "ICA-ERF", "ICA")          # would be uncoupling at the rear
end

@testset "G (no coupling, no turning)" begin
    @test feasible("G", "ICA-ERF", "ICA-ERF")
    @test !feasible("G", "ICA-ERF", "ERF-ICA")
    @test !feasible("G", "ICA", "ICA-ICA")
end

# -----------------------------------------------------------
# FEASIBLE TRANSITIONS PER CONNECTION
# -----------------------------------------------------------
feasible_pairs, connection_codes = get_feasible_transitions_per_connection(
    connections, timetable_data, comp_units, cutpoints, shunting_operations, system_mapping
)

C = length(compositions)
N = nrow(connections)
println("\nC = $C ordered compositions, N = $N connections")
println("x variables without restriction: $(C^2 * N)")
println("x variables with restriction:    $(sum(length, feasible_pairs))\n")

println("Connections per shunt code:")
for code in sort(unique(connection_codes))
    idx = findall(==(code), connection_codes)
    println("  $code: $(length(idx)) connections, $(length(feasible_pairs[idx[1]])) feasible (c1, c2) each")
end

println("\nShunt code per connection station (excluding Start/End):")
station_summary = combine(
    groupby(DataFrame(Station = connections.ConnectionStation, Code = connection_codes), [:Station, :Code]),
    nrow => :Count
)
show(sort(filter(row -> !(row.Code in ("Start", "End")), station_summary), :Station), allrows = true)
println()

# example: all feasible successors of one composition
for code in ("aGk", "Vka")
    successors = [c2 for c2 in compositions if feasible(code, "ICA-ERF", c2)]
    println("\n$code: ICA-ERF -> ", join(successors, ", "))
end
