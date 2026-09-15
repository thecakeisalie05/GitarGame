#define main gitarGameLegacyMain
#include "main.cpp"
#undef main

#ifdef _WIN32
#include <objbase.h>
#include <shobjidl.h>
#endif

#include <array>
#include <climits>
#include <numeric>

// Alpha.5: UI/QoL-focused runtime. The lower-level chart parser, audio loader,
// gameplay rules, XInput poller, config handling, and diagnostics remain in
// main.cpp so this pass can focus on the shell around the player.

static constexpr const char* GG_VERSION = "v0.1.0-alpha.5";

static std::string pathUtf8(const fs::path& path) {
#ifdef _WIN32
    const std::wstring wide = path.wstring();
    if (wide.empty()) return {};
    const int count = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()), nullptr, 0, nullptr, nullptr);
    if (count <= 0) return {};
    std::string out(static_cast<size_t>(count), '\0');
    WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()), out.data(), count, nullptr, nullptr);
    return out;
#else
    return path.string();
#endif
}

#ifdef _WIN32
static std::wstring utf8ToWide(const std::string& text) {
    if (text.empty()) return {};
    const int count = MultiByteToWideChar(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()), nullptr, 0);
    if (count <= 0) return {};
    std::wstring out(static_cast<size_t>(count), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()), out.data(), count);
    return out;
}

static std::optional<std::string> chooseSongsFolder() {
    const HRESULT init = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    const bool shouldUninit = SUCCEEDED(init);

    IFileDialog* dialog = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
    if (FAILED(hr) || !dialog) {
        if (shouldUninit) CoUninitialize();
        return std::nullopt;
    }

    DWORD options = 0;
    if (SUCCEEDED(dialog->GetOptions(&options))) {
        dialog->SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST);
    }
    dialog->SetTitle(L"Choose GitarGame songs folder");

    std::optional<std::string> result;
    if (SUCCEEDED(dialog->Show(nullptr))) {
        IShellItem* item = nullptr;
        if (SUCCEEDED(dialog->GetResult(&item)) && item) {
            PWSTR widePath = nullptr;
            if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &widePath)) && widePath) {
                result = pathUtf8(fs::path(widePath));
                CoTaskMemFree(widePath);
            }
            item->Release();
        }
    }

    dialog->Release();
    if (shouldUninit) CoUninitialize();
    return result;
}
#endif

static double readChartOffsetSecondsV5(const fs::path& file) {
    std::ifstream in(file);
    if (!in) return 0.0;
    std::string section;
    std::string line;
    while (std::getline(in, line)) {
        line = trim(line);
        if (line.empty() || line[0] == '{' || line[0] == '}') continue;
        if (line.front() == '[' && line.back() == ']') {
            section = line.substr(1, line.size() - 2);
            continue;
        }
        if (section != "Song") continue;
        const auto p = line.find('=');
        if (p == std::string::npos || lower(trim(line.substr(0, p))) != "offset") continue;
        try { return std::stod(unquote(line.substr(p + 1))); }
        catch (...) { return 0.0; }
    }
    return 0.0;
}

static double correctedSongTimeV5(const Session& s, const Settings& cfg, double chartOffsetSeconds) {
    if (s.stems.empty() || !s.song) return 0.0;
    const double audioSeconds = static_cast<double>(GetMusicTimePlayed(s.stems.front().music));
    return audioSeconds + chartOffsetSeconds
        - static_cast<double>(s.song->delayMs) / 1000.0
        - static_cast<double>(cfg.audioOffsetMs) / 1000.0;
}

static void logSongTimingV5(const Session& s, const Settings& cfg, double chartOffsetSeconds) {
#ifdef _WIN32
    if (!s.song) return;
    std::ostringstream out;
    out << "Timing map loaded: chart_offset_s=" << chartOffsetSeconds
        << " song_ini_delay_ms=" << s.song->delayMs
        << " user_audio_offset_ms=" << cfg.audioOffsetMs;
    ggdiag::log(out.str());
#else
    (void)s; (void)cfg; (void)chartOffsetSeconds;
#endif
}

struct UiPrefs {
    bool showFps = true;
    bool showAlbumArt = true;
    bool depthGuides = true;
    float cameraFov = 44.0f;
    float roadWidth = 7.4f;
    float noteScale = 1.0f;
    int paletteIndex = 0; // -1 = custom; 0 classic; 1 neon; 2 pastel; 3 mono
};

static bool loadUiPrefs(const fs::path& path, UiPrefs& ui) {
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
            if (key == "show_fps") ui.showFps = parseBool(value, ui.showFps);
            else if (key == "show_album_art") ui.showAlbumArt = parseBool(value, ui.showAlbumArt);
            else if (key == "depth_guides") ui.depthGuides = parseBool(value, ui.depthGuides);
            else if (key == "camera_fov") ui.cameraFov = clampFloat(std::stof(value), 30.0f, 70.0f);
            else if (key == "highway_width") ui.roadWidth = clampFloat(std::stof(value), 5.0f, 11.0f);
            else if (key == "note_scale") ui.noteScale = clampFloat(std::stof(value), 0.55f, 1.60f);
            else if (key == "palette_index") ui.paletteIndex = clampInt(std::stoi(value), -1, 3);
        } catch (...) {}
    }
    return true;
}

static void saveUiPrefs(const fs::path& path, const UiPrefs& ui) {
    std::ofstream out(path, std::ios::trunc);
    if (!out) return;
    out << "# GitarGame UI / presentation settings\n\n[ui]\n";
    out << "show_fps = " << (ui.showFps ? "true" : "false") << '\n';
    out << "show_album_art = " << (ui.showAlbumArt ? "true" : "false") << '\n';
    out << "depth_guides = " << (ui.depthGuides ? "true" : "false") << '\n';
    out << "camera_fov = " << ui.cameraFov << '\n';
    out << "highway_width = " << ui.roadWidth << '\n';
    out << "note_scale = " << ui.noteScale << '\n';
    out << "palette_index = " << ui.paletteIndex << '\n';
}

struct SongUiMeta {
    std::string album;
    std::string genre;
    std::string year;
    std::string charter;
    fs::path artPath;
};

static fs::path findSongArt(const fs::path& dir) {
    static const std::array<const char*, 10> candidates = {
        "album.png", "album.jpg", "album.jpeg", "cover.png", "cover.jpg",
        "cover.jpeg", "icon.png", "icon.jpg", "background.png", "background.jpg"
    };
    std::error_code ec;
    for (const char* name : candidates) {
        fs::path candidate = dir / name;
        if (fs::is_regular_file(candidate, ec)) return candidate;
        ec.clear();
    }
    return {};
}

static SongUiMeta readSongUiMeta(const SongInfo& song) {
    SongUiMeta meta;
    meta.artPath = findSongArt(song.directory);
    std::ifstream in(song.directory / "song.ini");
    std::string line;
    while (std::getline(in, line)) {
        const auto p = line.find('=');
        if (p == std::string::npos) continue;
        const std::string key = lower(trim(line.substr(0, p)));
        const std::string value = unquote(line.substr(p + 1));
        if (key == "album") meta.album = value;
        else if (key == "genre") meta.genre = value;
        else if (key == "year") meta.year = value;
        else if (key == "charter" || key == "frets") meta.charter = value;
    }
    return meta;
}

static std::vector<SongUiMeta> buildSongMeta(const std::vector<SongInfo>& songs) {
    std::vector<SongUiMeta> out;
    out.reserve(songs.size());
    for (const auto& song : songs) out.push_back(readSongUiMeta(song));
    return out;
}

struct ArtTexture {
    Texture2D texture{};
    fs::path path;
    bool valid = false;

    void clear() {
        if (valid && texture.id != 0) UnloadTexture(texture);
        texture = {};
        path.clear();
        valid = false;
    }

    void load(const fs::path& nextPath) {
        if (nextPath == path) return;
        clear();
        path = nextPath;
        if (path.empty()) return;
        const std::string utf8 = pathUtf8(path);
        texture = LoadTexture(utf8.c_str());
        valid = texture.id != 0;
#ifdef _WIN32
        ggdiag::log(std::string("Artwork load: ") + utf8 + (valid ? " [ok]" : " [failed]"));
#endif
    }
};

