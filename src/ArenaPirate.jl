module ArenaPirate
import Mmap: MADV_HUGEPAGE

export activate_arena!, @arena, @noarena, copy_from_arena, mtmap_arena, map_arena

# can we assert arena is free after the end of use? this happens automatically, doesn't it? so what can be asserted?
# have immutable arena to save on indirection?

# Strict arena - no nesting allowed?
# ! to make sure we can't introduce a new arena inside @noarena block, we may use 3 states for it: Nothing | Arena | Noarena
# what semantics do we want from `@arena(@noarena(@arena(f(x))))`?
# what if `arena[]` | `arena_pool` manipulations occur within an arena? We definitely don't want that

mutable struct Arena
    const ptr :: Ptr{Nothing}
    const capacity :: Int
    active :: Bool
    # call_depth :: Int
    # @atomic offset :: Int
    offset :: Int
    task :: Task
    debug :: Bool
end

const arena = Base.ScopedValues.ScopedValue{Union{Nothing, Arena}}(nothing)
const arena_pool  = (; lock=Threads.SpinLock(), pool=Vector{ArenaPirate.Arena}[]) # pool should have try to avoid moving across cores / threads / tasks

function Arena(capacity=2^27)
    if Sys.islinux()
        ptr = @ccall pvalloc(capacity::Csize_t)::Ptr{Cvoid} # depreceated pvalloc
        retcode = @ccall madvise(ptr::Ptr{Cvoid}, capacity::Csize_t, MADV_HUGEPAGE::Cint) :: Cint
        @assert iszero(retcode)           
    else
        ptr = Libc.malloc(capacity)
    end
    finalizer(Arena(ptr, capacity, true, 0, current_task(), false)) do a
        Libc.free(a.ptr)
    end
end

function reset_arena!(arena, tgt_offset=0)
    arena.active = true
    # arena.call_depth = 0
    arena.offset = tgt_offset
    # @atomic arena.offset = tgt_offset
    return arena
end


# have a dict of currently used arenas and pick it up again to allow for @arena -> @noarena -> @arena pattern
macro arena(call)
    quote
        tid = Threads.threadid()
        if isnothing(arena[])
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
            arena2use :: Arena = arena[]
        end
        offset_orig = arena2use.offset
        active_orig = arena2use.active
        try
            # arena2use.call_depth += 1
            arena2use.active = true
            Base.ScopedValues.with(arena => arena2use) do # is deep nesting a problem? hopefully not
                $(esc(call))
            end
        finally
            # @atomic arena2use.offset = offset_orig
            arena2use.offset = offset_orig
            arena2use.active = active_orig 
            # arena2use.call_depth -= 1
            # if iszero(arena2use.call_depth)
            if isnothing(arena[])
                @assert iszero(arena2use.offset)
                reset_arena!(arena2use)
                # can this get arena allocated?! if we were in a nested call...
                Base.ScopedValues.with(arena => nothing) do
                    lock(arena_pool.lock) do  # what if we did @noarena here?
                        push!(arena_pool.pool[tid], arena2use)
                    end
                end
            end
        end
    end
end

macro noarena(call)
    quote
        if isnothing(arena[])
            Base.ScopedValues.with(arena => nothing) do
                $(esc(call))
            end
        else
            arena2use = arena[]
            active_orig = arena2use.active
            arena2use.active = false
            try
                $(esc(call))
            finally
                arena2use.active = active_orig 
            end
        end
    end
end

function copy_from_arena(x)
    @noarena(copy(x))
end

@inline function alloc_arena!(arena :: Arena, ::Type{T}, nels) where T # fails without Arena typed explicitly
    if (current_task() === arena.task) && arena.active
        # since no other task uses this arena we don't worry about concurrency bugs
        elsz = Base.aligned_sizeof(T)
        nbytes = nels * elsz
        offset_cand = arena.offset + nbytes
        offset_cand = (offset_cand + (elsz - 1)) & ~(elsz - 1) # enforce alignment
        mem_avail = arena.capacity - offset_cand
        if mem_avail >= nbytes
            # offset_new = @atomic arena.offset += nbytes
            arena.offset = offset_cand
            ptr_cur = arena.ptr + arena.offset - nbytes
            mem = @ccall jl_ptr_to_genericmemory(Memory{T}::Any, ptr_cur::Ptr{Cvoid}, nbytes::Csize_t, 0::Cint) :: Memory{T}
            return mem
        end
    end
    # fallback to usual memory allocator when arena doesn't have enough memory or when called from a different task
    # is this threadsafe though?
    @ccall jl_alloc_genericmemory(Memory{T}::Any, nels::Csize_t)::Memory{T}
end

function mtmap_arena(f, els)
    fetch.([Threads.@spawn (@arena f(el)) for el in els])
end

function map_arena(f, els)
    map(x -> @arena(f(x)), els)
end

# function clear_arena_pool!(pool_sz=0)
#     resize!(arena_pool.pool, pool_sz)
# end

function activate_arena!(types=(Float64, Int64, UInt8))
    for tid in 1:(Threads.nthreads(:interactive) + Threads.nthreads(:default) - length(arena_pool.pool))
        push!(arena_pool.pool, Arena[])
    end
    @eval begin
        @inline function Memory{T}(::UndefInitializer, m::Int64) where T <: Any
            if isbitstype(T) && !isnothing(arena[]) && (m * sizeof(T) > 2000) #(m >= (2^12 ÷ sizeof($T))) # GC_PERM_POOL_LIMIT, GC_MAX_SZCLASS
                if arena[].debug
                    @show T, m
                end
                alloc_arena!(arena[], T, m)
            else
                @ccall jl_alloc_genericmemory(Memory{T}::Any, m::Csize_t)::Memory{T}
            end
        end
    end
end


# function activate_arena!(types=(Float64, Int64, UInt8))
#     for tid in 1:Threads.nthreads()
#         push!(arena_pool.pool, Arena[])
#     end
#     for T in types
#         @eval begin
#             @inline function Memory{$T}(::UndefInitializer, m::Int64)
#                 if !isnothing(arena[]) && (m * sizeof($T) > 2000) #(m >= (2^12 ÷ sizeof($T))) # GC_PERM_POOL_LIMIT, GC_MAX_SZCLASS
#                     alloc_arena!(arena[], $T, m)
#                 else
#                     @ccall jl_alloc_genericmemory(Memory{$T}::Any, m::Csize_t)::Memory{$T}
#                 end
#             end
#         end
#     end
# end

# @inline function Memory{T}(::UndefInitializer, m::Int64) where T
#     if !isnothing(arena[]) && (m * sizeof($T) > 2000) #(m >= (2^12 ÷ sizeof($T))) # GC_PERM_POOL_LIMIT, GC_MAX_SZCLASS
#         # @show "hi"
#         alloc_arena!(arena[], T, m)
#     else
#         @ccall jl_alloc_genericmemory(Memory{T}::Any, m::Csize_t)::Memory{T}
#     end
# end


end # module ArenaPirate
