#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <limits>
#include <map>
#include <optional>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

enum class ChartIssueSeverity { Info, Warning, Error };

struct ChartIssue {
    ChartIssueSeverity severity = ChartIssueSeverity::Info;
    std::string message;
    int line = 0;
};

struct TempoEvent {
    int64_t tick = 0;
    double bpm = 120.0;
    double time = 0.0;
};

struct TimeSignatureEvent {
    int64_t tick = 0;
    int numerator = 4;
    int denominator = 4;
    double time = 0.0;
};

struct StarPowerPhrase {
    int64_t tick = 0;
    int64_t lengthTicks = 0;
    double startTime = 0.0;
    double endTime = 0.0;
};

struct Note {
    int64_t tick = 0;
    double time = 0.0;
    double sustain = 0.0;
    int64_t maxSustainTicks = 0;
    std::array<int64_t, 5> laneSustainTicks{};
    std::array<double, 5> laneSustain{};
    uint8_t mask = 0;
    bool open = false;
    bool hopo = false;
    bool tap = false;
    bool forced = false;
    bool hit = false;
    bool missed = false;
    int starPhrase = -1;
    double judgedAt = -1000.0;
    double hitErrorMs = 0.0;
};

struct ChartData {
    int resolution = 192;
    bool resolutionExplicit = false;
    bool hadUtf8Bom = false;
    double offsetSeconds = 0.0;
    std::string selectedSection = "ExpertSingle";
    std::vector<TempoEvent> tempos;
    std::vector<TimeSignatureEvent> timeSignatures;
    std::vector<StarPowerPhrase> starPowerPhrases;
    std::vector<Note> notes;
    std::vector<ChartIssue> issues;
};