static Color alphaColor(Color c, unsigned char a) { c.a = a; return c; }

static Color mixColor(Color a, Color b, float t) {
    t = std::clamp(t, 0.0f, 1.0f);
    auto lerpByte = [t](unsigned char x, unsigned char y) {
        return static_cast<unsigned char>(static_cast<float>(x) + (static_cast<float>(y) - static_cast<float>(x)) * t);
    };
    return {lerpByte(a.r, b.r), lerpByte(a.g, b.g), lerpByte(a.b, b.b), lerpByte(a.a, b.a)};
}

static void drawPanel(Rectangle r, Color color, float roundness = 0.08f) {
    DrawRectangleRounded(r, roundness, 8, color);
    DrawRectangleLinesEx(r, 1.0f, alphaColor(RAYWHITE, 24));
}

static void drawSectionTitle(const char* title, const char* subtitle) {
    DrawText(title, 56, 42, 34, RAYWHITE);
    if (subtitle && *subtitle) DrawText(subtitle, 58, 82, 18, GRAY);
}

struct UiNav {
    bool up = false;
    bool down = false;
    bool left = false;
    bool right = false;
    bool accept = false;
    bool back = false;
    bool start = false;
};

static UiNav keyboardNav() {
    UiNav nav;
    nav.up = IsKeyPressed(KEY_UP) || IsKeyPressed(KEY_W);
    nav.down = IsKeyPressed(KEY_DOWN) || IsKeyPressed(KEY_S);
    nav.left = IsKeyPressed(KEY_LEFT) || IsKeyPressed(KEY_A);
    nav.right = IsKeyPressed(KEY_RIGHT) || IsKeyPressed(KEY_D);
    nav.accept = IsKeyPressed(KEY_ENTER);
    nav.back = IsKeyPressed(KEY_ESCAPE);
    return nav;
}

#ifdef _WIN32
static void mergeGuitarNav(UiNav& nav, const std::vector<InputEvent>& events, const Settings& cfg) {
    for (const auto& ev : events) {
        if (!ev.down) continue;
        if (ev.bit == cfg.strumUp) nav.up = true;
        if (ev.bit == cfg.strumDown) nav.down = true;
        if (ev.bit == cfg.green) nav.accept = true;
        if (ev.bit == cfg.red) nav.back = true;
        if (ev.bit == cfg.yellow) nav.left = true;
        if (ev.bit == cfg.blue) nav.right = true;
        if (ev.bit == cfg.start) nav.start = true;
    }
}
#endif

static int wrapIndex(int value, int count) {
    if (count <= 0) return 0;
    value %= count;
    if (value < 0) value += count;
    return value;
}

static void drawMenuList(const std::vector<std::string>& items, int selected, float x, float y, float width, float rowH) {
    for (int i = 0; i < static_cast<int>(items.size()); ++i) {
        Rectangle row{x, y + rowH * i, width, rowH - 8.0f};
        if (i == selected) {
            DrawRectangleRounded(row, 0.12f, 8, alphaColor(RAYWHITE, 24));
            DrawRectangleLinesEx(row, 2.0f, alphaColor(RAYWHITE, 75));
        }
        DrawText(items[i].c_str(), static_cast<int>(x + 22), static_cast<int>(row.y + 14), 24,
                 i == selected ? RAYWHITE : LIGHTGRAY);
    }
}

static void drawControllerHint(bool connected) {
    const char* state = connected ? "Guitar connected" : "Keyboard active / guitar not detected";
    DrawText(state, 56, GetScreenHeight() - 52, 16, connected ? GREEN : GRAY);
    DrawText("Strum: move   Green: select   Red: back   Yellow/Blue: adjust",
             56, GetScreenHeight() - 28, 15, GRAY);
}

static void drawMainMenu(int selected, bool controllerConnected, const Settings& cfg) {
    ClearBackground(cfg.background);
    const int sw = GetScreenWidth();
    const int sh = GetScreenHeight();

    for (int i = 0; i < 5; ++i) {
        const int x = sw - 420 + i * 64;
        DrawLineEx({static_cast<float>(x), 80.0f}, {static_cast<float>(x + 80), static_cast<float>(sh - 70)},
                   2.0f, alphaColor(cfg.lanes[i], 55));
    }

    DrawText("GitarGame", 72, 72, 58, RAYWHITE);
    DrawText("lightweight five-fret player", 76, 136, 20, GRAY);
    DrawText(GG_VERSION, 76, 165, 16, DARKGRAY);

    const std::vector<std::string> items = {"Play", "Settings", "Calibration", "Controller Setup", "Quit"};
    drawMenuList(items, selected, 72.0f, 235.0f, 430.0f, 62.0f);

    DrawText("Fast startup. Audio-clock timing. Fully configurable highway.", 72, sh - 96, 17, LIGHTGRAY);
    drawControllerHint(controllerConnected);
}

enum class AppScreen {
    MainMenu,
    SongBrowser,
    SettingsCategories,
    SettingsPage,
    Calibration,
    Playing,
    PauseMenu
};

enum class SettingsCategory {
    Gameplay,
    Audio,
    Video,
    Appearance,
    Input,
    Library,
    Count
};

static const char* categoryName(SettingsCategory c) {
    switch (c) {
        case SettingsCategory::Gameplay: return "Gameplay";
        case SettingsCategory::Audio: return "Audio & Timing";
        case SettingsCategory::Video: return "Video";
        case SettingsCategory::Appearance: return "Appearance";
        case SettingsCategory::Input: return "Input";
        case SettingsCategory::Library: return "Song Library";
        default: return "Settings";
    }
}

static const char* categoryDescription(SettingsCategory c) {
    switch (c) {
        case SettingsCategory::Gameplay: return "Highway feel, hit window, and note sizing";
        case SettingsCategory::Audio: return "Volume, timing offset, and calibration";
        case SettingsCategory::Video: return "Frame pacing and display options";
        case SettingsCategory::Appearance: return "Colors, camera, art, and highway presentation";
        case SettingsCategory::Input: return "Polling, controller binding, and diagnostics";
        case SettingsCategory::Library: return "Song folder and library management";
        default: return "";
    }
}

static int settingsRowCount(SettingsCategory c) {
    switch (c) {
        case SettingsCategory::Gameplay: return 4;
        case SettingsCategory::Audio: return 3;
        case SettingsCategory::Video: return 4;
        case SettingsCategory::Appearance: return 11;
        case SettingsCategory::Input: return 3;
        case SettingsCategory::Library: return 3;
        default: return 0;
    }
}

static std::string onOff(bool v) { return v ? "On" : "Off"; }
static std::string fpsLabel(int fps) { return fps <= 0 ? "Uncapped" : std::to_string(fps); }

static const std::array<std::pair<const char*, Color>, 9>& laneSwatches() {
    static const std::array<std::pair<const char*, Color>, 9> swatches = {{
        {"Green", {53, 208, 79, 255}}, {"Red", {239, 51, 64, 255}},
        {"Yellow", {255, 210, 63, 255}}, {"Blue", {38, 132, 255, 255}},
        {"Orange", {255, 139, 44, 255}}, {"Purple", {183, 89, 255, 255}},
        {"Cyan", {55, 220, 235, 255}}, {"Pink", {255, 94, 174, 255}},
        {"White", {230, 232, 238, 255}}
    }};
    return swatches;
}

static int nearestSwatch(Color c) {
    const auto& swatches = laneSwatches();
    int best = 0;
    long bestDist = LONG_MAX;
    for (int i = 0; i < static_cast<int>(swatches.size()); ++i) {
        const Color s = swatches[i].second;
        const long dr = static_cast<long>(c.r) - s.r;
        const long dg = static_cast<long>(c.g) - s.g;
        const long db = static_cast<long>(c.b) - s.b;
        const long d = dr * dr + dg * dg + db * db;
        if (d < bestDist) { bestDist = d; best = i; }
    }
    return best;
}

static const char* paletteLabel(int index) {
    static const std::array<const char*, 4> names = {"Classic", "Neon", "Pastel", "Mono"};
    return index >= 0 && index < static_cast<int>(names.size()) ? names[index] : "Custom";
}

