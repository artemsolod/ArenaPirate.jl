using Test

function f(N)
    sum(collect(1:N) + collect(1:N))
end

@testset "ArenaPirate.jl" begin
    x_noarena = f(2000)

    using ArenaPirate
    x_arena = f(2000)

    @test x_noarena == x_arena
end


# edge case: `@arena @spawn @arena f(x)`
# to copy f(x) we need to put copy inside `@spawn` (or better even inside @arena)



