module ArenaPirate
import Mmap: MADV_HUGEPAGE
using Base.Threads
using Base.ScopedValues

export @arena, @noarena, clear_arena_pool!, copyfromarena, mtmap_arena, map_arena

mutable struct Arena
    const ptr::Ptr{Nothing}
    const capacity::Int
    active::Bool
    offset::Int
    min_alloc::Int
    task::Task # assigned only when `offset == 0`
end

const arena = Base.ScopedValues.ScopedValue{Union{Nothing,Arena}}(nothing)
const arena_pool = (;
    capacity=Ref{Int}(2^27),
    min_alloc=Ref{Int}(2032 - sizeof(Ptr{Nothing})), # GC_MAX_SZCLASS (2032-sizeof(void*))
    lock=ReentrantLock(), # SpinLock(),
    pool=Vector{Vector{Arena}}(), # should try to avoid moving arenas across cores / threads
)
const min_alloc = 2032 - sizeof(Ptr{Nothing}) # GC_MAX_SZCLASS (2032-sizeof(void*))

function Arena(; capacity=nothing, min_alloc=nothing)
    capacity = @something(capacity, arena_pool.capacity[])
    min_alloc = @something(min_alloc, arena_pool.min_alloc[])

    @static if Sys.isunix()
        # ptr = @ccall pvalloc(capacity::Csize_t)::Ptr{Cvoid} # depreceated pvalloc
        # PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS  
        ptr = @ccall mmap(C_NULL::Ptr{Cvoid}, capacity::Csize_t, 3::Cint, 34::Cint, (-1)::Cint, 0::Csize_t)::Ptr{Cvoid}
        retcode = @ccall madvise(ptr::Ptr{Cvoid}, capacity::Csize_t, MADV_HUGEPAGE::Cint)::Cint
        iszero(retcode) || @warn "Madvise HUGEPAGE for arena memory failed"
    else
        ptr = Libc.malloc(capacity)
    end
    finalizer(Arena(ptr, capacity, true, 0, min_alloc, current_task())) do a
        @static if Sys.isunix()
            @ccall munmap(ptr::Ptr{Cvoid}, capacity::Csize_t)::Cint
        else
            Libc.free(a.ptr)
        end
    end
end

function _reset_arena!(arena, tgt_offset=0)
    arena.active = true
    arena.offset = tgt_offset
    return arena
end

macro arena(call)
    quote
        tid = threadid()
        arenavisible = arena[]
        isoutermostarena = isnothing(arenavisible)
        if isoutermostarena 
            arena2use = lock(arena_pool.lock) do
                if isempty(arena_pool.pool[tid])
                    Arena()
                else
                    arena = pop!(arena_pool.pool[tid])
                    arena.task = current_task()
                    arena
                end
            end
        else
            arena2use::Arena = arenavisible
        end
        offset_orig = arena2use.offset
        active_orig = arena2use.active
        try
            arena2use.active = true
            if isoutermostarena
                @with arena => arena2use $(esc(call))
            else
                $(esc(call))
            end
        finally
            arena2use.offset = offset_orig
            arena2use.active = active_orig
            if isoutermostarena # can return the arena into the pool
                iszero(arena2use.offset) || @warn "Arena's offset should have returned to zero. Expect bugs."
                _reset_arena!(arena2use)
                lock(arena_pool.lock) do
                    push!(arena_pool.pool[tid], arena2use)
                end
            end
        end
    end
end

macro noarena(call)
    # if we have an arena, switch its status to inactive
    quote
        arenavisible = arena[]
        if isnothing(arenavisible)
            $(esc(call))
        else
            arena2use::Arena = arenavisible
            active_orig = arena2use.active
            try
                arena2use.active = false
                $(esc(call))
            finally
                arena2use.active = active_orig
            end
        end
    end
end

function copyfromarena(x)
    # ugly but ensures we don't return arena to pool prior to copying
    # simply `with(arena => nothing)` will interfere with nested `@arena` uses
    @arena(@noarena(copy(x)))
end

