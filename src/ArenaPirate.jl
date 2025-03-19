module ArenaPirate
import Mmap: MADV_HUGEPAGE

export activate_arena!, @arena, @noarena, copy_from_arena, mtmap_arena

mutable struct Arena
    const ptr :: Ptr{Nothing}
    const capacity :: Int
    # @atomic offset :: Int
    offset :: Int
    task :: Task
end

# Strict arena - no nesting allowed
const arena = Base.ScopedValues.ScopedValue{Union{Nothing, Arena}}(nothing) # toggle array caching
const arena_pool  = (; lock=Threads.SpinLock(), pool=Arena[])

function Arena(capacity=2^27)
    if Sys.islinux()
        ptr = @ccall pvalloc(capacity::Csize_t)::Ptr{Cvoid} # depreceated pvalloc
        retcode = @ccall madvise(ptr::Ptr{Cvoid}, capacity::Csize_t, MADV_HUGEPAGE::Cint) :: Cint
        @assert iszero(retcode)           
    else
        ptr = Libc.malloc(capacity)
    end
    finalizer(Arena(ptr, capacity, 0, current_task())) do a
        Libc.free(a.ptr)
    end
end

# have a dict of currently used arenas and pick it up again to allow for @arena -> @noarena -> @arena pattern
macro arena(call)
    quote
        if isnothing(arena[])
            arena2use = lock(arena_pool.lock) do
                if isempty(arena_pool.pool)
                    Arena()
                else
                    arena = pop!(arena_pool.pool)
                    arena.task = current_task()
                    arena
                end
            end
            Base.ScopedValues.with(arena => arena2use) do
                res = $(esc(call))
                lock(arena_pool.lock) do 
                    reset_arena!(arena2use)
                    push!(arena_pool.pool, arena2use)
                end
                res
            end
        else
            arena2use :: Arena = arena[]
            offset_orig = arena2use.offset
            res = $(esc(call)) # currently do not optimize nested arena calls
            # @atomic arena2use.offset = offset_orig
            arena2use.offset = offset_orig
            res
        end
    end
end

macro noarena(call)
    quote
        Base.ScopedValues.with(arena => nothing) do
            res = $(esc(call))
        end
    end
end

function copy_from_arena(x)
    @noarena copy(x)
end

@inline function alloc_arena!(arena :: Arena, ::Type{T}, nels) where T # fails without Arena typed explicitly
    if current_task() === arena.task
        # since no other task uses this arena we don't worry about concurrency bugs
        nbytes = nels * sizeof(T)
        mem_avail = arena.capacity - arena.offset
        if mem_avail >= nbytes
            # offset_new = @atomic arena.offset += nbytes
            offset_new = arena.offset += nbytes
            ptr_cur = arena.ptr + offset_new - nbytes
            mem = @ccall jl_ptr_to_genericmemory(Memory{T}::Any, ptr_cur::Ptr{Cvoid}, nbytes::Csize_t, 0::Cint) :: Memory{T}
            return mem
        end
    end
    # fallback to usual memory allocator when arena doesn't have enough memory or when called from a different task
    @ccall jl_alloc_genericmemory(Memory{T}::Any, nels::Csize_t)::Memory{T}
end

function reset_arena!(arena, tgt_offset=0)
    arena.offset = tgt_offset
    # @atomic arena.offset = tgt_offset
    return arena
end

function mtmap_arena(f, els)
    fetch.([Threads.@spawn (@arena f(el)) for el in els])
end

function clear_arena_pool!(pool_sz=0)
    resize!(arena_pool.pool, pool_sz)
end

# function activate_arena!(types=(Float64, Int64,  UInt8))
#     for T in types
#         @eval begin
#             @inline function Memory{$T}(::UndefInitializer, m::Int64)
#                 if !isnothing(arena[]) # && (m * sizeof($T) > 2000) #(m >= (2^12 ÷ sizeof($T))) # GC_PERM_POOL_LIMIT, GC_MAX_SZCLASS
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
#         @show "hi"
#         alloc_arena!(arena[], T, m)
#     else
#         @ccall jl_alloc_genericmemory(Memory{T}::Any, m::Csize_t)::Memory{T}
#     end
# end


end # module ArenaPirate
