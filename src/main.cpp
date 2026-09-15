#include "raylib.h"

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <Xinput.h>
#include <mmsystem.h>
#endif

#include <algorithm>
#include <atomic>
#include <bit>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <deque>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <mutex>
#include <optional>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

namespace fs = std::filesystem;
using Clock = std::chrono::steady_clock;

static std::string trim(std::string s) {
    auto notSpace = [](unsigned char c) { return !std::isspace(c); };
    s.erase(s.begin(), std::find_if(s.begin(), s.end(), notSpace));
    s.erase(std::find_if(s.rbegin(), s.rend(), notSpace).base(), s.end());
    return s;
}

static std::string lower(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return s;
}

static std::string unquote(std::string s) {
    s = trim(std::move(s));
    if (s.size() >= 2 && ((s.front() == '"' && s.back() == '"') || (s.front() == '\'' && s.back() == '\''))) {
        return s.substr(1, s.size() - 2);
    }
    return s;
}

static bool parseBool(const std::string& s, bool fallback) {
    const std::string v = lower(trim(s));
    if (v == "true" || v == "1" || v == "yes" || v == "on") return true;
    if (v == "false" || v == "0" || v == "no" || v == "off") return false;
    return fallback;
}

static int clampInt(int v, int lo, int hi) { return std::max(lo, std::min(v, hi)); }
static float clampFloat(float v, float lo, float hi) { return std::max(lo, std::min(v, hi)); }

static Color parseColor(std::string s, Color fallback) {
    s = trim(std::move(s));
    if (!s.empty() && s.front() == '#') s.erase(s.begin());
    if (s.size() != 6 && s.size() != 8) return fallback;
    try {
        unsigned long value = std::stoul(s, nullptr, 16);
        if (s.size() == 6) value = (value << 8U) | 0xFFU;
        return GetColor(static_cast<unsigned int>(value));
    } catch (...) {
        return fallback;
    }
}

static std::string colorString(Color c) {
    std::ostringstream out;
    out << '#' << std::hex << std::uppercase << std::setfill('0')
        << std::setw(2) << static_cast<int>(c.r)
        << std::setw(2) << static_cast<int>(c.g)
        << std::setw(2) << static_cast<int>(c.b);
    return out.str();
}

struct Settings {
    std::string songsDirectory = "songs";
    int windowWidth = 1280;
    int windowHeight = 720;
    bool fullscreen = false;
    bool vsync = false;
    int fpsCap = 500;
    int inputPollHz = 1000;
    float highwaySpeed = 1.0f;
    float highwayLength = 0.82f;
    float hitWindowMs = 120.0f;
    float audioOffsetMs = 0.0f;
    float masterVolume = 0.85f;
    std::string colorScheme = "classic";
    Color background = {16, 17, 22, 255};
    Color highway = {26, 29, 37, 255};
    Color hitLine = {245, 245, 245, 255};
    Color lanes[5] = {
        {53, 208, 79, 255}, {239, 51, 64, 255}, {255, 210, 63, 255}, {38, 132, 255, 255}, {255, 139, 44, 255}
    };
#ifdef _WIN32
    WORD green = XINPUT_GAMEPAD_A;
    WORD red = XINPUT_GAMEPAD_B;
    WORD yellow = XINPUT_GAMEPAD_Y;
    WORD blue = XINPUT_GAMEPAD_X;
    WORD orange = XINPUT_GAMEPAD_RIGHT_SHOULDER;
    WORD strumUp = XINPUT_GAMEPAD_DPAD_UP;
    WORD strumDown = XINPUT_GAMEPAD_DPAD_DOWN;
    WORD starPower = XINPUT_GAMEPAD_LEFT_SHOULDER;
    WORD start = XINPUT_GAMEPAD_START;
#else
    uint16_t green = 0x1000, red = 0x2000, yellow = 0x8000, blue = 0x4000, orange = 0x0200;
    uint16_t strumUp = 0x0001, strumDown = 0x0002, starPower = 0x0100, start = 0x0010;
#endif
};

static void applyPreset(Settings& s, const std::string& preset) {
    const std::string p = lower(preset);
    s.colorScheme = p;
    if (p == "neon") {
        s.background = {4, 6, 12, 255}; s.highway = {11, 14, 24, 255}; s.hitLine = {230, 250, 255, 255};
        s.lanes[0] = {0, 255, 140, 255}; s.lanes[1] = {255, 45, 95, 255}; s.lanes[2] = {255, 235, 40, 255}; s.lanes[3] = {40, 150, 255, 255}; s.lanes[4] = {255, 120, 15, 255};
    } else if (p == "pastel") {
        s.background = {22, 22, 28, 255}; s.highway = {35, 35, 45, 255}; s.hitLine = {245, 245, 250, 255};
        s.lanes[0] = {126, 224, 166, 255}; s.lanes[1] = {248, 139, 152, 255}; s.lanes[2] = {248, 223, 140, 255}; s.lanes[3] = {135, 181, 245, 255}; s.lanes[4] = {245, 177, 125, 255};
    } else if (p == "mono") {
        s.background = {12, 12, 12, 255}; s.highway = {28, 28, 28, 255}; s.hitLine = {245, 245, 245, 255};
        for (auto& lane : s.lanes) lane = {220, 220, 220, 255};
    } else {
        s.colorScheme = "classic";
        s.background = {16, 17, 22, 255}; s.highway = {26, 29, 37, 255}; s.hitLine = {245, 245, 245, 255};
        s.lanes[0] = {53, 208, 79, 255}; s.lanes[1] = {239, 51, 64, 255}; s.lanes[2] = {255, 210, 63, 255}; s.lanes[3] = {38, 132, 255, 255}; s.lanes[4] = {255, 139, 44, 255};
    }
}

