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
f(data)
@time f(data)

repeated_f(data)
@time repeated_f(data)

repeated_f_mt(data)
@time repeated_f_mt(data)

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
@time f_arena(data)

repeated_f_arena(data)
@time repeated_f_arena(data)

repeated_f_mt_arena(data)
@time repeated_f_mt_arena(data)