static std::vector<std::pair<std::string, std::string>> settingsRows(
    SettingsCategory c, const Settings& cfg, const UiPrefs& ui, const fs::path& songsRoot,
    size_t songCount, bool inputOverlay) {
    std::vector<std::pair<std::string, std::string>> rows;
    switch (c) {
        case SettingsCategory::Gameplay:
            rows = {{"Highway speed", TextFormat("%.2fx", cfg.highwaySpeed)}, {"Highway length", TextFormat("%.0f%%", cfg.highwayLength * 100.0f)}, {"Hit window", TextFormat("%.0f ms", cfg.hitWindowMs)}, {"Note size", TextFormat("%.0f%%", ui.noteScale * 100.0f)}};
            break;
        case SettingsCategory::Audio:
            rows = {{"Master volume", TextFormat("%.0f%%", cfg.masterVolume * 100.0f)}, {"Timing offset", TextFormat("%+.0f ms", cfg.audioOffsetMs)}, {"Calibration tool", "Open"}};
            break;
        case SettingsCategory::Video:
            rows = {{"FPS cap", fpsLabel(cfg.fpsCap)}, {"VSync", onOff(cfg.vsync) + " (restart)"}, {"Fullscreen", onOff(cfg.fullscreen)}, {"Show FPS", onOff(ui.showFps)}};
            break;
        case SettingsCategory::Appearance:
            rows.push_back({"Palette", paletteLabel(ui.paletteIndex)});
            for (int lane = 0; lane < 5; ++lane) {
                const char* names[] = {"Green lane", "Red lane", "Yellow lane", "Blue lane", "Orange lane"};
                rows.push_back({names[lane], laneSwatches()[nearestSwatch(cfg.lanes[lane])].first});
            }
            rows.push_back({"Camera FOV", TextFormat("%.0f deg", ui.cameraFov)});
            rows.push_back({"Highway width", TextFormat("%.1f", ui.roadWidth)});
            rows.push_back({"Depth guides", onOff(ui.depthGuides)});
            rows.push_back({"Album artwork", onOff(ui.showAlbumArt)});
            rows.push_back({"Restore visual defaults", "Reset"});
            break;
        case SettingsCategory::Input:
            rows = {{"Input polling", TextFormat("%d Hz", cfg.inputPollHz)}, {"Controller binding", "Open wizard"}, {"Input diagnostics", onOff(inputOverlay)}};
            break;
        case SettingsCategory::Library:
            rows = {{"Songs folder", pathUtf8(songsRoot)}, {"Rescan library", "Scan now"}, {"Detected songs", std::to_string(songCount)}};
            break;
        default: break;
    }
    return rows;
}

static void drawSettingsCategories(int selected, const Settings& cfg, bool controllerConnected) {
    ClearBackground(cfg.background);
    drawSectionTitle("Settings", "Choose a category");
    const int count = static_cast<int>(SettingsCategory::Count);
    const float x = 58.0f, y = 135.0f, width = static_cast<float>(GetScreenWidth()) - 116.0f, rowH = 76.0f;
    for (int i = 0; i < count; ++i) {
        const auto cat = static_cast<SettingsCategory>(i);
        Rectangle row{x, y + i * rowH, width, rowH - 10.0f};
        drawPanel(row, i == selected ? alphaColor(RAYWHITE, 24) : alphaColor(RAYWHITE, 8), 0.08f);
        DrawText(categoryName(cat), static_cast<int>(x + 24), static_cast<int>(row.y + 12), 23, i == selected ? RAYWHITE : LIGHTGRAY);
        DrawText(categoryDescription(cat), static_cast<int>(x + 24), static_cast<int>(row.y + 40), 16, GRAY);
    }
    drawControllerHint(controllerConnected);
}

static void drawSettingsPage(SettingsCategory category, int selectedRow, const Settings& cfg, const UiPrefs& ui,
                             const fs::path& songsRoot, size_t songCount, bool inputOverlay, const std::string& status,
                             bool controllerConnected) {
    ClearBackground(cfg.background);
    drawSectionTitle(categoryName(category), categoryDescription(category));
    const auto rows = settingsRows(category, cfg, ui, songsRoot, songCount, inputOverlay);
    const float x = 56.0f, y = 130.0f, width = static_cast<float>(GetScreenWidth()) - 112.0f;
    const float rowH = std::min(60.0f, (GetScreenHeight() - 220.0f) / std::max(1.0f, static_cast<float>(rows.size())));
    for (int i = 0; i < static_cast<int>(rows.size()); ++i) {
        Rectangle row{x, y + i * rowH, width, rowH - 6.0f};
        if (i == selectedRow) DrawRectangleRounded(row, 0.10f, 8, alphaColor(RAYWHITE, 22));
        DrawText(rows[i].first.c_str(), static_cast<int>(x + 18), static_cast<int>(row.y + 13), 20, i == selectedRow ? RAYWHITE : LIGHTGRAY);
        const int valueW = MeasureText(rows[i].second.c_str(), 19);
        DrawText(rows[i].second.c_str(), static_cast<int>(x + width - 18 - valueW), static_cast<int>(row.y + 14), 19, i == selectedRow ? RAYWHITE : GRAY);
    }
    if (!status.empty()) DrawText(status.c_str(), 56, GetScreenHeight() - 82, 16, ORANGE);
    DrawText("Yellow/Blue or Left/Right: adjust   Green/Enter: activate   Red/Esc: back", 56, GetScreenHeight() - 56, 15, GRAY);
    drawControllerHint(controllerConnected);
}

static void drawArtPlaceholder(Rectangle area, const Settings& cfg, const SongInfo& song) {
    drawPanel(area, mixColor(cfg.highway, cfg.background, 0.35f), 0.05f);
    const char initial = song.name.empty() ? '?' : static_cast<char>(std::toupper(static_cast<unsigned char>(song.name.front())));
    char text[2] = {initial, '\0'};
    const int size = static_cast<int>(std::min(area.width, area.height) * 0.34f);
    const int w = MeasureText(text, size);
    DrawText(text, static_cast<int>(area.x + (area.width - w) / 2), static_cast<int>(area.y + (area.height - size) / 2), size, alphaColor(RAYWHITE, 100));
}

static void drawArtwork(const ArtTexture& art, Rectangle area, const Settings& cfg, const SongInfo& song) {
    if (!art.valid || art.texture.id == 0) { drawArtPlaceholder(area, cfg, song); return; }
    const float sx = static_cast<float>(art.texture.width), sy = static_cast<float>(art.texture.height);
    const float scale = std::min(area.width / sx, area.height / sy), w = sx * scale, h = sy * scale;
    Rectangle dest{area.x + (area.width - w) * 0.5f, area.y + (area.height - h) * 0.5f, w, h};
    drawPanel(area, alphaColor(BLACK, 70), 0.05f);
    DrawTexturePro(art.texture, {0, 0, sx, sy}, dest, {0, 0}, 0.0f, WHITE);
}

