param(
    [Parameter(Mandatory=$true)][string]$InputPath,
    [Parameter(Mandatory=$true)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$alpha16 = Join-Path $PSScriptRoot 'prepare_alpha16.ps1'
& $alpha16 -InputPath $InputPath -OutputPath $OutputPath
if (-not (Test-Path $OutputPath)) { throw 'alpha.16 source preparation did not produce an output file before alpha.17 patching' }

$generatedDir = Split-Path -Parent $OutputPath
$legacyPath = Join-Path $generatedDir 'main.cpp'
$legacy = [System.IO.File]::ReadAllText($legacyPath)

# ---------------------------------------------------------------------------
# Feel tuning: alpha.16's low-latency path stays intact, but the baseline strum
# window is relaxed and normal CH-style HOPO/tap frontend buffering is added.
# ---------------------------------------------------------------------------
$legacy = $legacy.Replace('    float hitWindowMs = 70.0f;', '    float hitWindowMs = 90.0f;')

$sessionNeedle = '    bool lastHitTap = false;' + [Environment]::NewLine + '    Clock::time_point lastHitWall{};'
$sessionReplacement = '    bool lastHitTap = false;' + [Environment]::NewLine +
                      '    size_t frontendArmedNote = static_cast<size_t>(-1);' + [Environment]::NewLine +
                      '    Clock::time_point lastHitWall{};'
if (-not $legacy.Contains($sessionNeedle)) { throw 'Could not locate Session hit-feedback fields for frontend state' }
$legacy = $legacy.Replace($sessionNeedle, $sessionReplacement)

$resetNeedle = 's.lastHitHopo = false; s.lastHitTap = false; s.lastHitWall = Clock::time_point{};'
$resetReplacement = 's.lastHitHopo = false; s.lastHitTap = false; s.frontendArmedNote = static_cast<size_t>(-1); s.lastHitWall = Clock::time_point{};'
if (-not $legacy.Contains($resetNeedle)) { throw 'Could not locate chart-state reset for frontend state' }
$legacy = $legacy.Replace($resetNeedle, $resetReplacement)

# Any committed hit or overstrum consumes/invalidates the current frontend arm.
$markAdvanceNeedle = '    while (s.nextNote < s.chart.notes.size() && (s.chart.notes[s.nextNote].hit || s.chart.notes[s.nextNote].missed)) ++s.nextNote;'
$markAdvanceReplacement = '    s.frontendArmedNote = static_cast<size_t>(-1);' + [Environment]::NewLine + $markAdvanceNeedle
if (-not $legacy.Contains($markAdvanceNeedle)) { throw 'Could not locate markHit next-note advancement' }
$legacy = $legacy.Replace($markAdvanceNeedle, $markAdvanceReplacement)

$badStrumNeedle = '    s.lastJudgmentOverstrum = true;'
if (-not $legacy.Contains($badStrumNeedle)) { throw 'Could not locate bad-strum state for frontend invalidation' }
$legacy = $legacy.Replace(
    $badStrumNeedle,
    $badStrumNeedle + [Environment]::NewLine + '    s.frontendArmedNote = static_cast<size_t>(-1);'
)

$fretPattern = '(?ms)^static bool tryFretTransitionV16\(Session& s, double now, double window,.*?^}\r?\n'
$fretReplacement = @'
static bool tryFretTransitionV17(Session& s, double now, double window,
                                 uint8_t resultingHeld, uint8_t pressedMask,
                                 uint8_t releasedMask) {
    if (s.nextNote >= s.chart.notes.size()) return false;
    auto& n = s.chart.notes[s.nextNote];

    // If an early-fretted note was armed but the player changed away from the
    // required state before it reached the window, disarm it immediately.
    if (s.frontendArmedNote == s.nextNote &&
        !ggengine::frontendHeldStillValid(n.hopo, n.tap, n.open, s.combo,
                                          resultingHeld, n.mask)) {
        s.frontendArmedNote = static_cast<size_t>(-1);
    }

    // Normal Clone Hero feel allows a HOPO/tap to be fretted before the front
    // edge of the window and then awarded when the window reaches it, provided
    // the correct fret state is still held. Precision-style behavior would
    // require the transition itself to occur inside the window.
    if (now < n.time - window) {
        if (ggengine::canFretTransitionHit(n.hopo, n.tap, n.open, s.combo,
                                           resultingHeld, n.mask,
                                           pressedMask, releasedMask)) {
            s.frontendArmedNote = s.nextNote;
        }
        return false;
    }

    if (!ggengine::withinHitWindow(n.time, now, window)) return false;
    if (!ggengine::canFretTransitionHit(n.hopo, n.tap, n.open, s.combo,
                                        resultingHeld, n.mask,
                                        pressedMask, releasedMask)) {
        return false;
    }

    markHit(s, n, now, (now - n.time) * 1000.0);
    return true;
}

static bool tryConsumeFrontendV17(Session& s, double now, double window,
                                  uint8_t held) {
    if (s.frontendArmedNote != s.nextNote || s.nextNote >= s.chart.notes.size())
        return false;

    auto& n = s.chart.notes[s.nextNote];
    if (now < n.time - window) return false;
    if (now > n.time + window) {
        s.frontendArmedNote = static_cast<size_t>(-1);
        return false;
    }

    if (!ggengine::frontendHeldStillValid(n.hopo, n.tap, n.open, s.combo,
                                          held, n.mask)) {
        s.frontendArmedNote = static_cast<size_t>(-1);
        return false;
    }

    markHit(s, n, now, (now - n.time) * 1000.0);
    return true;
}
'@
$updatedLegacy = [regex]::Replace($legacy, $fretPattern, $fretReplacement, 1)
if ($updatedLegacy -eq $legacy) { throw 'Could not replace alpha.16 fret transition logic for alpha.17' }
$legacy = $updatedLegacy

[System.IO.File]::WriteAllText($legacyPath, $legacy, [System.Text.UTF8Encoding]::new($false))

# ---------------------------------------------------------------------------
# Persistent calibration profile. Core config continues to contain the offsets,
# but Windows also mirrors them under LocalAppData so calibration survives
# executable replacement/moves and cannot be lost when using a fresh release ZIP.
# ---------------------------------------------------------------------------
$text = [System.IO.File]::ReadAllText($OutputPath)
$text = $text.Replace('v0.1.0-alpha.16', 'v0.1.0-alpha.17')
$text = $text.Replace('#include "calibration_engine.h"',
                      '#include "calibration_engine.h"' + [Environment]::NewLine + '#include "calibration_profile.h"' +
                      [Environment]::NewLine + '#include <iterator>')

$mainMarker = 'int main(int argc, char** argv) {'
$profileHelpers = @'
static fs::path calibrationProfilePathV17(const fs::path& exeDir) {
#ifdef _WIN32
    std::array<wchar_t, 32768> buffer{};
    const DWORD count = GetEnvironmentVariableW(L"LOCALAPPDATA", buffer.data(),
                                                 static_cast<DWORD>(buffer.size()));
    if (count > 0 && count < buffer.size())
        return fs::path(buffer.data()) / L"GitarGame" / L"calibration.ini";
#endif
    return exeDir / "calibration.ini";
}

static bool loadCalibrationProfileV17(const fs::path& path, Settings& cfg) {
    std::ifstream in(path, std::ios::binary);
    if (!in) return false;
    const std::string text((std::istreambuf_iterator<char>(in)),
                           std::istreambuf_iterator<char>());
    const auto values = ggcalprofile::parse(text);
    if (!values) return false;
    cfg.audioOffsetMs = static_cast<float>(values->audioOffsetMs);
    cfg.videoOffsetMs = static_cast<float>(values->videoOffsetMs);
    return true;
}

static bool saveCalibrationProfileV17(const fs::path& path, const Settings& cfg) {
    std::error_code ec;
    if (!path.parent_path().empty()) fs::create_directories(path.parent_path(), ec);
    if (ec) return false;

    fs::path temp = path;
    temp += ".tmp";
    {
        std::ofstream out(temp, std::ios::binary | std::ios::trunc);
        if (!out) return false;
        ggcalprofile::Values values;
        values.audioOffsetMs = cfg.audioOffsetMs;
        values.videoOffsetMs = cfg.videoOffsetMs;
        out << ggcalprofile::serialize(values);
        out.flush();
        if (!out) return false;
    }

    fs::remove(path, ec);
    ec.clear();
    fs::rename(temp, path, ec);
    if (ec) {
        fs::remove(temp, ec);
        return false;
    }
    return true;
}

'@
if (-not $text.Contains($mainMarker)) { throw 'Could not locate main() for calibration persistence helpers' }
$text = $text.Replace($mainMarker, $profileHelpers + $mainMarker)

# Replace alpha.16 startup migration with alpha.17 migration and persistent
# calibration-profile load/seed.
$configPattern = '(?ms)    Settings cfg;\r?\n    const bool loadedCoreConfigV16 = loadConfig\(configPath, cfg\);.*?    UiPrefs ui; if \(!loadUiPrefs\(uiPath, ui\)\) saveUiPrefs\(uiPath, ui\);'
$configReplacement = @'
    Settings cfg;
    const bool loadedCoreConfigV17 = loadConfig(configPath, cfg);
    if (!loadedCoreConfigV17) {
        cfg.hitWindowMs = 90.0f;
        cfg.engineRulesVersion = 17;
        saveConfig(configPath, cfg);
    } else if (cfg.engineRulesVersion < 17) {
        // Alpha.16 introduced a +/-70ms baseline. User playtesting found it
        // perceptibly stricter than their Clone Hero setup, so only migrate
        // that untouched alpha.16 default; preserve any custom value.
        if (std::abs(cfg.hitWindowMs - 70.0f) < 0.01f) cfg.hitWindowMs = 90.0f;
        cfg.engineRulesVersion = 17;
        saveConfig(configPath, cfg);
#ifdef _WIN32
        ggdiag::log("alpha.17 gameplay rules migrated: half_window_ms=" + std::to_string(cfg.hitWindowMs));
#endif
    }

    const fs::path calibrationProfilePathV17Value = calibrationProfilePathV17(exeDir);
    if (loadCalibrationProfileV17(calibrationProfilePathV17Value, cfg)) {
#ifdef _WIN32
        ggdiag::log("Persistent calibration loaded: audio/input_ms=" + std::to_string(cfg.audioOffsetMs) +
                    " video_ms=" + std::to_string(cfg.videoOffsetMs));
#endif
    } else {
        // Seed from config.ini so existing users keep their current calibration
        // when upgrading to the persistent profile.
        saveCalibrationProfileV17(calibrationProfilePathV17Value, cfg);
    }

    auto persistCalibrationV17 = [&]() {
        saveConfig(configPath, cfg);
        const bool ok = saveCalibrationProfileV17(calibrationProfilePathV17Value, cfg);
#ifdef _WIN32
        ggdiag::log(std::string("Persistent calibration save ") + (ok ? "succeeded" : "FAILED") +
                    ": audio/input_ms=" + std::to_string(cfg.audioOffsetMs) +
                    " video_ms=" + std::to_string(cfg.videoOffsetMs));
#endif
        return ok;
    };

    UiPrefs ui; if (!loadUiPrefs(uiPath, ui)) saveUiPrefs(uiPath, ui);
'@
$updated = [regex]::Replace($text, $configPattern, $configReplacement, 1)
if ($updated -eq $text) { throw 'Could not replace alpha.16 startup config migration for alpha.17' }
$text = $updated

# The calibration result screen must update both config.ini and the stable
# per-user profile.
$calApplyNeedle = @'
                            saveConfig(configPath, cfg);
#ifdef _WIN32
                            ggdiag::log("Calibration applied: audio/input_ms=" + std::to_string(cfg.audioOffsetMs) +
'@
$calApplyReplacement = @'
                            persistCalibrationV17();
#ifdef _WIN32
                            ggdiag::log("Calibration applied: audio/input_ms=" + std::to_string(cfg.audioOffsetMs) +
'@
if (-not $text.Contains($calApplyNeedle)) { throw 'Could not locate calibration result save for persistent profile' }
$text = $text.Replace($calApplyNeedle, $calApplyReplacement)

# Manual offset edits in Settings also write the stable profile.
$settingsSaveOld = '                    if (saveCore) saveConfig(configPath, cfg); if (savePresentation) saveUiPrefs(uiPath, ui); if (nav.back) screen = AppScreen::SettingsCategories; break;'
$settingsSaveNew = @'
                    if (saveCore) {
                        saveConfig(configPath, cfg);
                        const bool calibrationChanged =
                            (activeCategory == SettingsCategory::Audio && settingRow == 1) ||
                            (activeCategory == SettingsCategory::Video && settingRow == 4);
                        if (calibrationChanged)
                            saveCalibrationProfileV17(calibrationProfilePathV17Value, cfg);
                    }
                    if (savePresentation) saveUiPrefs(uiPath, ui);
                    if (nav.back) screen = AppScreen::SettingsCategories;
                    break;
'@
if (-not $text.Contains($settingsSaveOld)) { throw 'Could not locate settings save block for calibration persistence' }
$text = $text.Replace($settingsSaveOld, $settingsSaveNew.TrimEnd())

# Gameplay F7/F8/F9 manual calibration controls persist too.
$text = $text.Replace(
    'cfg.audioOffsetMs = clampFloat(cfg.audioOffsetMs - step, -500.0f, 500.0f); saveConfig(configPath, cfg);',
    'cfg.audioOffsetMs = clampFloat(cfg.audioOffsetMs - step, -500.0f, 500.0f); persistCalibrationV17();'
)
$text = $text.Replace(
    'cfg.audioOffsetMs = clampFloat(cfg.audioOffsetMs + step, -500.0f, 500.0f); saveConfig(configPath, cfg);',
    'cfg.audioOffsetMs = clampFloat(cfg.audioOffsetMs + step, -500.0f, 500.0f); persistCalibrationV17();'
)
$text = $text.Replace(
    'cfg.audioOffsetMs = 0.0f; saveConfig(configPath, cfg);',
    'cfg.audioOffsetMs = 0.0f; persistCalibrationV17();'
)

# ---------------------------------------------------------------------------
# Frontend consumption in the high-resolution input loop.
# ---------------------------------------------------------------------------
$text = $text.Replace(
    'tryFretTransitionV16(session, eventNow, window, heldAtEvent,',
    'tryFretTransitionV17(session, eventNow, window, heldAtEvent,'
)
$text = $text.Replace(
    'tryFretTransitionV16(session, now, window, kbHeld,',
    'tryFretTransitionV17(session, now, window, kbHeld,'
)

$xinputAdvance = @'
                        advanceMisses(session, eventNow, window);
                        const uint8_t heldAtEvent = heldMaskFromXInput(snapshot, cfg);
'@
$xinputAdvanceNew = @'
                        const uint8_t heldAtEvent = heldMaskFromXInput(snapshot, cfg);
                        tryConsumeFrontendV17(session, eventNow, window, heldAtEvent);
                        advanceMisses(session, eventNow, window);
'@
if (-not $text.Contains($xinputAdvance)) { throw 'Could not locate timestamped XInput miss advancement for frontend consumption' }
$text = $text.Replace($xinputAdvance, $xinputAdvanceNew)

$keyboardAdvance = @'
                    advanceMisses(session, now, window);
                    const bool kbStrumV16 = IsKeyPressed(KEY_UP) || IsKeyPressed(KEY_DOWN);
'@
$keyboardAdvanceNew = @'
#ifdef _WIN32
                    tryConsumeFrontendV17(session, now, window,
                                         heldMaskFromXInput(poller.buttons(), cfg));
#endif
                    tryConsumeFrontendV17(session, now, window, kbHeld);
                    advanceMisses(session, now, window);
                    const bool kbStrumV16 = IsKeyPressed(KEY_UP) || IsKeyPressed(KEY_DOWN);
'@
if (-not $text.Contains($keyboardAdvance)) { throw 'Could not locate frame-level miss advancement for frontend consumption' }
$text = $text.Replace($keyboardAdvance, $keyboardAdvanceNew)

if ($text.Contains('tryFretTransitionV16(')) { throw 'alpha.17 hardening failed: old fret-transition call remains' }

[System.IO.File]::WriteAllText($OutputPath, $text, [System.Text.UTF8Encoding]::new($false))
Write-Host "Prepared alpha.17 relaxed CH-like feel, frontend buffering and persistent calibration: $OutputPath"
