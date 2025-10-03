using Profile

using Random
Random.seed!(42)

Ndata = 100_000
data_a, data_b, data_c = randn(Ndata), randn(Ndata), randn(Ndata)
params_a = params_b = params_c = 1:30 #20

function param_search(data_a, data_b, data_c, params_a, params_b, params_c)
    map(params_a) do a
        y_a = a * data_a
        map(params_b) do b
            y_ab = @. y_a + b * data_b
            # y_abc = similar(y_ab)
            map(params_c) do c
                # @. y_abc = y_ab + c * data_c
                y_abc = @. y_ab + c * data_c
                cost = sum(y_abc)
                (; a, b, c, cost)
            end 
        end |> xs -> reduce(vcat, xs)
    end |> xs -> reduce(vcat, xs)
end

param_search(data_a, data_b, data_c, params_a, params_b, params_c)
res1 = @time param_search(data_a, data_b, data_c, params_a, params_b, params_c)

using Revise
using ArenaPirate

function param_search_arena(data_a, data_b, data_c, params_a, params_b, params_c)
    map_arena(params_a) do a
        y_a = a * data_a
        map_arena(params_b) do b
            y_ab = @. y_a + b * data_b
            map_arena(params_c) do c
                y_abc = @. y_ab + c * data_c
                cost = sum(y_abc)
                (; a, b, c, cost)
            end |> xs -> @noarena(copy(xs))
        end |> xs -> @noarena(reduce(vcat, xs))
    end |> xs -> reduce(vcat, xs)
end

# @profview_allocs 
param_search_arena(data_a, data_b, data_c, params_a, params_b, params_c)
res2 = @time param_search_arena(data_a, data_b, data_c, params_a, params_b, params_c)

@assert res1 == res2