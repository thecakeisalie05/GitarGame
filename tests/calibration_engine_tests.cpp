#include "calibration_engine.h"

#include <cassert>
#include <cmath>
#include <iostream>
#include <vector>

static bool near(double a, double b, double eps = 0.001) {
    return std::abs(a - b) <= eps;
}

int main() {
    {
        const std::vector<double> samples = {41, 39, 40, 42, 40, 38, 250, 41, 39, 40};
        const auto estimate = ggcal::robustEstimate(samples);
        assert(estimate.valid);
        assert(estimate.used == 9);
        assert(near(estimate.centerMs, 40.0));
        assert(estimate.spreadMs <= 2.0);
    }

    {
        const std::vector<double> audio = {31, 29, 30, 32, 30, 28, 31, 30};
        const std::vector<double> video = {56, 54, 55, 57, 55, 53, 56, 55};
        const auto result = ggcal::computeAv(audio, video);
        assert(result.audio.valid);
        assert(result.video.valid);
        assert(near(result.audioOffsetMs, 30.0));
        assert(near(result.videoOffsetMs, 55.0));
        assert(near(result.videoMinusAudioMs, 25.0));
    }

    {
        const auto estimate = ggcal::robustEstimate({10, 20, 30});
        assert(!estimate.valid);
        assert(std::string(ggcal::qualityLabel(estimate)) == "Not enough samples");
    }

    std::cout << "GitarGame calibration engine tests passed\n";
    return 0;
}
