using Random, Statistics

function f(data)
    median(data)
end

function repeated_f(data, n=10)
    for _ in 1:n
        f(data)
    end
end

function repeated_f_mt(data, n=10)
    Threads.@threads for _ in 1:n
        f(data)
    end
end

Random.seed!(42)
data = rand(10_000_000)
nruns = 32
f(data)
res_f = @time f(data)

repeated_f(data, 1)
res_rep_f = @time repeated_f(data, nruns)

repeated_f_mt(data, 1)
res_rep_f_mt = @time repeated_f_mt(data, nruns)

using ArenaPirate

function f_arena(data)
    @arena median(data)
end

function repeated_f_arena(data, n=10)
    for _ in 1:n
        f_arena(data)
    end
end

function repeated_f_mt_arena(data, n=10)
    Threads.@threads for _ in 1:n
        f_arena(data)
    end
end

println("____ Arena benchmarks:")
f_arena(data)
res_f_arena = @time f_arena(data)

repeated_f_arena(data, 1)
res_rep_f_arena = @time repeated_f_arena(data, nruns)

repeated_f_mt_arena(data, 1)
res_rep_f_mt_arena = @time repeated_f_mt_arena(data, nruns)

@assert res_f == res_f_arena
@assert res_rep_f == res_rep_f_arena
@assert res_rep_f_mt == res_rep_f_mt_arena