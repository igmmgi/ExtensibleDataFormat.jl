# ExtensibleDataFormat.jl

A lightweight Julia package for reading Extensible Data Format (.xdf) files.

## Overview

XDF is a general-purpose container format for multi-channel time-series data, widely used with the Lab Streaming Layer (LSL) ecosystem for synchronized recordings of EEG, eye-tracking, and behavioral data.

For the full format specification, see the [XDF Specifications Wiki](https://github.com/sccn/xdf/wiki/Specifications).

## Usage

```julia
using ExtensibleDataFormat

# Read an XDF file
xdf = read_xdf("path/to/your/recording.xdf")

# Inspect the streams
for (id, stream) in xdf.streams
    println("Stream ID: \$id")
    println("Name: ", stream.header.name)
    println("Type: ", stream.header.type)
    println("Sample Rate: ", stream.header.nominal_srate)
    println("Channels: ", stream.header.channel_count)
    println("Samples: ", size(stream.time_series, 1))
    println()
end
```

## Acknowledgments

Development and refactoring of the core I/O architecture was assisted by Google's Gemini 3.1, with reference to the official [pyxdf](https://github.com/sccn/xdf/tree/master/Python/pyxdf) Python implementation for robust mathematical synchronization and de-jittering algorithms.