static void drawSongBrowser(const std::vector<SongInfo>& songs, const std::vector<SongUiMeta>& meta,
                            int selected, const ArtTexture& art, const Settings& cfg, const UiPrefs& ui,
                            const std::string& status, bool controllerConnected) {
    ClearBackground(cfg.background);
    drawSectionTitle("Songs", TextFormat("%d songs detected", static_cast<int>(songs.size())));
    if (songs.empty()) {
        drawPanel({56, 145, static_cast<float>(GetScreenWidth() - 112), 220}, alphaColor(RAYWHITE, 8));
        drawCentered("No notes.chart files found", 205, 30, RAYWHITE);
        drawCentered("Open Settings > Song Library to choose a songs folder.", 252, 18, GRAY);
        if (!status.empty()) DrawText(status.c_str(), 58, 390, 17, ORANGE);
        drawControllerHint(controllerConnected);
        return;
    }
    const float sw = static_cast<float>(GetScreenWidth()), sh = static_cast<float>(GetScreenHeight());
    const float listX = 48.0f, listY = 122.0f, listW = std::max(470.0f, sw * 0.54f);
    const float panelX = listX + listW + 24.0f, panelW = sw - panelX - 48.0f, rowH = 46.0f;
    const int visible = std::max(6, static_cast<int>((sh - 220.0f) / rowH));
    const int maxStart = std::max(0, static_cast<int>(songs.size()) - visible);
    const int start = std::clamp(selected - visible / 2, 0, maxStart);
    drawPanel({listX, listY, listW, visible * rowH + 12.0f}, alphaColor(RAYWHITE, 7));
    for (int row = 0; row < visible && start + row < static_cast<int>(songs.size()); ++row) {
        const int i = start + row; const float y = listY + 6.0f + row * rowH;
        Rectangle r{listX + 6.0f, y, listW - 12.0f, rowH - 4.0f};
        if (i == selected) { DrawRectangleRounded(r, 0.08f, 6, alphaColor(RAYWHITE, 23)); DrawRectangle(static_cast<int>(r.x), static_cast<int>(r.y), 5, static_cast<int>(r.height), cfg.lanes[0]); }
        const std::string title = songs[i].name.empty() ? pathUtf8(songs[i].directory.filename()) : songs[i].name;
        DrawText(title.c_str(), static_cast<int>(r.x + 18), static_cast<int>(r.y + 6), 19, i == selected ? RAYWHITE : LIGHTGRAY);
        if (!songs[i].artist.empty()) { const int aw = MeasureText(songs[i].artist.c_str(), 15); DrawText(songs[i].artist.c_str(), static_cast<int>(r.x + r.width - aw - 14), static_cast<int>(r.y + 9), 15, i == selected ? LIGHTGRAY : GRAY); }
    }
    const SongInfo& song = songs[selected]; const SongUiMeta& sm = meta[selected];
    Rectangle detail{panelX, listY, panelW, sh - listY - 90.0f}; drawPanel(detail, alphaColor(RAYWHITE, 8));
    const float artSize = std::min({panelW - 40.0f, 285.0f, detail.height * 0.52f});
    Rectangle artArea{detail.x + (detail.width - artSize) * 0.5f, detail.y + 20.0f, artSize, artSize};
    if (ui.showAlbumArt) drawArtwork(art, artArea, cfg, song);
    float textY = ui.showAlbumArt ? artArea.y + artArea.height + 20.0f : detail.y + 28.0f;
    DrawText(song.name.c_str(), static_cast<int>(detail.x + 22), static_cast<int>(textY), 24, RAYWHITE); textY += 31.0f;
    DrawText(song.artist.c_str(), static_cast<int>(detail.x + 22), static_cast<int>(textY), 18, LIGHTGRAY); textY += 30.0f;
    if (!sm.album.empty()) { DrawText(TextFormat("Album: %s", sm.album.c_str()), static_cast<int>(detail.x + 22), static_cast<int>(textY), 16, GRAY); textY += 23.0f; }
    if (!sm.year.empty()) { DrawText(TextFormat("Year: %s", sm.year.c_str()), static_cast<int>(detail.x + 22), static_cast<int>(textY), 16, GRAY); textY += 23.0f; }
    if (!sm.genre.empty()) { DrawText(TextFormat("Genre: %s", sm.genre.c_str()), static_cast<int>(detail.x + 22), static_cast<int>(textY), 16, GRAY); textY += 23.0f; }
    if (!sm.charter.empty()) { DrawText(TextFormat("Charter: %s", sm.charter.c_str()), static_cast<int>(detail.x + 22), static_cast<int>(textY), 16, GRAY); textY += 23.0f; }
    DrawText(TextFormat("%d / %d", selected + 1, static_cast<int>(songs.size())), static_cast<int>(detail.x + 22), static_cast<int>(detail.y + detail.height - 30), 15, DARKGRAY);
    if (!status.empty()) DrawText(status.c_str(), 52, GetScreenHeight() - 80, 16, ORANGE);
    DrawText("Strum/Up/Down: browse   Green/Enter: play   Red/Esc: main menu   F5: rescan", 52, GetScreenHeight() - 55, 15, GRAY);
    drawControllerHint(controllerConnected);
}

static void drawDisc3DV5(Vector3 center, float radius, float thickness, int sides, Color color) { DrawCylinder(center, radius, radius, thickness, sides, color); }

static void drawHighway3DV5(const Session& s, const Settings& cfg, const UiPrefs& ui, double now, uint8_t held,
                            double chartOffsetSeconds) {
    ClearBackground(cfg.background);
    const float roadWidth = ui.roadWidth, laneWidth = roadWidth / 5.0f, hitZ = 0.35f;
    const float farZ = 13.0f + 10.0f * ((cfg.highwayLength - 0.35f) / 0.60f);
    const double visibleSeconds = 2.45 / std::max(0.25f, cfg.highwaySpeed);
    Camera3D camera{}; camera.position = {0.0f, 6.4f, -6.8f}; camera.target = {0.0f, 0.15f, 6.4f}; camera.up = {0.0f, 1.0f, 0.0f}; camera.fovy = ui.cameraFov; camera.projection = CAMERA_PERSPECTIVE;
    BeginMode3D(camera);
    const float left = -roadWidth * 0.5f, right = roadWidth * 0.5f, nearZ = -0.35f, roadY = 0.0f;
    DrawTriangle3D({left, roadY, nearZ}, {right, roadY, farZ}, {right, roadY, nearZ}, cfg.highway);
    DrawTriangle3D({left, roadY, nearZ}, {left, roadY, farZ}, {right, roadY, farZ}, cfg.highway);
    for (int i = 0; i <= 5; ++i) { const float x = left + laneWidth * static_cast<float>(i); const Color line = (i == 0 || i == 5) ? alphaColor(RAYWHITE, 90) : alphaColor(RAYWHITE, 34); DrawLine3D({x, roadY + 0.018f, nearZ}, {x, roadY + 0.018f, farZ}, line); }
    if (ui.depthGuides) for (int i = 1; i <= 9; ++i) { const float t = static_cast<float>(i) / 10.0f; const float z = hitZ + t * (farZ - hitZ); DrawLine3D({left, roadY + 0.012f, z}, {right, roadY + 0.012f, z}, alphaColor(RAYWHITE, 18)); }
    auto laneX = [&](int lane) { return right - laneWidth * (static_cast<float>(lane) + 0.5f); };
    for (const auto& n : s.chart.notes) {
        if (n.missed || n.sustain <= 0.03) continue; const double dt = n.time - now; if (dt > visibleSeconds * 1.06 || dt + n.sustain < -0.20) continue;
        const float z0 = hitZ + static_cast<float>(dt / visibleSeconds) * (farZ - hitZ), z1 = hitZ + static_cast<float>((dt + n.sustain) / visibleSeconds) * (farZ - hitZ);
        const float startZ = std::max(nearZ, z0), endZ = std::min(farZ, z1); if (endZ <= startZ) continue;
        for (int lane = 0; lane < 5; ++lane) if (n.mask & (1 << lane)) { Color c = cfg.lanes[lane]; c.a = static_cast<unsigned char>(n.hit ? 65 : 155); DrawCube({laneX(lane), 0.055f, (startZ + endZ) * 0.5f}, laneWidth * 0.16f * ui.noteScale, 0.045f, std::max(0.02f, endZ - startZ), c); }
    }
    for (const auto& n : s.chart.notes) {
        if (n.missed) continue; const double dt = n.time - now; if (dt > visibleSeconds * 1.06 || dt < -0.22) continue; const float z = hitZ + static_cast<float>(dt / visibleSeconds) * (farZ - hitZ); if (z < nearZ || z > farZ) continue;
        for (int lane = 0; lane < 5; ++lane) if (n.mask & (1 << lane)) { Color c = cfg.lanes[lane]; if (n.hit) c.a = 70; const float radius = laneWidth * 0.31f * ui.noteScale; drawDisc3DV5({laneX(lane), 0.07f, z}, radius, 0.115f, 12, c); if (n.hopo || n.tap) { Color center = n.tap ? RAYWHITE : cfg.highway; center.a = n.hit ? 80 : 230; drawDisc3DV5({laneX(lane), 0.185f, z}, radius * 0.43f, 0.025f, 12, center); } }
    }
    DrawCube({0.0f, 0.075f, hitZ}, roadWidth + 0.22f, 0.065f, 0.10f, cfg.hitLine);
    for (int lane = 0; lane < 5; ++lane) { Color receptor = cfg.lanes[lane]; receptor.a = (held & (1 << lane)) ? 255 : 75; const float x = laneX(lane); drawDisc3DV5({x, 0.10f, hitZ - 0.12f}, laneWidth * 0.29f * ui.noteScale, 0.12f, 14, receptor); DrawCylinderWires({x, 0.10f, hitZ - 0.12f}, laneWidth * 0.30f * ui.noteScale, laneWidth * 0.30f * ui.noteScale, 0.125f, 14, alphaColor(RAYWHITE, 155)); }
    EndMode3D();
    if (s.song) { DrawText(s.song->name.c_str(), 28, 24, 26, RAYWHITE); DrawText(s.song->artist.c_str(), 30, 54, 17, GRAY); }
    DrawText(TextFormat("Score %lld", s.score), 28, 92, 20, LIGHTGRAY); DrawText(TextFormat("Combo %d", s.combo), 28, 118, 20, LIGHTGRAY);
    const int judged = s.hits + s.misses; const float accuracy = judged > 0 ? 100.0f * static_cast<float>(s.hits) / static_cast<float>(judged) : 100.0f;
    DrawText(TextFormat("Accuracy %.2f%%", accuracy), 28, 144, 20, LIGHTGRAY); DrawText(TextFormat("Offset %+.0f ms", cfg.audioOffsetMs), GetScreenWidth() - 175, 26, 16, GRAY);
    DrawText(TextFormat("Chart %+0.0f | delay %+0.0f ms", chartOffsetSeconds * 1000.0, s.song ? s.song->delayMs : 0.0f), GetScreenWidth() - 250, 49, 15, DARKGRAY);
}