namespace chartcompat {

inline std::string trimCopy(std::string s) {
    const auto first = std::find_if_not(s.begin(), s.end(), [](unsigned char c) { return std::isspace(c) != 0; });
    const auto last = std::find_if_not(s.rbegin(), s.rend(), [](unsigned char c) { return std::isspace(c) != 0; }).base();
    if (first >= last) return {};
    return std::string(first, last);
}

inline std::string lowerCopy(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return s;
}

inline std::string unquoteCopy(std::string s) {
    s = trimCopy(std::move(s));
    if (s.size() >= 2 && ((s.front() == '"' && s.back() == '"') || (s.front() == '\'' && s.back() == '\''))) {
        s = s.substr(1, s.size() - 2);
    }
    return s;
}

inline void issue(ChartData& chart, ChartIssueSeverity severity, std::string message, int line = 0) {
    chart.issues.push_back({severity, std::move(message), line});
}

inline bool isSupportedFiveFretSection(const std::string& section) {
    static const std::array<const char*, 20> names = {
        "expertsingle", "hardsingle", "mediumsingle", "easysingle",
        "expertdoubleguitar", "harddoubleguitar", "mediumdoubleguitar", "easydoubleguitar",
        "expertdoublebass", "harddoublebass", "mediumdoublebass", "easydoublebass",
        "expertdoublerhythm", "harddoublerhythm", "mediumdoublerhythm", "easydoublerhythm",
        "expertkeyboard", "hardkeyboard", "mediumkeyboard", "easykeyboard"
    };
    return std::find(names.begin(), names.end(), section) != names.end();
}

inline std::string chooseFiveFretSection(const std::map<std::string, std::vector<std::pair<int, std::string>>>& tracks) {
    static const std::array<const char*, 20> priority = {
        "expertsingle", "hardsingle", "mediumsingle", "easysingle",
        "expertdoubleguitar", "expertdoublebass", "expertdoublerhythm", "expertkeyboard",
        "harddoubleguitar", "harddoublebass", "harddoublerhythm", "hardkeyboard",
        "mediumdoubleguitar", "mediumdoublebass", "mediumdoublerhythm", "mediumkeyboard",
        "easydoubleguitar", "easydoublebass", "easydoublerhythm", "easykeyboard"
    };
    for (const char* name : priority) if (tracks.contains(name)) return name;
    return {};
}

inline std::string displaySectionName(const std::string& lowerName) {
    static const std::map<std::string, std::string> names = {
        {"expertsingle", "ExpertSingle"}, {"hardsingle", "HardSingle"},
        {"mediumsingle", "MediumSingle"}, {"easysingle", "EasySingle"},
        {"expertdoubleguitar", "ExpertDoubleGuitar"}, {"expertdoublebass", "ExpertDoubleBass"},
        {"expertdoublerhythm", "ExpertDoubleRhythm"}, {"expertkeyboard", "ExpertKeyboard"},
        {"harddoubleguitar", "HardDoubleGuitar"}, {"harddoublebass", "HardDoubleBass"},
        {"harddoublerhythm", "HardDoubleRhythm"}, {"hardkeyboard", "HardKeyboard"},
        {"mediumdoubleguitar", "MediumDoubleGuitar"}, {"mediumdoublebass", "MediumDoubleBass"},
        {"mediumdoublerhythm", "MediumDoubleRhythm"}, {"mediumkeyboard", "MediumKeyboard"},
        {"easydoubleguitar", "EasyDoubleGuitar"}, {"easydoublebass", "EasyDoubleBass"},
        {"easydoublerhythm", "EasyDoubleRhythm"}, {"easykeyboard", "EasyKeyboard"}
    };
    const auto it = names.find(lowerName);
    return it == names.end() ? lowerName : it->second;
}

inline void normalizeTempoMap(ChartData& chart) {
    std::stable_sort(chart.tempos.begin(), chart.tempos.end(), [](const TempoEvent& a, const TempoEvent& b) { return a.tick < b.tick; });
    std::vector<TempoEvent> collapsed;
    for (const auto& tempo : chart.tempos) {
        if (!std::isfinite(tempo.bpm) || tempo.bpm <= 0.0) {
            issue(chart, ChartIssueSeverity::Warning, "Ignored a non-positive or non-finite BPM event.");
            continue;
        }
        if (!collapsed.empty() && collapsed.back().tick == tempo.tick) collapsed.back() = tempo;
        else collapsed.push_back(tempo);
    }
    chart.tempos = std::move(collapsed);
    if (chart.tempos.empty() || chart.tempos.front().tick != 0) {
        chart.tempos.insert(chart.tempos.begin(), {0, 120.0, 0.0});
        issue(chart, ChartIssueSeverity::Warning, "No BPM event at tick 0; inserted 120 BPM fallback.");
    }
}

inline double ticksToSecondsAtResolution(int64_t tick, int resolution, const std::vector<TempoEvent>& tempos) {
    if (resolution <= 0) return 0.0;
    if (tempos.empty()) return (static_cast<double>(tick) / static_cast<double>(resolution)) * 0.5;
    double seconds = 0.0;
    int64_t previousTick = 0;
    double bpm = 120.0;
    size_t index = 0;
    if (tempos.front().tick == 0) {
        bpm = tempos.front().bpm;
        index = 1;
    }
    for (; index < tempos.size() && tempos[index].tick <= tick; ++index) {
        const int64_t deltaTicks = tempos[index].tick - previousTick;
        seconds += (static_cast<double>(deltaTicks) / static_cast<double>(resolution)) * (60.0 / bpm);
        previousTick = tempos[index].tick;
        bpm = tempos[index].bpm;
    }
    seconds += (static_cast<double>(tick - previousTick) / static_cast<double>(resolution)) * (60.0 / bpm);
    return seconds;
}

inline int playableGemCount(const Note& note) {
    return note.open ? 1 : std::popcount(static_cast<unsigned int>(note.mask));
}

inline int noteIdentity(const Note& note) {
    if (note.open) return 1 << 7;
    return static_cast<int>(note.mask);
}

inline void rebuildTiming(ChartData& chart) {
    normalizeTempoMap(chart);
    for (auto& tempo : chart.tempos) tempo.time = ticksToSecondsAtResolution(tempo.tick, chart.resolution, chart.tempos);
    for (auto& signature : chart.timeSignatures) signature.time = ticksToSecondsAtResolution(signature.tick, chart.resolution, chart.tempos);
    for (auto& phrase : chart.starPowerPhrases) {
        phrase.startTime = ticksToSecondsAtResolution(phrase.tick, chart.resolution, chart.tempos);
        phrase.endTime = ticksToSecondsAtResolution(phrase.tick + std::max<int64_t>(0, phrase.lengthTicks), chart.resolution, chart.tempos);
    }
    for (auto& note : chart.notes) {
        note.time = ticksToSecondsAtResolution(note.tick, chart.resolution, chart.tempos);
        note.sustain = 0.0;
        for (int lane = 0; lane < 5; ++lane) {
            if ((note.mask & (1U << lane)) == 0) { note.laneSustain[lane] = 0.0; continue; }
            const int64_t endTick = note.tick + std::max<int64_t>(0, note.laneSustainTicks[lane]);
            note.laneSustain[lane] = std::max(0.0, ticksToSecondsAtResolution(endTick, chart.resolution, chart.tempos) - note.time);
            note.sustain = std::max(note.sustain, note.laneSustain[lane]);
        }
        if (note.open && note.maxSustainTicks > 0) {
            note.sustain = std::max(0.0, ticksToSecondsAtResolution(note.tick + note.maxSustainTicks, chart.resolution, chart.tempos) - note.time);
        }
        note.starPhrase = -1;
        for (size_t i = 0; i < chart.starPowerPhrases.size(); ++i) {
            const auto& phrase = chart.starPowerPhrases[i];
            if (note.tick >= phrase.tick && note.tick <= phrase.tick + phrase.lengthTicks) {
                note.starPhrase = static_cast<int>(i);
                break;
            }
        }
    }

    const int64_t hopoThreshold = std::max<int64_t>(1, static_cast<int64_t>(std::floor((65.0 / 192.0) * chart.resolution)));
    for (auto& note : chart.notes) note.hopo = note.tap;
    for (size_t i = 1; i < chart.notes.size(); ++i) {
        auto& note = chart.notes[i];
        const auto& previous = chart.notes[i - 1];
        const bool singleCurrent = playableGemCount(note) == 1;
        const bool singlePrevious = playableGemCount(previous) == 1;
        const bool different = noteIdentity(note) != noteIdentity(previous);
        const bool closeEnough = note.tick >= previous.tick && (note.tick - previous.tick) <= hopoThreshold;
        const bool naturalHopo = singleCurrent && singlePrevious && different && closeEnough;
        note.hopo = note.tap ? true : (note.forced ? !naturalHopo : naturalHopo);
    }
}

inline double chartEndTime(const ChartData& chart) {
    double end = 0.0;
    for (const auto& note : chart.notes) end = std::max(end, note.time + note.sustain);
    return end;
}

inline double tempoAtSeconds(const ChartData& chart, double seconds) {
    double bpm = chart.tempos.empty() ? 120.0 : chart.tempos.front().bpm;
    for (const auto& tempo : chart.tempos) {
        if (tempo.time > seconds) break;
        bpm = tempo.bpm;
    }
    return bpm;
}

inline double measureQuarterNotesAtSeconds(const ChartData& chart, double seconds) {
    int numerator = 4;
    int denominator = 4;
    for (const auto& signature : chart.timeSignatures) {
        if (signature.time > seconds) break;
        numerator = signature.numerator;
        denominator = signature.denominator;
    }
    return static_cast<double>(std::max(1, numerator)) * 4.0 / static_cast<double>(std::max(1, denominator));
}

inline double starPowerDrainPerSecond(const ChartData& chart, double seconds) {
    const double bpm = std::max(1.0, tempoAtSeconds(chart, seconds));
    const double quartersPerMeasure = std::max(0.25, measureQuarterNotesAtSeconds(chart, seconds));
    return (bpm / 60.0) / (quartersPerMeasure * 8.0);
}

} // namespace chartcompat

