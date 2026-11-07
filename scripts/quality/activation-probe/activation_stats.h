#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <vector>

// Per-channel sufficient statistics only. No raw activation storage survives a
// callback. Each vector is one teacher-forced decoder position, not one speaker.
namespace recscribe_probe {
struct ChannelStats {
    std::size_t channels;
    std::uint64_t count = 0;
    std::uint64_t observations = 0;
    std::vector<double> sum_abs, sum_squares, max_abs;

    explicit ChannelStats(std::size_t width) : channels(width),
        sum_abs(width, 0), sum_squares(width, 0), max_abs(width, 0) {
        if (width == 0 || width > 1280) throw std::runtime_error("Invalid channel bound");
    }

    void observe(const float * data, std::size_t width, std::size_t positions) {
        if (!data || width != channels || positions == 0 || positions > 64 ||
            count + positions > 64 || observations != 0) {
            throw std::runtime_error("Unexpected decoder observation shape/count");
        }
        // Validate the whole bounded observation before mutating aggregate state.
        for (std::size_t i = 0; i < width * positions; ++i) {
            if (!std::isfinite(data[i])) throw std::runtime_error("Nonfinite activation");
        }
        for (std::size_t t = 0; t < positions; ++t) {
            for (std::size_t c = 0; c < width; ++c) {
                const double value = data[t * width + c];
                const double magnitude = std::abs(value);
                sum_abs[c] += magnitude;
                sum_squares[c] += value * value;
                max_abs[c] = std::max(max_abs[c], magnitude);
            }
        }
        count += positions;
        ++observations;
    }
};
} // namespace recscribe_probe