static Sound createCalibrationClick() {
    constexpr unsigned int sampleRate = 48000, frames = 2400; constexpr double pi = 3.14159265358979323846;
    std::vector<short> samples(frames);
    for (unsigned int i = 0; i < frames; ++i) { const double t = static_cast<double>(i) / sampleRate; const double envelope = std::exp(-t * 55.0); const double tone = std::sin(2.0 * pi * 1100.0 * t) * 0.80 + std::sin(2.0 * pi * 2200.0 * t) * 0.20; samples[i] = static_cast<short>(std::clamp(tone * envelope, -1.0, 1.0) * 26000.0); }
    Wave wave{}; wave.frameCount = frames; wave.sampleRate = sampleRate; wave.sampleSize = 16; wave.channels = 1; wave.data = samples.data(); return LoadSoundFromWave(wave);
}

struct CalibrationBeat { Clock::time_point time{}; bool captured = false; };
struct CalibrationState {
    bool running = false, finished = false; int emitted = 0; Clock::time_point nextBeat{}; std::vector<CalibrationBeat> beats; std::vector<double> samplesMs; double suggestedMs = 0.0;
    void reset() { running = false; finished = false; emitted = 0; beats.clear(); samplesMs.clear(); suggestedMs = 0.0; }
    void start() { reset(); running = true; nextBeat = Clock::now() + std::chrono::milliseconds(900); }
    void update(const Sound& click, bool clickReady) { if (!running) return; const auto now = Clock::now(); while (emitted < 12 && now >= nextBeat) { if (clickReady) PlaySound(click); beats.push_back({nextBeat, false}); ++emitted; nextBeat += std::chrono::milliseconds(500); } if (emitted >= 12 && now > nextBeat + std::chrono::milliseconds(350)) { running = false; finished = true; computeSuggestion(); } }
    void capture(Clock::time_point when) { if (!running || beats.empty()) return; int best = -1; double bestAbs = 1e9; for (int i = 0; i < static_cast<int>(beats.size()); ++i) { if (beats[i].captured) continue; const double delta = std::chrono::duration<double, std::milli>(when - beats[i].time).count(); const double absDelta = std::abs(delta); if (absDelta < bestAbs && absDelta <= 300.0) { best = i; bestAbs = absDelta; } } if (best >= 0) { beats[best].captured = true; samplesMs.push_back(std::chrono::duration<double, std::milli>(when - beats[best].time).count()); } }
    void computeSuggestion() { if (samplesMs.size() < 4) { suggestedMs = 0.0; return; } std::vector<double> sorted = samplesMs; std::sort(sorted.begin(), sorted.end()); const size_t n = sorted.size(); suggestedMs = n % 2 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) * 0.5; suggestedMs = std::clamp(suggestedMs, -300.0, 300.0); }
};

static void drawCalibration(const CalibrationState& cal, const Settings& cfg, bool controllerConnected, bool audioReady) {
    ClearBackground(cfg.background); drawSectionTitle("Calibration", "Strum exactly when you hear each click"); Rectangle card{70, 145, static_cast<float>(GetScreenWidth() - 140), static_cast<float>(GetScreenHeight() - 260)}; drawPanel(card, alphaColor(RAYWHITE, 8));
    if (!audioReady) { drawCentered("Audio device is not available", 220, 28, ORANGE); drawCentered("Calibration needs working audio output.", 262, 18, GRAY); }
    else if (!cal.running && !cal.finished) { drawCentered("12 clicks • about six seconds", 210, 28, RAYWHITE); drawCentered("Use the guitar strum bar. Keyboard fallback: Space.", 252, 18, GRAY); drawCentered("Green / Enter to begin", 320, 22, LIGHTGRAY); }
    else if (cal.running) { DrawText(TextFormat("Click %d / 12", cal.emitted), 110, 190, 27, RAYWHITE); DrawText(TextFormat("Captured %d", static_cast<int>(cal.samplesMs.size())), 110, 228, 19, LIGHTGRAY); const float startX = 110.0f, gap = (card.width - 110.0f) / 12.0f; for (int i = 0; i < 12; ++i) { const float x = startX + i * gap; Color c = i < static_cast<int>(cal.beats.size()) ? (cal.beats[i].captured ? GREEN : LIGHTGRAY) : DARKGRAY; DrawCircle(static_cast<int>(x), 305, 11.0f, c); } drawCentered("Keep strumming on the audible click — don't chase the animation.", 370, 18, GRAY); }
    else { if (cal.samplesMs.size() >= 4) { drawCentered(TextFormat("Suggested timing offset: %+.0f ms", cal.suggestedMs), 210, 32, RAYWHITE); drawCentered(TextFormat("Based on %d usable samples", static_cast<int>(cal.samplesMs.size())), 258, 18, GRAY); drawCentered("Green / Enter: apply   Yellow/Blue: fine tune   Orange / R: retry", 335, 18, LIGHTGRAY); } else { drawCentered("Not enough clean samples", 215, 30, ORANGE); drawCentered("Retry and strum once on each click.", 260, 18, GRAY); drawCentered("Orange / R to retry", 330, 18, LIGHTGRAY); } }
    DrawText("Red / Esc: back", 72, GetScreenHeight() - 80, 16, GRAY); drawControllerHint(controllerConnected);
}

static void drawPauseMenu(int selected, const Session& session, const Settings& cfg) {
    ClearBackground(cfg.background); if (session.song) { DrawText(session.song->name.c_str(), 58, 48, 30, RAYWHITE); DrawText(session.song->artist.c_str(), 60, 84, 18, GRAY); } DrawText("Paused", 58, 132, 44, RAYWHITE); const std::vector<std::string> items = {"Resume", "Restart", "Settings", "Calibration", "Song Select", "Main Menu"}; drawMenuList(items, selected, 58.0f, 205.0f, 430.0f, 56.0f); DrawText("Start / Green: select   Red / Esc: resume", 58, GetScreenHeight() - 46, 16, GRAY);
}

static void drawInputOverlayV5(bool connected, int hz, uint16_t buttons) {
#ifdef _WIN32
    const int boxW = 430, boxH = 168, x = GetScreenWidth() - boxW - 18; DrawRectangle(x, 18, boxW, boxH, alphaColor(BLACK, 225)); DrawRectangleLines(x, 18, boxW, boxH, alphaColor(RAYWHITE, 45)); DrawText("INPUT DIAGNOSTICS", x + 18, 34, 18, RAYWHITE); DrawText(TextFormat("XInput: %s", connected ? "connected" : "not connected"), x + 18, 64, 17, connected ? GREEN : ORANGE); DrawText(TextFormat("Poll target: %d Hz", hz), x + 18, 88, 17, LIGHTGRAY); std::string pressed = "Held: "; for (const auto& [name, bit] : buttonNames()) if (buttons & bit) pressed += name + " "; DrawText(pressed.c_str(), x + 18, 113, 16, LIGHTGRAY); DrawText("F2 toggles this overlay", x + 18, 140, 15, GRAY);
#else
    (void)connected; (void)hz; (void)buttons;
#endif
}

