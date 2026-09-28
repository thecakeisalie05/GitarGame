param(
    [Parameter(Mandatory=$true)][string]$InputPath,
    [Parameter(Mandatory=$true)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$alpha17 = Join-Path $PSScriptRoot 'prepare_alpha17.ps1'
& $alpha17 -InputPath $InputPath -OutputPath $OutputPath
if (-not (Test-Path $OutputPath)) { throw 'alpha.17 source preparation did not produce an output file before alpha.18 patching' }

$generatedDir = Split-Path -Parent $OutputPath
$legacyPath = Join-Path $generatedDir 'main.cpp'
$legacy = [System.IO.File]::ReadAllText($legacyPath)
$nl = [Environment]::NewLine

# ---------------------------------------------------------------------------
# Clone Hero compatibility state.
# Alpha.17's single "armed note" is replaced with persistent tap readiness,
# early-strum buffering, and one-shot post-HOPO strum eating.
# ---------------------------------------------------------------------------
$legacy = $legacy.Replace('    float hitWindowMs = 90.0f;', '    float hitWindowMs = 70.0f;')

$oldState = '    size_t frontendArmedNote = static_cast<size_t>(-1);'
$newState = @'
    bool chTapReady = false;
    bool pendingStrum = false;
    double pendingStrumAt = -1000.0;
    bool hopoStrumEatAvailable = false;
    double hopoStrumEatUntil = -1000.0;
    ggengine::StrumDirection lastStrumDirection = ggengine::StrumDirection::None;
    double lastAcceptedStrumAt = -1000.0;
'@.TrimEnd()
if (-not $legacy.Contains($oldState)) { throw 'Could not locate alpha.17 frontend state for alpha.18' }
$legacy = $legacy.Replace($oldState, $newState)

$resetOld = 's.frontendArmedNote = static_cast<size_t>(-1);'
$resetNew = 's.chTapReady = false; s.pendingStrum = false; s.pendingStrumAt = -1000.0; s.hopoStrumEatAvailable = false; s.hopoStrumEatUntil = -1000.0; s.lastStrumDirection = ggengine::StrumDirection::None; s.lastAcceptedStrumAt = -1000.0;'
# The first occurrence is resetChartState; later alpha.17 occurrences are patched separately below.
$resetIndex = $legacy.IndexOf($resetOld)
if ($resetIndex -lt 0) { throw 'Could not locate alpha.17 reset state for alpha.18' }
$legacy = $legacy.Remove($resetIndex, $resetOld.Length).Insert($resetIndex, $resetNew)

# markHit() currently contains alpha.17's frontend invalidation immediately
# before nextNote advancement. Replace it with CH-style post-hit state:
# - strum notes leave the frontend/tap state live for the next HOPO/tap
# - HOPO/tap notes clear tap readiness and open an 80ms one-strum eat window
# - any successful hit consumes a pending buffered strum.
$markOld = @'
    s.frontendArmedNote = static_cast<size_t>(-1);
    while (s.nextNote < s.chart.notes.size() && (s.chart.notes[s.nextNote].hit || s.chart.notes[s.nextNote].missed)) ++s.nextNote;
'@
$markNew = @'
    s.pendingStrum = false;
    s.pendingStrumAt = -1000.0;
    if (n.hopo || n.tap) {
        s.chTapReady = false;
        s.hopoStrumEatAvailable = true;
        s.hopoStrumEatUntil = now + ggengine::kCloneHeroHopoStrumEatMs / 1000.0;
    } else {
        // Clone Hero/GH3-style infinite frontend: hitting a strum note primes
        // the next HOPO/tap even if its target fret was already held.
        s.chTapReady = true;
        s.hopoStrumEatAvailable = false;
        s.hopoStrumEatUntil = -1000.0;
    }
    while (s.nextNote < s.chart.notes.size() && (s.chart.notes[s.nextNote].hit || s.chart.notes[s.nextNote].missed)) ++s.nextNote;
'@
if (-not $legacy.Contains($markOld)) { throw 'Could not locate alpha.17 markHit frontend reset' }
$legacy = $legacy.Replace($markOld, $markNew)

# Overstrums clear all carried input leniency. Alpha.17 inserted a standalone
# frontend reset after the lastJudgmentOverstrum assignment.
$badOld = @'
    s.lastJudgmentOverstrum = true;
    s.frontendArmedNote = static_cast<size_t>(-1);
'@
$badNew = @'
    s.lastJudgmentOverstrum = true;
    s.chTapReady = false;
    s.pendingStrum = false;
    s.pendingStrumAt = -1000.0;
    s.hopoStrumEatAvailable = false;
    s.hopoStrumEatUntil = -1000.0;
'@
if (-not $legacy.Contains($badOld)) { throw 'Could not locate alpha.17 bad-strum frontend reset' }
$legacy = $legacy.Replace($badOld, $badNew)

# Missing a note clears GH3-style infinite frontend as documented in historical
# CH release notes. Pending strums/strum-eat state also cannot cross a miss.
$missOld = @'
            s.combo = 0;
            s.rockMeter = std::max(0.0f, s.rockMeter - 0.060f);
'@
$missNew = @'
            s.combo = 0;
            s.chTapReady = false;
            s.pendingStrum = false;
            s.pendingStrumAt = -1000.0;
            s.hopoStrumEatAvailable = false;
            s.hopoStrumEatUntil = -1000.0;
            s.rockMeter = std::max(0.0f, s.rockMeter - 0.060f);
'@
if (-not $legacy.Contains($missOld)) { throw 'Could not locate miss-state block for alpha.18' }
$legacy = $legacy.Replace($missOld, $missNew)

# Replace alpha.16's immediate strum judgment with a CH-style strum state
# machine: +/-70ms core window, 50ms early-strum buffer, fret-correction
# leniency while the buffered strum is alive, and post-HOPO strum eating.
$tryPattern = '(?ms)^static bool tryHit\(Session& s, double now, double window, uint8_t held, bool strum, uint8_t pressedFret = 0\) \{.*?^}\r?\n'
$tryReplacement = @'
static bool tryConsumeFrontendV18(Session& s, double now, double window,
                                  uint8_t held) {
    if (!s.chTapReady || s.nextNote >= s.chart.notes.size()) return false;
    auto& n = s.chart.notes[s.nextNote];

    if (!(n.hopo || n.tap)) return false;
    if (!ggengine::withinHitWindow(n.time, now, window)) return false;
    if (n.hopo && s.combo <= 0) return false;
    if (!ggengine::noteFrettingMatches(held, n.mask, n.open, false, n.hopo, n.tap))
        return false;

    markHit(s, n, now, (now - n.time) * 1000.0);
    return true;
}

static bool tryConsumePendingStrumV18(Session& s, double now, double window,
                                      uint8_t held) {
    if (!s.pendingStrum) return false;

    const double leniency = ggengine::kCloneHeroStrumLeniencyMs / 1000.0;
    if (s.nextNote < s.chart.notes.size()) {
        auto& n = s.chart.notes[s.nextNote];
        if (ggengine::withinHitWindow(n.time, now, window) &&
            ggengine::noteFrettingMatches(held, n.mask, n.open, true, n.hopo, n.tap)) {
            markHit(s, n, now, (now - n.time) * 1000.0);
            return true;
        }
    }

    if (!ggengine::strumBufferActive(s.pendingStrumAt, now, leniency)) {
        s.pendingStrum = false;
        s.pendingStrumAt = -1000.0;
        registerBadStrumV7(s, now);
    }
    return false;
}

static bool tryHit(Session& s, double now, double window, uint8_t held,
                   bool strum, uint8_t pressedFret = 0,
                   ggengine::StrumDirection direction = ggengine::StrumDirection::None,
                   double doubleStrumProtectionSeconds = 0.0) {
    (void) pressedFret;
    if (!strum) return false;

    if (ggengine::sameDirectionStrumProtected(
            s.lastStrumDirection, s.lastAcceptedStrumAt, direction, now,
            doubleStrumProtectionSeconds)) {
        return false;
    }
    s.lastStrumDirection = direction;
    s.lastAcceptedStrumAt = now;

    const double hopoEat = ggengine::kCloneHeroHopoStrumEatMs / 1000.0;
    if (s.hopoStrumEatAvailable) {
        if (ggengine::hopoCanEatStrum(s.hopoStrumEatUntil - hopoEat, now, hopoEat)) {
            // Clone Hero is notably forgiving when a HOPO/tap and strum land
            // close together. One strum is consumed without breaking combo.
            s.hopoStrumEatAvailable = false;
            s.hopoStrumEatUntil = -1000.0;
            return false;
        }
        if (now > s.hopoStrumEatUntil) {
            s.hopoStrumEatAvailable = false;
            s.hopoStrumEatUntil = -1000.0;
        }
    }

    // A second strum while the first is buffered is an overstrum. Continue
    // handling the new strum as a fresh input, matching the timer-based GH/CH
    // family behavior instead of silently discarding it.
    if (s.pendingStrum) {
        s.pendingStrum = false;
        s.pendingStrumAt = -1000.0;
        registerBadStrumV7(s, now);
    }

    if (s.nextNote >= s.chart.notes.size()) {
        registerBadStrumV7(s, now);
        return false;
    }

    auto& n = s.chart.notes[s.nextNote];
    const bool inCoreWindow = ggengine::withinHitWindow(n.time, now, window);
    if (inCoreWindow) {
        if (ggengine::noteFrettingMatches(held, n.mask, n.open, true, n.hopo, n.tap)) {
            markHit(s, n, now, (now - n.time) * 1000.0);
            return true;
        }

        // Keep the strum alive briefly so fret order within a physical gesture
        // does not create an artificial miss/overstrum.
        s.pendingStrum = true;
        s.pendingStrumAt = now;
        return false;
    }

    const double leniency = ggengine::kCloneHeroStrumLeniencyMs / 1000.0;
    if (ggengine::earlyStrumCanBuffer(n.time, now, window, leniency)) {
        s.pendingStrum = true;
        s.pendingStrumAt = now;
        return false;
    }

    registerBadStrumV7(s, now);
    return false;
}
'@
$updatedLegacy = [regex]::Replace($legacy, $tryPattern, $tryReplacement, 1)
if ($updatedLegacy -eq $legacy) { throw 'Could not replace strum judgment for alpha.18' }
$legacy = $updatedLegacy

# Replace alpha.17's note-specific frontend arming with true GH3/Clone Hero
# infinite frontend: any fret transition makes tap state live, and it remains
# live until a HOPO/tap consumes it, a miss/overstrum clears it, or playback resets.
$fretPattern = '(?ms)^static bool tryFretTransitionV17\(Session& s, double now, double window,.*?^}\r?\n\r?\nstatic bool tryConsumeFrontendV17\(Session& s, double now, double window,.*?^}\r?\n'
$fretReplacement = @'
static bool tryFretTransitionV18(Session& s, double now, double window,
                                 uint8_t resultingHeld, uint8_t pressedMask,
                                 uint8_t releasedMask) {
    if ((pressedMask | releasedMask) == 0) return false;

    // Normal CH ghost inputs do not punish combo/hitability. Any real fret
    // transition keeps the HOPO/tap frontend state live; actual note matching
    // is checked only when attempting the hit.
    s.chTapReady = true;

    if (tryConsumeFrontendV18(s, now, window, resultingHeld)) return true;
    return tryConsumePendingStrumV18(s, now, window, resultingHeld);
}
'@
$updatedLegacy = [regex]::Replace($legacy, $fretPattern, $fretReplacement, 1)
if ($updatedLegacy -eq $legacy) { throw 'Could not replace alpha.17 frontend engine for alpha.18' }
$legacy = $updatedLegacy

if ($legacy.Contains('frontendArmedNote') -or $legacy.Contains('tryConsumeFrontendV17') -or
    $legacy.Contains('tryFretTransitionV17')) {
    throw 'alpha.18 hardening failed: alpha.17 frontend implementation remains in legacy source'
}

[System.IO.File]::WriteAllText($legacyPath, $legacy, [System.Text.UTF8Encoding]::new($false))

# ---------------------------------------------------------------------------
# Main/UI integration. Keep alpha.17 calibration persistence untouched.
# ---------------------------------------------------------------------------
$text = [System.IO.File]::ReadAllText($OutputPath)
$text = $text.Replace('v0.1.0-alpha.17', 'v0.1.0-alpha.18')

# Clone Hero exposes these as profile settings. Keep zero as the neutral default
# until the player selects the same values used by their CH profile.
# Settings is declared in generated main.cpp (inside namespace legacy from
# main_v3.cpp), so patch the legacy generated file rather than the wrapper.
$legacySettingsText = [System.IO.File]::ReadAllText($legacyPath)
$settingsPattern = '(?m)^(\s*float hitWindowMs\s*=\s*[^;]+;)'
if (-not [regex]::IsMatch($legacySettingsText, $settingsPattern)) { throw 'Could not locate Settings hit-window field for alpha.18 profile settings' }
$legacySettingsText = [regex]::Replace(
    $legacySettingsText, $settingsPattern,
    '$1' + $nl +
    '    float doubleStrumProtectionMs = 0.0f;' + $nl +
    '    float sustainDropLeniencyMs = 0.0f;',
    1
)
[System.IO.File]::WriteAllText($legacyPath, $legacySettingsText)
$text = $text.Replace(
    'else if (key == "hit_window_ms") s.hitWindowMs = clampFloat(std::stof(value), 20.0f, 250.0f);',
    'else if (key == "hit_window_ms") s.hitWindowMs = clampFloat(std::stof(value), 20.0f, 250.0f);' + $nl +
    '            else if (key == "double_strum_protection_ms") s.doubleStrumProtectionMs = clampFloat(std::stof(value), 0.0f, 250.0f);' + $nl +
    '            else if (key == "sustain_drop_leniency_ms") s.sustainDropLeniencyMs = clampFloat(std::stof(value), 0.0f, 250.0f);'
)
$text = $text.Replace(
    'out << "hit_window_ms = " << s.hitWindowMs << "\naudio_offset_ms = " << s.audioOffsetMs',
    'out << "hit_window_ms = " << s.hitWindowMs << "\ndouble_strum_protection_ms = " << s.doubleStrumProtectionMs << "\nsustain_drop_leniency_ms = " << s.sustainDropLeniencyMs << "\naudio_offset_ms = " << s.audioOffsetMs'
)

# Restore the core window to the documented CH +/-70ms and migrate only the
# untouched alpha.17 +/-90ms default. Custom windows remain custom.
$text = $text.Replace('cfg.hitWindowMs = 90.0f;' + $nl + '        cfg.engineRulesVersion = 17;',
                      'cfg.hitWindowMs = 70.0f;' + $nl + '        cfg.engineRulesVersion = 18;')
$text = $text.Replace('} else if (cfg.engineRulesVersion < 17) {', '} else if (cfg.engineRulesVersion < 18) {')
$text = $text.Replace(
    'if (std::abs(cfg.hitWindowMs - 70.0f) < 0.01f) cfg.hitWindowMs = 90.0f;' + $nl +
    '        cfg.engineRulesVersion = 17;',
    'if (std::abs(cfg.hitWindowMs - 90.0f) < 0.01f) cfg.hitWindowMs = 70.0f;' + $nl +
    '        cfg.engineRulesVersion = 18;'
)
$text = $text.Replace('alpha.17 gameplay rules migrated:', 'alpha.18 Clone Hero rules migrated:')

# Swap alpha.17 calls for the new state machine.
$text = $text.Replace('tryConsumeFrontendV17(', 'tryConsumeFrontendV18(')
$text = $text.Replace('tryFretTransitionV17(', 'tryFretTransitionV18(')

# Preserve physical strum direction for CH's same-direction Double Strum
# Protection. Opposite-direction alt-strums must never be swallowed.
$text = $text.Replace(
    'bool strumDown = false;' + $nl + '                        bool startDown = false;',
    'bool strumDown = false;' + $nl +
    '                        ggengine::StrumDirection strumDirectionV18 = ggengine::StrumDirection::None;' + $nl +
    '                        bool startDown = false;'
)
$text = $text.Replace(
    'if (ev.down && (ev.bit == cfg.strumUp || ev.bit == cfg.strumDown)) strumDown = true;',
    'if (ev.down && (ev.bit == cfg.strumUp || ev.bit == cfg.strumDown)) {' + $nl +
    '                                strumDown = true;' + $nl +
    '                                strumDirectionV18 = (ev.bit == cfg.strumUp) ? ggengine::StrumDirection::Up : ggengine::StrumDirection::Down;' + $nl +
    '                            }'
)
$text = $text.Replace(
    'tryHit(session, eventNow, window, heldAtEvent, true);',
    'tryHit(session, eventNow, window, heldAtEvent, true, 0, strumDirectionV18, cfg.doubleStrumProtectionMs / 1000.0);'
)
$text = $text.Replace(
    'const bool kbStrumV16 = IsKeyPressed(KEY_UP) || IsKeyPressed(KEY_DOWN);' + $nl +
    '                    if (kbStrumV16) {' + $nl +
    '                        tryHit(session, now, window, kbHeld, true);',
    'const bool kbUpV18 = IsKeyPressed(KEY_UP);' + $nl +
    '                    const bool kbDownV18 = IsKeyPressed(KEY_DOWN);' + $nl +
    '                    const bool kbStrumV16 = kbUpV18 || kbDownV18;' + $nl +
    '                    if (kbStrumV16) {' + $nl +
    '                        const auto kbDirectionV18 = kbUpV18 ? ggengine::StrumDirection::Up : ggengine::StrumDirection::Down;' + $nl +
    '                        tryHit(session, now, window, kbHeld, true, 0, kbDirectionV18, cfg.doubleStrumProtectionMs / 1000.0);'
)

# main_v3.cpp includes generated main.cpp inside namespace legacy, so its static
# Star Power helper is not directly visible here. Inline the tiny activation rule.
$text = $text.Replace(
    'if (starPowerDown) activateStarPowerV7(session);',
    'if (starPowerDown && !session.starPowerActive && session.starPowerMeter >= 0.50f) session.starPowerActive = true;'
)
$text = $text.Replace(
    'if (IsKeyPressed(KEY_TAB)) activateStarPowerV7(session);',
    'if (IsKeyPressed(KEY_TAB) && !session.starPowerActive && session.starPowerMeter >= 0.50f) session.starPowerActive = true;'
)

# Pending strums must be reevaluated whenever time or fret state advances.
$xinputConsumeOld = @'
                        tryConsumeFrontendV18(session, eventNow, window, heldAtEvent);
                        advanceMisses(session, eventNow, window);
'@
$xinputConsumeNew = @'
                        tryConsumeFrontendV18(session, eventNow, window, heldAtEvent);
                        tryConsumePendingStrumV18(session, eventNow, window, heldAtEvent);
                        advanceMisses(session, eventNow, window);
'@
if (-not $text.Contains($xinputConsumeOld)) { throw 'Could not locate XInput frontend consume for alpha.18' }
$text = $text.Replace($xinputConsumeOld, $xinputConsumeNew)

$frameXinputOld = @'
                    tryConsumeFrontendV18(session, now, window,
                                         heldMaskFromXInput(poller.buttons(), cfg));
#endif
                    tryConsumeFrontendV18(session, now, window, kbHeld);
                    advanceMisses(session, now, window);
'@
$frameXinputNew = @'
                    const uint8_t liveXInputHeldV18 = heldMaskFromXInput(poller.buttons(), cfg);
                    tryConsumeFrontendV18(session, now, window, liveXInputHeldV18);
                    tryConsumePendingStrumV18(session, now, window, liveXInputHeldV18);
#endif
                    tryConsumeFrontendV18(session, now, window, kbHeld);
                    tryConsumePendingStrumV18(session, now, window, kbHeld);
                    advanceMisses(session, now, window);
'@
if (-not $text.Contains($frameXinputOld)) { throw 'Could not locate frame frontend consume for alpha.18' }
$text = $text.Replace($frameXinputOld, $frameXinputNew)

# The settings UI still displays the core window directly. Add a concise hint so
# users do not interpret +/-70ms as the complete effective input forgiveness.
$text = $text.Replace(
    '{"Hit window", TextFormat("±%.0f ms (%.0f total)", cfg.hitWindowMs, cfg.hitWindowMs * 2.0f)}',
    '{"Hit window", TextFormat("±%.0f ms core + CH leniency", cfg.hitWindowMs)}'
)

if ($text.Contains('tryConsumeFrontendV17(') -or $text.Contains('tryFretTransitionV17(')) {
    throw 'alpha.18 hardening failed: old frontend calls remain in generated UI source'
}

[System.IO.File]::WriteAllText($OutputPath, $text, [System.Text.UTF8Encoding]::new($false))
Write-Host "Prepared alpha.18 Clone Hero compatibility state machine: $OutputPath"