#ifdef _WIN32
static const std::vector<std::pair<std::string, WORD>>& buttonNames() {
    static const std::vector<std::pair<std::string, WORD>> values = {
        {"DPAD_UP", XINPUT_GAMEPAD_DPAD_UP}, {"DPAD_DOWN", XINPUT_GAMEPAD_DPAD_DOWN},
        {"DPAD_LEFT", XINPUT_GAMEPAD_DPAD_LEFT}, {"DPAD_RIGHT", XINPUT_GAMEPAD_DPAD_RIGHT},
        {"START", XINPUT_GAMEPAD_START}, {"BACK", XINPUT_GAMEPAD_BACK},
        {"LS", XINPUT_GAMEPAD_LEFT_THUMB}, {"RS", XINPUT_GAMEPAD_RIGHT_THUMB},
        {"LB", XINPUT_GAMEPAD_LEFT_SHOULDER}, {"RB", XINPUT_GAMEPAD_RIGHT_SHOULDER},
        {"A", XINPUT_GAMEPAD_A}, {"B", XINPUT_GAMEPAD_B}, {"X", XINPUT_GAMEPAD_X}, {"Y", XINPUT_GAMEPAD_Y}
    };
    return values;
}

static WORD parseButton(std::string name, WORD fallback) {
    name = upper(trim(std::move(name)));
    for (const auto& [n, bit] : buttonNames()) if (n == name) return bit;
    if (name.rfind("0X", 0) == 0) {
        try { return static_cast<WORD>(std::stoul(name, nullptr, 16)); } catch (...) {}
    }
    return fallback;
}

static std::string buttonName(WORD bit) {
    for (const auto& [name, b] : buttonNames()) if (b == bit) return name;
    std::ostringstream out; out << "0x" << std::hex << std::uppercase << static_cast<unsigned int>(bit); return out.str();
}
#else
static std::string buttonName(uint16_t bit) { std::ostringstream out; out << "0x" << std::hex << bit; return out.str(); }
#endif

// C++ does not have a standard upper-copy helper.
static std::string upperCopy(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return static_cast<char>(std::toupper(c)); });
    return s;
}

#ifdef _WIN32
static WORD parseButtonSafe(std::string name, WORD fallback) {
    name = upperCopy(trim(std::move(name)));
    for (const auto& [n, bit] : buttonNames()) if (n == name) return bit;
    if (name.rfind("0X", 0) == 0) {
        try { return static_cast<WORD>(std::stoul(name, nullptr, 16)); } catch (...) {}
    }
    return fallback;
}
#endif

static bool loadConfig(const fs::path& path, Settings& s) {
    std::ifstream in(path);
    if (!in) return false;
    std::string line;
    while (std::getline(in, line)) {
        line = trim(line);
        if (line.empty() || line[0] == '#' || line[0] == ';' || line[0] == '[') continue;
        const auto pos = line.find('=');
        if (pos == std::string::npos) continue;
        const std::string key = lower(trim(line.substr(0, pos)));
        const std::string value = trim(line.substr(pos + 1));
        try {
            if (key == "songs_directory") s.songsDirectory = unquote(value);
            else if (key == "window_width") s.windowWidth = clampInt(std::stoi(value), 640, 7680);
            else if (key == "window_height") s.windowHeight = clampInt(std::stoi(value), 360, 4320);
            else if (key == "fullscreen") s.fullscreen = parseBool(value, s.fullscreen);
            else if (key == "vsync") s.vsync = parseBool(value, s.vsync);
            else if (key == "fps_cap") s.fpsCap = clampInt(std::stoi(value), 0, 2000);
            else if (key == "input_poll_hz") s.inputPollHz = clampInt(std::stoi(value), 60, 4000);
            else if (key == "highway_speed") s.highwaySpeed = clampFloat(std::stof(value), 0.25f, 5.0f);
            else if (key == "highway_length") s.highwayLength = clampFloat(std::stof(value), 0.35f, 0.95f);
            else if (key == "hit_window_ms") s.hitWindowMs = clampFloat(std::stof(value), 20.0f, 250.0f);
            else if (key == "audio_offset_ms") s.audioOffsetMs = clampFloat(std::stof(value), -500.0f, 500.0f);
            else if (key == "master_volume") s.masterVolume = clampFloat(std::stof(value), 0.0f, 1.0f);
            else if (key == "color_scheme") applyPreset(s, unquote(value));
            else if (key == "background_color") s.background = parseColor(value, s.background);
            else if (key == "highway_color") s.highway = parseColor(value, s.highway);
            else if (key == "hit_line_color") s.hitLine = parseColor(value, s.hitLine);
            else if (key == "lane_green") s.lanes[0] = parseColor(value, s.lanes[0]);
            else if (key == "lane_red") s.lanes[1] = parseColor(value, s.lanes[1]);
            else if (key == "lane_yellow") s.lanes[2] = parseColor(value, s.lanes[2]);
            else if (key == "lane_blue") s.lanes[3] = parseColor(value, s.lanes[3]);
            else if (key == "lane_orange") s.lanes[4] = parseColor(value, s.lanes[4]);
#ifdef _WIN32
            else if (key == "xinput_green") s.green = parseButtonSafe(value, s.green);
            else if (key == "xinput_red") s.red = parseButtonSafe(value, s.red);
            else if (key == "xinput_yellow") s.yellow = parseButtonSafe(value, s.yellow);
            else if (key == "xinput_blue") s.blue = parseButtonSafe(value, s.blue);
            else if (key == "xinput_orange") s.orange = parseButtonSafe(value, s.orange);
            else if (key == "xinput_strum_up") s.strumUp = parseButtonSafe(value, s.strumUp);
            else if (key == "xinput_strum_down") s.strumDown = parseButtonSafe(value, s.strumDown);
            else if (key == "xinput_star_power") s.starPower = parseButtonSafe(value, s.starPower);
            else if (key == "xinput_start") s.start = parseButtonSafe(value, s.start);
#endif
        } catch (...) {
            std::cerr << "Ignoring invalid config value: " << key << " = " << value << '\n';
        }
    }
    return true;
}