static void drawHelpV5(const Settings& cfg) {
    const int w = std::min(820, GetScreenWidth() - 50), h = std::min(500, GetScreenHeight() - 50), x = (GetScreenWidth() - w) / 2, y = (GetScreenHeight() - h) / 2; DrawRectangle(x, y, w, h, alphaColor(BLACK, 242)); DrawRectangleLines(x, y, w, h, alphaColor(RAYWHITE, 60)); DrawText("GitarGame controls", x + 26, y + 24, 28, RAYWHITE); DrawText("Menus: strum = up/down, green = select, red = back, yellow/blue = adjust", x + 26, y + 72, 18, LIGHTGRAY); DrawText("Gameplay: frets A/S/J/K/L or guitar frets, Up/Down or strum bar", x + 26, y + 106, 18, LIGHTGRAY); DrawText("Start / Esc: pause    R: restart    F2: input diagnostics    F3: bind controller", x + 26, y + 140, 18, LIGHTGRAY); DrawText("F7/F8: timing -/+ 5ms (Shift = 25ms)    F9: reset timing", x + 26, y + 174, 18, LIGHTGRAY); DrawText("Calibration is available from the main menu and Settings > Audio & Timing.", x + 26, y + 224, 17, GRAY); DrawText(TextFormat("Current: %d FPS | %d Hz input | %.2fx highway | %.0f ms window", cfg.fpsCap, cfg.inputPollHz, cfg.highwaySpeed, cfg.hitWindowMs), x + 26, y + 264, 17, GRAY); DrawText("Press F1 to close", x + 26, y + h - 42, 16, GRAY);
}

static int cycleChoice(int current, const std::vector<int>& values, int dir) { int best = 0, bestDistance = INT_MAX; for (int i = 0; i < static_cast<int>(values.size()); ++i) { const int d = std::abs(values[i] - current); if (d < bestDistance) { bestDistance = d; best = i; } } return values[wrapIndex(best + dir, static_cast<int>(values.size()))]; }

