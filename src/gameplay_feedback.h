#pragma once

#include <algorithm>
#include <cmath>

namespace ggfeedback {

inline double clamp01(double value) {
    return std::clamp(value, 0.0, 1.0);
}

inline double rippleProgress(double ageSeconds, double durationSeconds = 0.42) {
    if (durationSeconds <= 0.0) return 1.0;
    return clamp01(ageSeconds / durationSeconds);
}

inline double rippleStrength(double ageSeconds, double durationSeconds = 0.42) {
    const double p = rippleProgress(ageSeconds, durationSeconds);
    if (ageSeconds < 0.0 || p >= 1.0) return 0.0;
    const double ease = 1.0 - p;
    return ease * ease;
}

inline double hitBloomProgress(double ageSeconds, double durationSeconds = 0.34) {
    if (durationSeconds <= 0.0) return 1.0;
    return clamp01(ageSeconds / durationSeconds);
}

inline double hitBloomAlpha(double ageSeconds, double durationSeconds = 0.34) {
    if (ageSeconds < 0.0) return 0.0;
    const double p = hitBloomProgress(ageSeconds, durationSeconds);
    if (p >= 1.0) return 0.0;
    const double remaining = 1.0 - p;
    return remaining * remaining;
}

inline double hitBloomScale(double ageSeconds, double durationSeconds = 0.34) {
    const double p = hitBloomProgress(ageSeconds, durationSeconds);
    // Fast initial pop, then a smaller outward drift as the ghost fades.
    return 1.0 + 0.34 * (1.0 - std::pow(1.0 - p, 2.0));
}

inline double missProgress(double ageSeconds, double durationSeconds = 0.46) {
    if (durationSeconds <= 0.0) return 1.0;
    return clamp01(std::max(0.0, ageSeconds) / durationSeconds);
}

inline double missRedBlend(double ageSeconds, double durationSeconds = 0.46) {
    const double p = missProgress(ageSeconds, durationSeconds);
    // Red arrives quickly so the miss is legible before the gem travels far
    // past the strike line.
    return 1.0 - std::pow(1.0 - p, 4.0);
}

inline double missScale(double ageSeconds, double durationSeconds = 0.46) {
    const double p = missProgress(ageSeconds, durationSeconds);
    const double throb = std::sin(std::min(1.0, p * 2.0) * 3.14159265358979323846);
    return 1.0 + 0.07 * throb - 0.10 * p;
}

inline double missAlpha(double ageSeconds, double durationSeconds = 0.46) {
    const double p = missProgress(ageSeconds, durationSeconds);
    if (p < 0.42) return 1.0;
    const double fade = (p - 0.42) / 0.58;
    return std::clamp(1.0 - 0.58 * fade, 0.42, 1.0);
}

inline bool sustainHolding(bool noteHit, double noteTime, double sustainSeconds,
                           double now, bool heldCorrect) {
    if (!noteHit || sustainSeconds <= 0.03 || !heldCorrect) return false;
    return now >= noteTime - 0.02 && now <= noteTime + sustainSeconds + 0.02;
}

inline double previewStartSeconds(double explicitStartMs, double audioLengthSeconds) {
    if (audioLengthSeconds <= 0.0) return 0.0;
    const double latestUseful = std::max(0.0, audioLengthSeconds - 8.0);
    if (explicitStartMs >= 0.0) {
        return std::clamp(explicitStartMs / 1000.0, 0.0, latestUseful);
    }
    const double fallback = std::min(30.0, std::max(5.0, audioLengthSeconds * 0.28));
    return std::clamp(fallback, 0.0, latestUseful);
}

inline double previewEndSeconds(double explicitEndMs, double startSeconds,
                                double audioLengthSeconds) {
    if (audioLengthSeconds <= 0.0) return startSeconds;
    if (explicitEndMs > 0.0) {
        const double requested = explicitEndMs / 1000.0;
        if (requested > startSeconds + 1.0)
            return std::clamp(requested, startSeconds + 1.0, audioLengthSeconds);
    }
    return std::min(audioLengthSeconds, startSeconds + 18.0);
}

inline bool songFinished(double playedSeconds, double lengthSeconds,
                         double toleranceSeconds = 0.08) {
    return lengthSeconds > 0.25 && playedSeconds >= std::max(0.0, lengthSeconds - toleranceSeconds);
}

} // namespace ggfeedback
