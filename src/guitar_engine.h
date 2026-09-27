#pragma once

#include <algorithm>
#include <bit>
#include <cstdint>

namespace ggengine {

constexpr double kCloneHeroLikeHalfWindowMs = 70.0;

inline bool heldMatches(uint8_t held, uint8_t target) {
    const int count = std::popcount(static_cast<unsigned int>(target));
    if (count > 1) return held == target;
    if (count != 1) return false;

    const int lane = std::countr_zero(static_cast<unsigned int>(target));
    const uint8_t targetAndLower = static_cast<uint8_t>((1U << (lane + 1)) - 1U);

    // Guitar Hero/Clone Hero-style anchoring: lower frets may remain held
    // beneath a single higher target, but higher frets invalidate it.
    return (held & target) != 0 &&
           (held & static_cast<uint8_t>(~targetAndLower)) == 0;
}

inline bool releasedHigherFret(uint8_t releasedMask, uint8_t target) {
    if (std::popcount(static_cast<unsigned int>(target)) != 1) return false;
    const int targetLane = std::countr_zero(static_cast<unsigned int>(target));
    const uint8_t higherMask = static_cast<uint8_t>(0x1fU & ~((1U << (targetLane + 1)) - 1U));
    return (releasedMask & higherMask) != 0;
}

inline bool frontendHeldStillValid(bool hopo, bool tap, bool open,
                                      int comboBeforeHit, uint8_t held,
                                      uint8_t targetMask) {
    if (open) {
        if (held != 0) return false;
        if (tap) return true;
        return hopo && comboBeforeHit > 0;
    }

    if (!heldMatches(held, targetMask)) return false;
    if (tap) return true;
    return hopo && comboBeforeHit > 0;
}

inline bool canFretTransitionHit(bool hopo, bool tap, bool open,
                                 int comboBeforeHit, uint8_t resultingHeld,
                                 uint8_t targetMask, uint8_t pressedMask,
                                 uint8_t releasedMask) {
    if (open) {
        if (resultingHeld != 0 || releasedMask == 0) return false;
        if (tap) return true;
        return hopo && comboBeforeHit > 0;
    }

    if (std::popcount(static_cast<unsigned int>(targetMask)) != 1) return false;
    if (!heldMatches(resultingHeld, targetMask)) return false;

    if (tap) {
        // Taps do not need an active combo, but they must come from a press of
        // the target fret. Releasing/re-pressing is therefore required for
        // repeated taps on the same lane.
        return (pressedMask & targetMask) != 0;
    }

    if (!hopo || comboBeforeHit <= 0) return false;

    // Hammer-on: target fret was pressed.
    if ((pressedMask & targetMask) != 0) return true;

    // Pull-off: a physically higher fret was released and the resulting held
    // state now matches the lower target (possibly with anchored lower frets).
    return releasedHigherFret(releasedMask, targetMask);
}

inline double eventSongTime(double frameSongTimeSeconds,
                            double eventAgeSeconds) {
    // XInput events are sampled on the polling thread before the render frame
    // consumes them. Preserve that original timestamp rather than adding a
    // frame of latency/jitter. Negative age can only happen from tiny ordering
    // races and is clamped away.
    return frameSongTimeSeconds - std::max(0.0, eventAgeSeconds);
}

inline bool withinHitWindow(double noteTimeSeconds, double inputTimeSeconds,
                            double halfWindowSeconds) {
    return std::abs(noteTimeSeconds - inputTimeSeconds) <= halfWindowSeconds;
}

} // namespace ggengine