static void saveConfig(const fs::path& path, const Settings& s) {
    std::ofstream out(path, std::ios::trunc);
    if (!out) return;
    out << "# GitarGame configuration\n\n[paths]\n";
    out << "songs_directory = " << s.songsDirectory << "\n\n[video]\n";
    out << "window_width = " << s.windowWidth << "\nwindow_height = " << s.windowHeight << "\n";
    out << "fullscreen = " << (s.fullscreen ? "true" : "false") << "\nvsync = " << (s.vsync ? "true" : "false") << "\n";
    out << "fps_cap = " << s.fpsCap << "\n\n[input]\ninput_poll_hz = " << s.inputPollHz << "\n";
#ifdef _WIN32
    out << "xinput_green = " << buttonName(s.green) << "\n";
    out << "xinput_red = " << buttonName(s.red) << "\n";
    out << "xinput_yellow = " << buttonName(s.yellow) << "\n";
    out << "xinput_blue = " << buttonName(s.blue) << "\n";
    out << "xinput_orange = " << buttonName(s.orange) << "\n";
    out << "xinput_strum_up = " << buttonName(s.strumUp) << "\n";
    out << "xinput_strum_down = " << buttonName(s.strumDown) << "\n";
    out << "xinput_star_power = " << buttonName(s.starPower) << "\n";
    out << "xinput_start = " << buttonName(s.start) << "\n";
#endif
    out << "\n[gameplay]\nhighway_speed = " << s.highwaySpeed << "\nhighway_length = " << s.highwayLength << "\n";
    out << "hit_window_ms = " << s.hitWindowMs << "\naudio_offset_ms = " << s.audioOffsetMs << "\nmaster_volume = " << s.masterVolume << "\n";
    out << "\n[appearance]\ncolor_scheme = " << s.colorScheme << "\n";
    out << "background_color = " << colorString(s.background) << "\nhighway_color = " << colorString(s.highway) << "\nhit_line_color = " << colorString(s.hitLine) << "\n";
    out << "lane_green = " << colorString(s.lanes[0]) << "\nlane_red = " << colorString(s.lanes[1]) << "\nlane_yellow = " << colorString(s.lanes[2]) << "\n";
    out << "lane_blue = " << colorString(s.lanes[3]) << "\nlane_orange = " << colorString(s.lanes[4]) << "\n";
}

struct SongInfo {
    fs::path directory;
    std::string name;
    std::string artist;
    float delayMs = 0.0f;
};

static SongInfo readSongInfo(const fs::path& dir) {
    SongInfo song;
    song.directory = dir;
    song.name = dir.filename().string();
    std::ifstream in(dir / "song.ini");
    std::string line;
    while (std::getline(in, line)) {
        const auto p = line.find('=');
        if (p == std::string::npos) continue;
        const std::string key = lower(trim(line.substr(0, p)));
        const std::string value = unquote(line.substr(p + 1));
        if (key == "name" && !value.empty()) song.name = value;
        else if (key == "artist") song.artist = value;
        else if (key == "delay") { try { song.delayMs = std::stof(value); } catch (...) {} }
    }
    return song;
}

static std::vector<SongInfo> scanSongs(const fs::path& root) {
    std::vector<SongInfo> songs;
    std::error_code ec;
    if (!fs::exists(root, ec)) fs::create_directories(root, ec);
    if (fs::exists(root / "notes.chart", ec)) songs.push_back(readSongInfo(root));
    fs::recursive_directory_iterator it(root, fs::directory_options::skip_permission_denied, ec), end;
    for (; !ec && it != end; it.increment(ec)) {
        if (!it->is_regular_file(ec)) continue;
        if (lower(it->path().filename().string()) == "notes.chart") songs.push_back(readSongInfo(it->path().parent_path()));
    }
    std::sort(songs.begin(), songs.end(), [](const auto& a, const auto& b) {
        if (lower(a.artist) == lower(b.artist)) return lower(a.name) < lower(b.name);
        return lower(a.artist) < lower(b.artist);
    });
    songs.erase(std::unique(songs.begin(), songs.end(), [](const auto& a, const auto& b) { return a.directory == b.directory; }), songs.end());
    return songs;
}

struct TempoEvent { int64_t tick = 0; double bpm = 120.0; };
struct Note {
    int64_t tick = 0;
    double time = 0.0;
    double sustain = 0.0;
    uint8_t mask = 0;
    bool hopo = false;
    bool tap = false;
    bool forced = false;
    bool hit = false;
    bool missed = false;
};

struct ChartData {
    int resolution = 192;
    std::vector<TempoEvent> tempos;
    std::vector<Note> notes;
};

static double tickToSeconds(int64_t tick, int resolution, const std::vector<TempoEvent>& tempos) {
    if (tempos.empty()) return (static_cast<double>(tick) / resolution) * 0.5;
    double seconds = 0.0;
    int64_t prevTick = 0;
    double bpm = tempos.front().tick == 0 ? tempos.front().bpm : 120.0;
    size_t i = tempos.front().tick == 0 ? 1 : 0;
    for (; i < tempos.size() && tempos[i].tick <= tick; ++i) {
        const int64_t dt = tempos[i].tick - prevTick;
        seconds += (static_cast<double>(dt) / resolution) * (60.0 / bpm);
        prevTick = tempos[i].tick;
        bpm = tempos[i].bpm;
    }
    seconds += (static_cast<double>(tick - prevTick) / resolution) * (60.0 / bpm);
    return seconds;
}

