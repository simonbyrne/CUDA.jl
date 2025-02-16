export CuArray, CuVector, CuMatrix, CuVecOrMat, cu


## array storage

# array storage is shared by arrays that refer to the same data, while keeping track of
# the number of outstanding references

struct ArrayStorage
  buffer::Mem.DeviceBuffer

  ctx::CuContext

  # the refcount also encodes the state of the array:
  # < 0: unmanaged
  # = 0: freed
  # > 0: referenced
  refcount::Threads.Atomic{Int}
end

ArrayStorage(buf::Mem.DeviceBuffer, ctx::CuContext, state::Int) =
  ArrayStorage(buf, ctx, Threads.Atomic{Int}(state))


## array type

mutable struct CuArray{T,N} <: AbstractGPUArray{T,N}
  storage::Union{Nothing,ArrayStorage}

  maxsize::Int  # maximum data size; excluding any selector bytes
  offset::Int

  dims::Dims{N}

  function CuArray{T,N}(::UndefInitializer, dims::Dims{N}) where {T,N}
    Base.allocatedinline(T) || error("CuArray only supports element types that are stored inline")
    maxsize = prod(dims) * sizeof(T)
    bufsize = if Base.isbitsunion(T)
      # type tag array past the data
      maxsize + prod(dims)
    else
      maxsize
    end
    storage = ArrayStorage(alloc(bufsize), context(), 1)
    obj = new{T,N}(storage, maxsize, 0, dims)
    finalizer(unsafe_finalize!, obj)
  end

  function CuArray{T,N}(storage::ArrayStorage, dims::Dims{N};
                        maxsize::Int=prod(dims) * sizeof(T), offset::Int=0) where {T,N}
    Base.allocatedinline(T) || error("CuArray only supports element types that are stored inline")
    return new{T,N}(storage, maxsize, offset, dims,)
  end
end

"""
    CUDA.unsafe_free!(a::CuArray, [stream::CuStream])

Release the memory of an array for reuse by future allocations. This function is
automatically called by the finalizer when an array goes out of scope, but can be called
earlier to reduce pressure on the memory allocator.

By default, the operation is performed on the task-local stream. During task or process
finalization however, that stream may be destroyed already, so be sure to specify a safe
stream (i.e. `CuDefaultStream()`, which will ensure the operation will block on other
streams) when calling this function from a finalizer. For simplicity, the `unsafe_finalize!`
function does exactly that.
"""
function unsafe_free!(xs::CuArray, stream::CuStream=stream())
  # this call should only have an effect once, because both the user and the GC can call it
  if xs.storage === nothing
    return
  elseif xs.storage.refcount[] < 0
    throw(ArgumentError("Cannot free an unmanaged buffer."))
  end

  refcount = Threads.atomic_add!(xs.storage.refcount, -1)
  if refcount == 1
    @context! skip_destroyed=true xs.storage.ctx begin
      free(xs.storage.buffer; stream)
    end
  end

  # this array object is now dead, so replace its storage by a dummy one
  xs.storage = nothing

  return
end

function unsafe_finalize!(xs::CuArray)
  # during task or process finalization, the local stream might be destroyed already, so
  # use the default stream. additionally, since we don't use per-thread APIs, this default
  # stream follows legacy semantics and will synchronize all other streams. this protects
  # against freeing resources that are still in use.
  #
  # TODO: although this is still an asynchronous operation, even when using the default
  # stream, it synchronizes "too much". we could do better, e.g., by keeping track of all
  # streams involved, or by refcounting uses and decrementing that refcount after the
  # operation using `cuLaunchHostFunc`. See CUDA.jl#778 and CUDA.jl#780 for details.
  unsafe_free!(xs, CuDefaultStream())
end


## alias detection

Base.dataids(A::CuArray) = (UInt(pointer(A.storage.buffer)),)

Base.unaliascopy(A::CuArray) = copy(A)

function Base.mightalias(A::CuArray, B::CuArray)
  rA = pointer(A):pointer(A)+sizeof(A)
  rB = pointer(B):pointer(B)+sizeof(B)
  return first(rA) <= first(rB) < last(rA) || first(rB) <= first(rA) < last(rB)
