param(
    [Parameter(Mandatory=$true)][string]$InputPath,
    [Parameter(Mandatory=$true)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$alpha19 = Join-Path $PSScriptRoot 'prepare_alpha19.ps1'
& $alpha19 -InputPath $InputPath -OutputPath $OutputPath
if (-not (Test-Path $OutputPath)) { throw 'alpha.19 source preparation did not produce an output file before alpha.20 patching' }

$generatedDir = Split-Path -Parent $OutputPath
$legacyPath = Join-Path $generatedDir 'main.cpp'
$legacy = [System.IO.File]::ReadAllText($legacyPath)
$nl = [Environment]::NewLine

# ---------------------------------------------------------------------------
# Compatibility regression fix.
#
# alpha.19 accidentally asked audioExtension() whether .opus files existed.
# audioExtension() intentionally reports only formats raylib can stream
# natively, so Opus-only packages were invisible to the cache/prewarm path.
# Detect Opus explicitly and always retain the proven decoder/mixer fallback.
# ---------------------------------------------------------------------------
$needsPattern = '(?ms)^static bool needsFullOpusPreparationV19\(const fs::path& dir\) \{.*?^\}\r?\n'
$needsReplacement = @'
static bool needsFullOpusPreparationV19(const fs::path& dir) {
    std::error_code ec;
    bool hasOpus = false;
    bool hasNative = false;
    for (const auto& entry : fs::directory_iterator(dir, ec)) {
        if (!entry.is_regular_file(ec)) { ec.clear(); continue; }
        const auto path = entry.path();
        if (lower(path.stem().string()) == "preview") continue;
        const std::string ext = lower(path.extension().string());
        if (ext == ".opus") hasOpus = true;
        else if (audioExtension(path)) hasNative = true;
    }
    // Native streams remain preferred when present. Opus preparation is only
    // required for packages that would otherwise have no playable audio.
    return hasOpus && !hasNative;
}
'@
$updated = [regex]::Replace($legacy, $needsPattern, $needsReplacement, 1)
if ($updated -eq $legacy) { throw 'Could not repair alpha.19 Opus detection for alpha.20' }
$legacy = $updated

$loadPattern = '(?ms)^static std::vector<Stem> loadStems\(const fs::path& dir\) \{.*?^\}\r?\n\r?\nstatic void unloadStems'
$loadReplacement = @'
static std::vector<Stem> loadStems(const fs::path& dir) {
    std::vector<fs::path> files;
    std::error_code ec;
    bool hasOpus = false;
    for (const auto& entry : fs::directory_iterator(dir, ec)) {
        if (!entry.is_regular_file(ec)) { ec.clear(); continue; }
        const auto path = entry.path();
        if (lower(path.stem().string()) == "preview") continue;
        const std::string ext = lower(path.extension().string());
        if (ext == ".opus") {
            hasOpus = true;
            continue;
        }
        if (audioExtension(path)) files.push_back(path);
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
    if (!stems.empty() || !hasOpus) return stems;

    // Fast path: persistent prepared WAV from alpha.19.
    fs::path preparedPath = preparedFullOpusPathV19(dir);
    if (!preparedPath.empty()) {
        const std::string preparedUtf8 = preparedPath.string();
        Music m = LoadMusicStream(preparedUtf8.c_str());
        if (m.ctxData != nullptr) {
            stems.push_back({m, preparedPath, {}});
#ifdef _WIN32
            ggdiag::log("Loaded Opus package from persistent PCM cache");
#endif
            return stems;
        }
    }

    // Compatibility fallback: cache preparation must never decide whether a
    // valid song can play. If the cache is absent/broken, use the proven
    // alpha.9 decoder/mixer directly and keep the bytes alive with the Stem.
    std::string opusError;
    auto mixed = opusmix::mixDirectory(dir, opusError);
    if (!mixed) {
#ifdef _WIN32
        if (!opusError.empty() && opusError != "No .opus stems found")
            ggdiag::log("Opus compatibility fallback failed: " + opusError);
#endif
        return stems;
    }

    auto backing = std::make_shared<std::vector<unsigned char>>(std::move(mixed->wavBytes));
    if (backing->size() > static_cast<size_t>(std::numeric_limits<int>::max())) return stems;
    Music m = LoadMusicStreamFromMemory(".wav", backing->data(), static_cast<int>(backing->size()));
    if (m.ctxData != nullptr) {
        stems.push_back({m, dir / "<mixed opus stems>", backing});
#ifdef _WIN32
        ggdiag::log("Loaded Opus package through compatibility fallback");
#endif
    }
    return stems;
}

static void unloadStems
'@
$updated = [regex]::Replace($legacy, $loadPattern, $loadReplacement, 1)
if ($updated -eq $legacy) { throw 'Could not replace alpha.19 loader with alpha.20 compatibility-first loader' }
$legacy = $updated

# ---------------------------------------------------------------------------
# Whammy input.
#
# XInput guitar adapters vary: common mappings expose whammy through a trigger
# or right-stick axis. Track all common analog candidates and use the strongest
# normalized displacement. Keyboard fallback is Space while playing.
# ---------------------------------------------------------------------------
$buttonsAccessor = '    WORD buttons() const { return buttons_.load(std::memory_order_relaxed); }'
$buttonsWithWhammy = $buttonsAccessor + $nl + '    float whammy() const { return whammy_.load(std::memory_order_relaxed); }'
if (-not $legacy.Contains($buttonsAccessor)) { throw 'Could not locate XInput buttons accessor for whammy' }
$legacy = $legacy.Replace($buttonsAccessor, $buttonsWithWhammy)

$buttonsStore = '            buttons_.store(now, std::memory_order_relaxed);'
$whammyStore = @'
            buttons_.store(now, std::memory_order_relaxed);
            float whammyValue = 0.0f;
            if (ok) {
                const float leftTrigger = static_cast<float>(state.Gamepad.bLeftTrigger) / 255.0f;
                const float rightTrigger = static_cast<float>(state.Gamepad.bRightTrigger) / 255.0f;
                const auto axisAmount = [](SHORT value) {
                    const float normalized = std::abs(static_cast<float>(value)) / 32767.0f;
                    return normalized < 0.16f ? 0.0f : (normalized - 0.16f) / 0.84f;
                };
                const float rightX = axisAmount(state.Gamepad.sThumbRX);
                const float rightY = axisAmount(state.Gamepad.sThumbRY);
                whammyValue = std::clamp(std::max({leftTrigger, rightTrigger, rightX, rightY}), 0.0f, 1.0f);
            }
            whammy_.store(whammyValue, std::memory_order_relaxed);
'@
if (-not $legacy.Contains($buttonsStore)) { throw 'Could not locate XInput button state store for whammy' }
$legacy = $legacy.Replace($buttonsStore, $whammyStore.TrimEnd())

$buttonsAtomic = '    std::atomic<WORD> buttons_{0};'
$whammyAtomic = $buttonsAtomic + $nl + '    std::atomic<float> whammy_{0.0f};'
if (-not $legacy.Contains($buttonsAtomic)) { throw 'Could not locate XInput button atomic for whammy' }
$legacy = $legacy.Replace($buttonsAtomic, $whammyAtomic)

[System.IO.File]::WriteAllText($legacyPath, $legacy, [System.Text.UTF8Encoding]::new($false))

# ---------------------------------------------------------------------------
# UI / visuals / whammy gameplay.
# ---------------------------------------------------------------------------
$text = [System.IO.File]::ReadAllText($OutputPath)
$text = $text.Replace('v0.1.0-alpha.19', 'v0.1.0-alpha.20')

# Selected-song preview must request Opus preparation based on explicit Opus
# detection, not raylib's native extension list (fixed above in legacy source).

# Gold Star Power phrase gems + much stronger HOPO glow. Patch the alpha.14
# lane-note renderer after all earlier visual passes have been applied.
$lanePattern = '(?ms)        for \(int lane = 0; lane < 5; \+\+lane\) if \(n\.mask & \(1 << lane\)\) \{.*?^        \}\r?\n'
$laneReplacement = @'
        for (int lane = 0; lane < 5; ++lane) if (n.mask & (1 << lane)) {
            const bool starNoteV20 = n.starPhrase >= 0;
            const Color goldV20{255, 202, 55, 255};
            Color c = starNoteV20 ? goldV20 : cfg.lanes[lane];
            float radius = laneWidth * 0.31f * ui.noteScale;
            float missAlpha = 1.0f;
            float redMix = 0.0f;
            if (n.missed) {
                const double missAge = std::max(0.0, now - n.judgedAt);
                redMix = static_cast<float>(ggfeedback::missRedBlend(missAge));
                radius *= static_cast<float>(ggfeedback::missScale(missAge));
                missAlpha = static_cast<float>(ggfeedback::missAlpha(missAge));
                c = mixColor(c, missColor, redMix);
                c.a = static_cast<unsigned char>(235.0f * missAlpha);
            } else if (n.hit) {
                c.a = 70;
            }

            if (n.tap) {
                Color tapOuter = n.missed ? mixColor(RAYWHITE, missColor, redMix * 0.82f)
                                          : (starNoteV20 ? Color{255, 232, 130, 255} : Color{235, 248, 255, 255});
                tapOuter.a = n.missed ? static_cast<unsigned char>(225.0f * missAlpha)
                                      : static_cast<unsigned char>(n.hit ? 75 : 255);
                drawDisc3DV5({laneX(lane), 0.075f, z}, radius * 0.96f, 0.110f, 14, tapOuter);
                drawDisc3DV5({laneX(lane), 0.190f, z}, radius * 0.47f, 0.028f, 14, c);
                DrawCylinderWires({laneX(lane), 0.195f, z}, radius * 0.53f, radius * 0.53f, 0.034f, 14,
                                  n.missed ? alphaColor(missColor, static_cast<unsigned char>(205.0f * missAlpha))
                                           : alphaColor(RAYWHITE, n.hit ? 65 : 245));
            } else if (n.hopo) {
                // HOPOs get a visible aura rather than relying on the small
                // silver center alone. The glow pulses subtly but remains
                // unmistakable at highway speed.
                const float hopoPulseV20 = 0.80f + 0.20f * std::sin(static_cast<float>(GetTime()) * 7.0f + lane);
                Color aura = starNoteV20 ? Color{255, 220, 80, static_cast<unsigned char>(135 * hopoPulseV20)}
                                         : Color{205, 238, 255, static_cast<unsigned char>(125 * hopoPulseV20)};
                if (!n.missed && !n.hit) {
                    drawDisc3DV5({laneX(lane), 0.050f, z}, radius * 1.20f, 0.040f, 18, aura);
                    DrawCylinderWires({laneX(lane), 0.055f, z}, radius * 1.24f, radius * 1.24f, 0.045f, 18,
                                      alphaColor(aura, static_cast<unsigned char>(185 * hopoPulseV20)));
                }
                Color rim = n.missed ? mixColor(Color{225, 235, 245, 255}, missColor, redMix * 0.86f)
                                     : (starNoteV20 ? Color{255, 235, 150, 255} : Color{225, 235, 245, 255});
                rim.a = n.missed ? static_cast<unsigned char>(220.0f * missAlpha)
                                 : static_cast<unsigned char>(n.hit ? 65 : 255);
                drawDisc3DV5({laneX(lane), 0.072f, z}, radius * 0.88f, 0.100f, 14, rim);
                drawDisc3DV5({laneX(lane), 0.178f, z}, radius * 0.55f, 0.035f, 14, c);
                DrawCylinderWires({laneX(lane), 0.181f, z}, radius * 0.62f, radius * 0.62f, 0.042f, 14,
                                  n.missed ? alphaColor(missColor, static_cast<unsigned char>(195.0f * missAlpha))
                                           : alphaColor(RAYWHITE, n.hit ? 55 : 245));
            } else {
                if (starNoteV20 && !n.missed && !n.hit) {
                    drawDisc3DV5({laneX(lane), 0.050f, z}, radius * 1.10f, 0.035f, 16,
                                 alphaColor(goldV20, 85));
                }
                drawDisc3DV5({laneX(lane), 0.07f, z}, radius, 0.115f, 12, c);
                Color shine = n.missed ? mixColor(alphaColor(RAYWHITE, 65), missColor, redMix)
                                       : alphaColor(RAYWHITE, n.hit ? 20 : (starNoteV20 ? 130 : 65));
                if (n.missed) shine.a = static_cast<unsigned char>(100.0f * missAlpha);
                drawDisc3DV5({laneX(lane), 0.188f, z}, radius * (starNoteV20 ? 0.24f : 0.18f), 0.020f, 10, shine);
            }
        }
'@
$updated = [regex]::Replace($text, $lanePattern, $laneReplacement, 1)
if ($updated -eq $text) { throw 'Could not replace lane-note renderer for alpha.20 glow/SP visuals' }
$text = $updated

# Open notes in SP phrases become gold bars.
$openMarker = '        if (n.open) {'
$openGold = @'
        if (n.open) {
            const bool starOpenV20 = n.starPhrase >= 0;
'@
if (-not $text.Contains($openMarker)) { throw 'Could not locate open note renderer for SP visuals' }
$text = $text.Replace($openMarker, $openGold.TrimEnd())
$text = $text.Replace('            Color c = RAYWHITE;', '            Color c = starOpenV20 ? Color{255, 202, 55, 255} : RAYWHITE;', 1)

# Stronger receptor/strike-line hit animation: bright flash plus expanding lane
# ring. This supplements, rather than replaces, alpha.14's shaped hit ghost.
$strikeNeedle = '    if (openSustainHeldV13) strike = mixColor(strike, RAYWHITE, 0.55f);'
$strikeAdd = @'
    if (openSustainHeldV13) strike = mixColor(strike, RAYWHITE, 0.55f);
    if (hitAgeV13 >= 0.0 && hitAgeV13 < 0.18) {
        const float flashV20 = 1.0f - static_cast<float>(hitAgeV13 / 0.18);
        strike = mixColor(strike, RAYWHITE, 0.35f + 0.65f * flashV20);
    }
'@
if (-not $text.Contains($strikeNeedle)) { throw 'Could not locate strike feedback for alpha.20' }
$text = $text.Replace($strikeNeedle, $strikeAdd.TrimEnd())

$laneHitMarker = @'
        if (laneHit) {
            // Render a short-lived ghost of the note itself. Normal notes,
'@
$laneHitReplacement = @'
        if (laneHit) {
            const float impactProgressV20 = std::clamp(static_cast<float>(hitAgeV13 / 0.24), 0.0f, 1.0f);
            const float impactAlphaV20 = 1.0f - impactProgressV20;
            const float impactRadiusV20 = baseRadius * (1.15f + impactProgressV20 * 1.55f);
            DrawCylinderWires({x, 0.170f, hitZ - 0.12f}, impactRadiusV20, impactRadiusV20, 0.028f, 20,
                              alphaColor(RAYWHITE, static_cast<unsigned char>(235.0f * impactAlphaV20)));

            // Render a short-lived ghost of the note itself. Normal notes,
'@
if (-not $text.Contains($laneHitMarker)) { throw 'Could not locate lane hit ghost for alpha.20 impact ring' }
$text = $text.Replace($laneHitMarker, $laneHitReplacement.TrimEnd())

# Whammy state and Star Power gain. While a hit SP sustain is currently being
# held, moving the whammy bar provides a small continuous SP gain. The rendered
# sustain also wiggles in width so the player can see the input immediately.
$playingHeldNeedle = @'
#ifdef _WIN32
                const uint8_t held = static_cast<uint8_t>(heldMaskFromKeyboard() | heldMaskFromXInput(poller.buttons(), cfg));
#else
                const uint8_t held = heldMaskFromKeyboard();
#endif
'@
$playingHeldReplacement = @'
#ifdef _WIN32
                const uint8_t held = static_cast<uint8_t>(heldMaskFromKeyboard() | heldMaskFromXInput(poller.buttons(), cfg));
                const float whammyV20 = std::max(poller.whammy(), IsKeyDown(KEY_SPACE) ? 1.0f : 0.0f);
#else
                const uint8_t held = heldMaskFromKeyboard();
                const float whammyV20 = IsKeyDown(KEY_SPACE) ? 1.0f : 0.0f;
#endif
'@
if (-not $text.Contains($playingHeldNeedle)) { throw 'Could not locate Playing held-mask rendering block for whammy' }
$text = $text.Replace($playingHeldNeedle, $playingHeldReplacement.TrimEnd())

# drawHighway signature accepts current whammy amount for sustain animation.
$text = $text.Replace(
    'static void drawHighway3DV5(const Session& s, const Settings& cfg, const UiPrefs& ui, double now, uint8_t held,' + $nl + '                            double chartOffsetSeconds) {',
    'static void drawHighway3DV5(const Session& s, const Settings& cfg, const UiPrefs& ui, double now, uint8_t held,' + $nl + '                            double chartOffsetSeconds, float whammyV20 = 0.0f) {'
)
$text = $text.Replace('activeChartOffset); break;', 'activeChartOffset, whammyV20); break;')

# Pulse currently held sustain widths with whammy.
$text = $text.Replace(
    'const float width = laneWidth * (holding ? 0.27f : 0.16f) * ui.noteScale;',
    'const float whammyScaleV20 = holding ? (1.0f + 0.18f * whammyV20 * std::sin(static_cast<float>(GetTime()) * 24.0f + lane)) : 1.0f;' + $nl +
    '            const float width = laneWidth * (holding ? 0.27f : 0.16f) * ui.noteScale * whammyScaleV20;'
)

# Gameplay-side SP gain runs once per frame using the current corrected song
# time and actual held state. Only an already-hit sustain in an SP phrase counts.
$updateNeedle = '                    updateGameplayStateV7(session, now, window);'
$updateReplacement = @'
                    updateGameplayStateV7(session, now, window);
                    float whammyInputV20 = IsKeyDown(KEY_SPACE) ? 1.0f : 0.0f;
#ifdef _WIN32
                    whammyInputV20 = std::max(whammyInputV20, poller.whammy());
#endif
                    if (whammyInputV20 > 0.03f && !session.starPowerActive) {
                        bool whammyEligibleV20 = false;
                        for (const auto& noteV20 : session.chart.notes) {
                            if (noteV20.time > now + 0.02) break;
                            if (!noteV20.hit || noteV20.starPhrase < 0 || noteV20.sustain <= 0.02) continue;
                            if (now < noteV20.time || now > noteV20.time + noteV20.sustain) continue;
#ifdef _WIN32
                            const uint8_t heldWhammyV20 = static_cast<uint8_t>(heldMaskFromKeyboard() | heldMaskFromXInput(poller.buttons(), cfg));
#else
                            const uint8_t heldWhammyV20 = heldMaskFromKeyboard();
#endif
                            if (noteV20.open ? heldWhammyV20 == 0 : heldMatches(heldWhammyV20, noteV20.mask)) {
                                whammyEligibleV20 = true;
                                break;
                            }
                        }
                        if (whammyEligibleV20) {
                            const float dtWhammyV20 = std::clamp(GetFrameTime(), 0.0f, 0.05f);
                            session.starPowerMeter = std::min(1.0f, session.starPowerMeter + dtWhammyV20 * 0.035f * whammyInputV20);
                        }
                    }
'@
if (-not $text.Contains($updateNeedle)) { throw 'Could not locate gameplay update for whammy SP gain' }
$text = $text.Replace($updateNeedle, $updateReplacement.TrimEnd())

[System.IO.File]::WriteAllText($OutputPath, $text, [System.Text.UTF8Encoding]::new($false))
Write-Host "Prepared alpha.20 compatibility restoration, stronger note feedback, HOPO glow, whammy and SP phrase visuals: $OutputPath"
