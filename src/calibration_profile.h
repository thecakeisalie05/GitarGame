#pragma once

#include <algorithm>
#include <optional>
#include <sstream>
#include <string>

namespace ggcalprofile {

struct Values {
    double audioOffsetMs = 0.0;
    double videoOffsetMs = 0.0;
    int version = 1;
};

inline std::string serialize(const Values& values) {
    std::ostringstream out;
    out << "# GitarGame persistent calibration\n";
    out << "version = " << values.version << "\n";
    out << "audio_offset_ms = " << values.audioOffsetMs << "\n";
    out << "video_offset_ms = " << values.videoOffsetMs << "\n";
    return out.str();
}

inline std::optional<Values> parse(const std::string& text) {
    Values values;
    bool sawAudio = false;
    bool sawVideo = false;
    std::istringstream in(text);
    std::string line;

    while (std::getline(in, line)) {
        const auto first = line.find_first_not_of(" \t\r");
        if (first == std::string::npos || line[first] == '#' || line[first] == ';') continue;
        const auto eq = line.find('=');
        if (eq == std::string::npos) continue;

        auto trim = [](std::string s) {
            const auto a = s.find_first_not_of(" \t\r");
            if (a == std::string::npos) return std::string{};
            const auto b = s.find_last_not_of(" \t\r");
            return s.substr(a, b - a + 1);
        };

        const std::string key = trim(line.substr(0, eq));
        const std::string value = trim(line.substr(eq + 1));
        try {
            if (key == "version") values.version = std::max(1, std::stoi(value));
            else if (key == "audio_offset_ms") {
                values.audioOffsetMs = std::clamp(std::stod(value), -500.0, 500.0);
                sawAudio = true;
            } else if (key == "video_offset_ms") {
                values.videoOffsetMs = std::clamp(std::stod(value), -500.0, 500.0);
                sawVideo = true;
            }
        } catch (...) {
            return std::nullopt;
        }
    }

    if (!sawAudio || !sawVideo) return std::nullopt;
    return values;
}

} // namespace ggcalprofile