end


## convenience constructors

CuVector{T} = CuArray{T,1}
CuMatrix{T} = CuArray{T,2}
CuVecOrMat{T} = Union{CuVector{T},CuMatrix{T}}

# type and dimensionality specified, accepting dims as series of Ints
CuArray{T,N}(::UndefInitializer, dims::Integer...) where {T,N} = CuArray{T,N}(undef, dims)

# type but not dimensionality specified
CuArray{T}(::UndefInitializer, dims::Dims{N}) where {T,N} = CuArray{T,N}(undef, dims)
CuArray{T}(::UndefInitializer, dims::Integer...) where {T} =
  CuArray{T}(undef, convert(Tuple{Vararg{Int}}, dims))

# empty vector constructor
CuArray{T,1}() where {T} = CuArray{T,1}(undef, 0)

# do-block constructors
for (ctor, tvars) in (:CuArray => (), :(CuArray{T}) => (:T,), :(CuArray{T,N}) => (:T, :N))
  @eval begin
    function $ctor(f::Function, args...) where {$(tvars...)}
      xs = $ctor(args...)
      try
        f(xs)
      finally
        unsafe_free!(xs)
      end
    end
  end
end

Base.similar(a::CuArray{T,N}) where {T,N} = CuArray{T,N}(undef, size(a))
Base.similar(a::CuArray{T}, dims::Base.Dims{N}) where {T,N} = CuArray{T,N}(undef, dims)
Base.similar(a::CuArray, ::Type{T}, dims::Base.Dims{N}) where {T,N} = CuArray{T,N}(undef, dims)

function Base.copy(a::CuArray{T,N}) where {T,N}
  b = similar(a)
  @inbounds copyto!(b, a)
end


"""
  unsafe_wrap(::CuArray, ptr::CuPtr{T}, dims; own=false, ctx=context())

Wrap a `CuArray` object around the data at the address given by `ptr`. The pointer
element type `T` determines the array element type. `dims` is either an integer (for a 1d
array) or a tuple of the array dimensions. `own` optionally specified whether Julia should
take ownership of the memory, calling `cudaFree` when the array is no longer referenced. The
`ctx` argument determines the CUDA context where the data is allocated in.
"""
function Base.unsafe_wrap(::Union{Type{CuArray},Type{CuArray{T}},Type{CuArray{T,N}}},
                          ptr::CuPtr{T}, dims::NTuple{N,Int};
                          own::Bool=false, ctx::CuContext=context()) where {T,N}
  Base.isbitstype(T) || error("Can only unsafe_wrap a pointer to a bits type")
  sz = prod(dims) * sizeof(T)

  # identify the buffer
  buf = try
    typ = memory_type(ptr)
    if is_managed(ptr)
      Mem.UnifiedBuffer(ptr, sz)
    elseif typ == CU_MEMORYTYPE_DEVICE
      Mem.DeviceBuffer(ptr, sz)
    elseif typ == CU_MEMORYTYPE_HOST
      error("Cannot unsafe_wrap a host pointer with a CuArray")
    else
      error("Unknown memory type; please file an issue.")
    end
  catch err
      error("Could not identify the buffer type; are you passing a valid CUDA pointer to unsafe_wrap?")
  end

  storage = ArrayStorage(buf, ctx, -1)
  # TODO: make this array normally managed too (deal in pool.jl with different buffer types)
  xs = CuArray{T, length(dims)}(storage, dims)
  if own
    finalizer(xs) do obj
      @context! skip_destroyed=true ctx begin
        if buf isa Mem.DeviceBuffer
          # see comments in unsafe_free! for notes on the use of CuDefaultStream
          Mem.free(buf; stream=CuDefaultStream())
        else
          Mem.free(buf)
        end
      end
    end
  end
  return xs
end

function Base.unsafe_wrap(Atype::Union{Type{CuArray},Type{CuArray{T}},Type{CuArray{T,1}}},
                          p::CuPtr{T}, dim::Integer;
                          own::Bool=false, ctx::CuContext=context()) where {T}
  unsafe_wrap(Atype, p, (dim,); own, ctx)
