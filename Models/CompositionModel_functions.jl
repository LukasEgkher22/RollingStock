using DataFrames

function get_coupling_matrices(comp_list, unit_names)
    # 1. Pre-calculate the counts of each unit in each composition
    # This creates a nested lookup: counts_per_comp["ICA-ERF"]["ICA"] = 1
    counts_per_comp = Dict(
        c => Dict(u => count(==(u), split(c, "-")) for u in unit_names) 
        for c in comp_list[:, 1]
    )
    
    # 2. Initialize the dictionaries for results
    # Key format: (unit_name, composition_from, composition_to)
    coupled = Dict{Tuple{String, String, String}, Int}()
    decoupled = Dict{Tuple{String, String, String}, Int}()
    
    # 3. Fill the dictionaries
    for u in unit_names
        for c_from in comp_list[:, 1]
            for c_to in comp_list[:, 1] 
                # Calculate the change in number of units
                diff = counts_per_comp[c_to][u] - counts_per_comp[c_from][u]
                
                # Assign to the correct dictionary
                coupled[(u, c_from, c_to)] = max(0, diff)
                decoupled[(u, c_from, c_to)] = max(0, -diff)
            end
        end
    end
    
    return counts_per_comp, coupled, decoupled
end