static std::optional<ChartData> parseChart(const fs::path& file, std::string& error) {
    std::ifstream in(file);
    if (!in) { error = "Could not open notes.chart"; return std::nullopt; }
    ChartData chart;
    std::string section;
    std::string line;
    struct TempNote { uint8_t mask = 0; int64_t sustainTicks = 0; bool forced = false; bool tap = false; };
    std::map<int64_t, TempNote> tempNotes;
    while (std::getline(in, line)) {
        line = trim(line);
        if (line.empty() || line[0] == '{' || line[0] == '}') continue;
        if (line.front() == '[' && line.back() == ']') { section = line.substr(1, line.size() - 2); continue; }
        if (section == "Song") {
            const auto p = line.find('=');
            if (p != std::string::npos && lower(trim(line.substr(0, p))) == "resolution") {
                try { chart.resolution = std::max(1, std::stoi(trim(line.substr(p + 1)))); } catch (...) {}
            }
        } else if (section == "SyncTrack") {
            std::istringstream ss(line);
            int64_t tick = 0; char eq = 0; std::string type; int value = 0;
            if (ss >> tick >> eq >> type >> value) {
                if (type == "B") chart.tempos.push_back({tick, value / 1000.0});
            }
        } else if (section == "ExpertSingle") {
            std::istringstream ss(line);
            int64_t tick = 0, sustain = 0; char eq = 0; std::string type; int lane = -1;
            if (ss >> tick >> eq >> type >> lane >> sustain) {
                if (type != "N") continue;
                auto& t = tempNotes[tick];
                if (lane >= 0 && lane <= 4) {
                    t.mask |= static_cast<uint8_t>(1U << lane);
                    t.sustainTicks = std::max(t.sustainTicks, sustain);
                } else if (lane == 5) t.forced = true;
                else if (lane == 6) t.tap = true;
            }
        }
    }
    if (chart.tempos.empty()) chart.tempos.push_back({0, 120.0});
    std::sort(chart.tempos.begin(), chart.tempos.end(), [](auto a, auto b) { return a.tick < b.tick; });
    if (chart.tempos.front().tick != 0) chart.tempos.insert(chart.tempos.begin(), {0, 120.0});
    for (const auto& [tick, t] : tempNotes) {
        if (t.mask == 0) continue;
        Note n;
        n.tick = tick;
        n.mask = t.mask;
        n.forced = t.forced;
        n.tap = t.tap;
        n.time = tickToSeconds(tick, chart.resolution, chart.tempos);
        n.sustain = std::max(0.0, tickToSeconds(tick + t.sustainTicks, chart.resolution, chart.tempos) - n.time);
        chart.notes.push_back(n);
    }
    const int64_t hopoThreshold = std::max<int64_t>(1, chart.resolution / 3);
    for (size_t i = 1; i < chart.notes.size(); ++i) {
        auto& n = chart.notes[i];
        const auto& prev = chart.notes[i - 1];
        const bool autoHopo = std::popcount(n.mask) == 1 && std::popcount(prev.mask) == 1 && n.mask != prev.mask && (n.tick - prev.tick) <= hopoThreshold;
        n.hopo = n.forced ? !autoHopo : autoHopo;
        if (n.tap) n.hopo = true;
    }
    if (chart.notes.empty()) { error = "No ExpertSingle notes found in notes.chart"; return std::nullopt; }
    return chart;
}

#ifdef _WIN32
struct InputEvent { WORD bit = 0; bool down = false; Clock::time_point when{}; };

class XInputPoller {
public:
    explicit XInputPoller(int hz) { start(hz); }
    ~XInputPoller() { stop(); }
    XInputPoller(const XInputPoller&) = delete;
    XInputPoller& operator=(const XInputPoller&) = delete;

    void restart(int hz) { stop(); start(hz); }
    WORD buttons() const { return buttons_.load(std::memory_order_relaxed); }
    bool connected() const { return connected_.load(std::memory_order_relaxed); }
    int hz() const { return hz_; }

