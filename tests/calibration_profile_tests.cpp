#include "calibration_profile.h"

#include <cassert>
#include <cmath>
#include <iostream>

static bool near(double a, double b, double eps = 1e-6) {
    return std::abs(a - b) <= eps;
}

int main() {
    ggcalprofile::Values source;
    source.audioOffsetMs = 37.5;
    source.videoOffsetMs = -12.0;

    const std::string encoded = ggcalprofile::serialize(source);
    const auto decoded = ggcalprofile::parse(encoded);
    assert(decoded.has_value());
    assert(near(decoded->audioOffsetMs, 37.5));
    assert(near(decoded->videoOffsetMs, -12.0));

    const auto clamped = ggcalprofile::parse(
        "version = 1\naudio_offset_ms = 999\nvideo_offset_ms = -999\n");
    assert(clamped.has_value());
    assert(near(clamped->audioOffsetMs, 500.0));
    assert(near(clamped->videoOffsetMs, -500.0));

    assert(!ggcalprofile::parse("audio_offset_ms = 15\n").has_value());
    assert(!ggcalprofile::parse("audio_offset_ms = nope\nvideo_offset_ms = 0\n").has_value());

    std::cout << "GitarGame calibration profile tests passed\n";
    return 0;
}
