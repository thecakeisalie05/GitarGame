param(
    [Parameter(Mandatory=$true)][string]$InputPath,
    [Parameter(Mandatory=$true)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$text = [System.IO.File]::ReadAllText($InputPath)
$sourceDir = Split-Path -Parent $InputPath
$generatedDir = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Force -Path $generatedDir | Out-Null

# Keep the lightweight PowerShell-backed native folder chooser used by alpha.5/6.
$includePattern = '(?ms)^#ifdef _WIN32\r?\n#include <objbase\.h>\r?\n#include <shobjidl\.h>\r?\n#endif'
$includeReplacement = @'
#ifdef _WIN32
#ifdef PlaySound
#undef PlaySound
#endif
#endif
#include <cstdio>
'@
$text = [regex]::Replace($text, $includePattern, $includeReplacement, 1)

$pickerPattern = '(?ms)^static std::optional<std::string> chooseSongsFolder\(\) \{.*?^\}\r?\n#endif'
$pickerReplacement = @'
static std::optional<std::string> chooseSongsFolder() {
    const char* command =
        "powershell.exe -NoProfile -STA -Command \""
        "$OutputEncoding=[Console]::OutputEncoding=[Text.UTF8Encoding]::new();"
        "Add-Type -AssemblyName System.Windows.Forms;"
        "$d=New-Object System.Windows.Forms.FolderBrowserDialog;"
        "$d.Description='Choose GitarGame songs folder';"
        "if($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK){[Console]::Write($d.SelectedPath)}"
        "\"";
    FILE* pipe = _popen(command, "r");
    if (!pipe) return std::nullopt;
    std::string output;
    char buffer[2048]{};
    while (std::fgets(buffer, static_cast<int>(sizeof(buffer)), pipe)) output += buffer;
    const int code = _pclose(pipe);
    output = trim(output);
    if (code != 0 || output.empty()) return std::nullopt;
    return output;
}
#endif
'@
$text = [regex]::Replace($text, $pickerPattern, $pickerReplacement, 1)

# Version label lives in the UI source, but release source remains intentionally reusable.
$text = $text.Replace('v0.1.0-alpha.5', 'v0.1.0-alpha.7')

# Alpha.7 playback clock: decoded audio progress is the long-term authority again.
# We interpolate by at most 20 ms between decoder updates for visual smoothness, but
# never allow wall time to accumulate into chart-speed drift.
$timingPattern = '(?ms)^static double correctedSongTimeV5\(const Session& s, const Settings& cfg, double chartOffsetSeconds\) \{.*?^\}\r?\n'
$timingReplacement = @'
struct AudioClockV7 {
    bool initialized = false;
    double lastRaw = 0.0;
    Clock::time_point rawChangedAt{};

    void reset() {
        initialized = false;
        lastRaw = 0.0;
        rawChangedAt = Clock::now();
    }

    double sample(const Session& s) {
        if (s.stems.empty()) return 0.0;
        const double raw = std::max(0.0, static_cast<double>(GetMusicTimePlayed(s.stems.front().music)));
        const auto now = Clock::now();
        if (!initialized || raw + 0.050 < lastRaw || std::abs(raw - lastRaw) > 0.00001) {
            initialized = true;
            lastRaw = raw;
            rawChangedAt = now;
        }
        if (s.paused) return raw;
        const double interpolation = std::clamp(std::chrono::duration<double>(now - rawChangedAt).count(), 0.0, 0.020);
        return raw + interpolation;
    }
};

static AudioClockV7 audioClockV7;
static double activeSongDelayMsV7 = 0.0;
static std::string activeSongDelayRawV7 = "0";
static bool activeSongDelayLegacySecondsV7 = false;

static double readCompatibleSongDelayMsV7(const SongInfo& song) {
    activeSongDelayRawV7 = "0";
    activeSongDelayLegacySecondsV7 = false;
    std::ifstream in(song.directory / "song.ini");
    std::string line;
    while (std::getline(in, line)) {
        const auto p = line.find('=');
        if (p == std::string::npos || lower(trim(line.substr(0, p))) != "delay") continue;
        activeSongDelayRawV7 = unquote(line.substr(p + 1));
        try {
            const double value = std::stod(activeSongDelayRawV7);
            const bool fractional = activeSongDelayRawV7.find('.') != std::string::npos || activeSongDelayRawV7.find('e') != std::string::npos || activeSongDelayRawV7.find('E') != std::string::npos;
            if (fractional && std::abs(value) > 0.000001 && std::abs(value) < 20.0) {
                activeSongDelayLegacySecondsV7 = true;
                return value * 1000.0;
            }
            return value;
        } catch (...) { return static_cast<double>(song.delayMs); }
    }
    return static_cast<double>(song.delayMs);
}

static bool loadSongV7(Session& s, const SongInfo& info) {
    const bool ok = loadSong(s, info);
    if (!ok) return false;
    activeSongDelayMsV7 = readCompatibleSongDelayMsV7(info);
    audioClockV7.reset();
    return true;
}

static void playFromStartV7(Session& s) {
    playFromStart(s);
    audioClockV7.reset();
}

static void togglePauseV7(Session& s) {
    togglePause(s);
    if (!s.paused) audioClockV7.reset();
}

static double correctedSongTimeV5(const Session& s, const Settings& cfg, double chartOffsetSeconds) {
    if (s.stems.empty() || !s.song) return 0.0;
    const double audioSeconds = audioClockV7.sample(s);
#ifdef _WIN32
    static Clock::time_point lastLog{};
    const auto now = Clock::now();
    if (lastLog.time_since_epoch().count() == 0 || now - lastLog >= std::chrono::seconds(5)) {
        const double raw = static_cast<double>(GetMusicTimePlayed(s.stems.front().music));
        std::ostringstream out;
        out << "alpha.7 audio clock: raw_decoder_s=" << raw
            << " interpolated_s=" << audioSeconds
            << " interpolation_ms=" << (audioSeconds - raw) * 1000.0
            << " delay_raw=" << activeSongDelayRawV7
            << " delay_ms=" << activeSongDelayMsV7
            << " delay_mode=" << (activeSongDelayLegacySecondsV7 ? "legacy-seconds" : "milliseconds");
        ggdiag::log(out.str());
        lastLog = now;
    }
#endif
    return audioSeconds + chartOffsetSeconds
        - activeSongDelayMsV7 / 1000.0
        - static_cast<double>(cfg.audioOffsetMs) / 1000.0;
}
'@
$timingUpdated = [regex]::Replace($text, $timingPattern, $timingReplacement, 1)
if ($timingUpdated -eq $text) { throw 'Could not replace correctedSongTimeV5() for alpha.7' }
$text = $timingUpdated

# Use the offset already parsed and verified by the chart layer.
$text = $text.Replace('activeChartOffset = readChartOffsetSecondsV5(session.song->directory / "notes.chart");', 'activeChartOffset = session.chart.offsetSeconds;')

# Route song transport through the alpha.7 clock wrappers. These substitutions happen
# before the wrapper definitions are injected above, so the wrapper bodies retain calls
# to the low-level functions.
$text = $text.Replace('loadSong(session, info)', 'loadSongV7(session, info)')
$text = $text.Replace('loadSong(session, songs[selectedSong])', 'loadSongV7(session, songs[selectedSong])')
$text = $text.Replace('playFromStart(session)', 'playFromStartV7(session)')
$text = $text.Replace('togglePause(session)', 'togglePauseV7(session)')

# Add gameplay state maintenance and SP activation to the playing loop.
$text = $text.Replace('advanceMisses(session, now, window); bool pauseRequested', 'advanceMisses(session, now, window); updateGameplayStateV7(session, now, window); bool pauseRequested')
$text = $text.Replace('if (ev.bit == cfg.start) { pauseRequested = true; continue; } if (ev.bit == cfg.strumUp', 'if (ev.bit == cfg.start) { pauseRequested = true; continue; } if (ev.bit == cfg.starPower) { activateStarPowerV7(session); continue; } if (ev.bit == cfg.strumUp')
$text = $text.Replace('const float step = (IsKeyDown(KEY_LEFT_SHIFT)', 'if (IsKeyPressed(KEY_TAB)) activateStarPowerV7(session); const float step = (IsKeyDown(KEY_LEFT_SHIFT)')

# Richer 3D highway and graphical HUD.
$highwayPattern = '(?ms)^static void drawDisc3DV5\(Vector3 center, float radius, float thickness, int sides, Color color\).*?^static Sound createCalibrationClick\(\) \{'
$highwayReplacement = @'
static void drawDisc3DV5(Vector3 center, float radius, float thickness, int sides, Color color) { DrawCylinder(center, radius, radius, thickness, sides, color); }

static void drawHorizontalMeterV7(Rectangle box, float value, Color fill, const char* label, const char* rightText) {
    value = std::clamp(value, 0.0f, 1.0f);
    DrawRectangleRounded(box, 0.25f, 8, alphaColor(BLACK, 155));
    Rectangle inner{box.x + 3.0f, box.y + 3.0f, (box.width - 6.0f) * value, box.height - 6.0f};
    if (inner.width > 1.0f) DrawRectangleRounded(inner, 0.30f, 8, fill);
    DrawRectangleLinesEx(box, 1.0f, alphaColor(RAYWHITE, 55));
    DrawText(label, static_cast<int>(box.x), static_cast<int>(box.y - 21), 15, LIGHTGRAY);
    if (rightText && *rightText) {
        const int w = MeasureText(rightText, 15);
        DrawText(rightText, static_cast<int>(box.x + box.width - w), static_cast<int>(box.y - 21), 15, RAYWHITE);
    }
}

static void drawVerticalMeterV7(Rectangle box, float value, Color fill, const char* label) {
    value = std::clamp(value, 0.0f, 1.0f);
    DrawRectangleRounded(box, 0.25f, 8, alphaColor(BLACK, 170));
    const float usable = box.height - 6.0f;
    Rectangle inner{box.x + 3.0f, box.y + 3.0f + usable * (1.0f - value), box.width - 6.0f, usable * value};
    if (inner.height > 1.0f) DrawRectangleRounded(inner, 0.25f, 8, fill);
    DrawRectangleLinesEx(box, 1.0f, alphaColor(RAYWHITE, 70));
    const int w = MeasureText(label, 14);
    DrawText(label, static_cast<int>(box.x + (box.width - w) * 0.5f), static_cast<int>(box.y + box.height + 7), 14, LIGHTGRAY);
}

static void drawHighway3DV5(const Session& s, const Settings& cfg, const UiPrefs& ui, double now, uint8_t held,
                            double chartOffsetSeconds) {
    ClearBackground(cfg.background);
    const float roadWidth = ui.roadWidth, laneWidth = roadWidth / 5.0f, hitZ = 0.35f;
    const float farZ = 13.0f + 10.0f * ((cfg.highwayLength - 0.35f) / 0.60f);
    const double visibleSeconds = 2.45 / std::max(0.25f, cfg.highwaySpeed);
    Camera3D camera{};
    camera.position = {0.0f, 6.4f, -6.8f}; camera.target = {0.0f, 0.15f, 6.4f}; camera.up = {0.0f, 1.0f, 0.0f}; camera.fovy = ui.cameraFov; camera.projection = CAMERA_PERSPECTIVE;
    BeginMode3D(camera);
    const float left = -roadWidth * 0.5f, right = roadWidth * 0.5f, nearZ = -0.35f, roadY = 0.0f;
    const Color roadColor = s.starPowerActive ? mixColor(cfg.highway, {35, 95, 160, 255}, 0.34f) : cfg.highway;
    DrawTriangle3D({left, roadY, nearZ}, {right, roadY, farZ}, {right, roadY, nearZ}, roadColor);
    DrawTriangle3D({left, roadY, nearZ}, {left, roadY, farZ}, {right, roadY, farZ}, roadColor);
    for (int i = 0; i <= 5; ++i) {
        const float x = left + laneWidth * static_cast<float>(i);
        const Color line = (i == 0 || i == 5) ? alphaColor(RAYWHITE, 95) : alphaColor(RAYWHITE, 38);
        DrawLine3D({x, roadY + 0.018f, nearZ}, {x, roadY + 0.018f, farZ}, line);
    }
    if (ui.depthGuides) for (int i = 1; i <= 9; ++i) {
        const float t = static_cast<float>(i) / 10.0f;
        const float z = hitZ + t * (farZ - hitZ);
        DrawLine3D({left, roadY + 0.012f, z}, {right, roadY + 0.012f, z}, alphaColor(RAYWHITE, 18));
    }
    auto laneX = [&](int lane) { return right - laneWidth * (static_cast<float>(lane) + 0.5f); };

    for (const auto& n : s.chart.notes) {
        const double dt = n.time - now;
        if (dt > visibleSeconds * 1.06 || dt + n.sustain < -0.45) continue;
        if (n.sustain <= 0.03) continue;
        const Color missColor{255, 55, 70, 165};
        if (n.open) {
            const float z0 = hitZ + static_cast<float>(dt / visibleSeconds) * (farZ - hitZ);
            const float z1 = hitZ + static_cast<float>((dt + n.sustain) / visibleSeconds) * (farZ - hitZ);
            const float startZ = std::max(nearZ, z0), endZ = std::min(farZ, z1);
            if (endZ > startZ) DrawCube({0.0f, 0.052f, (startZ + endZ) * 0.5f}, roadWidth * 0.70f, 0.035f, endZ - startZ, n.missed ? missColor : alphaColor(RAYWHITE, n.hit ? 55 : 145));
            continue;
        }
        for (int lane = 0; lane < 5; ++lane) if (n.mask & (1 << lane)) {
            const double laneSustain = n.laneSustain[lane];
            if (laneSustain <= 0.03) continue;
            const float z0 = hitZ + static_cast<float>(dt / visibleSeconds) * (farZ - hitZ);
            const float z1 = hitZ + static_cast<float>((dt + laneSustain) / visibleSeconds) * (farZ - hitZ);
            const float startZ = std::max(nearZ, z0), endZ = std::min(farZ, z1);
            if (endZ <= startZ) continue;
            Color c = n.missed ? missColor : cfg.lanes[lane];
            c.a = static_cast<unsigned char>(n.missed ? 165 : (n.hit ? 60 : 165));
            DrawCube({laneX(lane), 0.055f, (startZ + endZ) * 0.5f}, laneWidth * 0.16f * ui.noteScale, 0.045f, std::max(0.02f, endZ - startZ), c);
        }
    }

    for (const auto& n : s.chart.notes) {
        const double dt = n.time - now;
        if (dt > visibleSeconds * 1.06 || dt < -0.45) continue;
        const float z = hitZ + static_cast<float>(dt / visibleSeconds) * (farZ - hitZ);
        if (z < nearZ || z > farZ) continue;
        Color missColor{255, 55, 70, 220};
        if (n.open) {
            Color c = n.missed ? missColor : RAYWHITE;
            if (n.hit) c.a = 70;
            DrawCube({0.0f, 0.09f, z}, roadWidth * 0.78f, 0.13f, 0.20f, c);
            continue;
        }
        for (int lane = 0; lane < 5; ++lane) if (n.mask & (1 << lane)) {
            Color c = n.missed ? missColor : cfg.lanes[lane];
            if (n.hit) c.a = 70;
            const float radius = laneWidth * 0.31f * ui.noteScale;
            drawDisc3DV5({laneX(lane), 0.07f, z}, radius, 0.115f, 12, c);
            if (!n.missed && (n.hopo || n.tap)) {
                Color center = n.tap ? RAYWHITE : roadColor;
                center.a = n.hit ? 80 : 230;
                drawDisc3DV5({laneX(lane), 0.185f, z}, radius * 0.43f, 0.025f, 12, center);
            }
        }
    }

    Color strike = cfg.hitLine;
    if (now - s.lastJudgmentAt < 0.16) strike = s.lastJudgmentHit ? Color{90, 255, 150, 255} : Color{255, 70, 80, 255};
    DrawCube({0.0f, 0.075f, hitZ}, roadWidth + 0.22f, 0.065f, 0.10f, strike);
    for (int lane = 0; lane < 5; ++lane) {
        Color receptor = cfg.lanes[lane]; receptor.a = (held & (1 << lane)) ? 255 : 75;
        const float x = laneX(lane);
        drawDisc3DV5({x, 0.10f, hitZ - 0.12f}, laneWidth * 0.29f * ui.noteScale, 0.12f, 14, receptor);
        DrawCylinderWires({x, 0.10f, hitZ - 0.12f}, laneWidth * 0.30f * ui.noteScale, laneWidth * 0.30f * ui.noteScale, 0.125f, 14, alphaColor(RAYWHITE, 155));
    }
    EndMode3D();

    if (s.song) { DrawText(s.song->name.c_str(), 28, 24, 26, RAYWHITE); DrawText(s.song->artist.c_str(), 30, 54, 17, GRAY); }
    DrawText(TextFormat("Score %lld", s.score), 28, 92, 20, LIGHTGRAY);
    DrawText(TextFormat("Combo %d", s.combo), 28, 118, 22, s.combo >= 30 ? RAYWHITE : LIGHTGRAY);
    const int judged = s.hits + s.misses;
    const float accuracy = judged > 0 ? static_cast<float>(s.hits) / static_cast<float>(judged) : 1.0f;
    drawHorizontalMeterV7({28.0f, 170.0f, 230.0f, 18.0f}, accuracy, {70, 195, 255, 230}, "ACCURACY", TextFormat("%.2f%%", accuracy * 100.0f));
    DrawText(TextFormat("%d hit / %d miss", s.hits, s.misses), 28, 199, 15, GRAY);

    const float gaugeX = static_cast<float>(GetScreenWidth()) - 82.0f;
    const float gaugeY = 118.0f;
    Color rockColor = s.rockMeter < 0.30f ? Color{245, 65, 65, 240} : (s.rockMeter < 0.58f ? Color{245, 195, 65, 240} : Color{80, 220, 115, 240});
    drawVerticalMeterV7({gaugeX, gaugeY, 24.0f, 185.0f}, s.rockMeter, rockColor, "ROCK");
    Color spColor = s.starPowerActive ? Color{185, 235, 255, 255} : Color{65, 150, 255, 235};
    drawVerticalMeterV7({gaugeX - 42.0f, gaugeY, 24.0f, 185.0f}, s.starPowerMeter, spColor, "SP");
    if (!s.starPowerActive && s.starPowerMeter >= 0.50f) DrawText("READY", static_cast<int>(gaugeX - 55.0f), static_cast<int>(gaugeY - 25.0f), 14, Color{110, 205, 255, 255});
    if (s.starPowerActive) DrawText("ACTIVE", static_cast<int>(gaugeX - 61.0f), static_cast<int>(gaugeY - 25.0f), 14, RAYWHITE);

    if (now - s.lastJudgmentAt < 0.40) {
        const char* word = "MISS";
        Color judgeColor{255, 75, 85, 255};
        if (s.lastJudgmentHit) {
            const double absolute = std::abs(s.lastJudgmentErrorMs);
            if (absolute <= 25.0) word = "PERFECT";
            else if (absolute <= 55.0) word = "GREAT";
            else word = "GOOD";
            judgeColor = absolute <= 25.0 ? Color{120, 235, 255, 255} : Color{130, 255, 165, 255};
        } else if (s.lastJudgmentOverstrum) word = "OVERSTRUM";
        const int size = s.lastJudgmentHit ? 27 : 25;
        const int w = MeasureText(word, size);
        DrawText(word, (GetScreenWidth() - w) / 2, static_cast<int>(GetScreenHeight() * 0.59f), size, judgeColor);
        if (s.lastJudgmentHit) {
            const char* delta = TextFormat("%+.0f ms", s.lastJudgmentErrorMs);
            const int dw = MeasureText(delta, 15);
            DrawText(delta, (GetScreenWidth() - dw) / 2, static_cast<int>(GetScreenHeight() * 0.59f) + 32, 15, LIGHTGRAY);
        }
    }

    const int warnings = chartWarningCount(s.chart), errors = chartErrorCount(s.chart);
    const char* validation = errors > 0 ? TextFormat("Chart: %d errors", errors) : (warnings > 0 ? TextFormat("Chart: %d warnings", warnings) : "Chart: verified");
    DrawText(validation, GetScreenWidth() - MeasureText(validation, 14) - 22, 27, 14, errors > 0 ? RED : (warnings > 0 ? ORANGE : GREEN));
    DrawText(TextFormat("%s | Res %d | %zu BPM events", s.chart.selectedSection.c_str(), s.chart.resolution, s.chart.tempos.size()), 28, GetScreenHeight() - 26, 14, DARKGRAY);
    DrawText(TextFormat("Chart %+0.0f ms | delay %+0.0f ms", chartOffsetSeconds * 1000.0, activeSongDelayMsV7), GetScreenWidth() - 305, 51, 14, DARKGRAY);
}

static Sound createCalibrationClick() {
'@
$highwayUpdated = [regex]::Replace($text, $highwayPattern, $highwayReplacement, 1)
if ($highwayUpdated -eq $text) { throw 'Could not replace drawHighway3DV5() for alpha.7' }
$text = $highwayUpdated

# Patch the legacy low-level source into the generated directory. main_v3.cpp includes
# "main.cpp" by name, so the generated copy shadows src/main.cpp for this build only.
$legacyInput = Join-Path $sourceDir 'main.cpp'
$legacyText = [System.IO.File]::ReadAllText($legacyInput)

$chartPattern = '(?ms)^struct TempoEvent \{.*?^#ifdef _WIN32\r?\nstruct InputEvent'
$chartReplacement = @'
#include "chart_engine.h"

#ifdef _WIN32
struct InputEvent
'@
$legacyPatched = [regex]::Replace($legacyText, $chartPattern, $chartReplacement, 1)
if ($legacyPatched -eq $legacyText) { throw 'Could not replace legacy chart parser with chart_engine.h' }
$legacyText = $legacyPatched

$sessionPattern = '(?ms)^struct Session \{.*?^static void drawCentered\(const std::string& text, int y, int size, Color color\) \{'
$sessionReplacement = @'
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
    float rockMeter = 0.67f;
    float starPowerMeter = 0.0f;
    bool starPowerActive = false;
    size_t nextStarPhrase = 0;
    std::vector<bool> starPhraseFailed;
    double lastGameplayUpdate = -1.0;
    double lastJudgmentAt = -1000.0;
    double lastJudgmentErrorMs = 0.0;
    bool lastJudgmentHit = false;
    bool lastJudgmentOverstrum = false;
    std::string error;
};

static void resetChartState(Session& s) {
    for (auto& n : s.chart.notes) { n.hit = false; n.missed = false; n.judgedAt = -1000.0; n.hitErrorMs = 0.0; }
    s.nextNote = 0; s.combo = 0; s.maxCombo = 0; s.score = 0; s.hits = 0; s.misses = 0;
    s.rockMeter = 0.67f; s.starPowerMeter = 0.0f; s.starPowerActive = false; s.nextStarPhrase = 0;
    s.starPhraseFailed.assign(s.chart.starPowerPhrases.size(), false);
    s.lastGameplayUpdate = -1.0; s.lastJudgmentAt = -1000.0; s.lastJudgmentErrorMs = 0.0; s.lastJudgmentHit = false; s.lastJudgmentOverstrum = false;
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
    const double audioLength = static_cast<double>(GetMusicTimeLength(stems.front().music));
    if (!verifyChartAgainstAudio(*chart, audioLength)) {
        session.error = "Chart/audio verification failed; see GitarGame.log for details.";
#ifdef _WIN32
        for (const auto& issue : chart->issues) ggdiag::log(std::string("Chart verification: ") + issue.message);
#endif
        unloadStems(stems);
        return false;
    }
#ifdef _WIN32
    {
        std::ostringstream summary;
        summary << "Chart loaded: section=" << chart->selectedSection
            << " resolution=" << chart->resolution
            << " explicit_resolution=" << (chart->resolutionExplicit ? "yes" : "no")
            << " bom=" << (chart->hadUtf8Bom ? "yes" : "no")
            << " tempos=" << chart->tempos.size()
            << " notes=" << chart->notes.size()
            << " star_phrases=" << chart->starPowerPhrases.size()
            << " chart_end_s=" << chartcompat::chartEndTime(*chart)
            << " audio_length_s=" << audioLength
            << " warnings=" << chartWarningCount(*chart)
            << " errors=" << chartErrorCount(*chart);
        ggdiag::log(summary.str());
        for (const auto& issue : chart->issues) {
            const char* severity = issue.severity == ChartIssueSeverity::Error ? "ERROR" : (issue.severity == ChartIssueSeverity::Warning ? "WARN" : "INFO");
            ggdiag::log(std::string("Chart ") + severity + ": " + issue.message);
        }
    }
#endif
    session.song = info;
    session.chart = std::move(*chart);
    session.stems = std::move(stems);
    playFromStart(session);
    return true;
}

static void registerBadStrumV7(Session& s, double now) {
    s.combo = 0;
    s.rockMeter = std::max(0.0f, s.rockMeter - 0.025f);
    s.lastJudgmentAt = now;
    s.lastJudgmentErrorMs = 0.0;
    s.lastJudgmentHit = false;
    s.lastJudgmentOverstrum = true;
}

static void advanceMisses(Session& s, double now, double window) {
    while (s.nextNote < s.chart.notes.size()) {
        auto& n = s.chart.notes[s.nextNote];
        if (n.hit || n.missed) { ++s.nextNote; continue; }
        if (now > n.time + window) {
            n.missed = true;
            n.judgedAt = now;
            n.hitErrorMs = (now - n.time) * 1000.0;
            ++s.misses;
            s.combo = 0;
            s.rockMeter = std::max(0.0f, s.rockMeter - 0.060f);
            if (n.starPhrase >= 0 && n.starPhrase < static_cast<int>(s.starPhraseFailed.size())) s.starPhraseFailed[static_cast<size_t>(n.starPhrase)] = true;
            s.lastJudgmentAt = now;
            s.lastJudgmentErrorMs = n.hitErrorMs;
            s.lastJudgmentHit = false;
            s.lastJudgmentOverstrum = false;
            ++s.nextNote;
        } else break;
    }
}

static void markHit(Session& s, Note& n, double now, double hitErrorMs) {
    n.hit = true;
    n.judgedAt = now;
    n.hitErrorMs = hitErrorMs;
    ++s.hits;
    ++s.combo;
    s.maxCombo = std::max(s.maxCombo, s.combo);
    const int multiplier = std::min(4, 1 + s.combo / 10);
    const int gems = n.open ? 1 : std::max(1, std::popcount(static_cast<unsigned int>(n.mask)));
    const int starMultiplier = s.starPowerActive ? 2 : 1;
    s.score += 50LL * gems * multiplier * starMultiplier;
    s.rockMeter = std::min(1.0f, s.rockMeter + 0.0125f * static_cast<float>(gems));
    s.lastJudgmentAt = now;
    s.lastJudgmentErrorMs = hitErrorMs;
    s.lastJudgmentHit = true;
    s.lastJudgmentOverstrum = false;
    while (s.nextNote < s.chart.notes.size() && (s.chart.notes[s.nextNote].hit || s.chart.notes[s.nextNote].missed)) ++s.nextNote;
}

static bool tryHit(Session& s, double now, double window, uint8_t held, bool strum, uint8_t pressedFret = 0) {
    if (s.nextNote >= s.chart.notes.size()) { if (strum) registerBadStrumV7(s, now); return false; }
    auto& n = s.chart.notes[s.nextNote];
    const double delta = n.time - now;
    if (std::abs(delta) > window) { if (strum && delta > window) registerBadStrumV7(s, now); return false; }
    const bool heldCorrect = n.open ? held == 0 : heldMatches(held, n.mask);
    if (!heldCorrect) { if (strum) registerBadStrumV7(s, now); return false; }
    if (!strum) {
        if (n.open || !(n.hopo || n.tap) || std::popcount(static_cast<unsigned int>(n.mask)) != 1 || (pressedFret & n.mask) == 0) return false;
    }
    markHit(s, n, now, (now - n.time) * 1000.0);
    return true;
}

static void activateStarPowerV7(Session& s) {
    if (!s.starPowerActive && s.starPowerMeter >= 0.50f) s.starPowerActive = true;
}

static void updateGameplayStateV7(Session& s, double now, double window) {
    while (s.nextStarPhrase < s.chart.starPowerPhrases.size()) {
        const auto& phrase = s.chart.starPowerPhrases[s.nextStarPhrase];
        if (now <= phrase.endTime + window) break;
        const bool failed = s.nextStarPhrase < s.starPhraseFailed.size() && s.starPhraseFailed[s.nextStarPhrase];
        if (!failed) s.starPowerMeter = std::min(1.0f, s.starPowerMeter + 0.25f);
        ++s.nextStarPhrase;
    }
    if (s.lastGameplayUpdate < -0.5) { s.lastGameplayUpdate = now; return; }
    const double delta = std::clamp(now - s.lastGameplayUpdate, 0.0, 0.25);
    s.lastGameplayUpdate = now;
    if (s.starPowerActive) {
        const double drain = chartcompat::starPowerDrainPerSecond(s.chart, now) * delta;
        s.starPowerMeter = std::max(0.0f, s.starPowerMeter - static_cast<float>(drain));
        if (s.starPowerMeter <= 0.0001f) s.starPowerActive = false;
    }
}

static void drawCentered(const std::string& text, int y, int size, Color color) {
'@
$legacyUpdated = [regex]::Replace($legacyText, $sessionPattern, $sessionReplacement, 1)
if ($legacyUpdated -eq $legacyText) { throw 'Could not replace legacy Session/gameplay block' }
$legacyText = $legacyUpdated

[System.IO.File]::WriteAllText((Join-Path $generatedDir 'main.cpp'), $legacyText, [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText($OutputPath, $text, [System.Text.UTF8Encoding]::new($false))
Write-Host "Prepared alpha.7 source and chart/gameplay compatibility layer: $OutputPath"
