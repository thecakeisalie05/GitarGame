#include "gameplay_feedback.h"

#include <cassert>
#include <cmath>
#include <iostream>

static bool near(double a, double b, double eps = 1e-6) {
    return std::abs(a - b) <= eps;
}

int main() {
    assert(near(ggfeedback::rippleProgress(0.0), 0.0));
    assert(ggfeedback::rippleStrength(0.10) > 0.0);
    assert(near(ggfeedback::rippleStrength(1.0), 0.0));

    assert(ggfeedback::sustainHolding(true, 2.0, 1.0, 2.4, true));
    assert(!ggfeedback::sustainHolding(true, 2.0, 1.0, 2.4, false));
    assert(!ggfeedback::sustainHolding(false, 2.0, 1.0, 2.4, true));
    assert(!ggfeedback::sustainHolding(true, 2.0, 1.0, 3.2, true));

    assert(near(ggfeedback::previewStartSeconds(42000.0, 180.0), 42.0));
    assert(ggfeedback::previewStartSeconds(-1.0, 180.0) >= 5.0);
    assert(near(ggfeedback::previewEndSeconds(60000.0, 42.0, 180.0), 60.0));
    assert(ggfeedback::previewEndSeconds(-1.0, 42.0, 180.0) > 42.0);

    assert(!ggfeedback::songFinished(99.7, 100.0));
    assert(ggfeedback::songFinished(99.95, 100.0));

    std::cout << "GitarGame gameplay feedback tests passed\n";
    return 0;
}
