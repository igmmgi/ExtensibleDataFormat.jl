"""
    XdfStreamHeader

Contains metadata parsed from the XML StreamHeader chunk of an XDF file.
"""
struct XdfStreamHeader
    name::String
    type::String
    channel_count::Int
    nominal_srate::Float64
    effective_srate::Float64
    channel_format::String
    info::Dict{String, Any}
    xml_header::String
end

"""
    XdfStream{T}

Represents a single parsed stream from an XDF file.
`T` is the underlying data type of the time series (e.g. Float32, String).
"""
struct XdfStream{T}
    stream_id::Int
    header::XdfStreamHeader
    timestamps::Vector{Float64}
    time_series::Matrix{T}
    xml_footer::String
end

"""
    XdfData

A collection of all streams read from an XDF file.
"""
struct XdfData
    filename::String
    info::Dict{String, Any}
    streams::Dict{Int,XdfStream}
end
