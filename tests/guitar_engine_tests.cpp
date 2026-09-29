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

    // Strum chords require exact fret state, but CH allows lower-fret
    // anchoring on HOPO/tap chords.
    assert(noteFrettingMatches(0b00110, 0b00110, false, true, false, false));
    assert(!noteFrettingMatches(0b00111, 0b00110, false, true, false, false));
    assert(noteFrettingMatches(0b00111, 0b00110, false, false, true, false));
    assert(!noteFrettingMatches(0b01110, 0b00110, false, false, true, false));

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
    assert(canFretTransitionHit(false, true, true, 0, 0, 0, 0, 0b00010));

    // Clone Hero-like frontend buffering remains armed only while the target
    // fret state is still physically valid. HOPOs lose the arm if combo breaks;
    // taps do not.
    assert(frontendHeldStillValid(true, false, false, 5, 0b00011, 0b00010));
    assert(!frontendHeldStillValid(true, false, false, 0, 0b00011, 0b00010));
    assert(frontendHeldStillValid(false, true, false, 0, 0b01000, 0b01000));
    assert(frontendHeldStillValid(true, false, true, 3, 0, 0));
    assert(!frontendHeldStillValid(true, false, true, 0, 0, 0));

    // Clone Hero's normal guitar engine uses a +/-70 ms core window plus a
    // lead-developer-confirmed ~50 ms early-strum leniency.
    assert(earlyStrumCanBuffer(5.0, 4.881, 0.070, 0.050));
    assert(!earlyStrumCanBuffer(5.0, 4.879, 0.070, 0.050));
    assert(strumBufferActive(4.881, 4.925, 0.050));
    assert(!strumBufferActive(4.881, 4.940, 0.050));

    // A recently hit HOPO/tap may consume one nearby strum rather than turning
    // it into an overstrum; 80 ms is the YARG-derived compatibility estimate.
    assert(hopoCanEatStrum(10.000, 10.079, 0.080));
    assert(!hopoCanEatStrum(10.000, 10.081, 0.080));

    // Dense-stream protection: a strum inside the post-HOPO forgiveness window
    // must still hit the next valid note if that next note is already hittable.
    assert(!hopoStrumShouldBeEaten(20.000, 20.075, 0.080, 20.075, 0.070, true));
    assert(hopoStrumShouldBeEaten(20.000, 20.040, 0.080, 20.120, 0.070, true));
    assert(hopoStrumShouldBeEaten(20.000, 20.040, 0.080, 20.040, 0.070, false));

    // Anchored HOPO/tap chords can be entered via a real fret transition.
    assert(canFretTransitionHit(true, false, false, 8, 0b00111, 0b00110, 0b00100, 0));
    assert(canFretTransitionHit(false, true, false, 0, 0b00111, 0b00110, 0b00100, 0));

    // Double-strum protection is direction-specific: repeated down/down can be
    // ignored, but down/up remains a legitimate alt-strum even at the same
    // spacing. Zero disables the profile setting.
    assert(sameDirectionStrumProtected(StrumDirection::Down, 20.000,
                                       StrumDirection::Down, 20.025, 0.030));
    assert(!sameDirectionStrumProtected(StrumDirection::Down, 20.000,
                                        StrumDirection::Up, 20.025, 0.030));
    assert(!sameDirectionStrumProtected(StrumDirection::Down, 20.000,
                                        StrumDirection::Down, 20.031, 0.030));
    assert(!sameDirectionStrumProtected(StrumDirection::Down, 20.000,
                                        StrumDirection::Down, 20.001, 0.0));

    // Sustain-drop leniency is likewise a profile parameter rather than a
    // guessed universal CH constant.
    assert(sustainDropIsForgiven(30.000, 30.040, 0.050));
    assert(!sustainDropIsForgiven(30.000, 30.051, 0.050));
    assert(!sustainDropIsForgiven(30.000, 30.001, 0.0));

    // Poll timestamp mapping removes render-frame delay.
    assert(near(eventSongTime(10.000, 0.006), 9.994));
    assert(near(eventSongTime(10.000, -0.001), 10.000));

    assert(withinHitWindow(5.0, 4.931, 0.070));
    assert(!withinHitWindow(5.0, 4.929, 0.070));

    std::cout << "GitarGame guitar engine tests passed\n";
    return 0;
}