    std::vector<InputEvent> takeEvents() {
        std::lock_guard lock(mutex_);
        std::vector<InputEvent> out(queue_.begin(), queue_.end());
        queue_.clear();
        return out;
    }

private:
    void start(int hz) {
        hz_ = clampInt(hz, 60, 4000);
        running_.store(true);
        timeBeginPeriod(1);
        thread_ = std::thread([this] { run(); });
    }
    void stop() {
        if (!running_.exchange(false)) return;
        if (thread_.joinable()) thread_.join();
        timeEndPeriod(1);
    }
    void run() {
        WORD previous = 0;
        const auto period = std::chrono::nanoseconds(static_cast<long long>(1'000'000'000LL / hz_));
        auto next = Clock::now();
        while (running_.load(std::memory_order_relaxed)) {
            XINPUT_STATE state{};
            const DWORD result = XInputGetState(0, &state);
            const bool ok = result == ERROR_SUCCESS;
            connected_.store(ok, std::memory_order_relaxed);
            const WORD now = ok ? state.Gamepad.wButtons : 0;
            buttons_.store(now, std::memory_order_relaxed);
            const WORD changed = static_cast<WORD>(now ^ previous);
            if (changed) {
                const auto stamp = Clock::now();
                std::lock_guard lock(mutex_);
                for (unsigned i = 0; i < 16; ++i) {
                    const WORD bit = static_cast<WORD>(1U << i);
                    if (changed & bit) queue_.push_back({bit, (now & bit) != 0, stamp});
                }
                while (queue_.size() > 2048) queue_.pop_front();
            }
            previous = now;
            next += period;
            for (;;) {
                const auto cur = Clock::now();
                if (cur >= next) break;
                const auto remaining = next - cur;
                if (remaining > std::chrono::microseconds(400)) std::this_thread::sleep_for(remaining - std::chrono::microseconds(200));
                else std::this_thread::yield();
            }
            if (Clock::now() - next > period * 4) next = Clock::now();
        }
    }

    std::atomic<bool> running_{false};
    std::atomic<bool> connected_{false};
    std::atomic<WORD> buttons_{0};
    int hz_ = 1000;
    std::thread thread_;
    std::mutex mutex_;
    std::deque<InputEvent> queue_;
};
#endif

struct Stem { Music music{}; fs::path path; };

static bool audioExtension(const fs::path& p) {
    const std::string e = lower(p.extension().string());
    return e == ".ogg" || e == ".mp3" || e == ".wav" || e == ".flac";
}

static int audioPriority(const fs::path& p) {
    const std::string n = lower(p.filename().string());
    if (n == "song.ogg" || n == "song.mp3" || n == "song.wav") return 0;
    if (n.rfind("guitar.", 0) == 0) return 1;
    return 2;
}

static std::vector<Stem> loadStems(const fs::path& dir) {
    std::vector<fs::path> files;
    std::error_code ec;
    for (const auto& entry : fs::directory_iterator(dir, ec)) {
        if (entry.is_regular_file(ec) && audioExtension(entry.path()) && lower(entry.path().stem().string()) != "preview") files.push_back(entry.path());
    }
    std::sort(files.begin(), files.end(), [](const auto& a, const auto& b) {
        const int pa = audioPriority(a), pb = audioPriority(b);
        return pa == pb ? lower(a.filename().string()) < lower(b.filename().string()) : pa < pb;
    });
    std::vector<Stem> stems;
    for (const auto& path : files) {
        Music m = LoadMusicStream(path.string().c_str());
        if (m.ctxData != nullptr) stems.push_back({m, path});
    }
    return stems;
}

static void unloadStems(std::vector<Stem>& stems) {
    for (auto& s : stems) UnloadMusicStream(s.music);
    stems.clear();
}

static uint8_t heldMaskFromKeyboard() {
    uint8_t mask = 0;
    if (IsKeyDown(KEY_A)) mask |= 1 << 0;
    if (IsKeyDown(KEY_S)) mask |= 1 << 1;
    if (IsKeyDown(KEY_J)) mask |= 1 << 2;
    if (IsKeyDown(KEY_K)) mask |= 1 << 3;
    if (IsKeyDown(KEY_L)) mask |= 1 << 4;
    return mask;
}

#ifdef _WIN32
static uint8_t heldMaskFromXInput(WORD buttons, const Settings& s) {
    uint8_t mask = 0;
    if (buttons & s.green) mask |= 1 << 0;
    if (buttons & s.red) mask |= 1 << 1;
    if (buttons & s.yellow) mask |= 1 << 2;
    if (buttons & s.blue) mask |= 1 << 3;
    if (buttons & s.orange) mask |= 1 << 4;
    return mask;
}
#endif

static bool heldMatches(uint8_t held, uint8_t target) {
    const int count = std::popcount(target);
    if (count > 1) return held == target;
    if (count != 1) return false;
    const int lane = std::countr_zero(static_cast<unsigned int>(target));
    const uint8_t targetAndLower = static_cast<uint8_t>((1U << (lane + 1)) - 1U);
    return (held & target) != 0 && (held & static_cast<uint8_t>(~targetAndLower)) == 0;
}

struct Session {
    std::optional<SongInfo> song;
    ChartData chart;
    std::vector<Stem> stems;
    size_t nextNote = 0;
    int combo = 0;
    int maxCombo = 0;
    long long score = 0;
    int hits = 0;
    int misses = 0;
    bool playing = false;
    bool paused = false;
    std::string error;
};

static void resetChartState(Session& s) {
    for (auto& n : s.chart.notes) { n.hit = false; n.missed = false; }
    s.nextNote = 0; s.combo = 0; s.maxCombo = 0; s.score = 0; s.hits = 0; s.misses = 0;
}

static void playFromStart(Session& s) {
    resetChartState(s);
    for (auto& stem : s.stems) { StopMusicStream(stem.music); SeekMusicStream(stem.music, 0.0f); PlayMusicStream(stem.music); }
    s.playing = !s.stems.empty();
    s.paused = false;
}

static void togglePause(Session& s) {
    if (!s.playing) return;
    s.paused = !s.paused;
    for (auto& stem : s.stems) {
        if (s.paused) PauseMusicStream(stem.music); else ResumeMusicStream(stem.music);
    }
}

static double songTime(const Session& s, const Settings& cfg) {
    if (s.stems.empty() || !s.song) return 0.0;
    return static_cast<double>(GetMusicTimePlayed(s.stems.front().music)) + (cfg.audioOffsetMs + s.song->delayMs) / 1000.0;
}

static bool loadSong(Session& session, const SongInfo& info) {
    unloadStems(session.stems);
    session.error.clear();
    std::string err;
    auto chart = parseChart(info.directory / "notes.chart", err);
    if (!chart) { session.error = err; return false; }
    auto stems = loadStems(info.directory);
    if (stems.empty()) { session.error = "No supported audio files found (ogg/mp3/wav/flac)."; return false; }
    session.song = info;
    session.chart = std::move(*chart);
    session.stems = std::move(stems);
    playFromStart(session);
    return true;
}

static void advanceMisses(Session& s, double now, double window) {
    while (s.nextNote < s.chart.notes.size()) {
        auto& n = s.chart.notes[s.nextNote];
        if (n.hit || n.missed) { ++s.nextNote; continue; }
        if (now > n.time + window) {
            n.missed = true; ++s.misses; s.combo = 0; ++s.nextNote;
        } else break;
    }
}

static void markHit(Session& s, Note& n) {
    n.hit = true;
    ++s.hits;
    ++s.combo;
    s.maxCombo = std::max(s.maxCombo, s.combo);
    const int multiplier = std::min(4, 1 + s.combo / 10);
    s.score += 50LL * std::max(1, std::popcount(n.mask)) * multiplier;
    while (s.nextNote < s.chart.notes.size() && (s.chart.notes[s.nextNote].hit || s.chart.notes[s.nextNote].missed)) ++s.nextNote;
}

static bool tryHit(Session& s, double now, double window, uint8_t held, bool strum, uint8_t pressedFret = 0) {
    if (s.nextNote >= s.chart.notes.size()) { if (strum) s.combo = 0; return false; }
    auto& n = s.chart.notes[s.nextNote];
    const double delta = n.time - now;
    if (std::abs(delta) > window) { if (strum && delta > window) s.combo = 0; return false; }
    if (!heldMatches(held, n.mask)) { if (strum) s.combo = 0; return false; }
    if (!strum) {
        if (!(n.hopo || n.tap) || std::popcount(n.mask) != 1 || (pressedFret & n.mask) == 0) return false;
    }
    markHit(s, n);
    return true;
}

static void drawCentered(const std::string& text, int y, int size, Color color) {
    const int w = MeasureText(text.c_str(), size);
    DrawText(text.c_str(), (GetScreenWidth() - w) / 2, y, size, color);
}

static void drawBrowser(const std::vector<SongInfo>& songs, int selected, const fs::path& root, const Settings& cfg, const std::string& error) {
    ClearBackground(cfg.background);
    DrawText("GitarGame", 36, 26, 34, RAYWHITE);
    DrawText("minimal five-fret player  |  v0.1.0-alpha.1", 38, 66, 18, GRAY);
    DrawText(TextFormat("Songs: %s", root.string().c_str()), 38, 102, 18, LIGHTGRAY);
    if (songs.empty()) {
        drawCentered("No notes.chart files found.", 210, 28, RAYWHITE);
        drawCentered("Put Clone Hero-style song folders in the configured songs_directory, then press F5.", 255, 18, GRAY);
    } else {
        const int visible = std::max(5, (GetScreenHeight() - 210) / 34);
        const int start = std::max(0, std::min(selected - visible / 2, static_cast<int>(songs.size()) - visible));
        for (int row = 0; row < visible && start + row < static_cast<int>(songs.size()); ++row) {
            const int i = start + row;
            const int y = 145 + row * 34;
            if (i == selected) DrawRectangle(28, y - 4, GetScreenWidth() - 56, 30, Fade(RAYWHITE, 0.10f));
            const auto& s = songs[i];
            const std::string label = s.artist.empty() ? s.name : s.artist + "  -  " + s.name;
            DrawText(label.c_str(), 42, y, 21, i == selected ? RAYWHITE : LIGHTGRAY);
        }
    }
    if (!error.empty()) DrawText(error.c_str(), 38, GetScreenHeight() - 82, 18, RED);
    DrawText("Up/Down: select   Enter: play   F3: bind guitar   F5: rescan   F6: reload config   F1: help", 38, GetScreenHeight() - 42, 16, GRAY);
}

static void drawHighway(const Session& s, const Settings& cfg, double now, uint8_t held) {
    ClearBackground(cfg.background);
    const float sw = static_cast<float>(GetScreenWidth());
    const float sh = static_cast<float>(GetScreenHeight());
    const float width = std::min(sw * 0.48f, 560.0f);
    const float laneW = width / 5.0f;
    const float left = (sw - width) * 0.5f;
    const float hitY = sh * 0.88f;
    const float highwayPx = sh * cfg.highwayLength;
    const float topY = std::max(24.0f, hitY - highwayPx);
    const double visibleSeconds = 2.25 / std::max(0.25f, cfg.highwaySpeed);

    DrawRectangle(static_cast<int>(left), static_cast<int>(topY), static_cast<int>(width), static_cast<int>(hitY - topY + 28), cfg.highway);
    for (int i = 0; i <= 5; ++i) {
        const float x = left + laneW * i;
        DrawLineEx({x, topY}, {x, hitY + 28}, 2.0f, Fade(RAYWHITE, 0.10f));
    }

    for (const auto& n : s.chart.notes) {
        if (n.missed) continue;
        const double dt = n.time - now;
        if (dt > visibleSeconds * 1.05 || dt < -0.25) continue;
        const float y = hitY - static_cast<float>(dt / visibleSeconds) * (hitY - topY);
        if (n.sustain > 0.03) {
            const float tail = static_cast<float>(n.sustain / visibleSeconds) * (hitY - topY);
            for (int lane = 0; lane < 5; ++lane) if (n.mask & (1 << lane)) {
                const float x = left + laneW * lane + laneW * 0.44f;
                DrawRectangleRounded({x, y - tail, laneW * 0.12f, tail}, 0.4f, 4, Fade(cfg.lanes[lane], n.hit ? 0.25f : 0.65f));
            }
        }
        for (int lane = 0; lane < 5; ++lane) if (n.mask & (1 << lane)) {
            const Vector2 c{left + laneW * (lane + 0.5f), y};
            const float radius = laneW * 0.28f;
            DrawCircleV(c, radius, n.hit ? Fade(cfg.lanes[lane], 0.23f) : cfg.lanes[lane]);
            if (n.hopo || n.tap) DrawCircleLines(static_cast<int>(c.x), static_cast<int>(c.y), radius * 0.48f, RAYWHITE);
        }
    }

    DrawLineEx({left, hitY}, {left + width, hitY}, 4.0f, cfg.hitLine);
    for (int lane = 0; lane < 5; ++lane) {
        const Vector2 c{left + laneW * (lane + 0.5f), hitY + 14};
        DrawCircleV(c, laneW * 0.21f, (held & (1 << lane)) ? cfg.lanes[lane] : Fade(cfg.lanes[lane], 0.22f));
        DrawCircleLines(static_cast<int>(c.x), static_cast<int>(c.y), laneW * 0.22f, Fade(RAYWHITE, 0.50f));
    }

    if (s.song) {
        DrawText(s.song->name.c_str(), 28, 24, 26, RAYWHITE);
        DrawText(s.song->artist.c_str(), 30, 54, 17, GRAY);
    }
    DrawText(TextFormat("Score %lld", s.score), 28, 92, 20, LIGHTGRAY);
    DrawText(TextFormat("Combo %d", s.combo), 28, 118, 20, LIGHTGRAY);
    const int judged = s.hits + s.misses;
    const float accuracy = judged > 0 ? 100.0f * s.hits / judged : 100.0f;
    DrawText(TextFormat("Accuracy %.2f%%", accuracy), 28, 144, 20, LIGHTGRAY);
    DrawText(TextFormat("%.3fs", now), GetScreenWidth() - 150, 24, 18, GRAY);
    if (s.paused) drawCentered("PAUSED", GetScreenHeight() / 2 - 30, 44, RAYWHITE);
    DrawText("Esc browser   R restart   Space pause   F2 input   F3 bind   F1 help", 24, GetScreenHeight() - 28, 15, GRAY);
}

static void drawHelp(const Settings& cfg) {
    const int w = std::min(760, GetScreenWidth() - 40);
    const int h = std::min(430, GetScreenHeight() - 40);
    const int x = (GetScreenWidth() - w) / 2, y = (GetScreenHeight() - h) / 2;
    DrawRectangle(x, y, w, h, Fade(BLACK, 0.94f));
    DrawRectangleLines(x, y, w, h, Fade(RAYWHITE, 0.35f));
    DrawText("GitarGame alpha controls", x + 26, y + 24, 26, RAYWHITE);
    DrawText("Keyboard frets: A S J K L", x + 26, y + 72, 19, LIGHTGRAY);
    DrawText("Keyboard strum: Up / Down", x + 26, y + 100, 19, LIGHTGRAY);
    DrawText("F3: interactive XInput guitar binding wizard", x + 26, y + 138, 19, LIGHTGRAY);
    DrawText("F2: input diagnostics overlay", x + 26, y + 166, 19, LIGHTGRAY);
    DrawText("F5: rescan songs    F6: reload config.ini", x + 26, y + 194, 19, LIGHTGRAY);
    DrawText("R: restart song     Space: pause/resume     Esc: song browser", x + 26, y + 222, 19, LIGHTGRAY);
    DrawText("Configurable: highway speed/length, colors, song path, FPS, polling, hit window, offsets.", x + 26, y + 270, 17, GRAY);
    DrawText(TextFormat("Current: %d FPS cap | %d Hz XInput poll | %.2fx highway speed | %.0f ms window", cfg.fpsCap, cfg.inputPollHz, cfg.highwaySpeed, cfg.hitWindowMs), x + 26, y + 300, 17, GRAY);
    DrawText("Alpha limitation: ExpertSingle .chart only; open notes and advanced CH edge cases are not implemented yet.", x + 26, y + 336, 16, ORANGE);
    DrawText("Press F1 to close", x + 26, y + h - 40, 16, GRAY);
}

int main(int argc, char** argv) {
    SetTraceLogLevel(LOG_WARNING);
    const fs::path exeDir = fs::absolute(fs::path(argc > 0 ? argv[0] : "GitarGame.exe")).parent_path();
    const fs::path configPath = exeDir / "config.ini";
    Settings cfg;
    if (!loadConfig(configPath, cfg)) saveConfig(configPath, cfg);

    if (cfg.vsync) SetConfigFlags(FLAG_VSYNC_HINT | FLAG_WINDOW_RESIZABLE | FLAG_MSAA_4X_HINT);
    else SetConfigFlags(FLAG_WINDOW_RESIZABLE | FLAG_MSAA_4X_HINT);
    InitWindow(cfg.windowWidth, cfg.windowHeight, "GitarGame");
    if (cfg.fullscreen) ToggleFullscreen();
    if (cfg.fpsCap > 0) SetTargetFPS(cfg.fpsCap);
    InitAudioDevice();
    SetMasterVolume(cfg.masterVolume);

#ifdef _WIN32
    XInputPoller poller(cfg.inputPollHz);
#endif

    fs::path songsRoot = fs::path(cfg.songsDirectory);
    if (songsRoot.is_relative()) songsRoot = exeDir / songsRoot;
    auto songs = scanSongs(songsRoot);
    int selected = 0;
    Session session;
    bool inBrowser = true;
    bool showHelp = false;
    bool showInput = false;
    bool binding = false;
    int bindIndex = 0;
    std::string status;

#ifdef _WIN32
    const std::vector<std::string> bindLabels = {"Green", "Red", "Yellow", "Blue", "Orange", "Strum Up", "Strum Down", "Star Power", "Start"};
    auto setBinding = [&](int index, WORD bit) {
        WORD* targets[] = {&cfg.green, &cfg.red, &cfg.yellow, &cfg.blue, &cfg.orange, &cfg.strumUp, &cfg.strumDown, &cfg.starPower, &cfg.start};
        if (index >= 0 && index < static_cast<int>(std::size(targets))) *targets[index] = bit;
    };
#endif

    if (argc >= 2) {
        fs::path direct = argv[1];
        if (fs::is_regular_file(direct) && lower(direct.filename().string()) == "notes.chart") direct = direct.parent_path();
        if (fs::exists(direct / "notes.chart")) {
            SongInfo info = readSongInfo(direct);
            if (loadSong(session, info)) inBrowser = false; else status = session.error;
        }
    }

    while (!WindowShouldClose()) {
        if (IsKeyPressed(KEY_F1)) showHelp = !showHelp;
        if (IsKeyPressed(KEY_F2)) showInput = !showInput;

#ifdef _WIN32
        auto events = poller.takeEvents();
        if (IsKeyPressed(KEY_F3)) {
            binding = true; bindIndex = 0;
            if (!inBrowser && session.playing && !session.paused) togglePause(session);
        }
        if (binding) {
            if (IsKeyPressed(KEY_ESCAPE)) { binding = false; status = "Binding cancelled."; }
            for (const auto& ev : events) {
                if (!ev.down || !binding) continue;
                setBinding(bindIndex, ev.bit);
                ++bindIndex;
                if (bindIndex >= static_cast<int>(bindLabels.size())) {
                    binding = false;
                    saveConfig(configPath, cfg);
                    status = "Controller bindings saved to config.ini";
                }
            }
        }
#endif

        if (IsKeyPressed(KEY_F6)) {
            Settings updated = cfg;
            if (loadConfig(configPath, updated)) {
                cfg = updated;
                if (cfg.fpsCap > 0) SetTargetFPS(cfg.fpsCap); else SetTargetFPS(0);
                SetMasterVolume(cfg.masterVolume);
#ifdef _WIN32
                poller.restart(cfg.inputPollHz);
#endif
                fs::path newRoot = fs::path(cfg.songsDirectory);
                if (newRoot.is_relative()) newRoot = exeDir / newRoot;
                songsRoot = newRoot;
                songs = scanSongs(songsRoot);
                selected = std::clamp(selected, 0, std::max(0, static_cast<int>(songs.size()) - 1));
                status = "Reloaded config.ini";
            }
        }

        if (!binding && !showHelp) {
            if (inBrowser) {
                if (IsKeyPressed(KEY_DOWN) && !songs.empty()) selected = (selected + 1) % static_cast<int>(songs.size());
                if (IsKeyPressed(KEY_UP) && !songs.empty()) selected = (selected - 1 + static_cast<int>(songs.size())) % static_cast<int>(songs.size());
                if (IsKeyPressed(KEY_F5)) { songs = scanSongs(songsRoot); selected = std::clamp(selected, 0, std::max(0, static_cast<int>(songs.size()) - 1)); status = "Song library rescanned."; }
                if (IsKeyPressed(KEY_ENTER) && !songs.empty()) {
                    if (loadSong(session, songs[selected])) { inBrowser = false; status.clear(); }
                    else status = session.error;
                }
            } else {
                for (auto& stem : session.stems) UpdateMusicStream(stem.music);
                const double now = songTime(session, cfg);
                const double window = cfg.hitWindowMs / 1000.0;
                advanceMisses(session, now, window);
#ifdef _WIN32
                const WORD xb = poller.buttons();
                const uint8_t gamepadHeld = heldMaskFromXInput(xb, cfg);
                if (!binding) {
                    for (const auto& ev : events) if (ev.down) {
                        if (ev.bit == cfg.strumUp || ev.bit == cfg.strumDown) tryHit(session, now, window, gamepadHeld, true);
                        uint8_t fretPressed = 0;
                        if (ev.bit == cfg.green) fretPressed = 1 << 0;
                        else if (ev.bit == cfg.red) fretPressed = 1 << 1;
                        else if (ev.bit == cfg.yellow) fretPressed = 1 << 2;
                        else if (ev.bit == cfg.blue) fretPressed = 1 << 3;
                        else if (ev.bit == cfg.orange) fretPressed = 1 << 4;
                        if (fretPressed) tryHit(session, now, window, gamepadHeld, false, fretPressed);
                    }
                }
#endif
                const uint8_t kbHeld = heldMaskFromKeyboard();
                if (IsKeyPressed(KEY_UP) || IsKeyPressed(KEY_DOWN)) tryHit(session, now, window, kbHeld, true);
                if (IsKeyPressed(KEY_A)) tryHit(session, now, window, kbHeld, false, 1 << 0);
                if (IsKeyPressed(KEY_S)) tryHit(session, now, window, kbHeld, false, 1 << 1);
                if (IsKeyPressed(KEY_J)) tryHit(session, now, window, kbHeld, false, 1 << 2);
                if (IsKeyPressed(KEY_K)) tryHit(session, now, window, kbHeld, false, 1 << 3);
                if (IsKeyPressed(KEY_L)) tryHit(session, now, window, kbHeld, false, 1 << 4);
                if (IsKeyPressed(KEY_R)) playFromStart(session);
                if (IsKeyPressed(KEY_SPACE)) togglePause(session);
                if (IsKeyPressed(KEY_ESCAPE)) {
                    unloadStems(session.stems); session.playing = false; session.song.reset(); inBrowser = true;
                }
            }
        }

        BeginDrawing();
        if (inBrowser) drawBrowser(songs, selected, songsRoot, cfg, status);
        else {
#ifdef _WIN32
            const uint8_t held = static_cast<uint8_t>(heldMaskFromKeyboard() | heldMaskFromXInput(poller.buttons(), cfg));
#else
            const uint8_t held = heldMaskFromKeyboard();
#endif
            drawHighway(session, cfg, songTime(session, cfg), held);
        }

#ifdef _WIN32
        if (showInput) {
            const int boxW = 420, boxH = 180;
            DrawRectangle(GetScreenWidth() - boxW - 18, 18, boxW, boxH, Fade(BLACK, 0.90f));
            DrawText("INPUT DIAGNOSTICS", GetScreenWidth() - boxW, 34, 18, RAYWHITE);
            DrawText(TextFormat("XInput: %s", poller.connected() ? "connected" : "not connected"), GetScreenWidth() - boxW, 64, 17, poller.connected() ? GREEN : ORANGE);
            DrawText(TextFormat("Poll target: %d Hz", poller.hz()), GetScreenWidth() - boxW, 88, 17, LIGHTGRAY);
            const WORD b = poller.buttons();
            std::string pressed = "Held: ";
            for (const auto& [name, bit] : buttonNames()) if (b & bit) pressed += name + " ";
            DrawText(pressed.c_str(), GetScreenWidth() - boxW, 112, 16, LIGHTGRAY);
            DrawText("F3 runs binding wizard", GetScreenWidth() - boxW, 146, 16, GRAY);
        }
        if (binding) {
            const int w = std::min(620, GetScreenWidth() - 40), h = 210;
            const int x = (GetScreenWidth() - w) / 2, y = (GetScreenHeight() - h) / 2;
            DrawRectangle(x, y, w, h, Fade(BLACK, 0.96f));
            DrawRectangleLines(x, y, w, h, Fade(RAYWHITE, 0.45f));
            DrawText("Controller binding wizard", x + 24, y + 24, 26, RAYWHITE);
            DrawText(poller.connected() ? "XInput device detected" : "Waiting for XInput device...", x + 24, y + 62, 17, poller.connected() ? GREEN : ORANGE);
            if (bindIndex < static_cast<int>(bindLabels.size())) {
                DrawText(TextFormat("Press: %s", bindLabels[bindIndex].c_str()), x + 24, y + 102, 30, RAYWHITE);
                DrawText(TextFormat("%d / %d", bindIndex + 1, static_cast<int>(bindLabels.size())), x + 24, y + 146, 17, GRAY);
            }
            DrawText("Esc cancels", x + w - 120, y + h - 32, 15, GRAY);
        }
#endif
        if (showHelp) drawHelp(cfg);
        DrawFPS(GetScreenWidth() - 92, GetScreenHeight() - 28);
        EndDrawing();
    }

    unloadStems(session.stems);
    CloseAudioDevice();
    CloseWindow();
    return 0;
}