inline double tickToSeconds(int64_t tick, int resolution, const std::vector<TempoEvent>& tempos) {
    return chartcompat::ticksToSecondsAtResolution(tick, resolution, tempos);
}

inline std::optional<ChartData> parseChart(const std::filesystem::path& file, std::string& error) {
    std::ifstream in(file, std::ios::binary);
    if (!in) { error = "Could not open notes.chart"; return std::nullopt; }

    ChartData chart;
    std::string section;
    std::string line;
    int lineNumber = 0;
    bool firstLine = true;
    std::map<std::string, std::vector<std::pair<int, std::string>>> tracks;

    while (std::getline(in, line)) {
        ++lineNumber;
        if (firstLine) {
            firstLine = false;
            if (line.size() >= 3 && static_cast<unsigned char>(line[0]) == 0xEF && static_cast<unsigned char>(line[1]) == 0xBB && static_cast<unsigned char>(line[2]) == 0xBF) {
                line.erase(0, 3);
                chart.hadUtf8Bom = true;
                chartcompat::issue(chart, ChartIssueSeverity::Info, "UTF-8 BOM detected and normalized.", lineNumber);
            }
        }
        line = chartcompat::trimCopy(std::move(line));
        if (line.empty() || line == "{" || line == "}") continue;
        if (line.front() == '[' && line.back() == ']') {
            section = chartcompat::lowerCopy(chartcompat::trimCopy(line.substr(1, line.size() - 2)));
            continue;
        }

        if (section == "song") {
            const auto pos = line.find('=');
            if (pos == std::string::npos) continue;
            const std::string key = chartcompat::lowerCopy(chartcompat::trimCopy(line.substr(0, pos)));
            const std::string value = chartcompat::unquoteCopy(line.substr(pos + 1));
            if (key == "resolution") {
                try {
                    const int parsed = std::stoi(value);
                    if (parsed > 0 && parsed <= 9600) {
                        chart.resolution = parsed;
                        chart.resolutionExplicit = true;
                    } else chartcompat::issue(chart, ChartIssueSeverity::Warning, "Invalid Resolution value; using 192.", lineNumber);
                } catch (...) { chartcompat::issue(chart, ChartIssueSeverity::Warning, "Could not parse Resolution; using 192.", lineNumber); }
            } else if (key == "offset") {
                try { chart.offsetSeconds = std::stod(value); }
                catch (...) { chartcompat::issue(chart, ChartIssueSeverity::Warning, "Could not parse chart Offset; using 0.", lineNumber); }
            }
            continue;
        }

        if (section == "synctrack") {
            std::istringstream stream(line);
            int64_t tick = 0;
            char equals = 0;
            std::string type;
            if (!(stream >> tick >> equals >> type) || equals != '=') {
                chartcompat::issue(chart, ChartIssueSeverity::Warning, "Malformed SyncTrack event ignored.", lineNumber);
                continue;
            }
            type = chartcompat::lowerCopy(type);
            if (type == "b") {
                int64_t raw = 0;
                if (stream >> raw && raw > 0) chart.tempos.push_back({tick, static_cast<double>(raw) / 1000.0, 0.0});
                else chartcompat::issue(chart, ChartIssueSeverity::Warning, "Invalid BPM event ignored.", lineNumber);
            } else if (type == "ts") {
                int numerator = 4;
                int exponent = 2;
                if (stream >> numerator) {
                    if (!(stream >> exponent)) exponent = 2;
                    exponent = std::clamp(exponent, 0, 10);
                    chart.timeSignatures.push_back({tick, std::max(1, numerator), 1 << exponent, 0.0});
                }
            } else if (type == "a") {
                // Tempo anchors are editor metadata. They intentionally do not change playback timing.
            }
            continue;
        }

        if (chartcompat::isSupportedFiveFretSection(section)) tracks[section].push_back({lineNumber, line});
    }

    if (!chart.resolutionExplicit) chartcompat::issue(chart, ChartIssueSeverity::Warning, "Resolution was missing; defaulted to 192.");
    chartcompat::normalizeTempoMap(chart);
    if (chart.timeSignatures.empty() || chart.timeSignatures.front().tick != 0) chart.timeSignatures.insert(chart.timeSignatures.begin(), {0, 4, 4, 0.0});
    std::stable_sort(chart.timeSignatures.begin(), chart.timeSignatures.end(), [](const auto& a, const auto& b) { return a.tick < b.tick; });

    const std::string chosen = chartcompat::chooseFiveFretSection(tracks);
    if (chosen.empty()) { error = "No supported five-fret guitar track found in notes.chart"; return std::nullopt; }
    chart.selectedSection = chartcompat::displaySectionName(chosen);
    if (chosen != "expertsingle") chartcompat::issue(chart, ChartIssueSeverity::Warning, "ExpertSingle not found; using " + chart.selectedSection + ".");

    struct TempNote {
        uint8_t mask = 0;
        bool open = false;
        bool forced = false;
        bool tap = false;
        std::array<int64_t, 5> laneSustain{};
        int64_t openSustain = 0;
    };
    std::map<int64_t, TempNote> grouped;

    for (const auto& [sourceLine, text] : tracks.at(chosen)) {
        std::istringstream stream(text);
        int64_t tick = 0;
        char equals = 0;
        std::string type;
        if (!(stream >> tick >> equals >> type) || equals != '=') {
            chartcompat::issue(chart, ChartIssueSeverity::Warning, "Malformed instrument event ignored.", sourceLine);
            continue;
        }
        type = chartcompat::lowerCopy(type);
        if (type == "n") {
            int lane = -1;
            int64_t sustain = 0;
            if (!(stream >> lane >> sustain)) {
                chartcompat::issue(chart, ChartIssueSeverity::Warning, "Malformed note event ignored.", sourceLine);
                continue;
            }
            auto& temp = grouped[tick];
            sustain = std::max<int64_t>(0, sustain);
            if (lane >= 0 && lane <= 4) {
                temp.mask |= static_cast<uint8_t>(1U << lane);
                temp.laneSustain[lane] = std::max(temp.laneSustain[lane], sustain);
            } else if (lane == 5) temp.forced = true;
            else if (lane == 6) temp.tap = true;
            else if (lane == 7) { temp.open = true; temp.openSustain = std::max(temp.openSustain, sustain); }
        } else if (type == "s") {
            int phraseType = -1;
            int64_t length = 0;
            if (stream >> phraseType >> length) {
                if (phraseType == 2 && length >= 0) chart.starPowerPhrases.push_back({tick, length, 0.0, 0.0});
            }
        }
    }

    for (const auto& [tick, temp] : grouped) {
        if (temp.mask == 0 && !temp.open) continue; // Modifier-only ticks are not notes.
        Note note;
        note.tick = tick;
        note.mask = temp.mask;
        note.open = temp.open;
        note.forced = temp.forced;
        note.tap = temp.tap;
        note.laneSustainTicks = temp.laneSustain;
        note.maxSustainTicks = temp.open ? temp.openSustain : 0;
        for (const auto sustain : temp.laneSustain) note.maxSustainTicks = std::max(note.maxSustainTicks, sustain);
        if (note.open && note.mask != 0) {
            chartcompat::issue(chart, ChartIssueSeverity::Warning, "Open note and fretted note shared one tick; fretted chord kept.");
            note.open = false;
        }
        chart.notes.push_back(note);
    }

    std::sort(chart.notes.begin(), chart.notes.end(), [](const Note& a, const Note& b) { return a.tick < b.tick; });
    std::sort(chart.starPowerPhrases.begin(), chart.starPowerPhrases.end(), [](const auto& a, const auto& b) { return a.tick < b.tick; });
    chartcompat::rebuildTiming(chart);

    if (chart.notes.empty()) { error = "Selected guitar track contains no playable notes"; return std::nullopt; }

    for (size_t i = 1; i < chart.notes.size(); ++i) {
        if (chart.notes[i].time + 1e-9 < chart.notes[i - 1].time) {
            chartcompat::issue(chart, ChartIssueSeverity::Error, "Note timestamps are not monotonic after tempo conversion.");
            error = "Chart timing validation failed: non-monotonic note times";
            return std::nullopt;
        }
    }

    size_t denseWindowStart = 0;
    for (size_t i = 0; i < chart.notes.size(); ++i) {
        while (denseWindowStart < i && chart.notes[i].time - chart.notes[denseWindowStart].time > 1.0) ++denseWindowStart;
        if (i - denseWindowStart + 1 > 48) {
            chartcompat::issue(chart, ChartIssueSeverity::Warning, "Chart exceeds 48 note events per second in at least one one-second window.");
            break;
        }
    }

    error.clear();
    return chart;
}

