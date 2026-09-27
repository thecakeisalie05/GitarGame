param(
    [Parameter(Mandatory=$true)][string]$InputPath,
    [Parameter(Mandatory=$true)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$nl = [Environment]::NewLine
$alpha11 = Join-Path $PSScriptRoot 'prepare_alpha11.ps1'
& $alpha11 -InputPath $InputPath -OutputPath $OutputPath
if (-not (Test-Path $OutputPath)) { throw 'alpha.11 source preparation did not produce an output file before alpha.12 patching' }

$generatedDir = Split-Path -Parent $OutputPath
$legacyPath = Join-Path $generatedDir 'main.cpp'
$legacy = [System.IO.File]::ReadAllText($legacyPath)

# Engine timing model: audio/input offset affects judgment; video offset affects rendering only.
$legacy = $legacy.Replace(
    '    float audioOffsetMs = 0.0f;' + $nl + '    float masterVolume = 0.85f;',
    '    float audioOffsetMs = 0.0f;' + $nl + '    float videoOffsetMs = 0.0f;' + $nl + '    float masterVolume = 0.85f;'
)
$legacy = $legacy.Replace(
    '            else if (key == "audio_offset_ms") s.audioOffsetMs = clampFloat(std::stof(value), -500.0f, 500.0f);',
    '            else if (key == "audio_offset_ms") s.audioOffsetMs = clampFloat(std::stof(value), -500.0f, 500.0f);' + $nl +
    '            else if (key == "video_offset_ms") s.videoOffsetMs = clampFloat(std::stof(value), -500.0f, 500.0f);'
)
$legacy = $legacy.Replace(
    '    out << "hit_window_ms = " << s.hitWindowMs << "\naudio_offset_ms = " << s.audioOffsetMs << "\nmaster_volume = " << s.masterVolume << "\n";',
    '    out << "hit_window_ms = " << s.hitWindowMs << "\naudio_offset_ms = " << s.audioOffsetMs << "\nvideo_offset_ms = " << s.videoOffsetMs << "\nmaster_volume = " << s.masterVolume << "\n";'
)
if (-not $legacy.Contains('videoOffsetMs')) { throw 'Could not add video_offset_ms to generated Settings/config layer' }
[System.IO.File]::WriteAllText($legacyPath, $legacy, [System.Text.UTF8Encoding]::new($false))

$text = [System.IO.File]::ReadAllText($OutputPath)
$text = $text.Replace('v0.1.0-alpha.11', 'v0.1.0-alpha.12')
$text = $text.Replace('#include <numeric>', '#include <numeric>' + $nl + '#include "calibration_engine.h"')

$uiPrefsMarker = 'struct UiPrefs {'
$visualClock = @'
static double visualSongTimeV12(const Session& s, const Settings& cfg, double chartOffsetSeconds) {
    return correctedSongTimeV5(s, cfg, chartOffsetSeconds)
        + static_cast<double>(cfg.videoOffsetMs) / 1000.0;
}

'@
if (-not $text.Contains($uiPrefsMarker)) { throw 'Could not locate UiPrefs for visual clock injection' }
$text = $text.Replace($uiPrefsMarker, $visualClock + $uiPrefsMarker)

# Animated menu selection.
$menuPattern = '(?ms)^static void drawMenuList\(const std::vector<std::string>& items, int selected, float x, float y, float width, float rowH\) \{.*?^}\r?\n'
$menuReplacement = @'
static float easeTowardV12(float current, float target, float speed) {
    const float dt = std::clamp(GetFrameTime(), 0.0f, 0.05f);
    return current + (target - current) * (1.0f - std::exp(-speed * dt));
}

static void drawMenuList(const std::vector<std::string>& items, int selected, float x, float y, float width, float rowH) {
    static bool initialized = false;
    static float highlightY = 0.0f;
    static float lastX = 0.0f, lastY = 0.0f, lastW = 0.0f, lastH = 0.0f;
    const bool geometryChanged = !initialized || std::abs(lastX - x) > 1.0f || std::abs(lastY - y) > 1.0f ||
                                 std::abs(lastW - width) > 1.0f || std::abs(lastH - rowH) > 1.0f;
    const float targetY = y + rowH * std::clamp(selected, 0, std::max(0, static_cast<int>(items.size()) - 1));
    if (geometryChanged) {
        highlightY = targetY;
        initialized = true;
        lastX = x; lastY = y; lastW = width; lastH = rowH;
    } else {
        highlightY = easeTowardV12(highlightY, targetY, 17.0f);
    }

    const float pulse = 0.5f + 0.5f * std::sin(static_cast<float>(GetTime()) * 4.0f);
    Rectangle glow{x - 3.0f, highlightY - 3.0f, width + 6.0f, rowH - 2.0f};
    DrawRectangleRounded(glow, 0.14f, 10, alphaColor(RAYWHITE, static_cast<unsigned char>(8 + pulse * 8)));
    Rectangle highlight{x, highlightY, width, rowH - 8.0f};
    DrawRectangleRounded(highlight, 0.12f, 10, alphaColor(RAYWHITE, static_cast<unsigned char>(22 + pulse * 8)));
    DrawRectangleLinesEx(highlight, 1.5f + pulse * 0.6f, alphaColor(RAYWHITE, static_cast<unsigned char>(65 + pulse * 35)));

    for (int i = 0; i < static_cast<int>(items.size()); ++i) {
        const float rowY = y + rowH * i;
        const bool active = i == selected;
        const float slide = active ? 8.0f + pulse * 2.0f : 0.0f;
        DrawText(items[i].c_str(), static_cast<int>(x + 22 + slide), static_cast<int>(rowY + 14), 24,
                 active ? RAYWHITE : LIGHTGRAY);
        if (active) {
            DrawCircle(static_cast<int>(x + 8), static_cast<int>(rowY + (rowH - 8.0f) * 0.5f),
                       2.5f + pulse * 1.5f, alphaColor(RAYWHITE, 180));
        }
    }
}
'@
$updated = [regex]::Replace($text, $menuPattern, $menuReplacement, 1)
if ($updated -eq $text) { throw 'Could not replace drawMenuList for alpha.12 motion' }
$text = $updated

$text = $text.Replace(
    '        const int x = sw - 420 + i * 64;' + $nl +
    '        DrawLineEx({static_cast<float>(x), 80.0f}, {static_cast<float>(x + 80), static_cast<float>(sh - 70)},',
    '        const float drift = std::sin(static_cast<float>(GetTime()) * 0.55f + static_cast<float>(i) * 0.8f) * 16.0f;' + $nl +
    '        const int x = sw - 420 + i * 64 + static_cast<int>(drift);' + $nl +
    '        DrawLineEx({static_cast<float>(x), 80.0f + drift * 0.25f}, {static_cast<float>(x + 80), static_cast<float>(sh - 70) + drift * 0.15f},'
)

$categoriesPattern = '(?ms)^static void drawSettingsCategories\(int selected, const Settings& cfg, bool controllerConnected\) \{.*?^}\r?\n'
$categoriesReplacement = @'
static void drawSettingsCategories(int selected, const Settings& cfg, bool controllerConnected) {
    ClearBackground(cfg.background);
    drawSectionTitle("Settings", "Choose a category");
    const int count = static_cast<int>(SettingsCategory::Count);
    const float x = 58.0f, y = 135.0f, width = static_cast<float>(GetScreenWidth()) - 116.0f, rowH = 76.0f;
    static float highlightY = y;
    highlightY = easeTowardV12(highlightY, y + selected * rowH, 16.0f);
    const float pulse = 0.5f + 0.5f * std::sin(static_cast<float>(GetTime()) * 3.5f);
    DrawRectangleRounded({x - 2.0f, highlightY - 2.0f, width + 4.0f, rowH - 6.0f}, 0.08f, 8,
                         alphaColor(RAYWHITE, static_cast<unsigned char>(15 + pulse * 10)));
    for (int i = 0; i < count; ++i) {
        const auto cat = static_cast<SettingsCategory>(i);
        Rectangle row{x, y + i * rowH, width, rowH - 10.0f};
        drawPanel(row, i == selected ? alphaColor(RAYWHITE, 18) : alphaColor(RAYWHITE, 8), 0.08f);
        const float slide = i == selected ? 7.0f : 0.0f;
        DrawText(categoryName(cat), static_cast<int>(x + 24 + slide), static_cast<int>(row.y + 12), 23, i == selected ? RAYWHITE : LIGHTGRAY);
        DrawText(categoryDescription(cat), static_cast<int>(x + 24 + slide), static_cast<int>(row.y + 40), 16, GRAY);
    }
    drawControllerHint(controllerConnected);
}
'@
$updated = [regex]::Replace($text, $categoriesPattern, $categoriesReplacement, 1)
if ($updated -eq $text) { throw 'Could not animate settings categories' }
$text = $updated

$text = $text.Replace('        case SettingsCategory::Video: return 4;', '        case SettingsCategory::Video: return 6;')
$text = $text.Replace(
    '            rows = {{"Master volume", TextFormat("%.0f%%", cfg.masterVolume * 100.0f)}, {"Timing offset", TextFormat("%+.0f ms", cfg.audioOffsetMs)}, {"Calibration tool", "Open"}};',
    '            rows = {{"Master volume", TextFormat("%.0f%%", cfg.masterVolume * 100.0f)}, {"Audio / input offset", TextFormat("%+.0f ms", cfg.audioOffsetMs)}, {"A/V calibration", "Open"}};'
)
$text = $text.Replace(
    '            rows = {{"FPS cap", fpsLabel(cfg.fpsCap)}, {"VSync", onOff(cfg.vsync) + " (restart)"}, {"Fullscreen", onOff(cfg.fullscreen)}, {"Show FPS", onOff(ui.showFps)}};',
    '            rows = {{"FPS cap", fpsLabel(cfg.fpsCap)}, {"VSync", onOff(cfg.vsync) + " (restart)"}, {"Fullscreen", onOff(cfg.fullscreen)}, {"Show FPS", onOff(ui.showFps)}, {"Video offset", TextFormat("%+.0f ms", cfg.videoOffsetMs)}, {"Auto video calibration", "Open"}};'
)

$settingsDrawPattern = '(?ms)^static void drawSettingsPage\(SettingsCategory category, int selectedRow, const Settings& cfg, const UiPrefs& ui,\r?\n.*?^}\r?\n'
$settingsDrawReplacement = @'
static void drawSettingsPage(SettingsCategory category, int selectedRow, const Settings& cfg, const UiPrefs& ui,
                             const fs::path& songsRoot, size_t songCount, bool inputOverlay, const std::string& status,
                             bool controllerConnected) {
    ClearBackground(cfg.background);
    drawSectionTitle(categoryName(category), categoryDescription(category));
    const auto rows = settingsRows(category, cfg, ui, songsRoot, songCount, inputOverlay);
    const float x = 56.0f, y = 130.0f, width = static_cast<float>(GetScreenWidth()) - 112.0f;
    const float rowH = std::min(60.0f, (GetScreenHeight() - 220.0f) / std::max(1.0f, static_cast<float>(rows.size())));
    static float highlightY = y;
    static SettingsCategory previousCategory = SettingsCategory::Gameplay;
    if (previousCategory != category) {
        highlightY = y + selectedRow * rowH;
        previousCategory = category;
    } else {
        highlightY = easeTowardV12(highlightY, y + selectedRow * rowH, 17.0f);
    }
    const float pulse = 0.5f + 0.5f * std::sin(static_cast<float>(GetTime()) * 4.0f);
    DrawRectangleRounded({x - 2.0f, highlightY - 2.0f, width + 4.0f, rowH - 2.0f}, 0.10f, 8,
                         alphaColor(RAYWHITE, static_cast<unsigned char>(13 + pulse * 9)));

    for (int i = 0; i < static_cast<int>(rows.size()); ++i) {
        Rectangle row{x, y + i * rowH, width, rowH - 6.0f};
        if (i == selectedRow) DrawRectangleRounded(row, 0.10f, 8, alphaColor(RAYWHITE, 18));
        const float slide = i == selectedRow ? 6.0f : 0.0f;
        DrawText(rows[i].first.c_str(), static_cast<int>(x + 18 + slide), static_cast<int>(row.y + 13), 20, i == selectedRow ? RAYWHITE : LIGHTGRAY);
        const int valueW = MeasureText(rows[i].second.c_str(), 19);
        DrawText(rows[i].second.c_str(), static_cast<int>(x + width - 18 - valueW - (i == selectedRow ? 4.0f : 0.0f)),
                 static_cast<int>(row.y + 14), 19, i == selectedRow ? RAYWHITE : GRAY);
    }
    if (!status.empty()) DrawText(status.c_str(), 56, GetScreenHeight() - 82, 16, ORANGE);
    DrawText("Yellow/Blue or Left/Right: adjust   Green/Enter: activate   Red/Esc: back", 56, GetScreenHeight() - 56, 15, GRAY);
    drawControllerHint(controllerConnected);
}
'@
$updated = [regex]::Replace($text, $settingsDrawPattern, $settingsDrawReplacement, 1)
if ($updated -eq $text) { throw 'Could not animate settings page' }
$text = $updated

$calPattern = '(?ms)^struct CalibrationBeat \{.*?^static void drawPauseMenu'
$calReplacement = @'
enum class CalibrationModeV12 { FullAV, AudioOnly, VideoOnly };
enum class CalibrationPhaseV12 { Choose, Audio, Video, Results };

struct CalibrationBeatV12 {
    Clock::time_point time{};
    bool captured = false;
    int direction = 1;
};

struct CalibrationState {
    CalibrationModeV12 mode = CalibrationModeV12::FullAV;
    CalibrationPhaseV12 phase = CalibrationPhaseV12::Choose;
    bool modeLocked = false;
    int modeIndex = 0;
    int emitted = 0;
    int resultRow = 0;
    Clock::time_point nextBeat{};
    std::vector<CalibrationBeatV12> beats;
    std::vector<double> audioSamplesMs;
    std::vector<double> videoSamplesMs;
    ggcal::RobustEstimate audioEstimate;
    ggcal::RobustEstimate videoEstimate;
    double suggestedAudioMs = 0.0;
    double suggestedVideoMs = 0.0;

    void reset() {
        mode = CalibrationModeV12::FullAV;
        phase = CalibrationPhaseV12::Choose;
        modeLocked = false;
        modeIndex = 0;
        emitted = 0;
        resultRow = 0;
        beats.clear();
        audioSamplesMs.clear();
        videoSamplesMs.clear();
        audioEstimate = {};
        videoEstimate = {};
        suggestedAudioMs = 0.0;
        suggestedVideoMs = 0.0;
    }

    void lockTo(CalibrationModeV12 selectedMode) {
        reset();
        mode = selectedMode;
        modeIndex = selectedMode == CalibrationModeV12::FullAV ? 0 :
                    selectedMode == CalibrationModeV12::AudioOnly ? 1 : 2;
        modeLocked = true;
    }

    void syncModeFromIndex() {
        modeIndex = std::clamp(modeIndex, 0, 2);
        mode = modeIndex == 0 ? CalibrationModeV12::FullAV :
               modeIndex == 1 ? CalibrationModeV12::AudioOnly : CalibrationModeV12::VideoOnly;
    }

    bool requiresAudio() const {
        return mode == CalibrationModeV12::FullAV || mode == CalibrationModeV12::AudioOnly;
    }

    bool begin(bool audioReady) {
        if (requiresAudio() && !audioReady) return false;
        emitted = 0;
        resultRow = 0;
        beats.clear();
        audioSamplesMs.clear();
        videoSamplesMs.clear();
        audioEstimate = {};
        videoEstimate = {};
        suggestedAudioMs = 0.0;
        suggestedVideoMs = 0.0;
        if (mode == CalibrationModeV12::VideoOnly) startVideo();
        else startAudio();
        return true;
    }

    void startAudio() {
        phase = CalibrationPhaseV12::Audio;
        beats.clear();
        emitted = 0;
        nextBeat = Clock::now() + std::chrono::milliseconds(900);
    }

    void startVideo() {
        phase = CalibrationPhaseV12::Video;
        beats.clear();
        emitted = 0;
        const auto first = Clock::now() + std::chrono::milliseconds(1100);
        for (int i = 0; i < 12; ++i)
            beats.push_back({first + std::chrono::milliseconds(i * 700), false, (i & 1) ? -1 : 1});
    }

    void finishAudio() {
        audioEstimate = ggcal::robustEstimate(audioSamplesMs);
        if (audioEstimate.valid) suggestedAudioMs = std::clamp(audioEstimate.centerMs, -500.0, 500.0);
        if (mode == CalibrationModeV12::FullAV) startVideo();
        else phase = CalibrationPhaseV12::Results;
    }

    void finishVideo() {
        videoEstimate = ggcal::robustEstimate(videoSamplesMs);
        if (videoEstimate.valid) suggestedVideoMs = std::clamp(videoEstimate.centerMs, -500.0, 500.0);
        phase = CalibrationPhaseV12::Results;
    }

    void update(const Sound& click, bool clickReady) {
        const auto now = Clock::now();
        if (phase == CalibrationPhaseV12::Audio) {
            while (emitted < 12 && now >= nextBeat) {
                const auto dispatched = Clock::now();
                if (clickReady) PlaySound(click);
                beats.push_back({dispatched, false, 1});
                ++emitted;
                nextBeat += std::chrono::milliseconds(500);
            }
            if (emitted >= 12 && now > nextBeat + std::chrono::milliseconds(350)) finishAudio();
        } else if (phase == CalibrationPhaseV12::Video) {
            emitted = 0;
            for (const auto& beat : beats) if (now >= beat.time) ++emitted;
            if (!beats.empty() && now > beats.back().time + std::chrono::milliseconds(500)) finishVideo();
        }
    }

    void capture(Clock::time_point when) {
        if (phase != CalibrationPhaseV12::Audio && phase != CalibrationPhaseV12::Video) return;
        int best = -1;
        double bestAbs = 1e9;
        for (int i = 0; i < static_cast<int>(beats.size()); ++i) {
            if (beats[i].captured) continue;
            const double delta = std::chrono::duration<double, std::milli>(when - beats[i].time).count();
            const double absDelta = std::abs(delta);
            if (absDelta < bestAbs && absDelta <= 340.0) { best = i; bestAbs = absDelta; }
        }
        if (best < 0) return;
        beats[best].captured = true;
        const double sample = std::chrono::duration<double, std::milli>(when - beats[best].time).count();
        if (phase == CalibrationPhaseV12::Audio) audioSamplesMs.push_back(sample);
        else videoSamplesMs.push_back(sample);
    }

    bool resultValid() const {
        if (mode == CalibrationModeV12::FullAV) return audioEstimate.valid && videoEstimate.valid;
        if (mode == CalibrationModeV12::AudioOnly) return audioEstimate.valid;
        return videoEstimate.valid;
    }
};

static const char* calibrationModeNameV12(CalibrationModeV12 mode) {
    switch (mode) {
        case CalibrationModeV12::FullAV: return "Full A/V auto calibration";
        case CalibrationModeV12::AudioOnly: return "Audio / input only";
        case CalibrationModeV12::VideoOnly: return "Video only";
        default: return "Calibration";
    }
}

static void drawCalibration(const CalibrationState& cal, const Settings& cfg, bool controllerConnected, bool audioReady) {
    ClearBackground(cfg.background);
    const int sw = GetScreenWidth(), sh = GetScreenHeight();
    const float pulse = 0.5f + 0.5f * std::sin(static_cast<float>(GetTime()) * 4.2f);

    if (cal.phase == CalibrationPhaseV12::Choose) {
        drawSectionTitle("Calibration", "Measure end-to-end audio/input and display latency");
        Rectangle card{70, 132, static_cast<float>(sw - 140), static_cast<float>(sh - 235)};
        drawPanel(card, alphaColor(RAYWHITE, 8));
        if (!cal.modeLocked) {
            const std::vector<std::string> items = {
                "Full A/V auto calibration   · recommended",
                "Audio / input only",
                "Video only"
            };
            drawMenuList(items, cal.modeIndex, 105.0f, 190.0f, std::min(760.0f, card.width - 70.0f), 64.0f);
        } else {
            DrawText(calibrationModeNameV12(cal.mode), 110, 190, 30, RAYWHITE);
        }
        DrawText(TextFormat("Current audio/input offset  %+.0f ms", cfg.audioOffsetMs), 110, 410, 19, LIGHTGRAY);
        DrawText(TextFormat("Current video offset        %+.0f ms", cfg.videoOffsetMs), 110, 442, 19, LIGHTGRAY);
        DrawText("Full A/V runs an audible-click pass followed by a visual crossing pass.", 110, 495, 17, GRAY);
        DrawText("Repeated samples are filtered for outliers; video compensation never changes hit judgment.", 110, 523, 17, GRAY);
        if (!audioReady && cal.requiresAudio()) DrawText("Audio device unavailable — choose Video only.", 110, 558, 17, ORANGE);
        DrawText("Green / Enter: begin   Red / Esc: back", 72, sh - 80, 16, GRAY);
        drawControllerHint(controllerConnected);
        return;
    }

    if (cal.phase == CalibrationPhaseV12::Audio) {
        drawSectionTitle("Calibration · Audio", "Strum exactly when each click is heard");
        Rectangle card{70, 145, static_cast<float>(sw - 140), static_cast<float>(sh - 260)};
        drawPanel(card, alphaColor(RAYWHITE, 8));
        DrawText(TextFormat("Click %d / 12", cal.emitted), 110, 190, 27, RAYWHITE);
        DrawText(TextFormat("Captured %d", static_cast<int>(cal.audioSamplesMs.size())), 110, 228, 19, LIGHTGRAY);
        const float startX = 120.0f, gap = (card.width - 120.0f) / 12.0f;
        for (int i = 0; i < 12; ++i) {
            const float x = startX + i * gap;
            Color c = i < static_cast<int>(cal.beats.size()) ? (cal.beats[i].captured ? GREEN : LIGHTGRAY) : DARKGRAY;
            DrawCircle(static_cast<int>(x), 305, i == cal.emitted - 1 ? 12.0f + pulse * 3.0f : 10.0f, c);
        }
        drawCentered("Listen, then strum. Do not follow the circles visually.", 370, 18, GRAY);
        DrawText("Red / Esc: cancel", 72, sh - 80, 16, GRAY);
        drawControllerHint(controllerConnected);
        return;
    }

    if (cal.phase == CalibrationPhaseV12::Video) {
        drawSectionTitle("Calibration · Video", "Strum when the moving marker crosses the center target");
        Rectangle card{70, 145, static_cast<float>(sw - 140), static_cast<float>(sh - 260)};
        drawPanel(card, alphaColor(RAYWHITE, 8));
        const float left = card.x + 80.0f, right = card.x + card.width - 80.0f;
        const float center = (left + right) * 0.5f, y = card.y + card.height * 0.48f;
        DrawLineEx({left, y}, {right, y}, 3.0f, alphaColor(RAYWHITE, 45));
        DrawLineEx({center, y - 75.0f}, {center, y + 75.0f}, 4.0f, alphaColor(RAYWHITE, static_cast<unsigned char>(145 + pulse * 90)));
        DrawCircle(static_cast<int>(center), static_cast<int>(y), 18.0f + pulse * 4.0f, alphaColor(RAYWHITE, 45));
        DrawCircleLines(static_cast<int>(center), static_cast<int>(y), 24.0f, RAYWHITE);

        const auto now = Clock::now();
        const CalibrationBeatV12* active = nullptr;
        double bestDistance = 1e9;
        for (const auto& beat : cal.beats) {
            const double d = std::abs(std::chrono::duration<double, std::milli>(now - beat.time).count());
            if (d < bestDistance && d <= 430.0) { bestDistance = d; active = &beat; }
        }
        if (active) {
            const double dtMs = std::chrono::duration<double, std::milli>(now - active->time).count();
            const float u = std::clamp(static_cast<float>((dtMs + 350.0) / 700.0), 0.0f, 1.0f);
            const float from = active->direction > 0 ? left : right;
            const float to = active->direction > 0 ? right : left;
            const float markerX = from + (to - from) * u;
            DrawCircle(static_cast<int>(markerX), static_cast<int>(y), 17.0f, cfg.lanes[3]);
            DrawCircleLines(static_cast<int>(markerX), static_cast<int>(y), 20.0f, RAYWHITE);
        }

        DrawText(TextFormat("Crossing %d / 12", std::min(12, cal.emitted + 1)), 110, 190, 27, RAYWHITE);
        DrawText(TextFormat("Captured %d", static_cast<int>(cal.videoSamplesMs.size())), 110, 228, 19, LIGHTGRAY);
        drawCentered("The direction alternates to reduce anticipation bias.", static_cast<int>(card.y + card.height - 78), 17, GRAY);
        DrawText("Red / Esc: cancel", 72, sh - 80, 16, GRAY);
        drawControllerHint(controllerConnected);
        return;
    }

    drawSectionTitle("Calibration · Results", "Robust median estimates after outlier rejection");
    Rectangle card{70, 135, static_cast<float>(sw - 140), static_cast<float>(sh - 245)};
    drawPanel(card, alphaColor(RAYWHITE, 8));
    int row = 0;
    auto drawResult = [&](const char* label, double value, const ggcal::RobustEstimate& estimate, bool selected) {
        Rectangle r{110.0f, 190.0f + row * 110.0f, std::min(760.0f, card.width - 80.0f), 86.0f};
        DrawRectangleRounded(r, 0.10f, 8, selected ? alphaColor(RAYWHITE, 22) : alphaColor(RAYWHITE, 8));
        if (selected) DrawRectangleLinesEx(r, 2.0f, alphaColor(RAYWHITE, static_cast<unsigned char>(80 + pulse * 80)));
        DrawText(label, static_cast<int>(r.x + 18), static_cast<int>(r.y + 13), 20, LIGHTGRAY);
        DrawText(TextFormat("%+.0f ms", value), static_cast<int>(r.x + 18), static_cast<int>(r.y + 40), 27, RAYWHITE);
        DrawText(TextFormat("%s · %d/%d samples · spread %.1f ms", ggcal::qualityLabel(estimate), estimate.used, estimate.total, estimate.spreadMs),
                 static_cast<int>(r.x + 185), static_cast<int>(r.y + 45), 16, GRAY);
        ++row;
    };
    if (cal.mode != CalibrationModeV12::VideoOnly)
        drawResult("Audio / input offset", cal.suggestedAudioMs, cal.audioEstimate, cal.resultRow == 0);
    if (cal.mode != CalibrationModeV12::AudioOnly) {
        const int videoRow = cal.mode == CalibrationModeV12::FullAV ? 1 : 0;
        drawResult("Video offset", cal.suggestedVideoMs, cal.videoEstimate, cal.resultRow == videoRow);
    }
    if (cal.mode == CalibrationModeV12::FullAV && cal.audioEstimate.valid && cal.videoEstimate.valid) {
        DrawText(TextFormat("Display path relative to audio path: %+.1f ms", cal.videoEstimate.centerMs - cal.audioEstimate.centerMs),
                 110, 430, 18, LIGHTGRAY);
    }
    if (!cal.resultValid()) DrawText("Not enough clean samples — retry for a reliable result.", 110, 475, 18, ORANGE);
    DrawText("Strum Up/Down: choose result   Yellow/Blue: ±5 ms   Green: apply   Orange/R: retry",
             110, sh - 122, 16, LIGHTGRAY);
    DrawText("Red / Esc: back", 72, sh - 80, 16, GRAY);
    drawControllerHint(controllerConnected);
}

static void drawPauseMenu
'@
$updated = [regex]::Replace($text, $calPattern, $calReplacement, 1)
if ($updated -eq $text) { throw 'Could not replace calibration state/UI for alpha.12' }
$text = $updated

$text = $text.Replace(
    'case SettingsCategory::Video: if (settingRow == 0) { cfg.fpsCap = cycleChoice(cfg.fpsCap, {60, 120, 144, 165, 240, 360, 500, 1000, 0}, dir); if (cfg.fpsCap > 0) SetTargetFPS(cfg.fpsCap); else SetTargetFPS(0); saveCore = true; } break;',
    'case SettingsCategory::Video: if (settingRow == 0) { cfg.fpsCap = cycleChoice(cfg.fpsCap, {60, 120, 144, 165, 240, 360, 500, 1000, 0}, dir); if (cfg.fpsCap > 0) SetTargetFPS(cfg.fpsCap); else SetTargetFPS(0); saveCore = true; } else if (settingRow == 4) { cfg.videoOffsetMs = clampFloat(cfg.videoOffsetMs + dir * 5.0f, -500.0f, 500.0f); saveCore = true; } break;'
)
$text = $text.Replace(
    'case SettingsCategory::Video: if (settingRow == 1) { cfg.vsync = !cfg.vsync; status = "VSync change will apply next launch."; saveCore = true; } else if (settingRow == 2) { cfg.fullscreen = !cfg.fullscreen; ToggleFullscreen(); saveCore = true; } else if (settingRow == 3) { ui.showFps = !ui.showFps; savePresentation = true; } break;',
    'case SettingsCategory::Video: if (settingRow == 1) { cfg.vsync = !cfg.vsync; status = "VSync change will apply next launch."; saveCore = true; } else if (settingRow == 2) { cfg.fullscreen = !cfg.fullscreen; ToggleFullscreen(); saveCore = true; } else if (settingRow == 3) { ui.showFps = !ui.showFps; savePresentation = true; } else if (settingRow == 5) { calibrationReturn = AppScreen::SettingsPage; calibration.lockTo(CalibrationModeV12::VideoOnly); screen = AppScreen::Calibration; } break;'
)

$calCasePattern = '(?ms)^\s*case AppScreen::Calibration:\r?\n.*?^\s*break;\r?\n\s*case AppScreen::Playing:'
$calCaseReplacement = @'
                case AppScreen::Calibration: {
                    calibration.update(calibrationClick, calibrationClickReady);
#ifdef _WIN32
                    bool orange = false;
                    for (const auto& ev : events) {
                        if (!ev.down) continue;
                        if (ev.bit == cfg.orange) orange = true;
                        if ((calibration.phase == CalibrationPhaseV12::Audio || calibration.phase == CalibrationPhaseV12::Video) &&
                            (ev.bit == cfg.strumUp || ev.bit == cfg.strumDown)) calibration.capture(ev.when);
                    }
#else
                    bool orange = false;
#endif
                    if ((calibration.phase == CalibrationPhaseV12::Audio || calibration.phase == CalibrationPhaseV12::Video) &&
                        IsKeyPressed(KEY_SPACE)) calibration.capture(Clock::now());

                    if (calibration.phase == CalibrationPhaseV12::Choose) {
                        if (!calibration.modeLocked) {
                            if (nav.up) calibration.modeIndex = wrapIndex(calibration.modeIndex - 1, 3);
                            if (nav.down) calibration.modeIndex = wrapIndex(calibration.modeIndex + 1, 3);
                            calibration.syncModeFromIndex();
                        }
                        if (nav.accept || nav.start) {
                            if (!calibration.begin(IsAudioDeviceReady()))
                                status = "Audio device unavailable; Video-only calibration is still available.";
                        }
                        if (nav.back) { calibration.reset(); screen = calibrationReturn; }
                    } else if (calibration.phase == CalibrationPhaseV12::Audio || calibration.phase == CalibrationPhaseV12::Video) {
                        if (nav.back) { calibration.reset(); screen = calibrationReturn; }
                    } else {
                        const int resultRows = calibration.mode == CalibrationModeV12::FullAV ? 2 : 1;
                        if (nav.up) calibration.resultRow = wrapIndex(calibration.resultRow - 1, resultRows);
                        if (nav.down) calibration.resultRow = wrapIndex(calibration.resultRow + 1, resultRows);
                        const int adjust = nav.left ? -1 : (nav.right ? 1 : 0);
                        if (adjust != 0) {
                            const bool audioRow = calibration.mode == CalibrationModeV12::AudioOnly ||
                                                  (calibration.mode == CalibrationModeV12::FullAV && calibration.resultRow == 0);
                            if (audioRow) calibration.suggestedAudioMs = std::clamp(calibration.suggestedAudioMs + adjust * 5.0, -500.0, 500.0);
                            else calibration.suggestedVideoMs = std::clamp(calibration.suggestedVideoMs + adjust * 5.0, -500.0, 500.0);
                        }
                        if ((nav.accept || nav.start) && calibration.resultValid()) {
                            if (calibration.mode != CalibrationModeV12::VideoOnly)
                                cfg.audioOffsetMs = static_cast<float>(calibration.suggestedAudioMs);
                            if (calibration.mode != CalibrationModeV12::AudioOnly)
                                cfg.videoOffsetMs = static_cast<float>(calibration.suggestedVideoMs);
                            saveConfig(configPath, cfg);
#ifdef _WIN32
                            ggdiag::log("Calibration applied: audio/input_ms=" + std::to_string(cfg.audioOffsetMs) +
                                        " video_ms=" + std::to_string(cfg.videoOffsetMs));
#endif
                            status = TextFormat("Calibration saved: audio %+.0f ms · video %+.0f ms", cfg.audioOffsetMs, cfg.videoOffsetMs);
                            screen = calibrationReturn;
                        }
                        if (orange || IsKeyPressed(KEY_R)) {
                            const auto retryMode = calibration.mode;
                            const bool retryLocked = calibration.modeLocked;
                            calibration.reset();
                            calibration.mode = retryMode;
                            calibration.modeIndex = retryMode == CalibrationModeV12::FullAV ? 0 :
                                                    retryMode == CalibrationModeV12::AudioOnly ? 1 : 2;
                            calibration.modeLocked = retryLocked;
                            calibration.begin(IsAudioDeviceReady());
                        }
                        if (nav.back) { calibration.reset(); screen = calibrationReturn; }
                    }
                    break;
                }
                case AppScreen::Playing:
'@
$updated = [regex]::Replace($text, $calCasePattern, $calCaseReplacement, 1)
if ($updated -eq $text) { throw 'Could not replace calibration event loop for alpha.12' }
$text = $updated

$text = $text.Replace(
    'drawHighway3DV5(session, cfg, ui, correctedSongTimeV5(session, cfg, activeChartOffset), held, activeChartOffset);',
    'drawHighway3DV5(session, cfg, ui, visualSongTimeV12(session, cfg, activeChartOffset), held, activeChartOffset);'
)
if (-not $text.Contains('visualSongTimeV12(session')) { throw 'Could not route highway rendering through video-offset clock' }

[System.IO.File]::WriteAllText($OutputPath, $text, [System.Text.UTF8Encoding]::new($false))
Write-Host "Prepared alpha.12 robust A/V calibration and menu motion: $OutputPath"
