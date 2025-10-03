# ArenaPirate

Proof-of-concept arena memory allocation mechanism for the [julia programming language](https://julialang.org/), inspired by [Bumper.jl](https://github.com/MasonProtter/Bumper.jl/) and [AllocArrays.jl](https://github.com/ericphanson/AllocArrays.jl). In many cases this package can speed up allocations in code that is not arena-aware (like `Statistics.median`, see `examples/medians.jl`). For garbage collection-heavy multithreaded workloads 2-3x speedups are often observed. Another use case is to avoid writing boilerplate preallocation code.

 The implementation relies on language features defined in julia 1.11+: `GenericMemory` (a more centralized method for working with memory allocations) and `ScopedVariables` (a handy way of providing state to callees). 

**!!** This package works by redefining `function Memory{T}(::UndefInitializer, m::Int64) where T<:Any` thus committing a **huge type piracy** invalidating lots of compiled code. Expect all sorts of rough edges. The package is not registered in the general registry yet.

The main interface provided is the `@arena` macro. By wrapping a section of code with `@arena`, we promise that memory allocations within this section are "temporary" and will not be used outside the scope of the enclosing `@arena`. Calls to `Memory{T}` within `@arena` scope are allocated on arena and do not invoke `malloc` for allocation or garbage collector for deallocation.

Currently only large enough (`1000+` bytes) allocations of `Memory{T}` where `isbitstype(T)` are subject to arena allocation. For other allocations or when the arena doesn't have enough remaining capacity the standard julia allocation mechanism is used as fallback. In my experience small allocations do not benefit from arenas as garbage collector manages them efficiently in its pool.

Example usage:
```julia
function allocating_f(N)
    arr = collect(1:N) # allocates
    return sum(arr)
end

allocating_f(1_000_000); # compile
@time allocating_f(1_000_000) # 0.005462 seconds (3 allocations: 7.633 MiB)

using ArenaPirate
f_arena(N) = @arena allocating_f(N) # wrap allocating code in @arena
f_arena(1_000_000); # compile
@time f_arena(1_000_000) # 0.001739 seconds (11 allocations: 272 bytes)
```

`@arena`s can be nested - child arenas reuse the parent's memory block. The innermost `@arena` is the one defining scope for a particular allocation. There is also a `@noarena` macro that disables arena within its scope. The following example: `@noarena` ensures `results` vector memory will not move to arena in case it needs to grow. Note, however, it is an anti-pattern in my opinion because it breaks composability - a function containing such code will still allocate even if wrapped in `@arena`.
```julia
results = []
for x in arr
    @arena begin
        y = f(x)
        y = copyfromarena(y) # if y is not isbits
        @noarena push!(results, y)
    end
end
```
`map_arena` utility function and its multithreaded counterpart `mtmap_arena` are also provided. For multithreaded workloads on machines with NUMA I recommend trying `pinthreads(:numa)` from excellent [ThreadPinning.jl](https://github.com/carstenbauer/ThreadPinning.jl). This is intended to keep arena memory close to the core using it.

## Arena management 
Upon calling `using ArenaPirate` `function Memory{T}` gets redefined and `ArenaPirate.__init__` method is called which initializes an empty pool of arenas (separate empty vector of arenas per thread). Arenas are exclusive per task. When a task requests an arena either one is retrieved from the corresponding thread's pool or a new 128mb Arena is allocated. Once the outermost `@arena` scope is exited, the arena is returned to the pool.

To release arenas call `clear_arena_pool!`.


## Limitations
- `@spawn` within `@arena` will prevent child tasks from acquiring their own arenas. Nesting arenas within a single task is fine, spawning tasks that call `@arena` outside arena scope works fine as well.
- Non-isbits types will go through usual allocations. Currently I do not know a better mechanism for deciding whether particular allocation is arena-eligible.
