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
