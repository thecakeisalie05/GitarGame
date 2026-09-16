#pragma once

#include "chart_engine.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

struct HighwayGridLine {
    int64_t tick = 0;
    double time = 0.0;
    bool measure = false;
    int beatInMeasure = 0;
    int measureIndex = 0;
};

inline std::vector<HighwayGridLine> buildHighwayGrid(const ChartData& chart) {
    std::vector<HighwayGridLine> lines;
    if (chart.resolution <= 0 || chart.notes.empty()) return lines;

    std::vector<TimeSignatureEvent> signatures = chart.timeSignatures;
    if (signatures.empty() || signatures.front().tick != 0) signatures.insert(signatures.begin(), {0, 4, 4, 0.0});
    std::stable_sort(signatures.begin(), signatures.end(), [](const auto& a, const auto& b) { return a.tick < b.tick; });

    int64_t finalTick = 0;
    for (const auto& note : chart.notes) finalTick = std::max(finalTick, note.tick + std::max<int64_t>(note.maxSustainTicks, 0));
    for (const auto& phrase : chart.starPowerPhrases) finalTick = std::max(finalTick, phrase.tick + std::max<int64_t>(phrase.lengthTicks, 0));
    finalTick += static_cast<int64_t>(chart.resolution) * 8;

    int globalMeasure = 0;
    int64_t lastAddedTick = std::numeric_limits<int64_t>::min();
    for (size_t segment = 0; segment < signatures.size(); ++segment) {
        const auto& signature = signatures[segment];
        const int numerator = std::max(1, signature.numerator);
        const int denominator = std::max(1, signature.denominator);
        const double beatTicks = static_cast<double>(chart.resolution) * 4.0 / static_cast<double>(denominator);
        if (!std::isfinite(beatTicks) || beatTicks <= 0.0) continue;

        const int64_t segmentStart = std::max<int64_t>(0, signature.tick);
        const int64_t segmentEnd = segment + 1 < signatures.size() ? signatures[segment + 1].tick : finalTick;
        if (segmentEnd < segmentStart) continue;

        int beatIndex = 0;
        int measureAtSegmentStart = globalMeasure;
        while (true) {
            const int64_t tick = segmentStart + static_cast<int64_t>(std::llround(static_cast<double>(beatIndex) * beatTicks));
            if (tick > segmentEnd || tick > finalTick) break;
            const int beatInMeasure = beatIndex % numerator;
            const bool isMeasure = beatInMeasure == 0;
            const int measureIndex = measureAtSegmentStart + beatIndex / numerator;

            if (tick != lastAddedTick) {
                lines.push_back({tick, chartcompat::ticksToSecondsAtResolution(tick, chart.resolution, chart.tempos), isMeasure, beatInMeasure, measureIndex});
                lastAddedTick = tick;
            } else if (isMeasure && !lines.empty()) {
                lines.back().measure = true;
                lines.back().beatInMeasure = 0;
                lines.back().measureIndex = measureIndex;
            }
            ++beatIndex;
            if (beatIndex > 1000000) break;
        }

        const int beatsCompleted = std::max(0, beatIndex - 1);
        globalMeasure = measureAtSegmentStart + beatsCompleted / numerator;
        if (segment + 1 < signatures.size()) ++globalMeasure;
    }

    std::stable_sort(lines.begin(), lines.end(), [](const HighwayGridLine& a, const HighwayGridLine& b) { return a.tick < b.tick; });
    lines.erase(std::unique(lines.begin(), lines.end(), [](const HighwayGridLine& a, const HighwayGridLine& b) { return a.tick == b.tick; }), lines.end());
    return lines;
}
