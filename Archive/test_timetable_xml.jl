# load external functions
include("functions.jl")

# construct file path to XML
parent_dir = dirname(dirname(@__FILE__))
file_path = normpath(joinpath(parent_dir, "Data", "DLK_Timetable.xml"))

df = parse_timetable_xml(file_path)
println(first(df, 5))