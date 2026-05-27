# ExtensibleDataFormat.jl

A lightweight, zero-dependency Julia package for reading Extensible Data Format (.xdf) files.

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

## Features

- **Blisteringly Fast**: Utilizes a highly-optimized, allocation-free, two-pass parsing algorithm. Benchmarks show it runs up to ~19x faster than standard Python implementations.
- **Robust Clock Synchronization**: Implements ADMM Huber-loss optimization to robustly calculate clock offsets while ignoring jitter spikes and detecting hardware clock resets.
- **De-Jittering**: Uses segmented least-squares regression to automatically enforce uniform sampling grids on networks with high latency variance.
- **Fault-Tolerant**: Implements byte-by-byte boundary signature scanning to recover from corrupted recordings.
- **Native XML Parsing**: Includes a lightweight, pure-Julia XML parser that automatically converts XDF headers into nested Julia Dictionaries without relying on external C-libraries (like `EzXML.jl`).
- **Zero-Dependency Core**: Only depends on standard libraries (`LinearAlgebra`, `Statistics`) and `CodecZlib` for on-the-fly decompression.

## Acknowledgments

Development and refactoring of the core I/O architecture was assisted by Google's Gemini 3.1, with reference to the official [pyxdf](https://github.com/sccn/xdf/tree/master/Python/pyxdf) Python implementation for robust mathematical synchronization and de-jittering algorithms.
