# io.jl

const CHUNK_FILEHEADER = 1
const CHUNK_STREAMHEADER = 2
const CHUNK_SAMPLES = 3
const CHUNK_CLOCKOFFSET = 4
const CHUNK_BOUNDARY = 5
const CHUNK_STREAMFOOTER = 6

const DATA_TYPE = Dict(
    "int8" => Int8,
    "int16" => Int16,
    "int32" => Int32,
    "int64" => Int64,
    "float32" => Float32,
    "double64" => Float64,
    "string" => String
)

const BOUNDARY_SIGNATURE = UInt8[
    0x43, 0xA5, 0x46, 0xDC, 0xCB, 0xF5, 0x41, 0x0F,
    0xB3, 0x0E, 0xD5, 0x46, 0x73, 0x83, 0xCB, 0xE4
]

"""
    read_xdf(filename::String; kwargs...) -> XdfData

Read an Extensible Data Format (.xdf) file.

## Keyword Arguments
- `select_streams::Vector{Int}`: Only load specific stream IDs.
- `sync::Bool=true`: Enable clock synchronization.
- `dejitter_timestamps::Bool=true`: Remove jitter from regularly sampled streams.
- `handle_clock_resets::Bool=true`: Detect and fix computer clock resets.
"""
function read_xdf(filename::String; 
    select_streams::Union{Nothing, Vector{Int}}=nothing,
    sync::Bool=true,
    dejitter_timestamps::Bool=true,
    handle_clock_resets::Bool=true)

    is_gzip = endswith(filename, ".xdfz") || endswith(filename, ".gz")
    
    function open_file()
        f = open(filename, "r")
        if is_gzip
            return GzipDecompressorStream(f)
        end
        return f
    end

    streams_meta = Dict{Int, Any}()
    file_xml_header = ""

    # --- First Pass ---
    io = open_file()
    try
        magic = String(read(io, 4))
        if magic != "XDF:"
            error("Invalid magic bytes sequence: not a valid XDF file")
        end

        while !eof(io)
            local len::Int
            try
                len = _read_varlen_int(io)
            catch e
                if e isa EOFError
                    break
                else
                    _scan_forward(io)
                    continue
                end
            end
            
            tag = read(io, UInt16)
            len -= sizeof(UInt16)

            id = 0
            if tag in (CHUNK_STREAMHEADER, CHUNK_SAMPLES, CHUNK_CLOCKOFFSET, CHUNK_STREAMFOOTER)
                try
                    id = Int(read(io, UInt32))
                catch
                    _scan_forward(io)
                    continue
                end
                len -= sizeof(UInt32)
                
                if select_streams !== nothing && !(id in select_streams)
                    skip(io, len)
                    continue
                end
            end

            if tag == CHUNK_FILEHEADER
                file_xml_header = String(read(io, len))
            elseif tag == CHUNK_STREAMHEADER
                xml = String(read(io, len))
                streams_meta[id] = Dict{String, Any}(
                    "name" => _findtag(xml, "name", String),
                    "type" => _findtag(xml, "type", String),
                    "nchannels" => _findtag(xml, "channel_count", Int),
                    "srate" => _findtag(xml, "nominal_srate", Float64),
                    "dtype" => DATA_TYPE[_findtag(xml, "channel_format", String)],
                    "data_count" => 0,
                    "clock" => Float64[],
                    "offset" => Float64[],
                    "xml_header" => xml,
                    "xml_footer" => "",
                    "effective_srate" => 0.0
                )
            elseif tag == CHUNK_SAMPLES
                # We can't `mark`/`reset` reliably on GzipDecompressorStream, 
                # so we just read nsamples and skip the rest
                if !haskey(streams_meta, id)
                    skip(io, len)
                    continue
                end
                
                # To skip properly without mark/reset, we read nsamples, then skip remaining
                # read_varlen_int consumes some bytes. We can track it or just use a peek hack.
                # Actually, reading the varlen_int bytes:
                pos_before = 0
                nbytes = read(io, Int8)
                if nbytes == 1
                    nsamples = Int(read(io, UInt8))
                    pos_before = 2
                elseif nbytes == 4
                    nsamples = Int(read(io, UInt32))
                    pos_before = 5
                elseif nbytes == 8
                    nsamples = Int(read(io, UInt64))
                    pos_before = 9
                else
                    _scan_forward(io)
                    continue
                end
                
                streams_meta[id]["data_count"] += nsamples
                skip(io, len - pos_before)
            elseif tag == CHUNK_CLOCKOFFSET
                if haskey(streams_meta, id)
                    push!(streams_meta[id]["clock"], read(io, Float64))
                    push!(streams_meta[id]["offset"], read(io, Float64))
                else
                    skip(io, len)
                end
            elseif tag == CHUNK_STREAMFOOTER
                if haskey(streams_meta, id)
                    streams_meta[id]["xml_footer"] = String(read(io, len))
                else
                    skip(io, len)
                end
            else
                skip(io, len)
            end
        end
    finally
        close(io)
    end

    # Pre-allocate arrays
    index = Dict{Int, Int}()
    for (id, meta) in streams_meta
        dtype = meta["dtype"]
        nsamples = meta["data_count"]
        nchannels = meta["nchannels"]
        meta["time_series"] = Array{dtype}(undef, nsamples, nchannels)
        meta["timestamps"] = Array{Float64}(undef, nsamples)
        index[id] = 1
    end

    # --- Second Pass ---
    io = open_file()
    try
        read(io, 4) # Skip magic bytes
        while !eof(io)
            local len::Int
            try
                len = _read_varlen_int(io)
            catch e
                if e isa EOFError
                    break
                else
                    _scan_forward(io)
                    continue
                end
            end
            
            tag = read(io, UInt16)
            len -= sizeof(UInt16)

            if tag != CHUNK_SAMPLES
                skip(io, len)
            else
                id = 0
                try
                    id = Int(read(io, UInt32))
                catch
                    _scan_forward(io)
                    continue
                end
                len -= sizeof(UInt32)
                
                if !haskey(streams_meta, id)
                    skip(io, len)
                    continue
                end
                
                nsamples = _read_varlen_int(io)
                meta = streams_meta[id]
                nchannels = meta["nchannels"]::Int
                srate = meta["srate"]::Float64
                
                if meta["dtype"] === String
                    index[id] = _read_chunk_string!(
                        io, nsamples, nchannels, srate, 
                        meta["timestamps"]::Vector{Float64}, 
                        meta["time_series"]::Matrix{String}, 
                        index[id]
                    )
                elseif meta["dtype"] === Float64
                    index[id] = _read_chunk_numeric!(io, nsamples, nchannels, srate, meta["timestamps"]::Vector{Float64}, meta["time_series"]::Matrix{Float64}, index[id])
                elseif meta["dtype"] === Float32
                    index[id] = _read_chunk_numeric!(io, nsamples, nchannels, srate, meta["timestamps"]::Vector{Float64}, meta["time_series"]::Matrix{Float32}, index[id])
                elseif meta["dtype"] === Int32
                    index[id] = _read_chunk_numeric!(io, nsamples, nchannels, srate, meta["timestamps"]::Vector{Float64}, meta["time_series"]::Matrix{Int32}, index[id])
                elseif meta["dtype"] === Int16
                    index[id] = _read_chunk_numeric!(io, nsamples, nchannels, srate, meta["timestamps"]::Vector{Float64}, meta["time_series"]::Matrix{Int16}, index[id])
                elseif meta["dtype"] === Int8
                    index[id] = _read_chunk_numeric!(io, nsamples, nchannels, srate, meta["timestamps"]::Vector{Float64}, meta["time_series"]::Matrix{Int8}, index[id])
                elseif meta["dtype"] === Int64
                    index[id] = _read_chunk_numeric!(io, nsamples, nchannels, srate, meta["timestamps"]::Vector{Float64}, meta["time_series"]::Matrix{Int64}, index[id])
                else
                    error("Unsupported dtype")
                end
            end
        end
    finally
        close(io)
    end

    if sync
        _clock_sync!(streams_meta; handle_clock_resets=handle_clock_resets)
    end
    
    if dejitter_timestamps
        _jitter_removal!(streams_meta)
    else
        for (_, meta) in streams_meta
            ts = meta["timestamps"]::Vector{Float64}
            if length(ts) > 1
                duration = ts[end] - ts[1]
                meta["effective_srate"] = duration > 0 ? length(ts) / duration : 0.0
            end
        end
    end

    # Build final XdfData structure
    final_streams = Dict{Int, XdfStream}()
    for (id, meta) in streams_meta
        parsed_xml = parse_xml(meta["xml_header"]::String)
        
        header = XdfStreamHeader(
            meta["name"]::String,
            meta["type"]::String,
            meta["nchannels"]::Int,
            meta["srate"]::Float64,
            meta["effective_srate"]::Float64,
            string(meta["dtype"]::DataType),
            parsed_xml,
            meta["xml_header"]::String
        )
        stream = XdfStream(id, header, meta["timestamps"]::Vector{Float64}, meta["time_series"], meta["xml_footer"]::String)
        final_streams[id] = stream
    end

    file_info = isempty(file_xml_header) ? Dict{String, Any}() : parse_xml(file_xml_header)
    if typeof(file_info) <: String
        file_info = Dict{String, Any}("text" => file_info)
    end
    
    return XdfData(file_info, final_streams)
