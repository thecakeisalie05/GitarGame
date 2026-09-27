param(
    [Parameter(Mandatory=$true)][string]$InputPath,
    [Parameter(Mandatory=$true)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$alpha13 = Join-Path $PSScriptRoot 'prepare_alpha13.ps1'
& $alpha13 -InputPath $InputPath -OutputPath $OutputPath
if (-not (Test-Path $OutputPath)) { throw 'alpha.13 source preparation did not produce an output file before alpha.14 patching' }

$generatedDir = Split-Path -Parent $OutputPath
$legacyPath = Join-Path $generatedDir 'main.cpp'
$legacy = [System.IO.File]::ReadAllText($legacyPath)

# Preserve the hit gem class so the feedback bloom can match normal/HOPO/tap
# geometry rather than emitting a generic circle.
$hitFieldsOld = @'
    uint8_t lastHitMask = 0;
    bool lastHitOpen = false;
    Clock::time_point lastHitWall{};
'@
$hitFieldsNew = @'
    uint8_t lastHitMask = 0;
    bool lastHitOpen = false;
    bool lastHitHopo = false;
    bool lastHitTap = false;
    Clock::time_point lastHitWall{};
'@
if (-not $legacy.Contains($hitFieldsOld)) { throw 'Could not locate alpha.13 hit-feedback Session fields' }
$legacy = $legacy.Replace($hitFieldsOld, $hitFieldsNew)

$resetOld = 's.lastHitMask = 0; s.lastHitOpen = false; s.lastHitWall = Clock::time_point{};'
$resetNew = 's.lastHitMask = 0; s.lastHitOpen = false; s.lastHitHopo = false; s.lastHitTap = false; s.lastHitWall = Clock::time_point{};'
if (-not $legacy.Contains($resetOld)) { throw 'Could not locate alpha.13 hit-feedback reset' }
$legacy = $legacy.Replace($resetOld, $resetNew)

$markOld = @'
    s.lastHitMask = n.mask;
    s.lastHitOpen = n.open;
    s.lastHitWall = Clock::now();
'@
$markNew = @'
    s.lastHitMask = n.mask;
    s.lastHitOpen = n.open;
    s.lastHitHopo = n.hopo;
    s.lastHitTap = n.tap;
    s.lastHitWall = Clock::now();
'@
if (-not $legacy.Contains($markOld)) { throw 'Could not locate alpha.13 markHit feedback capture' }
$legacy = $legacy.Replace($markOld, $markNew)

[System.IO.File]::WriteAllText($legacyPath, $legacy, [System.Text.UTF8Encoding]::new($false))

$text = [System.IO.File]::ReadAllText($OutputPath)
$text = $text.Replace('v0.1.0-alpha.13', 'v0.1.0-alpha.14')

# Alpha.14 no longer needs projected 2D receptor positions because the hit
# feedback is rendered as the actual 3D gem silhouette.
$text = $text.Replace('    std::array<Vector2, 5> receptorScreenV13{};' + [Environment]::NewLine, '')
$text = $text.Replace('    Vector2 openReceptorScreenV13 = GetWorldToScreen({0.0f, 0.10f, hitZ - 0.12f}, camera);' + [Environment]::NewLine, '')

# Open-note miss animation: retain the bar-shaped note, transition it into red,
# add a small throb, then partially fade as it passes the strike line.
$openGemPattern = '(?ms)        if \(n\.open\) \{\r?\n            Color c = n\.missed \? missColor : RAYWHITE;\r?\n            if \(n\.hit\) c\.a = 70;\r?\n            DrawCube\(\{0\.0f, 0\.09f, z\}, roadWidth \* 0\.78f, 0\.13f, 0\.20f, c\);\r?\n            continue;\r?\n        \}'
$openGemReplacement = @'
        if (n.open) {
            Color c = RAYWHITE;
            float scale = 1.0f;
            if (n.missed) {
                const double missAge = std::max(0.0, now - n.judgedAt);
                const float redMix = static_cast<float>(ggfeedback::missRedBlend(missAge));
                scale = static_cast<float>(ggfeedback::missScale(missAge));
                c = mixColor(RAYWHITE, missColor, redMix);
                c.a = static_cast<unsigned char>(225.0 * ggfeedback::missAlpha(missAge));
            } else if (n.hit) {
                c.a = 70;
            }
            DrawCube({0.0f, 0.09f, z}, roadWidth * 0.78f * scale, 0.13f * scale, 0.20f, c);
            continue;
        }
'@
$updated = [regex]::Replace($text, $openGemPattern, $openGemReplacement, 1)
if ($updated -eq $text) { throw 'Could not replace open-note miss renderer for alpha.14' }
$text = $updated

# Lane-note miss animation. Keep HOPO/tap silhouettes intact while their actual
# gem changes toward red; no separate giant warning sprite is introduced.
$laneGemPattern = '(?ms)        for \(int lane = 0; lane < 5; \+\+lane\) if \(n\.mask & \(1 << lane\)\) \{\r?\n            Color c = n\.missed \? missColor : cfg\.lanes\[lane\];\r?\n            if \(n\.hit\) c\.a = 70;\r?\n            const float radius = laneWidth \* 0\.31f \* ui\.noteScale;\r?\n\r?\n            if \(n\.missed\) \{.*?\r?\n            \} else if \(n\.tap\) \{.*?\r?\n            \} else if \(n\.hopo\) \{.*?\r?\n            \} else \{.*?\r?\n            \}\r?\n        \}'
$laneGemReplacement = @'
        for (int lane = 0; lane < 5; ++lane) if (n.mask & (1 << lane)) {
            Color c = cfg.lanes[lane];
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
                                          : Color{235, 248, 255, 255};
                tapOuter.a = n.missed ? static_cast<unsigned char>(225.0f * missAlpha)
                                      : static_cast<unsigned char>(n.hit ? 75 : 255);
                drawDisc3DV5({laneX(lane), 0.075f, z}, radius * 0.92f, 0.105f, 14, tapOuter);
                drawDisc3DV5({laneX(lane), 0.190f, z}, radius * 0.47f, 0.028f, 14, c);
                DrawCylinderWires({laneX(lane), 0.195f, z}, radius * 0.50f, radius * 0.50f, 0.032f, 14,
                                  n.missed ? alphaColor(missColor, static_cast<unsigned char>(205.0f * missAlpha))
                                           : alphaColor(RAYWHITE, n.hit ? 65 : 235));
            } else if (n.hopo) {
                Color rim = n.missed ? mixColor(Color{225, 235, 245, 255}, missColor, redMix * 0.86f)
                                     : Color{225, 235, 245, 255};
                rim.a = n.missed ? static_cast<unsigned char>(220.0f * missAlpha)
                                 : static_cast<unsigned char>(n.hit ? 65 : 245);
                drawDisc3DV5({laneX(lane), 0.072f, z}, radius * 0.86f, 0.095f, 14, rim);
                drawDisc3DV5({laneX(lane), 0.178f, z}, radius * 0.55f, 0.035f, 14, c);
                DrawCylinderWires({laneX(lane), 0.181f, z}, radius * 0.58f, radius * 0.58f, 0.040f, 14,
                                  n.missed ? alphaColor(missColor, static_cast<unsigned char>(195.0f * missAlpha))
                                           : alphaColor(RAYWHITE, n.hit ? 55 : 215));
            } else {
                drawDisc3DV5({laneX(lane), 0.07f, z}, radius, 0.115f, 12, c);
                Color shine = n.missed ? mixColor(alphaColor(RAYWHITE, 65), missColor, redMix)
                                       : alphaColor(RAYWHITE, n.hit ? 20 : 65);
                if (n.missed) shine.a = static_cast<unsigned char>(100.0f * missAlpha);
                drawDisc3DV5({laneX(lane), 0.188f, z}, radius * 0.18f, 0.018f, 10, shine);
            }
        }
'@
$updated = [regex]::Replace($text, $laneGemPattern, $laneGemReplacement, 1)
if ($updated -eq $text) { throw 'Could not replace lane-note miss renderer for alpha.14' }
$text = $updated

# Replace the alpha.13 receptor/ripple block. The strike bar is now physically
# lower than the receptors, inactive receptors are substantially more opaque,
# and hit feedback is a fading copy of the actual note silhouette.
$feedbackPattern = '(?ms)    Color strike = cfg\.hitLine;.*?^    if \(s\.song\)'
$feedbackReplacement = @'
    Color strike = cfg.hitLine;
    if (now - s.lastJudgmentAt < 0.16) strike = s.lastJudgmentHit ? Color{90, 255, 150, 255} : Color{255, 70, 80, 255};
    if (openSustainHeldV13) strike = mixColor(strike, RAYWHITE, 0.55f);

    // Keep the strike bar below the receptor caps. This prevents the bar from
    // visually washing over inactive fret receptors at shallow camera angles.
    DrawCube({0.0f, 0.040f, hitZ}, roadWidth + 0.22f, openSustainHeldV13 ? 0.060f : 0.045f, 0.10f, strike);

    const bool recentHitV14 = hitAgeV13 >= 0.0 && hitAgeV13 < 0.34;
    const float hitAlphaV14 = recentHitV14 ? static_cast<float>(ggfeedback::hitBloomAlpha(hitAgeV13)) : 0.0f;
    const float hitScaleV14 = recentHitV14 ? static_cast<float>(ggfeedback::hitBloomScale(hitAgeV13)) : 1.0f;
    const float hitProgressV14 = recentHitV14 ? static_cast<float>(ggfeedback::hitBloomProgress(hitAgeV13)) : 1.0f;

    for (int lane = 0; lane < 5; ++lane) {
        const bool laneHit = recentHitV14 && !s.lastHitOpen && (s.lastHitMask & (1 << lane));
        const bool sustainHeld = sustainHeldV13[lane];
        const bool fretHeld = (held & (1 << lane)) != 0;
        Color receptor = cfg.lanes[lane];

        // Inactive receptors remain clearly visible above the strike bar.
        receptor.a = (fretHeld || laneHit || sustainHeld) ? 255 : 158;
        if (laneHit) receptor = mixColor(receptor, RAYWHITE, std::min(0.90f, 0.38f + hitAlphaV14 * 0.58f));
        if (sustainHeld) receptor = mixColor(receptor, RAYWHITE, 0.35f);

        const float x = laneX(lane);
        const float baseRadius = laneWidth * 0.29f * ui.noteScale;
        const float receptorRadius = baseRadius * (1.0f + (laneHit ? 0.16f * hitAlphaV14 : 0.0f) + (sustainHeld ? 0.10f : 0.0f));

        // Dark pedestal gives the colored receptor a stable silhouette even
        // against a bright hit/measure bar.
        drawDisc3DV5({x, 0.083f, hitZ - 0.12f}, baseRadius * 1.08f, 0.060f, 14, alphaColor(BLACK, 165));
        drawDisc3DV5({x, 0.145f, hitZ - 0.12f}, receptorRadius, sustainHeld ? 0.165f : 0.135f, 14, receptor);
        DrawCylinderWires({x, 0.145f, hitZ - 0.12f}, receptorRadius * 1.03f, receptorRadius * 1.03f,
                          sustainHeld ? 0.170f : 0.140f, 14, alphaColor(RAYWHITE, sustainHeld ? 240 : 205));

        if (laneHit) {
            // Render a short-lived ghost of the note itself. Normal notes,
            // HOPOs and taps preserve their authored silhouette.
            const float ghostRadius = baseRadius * hitScaleV14;
            const float ghostY = 0.245f + hitProgressV14 * 0.22f;
            Color ghostColor = mixColor(cfg.lanes[lane], RAYWHITE, 0.55f);
            ghostColor.a = static_cast<unsigned char>(245.0f * hitAlphaV14);

            if (s.lastHitTap) {
                Color outer{240, 250, 255, static_cast<unsigned char>(245.0f * hitAlphaV14)};
                drawDisc3DV5({x, ghostY, hitZ - 0.12f}, ghostRadius * 0.92f, 0.070f, 14, outer);
                drawDisc3DV5({x, ghostY + 0.078f, hitZ - 0.12f}, ghostRadius * 0.47f, 0.025f, 14, ghostColor);
                DrawCylinderWires({x, ghostY + 0.080f, hitZ - 0.12f}, ghostRadius * 0.50f, ghostRadius * 0.50f,
                                  0.030f, 14, alphaColor(RAYWHITE, static_cast<unsigned char>(220.0f * hitAlphaV14)));
            } else if (s.lastHitHopo) {
                Color rim{230, 240, 250, static_cast<unsigned char>(235.0f * hitAlphaV14)};
                drawDisc3DV5({x, ghostY, hitZ - 0.12f}, ghostRadius * 0.86f, 0.065f, 14, rim);
                drawDisc3DV5({x, ghostY + 0.072f, hitZ - 0.12f}, ghostRadius * 0.55f, 0.025f, 14, ghostColor);
                DrawCylinderWires({x, ghostY + 0.074f, hitZ - 0.12f}, ghostRadius * 0.58f, ghostRadius * 0.58f,
                                  0.030f, 14, alphaColor(RAYWHITE, static_cast<unsigned char>(205.0f * hitAlphaV14)));
            } else {
                drawDisc3DV5({x, ghostY, hitZ - 0.12f}, ghostRadius, 0.080f, 14, ghostColor);
                drawDisc3DV5({x, ghostY + 0.084f, hitZ - 0.12f}, ghostRadius * 0.22f, 0.020f, 10,
                             alphaColor(RAYWHITE, static_cast<unsigned char>(205.0f * hitAlphaV14)));
                DrawCylinderWires({x, ghostY, hitZ - 0.12f}, ghostRadius * 1.02f, ghostRadius * 1.02f,
                                  0.085f, 14, alphaColor(RAYWHITE, static_cast<unsigned char>(175.0f * hitAlphaV14)));
            }
        }
    }

    if (recentHitV14 && s.lastHitOpen) {
        // Open-note feedback uses the same wide bar silhouette as the note.
        const float ghostY = 0.235f + hitProgressV14 * 0.20f;
        const float ghostWidth = roadWidth * 0.78f * hitScaleV14;
        Color ghost = mixColor(cfg.hitLine, RAYWHITE, 0.55f);
        ghost.a = static_cast<unsigned char>(235.0f * hitAlphaV14);
        DrawCube({0.0f, ghostY, hitZ - 0.12f}, ghostWidth, 0.095f, 0.20f, ghost);
        DrawCube({0.0f, ghostY + 0.065f, hitZ - 0.12f}, ghostWidth * 0.68f, 0.018f, 0.15f,
                 alphaColor(RAYWHITE, static_cast<unsigned char>(190.0f * hitAlphaV14)));
    }

    EndMode3D();

    if (s.song)
'@
$updated = [regex]::Replace($text, $feedbackPattern, $feedbackReplacement, 1)
if ($updated -eq $text) { throw 'Could not replace alpha.13 receptor/ripple block for alpha.14' }
$text = $updated

[System.IO.File]::WriteAllText($OutputPath, $text, [System.Text.UTF8Encoding]::new($false))
Write-Host "Prepared alpha.14 receptor layering, shaped hits and miss feedback: $OutputPath"
