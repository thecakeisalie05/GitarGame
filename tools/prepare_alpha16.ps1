param(
    [Parameter(Mandatory=$true)][string]$InputPath,
    [Parameter(Mandatory=$true)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$alpha15 = Join-Path $PSScriptRoot 'prepare_alpha15.ps1'
& $alpha15 -InputPath $InputPath -OutputPath $OutputPath
if (-not (Test-Path $OutputPath)) { throw 'alpha.15 source preparation did not produce an output file before alpha.16 patching' }

$generatedDir = Split-Path -Parent $OutputPath
$legacyPath = Join-Path $generatedDir 'main.cpp'
$legacy = [System.IO.File]::ReadAllText($legacyPath)

# ---------------------------------------------------------------------------
# Core guitar-engine rules / config migration.
# ---------------------------------------------------------------------------
if (-not $legacy.Contains('#include <bit>')) { throw 'Could not locate legacy <bit> include' }
$legacy = $legacy.Replace('#include <bit>', '#include <bit>' + [Environment]::NewLine + '#include "guitar_engine.h"')

# The setting is a half-window: 70ms early + 70ms late ~= 140ms total.
$legacy = $legacy.Replace(
    '    float hitWindowMs = 120.0f;',
    '    float hitWindowMs = 70.0f;' + [Environment]::NewLine + '    int engineRulesVersion = 0;'
)
if (-not $legacy.Contains('engineRulesVersion')) { throw 'Could not add alpha.16 engine rules version' }

$legacy = $legacy.Replace(
    '            else if (key == "hit_window_ms") s.hitWindowMs = clampFloat(std::stof(value), 20.0f, 250.0f);',
    '            else if (key == "hit_window_ms") s.hitWindowMs = clampFloat(std::stof(value), 20.0f, 250.0f);' + [Environment]::NewLine +
    '            else if (key == "engine_rules_version") s.engineRulesVersion = clampInt(std::stoi(value), 0, 1000);'
)

# Alpha.12 rewrites this output line to include video_offset_ms. Inject the
# engine version independently so old configs can be migrated once.
$saveNeedle = '    out << "hit_window_ms = " << s.hitWindowMs << "\naudio_offset_ms = " << s.audioOffsetMs'
if (-not $legacy.Contains($saveNeedle)) { throw 'Could not locate saveConfig hit-window output' }
$legacy = $legacy.Replace(
    $saveNeedle,
    '    out << "hit_window_ms = " << s.hitWindowMs << "\nengine_rules_version = " << s.engineRulesVersion << "\naudio_offset_ms = " << s.audioOffsetMs'
)

# Preserve the complete XInput state at the exact poll that generated each
# event. This is essential when fret + strum changes occur between render frames.
$inputEventOld = 'struct InputEvent { WORD bit = 0; bool down = false; Clock::time_point when{}; };'
$inputEventNew = 'struct InputEvent { WORD bit = 0; bool down = false; Clock::time_point when{}; WORD buttons = 0; };'
if (-not $legacy.Contains($inputEventOld)) { throw 'Could not locate InputEvent definition for alpha.16' }
$legacy = $legacy.Replace($inputEventOld, $inputEventNew)

$queueOld = 'queue_.push_back({bit, (now & bit) != 0, stamp});'
$queueNew = 'queue_.push_back({bit, (now & bit) != 0, stamp, now});'
if (-not $legacy.Contains($queueOld)) { throw 'Could not locate XInput event enqueue for alpha.16' }
$legacy = $legacy.Replace($queueOld, $queueNew)

# Use one tested fret-matching implementation everywhere (including sustain
# visuals) instead of letting gameplay and rendering drift apart.
$heldPattern = '(?ms)^static bool heldMatches\(uint8_t held, uint8_t target\) \{.*?^}\r?\n'
$heldReplacement = @'
static bool heldMatches(uint8_t held, uint8_t target) {
    return ggengine::heldMatches(held, target);
}
'@
$updatedLegacy = [regex]::Replace($legacy, $heldPattern, $heldReplacement, 1)
if ($updatedLegacy -eq $legacy) { throw 'Could not replace heldMatches for alpha.16' }
$legacy = $updatedLegacy

# Overstrums already break combo; make them cancel the currently active Star
# Power phrase too, matching Clone Hero's documented behavior.
$badStrumNeedle = '    s.lastJudgmentOverstrum = true;'
$badStrumAdd = @'
    s.lastJudgmentOverstrum = true;
    for (size_t i = 0; i < s.chart.starPowerPhrases.size() && i < s.starPhraseFailed.size(); ++i) {
        const auto& phrase = s.chart.starPowerPhrases[i];
        if (now >= phrase.startTime && now <= phrase.endTime) {
            s.starPhraseFailed[i] = true;
            break;
        }
    }
'@
if (-not $legacy.Contains($badStrumNeedle)) { throw 'Could not locate overstrum state for alpha.16' }
$legacy = $legacy.Replace($badStrumNeedle, $badStrumAdd.TrimEnd())

# Strums may hit every guitar note type. Fret transitions are handled separately
# so we can support true hammer-ons, pull-offs, taps and open HOPO/taps.
$tryPattern = '(?ms)^static bool tryHit\(Session& s, double now, double window, uint8_t held, bool strum, uint8_t pressedFret = 0\) \{.*?^}\r?\n'
$tryReplacement = @'
static bool tryHit(Session& s, double now, double window, uint8_t held, bool strum, uint8_t pressedFret = 0) {
    if (s.nextNote >= s.chart.notes.size()) {
        if (strum) registerBadStrumV7(s, now);
        return false;
    }

    auto& n = s.chart.notes[s.nextNote];
    const double delta = n.time - now;
    if (!ggengine::withinHitWindow(n.time, now, window)) {
        if (strum && delta > window) registerBadStrumV7(s, now);
        return false;
    }

    const bool heldCorrect = n.open ? held == 0 : heldMatches(held, n.mask);
    if (!heldCorrect) {
        if (strum) registerBadStrumV7(s, now);
        return false;
    }

    if (!strum) {
        const uint8_t pressedMask = pressedFret;
        if (!ggengine::canFretTransitionHit(n.hopo, n.tap, n.open, s.combo,
                                            held, n.mask, pressedMask, 0)) {
            return false;
        }
    }

    markHit(s, n, now, (now - n.time) * 1000.0);
    return true;
}

static bool tryFretTransitionV16(Session& s, double now, double window,
                                 uint8_t resultingHeld, uint8_t pressedMask,
                                 uint8_t releasedMask) {
    if (s.nextNote >= s.chart.notes.size()) return false;
    auto& n = s.chart.notes[s.nextNote];

    if (!ggengine::withinHitWindow(n.time, now, window)) return false;
    if (!ggengine::canFretTransitionHit(n.hopo, n.tap, n.open, s.combo,
                                        resultingHeld, n.mask,
                                        pressedMask, releasedMask)) {
        return false;
    }

    markHit(s, n, now, (now - n.time) * 1000.0);
    return true;
}
'@
$updatedLegacy = [regex]::Replace($legacy, $tryPattern, $tryReplacement, 1)
if ($updatedLegacy -eq $legacy) { throw 'Could not replace tryHit for alpha.16' }
$legacy = $updatedLegacy

[System.IO.File]::WriteAllText($legacyPath, $legacy, [System.Text.UTF8Encoding]::new($false))

# ---------------------------------------------------------------------------
# UI/main loop: migrate the old default window, clarify its units, and process
# high-resolution guitar events at their poll timestamps rather than frame time.
# ---------------------------------------------------------------------------
$text = [System.IO.File]::ReadAllText($OutputPath)
$text = $text.Replace('v0.1.0-alpha.15', 'v0.1.0-alpha.16')

$configInitOld = '    Settings cfg; if (!loadConfig(configPath, cfg)) saveConfig(configPath, cfg); UiPrefs ui; if (!loadUiPrefs(uiPath, ui)) saveUiPrefs(uiPath, ui);'
$configInitNew = @'
    Settings cfg;
    const bool loadedCoreConfigV16 = loadConfig(configPath, cfg);
    if (!loadedCoreConfigV16) {
        cfg.engineRulesVersion = 16;
        saveConfig(configPath, cfg);
    } else if (cfg.engineRulesVersion < 16) {
        // 120ms was GitarGame's historical default and was interpreted as
        // +/-120ms (240ms total), substantially looser than the CH-like target.
        // Preserve any non-default custom value.
        if (std::abs(cfg.hitWindowMs - 120.0f) < 0.01f) cfg.hitWindowMs = 70.0f;
        cfg.engineRulesVersion = 16;
        saveConfig(configPath, cfg);
#ifdef _WIN32
        ggdiag::log("alpha.16 gameplay rules migrated: half_window_ms=" + std::to_string(cfg.hitWindowMs));
#endif
    }
    UiPrefs ui; if (!loadUiPrefs(uiPath, ui)) saveUiPrefs(uiPath, ui);
'@
if (-not $text.Contains($configInitOld)) { throw 'Could not locate main config initialization for alpha.16 migration' }
$text = $text.Replace($configInitOld, $configInitNew.TrimEnd())

# Make it explicit in the menu that this value is one side of the timing window.
$text = $text.Replace(
    '{"Hit window", TextFormat("%.0f ms", cfg.hitWindowMs)}',
    '{"Hit window", TextFormat("±%.0f ms (%.0f total)", cfg.hitWindowMs, cfg.hitWindowMs * 2.0f)}'
)

# Alpha.13 put frame-wide miss advancement before event handling. Alpha.16
# defers it so an input sampled inside the window cannot be retroactively marked
# missed merely because the render frame consumed it a few milliseconds later.
$timingOld = @'
                    const double now = correctedSongTimeV5(session, cfg, activeChartOffset), window = cfg.hitWindowMs / 1000.0;
                    advanceMisses(session, now, window);
                    updateGameplayStateV7(session, now, window);
                    bool pauseRequested = IsKeyPressed(KEY_ESCAPE);
'@
$timingNew = @'
                    const double now = correctedSongTimeV5(session, cfg, activeChartOffset), window = cfg.hitWindowMs / 1000.0;
                    const auto frameWallV16 = Clock::now();
                    bool pauseRequested = IsKeyPressed(KEY_ESCAPE);
'@
if (-not $text.Contains($timingOld)) { throw 'Could not locate alpha.13 gameplay timing preamble' }
$text = $text.Replace($timingOld, $timingNew)

$inputPattern = '(?ms)#ifdef _WIN32\r?\n                    const WORD xb = poller\.buttons\(\);.*?#endif\r?\n                    const uint8_t kbHeld = heldMaskFromKeyboard\(\);.*?(?=                    const float step =)'
$inputReplacement = @'
#ifdef _WIN32
                    // Consume XInput changes in polling order. All button changes
                    // from one XInputGetState sample share a timestamp and a full
                    // state snapshot, so fret+strum transitions cannot be split by
                    // render-frame timing.
                    size_t eventIndexV16 = 0;
                    auto fretMaskForBitV16 = [&](WORD bit) -> uint8_t {
                        if (bit == cfg.green) return 1 << 0;
                        if (bit == cfg.red) return 1 << 1;
                        if (bit == cfg.yellow) return 1 << 2;
                        if (bit == cfg.blue) return 1 << 3;
                        if (bit == cfg.orange) return 1 << 4;
                        return 0;
                    };

                    while (eventIndexV16 < events.size()) {
                        const auto stamp = events[eventIndexV16].when;
                        const WORD snapshot = events[eventIndexV16].buttons;
                        bool strumDown = false;
                        bool startDown = false;
                        bool starPowerDown = false;
                        uint8_t fretPressed = 0;
                        uint8_t fretReleased = 0;

                        size_t groupEnd = eventIndexV16;
                        while (groupEnd < events.size() && events[groupEnd].when == stamp &&
                               events[groupEnd].buttons == snapshot) {
                            const auto& ev = events[groupEnd];
                            if (ev.down && (ev.bit == cfg.strumUp || ev.bit == cfg.strumDown)) strumDown = true;
                            if (ev.down && ev.bit == cfg.start) startDown = true;
                            if (ev.down && ev.bit == cfg.starPower) starPowerDown = true;

                            const uint8_t fret = fretMaskForBitV16(ev.bit);
                            if (fret != 0) {
                                if (ev.down) fretPressed |= fret;
                                else fretReleased |= fret;
                            }
                            ++groupEnd;
                        }

                        if (startDown) {
                            pauseRequested = true;
                            eventIndexV16 = groupEnd;
                            continue;
                        }
                        if (starPowerDown) activateStarPowerV7(session);

                        const double age = std::chrono::duration<double>(frameWallV16 - stamp).count();
                        const double eventNow = ggengine::eventSongTime(now, age);
                        advanceMisses(session, eventNow, window);
                        const uint8_t heldAtEvent = heldMaskFromXInput(snapshot, cfg);

                        // A single hardware sample may include fret changes and a
                        // strum. Treat that as one musical action: the strum gets
                        // priority and cannot also auto-hit the following HOPO.
                        if (strumDown) {
                            tryHit(session, eventNow, window, heldAtEvent, true);
                        } else if ((fretPressed | fretReleased) != 0) {
                            tryFretTransitionV16(session, eventNow, window, heldAtEvent,
                                                fretPressed, fretReleased);
                        }

                        eventIndexV16 = groupEnd;
                    }
#endif

                    // Keyboard remains frame-polled, but follows the same guitar
                    // semantics including pull-offs and open fret-release notes.
                    const uint8_t kbHeld = heldMaskFromKeyboard();
                    uint8_t kbPressedV16 = 0;
                    uint8_t kbReleasedV16 = 0;
                    if (IsKeyPressed(KEY_A)) kbPressedV16 |= 1 << 0;
                    if (IsKeyPressed(KEY_S)) kbPressedV16 |= 1 << 1;
                    if (IsKeyPressed(KEY_J)) kbPressedV16 |= 1 << 2;
                    if (IsKeyPressed(KEY_K)) kbPressedV16 |= 1 << 3;
                    if (IsKeyPressed(KEY_L)) kbPressedV16 |= 1 << 4;
                    if (IsKeyReleased(KEY_A)) kbReleasedV16 |= 1 << 0;
                    if (IsKeyReleased(KEY_S)) kbReleasedV16 |= 1 << 1;
                    if (IsKeyReleased(KEY_J)) kbReleasedV16 |= 1 << 2;
                    if (IsKeyReleased(KEY_K)) kbReleasedV16 |= 1 << 3;
                    if (IsKeyReleased(KEY_L)) kbReleasedV16 |= 1 << 4;

                    advanceMisses(session, now, window);
                    const bool kbStrumV16 = IsKeyPressed(KEY_UP) || IsKeyPressed(KEY_DOWN);
                    if (kbStrumV16) {
                        tryHit(session, now, window, kbHeld, true);
                    } else if ((kbPressedV16 | kbReleasedV16) != 0) {
                        tryFretTransitionV16(session, now, window, kbHeld,
                                            kbPressedV16, kbReleasedV16);
                    }

                    // Commit misses only after all timestamped inputs up through
                    // this frame have had a chance to be judged.
                    advanceMisses(session, now, window);
                    updateGameplayStateV7(session, now, window);
'@
$updated = [regex]::Replace($text, $inputPattern, $inputReplacement.TrimEnd(), 1)
if ($updated -eq $text) { throw 'Could not replace gameplay input loop for alpha.16' }
$text = $updated

[System.IO.File]::WriteAllText($OutputPath, $text, [System.Text.UTF8Encoding]::new($false))
Write-Host "Prepared alpha.16 Clone Hero-like timing/input engine: $OutputPath"