end

Base.unsafe_wrap(T::Type{<:CuArray}, ::Ptr, dims::NTuple{N,Int}; kwargs...) where {N} =
  throw(ArgumentError("cannot wrap a CPU pointer with a $T"))


## array interface

Base.elsize(::Type{<:CuArray{T}}) where {T} = sizeof(T)

Base.size(x::CuArray) = x.dims
Base.sizeof(x::CuArray) = Base.elsize(x) * length(x)


## derived types

export DenseCuArray, DenseCuVector, DenseCuMatrix, DenseCuVecOrMat,
       StridedCuArray, StridedCuVector, StridedCuMatrix, StridedCuVecOrMat,
       AnyCuArray, AnyCuVector, AnyCuMatrix, AnyCuVecOrMat

# dense arrays: stored contiguously in memory
#
# all common dense wrappers are currently represented as CuArray objects.
# this simplifies common use cases, and greatly improves load time.
# CUDA.jl 2.0 experimented with using ReshapedArray/ReinterpretArray/SubArray,
# but that proved much too costly. TODO: revisit when we have better Base support.
DenseCuArray{T,N} = CuArray{T,N}
DenseCuVector{T} = DenseCuArray{T,1}
DenseCuMatrix{T} = DenseCuArray{T,2}
DenseCuVecOrMat{T} = Union{DenseCuVector{T}, DenseCuMatrix{T}}

# strided arrays
StridedSubCuArray{T,N,I<:Tuple{Vararg{Union{Base.RangeIndex, Base.ReshapedUnitRange,
                                            Base.AbstractCartesianIndex}}}} =
  SubArray{T,N,<:CuArray,I}
StridedCuArray{T,N} = Union{CuArray{T,N}, StridedSubCuArray{T,N}}
StridedCuVector{T} = StridedCuArray{T,1}
StridedCuMatrix{T} = StridedCuArray{T,2}
StridedCuVecOrMat{T} = Union{StridedCuVector{T}, StridedCuMatrix{T}}

Base.pointer(x::StridedCuArray{T}) where {T} = Base.unsafe_convert(CuPtr{T}, x)
@inline function Base.pointer(x::StridedCuArray{T}, i::Integer) where T
    Base.unsafe_convert(CuPtr{T}, x) + Base._memory_offset(x, i)
end

# anything that's (secretly) backed by a CuArray
AnyCuArray{T,N} = Union{CuArray{T,N}, WrappedArray{T,N,CuArray,CuArray{T,N}}}
AnyCuVector{T} = AnyCuArray{T,1}
AnyCuMatrix{T} = AnyCuArray{T,2}
AnyCuVecOrMat{T} = Union{AnyCuVector{T}, AnyCuMatrix{T}}


## interop with other arrays

@inline function CuArray{T,N}(xs::AbstractArray{<:Any,N}) where {T,N}
  A = CuArray{T,N}(undef, size(xs))
  copyto!(A, convert(Array{T}, xs))
  return A
end

# underspecified constructors
CuArray{T}(xs::AbstractArray{S,N}) where {T,N,S} = CuArray{T,N}(xs)
(::Type{CuArray{T,N} where T})(x::AbstractArray{S,N}) where {S,N} = CuArray{S,N}(x)
CuArray(A::AbstractArray{T,N}) where {T,N} = CuArray{T,N}(A)

# idempotency
CuArray{T,N}(xs::CuArray{T,N}) where {T,N} = xs


## conversions

Base.convert(::Type{T}, x::T) where T <: CuArray = x


## interop with C libraries

Base.unsafe_convert(::Type{Ptr{T}}, x::CuArray{T}) where {T} =
  throw(ArgumentError("cannot take the CPU address of a $(typeof(x))"))
Base.unsafe_convert(::Type{CuPtr{T}}, x::CuArray{T}) where {T} =
  convert(CuPtr{T}, pointer(x.storage.buffer)) + x.offset


## interop with device arrays

