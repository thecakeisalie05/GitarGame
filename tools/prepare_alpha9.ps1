param(
    [Parameter(Mandatory=$true)][string]$InputPath,
    [Parameter(Mandatory=$true)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$alpha8 = Join-Path $PSScriptRoot 'prepare_alpha8.ps1'
& $alpha8 -InputPath $InputPath -OutputPath $OutputPath
if (-not (Test-Path $OutputPath)) { throw 'alpha.8 source preparation did not produce an output file before alpha.9 patching' }

# ---------------------------------------------------------------------------
# Patch the generated legacy core: song discovery, MIDI chart loading,
# Opus stem compatibility and clean-install defaults.
# ---------------------------------------------------------------------------
$generatedDir = Split-Path -Parent $OutputPath
$legacyPath = Join-Path $generatedDir 'main.cpp'
$legacy = [System.IO.File]::ReadAllText($legacyPath)

$legacy = $legacy.Replace('#include "chart_engine.h"', @'
#include "chart_engine.h"
#include "midi_chart.h"
#include "opus_mix.h"
#include <memory>
'@.Trim())

# Clean-install defaults requested for the alpha.9 usability pass.
$legacy = $legacy.Replace('    int windowHeight = 720;' + "`r`n" + '    bool fullscreen = false;', '    int windowHeight = 720;' + "`r`n" + '    bool nativeResolution = true;' + "`r`n" + '    bool fullscreen = true;')
$legacy = $legacy.Replace('    int windowHeight = 720;' + "`n" + '    bool fullscreen = false;', '    int windowHeight = 720;' + "`n" + '    bool nativeResolution = true;' + "`n" + '    bool fullscreen = true;')
$legacy = $legacy.Replace('    int fpsCap = 500;', '    int fpsCap = 0;')
$legacy = $legacy.Replace('    float highwaySpeed = 1.0f;', '    float highwaySpeed = 1.75f;')
$legacy = $legacy.Replace('    float highwayLength = 0.82f;', '    float highwayLength = 0.95f;')
$legacy = $legacy.Replace('    std::string colorScheme = "classic";', '    std::string colorScheme = "neon";')
$legacy = $legacy.Replace('    Color background = {16, 17, 22, 255};', '    Color background = {4, 6, 12, 255};')
$legacy = $legacy.Replace('    Color highway = {26, 29, 37, 255};', '    Color highway = {11, 14, 24, 255};')
$legacy = $legacy.Replace('    Color hitLine = {245, 245, 245, 255};', '    Color hitLine = {230, 250, 255, 255};')
$legacy = $legacy.Replace('        {53, 208, 79, 255}, {239, 51, 64, 255}, {255, 210, 63, 255}, {38, 132, 255, 255}, {255, 139, 44, 255}', '        {0, 255, 140, 255}, {255, 45, 95, 255}, {255, 235, 40, 255}, {40, 150, 255, 255}, {255, 120, 15, 255}')

# Persist native-resolution mode alongside the existing video settings.
$legacy = $legacy.Replace('            else if (key == "fullscreen") s.fullscreen = parseBool(value, s.fullscreen);', '            else if (key == "native_resolution") s.nativeResolution = parseBool(value, s.nativeResolution);' + "`r`n" + '            else if (key == "fullscreen") s.fullscreen = parseBool(value, s.fullscreen);')
$legacy = $legacy.Replace('            else if (key == "fullscreen") s.fullscreen = parseBool(value, s.fullscreen);', '            else if (key == "native_resolution") s.nativeResolution = parseBool(value, s.nativeResolution);' + "`n" + '            else if (key == "fullscreen") s.fullscreen = parseBool(value, s.fullscreen);')
$legacy = $legacy.Replace('    out << "fullscreen = " << (s.fullscreen ? "true" : "false") << "\nvsync = " << (s.vsync ? "true" : "false") << "\n";', '    out << "native_resolution = " << (s.nativeResolution ? "true" : "false") << "\n";' + "`r`n" + '    out << "fullscreen = " << (s.fullscreen ? "true" : "false") << "\nvsync = " << (s.vsync ? "true" : "false") << "\n";')

# Discover both text charts and standard Rock Band/Guitar Hero MIDI packages.
$scanPattern = '(?ms)^static std::vector<SongInfo> scanSongs\(const fs::path& root\) \{.*?^\}\r?\n\r?\n#include "chart_engine.h"'
$scanReplacement = @'
static bool isSongChartFileV9(const fs::path& path) {
    const std::string name = lower(path.filename().string());
    return name == "notes.chart" || name == "notes.mid" || name == "notes.midi";
}

static bool directoryHasSongChartV9(const fs::path& dir) {
    std::error_code ec;
    return fs::is_regular_file(dir / "notes.chart", ec) ||
           fs::is_regular_file(dir / "notes.mid", ec) ||
           fs::is_regular_file(dir / "notes.midi", ec);
}

static std::vector<SongInfo> scanSongs(const fs::path& root) {
    std::vector<SongInfo> songs;
    std::error_code ec;
    if (!fs::exists(root, ec)) fs::create_directories(root, ec);
    if (directoryHasSongChartV9(root)) songs.push_back(readSongInfo(root));
    fs::recursive_directory_iterator it(root, fs::directory_options::skip_permission_denied, ec), end;
    for (; !ec && it != end; it.increment(ec)) {
        if (!it->is_regular_file(ec)) continue;
        if (isSongChartFileV9(it->path())) songs.push_back(readSongInfo(it->path().parent_path()));
    }
    std::sort(songs.begin(), songs.end(), [](const auto& a, const auto& b) {
        if (lower(a.artist) == lower(b.artist)) return lower(a.name) < lower(b.name);
        return lower(a.artist) < lower(b.artist);
    });
    songs.erase(std::unique(songs.begin(), songs.end(), [](const auto& a, const auto& b) { return a.directory == b.directory; }), songs.end());
#ifdef _WIN32
    ggdiag::log("Song scan complete: " + std::to_string(songs.size()) + " playable chart package(s) found under " + root.string());
#endif
    return songs;
}

#include "chart_engine.h"
'@
$scanUpdated = [regex]::Replace($legacy, $scanPattern, $scanReplacement, 1)
if ($scanUpdated -eq $legacy) { throw 'Could not replace song scanner for alpha.9' }
$legacy = $scanUpdated

# Keep decoded Opus WAV memory alive for as long as raylib's Music object uses it.
$legacy = $legacy.Replace('struct Stem { Music music{}; fs::path path; };', 'struct Stem { Music music{}; fs::path path; std::shared_ptr<std::vector<unsigned char>> backing; };')

$loadStemsPattern = '(?ms)^static std::vector<Stem> loadStems\(const fs::path& dir\) \{.*?^\}\r?\n\r?\nstatic void unloadStems'
$loadStemsReplacement = @'
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
        if (m.ctxData != nullptr) stems.push_back({m, path, {}});
    }
    if (!stems.empty()) return stems;

    // raylib 5.5 does not decode Ogg Opus. Rock Band/YARG packages commonly use
    // multiple .opus stems, so decode/mix them into one in-memory PCM WAV and
    // then reuse the normal raylib Music transport and timing clock.
    std::string opusError;
    auto mixed = opusmix::mixDirectory(dir, opusError);
    if (!mixed) {
#ifdef _WIN32
        if (!opusError.empty() && opusError != "No .opus stems found") ggdiag::log("Opus load failed: " + opusError);
#endif
        return stems;
    }
    auto backing = std::make_shared<std::vector<unsigned char>>(std::move(mixed->wavBytes));
    if (backing->size() > static_cast<size_t>(std::numeric_limits<int>::max())) return stems;
    Music m = LoadMusicStreamFromMemory(".wav", backing->data(), static_cast<int>(backing->size()));
    if (m.ctxData != nullptr) {
        stems.push_back({m, dir / "<mixed opus stems>", backing});
#ifdef _WIN32
        ggdiag::log("Loaded Opus package: mixed " + std::to_string(mixed->stemCount) + " stem(s), duration_s=" + std::to_string(mixed->durationSeconds));
#endif
    }
    return stems;
}

static void unloadStems
'@
$stemsUpdated = [regex]::Replace($legacy, $loadStemsPattern, $loadStemsReplacement, 1)
if ($stemsUpdated -eq $legacy) { throw 'Could not replace audio stem loader for alpha.9' }
$legacy = $stemsUpdated

# Prefer notes.chart when both encodings exist; otherwise load notes.mid/notes.midi.
$chartLoadOld = '    auto chart = parseChart(info.directory / "notes.chart", err);'
$chartLoadNew = @'
    std::optional<ChartData> chart;
    std::error_code chartEc;
    if (fs::is_regular_file(info.directory / "notes.chart", chartEc)) {
        chart = parseChart(info.directory / "notes.chart", err);
    } else if (fs::is_regular_file(info.directory / "notes.mid", chartEc)) {
        chart = midichart::parse(info.directory / "notes.mid", err);
    } else if (fs::is_regular_file(info.directory / "notes.midi", chartEc)) {
        chart = midichart::parse(info.directory / "notes.midi", err);
    } else {
        err = "No notes.chart, notes.mid, or notes.midi found";
    }
'@
if (-not $legacy.Contains($chartLoadOld)) { throw 'Could not locate chart load site for alpha.9' }
$legacy = $legacy.Replace($chartLoadOld, $chartLoadNew.TrimEnd())

[System.IO.File]::WriteAllText($legacyPath, $legacy, [System.Text.UTF8Encoding]::new($false))

# ---------------------------------------------------------------------------
# Patch the generated UI shell: requested appearance defaults and native mode.
# ---------------------------------------------------------------------------
$text = [System.IO.File]::ReadAllText($OutputPath)
$text = $text.Replace('v0.1.0-alpha.8', 'v0.1.0-alpha.9')
$text = $text.Replace('    float cameraFov = 44.0f;', '    float cameraFov = 50.0f;')
$text = $text.Replace('    float roadWidth = 7.4f;', '    float roadWidth = 7.0f;')
$text = $text.Replace('    int paletteIndex = 0;', '    int paletteIndex = 1;')

# At startup, a native-resolution fullscreen default should use the monitor's
# current mode rather than stretching a historical 1280x720 window size.
$startupMarker = '    InitWindow(cfg.windowWidth, cfg.windowHeight, "GitarGame");'
$startupReplacement = @'
    InitWindow(cfg.windowWidth, cfg.windowHeight, "GitarGame");
    if (cfg.nativeResolution) {
        const int monitor = GetCurrentMonitor();
        const int nativeWidth = GetMonitorWidth(monitor);
        const int nativeHeight = GetMonitorHeight(monitor);
        if (nativeWidth > 0 && nativeHeight > 0) {
            cfg.windowWidth = nativeWidth;
            cfg.windowHeight = nativeHeight;
            SetWindowSize(nativeWidth, nativeHeight);
        }
    }
'@
if (-not $text.Contains($startupMarker)) { throw 'Could not locate InitWindow startup site for native resolution' }
$text = $text.Replace($startupMarker, $startupReplacement.TrimEnd())

[System.IO.File]::WriteAllText($OutputPath, $text, [System.Text.UTF8Encoding]::new($false))
Write-Host "Prepared alpha.9 MIDI/Opus song compatibility and requested defaults: $OutputPath"