end

function _read_chunk_numeric!(io::IO, nsamples::Int, nchannels::Int, srate::Float64, timestamps::Vector{Float64}, time_series::Matrix{T}, current_index::Int) where T
    delta = srate > 0 ? (1.0 / srate) : 0.0
    for _ in 1:nsamples
        if read(io, UInt8) == 8
            timestamps[current_index] = read(io, Float64)
        else
            prev_time = current_index == 1 ? 0.0 : timestamps[current_index - 1]
            timestamps[current_index] = prev_time + delta
        end
        
        for c in 1:nchannels
            time_series[current_index, c] = read(io, T)
        end
        current_index += 1
    end
    return current_index
end

function _read_chunk_string!(io::IO, nsamples::Int, nchannels::Int, srate::Float64, timestamps::Vector{Float64}, time_series::Matrix{String}, current_index::Int)
    delta = srate > 0 ? (1.0 / srate) : 0.0
    for _ in 1:nsamples
        if read(io, UInt8) == 8
            timestamps[current_index] = read(io, Float64)
        else
            prev_time = current_index == 1 ? 0.0 : timestamps[current_index - 1]
            timestamps[current_index] = prev_time + delta
        end
        
        for c in 1:nchannels
            time_series[current_index, c] = String(read(io, _read_varlen_int(io)))
        end
        current_index += 1
    end
    return current_index
end

function _read_varlen_int(io::IO)
    nbytes = read(io, Int8)
    if nbytes == 1
        return Int(read(io, UInt8))
    elseif nbytes == 4
        return Int(read(io, UInt32))
    elseif nbytes == 8
        return Int(read(io, UInt64))
    else
        error("Invalid variable length integer size: \$nbytes")
    end
end

function _findtag(xml::String, tag::String, type::DataType=String)
    m = match(Regex("<$tag>(.*?)</$tag>"), xml)
    content = isnothing(m) ? nothing : m[1]
    if isnothing(content)
        return type == String ? "" : zero(type)
    end
    return type == String ? String(content) : parse(type, content)
end

function _scan_forward(io::IO)
    # Read byte by byte until we match BOUNDARY_SIGNATURE
    match_idx = 1
    while !eof(io)
        b = read(io, UInt8)
        if b == BOUNDARY_SIGNATURE[match_idx]
            match_idx += 1
            if match_idx > length(BOUNDARY_SIGNATURE)
                return true
            end
        else
            # Re-evaluate from start
            match_idx = (b == BOUNDARY_SIGNATURE[1]) ? 2 : 1
        end
    end
    return false
end