function Base.unsafe_convert(::Type{CuDeviceArray{T,N,AS.Global}}, a::DenseCuArray{T,N}) where {T,N}
  CuDeviceArray{T,N,AS.Global}(size(a), reinterpret(LLVMPtr{T,AS.Global}, pointer(a)),
                               a.maxsize - a.offset)
end


## interop with CPU arrays

typetagdata(a::Array, i=1) = ccall(:jl_array_typetagdata, Ptr{UInt8}, (Any,), a) + i - 1
typetagdata(a::CuArray, i=1) =
  convert(CuPtr{UInt8}, pointer(a.storage.buffer) + a.maxsize) + a.offset÷Base.elsize(a) + i - 1

# We don't convert isbits types in `adapt`, since they are already
# considered GPU-compatible.

Adapt.adapt_storage(::Type{CuArray}, xs::AT) where {AT<:AbstractArray} =
  isbitstype(AT) ? xs : convert(CuArray, xs)

# if an element type is specified, convert to it
Adapt.adapt_storage(::Type{<:CuArray{T}}, xs::AT) where {T, AT<:AbstractArray} =
  isbitstype(AT) ? xs : convert(CuArray{T}, xs)

Base.collect(x::CuArray{T,N}) where {T,N} = copyto!(Array{T,N}(undef, size(x)), x)

function Base.copyto!(dest::DenseCuArray{T}, doffs::Integer, src::Array{T}, soffs::Integer,
                      n::Integer) where T
  n==0 && return dest
  @boundscheck checkbounds(dest, doffs)
  @boundscheck checkbounds(dest, doffs+n-1)
  @boundscheck checkbounds(src, soffs)
  @boundscheck checkbounds(src, soffs+n-1)
  unsafe_copyto!(dest, doffs, src, soffs, n)
  return dest
end

Base.copyto!(dest::DenseCuArray{T}, src::Array{T}) where {T} =
    copyto!(dest, 1, src, 1, length(src))

function Base.copyto!(dest::Array{T}, doffs::Integer, src::DenseCuArray{T}, soffs::Integer,
                      n::Integer) where T
  n==0 && return dest
  @boundscheck checkbounds(dest, doffs)
  @boundscheck checkbounds(dest, doffs+n-1)
  @boundscheck checkbounds(src, soffs)
  @boundscheck checkbounds(src, soffs+n-1)
  unsafe_copyto!(dest, doffs, src, soffs, n)
  return dest
end

Base.copyto!(dest::Array{T}, src::DenseCuArray{T}) where {T} =
    copyto!(dest, 1, src, 1, length(src))

function Base.copyto!(dest::DenseCuArray{T}, doffs::Integer, src::DenseCuArray{T}, soffs::Integer,
                      n::Integer) where T
  n==0 && return dest
  @boundscheck checkbounds(dest, doffs)
  @boundscheck checkbounds(dest, doffs+n-1)
  @boundscheck checkbounds(src, soffs)
  @boundscheck checkbounds(src, soffs+n-1)
  unsafe_copyto!(dest, doffs, src, soffs, n)
  return dest
end

Base.copyto!(dest::DenseCuArray{T}, src::DenseCuArray{T}) where {T} =
    copyto!(dest, 1, src, 1, length(src))

function Base.unsafe_copyto!(dest::DenseCuArray{T}, doffs, src::Array{T}, soffs, n) where T
  if !is_pinned(pointer(src))
    # operations on unpinned memory cannot be executed asynchronously, and synchronize
    # without yielding back to the Julia scheduler. prevent that by eagerly synchronizing.
    synchronize()
  end
  GC.@preserve src dest begin
    unsafe_copyto!(pointer(dest, doffs), pointer(src, soffs), n; async=true)
    if Base.isbitsunion(T)
      unsafe_copyto!(typetagdata(dest, doffs), typetagdata(src, soffs), n; async=true)
    end
  end
  return dest
end

