#include "midi_chart.h"

#include <cassert>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

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

static void event(std::vector<unsigned char>& track, uint32_t delta, std::initializer_list<unsigned char> bytes) {
    vlq(track, delta);
    track.insert(track.end(), bytes.begin(), bytes.end());
}

static void appendTrack(std::vector<unsigned char>& midi, const std::vector<unsigned char>& track) {
    midi.insert(midi.end(), {'M', 'T', 'r', 'k'});
    be32(midi, static_cast<uint32_t>(track.size()));
    midi.insert(midi.end(), track.begin(), track.end());
}

static fs::path writeFixture() {
    const fs::path dir = fs::temp_directory_path() / "gitargame-midi-sustain-tests";
    fs::create_directories(dir);
    fs::remove(dir / "song.ini");

    std::vector<unsigned char> midi{'M', 'T', 'h', 'd'};
    be32(midi, 6);
    be16(midi, 1);
    be16(midi, 2);
    be16(midi, 480);

    std::vector<unsigned char> conductor;
    event(conductor, 0, {0xff, 0x51, 0x03, 0x07, 0xa1, 0x20});
    event(conductor, 0, {0xff, 0x2f, 0x00});
    appendTrack(midi, conductor);

    std::vector<unsigned char> guitar;
    const std::string name = "PART GUITAR";
    vlq(guitar, 0);
    guitar.insert(guitar.end(), {0xff, 0x03, static_cast<unsigned char>(name.size())});
    guitar.insert(guitar.end(), name.begin(), name.end());

    // Ordinary DAW-authored gem: non-zero MIDI duration, but shorter than the
    // Clone Hero default cutoff (480/3 + 1 = 161 ticks), so it is NOT a sustain.
    event(guitar, 0, {0x90, 96, 100});
    event(guitar, 60, {0x80, 96, 0});

    // A real long sustain must survive the cutoff.
    event(guitar, 420, {0x90, 97, 100});
    event(guitar, 240, {0x80, 97, 0});
    event(guitar, 0, {0xff, 0x2f, 0x00});
    appendTrack(midi, guitar);

    const fs::path path = dir / "notes.mid";
    std::ofstream out(path, std::ios::binary);
    out.write(reinterpret_cast<const char*>(midi.data()), static_cast<std::streamsize>(midi.size()));
    return path;
}

int main() {
    const fs::path midi = writeFixture();
    std::string error;

    auto chart = midichart::parse(midi, error);
    assert(chart);
    assert(chart->resolution == 480);
    assert(chart->notes.size() == 2);
    assert(chart->notes[0].maxSustainTicks == 0);
    assert(chart->notes[0].sustain == 0.0);
    assert(chart->notes[1].maxSustainTicks == 240);
    assert(chart->notes[1].sustain > 0.0);

    // Verify the standard song.ini override is honored.
    {
        std::ofstream ini(midi.parent_path() / "song.ini");
        ini << "[song]\n";
        ini << "sustain_cutoff_threshold = 30\n";
    }
    auto overridden = midichart::parse(midi, error);
    assert(overridden);
    assert(overridden->notes[0].maxSustainTicks == 60);
    assert(overridden->notes[0].sustain > 0.0);
    fs::remove(midi.parent_path() / "song.ini");

    std::cout << "GitarGame MIDI sustain cutoff tests passed\n";
    return 0;
}
