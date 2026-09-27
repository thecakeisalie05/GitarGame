param(
    [Parameter(Mandatory=$true)][string]$InputPath,
    [Parameter(Mandatory=$true)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$alpha12 = Join-Path $PSScriptRoot 'prepare_alpha12.ps1'
& $alpha12 -InputPath $InputPath -OutputPath $OutputPath
if (-not (Test-Path $OutputPath)) { throw 'alpha.12 source preparation did not produce an output file before alpha.13 patching' }

$generatedDir = Split-Path -Parent $OutputPath
$legacyPath = Join-Path $generatedDir 'main.cpp'
$legacy = [System.IO.File]::ReadAllText($legacyPath)

# ---------------------------------------------------------------------------
# Gameplay event state used by receptor flashes/ripples. Store realtime hit age
# separately from chart time so video calibration never shifts effect timing.
# ---------------------------------------------------------------------------
$sessionField = '    bool lastJudgmentOverstrum = false;'
$sessionFields = @'
    bool lastJudgmentOverstrum = false;
    uint8_t lastHitMask = 0;
    bool lastHitOpen = false;
    Clock::time_point lastHitWall{};
'@
if (-not $legacy.Contains($sessionField)) { throw 'Could not locate Session judgment fields for alpha.13' }
$legacy = $legacy.Replace($sessionField, $sessionFields.TrimEnd())

$resetOld = '    s.lastGameplayUpdate = -1.0; s.lastJudgmentAt = -1000.0; s.lastJudgmentErrorMs = 0.0; s.lastJudgmentHit = false; s.lastJudgmentOverstrum = false;'
$resetNew = $resetOld + ' s.lastHitMask = 0; s.lastHitOpen = false; s.lastHitWall = Clock::time_point{};'
if (-not $legacy.Contains($resetOld)) { throw 'Could not locate resetChartState judgment reset for alpha.13' }
$legacy = $legacy.Replace($resetOld, $resetNew)

$markPattern = '(?ms)^static void markHit\(Session& s, Note& n, double now, double hitErrorMs\) \{.*?^}\r?\n'
$markMatch = [regex]::Match($legacy, $markPattern)
if (-not $markMatch.Success) { throw 'Could not locate markHit for alpha.13' }
$markText = $markMatch.Value
$markTextNew = $markText.Replace(
    '    s.lastJudgmentOverstrum = false;',
    '    s.lastJudgmentOverstrum = false;' + [Environment]::NewLine +
    '    s.lastHitMask = n.mask;' + [Environment]::NewLine +
    '    s.lastHitOpen = n.open;' + [Environment]::NewLine +
    '    s.lastHitWall = Clock::now();'
)
if ($markTextNew -eq $markText) { throw 'Could not add hit feedback state to markHit' }
$legacy = $legacy.Replace($markText, $markTextNew)

[System.IO.File]::WriteAllText($legacyPath, $legacy, [System.Text.UTF8Encoding]::new($false))

# ---------------------------------------------------------------------------
# UI shell: preview metadata/player, richer highway feedback, completion flow.
# ---------------------------------------------------------------------------
$text = [System.IO.File]::ReadAllText($OutputPath)
$text = $text.Replace('v0.1.0-alpha.12', 'v0.1.0-alpha.13')
$text = $text.Replace('#include "calibration_engine.h"', '#include "calibration_engine.h"' + [Environment]::NewLine + '#include "gameplay_feedback.h"')

# Preview metadata follows the common song.ini millisecond fields.
$text = $text.Replace(
@'
struct SongUiMeta {
    std::string album;
    std::string genre;
    std::string year;
    std::string charter;
    fs::path artPath;
};
'@,
@'
struct SongUiMeta {
    std::string album;
    std::string genre;
    std::string year;
    std::string charter;
    double previewStartMs = -1.0;
    double previewEndMs = -1.0;
    fs::path artPath;
};
'@
)

$metaParseOld = @'
        else if (key == "year") meta.year = value;
        else if (key == "charter" || key == "frets") meta.charter = value;
'@
$metaParseNew = @'
        else if (key == "year") meta.year = value;
        else if (key == "charter" || key == "frets") meta.charter = value;
        else if (key == "preview_start_time") { try { meta.previewStartMs = std::stod(value); } catch (...) {} }
        else if (key == "preview_end_time") { try { meta.previewEndMs = std::stod(value); } catch (...) {} }
'@
if (-not $text.Contains($metaParseOld)) { throw 'Could not locate SongUiMeta parser for preview metadata' }
$text = $text.Replace($metaParseOld, $metaParseNew)

# Preview transport: debounce rapid scrolling, prefer preview.* files, including
# native preview.opus decoding, and otherwise use a short full-stem segment.
$artMarker = 'struct ArtTexture {'
$previewCode = @'
static std::vector<Stem> loadPreviewStemsV13(const fs::path& dir, bool& dedicatedPreview) {
    dedicatedPreview = false;
    std::error_code ec;
    static const std::array<const char*, 6> names = {
        "preview.ogg", "preview.mp3", "preview.wav", "preview.flac", "preview.opus", "preview.wave"
    };

    for (const char* name : names) {
        const fs::path path = dir / name;
        if (!fs::is_regular_file(path, ec)) { ec.clear(); continue; }
        dedicatedPreview = true;
        if (lower(path.extension().string()) == ".opus") {
            std::string error;
            auto decoded = opusmix::decodeFile(path, error);
            if (!decoded) {
#ifdef _WIN32
                ggdiag::log("Preview Opus decode failed: " + error);
#endif
                continue;
            }
            auto backing = std::make_shared<std::vector<unsigned char>>(std::move(decoded->wavBytes));
            if (backing->size() > static_cast<size_t>(std::numeric_limits<int>::max())) continue;
            Music music = LoadMusicStreamFromMemory(".wav", backing->data(), static_cast<int>(backing->size()));
            if (music.ctxData != nullptr) return {{music, path, backing}};
        } else {
            const std::string utf8 = pathUtf8(path);
            Music music = LoadMusicStream(utf8.c_str());
            if (music.ctxData != nullptr) return {{music, path, {}}};
        }
    }

    dedicatedPreview = false;
    return loadStems(dir);
}

struct SongPreviewV13 {
    std::vector<Stem> stems;
    int activeSong = -1;
    int requestedSong = -1;
    Clock::time_point requestedAt{};
    double startSeconds = 0.0;
    double endSeconds = 0.0;
    bool dedicated = false;

    void stop() {
        if (!stems.empty()) unloadStems(stems);
        stems.clear();
        activeSong = -1;
        startSeconds = 0.0;
        endSeconds = 0.0;
        dedicated = false;
    }

    void request(int songIndex) {
        if (songIndex == requestedSong) return;
        requestedSong = songIndex;
        requestedAt = Clock::now();
        stop();
    }

    void clearRequest() {
        requestedSong = -1;
        stop();
    }

    bool activeFor(int songIndex) const {
        return activeSong == songIndex && !stems.empty();
    }

    void startRequested(const std::vector<SongInfo>& songs, const std::vector<SongUiMeta>& meta) {
        if (requestedSong < 0 || requestedSong >= static_cast<int>(songs.size())) return;
        bool usedDedicated = false;
        auto loaded = loadPreviewStemsV13(songs[requestedSong].directory, usedDedicated);
        if (loaded.empty()) return;

        const double length = static_cast<double>(GetMusicTimeLength(loaded.front().music));
        const auto& songMeta = meta[static_cast<size_t>(requestedSong)];
        startSeconds = usedDedicated ? 0.0 : ggfeedback::previewStartSeconds(songMeta.previewStartMs, length);
        endSeconds = usedDedicated ? std::min(length, 20.0)
                                   : ggfeedback::previewEndSeconds(songMeta.previewEndMs, startSeconds, length);
        if (endSeconds <= startSeconds + 0.5) endSeconds = std::min(length, startSeconds + 12.0);

        stems = std::move(loaded);
        dedicated = usedDedicated;
        activeSong = requestedSong;
        for (auto& stem : stems) {
            SeekMusicStream(stem.music, static_cast<float>(startSeconds));
            SetMusicVolume(stem.music, 0.58f);
            PlayMusicStream(stem.music);
        }
#ifdef _WIN32
        ggdiag::log("Song preview started: " + songs[activeSong].name +
                    " dedicated=" + std::string(dedicated ? "yes" : "no") +
                    " start_s=" + std::to_string(startSeconds) +
                    " end_s=" + std::to_string(endSeconds));
#endif
    }

    void update(const std::vector<SongInfo>& songs, const std::vector<SongUiMeta>& meta) {
        if (requestedSong < 0 || requestedSong >= static_cast<int>(songs.size())) {
            stop();
            return;
        }

        if (activeSong != requestedSong) {
            if (Clock::now() - requestedAt >= std::chrono::milliseconds(450))
                startRequested(songs, meta);
            return;
        }

        if (stems.empty()) return;
        for (auto& stem : stems) UpdateMusicStream(stem.music);
        const double played = static_cast<double>(GetMusicTimePlayed(stems.front().music));
        if (played >= endSeconds - 0.03) {
            for (auto& stem : stems) {
                SeekMusicStream(stem.music, static_cast<float>(startSeconds));
                PlayMusicStream(stem.music);
            }
        }
    }
};

'@
if (-not $text.Contains($artMarker)) { throw 'Could not locate ArtTexture marker for song preview code' }
$text = $text.Replace($artMarker, $previewCode + $artMarker)

# ---------------------------------------------------------------------------
# Highway feedback: active sustain glow, hit receptor flash and 2D ripple.
# ---------------------------------------------------------------------------
$laneMarker = '    auto laneX = [&](int lane) { return right - laneWidth * (static_cast<float>(lane) + 0.5f); };'
$laneReplacement = @'
    auto laneX = [&](int lane) { return right - laneWidth * (static_cast<float>(lane) + 0.5f); };
    bool sustainHeldV13[5] = {false, false, false, false, false};
    bool openSustainHeldV13 = false;
    std::array<Vector2, 5> receptorScreenV13{};
    Vector2 openReceptorScreenV13 = GetWorldToScreen({0.0f, 0.10f, hitZ - 0.12f}, camera);
    double hitAgeV13 = 999.0;
    if (s.lastHitWall.time_since_epoch().count() != 0)
        hitAgeV13 = std::chrono::duration<double>(Clock::now() - s.lastHitWall).count();
'@
if (-not $text.Contains($laneMarker)) { throw 'Could not locate laneX marker for feedback state' }
$text = $text.Replace($laneMarker, $laneReplacement)

$openTailOld = @'
            const float startZ = std::max(nearZ, z0), endZ = std::min(farZ, z1);
            if (endZ > startZ) DrawCube({0.0f, 0.052f, (startZ + endZ) * 0.5f}, roadWidth * 0.70f, 0.035f, endZ - startZ, n.missed ? missColor : alphaColor(RAYWHITE, n.hit ? 55 : 145));
            continue;
'@
$openTailNew = @'
            float startZ = std::max(nearZ, z0);
            const float endZ = std::min(farZ, z1);
            const bool holding = ggfeedback::sustainHolding(n.hit, n.time, n.sustain, now, held == 0);
            if (n.hit) startZ = std::max(startZ, hitZ);
            openSustainHeldV13 = openSustainHeldV13 || holding;
            if (endZ > startZ) {
                const Color body = n.missed ? missColor : alphaColor(RAYWHITE, holding ? 225 : (n.hit ? 85 : 145));
                DrawCube({0.0f, 0.052f, (startZ + endZ) * 0.5f}, roadWidth * (holding ? 0.78f : 0.70f), holding ? 0.060f : 0.035f, endZ - startZ, body);
                if (holding) DrawCube({0.0f, 0.090f, (startZ + endZ) * 0.5f}, roadWidth * 0.54f, 0.018f, endZ - startZ, alphaColor(RAYWHITE, 150));
            }
            continue;
'@
if (-not $text.Contains($openTailOld)) { throw 'Could not locate open sustain renderer for alpha.13' }
$text = $text.Replace($openTailOld, $openTailNew)

$laneTailOld = @'
            const float startZ = std::max(nearZ, z0), endZ = std::min(farZ, z1);
            if (endZ <= startZ) continue;
            Color c = n.missed ? missColor : cfg.lanes[lane];
            c.a = static_cast<unsigned char>(n.missed ? 165 : (n.hit ? 60 : 165));
            DrawCube({laneX(lane), 0.055f, (startZ + endZ) * 0.5f}, laneWidth * 0.16f * ui.noteScale, 0.045f, std::max(0.02f, endZ - startZ), c);
'@
$laneTailNew = @'
            float startZ = std::max(nearZ, z0);
            const float endZ = std::min(farZ, z1);
            if (endZ <= startZ) continue;
            const bool heldCorrect = heldMatches(held, n.mask);
            const bool holding = ggfeedback::sustainHolding(n.hit, n.time, laneSustain, now, heldCorrect);
            if (n.hit) startZ = std::max(startZ, hitZ);
            sustainHeldV13[lane] = sustainHeldV13[lane] || holding;
            Color c = n.missed ? missColor : cfg.lanes[lane];
            c.a = static_cast<unsigned char>(n.missed ? 165 : (holding ? 245 : (n.hit ? 90 : 165)));
            const float width = laneWidth * (holding ? 0.27f : 0.16f) * ui.noteScale;
            const float height = holding ? 0.075f : 0.045f;
            DrawCube({laneX(lane), 0.055f, (startZ + endZ) * 0.5f}, width, height, std::max(0.02f, endZ - startZ), c);
            if (holding) {
                const float pulse = 0.65f + 0.35f * std::sin(static_cast<float>(GetTime()) * 10.0f + lane);
                DrawCube({laneX(lane), 0.102f, (startZ + endZ) * 0.5f}, laneWidth * 0.065f * ui.noteScale,
                         0.020f, std::max(0.02f, endZ - startZ), alphaColor(RAYWHITE, static_cast<unsigned char>(105 + 95 * pulse)));
            }
'@
if (-not $text.Contains($laneTailOld)) { throw 'Could not locate lane sustain renderer for alpha.13' }
$text = $text.Replace($laneTailOld, $laneTailNew)

$receptorPattern = '(?ms)    Color strike = cfg\.hitLine;.*?    EndMode3D\(\);'
$receptorReplacement = @'
    Color strike = cfg.hitLine;
    if (now - s.lastJudgmentAt < 0.16) strike = s.lastJudgmentHit ? Color{90, 255, 150, 255} : Color{255, 70, 80, 255};
    if (openSustainHeldV13) strike = mixColor(strike, RAYWHITE, 0.55f);
    DrawCube({0.0f, 0.075f, hitZ}, roadWidth + 0.22f, openSustainHeldV13 ? 0.090f : 0.065f, 0.10f, strike);

    const bool recentHitV13 = hitAgeV13 >= 0.0 && hitAgeV13 < 0.42;
    const float rippleStrengthV13 = recentHitV13 ? static_cast<float>(ggfeedback::rippleStrength(hitAgeV13)) : 0.0f;
    for (int lane = 0; lane < 5; ++lane) {
        const bool laneHit = recentHitV13 && !s.lastHitOpen && (s.lastHitMask & (1 << lane));
        const bool sustainHeld = sustainHeldV13[lane];
        Color receptor = cfg.lanes[lane];
        const bool emphasized = (held & (1 << lane)) || laneHit || sustainHeld;
        receptor.a = emphasized ? 255 : 75;
        if (laneHit) receptor = mixColor(receptor, RAYWHITE, std::min(0.85f, 0.30f + rippleStrengthV13 * 0.75f));
        if (sustainHeld) receptor = mixColor(receptor, RAYWHITE, 0.35f);

        const float x = laneX(lane);
        const float baseRadius = laneWidth * 0.29f * ui.noteScale;
        const float radius = baseRadius * (1.0f + (laneHit ? rippleStrengthV13 * 0.23f : 0.0f) + (sustainHeld ? 0.10f : 0.0f));
        drawDisc3DV5({x, 0.10f, hitZ - 0.12f}, radius, sustainHeld ? 0.16f : 0.12f, 14, receptor);
        if (laneHit) {
            drawDisc3DV5({x, 0.245f, hitZ - 0.12f}, baseRadius * (0.38f + 0.20f * rippleStrengthV13),
                         0.025f, 14, alphaColor(RAYWHITE, static_cast<unsigned char>(100 + 155 * rippleStrengthV13)));
        }
        DrawCylinderWires({x, 0.10f, hitZ - 0.12f}, radius * 1.03f, radius * 1.03f, sustainHeld ? 0.165f : 0.125f, 14,
                          alphaColor(RAYWHITE, sustainHeld ? 235 : 155));
        receptorScreenV13[lane] = GetWorldToScreen({x, 0.10f, hitZ - 0.12f}, camera);
    }
    EndMode3D();

    // Agentic-Studio-inspired hit ripple: quick bright core followed by two
    // expanding, fading rings. This is deliberately 2D after projection so the
    // ring stays visually circular instead of becoming a perspective ellipse.
    if (recentHitV13) {
        const float progress = static_cast<float>(ggfeedback::rippleProgress(hitAgeV13));
        const unsigned char alpha = static_cast<unsigned char>(210.0f * (1.0f - progress) * (1.0f - progress));
        auto drawRipple = [&](Vector2 center, Color color, float phase) {
            const float p = std::clamp(progress - phase, 0.0f, 1.0f);
            if (progress < phase) return;
            const float radius = 16.0f + p * 72.0f;
            Color ring = mixColor(color, RAYWHITE, 0.48f);
            ring.a = static_cast<unsigned char>(alpha * (1.0f - phase * 0.45f));
            DrawRing(center, std::max(0.0f, radius - 2.3f), radius + 2.3f, 0.0f, 360.0f, 36, ring);
        };

        if (s.lastHitOpen) {
            for (int lane = 0; lane < 5; ++lane) {
                drawRipple(receptorScreenV13[lane], cfg.hitLine, 0.0f);
                drawRipple(receptorScreenV13[lane], cfg.hitLine, 0.18f);
            }
            DrawCircleV(openReceptorScreenV13, 8.0f + 14.0f * rippleStrengthV13, alphaColor(RAYWHITE, alpha));
        } else {
            for (int lane = 0; lane < 5; ++lane) if (s.lastHitMask & (1 << lane)) {
                drawRipple(receptorScreenV13[lane], cfg.lanes[lane], 0.0f);
                drawRipple(receptorScreenV13[lane], cfg.lanes[lane], 0.16f);
            }
        }
    }
'@
$updated = [regex]::Replace($text, $receptorPattern, $receptorReplacement, 1)
if ($updated -eq $text) { throw 'Could not replace receptor renderer for alpha.13 feedback' }
$text = $updated

# ---------------------------------------------------------------------------
# Main-loop song preview + automatic song-complete return.
# ---------------------------------------------------------------------------
$libraryMarker = 'ArtTexture artwork; int selectedSong = 0, artworkSong = -1;'
if (-not $text.Contains($libraryMarker)) { throw 'Could not locate song browser state for preview player' }
$text = $text.Replace($libraryMarker, 'ArtTexture artwork; SongPreviewV13 songPreview; int selectedSong = 0, artworkSong = -1;')

$loopMarker = '        if (!binding && !showHelp) {'
$previewLoop = @'
        if (screen == AppScreen::SongBrowser && !binding && !showHelp) {
            if (!songs.empty()) {
                songPreview.request(selectedSong);
                songPreview.update(songs, songMeta);
            } else {
                songPreview.clearRequest();
            }
        } else if (songPreview.activeSong >= 0 || songPreview.requestedSong >= 0) {
            songPreview.clearRequest();
        }

        if (!binding && !showHelp) {
'@
if (-not $text.Contains($loopMarker)) { throw 'Could not locate main switch loop for preview update' }
$text = $text.Replace($loopMarker, $previewLoop.TrimEnd())

$browserLoadOld = 'if ((nav.accept || nav.start) && !songs.empty()) { if (loadSong(session, songs[selectedSong]))'
$browserLoadNew = 'if ((nav.accept || nav.start) && !songs.empty()) { songPreview.clearRequest(); if (loadSong(session, songs[selectedSong]))'
if (-not $text.Contains($browserLoadOld)) { throw 'Could not locate browser Play action for preview stop' }
$text = $text.Replace($browserLoadOld, $browserLoadNew)

$playingStartOld = '                    for (auto& stem : session.stems) UpdateMusicStream(stem.music); const double now = correctedSongTimeV5(session, cfg, activeChartOffset), window = cfg.hitWindowMs / 1000.0; advanceMisses(session, now, window); bool pauseRequested = IsKeyPressed(KEY_ESCAPE);'
$playingStartNew = @'
                    for (auto& stem : session.stems) UpdateMusicStream(stem.music);
                    if (!session.stems.empty()) {
                        const double rawPlayed = static_cast<double>(GetMusicTimePlayed(session.stems.front().music));
                        const double rawLength = static_cast<double>(GetMusicTimeLength(session.stems.front().music));
                        if (ggfeedback::songFinished(rawPlayed, rawLength)) {
                            stopSongToBrowser();
                            status = "Song complete.";
                            break;
                        }
                    }
                    const double now = correctedSongTimeV5(session, cfg, activeChartOffset), window = cfg.hitWindowMs / 1000.0;
                    advanceMisses(session, now, window);
                    bool pauseRequested = IsKeyPressed(KEY_ESCAPE);
'@
if (-not $text.Contains($playingStartOld)) { throw 'Could not locate Playing update start for completion return' }
$text = $text.Replace($playingStartOld, $playingStartNew.TrimEnd())

# Display preview state in the browser without changing its layout contract.
$browserFooter = '    DrawText("Strum: browse   Green: play   Red: main menu   F5: rescan", 58, GetScreenHeight() - 34, 15, GRAY);'
if ($text.Contains($browserFooter)) {
    $browserFooterNew = '    DrawText("Strum: browse   Green: play   Red: main menu   F5: rescan   ·   preview starts after selection settles", 58, GetScreenHeight() - 34, 15, GRAY);'
    $text = $text.Replace($browserFooter, $browserFooterNew)
}

$shutdownOld = '    artwork.clear(); unloadStems(session.stems);'
$shutdownNew = '    songPreview.clearRequest(); artwork.clear(); unloadStems(session.stems);'
if (-not $text.Contains($shutdownOld)) { throw 'Could not locate shutdown cleanup for preview player' }
$text = $text.Replace($shutdownOld, $shutdownNew)

[System.IO.File]::WriteAllText($OutputPath, $text, [System.Text.UTF8Encoding]::new($false))
Write-Host "Prepared alpha.13 gameplay feedback, song previews and completion flow: $OutputPath"
