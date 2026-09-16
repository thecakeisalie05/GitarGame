#include <bit>
#include <cctype>
#include "chart_engine.h"
#include "highway_grid.h"
#include "midi_chart.h"

#include <cassert>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

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

static void be16(std::vector<unsigned char>& out, uint16_t v) {
    out.push_back(static_cast<unsigned char>((v >> 8) & 0xff));
    out.push_back(static_cast<unsigned char>(v & 0xff));
}
static void be32(std::vector<unsigned char>& out, uint32_t v) {
    out.push_back(static_cast<unsigned char>((v >> 24) & 0xff));
    out.push_back(static_cast<unsigned char>((v >> 16) & 0xff));
    out.push_back(static_cast<unsigned char>((v >> 8) & 0xff));
    out.push_back(static_cast<unsigned char>(v & 0xff));
}
static void vlq(std::vector<unsigned char>& out, uint32_t value) {
    unsigned char bytes[5]{};
    int count = 0;
    bytes[count++] = static_cast<unsigned char>(value & 0x7f);
    while ((value >>= 7) != 0) bytes[count++] = static_cast<unsigned char>(0x80 | (value & 0x7f));
    while (count-- > 0) out.push_back(bytes[count]);
}
static void midiEvent(std::vector<unsigned char>& track, uint32_t delta, std::initializer_list<unsigned char> bytes) {
    vlq(track, delta);
    track.insert(track.end(), bytes.begin(), bytes.end());
}
static void appendTrack(std::vector<unsigned char>& midi, const std::vector<unsigned char>& track) {
    midi.insert(midi.end(), {'M','T','r','k'});
    be32(midi, static_cast<uint32_t>(track.size()));
    midi.insert(midi.end(), track.begin(), track.end());
}
static fs::path writeMidiFixture() {
    std::vector<unsigned char> midi{'M','T','h','d'};
    be32(midi, 6); be16(midi, 1); be16(midi, 2); be16(midi, 480);

    std::vector<unsigned char> conductor;
    midiEvent(conductor, 0, {0xff, 0x51, 0x03, 0x07, 0xa1, 0x20}); // 120 BPM
    midiEvent(conductor, 0, {0xff, 0x58, 0x04, 0x04, 0x02, 0x18, 0x08});
    midiEvent(conductor, 480, {0xff, 0x51, 0x03, 0x03, 0xd0, 0x90}); // 240 BPM
    midiEvent(conductor, 0, {0xff, 0x2f, 0x00});
    appendTrack(midi, conductor);

    std::vector<unsigned char> guitar;
    const std::string name = "PART GUITAR";
    vlq(guitar, 0); guitar.insert(guitar.end(), {0xff, 0x03, static_cast<unsigned char>(name.size())}); guitar.insert(guitar.end(), name.begin(), name.end());
    midiEvent(guitar, 0, {0x90, 116, 100}); // star power 0..480
    midiEvent(guitar, 0, {0x90, 96, 100});  // green @ 0
    midiEvent(guitar, 60, {0x80, 96, 0});
    midiEvent(guitar, 60, {0x90, 102, 100}); // force strum @ 120
    midiEvent(guitar, 0, {0x90, 97, 100});
    midiEvent(guitar, 60, {0x80, 97, 0});
    midiEvent(guitar, 0, {0x80, 102, 0});
    midiEvent(guitar, 60, {0x90, 101, 100}); // force HOPO @ 240
    midiEvent(guitar, 0, {0x90, 97, 100});    // same fret as prior: naturally strum
    midiEvent(guitar, 60, {0x80, 97, 0});
    midiEvent(guitar, 0, {0x80, 101, 0});
    midiEvent(guitar, 60, {0x90, 104, 100}); // tap marker @ 360
    midiEvent(guitar, 0, {0x90, 99, 100});
    midiEvent(guitar, 60, {0x80, 99, 0});
    midiEvent(guitar, 0, {0x80, 104, 0});
    midiEvent(guitar, 60, {0x80, 116, 0});
    midiEvent(guitar, 480, {0x90, 100, 100}); // orange @ 960
    midiEvent(guitar, 60, {0x80, 100, 0});
    midiEvent(guitar, 0, {0xff, 0x2f, 0x00});
    appendTrack(midi, guitar);

    const fs::path dir = fs::temp_directory_path() / "gitargame-chart-tests";
    fs::create_directories(dir);
    const fs::path path = dir / "notes.mid";
    std::ofstream out(path, std::ios::binary);
    out.write(reinterpret_cast<const char*>(midi.data()), static_cast<std::streamsize>(midi.size()));
    return path;
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

    {
        std::string error;
        auto chart = midichart::parse(writeMidiFixture(), error);
        assert(chart);
        assert(chart->resolution == 480);
        assert(chart->selectedSection == "ExpertSingle (MIDI)");
        assert(chart->notes.size() == 5);
        assert(chart->starPowerPhrases.size() == 1);
        assert(!chart->notes[1].hopo); // naturally HOPO, explicit force-strum wins
        assert(chart->notes[2].hopo);  // same-fret repeat, explicit force-HOPO wins
        assert(chart->notes[3].tap && chart->notes[3].hopo);
        assert(near(chart->notes[4].time, 0.75)); // tempo change at tick 480
    }

    std::cout << "GitarGame chart compatibility tests passed\n";
    return 0;
}
