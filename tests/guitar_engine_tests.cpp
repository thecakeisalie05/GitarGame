#include "guitar_engine.h"

#include <cassert>
#include <cmath>
#include <iostream>

static bool near(double a, double b, double eps = 1e-9) {
    return std::abs(a - b) <= eps;
}

int main() {
    using namespace ggengine;

    // Single-note anchoring: green can stay held beneath red; yellow above red
    // invalidates the red note.
    assert(heldMatches(0b00011, 0b00010));
    assert(!heldMatches(0b00110, 0b00010));
    assert(heldMatches(0b00100, 0b00100));
    assert(heldMatches(0b00111, 0b00100));

    // Chords require exact fret state.
    assert(heldMatches(0b00110, 0b00110));
    assert(!heldMatches(0b00111, 0b00110));

    // HOPOs require an active combo.
    assert(!canFretTransitionHit(true, false, false, 0, 0b00010, 0b00010, 0b00010, 0));
    assert(canFretTransitionHit(true, false, false, 7, 0b00011, 0b00010, 0b00010, 0));

    // Pull off from yellow to an anchored red (green remains held).
    assert(canFretTransitionHit(true, false, false, 12, 0b00011, 0b00010, 0, 0b00100));
    // Releasing a lower fret while red remains held is not a pull-off to red.
    assert(!canFretTransitionHit(true, false, false, 12, 0b00010, 0b00010, 0, 0b00001));

    // Taps work without combo, but require a fresh press.
    assert(canFretTransitionHit(false, true, false, 0, 0b01000, 0b01000, 0b01000, 0));
    assert(!canFretTransitionHit(false, true, false, 0, 0b01000, 0b01000, 0, 0b00100));

    // Open HOPO/tap notes are played by releasing all frets.
    assert(canFretTransitionHit(true, false, true, 4, 0, 0, 0, 0b00010));
    assert(!canFretTransitionHit(true, false, true, 0, 0, 0, 0, 0b00010));
    assert(canFretTransitionHit(false, true, true, 0, 0, 0, 0b00010));

    // Poll timestamp mapping removes render-frame delay.
    assert(near(eventSongTime(10.000, 0.006), 9.994));
    assert(near(eventSongTime(10.000, -0.001), 10.000));

    assert(withinHitWindow(5.0, 4.931, 0.070));
    assert(!withinHitWindow(5.0, 4.929, 0.070));

    std::cout << "GitarGame guitar engine tests passed\n";
    return 0;
}