int main(int argc, char** argv) {
    SetTraceLogLevel(LOG_WARNING);
    const fs::path exeDir = fs::absolute(fs::path(argc > 0 ? argv[0] : "GitarGame.exe")).parent_path();
    const fs::path configPath = exeDir / "config.ini", uiPath = exeDir / "ui.ini";
    Settings cfg; if (!loadConfig(configPath, cfg)) saveConfig(configPath, cfg); UiPrefs ui; if (!loadUiPrefs(uiPath, ui)) saveUiPrefs(uiPath, ui);
    if (cfg.vsync) SetConfigFlags(FLAG_VSYNC_HINT | FLAG_WINDOW_RESIZABLE | FLAG_MSAA_4X_HINT); else SetConfigFlags(FLAG_WINDOW_RESIZABLE | FLAG_MSAA_4X_HINT);
    InitWindow(cfg.windowWidth, cfg.windowHeight, "GitarGame"); SetExitKey(KEY_NULL); if (cfg.fullscreen) ToggleFullscreen(); if (cfg.fpsCap > 0) SetTargetFPS(cfg.fpsCap); InitAudioDevice(); SetMasterVolume(cfg.masterVolume);
    Sound calibrationClick{}; bool calibrationClickReady = false; if (IsAudioDeviceReady()) { calibrationClick = createCalibrationClick(); calibrationClickReady = calibrationClick.frameCount > 0; }
#ifdef _WIN32
    XInputPoller poller(cfg.inputPollHz);
#endif
    auto resolveSongsRoot = [&]() {
#ifdef _WIN32
        const std::wstring wide = utf8ToWide(cfg.songsDirectory); fs::path root = wide.empty() ? fs::path(cfg.songsDirectory) : fs::path(wide);
#else
        fs::path root = fs::path(cfg.songsDirectory);
#endif
        if (root.is_relative()) root = exeDir / root; return root;
    };
    fs::path songsRoot = resolveSongsRoot(); auto songs = scanSongs(songsRoot); auto songMeta = buildSongMeta(songs); ArtTexture artwork; int selectedSong = 0, artworkSong = -1;
    auto refreshArtwork = [&]() { if (!ui.showAlbumArt || songs.empty() || selectedSong < 0 || selectedSong >= static_cast<int>(songs.size())) { artwork.clear(); artworkSong = selectedSong; return; } if (artworkSong == selectedSong) return; artworkSong = selectedSong; artwork.load(songMeta[selectedSong].artPath); };
    refreshArtwork();
    auto rescanLibrary = [&]() { songsRoot = resolveSongsRoot(); songs = scanSongs(songsRoot); songMeta = buildSongMeta(songs); selectedSong = std::clamp(selectedSong, 0, std::max(0, static_cast<int>(songs.size()) - 1)); artworkSong = -1; refreshArtwork(); };
    Session session; double activeChartOffset = 0.0; auto activateSongTiming = [&]() { if (!session.song) { activeChartOffset = 0.0; return; } activeChartOffset = readChartOffsetSecondsV5(session.song->directory / "notes.chart"); logSongTimingV5(session, cfg, activeChartOffset); };
    AppScreen screen = AppScreen::MainMenu, settingsReturn = AppScreen::MainMenu, calibrationReturn = AppScreen::MainMenu, bindingReturn = AppScreen::MainMenu;
    int mainIndex = 0, pauseIndex = 0, categoryIndex = 0, settingRow = 0; SettingsCategory activeCategory = SettingsCategory::Gameplay; bool showHelp = false, showInput = false, binding = false; int bindIndex = 0; std::string status; CalibrationState calibration; bool shouldQuit = false;
#ifdef _WIN32
    const std::vector<std::string> bindLabels = {"Green", "Red", "Yellow", "Blue", "Orange", "Strum Up", "Strum Down", "Star Power", "Start"};
    auto setBinding = [&](int index, WORD bit) { WORD* targets[] = {&cfg.green, &cfg.red, &cfg.yellow, &cfg.blue, &cfg.orange, &cfg.strumUp, &cfg.strumDown, &cfg.starPower, &cfg.start}; if (index >= 0 && index < static_cast<int>(std::size(targets))) *targets[index] = bit; };
#else
    const std::vector<std::string> bindLabels;
#endif
    auto beginBinding = [&](AppScreen returnScreen) {
#ifdef _WIN32
        binding = true; bindIndex = 0; bindingReturn = returnScreen; status.clear();
#else
        (void)returnScreen;
#endif
    };
    auto stopSongToBrowser = [&]() { unloadStems(session.stems); session.playing = false; session.song.reset(); activeChartOffset = 0.0; screen = AppScreen::SongBrowser; };
    if (argc >= 2) { fs::path direct = argv[1]; if (fs::is_regular_file(direct) && lower(direct.filename().string()) == "notes.chart") direct = direct.parent_path(); if (fs::exists(direct / "notes.chart")) { SongInfo info = readSongInfo(direct); if (loadSong(session, info)) { activateSongTiming(); screen = AppScreen::Playing; } else status = session.error; } }

    while (!shouldQuit && !WindowShouldClose()) {
        if (IsKeyPressed(KEY_F1)) showHelp = !showHelp; if (IsKeyPressed(KEY_F2)) showInput = !showInput;
#ifdef _WIN32
        auto events = poller.takeEvents();
#else
        std::vector<int> events;
#endif
        UiNav nav = keyboardNav();
#ifdef _WIN32
        mergeGuitarNav(nav, events, cfg);
#endif
        if (IsKeyPressed(KEY_F3) && !binding && screen != AppScreen::Playing) beginBinding(screen);
#ifdef _WIN32
        if (binding) { if (IsKeyPressed(KEY_ESCAPE)) { binding = false; screen = bindingReturn; status = "Binding cancelled."; } else { for (const auto& ev : events) { if (!ev.down || !binding) continue; setBinding(bindIndex, ev.bit); ++bindIndex; if (bindIndex >= static_cast<int>(bindLabels.size())) { binding = false; saveConfig(configPath, cfg); screen = bindingReturn; status = "Controller bindings saved."; } } } }
#endif
        if (IsKeyPressed(KEY_F6) && !binding) { Settings updated = cfg; UiPrefs updatedUi = ui; if (loadConfig(configPath, updated)) cfg = updated; if (loadUiPrefs(uiPath, updatedUi)) ui = updatedUi; if (cfg.fpsCap > 0) SetTargetFPS(cfg.fpsCap); else SetTargetFPS(0); SetMasterVolume(cfg.masterVolume);
#ifdef _WIN32
            poller.restart(cfg.inputPollHz);
#endif
            rescanLibrary(); status = "Configuration reloaded."; }

        if (!binding && !showHelp) {
            switch (screen) {
                case AppScreen::MainMenu:
                    if (nav.up) mainIndex = wrapIndex(mainIndex - 1, 5); if (nav.down) mainIndex = wrapIndex(mainIndex + 1, 5); if (nav.accept || nav.start) { if (mainIndex == 0) { screen = AppScreen::SongBrowser; status.clear(); refreshArtwork(); } else if (mainIndex == 1) { settingsReturn = AppScreen::MainMenu; screen = AppScreen::SettingsCategories; categoryIndex = 0; } else if (mainIndex == 2) { calibrationReturn = AppScreen::MainMenu; calibration.reset(); screen = AppScreen::Calibration; } else if (mainIndex == 3) beginBinding(AppScreen::MainMenu); else if (mainIndex == 4) shouldQuit = true; } break;
                case AppScreen::SongBrowser:
                    if (nav.up && !songs.empty()) { selectedSong = wrapIndex(selectedSong - 1, static_cast<int>(songs.size())); artworkSong = -1; refreshArtwork(); } if (nav.down && !songs.empty()) { selectedSong = wrapIndex(selectedSong + 1, static_cast<int>(songs.size())); artworkSong = -1; refreshArtwork(); } if (IsKeyPressed(KEY_F5)) { rescanLibrary(); status = "Song library rescanned."; } if ((nav.accept || nav.start) && !songs.empty()) { if (loadSong(session, songs[selectedSong])) { activateSongTiming(); screen = AppScreen::Playing; status.clear(); } else status = session.error; } if (nav.back) { screen = AppScreen::MainMenu; status.clear(); } break;
                case AppScreen::SettingsCategories: { const int count = static_cast<int>(SettingsCategory::Count); if (nav.up) categoryIndex = wrapIndex(categoryIndex - 1, count); if (nav.down) categoryIndex = wrapIndex(categoryIndex + 1, count); if (nav.accept || nav.start) { activeCategory = static_cast<SettingsCategory>(categoryIndex); settingRow = 0; screen = AppScreen::SettingsPage; } if (nav.back) screen = settingsReturn; break; }
                case AppScreen::SettingsPage: {
                    const int rows = settingsRowCount(activeCategory); if (nav.up) settingRow = wrapIndex(settingRow - 1, rows); if (nav.down) settingRow = wrapIndex(settingRow + 1, rows); const int dir = nav.left ? -1 : (nav.right ? 1 : 0); bool saveCore = false, savePresentation = false;
                    if (dir != 0) {
                        switch (activeCategory) {
                            case SettingsCategory::Gameplay: if (settingRow == 0) { cfg.highwaySpeed = clampFloat(cfg.highwaySpeed + dir * 0.05f, 0.25f, 5.0f); saveCore = true; } else if (settingRow == 1) { cfg.highwayLength = clampFloat(cfg.highwayLength + dir * 0.02f, 0.35f, 0.95f); saveCore = true; } else if (settingRow == 2) { cfg.hitWindowMs = clampFloat(cfg.hitWindowMs + dir * 5.0f, 20.0f, 250.0f); saveCore = true; } else if (settingRow == 3) { ui.noteScale = clampFloat(ui.noteScale + dir * 0.05f, 0.55f, 1.60f); savePresentation = true; } break;
                            case SettingsCategory::Audio: if (settingRow == 0) { cfg.masterVolume = clampFloat(cfg.masterVolume + dir * 0.05f, 0.0f, 1.0f); SetMasterVolume(cfg.masterVolume); saveCore = true; } else if (settingRow == 1) { cfg.audioOffsetMs = clampFloat(cfg.audioOffsetMs + dir * 5.0f, -500.0f, 500.0f); saveCore = true; } break;
                            case SettingsCategory::Video: if (settingRow == 0) { cfg.fpsCap = cycleChoice(cfg.fpsCap, {60, 120, 144, 165, 240, 360, 500, 1000, 0}, dir); if (cfg.fpsCap > 0) SetTargetFPS(cfg.fpsCap); else SetTargetFPS(0); saveCore = true; } break;
                            case SettingsCategory::Appearance:
                                if (settingRow == 0) { ui.paletteIndex = wrapIndex((ui.paletteIndex < 0 ? 0 : ui.paletteIndex) + dir, 4); const char* presets[] = {"classic", "neon", "pastel", "mono"}; applyPreset(cfg, presets[ui.paletteIndex]); saveCore = true; savePresentation = true; }
                                else if (settingRow >= 1 && settingRow <= 5) { const int lane = settingRow - 1; const int swatch = wrapIndex(nearestSwatch(cfg.lanes[lane]) + dir, static_cast<int>(laneSwatches().size())); cfg.lanes[lane] = laneSwatches()[swatch].second; cfg.colorScheme = "custom"; ui.paletteIndex = -1; saveCore = true; savePresentation = true; }
                                else if (settingRow == 6) { ui.cameraFov = clampFloat(ui.cameraFov + dir * 1.0f, 30.0f, 70.0f); savePresentation = true; } else if (settingRow == 7) { ui.roadWidth = clampFloat(ui.roadWidth + dir * 0.2f, 5.0f, 11.0f); savePresentation = true; } break;
                            case SettingsCategory::Input: if (settingRow == 0) { cfg.inputPollHz = cycleChoice(cfg.inputPollHz, {125, 250, 500, 1000, 2000, 4000}, dir);
#ifdef _WIN32
                                    poller.restart(cfg.inputPollHz);
#endif
                                    saveCore = true; } break;
                            default: break;
                        }
                    }
                    if (nav.accept || nav.start) {
                        switch (activeCategory) {
                            case SettingsCategory::Audio: if (settingRow == 2) { calibrationReturn = AppScreen::SettingsPage; calibration.reset(); screen = AppScreen::Calibration; } break;
                            case SettingsCategory::Video: if (settingRow == 1) { cfg.vsync = !cfg.vsync; status = "VSync change will apply next launch."; saveCore = true; } else if (settingRow == 2) { cfg.fullscreen = !cfg.fullscreen; ToggleFullscreen(); saveCore = true; } else if (settingRow == 3) { ui.showFps = !ui.showFps; savePresentation = true; } break;
                            case SettingsCategory::Appearance: if (settingRow == 8) { ui.depthGuides = !ui.depthGuides; savePresentation = true; } else if (settingRow == 9) { ui.showAlbumArt = !ui.showAlbumArt; artworkSong = -1; refreshArtwork(); savePresentation = true; } else if (settingRow == 10) { applyPreset(cfg, "classic"); ui = UiPrefs{}; artworkSong = -1; refreshArtwork(); saveCore = true; savePresentation = true; status = "Visual defaults restored."; } break;
                            case SettingsCategory::Input: if (settingRow == 1) beginBinding(AppScreen::SettingsPage); else if (settingRow == 2) showInput = !showInput; break;
                            case SettingsCategory::Library:
#ifdef _WIN32
                                if (settingRow == 0) { if (auto chosen = chooseSongsFolder()) { cfg.songsDirectory = *chosen; saveCore = true; rescanLibrary(); status = "Songs folder updated."; } }
#endif
                                if (settingRow == 1) { rescanLibrary(); status = "Song library rescanned."; } break;
                            default: break;
                        }
                    }
                    if (saveCore) saveConfig(configPath, cfg); if (savePresentation) saveUiPrefs(uiPath, ui); if (nav.back) screen = AppScreen::SettingsCategories; break;
                }
                case AppScreen::Calibration:
                    calibration.update(calibrationClick, calibrationClickReady);
                    if (calibration.running) {
#ifdef _WIN32
                        for (const auto& ev : events) if (ev.down && (ev.bit == cfg.strumUp || ev.bit == cfg.strumDown)) calibration.capture(ev.when);
#endif
                        if (IsKeyPressed(KEY_SPACE)) calibration.capture(Clock::now()); if (IsKeyPressed(KEY_ESCAPE)) { calibration.reset(); screen = calibrationReturn; }
                    } else if (!calibration.finished) { if (nav.accept || nav.start) calibration.start(); if (nav.back) screen = calibrationReturn; }
                    else { if (nav.left) calibration.suggestedMs = std::clamp(calibration.suggestedMs - 5.0, -500.0, 500.0); if (nav.right) calibration.suggestedMs = std::clamp(calibration.suggestedMs + 5.0, -500.0, 500.0); if (nav.accept || nav.start) { if (calibration.samplesMs.size() >= 4) { cfg.audioOffsetMs = static_cast<float>(calibration.suggestedMs); saveConfig(configPath, cfg); status = TextFormat("Calibration applied: %+.0f ms", cfg.audioOffsetMs); } }
#ifdef _WIN32
                        bool orange = false; for (const auto& ev : events) if (ev.down && ev.bit == cfg.orange) orange = true;
#else
                        bool orange = false;
#endif
                        if (orange || IsKeyPressed(KEY_R)) calibration.start(); if (nav.back) screen = calibrationReturn; }
                    break;
                case AppScreen::Playing: {
                    for (auto& stem : session.stems) UpdateMusicStream(stem.music); const double now = correctedSongTimeV5(session, cfg, activeChartOffset), window = cfg.hitWindowMs / 1000.0; advanceMisses(session, now, window); bool pauseRequested = IsKeyPressed(KEY_ESCAPE);
#ifdef _WIN32
                    const WORD xb = poller.buttons(); const uint8_t gamepadHeld = heldMaskFromXInput(xb, cfg); for (const auto& ev : events) { if (!ev.down) continue; if (ev.bit == cfg.start) { pauseRequested = true; continue; } if (ev.bit == cfg.strumUp || ev.bit == cfg.strumDown) tryHit(session, now, window, gamepadHeld, true); uint8_t fretPressed = 0; if (ev.bit == cfg.green) fretPressed = 1 << 0; else if (ev.bit == cfg.red) fretPressed = 1 << 1; else if (ev.bit == cfg.yellow) fretPressed = 1 << 2; else if (ev.bit == cfg.blue) fretPressed = 1 << 3; else if (ev.bit == cfg.orange) fretPressed = 1 << 4; if (fretPressed) tryHit(session, now, window, gamepadHeld, false, fretPressed); }
#endif
                    const uint8_t kbHeld = heldMaskFromKeyboard(); if (IsKeyPressed(KEY_UP) || IsKeyPressed(KEY_DOWN)) tryHit(session, now, window, kbHeld, true); if (IsKeyPressed(KEY_A)) tryHit(session, now, window, kbHeld, false, 1 << 0); if (IsKeyPressed(KEY_S)) tryHit(session, now, window, kbHeld, false, 1 << 1); if (IsKeyPressed(KEY_J)) tryHit(session, now, window, kbHeld, false, 1 << 2); if (IsKeyPressed(KEY_K)) tryHit(session, now, window, kbHeld, false, 1 << 3); if (IsKeyPressed(KEY_L)) tryHit(session, now, window, kbHeld, false, 1 << 4);
                    const float step = (IsKeyDown(KEY_LEFT_SHIFT) || IsKeyDown(KEY_RIGHT_SHIFT)) ? 25.0f : 5.0f; if (IsKeyPressed(KEY_F7)) { cfg.audioOffsetMs = clampFloat(cfg.audioOffsetMs - step, -500.0f, 500.0f); saveConfig(configPath, cfg); } if (IsKeyPressed(KEY_F8)) { cfg.audioOffsetMs = clampFloat(cfg.audioOffsetMs + step, -500.0f, 500.0f); saveConfig(configPath, cfg); } if (IsKeyPressed(KEY_F9)) { cfg.audioOffsetMs = 0.0f; saveConfig(configPath, cfg); } if (IsKeyPressed(KEY_R)) playFromStart(session); if (IsKeyPressed(KEY_SPACE)) togglePause(session); if (pauseRequested) { if (!session.paused) togglePause(session); pauseIndex = 0; screen = AppScreen::PauseMenu; } break;
                }
                case AppScreen::PauseMenu:
                    if (nav.up) pauseIndex = wrapIndex(pauseIndex - 1, 6); if (nav.down) pauseIndex = wrapIndex(pauseIndex + 1, 6); if (nav.back) { if (session.paused) togglePause(session); screen = AppScreen::Playing; } if (nav.accept || nav.start) { if (pauseIndex == 0) { if (session.paused) togglePause(session); screen = AppScreen::Playing; } else if (pauseIndex == 1) { playFromStart(session); screen = AppScreen::Playing; } else if (pauseIndex == 2) { settingsReturn = AppScreen::PauseMenu; screen = AppScreen::SettingsCategories; categoryIndex = 0; } else if (pauseIndex == 3) { calibrationReturn = AppScreen::PauseMenu; calibration.reset(); screen = AppScreen::Calibration; } else if (pauseIndex == 4) stopSongToBrowser(); else if (pauseIndex == 5) { unloadStems(session.stems); session.song.reset(); session.playing = false; screen = AppScreen::MainMenu; } } break;
            }
        }

        BeginDrawing();
#ifdef _WIN32
        const bool controllerConnected = poller.connected();
#else
        const bool controllerConnected = false;
#endif
        switch (screen) {
            case AppScreen::MainMenu: drawMainMenu(mainIndex, controllerConnected, cfg); break;
            case AppScreen::SongBrowser: drawSongBrowser(songs, songMeta, selectedSong, artwork, cfg, ui, status, controllerConnected); break;
            case AppScreen::SettingsCategories: drawSettingsCategories(categoryIndex, cfg, controllerConnected); break;
            case AppScreen::SettingsPage: drawSettingsPage(activeCategory, settingRow, cfg, ui, songsRoot, songs.size(), showInput, status, controllerConnected); break;
            case AppScreen::Calibration: drawCalibration(calibration, cfg, controllerConnected, IsAudioDeviceReady()); break;
            case AppScreen::Playing: {
#ifdef _WIN32
                const uint8_t held = static_cast<uint8_t>(heldMaskFromKeyboard() | heldMaskFromXInput(poller.buttons(), cfg));
#else
                const uint8_t held = heldMaskFromKeyboard();
#endif
                drawHighway3DV5(session, cfg, ui, correctedSongTimeV5(session, cfg, activeChartOffset), held, activeChartOffset); break;
            }
            case AppScreen::PauseMenu: drawPauseMenu(pauseIndex, session, cfg); break;
        }
#ifdef _WIN32
        if (showInput) drawInputOverlayV5(poller.connected(), poller.hz(), poller.buttons());
        if (binding) { const int w = std::min(650, GetScreenWidth() - 50), h = 230, x = (GetScreenWidth() - w) / 2, y = (GetScreenHeight() - h) / 2; DrawRectangle(x, y, w, h, alphaColor(BLACK, 246)); DrawRectangleLines(x, y, w, h, alphaColor(RAYWHITE, 70)); DrawText("Controller binding", x + 26, y + 25, 28, RAYWHITE); DrawText(poller.connected() ? "XInput guitar detected" : "Waiting for XInput device...", x + 26, y + 65, 17, poller.connected() ? GREEN : ORANGE); if (bindIndex < static_cast<int>(bindLabels.size())) { DrawText(TextFormat("Press: %s", bindLabels[bindIndex].c_str()), x + 26, y + 108, 30, RAYWHITE); DrawText(TextFormat("%d / %d", bindIndex + 1, static_cast<int>(bindLabels.size())), x + 26, y + 152, 17, GRAY); } DrawText("Esc cancels", x + w - 125, y + h - 34, 15, GRAY); }
#endif
        if (showHelp) drawHelpV5(cfg); if (ui.showFps) DrawFPS(GetScreenWidth() - 92, GetScreenHeight() - 28); EndDrawing();
    }

    artwork.clear(); unloadStems(session.stems); if (calibrationClickReady) UnloadSound(calibrationClick); CloseAudioDevice(); CloseWindow(); return 0;
}
