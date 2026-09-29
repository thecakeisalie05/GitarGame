#pragma once

#include <algorithm>
#include <bit>
#include <cstdint>
#include <cmath>

namespace ggengine {

constexpr double kCloneHeroHalfWindowMs = 70.0;
constexpr double kCloneHeroStrumLeniencyMs = 50.0;
// Clone Hero's exact post-HOPO strum-eat timer is not publicly documented.
// 80 ms is used by YARG's CH/GH-style guitar engine and matches community
// descriptions closely enough to serve as our behavioral approximation.
constexpr double kCloneHeroHopoStrumEatMs = 80.0;

// These two values are profile settings in Clone Hero, not universal engine
// constants. GitarGame keeps them parameterized so a CH profile can be copied
// exactly instead of baking an unverifiable value into hit detection.
constexpr double kDefaultDoubleStrumProtectionMs = 0.0;
constexpr double kDefaultSustainDropLeniencyMs = 0.0;

enum class StrumDirection : int8_t { None = 0, Up = -1, Down = 1 };

inline bool sameDirectionStrumProtected(StrumDirection previousDirection,
                                        double previousTimeSeconds,
                                        StrumDirection direction,
                                        double inputTimeSeconds,
                                        double protectionSeconds) {
    if (protectionSeconds <= 0.0 || previousDirection == StrumDirection::None ||
        direction == StrumDirection::None || previousDirection != direction)
        return false;
    const double delta = inputTimeSeconds - previousTimeSeconds;
    return delta >= 0.0 && delta <= protectionSeconds;
}

inline bool sustainDropIsForgiven(double releasedAtSeconds,
                                  double reacquiredAtSeconds,
                                  double leniencySeconds) {
    if (leniencySeconds <= 0.0 || releasedAtSeconds < 0.0 ||
        reacquiredAtSeconds < releasedAtSeconds) return false;
    return reacquiredAtSeconds - releasedAtSeconds <= leniencySeconds;
}

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

inline bool chordAnchoringMatches(uint8_t held, uint8_t target) {
    if (std::popcount(static_cast<unsigned int>(target)) < 2) return false;
    if ((held & target) != target) return false;

    const uint8_t extras = static_cast<uint8_t>(held & static_cast<uint8_t>(~target));
    if (extras == 0) return true;

    const int lowestTargetLane = std::countr_zero(static_cast<unsigned int>(target));
    const uint8_t allowedLower =
        lowestTargetLane == 0 ? 0 : static_cast<uint8_t>((1U << lowestTargetLane) - 1U);
    return (extras & static_cast<uint8_t>(~allowedLower)) == 0;
}

inline bool noteFrettingMatches(uint8_t held, uint8_t target,
                                bool open, bool strum, bool hopo, bool tap) {
    if (open) return held == 0;
    const int count = std::popcount(static_cast<unsigned int>(target));
    if (count <= 0) return false;
    if (count == 1) return heldMatches(held, target);

    // Clone Hero allows lower-fret anchoring on HOPO/tap chords, while strum
    // chords still require an exact chord mask.
    if (!strum && (hopo || tap)) return chordAnchoringMatches(held, target);
    return held == target;
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

    if (!noteFrettingMatches(held, targetMask, false, false, hopo, tap)) return false;
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

    if (!noteFrettingMatches(resultingHeld, targetMask, false, false, hopo, tap))
        return false;

    const int count = std::popcount(static_cast<unsigned int>(targetMask));
    if (count > 1) {
        // CH permits anchored HOPO/tap chords. A real fret transition is still
        // required so holding the same chord cannot repeatedly auto-hit it.
        if ((pressedMask | releasedMask) == 0) return false;
        if (tap) return true;
        return hopo && comboBeforeHit > 0;
    }

    if (tap) {
        return (pressedMask & targetMask) != 0;
    }

    if (!hopo || comboBeforeHit <= 0) return false;
    if ((pressedMask & targetMask) != 0) return true;
    return releasedHigherFret(releasedMask, targetMask);
}

inline bool earlyStrumCanBuffer(double noteTimeSeconds,
                                  double inputTimeSeconds,
                                  double halfWindowSeconds,
                                  double leniencySeconds) {
    const double frontEdge = noteTimeSeconds - halfWindowSeconds;
    return inputTimeSeconds < frontEdge &&
           inputTimeSeconds >= frontEdge - leniencySeconds;
}

inline bool strumBufferActive(double strumTimeSeconds, double nowSeconds,
                              double leniencySeconds) {
    return nowSeconds >= strumTimeSeconds &&
           nowSeconds <= strumTimeSeconds + leniencySeconds;
}

inline bool hopoCanEatStrum(double hopoHitTimeSeconds, double strumTimeSeconds,
                            double leniencySeconds) {
    if (hopoHitTimeSeconds < 0.0 || strumTimeSeconds < hopoHitTimeSeconds) return false;
    return strumTimeSeconds - hopoHitTimeSeconds <= leniencySeconds;
}

inline bool hopoStrumShouldBeEaten(double hopoHitTimeSeconds,
                                   double strumTimeSeconds,
                                   double eatLeniencySeconds,
                                   double nextNoteTimeSeconds,
                                   double halfWindowSeconds,
                                   bool nextNoteFrettingMatches) {
    if (!hopoCanEatStrum(hopoHitTimeSeconds, strumTimeSeconds, eatLeniencySeconds))
        return false;

    // A post-HOPO strum-eat window is forgiveness for a near-simultaneous
    // redundant strum. It must never swallow a strum that can legitimately
    // hit the next note in a dense stream.
    if (nextNoteFrettingMatches &&
        std::abs(nextNoteTimeSeconds - strumTimeSeconds) <= halfWindowSeconds)
        return false;

    return true;
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
