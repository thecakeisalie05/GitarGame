#include <bit>
#include <cctype>
#include "chart_engine.h"
#include "highway_grid.h"

#include <cassert>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>

namespace fs = std::filesystem;

static fs::path writeFixture(const std::string& name, const std::string& text, bool binary = false) {
    const fs::path dir = fs::temp_directory_path() / "gitargame-chart-tests";
    fs::create_directories(dir);
    const fs::path path = dir / name;
    std::ofstream out(path, binary ? std::ios::binary : std::ios::out);
    out << text;
    return path;
}

static bool near(double a, double b, double epsilon = 1e-6) {
    return std::abs(a - b) <= epsilon;
}

int main() {
    {
        const auto path = writeFixture("tempo.chart", R"([Song]
{
  Resolution = 192
}
[SyncTrack]
{
  0 = B 120000
  384 = B 240000
}
[ExpertSingle]
{
  0 = N 0 0
  576 = N 1 0
}
)");
        std::string error;
        auto chart = parseChart(path, error);
        assert(chart);
        assert(chart->resolution == 192);
        assert(chart->notes.size() == 2);
        assert(near(chart->notes[1].time, 1.25));
    }

    {
        std::string bom = "\xEF\xBB\xBF";
        bom += R"([Song]
{
  Resolution = 480
}
[SyncTrack]
{
  0 = B 120000
}
[ExpertSingle]
{
  480 = N 0 0
}
)";
        const auto path = writeFixture("bom.chart", bom, true);
        std::string error;
        auto chart = parseChart(path, error);
        assert(chart);
        assert(chart->hadUtf8Bom);
        assert(chart->resolutionExplicit);
        assert(chart->resolution == 480);
        assert(near(chart->notes.front().time, 0.5));
    }

    {
        const auto path = writeFixture("modifiers.chart", R"([Song]
{
  Resolution = 192
}
[SyncTrack]
{
  0 = B 120000
}
[ExpertSingle]
{
  0 = N 0 0
  0 = N 5 0
  65 = N 1 0
  65 = N 6 0
  131 = N 2 0
}
)");
        std::string error;
        auto chart = parseChart(path, error);
        assert(chart);
        assert(chart->notes.size() == 3);
        assert(chart->notes[0].forced);
        assert(chart->notes[1].tap);
        assert(chart->notes[1].hopo);
        assert(!chart->notes[2].hopo);
    }

    {
        const auto path = writeFixture("starpower.chart", R"([Song]
{
  Resolution = 192
}
[SyncTrack]
{
  0 = B 120000
}
[ExpertSingle]
{
  0 = S 2 384
  0 = N 0 96
  192 = N 1 96
  384 = N 2 0
}
)");
        std::string error;
        auto chart = parseChart(path, error);
        assert(chart);
        assert(chart->starPowerPhrases.size() == 1);
        assert(chart->notes[0].starPhrase == 0);
        assert(chart->notes[1].starPhrase == 0);
        assert(chart->notes[2].starPhrase == 0);
        assert(near(chart->starPowerPhrases[0].endTime, 1.0));
    }

    {
        const auto path = writeFixture("open.chart", R"([Song]
{
  Resolution = 192
}
[SyncTrack]
{
  0 = B 120000
}
[ExpertSingle]
{
  0 = N 7 192
  192 = N 0 0
}
)");
        std::string error;
        auto chart = parseChart(path, error);
        assert(chart);
        assert(chart->notes.size() == 2);
        assert(chart->notes[0].open);
        assert(near(chart->notes[0].sustain, 0.5));
    }

    {
        const auto path = writeFixture("fallback.chart", R"([Song]
{
  Resolution = 192
}
[SyncTrack]
{
  0 = B 120000
}
[HardSingle]
{
  0 = N 0 0
}
)");
        std::string error;
        auto chart = parseChart(path, error);
        assert(chart);
        assert(chart->selectedSection == "HardSingle");
        assert(chartWarningCount(*chart) >= 1);
    }

    {
        const auto path = writeFixture("grid.chart", R"([Song]
{
  Resolution = 192
}
[SyncTrack]
{
  0 = B 120000
  768 = TS 3 2
  1344 = B 240000
}
[ExpertSingle]
{
  0 = N 0 0
  1728 = N 1 0
}
)");
        std::string error;
        auto chart = parseChart(path, error);
        assert(chart);
        const auto grid = buildHighwayGrid(*chart);
        assert(!grid.empty());
        assert(grid[0].tick == 0 && grid[0].measure);
        bool sawMeasure768 = false;
        bool sawBeat960 = false;
        bool sawMeasure1344 = false;
        for (const auto& line : grid) {
            if (line.tick == 768 && line.measure) sawMeasure768 = true;
            if (line.tick == 960 && !line.measure) sawBeat960 = true;
            if (line.tick == 1344 && line.measure) sawMeasure1344 = true;
        }
        assert(sawMeasure768);
        assert(sawBeat960);
        assert(sawMeasure1344);
    }

    std::cout << "GitarGame chart compatibility tests passed\n";
    return 0;
}