using EzXML
using DataFrames


"""
Reads the XML file.

Arguments
- `file_path::AbstractString`: Path to the XML file to parse.

Returns
- `DataFrame` with columns:
    - `Operator::String`
    - `TrainCategory::String`
    - `TrainNumber::String`
    - `DayType::String`
    - `PassengerNum::Int` — parsed integer value of the <PassengerNumber> element
    - `FromStation::String` — the `ShortName` attribute of the <FromStation> sub-element
    - 'FromCountry::String' — the `CountryCode` attribute of the <FromStation> sub-element (optional)
    - `ToStation::String` — the `ShortName` attribute of the <ToStation> sub-element
    - 'ToCountry::String' — the `CountryCode` attribute of the <ToStation> sub-element (optional)
"""

function parse_passenger_xml(file_path::AbstractString)
    doc = readxml(file_path)

    # Define namespace map
    ns = ["tns" => "http://trafik.dsb.dk/passengernumbers"]
    
    data_rows = []

    # Find all PassengerNumber elements
    for node in findall("//tns:PassengerNumber", root(doc), ns)
        row = (
            Operator      = node["Operator"],
            TrainCategory = node["TrainCategory"],
            TrainNumber   = node["TrainNumber"],
            DayType       = node["DayType"],
            PassengerNum  = parse(Int, node["PassengerNumber"]),
            
            # get data from sub-elements
            FromStation   = findfirst("tns:FromStation", node, ns)["ShortName"],
            #FromCountry   = findfirst("tns:FromStation", node, ns)["CountryCode"],
            ToStation     = findfirst("tns:ToStation", node, ns)["ShortName"],
            #ToCountry     = findfirst("tns:ToStation", node, ns)["CountryCode"]
        )
        push!(data_rows, row)
    end
    
    return DataFrame(data_rows)
end


function aggregate_train_routes(df::DataFrame)
    gdf = groupby(df, [:Operator, :TrainCategory, :TrainNumber, :DayType])
    
    # create empty dataframe to store results
    results = combine(gdf) do sub_df
        max_p = maximum(sub_df.PassengerNum)
        
        from_stations = Set(sub_df.FromStation)
        to_stations = Set(sub_df.ToStation)
        
        # start_st is the one that appears in FromStation but never in ToStation, end_st is the opposite
        start_st = collect(setdiff(from_stations, to_stations))
        end_st = collect(setdiff(to_stations, from_stations))
        
        # build the full route as a path from start to end
        path = [start_st]
        current = start_st
        temp_df = copy(sub_df)
        
        while true
            idx = findfirst(x -> x == current, temp_df.FromStation)
            if idx === nothing
                break
            end
            next_st = temp_df.ToStation[idx]
            push!(path, next_st)
            current = next_st
            # delete the used row to avoid loops
            deleteat!(temp_df, idx)
        end
        
        full_route_string = join(path, "-")
        
        return (
            Operator        = sub_df.Operator[1],
            TrainCategory   = sub_df.TrainCategory[1],
            TrainNumber     = sub_df.TrainNumber[1],
            DayType         = sub_df.DayType[1],
            StartStation    = start_st,
            EndStation      = end_st,
            MaxPassengerNum = max_p,
            FullRoute       = full_route_string
        )
    end
    
    return results
end
