using Random, Statistics

Random.seed!(42)
data = rand(10_000_000)
nruns = 32

function f(data)
    median(data)
end

function repeated_f(f, data, n=10)
    [f(data) for _ in 1:n]
end

function repeated_f_mt(f, data, n=10)
    res = zeros(n)
    Threads.@threads for ix in 1:n
        res[ix] = f(data)
    end
    return res
end


println("____ Built-in allocator benchmarks:")
f(data)
res_f = @time f(data)

repeated_f(f, data, 1)
res_rep_f = @time repeated_f(f, data, nruns)

repeated_f_mt(f, data, 1)
res_rep_f_mt = @time repeated_f_mt(f, data, nruns)


using ArenaPirate

function f_arena(data)
    @arena f(data)
end

println("____ Arena benchmarks:")
f_arena(data)
res_f_arena = @time f_arena(data)

repeated_f(f_arena, data, 1)
res_rep_f_arena = @time repeated_f(f_arena, data, nruns)

repeated_f_mt(f_arena, data, 1)
res_rep_f_mt_arena = @time repeated_f_mt(f_arena, data, nruns)

@assert res_f == res_f_arena
@assert res_rep_f == res_rep_f_arena
@assert res_rep_f_mt == res_rep_f_mt_arena