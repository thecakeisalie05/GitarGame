#pragma once

#include "chart_engine.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <map>
#include <optional>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace midichart {

struct Reader {
    std::vector<unsigned char> data;
    size_t pos = 0;

    bool have(size_t n) const { return pos + n <= data.size(); }
    uint8_t u8() { return have(1) ? data[pos++] : 0; }
    uint16_t be16() { const uint16_t a = u8(), b = u8(); return static_cast<uint16_t>((a << 8) | b); }
    uint32_t be32() { const uint32_t a = u8(), b = u8(), c = u8(), d = u8(); return (a << 24) | (b << 16) | (c << 8) | d; }
    uint32_t vlq(bool& ok) {
        uint32_t value = 0;
        ok = false;
        for (int i = 0; i < 4 && have(1); ++i) {
            const uint8_t byte = u8();
            value = (value << 7) | (byte & 0x7fU);
            if ((byte & 0x80U) == 0) { ok = true; return value; }
        }
        return value;
    }
};

struct Span { int64_t start = 0; int64_t end = 0; };
struct RawNote { int note = 0; int velocity = 0; int64_t start = 0; int64_t end = 0; };
struct TrackData { std::string name; std::vector<RawNote> notes; };

inline bool insideAny(const std::vector<Span>& spans, int64_t tick) {
    for (const auto& span : spans) if (tick >= span.start && tick < std::max(span.start + 1, span.end)) return true;
    return false;
}

// Rock Band/Guitar Hero MIDI gems normally have a small non-zero note length
// even when they are not intended to be sustains. Clone Hero-compatible
// consumers collapse these "baby sustains" to zero. The default cutoff is
// floor(resolution / 3) + 1 ticks, and song.ini can override it.
inline int readSustainCutoffTicks(const std::filesystem::path& midiFile, int resolution) {
    const int defaultCutoff = std::max(0, resolution / 3 + 1);
    std::ifstream in(midiFile.parent_path() / "song.ini");
    if (!in) return defaultCutoff;

    std::string section;
    std::string line;
    while (std::getline(in, line)) {
        line = chartcompat::trimCopy(line);
        if (line.empty() || line[0] == ';' || line[0] == '#') continue;
        if (line.front() == '[' && line.back() == ']') {
            section = chartcompat::lowerCopy(chartcompat::trimCopy(line.substr(1, line.size() - 2)));
            continue;
        }
        if (section != "song") continue;
        const auto equals = line.find('=');
        if (equals == std::string::npos) continue;
        const std::string key = chartcompat::lowerCopy(chartcompat::trimCopy(line.substr(0, equals)));
        if (key != "sustain_cutoff_threshold" && key != "sustain_cuttoff_threshold") continue;
        std::string value = chartcompat::trimCopy(line.substr(equals + 1));
        if (value.size() >= 2 && ((value.front() == '"' && value.back() == '"') || (value.front() == '\'' && value.back() == '\''))) {
            value = value.substr(1, value.size() - 2);
        }
        try { return std::max(0, std::stoi(value)); }
        catch (...) { return defaultCutoff; }
    }
    return defaultCutoff;
}