inline bool verifyChartAgainstAudio(ChartData& chart, double audioLengthSeconds) {
    if (!(audioLengthSeconds > 0.0) || !std::isfinite(audioLengthSeconds)) {
        chartcompat::issue(chart, ChartIssueSeverity::Warning, "Audio duration unavailable; chart/audio length verification skipped.");
        return true;
    }

    double end = chartcompat::chartEndTime(chart);
    if (!chart.resolutionExplicit && !chart.notes.empty()) {
        const double initialRatio = end / audioLengthSeconds;
        if (initialRatio > 1.20 || initialRatio < 0.30) {
            static const std::array<int, 8> candidates = {48, 96, 192, 240, 384, 480, 768, 960};
            int bestResolution = chart.resolution;
            double bestScore = std::numeric_limits<double>::infinity();
            for (const int candidate : candidates) {
                const auto& last = chart.notes.back();
                const double candidateEnd = chartcompat::ticksToSecondsAtResolution(last.tick + last.maxSustainTicks, candidate, chart.tempos);
                const double ratio = candidateEnd / audioLengthSeconds;
                if (ratio < 0.35 || ratio > 1.15) continue;
                const double score = std::abs(ratio - 0.92);
                if (score < bestScore) { bestScore = score; bestResolution = candidate; }
            }
            if (bestResolution != chart.resolution) {
                chart.resolution = bestResolution;
                chartcompat::rebuildTiming(chart);
                end = chartcompat::chartEndTime(chart);
                chartcompat::issue(chart, ChartIssueSeverity::Warning, "Missing Resolution was auto-normalized to " + std::to_string(bestResolution) + " using audio-length sanity checking.");
            }
        }
    }

    const double ratio = end / audioLengthSeconds;
    if (end > audioLengthSeconds + std::max(8.0, audioLengthSeconds * 0.20)) {
        chartcompat::issue(chart, ChartIssueSeverity::Warning, "Chart extends well beyond the decoded audio duration (ratio " + std::to_string(ratio) + ").");
    }
    if (audioLengthSeconds > 30.0 && end < audioLengthSeconds * 0.25) {
        chartcompat::issue(chart, ChartIssueSeverity::Warning, "Playable chart is unusually short relative to the audio file.");
    }
    if (end > audioLengthSeconds * 3.0 + 10.0) {
        chartcompat::issue(chart, ChartIssueSeverity::Error, "Chart/audio duration mismatch is too large to play safely.");
        return false;
    }
    return true;
}

inline int chartWarningCount(const ChartData& chart) {
    return static_cast<int>(std::count_if(chart.issues.begin(), chart.issues.end(), [](const ChartIssue& issue) { return issue.severity == ChartIssueSeverity::Warning; }));
}

inline int chartErrorCount(const ChartData& chart) {
    return static_cast<int>(std::count_if(chart.issues.begin(), chart.issues.end(), [](const ChartIssue& issue) { return issue.severity == ChartIssueSeverity::Error; }));
}
