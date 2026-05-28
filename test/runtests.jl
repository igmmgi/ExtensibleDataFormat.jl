using Test
using ExtensibleDataFormat
using LinearAlgebra

# We need to test internal functions that aren't exported
import ExtensibleDataFormat: _robust_fit, _clock_sync!, _jitter_removal!

@testset "ExtensibleDataFormat.jl" begin

    @testset "Robust Clock Sync (ADMM Huber)" begin
        # Perfect linear relationship: y = 2x + 1
        X = hcat(ones(100), 1.0:100.0)
        y = collect(2.0 .* (1.0:100.0) .+ 1.0)
        
        # Add a massive outlier to index 50
        y[50] += 1000.0
        
        coef = _robust_fit(X, y; rho=1.0, iters=1000)
        
        # Robust fit should effectively ignore the outlier
        @test isapprox(coef[1], 1.0, atol=0.05)
        @test isapprox(coef[2], 2.0, atol=0.01)
    end

    @testset "Jitter Removal" begin
        # Create a mock streams_meta dictionary
        meta = Dict{Int, Any}()
        
        # Ideal timestamps: 1.0, 1.1, 1.2, 1.3, 1.4 (srate = 10Hz)
        # We add some random jitter
        jittered_timestamps = [1.0, 1.12, 1.19, 1.31, 1.4]
        
        meta[1] = Dict{String, Any}(
            "timestamps" => copy(jittered_timestamps),
            "srate" => 10.0,
            "effective_srate" => 0.0
        )
        
        _jitter_removal!(meta; threshold_seconds=1.0, threshold_samples=500)
        
        clean_ts = meta[1]["timestamps"]
        
        # The dejitter algorithm should enforce a perfectly uniform grid via linear regression
        diffs = diff(clean_ts)
        @test all(isapprox.(diffs, diffs[1], atol=1e-10))
        
        # Effective sample rate should be extremely close to 10.0 Hz
        @test isapprox(meta[1]["effective_srate"], 10.0, atol=0.1)
    end

    @testset "End-to-End File Parsing" begin
        # We test on bundled test files and the official minimal standard test files
        for test_file in ["test.xdf", "minimal.xdf", "clock_resets.xdf", "empty_streams.xdf"]
            file_path = joinpath(@__DIR__, test_file)
            if isfile(file_path)
                data = read_xdf(file_path; sync=true, dejitter_timestamps=true)
                
                @test !isempty(data.streams)
                
                # Check if all streams have pre-allocated time_series matrices and nested XML dicts
                for (id, stream) in data.streams
                    @test ndims(stream.time_series) == 2
                    @test size(stream.time_series, 2) == stream.header.channel_count
                    @test length(stream.timestamps) == size(stream.time_series, 1)
                    
                    # Verify deep XML parsing works natively
                    @test stream.header.info isa Dict{String, Any}
                    @test haskey(stream.header.info, "info")
                end
                
                # Standard compliance assertions
                if test_file == "minimal.xdf"
                    @test length(data.streams) == 2
                    s1 = data.streams[0]
                    s2 = data.streams[46202862]
                    @test s1.header.channel_count == 3
                    @test size(s1.time_series, 1) == 9
                    @test s1.header.channel_format == "Int16"
                    # Assert exact parsed data values
                    @test s1.time_series[1, 1] == 192
                    @test s1.time_series[2, 2] == 22
                    @test s1.time_series[3, 3] == 33
                    
                    @test s2.header.channel_count == 1
                    @test size(s2.time_series, 1) == 9
                    @test s2.header.channel_format == "String"
                    @test s2.time_series[2, 1] == "Hello"
                    @test s2.time_series[3, 1] == "World"
                    
                elseif test_file == "clock_resets.xdf"
                    @test length(data.streams) == 2
                    s1 = data.streams[1]
                    s2 = data.streams[2]
                    @test size(s1.time_series, 1) == 175
                    @test s1.header.channel_format == "String"
                    @test size(s2.time_series, 1) == 27815
                    @test s2.header.channel_count == 8
                    @test s2.header.channel_format == "Float32"
                    
                elseif test_file == "empty_streams.xdf"
                    @test length(data.streams) == 4
                    # Test Stream 1
                    @test size(data.streams[1].time_series, 1) == 1
                    @test data.streams[1].header.channel_format == "String"
                    @test data.streams[1].time_series[1, 1] == "{\"state\": 2}"
                    # Test Empty Stream 2
                    @test size(data.streams[2].time_series, 1) == 0
                    @test data.streams[2].header.channel_format == "String"
                    # Test Empty Stream 3
                    @test size(data.streams[3].time_series, 1) == 0
                    @test data.streams[3].header.channel_format == "Float32"
                    # Test Stream 4 (Int32 counter)
                    @test size(data.streams[4].time_series, 1) == 10
                    @test data.streams[4].header.channel_format == "Int32"
                    @test data.streams[4].time_series[1, 1] == 0
                    @test data.streams[4].time_series[end, 1] == 9
                end
                
                # Test selective stream loading
                first_stream_id = first(keys(data.streams))
                data_subset = read_xdf(file_path; select_streams=[first_stream_id], sync=false, dejitter_timestamps=false)
                @test length(data_subset.streams) == 1
            else
                @warn "Test file \$file_path not found, skipping."
            end
        end
    end
end
