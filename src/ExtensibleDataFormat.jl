module ExtensibleDataFormat

using LinearAlgebra
using Statistics: median
using CodecZlib

export XdfData, XdfStream, read_xdf

include("types.jl")
include("xml.jl")
include("sync.jl")
include("io.jl")

end # module ExtensibleDataFormat
