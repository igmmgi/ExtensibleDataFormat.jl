# sync.jl

using LinearAlgebra
using Statistics: median

"""
    _robust_fit(A, y; rho=1.0, iters=1000)

Perform robust linear regression using Huber loss via ADMM.
"""
function _robust_fit(A::Matrix{Float64}, y::Vector{Float64}; rho::Float64=1.0, iters::Int=1000)
    A_work = copy(A)
    offset = minimum(A_work[:, 2])
    A_work[:, 2] .-= offset
    Aty = A_work' * y
    # A_work' * A_work is symmetric positive definite
    AtA = A_work' * A_work
    L = cholesky(AtA).L
    U = L'

    z = zeros(length(y))
    u = zeros(length(y))
    x = zeros(2)

    # Pre-allocate loop temporaries
    rhs = zeros(2)
    d = zeros(length(y))
    d_inv = zeros(length(y))
    tmp = zeros(length(y))

    for _ in 1:iters
        # x .= U \ (L \ (Aty + A_work' * (z - u)))
        rhs .= Aty .+ A_work' * (z .- u)
        x .= U \ (L \ rhs)

        d .= A_work * x .- y .+ u

        d_inv .= ifelse.(d .== 0, 0.0, 1.0 ./ d)
        tmp .= max.(0.0, 1.0 .- (1.0 + 1.0 / rho) .* abs.(d_inv))

        z .= (rho / (1.0 + rho)) .* d .+ (1.0 / (1.0 + rho)) .* tmp .* d
        u .= d .- z
    end

    x[1] -= x[2] * offset
    return x
end

function _clock_sync!(streams_meta::Dict{Int,Any};
    handle_clock_resets=true,
    reset_threshold_stds=5.0,
    reset_threshold_seconds=5.0,
    reset_threshold_offset_stds=10.0,
    reset_threshold_offset_seconds=1.0,
    winsor_threshold=0.0001)

    for (_, meta) in streams_meta
        timestamps = meta["timestamps"]::Vector{Float64}
        if isempty(timestamps)
            continue
        end

        clock_times = meta["clock"]::Vector{Float64}
        clock_values = meta["offset"]::Vector{Float64}

        if isempty(clock_times)
            continue
        end

        ranges = Tuple{Int,Int}[]

        if handle_clock_resets && length(clock_times) > 1
            time_diff = diff(clock_times)
            value_diff = abs.(diff(clock_values))

            median_ival = median(time_diff)
            median_slope = median(value_diff)

            mad_time = median(abs.(time_diff .- median_ival)) + eps(Float64)
            time_glitch = (time_diff .< 0) .| (((time_diff .- median_ival) ./ mad_time .> reset_threshold_stds) .& (time_diff .- median_ival .> reset_threshold_seconds))

            mad_value = median(abs.(value_diff .- median_slope)) + eps(Float64)
            value_glitch = (value_diff .< 0) .| (((value_diff .- median_slope) ./ mad_value .> reset_threshold_offset_stds) .& (value_diff .- median_slope .> reset_threshold_offset_seconds))

            resets_at = time_glitch .& value_glitch

            if !any(resets_at)
                push!(ranges, (1, length(clock_times)))
            else
                indices = findall(resets_at)
                push!(ranges, (1, indices[1]))
                for i in 1:length(indices)-1
                    push!(ranges, (indices[i] + 1, indices[i+1]))
                end
                push!(ranges, (indices[end] + 1, length(clock_times)))
            end
        else
            push!(ranges, (1, length(clock_times)))
        end

        coef = Tuple{Float64,Float64}[]
        for rng in ranges
            start_idx, stop_idx = rng
            if start_idx != stop_idx
                e = ones(stop_idx - start_idx + 1)
                t_slice = clock_times[start_idx:stop_idx] ./ winsor_threshold
                X = hcat(e, t_slice)
                y_slice = clock_values[start_idx:stop_idx] ./ winsor_threshold

                c = _robust_fit(X, y_slice)
                c[1] *= winsor_threshold
                c[2] *= winsor_threshold
                push!(coef, (c[1], c[2]))
            else
                push!(coef, (clock_values[start_idx], 0.0))
            end
        end

        if length(ranges) == 1
            timestamps .= coef[1][1] .+ (1.0 + coef[1][2]) .* timestamps
        else
            # Map timestamps to the corresponding clock range based on time
            for i in eachindex(timestamps)
                t = timestamps[i]
                best_rng_idx = 1
                for r in eachindex(ranges)
                    t_start = clock_times[ranges[r][1]]
                    t_end = clock_times[ranges[r][2]]
                    if t >= t_start && t <= t_end
                        best_rng_idx = r
                        break
                    elseif t > t_end && r == length(ranges)
                        best_rng_idx = r
                    end
                end
                timestamps[i] += coef[best_rng_idx][1] + coef[best_rng_idx][2] * timestamps[i]
            end
        end
    end
end

function _jitter_removal!(streams_meta::Dict{Int,Any};
    threshold_seconds=1.0,
    threshold_samples=500)

    for (id, meta) in streams_meta
        timestamps = meta["timestamps"]::Vector{Float64}
        srate = meta["srate"]::Float64
        tdiff = srate > 0 ? 1.0 / srate : 0.0

        nsamples = length(timestamps)
        meta["effective_srate"] = 0.0

        if nsamples > 0 && srate > 0
            diffs = diff(timestamps)
            max_thresh = max(threshold_seconds, threshold_samples * tdiff)
            b_breaks = (diffs .> max_thresh) .| (diffs .< 0.0)

            break_inds = findall(b_breaks)

            seg_starts = [1; break_inds .+ 1]
            seg_stops = [break_inds; nsamples]

            for (start_ix, stop_ix) in zip(seg_starts, seg_stops)
                N = stop_ix - start_ix + 1
                if N > 1
                    x_bar = (start_ix + stop_ix) / 2.0
                    
                    # Compute mean of y
                    sum_y = 0.0
                    for i in start_ix:stop_ix
                        sum_y += timestamps[i]
                    end
                    y_bar = sum_y / N
                    
                    # Compute slope (beta_1)
                    num = 0.0
                    for i in start_ix:stop_ix
                        num += (i - x_bar) * timestamps[i]
                    end
                    den = Float64(N) * (Float64(N)^2 - 1.0) / 12.0
                    slope = num / den
                    
                    # Compute intercept (beta_0)
                    intercept = y_bar - slope * x_bar
                    
                    # Apply correction
                    for i in start_ix:stop_ix
                        timestamps[i] = intercept + slope * i
                    end
                end
            end

            counts = (seg_stops .+ 1) .- seg_starts
            if any(counts .> 0)
                durations = (timestamps[seg_stops] .+ tdiff) .- timestamps[seg_starts]
                meta["effective_srate"] = sum(counts) / sum(durations)
            end
        end

        effective_srate = meta["effective_srate"]::Float64
        if srate != 0 && abs(srate - effective_srate) / srate > 0.1
            @warn "Stream $id: Calculated effective sampling rate $effective_srate Hz is different from specified rate $srate Hz."
        end
    end
end