function Base.unsafe_copyto!(dest::Array{T}, doffs, src::DenseCuArray{T}, soffs, n) where T
  if !is_pinned(pointer(dest))
    # operations on unpinned memory cannot be executed asynchronously, and synchronize
    # without yielding back to the Julia scheduler. prevent that by eagerly synchronizing.
    synchronize()
  end
  GC.@preserve src dest begin
    unsafe_copyto!(pointer(dest, doffs), pointer(src, soffs), n; async=true)
    if Base.isbitsunion(T)
      unsafe_copyto!(typetagdata(dest, doffs), typetagdata(src, soffs), n; async=true)
    end
  end
  synchronize() # users expect values to be available after this call
  return dest
end

function Base.unsafe_copyto!(dest::DenseCuArray{T}, doffs, src::DenseCuArray{T}, soffs, n) where T
  GC.@preserve src dest begin
    unsafe_copyto!(pointer(dest, doffs), pointer(src, soffs), n; async=true)
    if Base.isbitsunion(T)
      unsafe_copyto!(typetagdata(dest, doffs), typetagdata(src, soffs), n; async=true)
    end
  end
  return dest
end

function Base.deepcopy_internal(x::CuArray, dict::IdDict)
  haskey(dict, x) && return dict[x]::typeof(x)
  return dict[x] = copy(x)
end


## Float32-preferring conversion

struct Float32Adaptor end

Adapt.adapt_storage(::Float32Adaptor, xs::AbstractArray) =
  isbits(xs) ? xs : convert(CuArray, xs)

Adapt.adapt_storage(::Float32Adaptor, xs::AbstractArray{<:AbstractFloat}) =
  isbits(xs) ? xs : convert(CuArray{Float32}, xs)

Adapt.adapt_storage(::Float32Adaptor, xs::AbstractArray{<:Complex{<:AbstractFloat}}) =
  isbits(xs) ? xs : convert(CuArray{ComplexF32}, xs)

# not for Float16
Adapt.adapt_storage(::Float32Adaptor, xs::AbstractArray{Float16}) =
  isbits(xs) ? xs : convert(CuArray, xs)
Adapt.adapt_storage(::Float32Adaptor, xs::AbstractArray{BFloat16}) =
  isbits(xs) ? xs : convert(CuArray, xs)

cu(xs) = adapt(Float32Adaptor(), xs)
Base.getindex(::typeof(cu), xs...) = CuArray([xs...])


## utilities

zeros(T::Type, dims...) = fill!(CuArray{T}(undef, dims...), 0)
ones(T::Type, dims...) = fill!(CuArray{T}(undef, dims...), 1)
zeros(dims...) = zeros(Float32, dims...)
ones(dims...) = ones(Float32, dims...)
fill(v, dims...) = fill!(CuArray{typeof(v)}(undef, dims...), v)
fill(v, dims::Dims) = fill!(CuArray{typeof(v)}(undef, dims...), v)

# optimized implementation of `fill!` for types that are directly supported by memset
memsettype(T::Type) = T
memsettype(T::Type{<:Signed}) = unsigned(T)
memsettype(T::Type{<:AbstractFloat}) = Base.uinttype(T)
const MemsetCompatTypes = Union{UInt8, Int8,
                                UInt16, Int16, Float16,
                                UInt32, Int32, Float32}
function Base.fill!(A::DenseCuArray{T}, x) where T <: MemsetCompatTypes
  U = memsettype(T)
  y = reinterpret(U, convert(T, x))
  Mem.set!(convert(CuPtr{U}, pointer(A)), y, length(A); async=true)
  A
end


## views

# optimize view to return a CuArray when contiguous

struct Contiguous end
struct NonContiguous end

# NOTE: this covers more cases than the I<:... in Base.FastContiguousSubArray
CuIndexStyle() = Contiguous()
CuIndexStyle(I...) = NonContiguous()
CuIndexStyle(::Union{Base.ScalarIndex, CartesianIndex}...) = Contiguous()
CuIndexStyle(i1::Colon, ::Union{Base.ScalarIndex, CartesianIndex}...) = Contiguous()
CuIndexStyle(i1::AbstractUnitRange, ::Union{Base.ScalarIndex, CartesianIndex}...) = Contiguous()
CuIndexStyle(i1::Colon, I...) = CuIndexStyle(I...)