@inline function _alloc_arena!(arena::Arena, ::Type{T}, nels) where T # fails without Arena typed explicitly
    elsz = Base.aligned_sizeof(T)
    nbytes = nels * elsz
    if (current_task() === arena.task) && arena.active && (nbytes > 0) && (nbytes >= min_alloc)
        # since no other task uses this arena we don't worry about concurrency bugs
        # @noarena @show(m, T)
        offset_cand = arena.offset + nbytes
        offset_cand = (offset_cand + (elsz - 1)) & ~(elsz - 1) # enforce alignment
        if offset_cand < arena.capacity
            arena.offset = offset_cand
            ptr_cur = convert(Ptr{T}, arena.ptr + arena.offset - nbytes)
            # mem = @ccall jl_ptr_to_genericmemory(Memory{T}::Any, ptr_cur::Ptr{Cvoid}, nels::Csize_t, 0::Cint) :: Memory{T}
            mem = unsafe_wrap(Memory{T}, ptr_cur, nels; own=false)::Memory{T}
            return mem
        end
    end
    # fallback to usual memory allocator when arena doesn't have enough memory or when called from a different task
    # is this threadsafe though?
    @ccall jl_alloc_genericmemory(Memory{T}::Any, nels::Csize_t)::Memory{T}
end

@inline function Memory{T}(::UndefInitializer, m::Int64) where T<:Any
    # zero element allocations seem to exist and cause problems
    if isbitstype(T)
        arena2use = arena[]
        isnothing(arena2use) || (return _alloc_arena!(arena2use, T, m))
    end
    return @ccall jl_alloc_genericmemory(Memory{T}::Any, m::Csize_t)::Memory{T}
end

function clear_arena_pool!(pool_sz=0)
    resize!(arena_pool.pool, pool_sz)
end

map_arena(f, els) = map(x -> @arena(f(x)), els)
mtmap_arena(f, els) = fetch.([@spawn (@arena f(el)) for el in els])

function __init__()
    for _ in 1:(nthreads(:interactive)+nthreads(:default)-length(arena_pool.pool))
        push!(arena_pool.pool, Arena[])
    end
end

end # module ArenaPirate


# max_arenas_per_thread=Ref{Int}(typemax(Int)),
# allocating everything or over certain size? can exceptions work?
# allocation of (n, m) shapes?
# strict arena option (without fallbacks)?
# lifetimes?
# activate on import default
# allow resizing, ENV variable for first init?

# have a dict of currently used arenas and pick it up again to allow for @arena -> @noarena -> @arena pattern

# how to ensure `copyfromarena` before arena is gone?
# should @noarena within @arena be ignored? can we have @banarena instead? 
#    if @noarena is ignored within @areana - what is it's purpose then?
#    imagine all is good except in one place you need to push!. wouldn't you want @noarena
#    to help?

# Strict arena - no nesting allowed?
# ! to make sure we can't introduce a new arena inside @noarena block, we may use 3 states for it: Nothing | Arena | Noarena
# what semantics do we want from `@arena(@noarena(@arena(f(x))))`?
# what if `arena[]` | `arena_pool` manipulations occur within an arena? We definitely don't want that

# ? can `arena` become a function, not macro?

# ! NumaAllocation of memory per thread?
# can we assert arena is free after the end of use? this happens automatically, doesn't it? so what can be asserted?

# have immutable arena to save on indirectiona ?


# problematic like this? locking arena_pool on each iteration?
# @arena for x in xs
#     ...
# end




# function activate_arena!() #types=(Float64, Int64, UInt8))
#     @eval begin
#     end
# end

# can "remove" `@noarena` in this pattern? no, inner arena gets reset once out of scope
# @arena begin
#     res = []
#     @arena for x in xs
#         y = f(x)
#         @noarena push!(res, y)
#     end
#     sum(res)
# end
# Would probably be good to use memory "device" Arena, not cpu.
# ! what we want is to ask `is_arena` on data. the problem here is memory fragmentation though.
#   ! stil breaks arena logic of reverting back to outer scope context
# Maybe needs having memory "age"
