#
# Global heap
#

immutable GlobalHeapID
    heap_offset::Offset
    index::UInt32
end
define_packed(GlobalHeapID)

isatend(f::JLDFile, gh::GlobalHeap) =
    gh.offset != UNDEFINED_ADDRESS && f.end_of_data == gh.offset + 8 + sizeof(Length) + gh.length

heap_object_length(data::AbstractArray) = length(data)
heap_object_length(::Any) = 1

function write_heap_object(f::JLDFile, odr, data, wsession::JLDWriteSession)
    psz = sizeof(odr)*heap_object_length(data)
    objsz = 8 + sizeof(Length) + psz
    objsz += 8 - mod1(objsz, 8)

    io = f.io

    # This is basically a memory allocation problem. Right now we do it
    # in a pretty naive way. We:

    # 1. Put the object in the last created global heap if it fits
    # 2. Extend the last global heap if it's at the end of the file
    # 3. Create a new global heap if we can't do 1 or 2

    # This is not a great approach if we're writing objects of
    # different sizes interspersed with new datasets. The torture case
    # would be a Vector{Any} of mutable objects, some of which contain
    # large (>4080 byte) strings and some of which contain small
    # strings. In that case, we'd be better off trying to put the small
    # strings into existing heaps, rather than writing new ones. This
    # should be revisited at a later date.

    if objsz + 8 + sizeof(Length) < f.global_heap.free
        # Fits in existing global heap
        gh = f.global_heap
    elseif isatend(f, f.global_heap)
        # Global heap is at end and can be extended
        gh = f.global_heap
        delta = objsz - gh.free + 8 + sizeof(Length)
        gh.free += delta
        gh.length += delta
        seek(io, gh.offset + 8)
        write(io, gh.length)
        f.end_of_data += delta
    else
        # Need to create a new global heap
        heapsz = max(objsz, 4096)
        offset = f.end_of_data + 8 - mod1(f.end_of_data, 8)
        seek(io, offset)
        write(io, GLOBAL_HEAP_SIGNATURE)
        write(io, UInt32(1))      # Version & Reserved
        write(io, Length(heapsz)) # Collection size
        f.end_of_data = position(io) + heapsz
        gh = f.global_heap = f.global_heaps[offset] = GlobalHeap(offset, heapsz, heapsz, Offset[])
    end

    # Write data
    index = length(gh.objects) + 1
    objoffset = gh.offset + 8 + sizeof(Length) + gh.length - gh.free
    seek(io, objoffset)
    write(io, UInt16(index))           # Heap object index
    write(io, UInt16(1))               # Reference count
    skip(io, 4)                        # Reserved
    write(io, Length(psz))             # Object size

    # Update global heap object
    gh.free -= objsz
    push!(gh.objects, objoffset)

    # Write free space object
    if gh.free >= 8 + sizeof(Length)
        seek(io, objoffset + objsz)
        skip(io, 8)                # Object index, reference count, reserved
        write(io, Length(gh.free - 8 - sizeof(Length))) # Object size
    end

    # Write data
    seek(io, objoffset + 8+sizeof(Length))
    write_data(f, data, odr, wsession) # Object data

    GlobalHeapID(gh.offset, index)
end

# Force specialization on DataType
write_heap_object(f::JLDFile, odr::Type{Union{}}, data, wsession::JLDWriteSession) =
    error("ODR is invalid")

function Base.read(io::IO, ::Type{GlobalHeap})
    offset = position(io)
    read(io, UInt32) == GLOBAL_HEAP_SIGNATURE || throw(InvalidDataException())
    read(io, UInt32) == 1 || throw(UnsupportedVersionException())
    heapsz = read(io, Length)
    index = 1
    objects = Offset[]
    startpos = position(io)
    free = heapsz
    while free > 8 + sizeof(Length)
        push!(objects, position(io))
        objidx = read(io, UInt16)
        objidx == 0 && break
        objidx == index || throw(UnsupportedFeatureException())
        skip(io, 6)                    # Reference count and reserved
        sz = read(io, Length)          # Length
        skip(io, sz + 8 - mod1(sz, 8)) # Payload
        free = heapsz - Length(position(io) - startpos)
        index += 1
    end
    GlobalHeap(offset, heapsz, free, objects)
end

# TODO make this take an ODR
function read_heap_object{T,RR}(f::JLDFile{MmapIO}, hid::GlobalHeapID, rr::ReadRepresentation{T,RR})
    io = f.io
    if haskey(f.global_heaps, hid.heap_offset)
        gh = f.global_heaps[hid.heap_offset]
    else
        seek(io, hid.heap_offset)
        f.global_heaps[hid.heap_offset] = gh = read(io, GlobalHeap)
    end
    seek(io, gh.objects[hid.index]+8)
    len = Int(read(io, Length))
    n = div(len, sizeof(RR))
    len == n * sizeof(RR) || throw(InvalidDataException())

    inptr = f.io.curptr
    v = Array(T, n)
    if isa(RR, DataType) && RR <: T && isbits(T)
        unsafe_copy!(pointer(v), convert(Ptr{T}, inptr), Int(n))
    else
        @simd for i = 1:n
            if jlconvert_isinitialized(rr, inptr)
                @inbounds v[i] = jlconvert(rr, f, inptr)
            end
            inptr += sizeof(RR)
        end
    end
    v
end