cuviewlength() = ()
@inline cuviewlength(::Real, I...) = cuviewlength(I...) # skip scalar
@inline cuviewlength(i1::AbstractUnitRange, I...) = (Base.unsafe_length(i1), cuviewlength(I...)...)
@inline cuviewlength(i1::AbstractUnitRange, ::Base.ScalarIndex...) = (Base.unsafe_length(i1),)

# we don't really want an array, so don't call `adapt(Array, ...)`,
# but just want CuArray indices to get downloaded back to the CPU.
# this makes sure we preserve array-like containers, like Base.Slice.
struct BackToCPU end
Adapt.adapt_storage(::BackToCPU, xs::CuArray) = convert(Array, xs)

@inline function Base.view(A::CuArray, I::Vararg{Any,N}) where {N}
    J = to_indices(A, I)
    @boundscheck begin
        # Base's boundscheck accesses the indices, so make sure they reside on the CPU.
        # this is expensive, but it's a bounds check after all.
        J_cpu = map(j->adapt(BackToCPU(), j), J)
        checkbounds(A, J_cpu...)
    end
    J_gpu = map(j->adapt(CuArray, j), J)
    unsafe_view(A, J_gpu, CuIndexStyle(I...))
end

@inline function unsafe_view(A, I, ::Contiguous)
    unsafe_contiguous_view(Base._maybe_reshape_parent(A, Base.index_ndims(I...)), I, cuviewlength(I...))
end
@inline function unsafe_contiguous_view(a::CuArray{T}, I::NTuple{N,Base.ViewIndex}, dims::NTuple{M,Integer}) where {T,N,M}
    offset = Base.compute_offset1(a, 1, I) * sizeof(T)

    refcount = a.storage.refcount[]
    @assert refcount != 0
    if refcount > 0
      Threads.atomic_add!(a.storage.refcount, 1)
    end

    b = CuArray{T,M}(a.storage, dims; a.maxsize, offset=a.offset+offset)
    if refcount > 0
        finalizer(unsafe_finalize!, b)
    end
    return b
end

@inline function unsafe_view(A, I, ::NonContiguous)
    Base.unsafe_view(Base._maybe_reshape_parent(A, Base.index_ndims(I...)), I...)
end

# pointer conversions
## contiguous
function Base.unsafe_convert(::Type{CuPtr{T}}, V::SubArray{T,N,P,<:Tuple{Vararg{Base.RangeIndex}}}) where {T,N,P}
    return Base.unsafe_convert(CuPtr{T}, parent(V)) +
           Base._memory_offset(V.parent, map(first, V.indices)...)
end
## reshaped
function Base.unsafe_convert(::Type{CuPtr{T}}, V::SubArray{T,N,P,<:Tuple{Vararg{Union{Base.RangeIndex,Base.ReshapedUnitRange}}}}) where {T,N,P}
   return Base.unsafe_convert(CuPtr{T}, parent(V)) +
          (Base.first_index(V)-1)*sizeof(T)
end


## PermutedDimsArray

Base.unsafe_convert(::Type{CuPtr{T}}, A::PermutedDimsArray) where {T} =
    Base.unsafe_convert(CuPtr{T}, parent(A))


## reshape

# optimize reshape to return a CuArray

function Base.reshape(a::CuArray{T,M}, dims::NTuple{N,Int}) where {T,N,M}
  if prod(dims) != length(a)
      throw(DimensionMismatch("new dimensions $(dims) must be consistent with array size $(size(a))"))
  end

  if N == M && dims == size(a)
      return a
  end

  refcount = a.storage.refcount[]
  @assert refcount != 0
  if refcount > 0
    Threads.atomic_add!(a.storage.refcount, 1)
  end

  b = CuArray{T,N}(a.storage, dims; a.maxsize, a.offset)
  if refcount > 0
      finalizer(unsafe_finalize!, b)
  end
  return b
end


## reinterpret

# optimize reshape to return a CuArray