inline std::optional<ChartData> parse(const std::filesystem::path& file, std::string& error) {
    std::ifstream in(file, std::ios::binary);
    if (!in) { error = "Could not open notes.mid"; return std::nullopt; }
    Reader r;
    r.data.assign(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
    if (r.data.size() < 14 || std::string(reinterpret_cast<const char*>(r.data.data()), 4) != "MThd") {
        error = "Invalid MIDI header"; return std::nullopt;
    }
    r.pos = 4;
    const uint32_t headerLength = r.be32();
    if (headerLength < 6 || !r.have(headerLength)) { error = "Truncated MIDI header"; return std::nullopt; }
    const uint16_t format = r.be16();
    const uint16_t trackCount = r.be16();
    const uint16_t division = r.be16();
    if (headerLength > 6) r.pos += headerLength - 6;
    if (format > 1) { error = "Unsupported MIDI format (only type 0/1 are supported)"; return std::nullopt; }
    if ((division & 0x8000U) != 0 || division == 0) { error = "SMPTE-timed MIDI charts are not supported"; return std::nullopt; }

    ChartData chart;
    chart.resolution = static_cast<int>(division);
    chart.resolutionExplicit = true;
    chart.selectedSection = "ExpertSingle (MIDI)";
    const int sustainCutoffTicks = readSustainCutoffTicks(file, chart.resolution);
    std::vector<TrackData> tracks;

    for (uint16_t trackIndex = 0; trackIndex < trackCount; ++trackIndex) {
        if (!r.have(8)) { error = "Truncated MIDI track header"; return std::nullopt; }
        const std::string chunk(reinterpret_cast<const char*>(&r.data[r.pos]), 4); r.pos += 4;
        const uint32_t length = r.be32();
        if (!r.have(length)) { error = "Truncated MIDI track"; return std::nullopt; }
        const size_t endPos = r.pos + length;
        if (chunk != "MTrk") { r.pos = endPos; continue; }

        TrackData track;
        int64_t tick = 0;
        uint8_t running = 0;
        struct Active { int64_t start = 0; int velocity = 0; };
        std::unordered_map<int, std::vector<Active>> active;

        while (r.pos < endPos) {
            bool deltaOk = false;
            const uint32_t delta = r.vlq(deltaOk);
            if (!deltaOk || r.pos >= endPos) { r.pos = endPos; break; }
            tick += static_cast<int64_t>(delta);
            uint8_t status = r.u8();
            uint8_t firstData = 0;
            bool hasFirstData = false;
            if (status < 0x80U) {
                if (running == 0) { error = "Invalid MIDI running status"; return std::nullopt; }
                firstData = status; hasFirstData = true; status = running;
            } else if (status < 0xF0U) running = status;

            if (status == 0xFFU) {
                running = 0;
                if (r.pos >= endPos) break;
                const uint8_t type = r.u8();
                bool lenOk = false; const uint32_t len = r.vlq(lenOk);
                if (!lenOk || r.pos + len > endPos) { error = "Truncated MIDI meta event"; return std::nullopt; }
                const size_t payload = r.pos;
                if (type == 0x03U) {
                    track.name.assign(reinterpret_cast<const char*>(&r.data[payload]), len);
                } else if (type == 0x51U && len == 3) {
                    const uint32_t us = (static_cast<uint32_t>(r.data[payload]) << 16) |
                                        (static_cast<uint32_t>(r.data[payload + 1]) << 8) |
                                         static_cast<uint32_t>(r.data[payload + 2]);
                    if (us > 0) chart.tempos.push_back({tick, 60000000.0 / static_cast<double>(us), 0.0});
                } else if (type == 0x58U && len >= 2) {
                    const int numerator = std::max(1, static_cast<int>(r.data[payload]));
                    const int exponent = std::clamp(static_cast<int>(r.data[payload + 1]), 0, 10);
                    chart.timeSignatures.push_back({tick, numerator, 1 << exponent, 0.0});
                }
                r.pos += len;
                continue;
            }
            if (status == 0xF0U || status == 0xF7U) {
                running = 0;
                bool lenOk = false; const uint32_t len = r.vlq(lenOk);
                if (!lenOk || r.pos + len > endPos) { error = "Truncated MIDI SysEx"; return std::nullopt; }
                r.pos += len; continue;
            }

            const uint8_t kind = status & 0xF0U;
            const bool oneByte = kind == 0xC0U || kind == 0xD0U;
            uint8_t d1 = hasFirstData ? firstData : (r.pos < endPos ? r.u8() : 0);
            uint8_t d2 = 0;
            if (!oneByte) {
                if (r.pos >= endPos) { r.pos = endPos; break; }
                d2 = r.u8();
            }

            if (kind == 0x90U && d2 != 0) {
                active[d1].push_back({tick, d2});
            } else if (kind == 0x80U || (kind == 0x90U && d2 == 0)) {
                auto it = active.find(d1);
                if (it != active.end() && !it->second.empty()) {
                    const Active started = it->second.back();
                    it->second.pop_back();
                    track.notes.push_back({static_cast<int>(d1), started.velocity, started.start, std::max<int64_t>(started.start, tick)});
                }
            }
        }
        for (auto& [note, starts] : active) for (const auto& started : starts) track.notes.push_back({note, started.velocity, started.start, tick});
        tracks.push_back(std::move(track));
        r.pos = endPos;
    }

    chartcompat::normalizeTempoMap(chart);
    if (chart.timeSignatures.empty() || chart.timeSignatures.front().tick != 0) chart.timeSignatures.insert(chart.timeSignatures.begin(), {0, 4, 4, 0.0});
    std::stable_sort(chart.timeSignatures.begin(), chart.timeSignatures.end(), [](const auto& a, const auto& b) { return a.tick < b.tick; });

    const TrackData* guitar = nullptr;
    for (const auto& track : tracks) {
        std::string name = chartcompat::lowerCopy(chartcompat::trimCopy(track.name));
        if (name == "part guitar" || name == "t1 gems") { guitar = &track; break; }
    }
    if (!guitar) { error = "No PART GUITAR/T1 GEMS track found in notes.mid"; return std::nullopt; }

    std::vector<Span> forceHopo, forceStrum, taps, star;
    for (const auto& raw : guitar->notes) {
        const Span span{raw.start, raw.end};
        if (raw.note == 101) forceHopo.push_back(span);
        else if (raw.note == 102) forceStrum.push_back(span);
        else if (raw.note == 104) taps.push_back(span);
        else if (raw.note == 116) star.push_back(span);
    }
    for (const auto& span : star) chart.starPowerPhrases.push_back({span.start, std::max<int64_t>(0, span.end - span.start), 0.0, 0.0});

    struct TempNote {
        uint8_t mask = 0;
        bool open = false;
        std::array<int64_t, 5> laneSustain{};
        int64_t openSustain = 0;
        bool forceHopo = false;
        bool forceStrum = false;
        bool tap = false;
    };
    std::map<int64_t, TempNote> grouped;
    for (const auto& raw : guitar->notes) {
        if (raw.note < 95 || raw.note > 100) continue;
        auto& temp = grouped[raw.start];
        const int64_t rawSustain = std::max<int64_t>(0, raw.end - raw.start);
        const int64_t sustain = rawSustain > sustainCutoffTicks ? rawSustain : 0;
        if (raw.note == 95) { temp.open = true; temp.openSustain = std::max(temp.openSustain, sustain); }
        else {
            const int lane = raw.note - 96;
            temp.mask |= static_cast<uint8_t>(1U << lane);
            temp.laneSustain[static_cast<size_t>(lane)] = std::max(temp.laneSustain[static_cast<size_t>(lane)], sustain);
        }
        temp.forceHopo = insideAny(forceHopo, raw.start);
        temp.forceStrum = insideAny(forceStrum, raw.start);
        temp.tap = insideAny(taps, raw.start);
    }

    std::vector<std::pair<size_t, std::pair<bool, bool>>> explicitForces;
    for (const auto& [tick, temp] : grouped) {
        if (temp.mask == 0 && !temp.open) continue;
        Note note;
        note.tick = tick; note.mask = temp.mask; note.open = temp.open; note.tap = temp.tap;
        note.laneSustainTicks = temp.laneSustain;
        note.maxSustainTicks = temp.open ? temp.openSustain : 0;
        for (const auto sustain : temp.laneSustain) note.maxSustainTicks = std::max(note.maxSustainTicks, sustain);
        if (note.open && note.mask != 0) {
            chartcompat::issue(chart, ChartIssueSeverity::Warning, "MIDI open and fretted gems share a tick; fretted chord kept.");
            note.open = false;
        }
        const size_t index = chart.notes.size();
        chart.notes.push_back(note);
        explicitForces.push_back({index, {temp.forceHopo, temp.forceStrum}});
    }
    if (chart.notes.empty()) { error = "PART GUITAR contains no Expert five-fret notes"; return std::nullopt; }

    std::sort(chart.notes.begin(), chart.notes.end(), [](const Note& a, const Note& b) { return a.tick < b.tick; });
    std::sort(chart.starPowerPhrases.begin(), chart.starPowerPhrases.end(), [](const auto& a, const auto& b) { return a.tick < b.tick; });
    chartcompat::rebuildTiming(chart);

    // MIDI has explicit force-HOPO and force-strum lanes rather than .chart's toggle flag.
    // Re-apply those semantics after natural-HOPO inference using tick membership so sorting is harmless.
    for (auto& note : chart.notes) {
        if (insideAny(taps, note.tick)) { note.tap = true; note.hopo = true; }
        else if (insideAny(forceStrum, note.tick)) note.hopo = false;
        else if (insideAny(forceHopo, note.tick)) note.hopo = true;
    }

    chartcompat::issue(chart, ChartIssueSeverity::Info, "Loaded Rock Band/Guitar Hero MIDI PART GUITAR Expert chart.");
    chartcompat::issue(chart, ChartIssueSeverity::Info, "MIDI sustain cutoff: " + std::to_string(sustainCutoffTicks) + " ticks.");
    error.clear();
    return chart;
}

} // namespace midichart
