#pragma once

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

namespace ggcal {

struct RobustEstimate {
    bool valid = false;
    double centerMs = 0.0;
    double spreadMs = 0.0;
    int used = 0;
    int total = 0;
};

inline double median(std::vector<double> values) {
    if (values.empty()) return 0.0;
    std::sort(values.begin(), values.end());
    const size_t n = values.size();
    return (n & 1U) ? values[n / 2] : (values[n / 2 - 1] + values[n / 2]) * 0.5;
}

inline RobustEstimate robustEstimate(const std::vector<double>& samples, int minSamples = 5) {
    RobustEstimate out;
    out.total = static_cast<int>(samples.size());
    if (static_cast<int>(samples.size()) < minSamples) return out;

    const double firstMedian = median(samples);
    std::vector<double> deviations;
    deviations.reserve(samples.size());
    for (double value : samples) deviations.push_back(std::abs(value - firstMedian));

    const double mad = median(deviations);
    // 1.4826 scales MAD toward standard deviation for a normal distribution.
    // Keep a practical floor so one slightly late human tap does not dominate a
    // very tight run, while still rejecting accidental double-strums.
    const double threshold = std::max(30.0, 3.5 * 1.4826 * mad);

    std::vector<double> filtered;
    filtered.reserve(samples.size());
    for (double value : samples) {
        if (std::abs(value - firstMedian) <= threshold) filtered.push_back(value);
    }
    if (static_cast<int>(filtered.size()) < minSamples) return out;

    out.centerMs = median(filtered);
    std::vector<double> filteredDeviations;
    filteredDeviations.reserve(filtered.size());
    for (double value : filtered) filteredDeviations.push_back(std::abs(value - out.centerMs));
    out.spreadMs = median(filteredDeviations);
    out.used = static_cast<int>(filtered.size());
    out.valid = true;
    return out;
}

inline const char* qualityLabel(const RobustEstimate& estimate) {
    if (!estimate.valid) return "Not enough samples";
    if (estimate.spreadMs <= 10.0) return "Excellent";
    if (estimate.spreadMs <= 20.0) return "Good";
    if (estimate.spreadMs <= 35.0) return "Fair";
    return "Noisy";
}

struct AvCalibration {
    RobustEstimate audio;
    RobustEstimate video;
    double audioOffsetMs = 0.0;
    double videoOffsetMs = 0.0;
    double videoMinusAudioMs = 0.0;
};

inline AvCalibration computeAv(const std::vector<double>& audioSamples,
                               const std::vector<double>& videoSamples) {
    AvCalibration out;
    out.audio = robustEstimate(audioSamples);
    out.video = robustEstimate(videoSamples);
    if (out.audio.valid) out.audioOffsetMs = out.audio.centerMs;
    if (out.video.valid) out.videoOffsetMs = out.video.centerMs;
    if (out.audio.valid && out.video.valid) {
        out.videoMinusAudioMs = out.video.centerMs - out.audio.centerMs;
    }
    return out;
}

} // namespace ggcal