struct _CuReinterpretBitsTypeError{T,A} <: Exception end
function Base.showerror(io::IO, ::_CuReinterpretBitsTypeError{T, <:AbstractArray{S}}) where {T, S}
  print(io, "cannot reinterpret an `$(S)` array to `$(T)`, because not all types are bitstypes")
end

struct _CuReinterpretZeroDimError{T,A} <: Exception end
function Base.showerror(io::IO, ::_CuReinterpretZeroDimError{T, <:AbstractArray{S,N}}) where {T, S, N}
  print(io, "cannot reinterpret a zero-dimensional `$(S)` array to `$(T)` which is of a different size")
end

struct _CuReinterpretDivisibilityError{T,A} <: Exception
  dim::Int
end
function Base.showerror(io::IO, err::_CuReinterpretDivisibilityError{T, <:AbstractArray{S,N}}) where {T, S, N}
  dim = err.dim
  print(io, """
      cannot reinterpret an `$(S)` array to `$(T)` whose first dimension has size `$(dim)`.
      The resulting array would have non-integral first dimension.
      """)
end

struct _CuReinterpretFirstIndexError{T,A,Ax1} <: Exception
  ax1::Ax1
end
function Base.showerror(io::IO, err::_CuReinterpretFirstIndexError{T, <:AbstractArray{S,N}}) where {T, S, N}
  ax1 = err.ax1
  print(io, "cannot reinterpret a `$(S)` array to `$(T)` when the first axis is $ax1. Try reshaping first.")
end

function _reinterpret_exception(::Type{T}, a::AbstractArray{S,N}) where {T,S,N}
  if !isbitstype(T) || !isbitstype(S)
    return _CuReinterpretBitsTypeError{T,typeof(a)}()
  end
  if N == 0 && sizeof(T) != sizeof(S)
    return _CuReinterpretZeroDimError{T,typeof(a)}()
  end
  if N != 0 && sizeof(S) != sizeof(T)
      ax1 = axes(a)[1]
      dim = length(ax1)
      if Base.rem(dim*sizeof(S),sizeof(T)) != 0
        return _CuReinterpretDivisibilityError{T,typeof(a)}(dim)
      end
      if first(ax1) != 1
        return _CuReinterpretFirstIndexError{T,typeof(a),typeof(ax1)}(ax1)
      end
  end
  return nothing
end

function Base.reinterpret(::Type{T}, a::CuArray{S,N}) where {T,S,N}
  err = _reinterpret_exception(T, a)
  err === nothing || throw(err)

  if sizeof(T) == sizeof(S) # for N == 0
    osize = size(a)
  else
    isize = size(a)
    size1 = div(isize[1]*sizeof(S), sizeof(T))
    osize = tuple(size1, Base.tail(isize)...)
  end

  refcount = a.storage.refcount[]
  @assert refcount != 0
  if refcount > 0
    Threads.atomic_add!(a.storage.refcount, 1)
  end

  b = CuArray{T,N}(a.storage, osize; a.maxsize, a.offset)
  if refcount > 0
      finalizer(unsafe_finalize!, b)
  end
  return b
end


## resizing

"""
  resize!(a::CuVector, n::Int)

Resize `a` to contain `n` elements. If `n` is smaller than the current collection length,
the first `n` elements will be retained. If `n` is larger, the new elements are not
guaranteed to be initialized.

Note that this operation is only supported on managed buffers, i.e., not on arrays that are
created by `unsafe_wrap` with `own=false`.
"""
function Base.resize!(A::CuVector{T}, n::Int) where T
  # TODO: add additional space to allow for quicker resizing
  maxsize = n * sizeof(T)
  bufsize = if Base.isbitsunion(T)
    # type tag array past the data
    maxsize + n
  else
    maxsize
  end

  new_storage = @context! A.storage.ctx begin
    buf = alloc(bufsize)
    ptr = convert(CuPtr{T}, buf)
    m = Base.min(length(A), n)
    unsafe_copyto!(ptr, pointer(A), m)
    ArrayStorage(buf, A.storage.ctx, 1)
  end

  unsafe_free!(A)
  A.storage = new_storage
  A.dims = (n,)
  A.maxsize = maxsize
  A.offset = 0

  A
end
