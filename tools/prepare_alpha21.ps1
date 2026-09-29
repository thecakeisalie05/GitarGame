param(
    [Parameter(Mandatory=$true)][string]$InputPath,
    [Parameter(Mandatory=$true)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$alpha20 = Join-Path $PSScriptRoot 'prepare_alpha20.ps1'
& $alpha20 -InputPath $InputPath -OutputPath $OutputPath
if (-not (Test-Path $OutputPath)) { throw 'alpha.20 source preparation did not produce an output file before alpha.21 patching' }

$text = [System.IO.File]::ReadAllText($OutputPath)
$nl = [Environment]::NewLine
$text = $text.Replace('v0.1.0-alpha.20', 'v0.1.0-alpha.21')

# ---------------------------------------------------------------------------
# Library sorting + held-scroll acceleration.
# ---------------------------------------------------------------------------
$metaMarker = @'
static std::vector<SongUiMeta> buildSongMeta(const std::vector<SongInfo>& songs) {
    std::vector<SongUiMeta> out;
    out.reserve(songs.size());
    for (const auto& song : songs) out.push_back(readSongUiMeta(song));
    return out;
}
'@
$libraryHelpers = @'

enum class LibrarySortV21 {
    Artist,
    Title,
    Album,
    Year,
    Folder
};

static const char* librarySortLabelV21(LibrarySortV21 mode) {
    switch (mode) {
        case LibrarySortV21::Artist: return "Artist";
        case LibrarySortV21::Title: return "Title";
        case LibrarySortV21::Album: return "Album";
        case LibrarySortV21::Year: return "Year";
        case LibrarySortV21::Folder: return "Folder";
        default: return "Artist";
    }
}

static LibrarySortV21 cycleLibrarySortV21(LibrarySortV21 mode, int dir) {
    const int count = 5;
    int value = static_cast<int>(mode);
    value = (value + dir) % count;
    if (value < 0) value += count;
    return static_cast<LibrarySortV21>(value);
}

static void applyLibrarySortV21(std::vector<SongInfo>& songs,
                                std::vector<SongUiMeta>& meta,
                                LibrarySortV21 mode) {
    if (songs.size() != meta.size()) return;
    struct Entry {
        SongInfo song;
        SongUiMeta meta;
    };
    std::vector<Entry> entries;
    entries.reserve(songs.size());
    for (size_t i = 0; i < songs.size(); ++i)
        entries.push_back({std::move(songs[i]), std::move(meta[i])});

    auto key = [mode](const Entry& e) {
        switch (mode) {
            case LibrarySortV21::Artist: return lower(e.song.artist + "\n" + e.song.name);
            case LibrarySortV21::Title: return lower(e.song.name + "\n" + e.song.artist);
            case LibrarySortV21::Album: return lower(e.meta.album + "\n" + e.song.artist + "\n" + e.song.name);
            case LibrarySortV21::Year: return lower(e.meta.year + "\n" + e.song.artist + "\n" + e.song.name);
            case LibrarySortV21::Folder: return lower(pathUtf8(e.song.directory));
            default: return lower(e.song.artist + "\n" + e.song.name);
        }
    };

    std::stable_sort(entries.begin(), entries.end(), [&](const Entry& a, const Entry& b) {
        return key(a) < key(b);
    });

    for (size_t i = 0; i < entries.size(); ++i) {
        songs[i] = std::move(entries[i].song);
        meta[i] = std::move(entries[i].meta);
    }
}

struct SongScrollRepeatV21 {
    int direction = 0;
    double startedAt = 0.0;
    double nextAt = 0.0;

    int update(bool upHeld, bool downHeld) {
        const int wanted = upHeld == downHeld ? 0 : (upHeld ? -1 : 1);
        const double now = GetTime();
        if (wanted == 0) {
            direction = 0;
            return 0;
        }
        if (wanted != direction) {
            direction = wanted;
            startedAt = now;
            nextAt = now + 0.30;
            return 0;
        }
        if (now < nextAt) return 0;

        const double heldFor = now - startedAt;
        const double interval = heldFor > 2.0 ? 0.045 : (heldFor > 1.0 ? 0.075 : 0.115);
        const int step = heldFor > 2.5 ? 3 : (heldFor > 1.4 ? 2 : 1);
        nextAt = now + interval;
        return direction * step;
    }

    void reset() {
        direction = 0;
        startedAt = 0.0;
        nextAt = 0.0;
    }
};
'@
if (-not $text.Contains($metaMarker)) { throw 'Could not locate song metadata builder for alpha.21 library helpers' }
$text = $text.Replace($metaMarker, $metaMarker + $libraryHelpers)

# Add sort label to browser signature/subtitle/footer.
$browserSigOld = @'
static void drawSongBrowser(const std::vector<SongInfo>& songs, const std::vector<SongUiMeta>& meta,
                            int selected, const ArtTexture& art, const Settings& cfg, const UiPrefs& ui,
                            const std::string& status, bool controllerConnected) {
'@
$browserSigNew = @'
static void drawSongBrowser(const std::vector<SongInfo>& songs, const std::vector<SongUiMeta>& meta,
                            int selected, const ArtTexture& art, const Settings& cfg, const UiPrefs& ui,
                            const std::string& status, bool controllerConnected, LibrarySortV21 sortMode) {
'@
if (-not $text.Contains($browserSigOld)) { throw 'Could not locate song browser signature for alpha.21' }
$text = $text.Replace($browserSigOld, $browserSigNew)

$text = $text.Replace(
    '    drawSectionTitle("Songs", TextFormat("%d songs detected", static_cast<int>(songs.size())));',
    '    drawSectionTitle("Songs", TextFormat("%d songs detected   ·   Sort: %s", static_cast<int>(songs.size()), librarySortLabelV21(sortMode)));'
)

$text = $text.Replace(
    'DrawText("Strum: browse   Green: play   Red: main menu   F5: rescan   ·   preview starts after selection settles", 58, GetScreenHeight() - 34, 15, GRAY);',
    'DrawText("Hold Strum/Up/Down: fast browse   Yellow/Blue: sort   Green: play   Red: back   F5: rescan", 58, GetScreenHeight() - 34, 15, GRAY);'
)
$text = $text.Replace(
    'DrawText("Strum/Up/Down: browse   Green/Enter: play   Red/Esc: main menu   F5: rescan", 52, GetScreenHeight() - 55, 15, GRAY);',
    'DrawText("Hold Strum/Up/Down: fast browse   Left/Right: sort   Green/Enter: play   Red/Esc: back   F5: rescan", 52, GetScreenHeight() - 55, 15, GRAY);'
)

# Main runtime state and sort-aware rescan.
$stateOld = 'fs::path songsRoot = resolveSongsRoot(); auto songs = scanSongs(songsRoot); auto songMeta = buildSongMeta(songs); ArtTexture artwork; SongPreviewV13 songPreview; int selectedSong = 0, artworkSong = -1;'
$stateNew = 'fs::path songsRoot = resolveSongsRoot(); auto songs = scanSongs(songsRoot); auto songMeta = buildSongMeta(songs); LibrarySortV21 librarySortV21 = LibrarySortV21::Artist; applyLibrarySortV21(songs, songMeta, librarySortV21); SongScrollRepeatV21 songScrollV21; ArtTexture artwork; SongPreviewV13 songPreview; int selectedSong = 0, artworkSong = -1;'
if (-not $text.Contains($stateOld)) { throw 'Could not locate alpha.20 song browser runtime state for alpha.21' }
$text = $text.Replace($stateOld, $stateNew)

$rescanOld = 'auto rescanLibrary = [&]() { songsRoot = resolveSongsRoot(); songs = scanSongs(songsRoot); songMeta = buildSongMeta(songs); selectedSong = std::clamp(selectedSong, 0, std::max(0, static_cast<int>(songs.size()) - 1)); artworkSong = -1; refreshArtwork(); };'
$rescanNew = 'auto rescanLibrary = [&]() { fs::path keepV21 = (!songs.empty() && selectedSong >= 0 && selectedSong < static_cast<int>(songs.size())) ? songs[static_cast<size_t>(selectedSong)].directory : fs::path{}; songsRoot = resolveSongsRoot(); songs = scanSongs(songsRoot); songMeta = buildSongMeta(songs); applyLibrarySortV21(songs, songMeta, librarySortV21); selectedSong = 0; if (!keepV21.empty()) for (int i = 0; i < static_cast<int>(songs.size()); ++i) if (songs[static_cast<size_t>(i)].directory == keepV21) { selectedSong = i; break; } selectedSong = std::clamp(selectedSong, 0, std::max(0, static_cast<int>(songs.size()) - 1)); artworkSong = -1; refreshArtwork(); };'
if (-not $text.Contains($rescanOld)) { throw 'Could not locate library rescan lambda for alpha.21' }
$text = $text.Replace($rescanOld, $rescanNew)

# Browser navigation: initial press remains immediate; held input repeats after
# a short delay and accelerates. Left/right changes sort mode while preserving
# the currently selected song.
$browserCasePattern = '(?ms)                case AppScreen::SongBrowser:\r?\n.*?                case AppScreen::SettingsCategories:'
$browserCaseReplacement = @'
                case AppScreen::SongBrowser: {
                    if (!songs.empty()) {
                        bool movedV21 = false;
                        if (nav.up) {
                            selectedSong = wrapIndex(selectedSong - 1, static_cast<int>(songs.size()));
                            movedV21 = true;
                        }
                        if (nav.down) {
                            selectedSong = wrapIndex(selectedSong + 1, static_cast<int>(songs.size()));
                            movedV21 = true;
                        }

                        bool upHeldV21 = IsKeyDown(KEY_UP) || IsKeyDown(KEY_W);
                        bool downHeldV21 = IsKeyDown(KEY_DOWN) || IsKeyDown(KEY_S);
#ifdef _WIN32
                        const WORD heldButtonsV21 = poller.buttons();
                        upHeldV21 = upHeldV21 || ((heldButtonsV21 & cfg.strumUp) != 0);
                        downHeldV21 = downHeldV21 || ((heldButtonsV21 & cfg.strumDown) != 0);
#endif
                        const int repeatV21 = songScrollV21.update(upHeldV21, downHeldV21);
                        if (repeatV21 != 0) {
                            selectedSong = wrapIndex(selectedSong + repeatV21, static_cast<int>(songs.size()));
                            movedV21 = true;
                        }
                        if (movedV21) {
                            artworkSong = -1;
                            refreshArtwork();
                        }

                        const int sortDirV21 = nav.left ? -1 : (nav.right ? 1 : 0);
                        if (sortDirV21 != 0) {
                            const fs::path keepV21 = songs[static_cast<size_t>(selectedSong)].directory;
                            librarySortV21 = cycleLibrarySortV21(librarySortV21, sortDirV21);
                            applyLibrarySortV21(songs, songMeta, librarySortV21);
                            for (int i = 0; i < static_cast<int>(songs.size()); ++i) {
                                if (songs[static_cast<size_t>(i)].directory == keepV21) {
                                    selectedSong = i;
                                    break;
                                }
                            }
                            artworkSong = -1;
                            refreshArtwork();
                            status = std::string("Sorted by ") + librarySortLabelV21(librarySortV21) + ".";
                        }
                    } else {
                        songScrollV21.reset();
                    }

                    if (IsKeyPressed(KEY_F5)) {
                        rescanLibrary();
                        status = "Song library rescanned.";
                    }
                    if ((nav.accept || nav.start) && !songs.empty()) {
                        songPreview.clearRequest();
                        const auto& chosenV19 = songs[static_cast<size_t>(selectedSong)];
                        if (needsFullOpusPreparationV19(chosenV19.directory) && !fullOpusPreparationFinishedV19(chosenV19.directory)) {
                            pendingSongV19 = selectedSong;
                            audioPrepV19.request(chosenV19.directory);
                            status = "Loading audio...";
                        } else if (loadSongV7(session, chosenV19)) {
                            activateSongTiming();
                            screen = AppScreen::Playing;
                            status.clear();
                        } else {
                            status = session.error;
                        }
                    }
                    if (nav.back) {
                        songScrollV21.reset();
                        screen = AppScreen::MainMenu;
                        status.clear();
                    }
                    break;
                }
                case AppScreen::SettingsCategories:
'@
$updated = [regex]::Replace($text, $browserCasePattern, $browserCaseReplacement, 1)
if ($updated -eq $text) { throw 'Could not replace song browser navigation for alpha.21' }
$text = $updated

# Route draw call through sort label.
$text = $text.Replace(
    'case AppScreen::SongBrowser: drawSongBrowser(songs, songMeta, selectedSong, artwork, cfg, ui, status, controllerConnected); break;',
    'case AppScreen::SongBrowser: drawSongBrowser(songs, songMeta, selectedSong, artwork, cfg, ui, status, controllerConnected, librarySortV21); break;'
)

# ---------------------------------------------------------------------------
# Color and animation in menus.
# ---------------------------------------------------------------------------
$menuListPattern = '(?ms)^static void drawMenuList\(const std::vector<std::string>& items, int selected, float x, float y, float width, float rowH\) \{.*?^\}\r?\n'
$menuListReplacement = @'
static void drawMenuList(const std::vector<std::string>& items, int selected, float x, float y, float width, float rowH) {
    const float timeV21 = static_cast<float>(GetTime());
    for (int i = 0; i < static_cast<int>(items.size()); ++i) {
        Rectangle row{x, y + rowH * i, width, rowH - 8.0f};
        const float hueV21 = std::fmod(timeV21 * 22.0f + static_cast<float>(i) * 58.0f, 360.0f);
        const Color accentV21 = ColorFromHSV(hueV21, 0.72f, 1.0f);
        if (i == selected) {
            const float pulseV21 = 0.5f + 0.5f * std::sin(timeV21 * 5.5f);
            DrawRectangleRounded(row, 0.12f, 8, alphaColor(accentV21, static_cast<unsigned char>(38 + pulseV21 * 25)));
            DrawRectangleLinesEx(row, 2.0f, alphaColor(accentV21, static_cast<unsigned char>(150 + pulseV21 * 80)));
            DrawRectangle(static_cast<int>(row.x), static_cast<int>(row.y + 7.0f), 5,
                          static_cast<int>(row.height - 14.0f), accentV21);
        }
        DrawText(items[i].c_str(), static_cast<int>(x + 22), static_cast<int>(row.y + 14), 24,
                 i == selected ? RAYWHITE : LIGHTGRAY);
    }
}
'@
$updated = [regex]::Replace($text, $menuListPattern, $menuListReplacement, 1)
if ($updated -eq $text) { throw 'Could not replace menu list renderer for alpha.21' }
$text = $updated

# Add moving colored background streaks to the main menu.
$mainMenuMarker = @'
    const int sw = GetScreenWidth();
    const int sh = GetScreenHeight();

    for (int i = 0; i < 5; ++i) {
'@
$mainMenuReplacement = @'
    const int sw = GetScreenWidth();
    const int sh = GetScreenHeight();
    const float menuTimeV21 = static_cast<float>(GetTime());

    for (int i = 0; i < 9; ++i) {
        const float phaseV21 = std::fmod(menuTimeV21 * (28.0f + i * 2.5f) + i * 137.0f,
                                         static_cast<float>(sw + 500));
        const float xV21 = phaseV21 - 250.0f;
        const Color streakV21 = ColorFromHSV(std::fmod(menuTimeV21 * 18.0f + i * 43.0f, 360.0f), 0.75f, 1.0f);
        DrawLineEx({xV21, 0.0f}, {xV21 + 280.0f, static_cast<float>(sh)},
                   2.0f + static_cast<float>(i % 3), alphaColor(streakV21, 24));
    }

    for (int i = 0; i < 5; ++i) {
'@
if (-not $text.Contains($mainMenuMarker)) { throw 'Could not locate main menu background for alpha.21 animation' }
$text = $text.Replace($mainMenuMarker, $mainMenuReplacement)

# Animate selected song row color instead of a static green strip.
$songSelectedOld = 'if (i == selected) { DrawRectangleRounded(r, 0.08f, 6, alphaColor(RAYWHITE, 23)); DrawRectangle(static_cast<int>(r.x), static_cast<int>(r.y), 5, static_cast<int>(r.height), cfg.lanes[0]); }'
$songSelectedNew = 'if (i == selected) { const float pulseV21 = 0.5f + 0.5f * std::sin(static_cast<float>(GetTime()) * 5.0f); const Color accentV21 = ColorFromHSV(std::fmod(static_cast<float>(GetTime()) * 26.0f, 360.0f), 0.68f, 1.0f); DrawRectangleRounded(r, 0.08f, 6, alphaColor(accentV21, static_cast<unsigned char>(24 + pulseV21 * 20))); DrawRectangleLinesEx(r, 1.5f, alphaColor(accentV21, static_cast<unsigned char>(110 + pulseV21 * 90))); DrawRectangle(static_cast<int>(r.x), static_cast<int>(r.y), 5, static_cast<int>(r.height), accentV21); }'
if (-not $text.Contains($songSelectedOld)) { throw 'Could not locate selected song row for alpha.21 animation' }
$text = $text.Replace($songSelectedOld, $songSelectedNew)

# ---------------------------------------------------------------------------
# Visible hit flash / glow.
#
# This is intentionally a geometry-based glow rather than full-screen
# post-processing bloom. Multiple translucent/additive layers make the note
# visibly emit light at impact without requiring HDR render targets.
# ---------------------------------------------------------------------------
$impactOld = @'
            const float impactProgressV20 = std::clamp(static_cast<float>(hitAgeV13 / 0.24), 0.0f, 1.0f);
            const float impactAlphaV20 = 1.0f - impactProgressV20;
            const float impactRadiusV20 = baseRadius * (1.15f + impactProgressV20 * 1.55f);
            DrawCylinderWires({x, 0.170f, hitZ - 0.12f}, impactRadiusV20, impactRadiusV20, 0.028f, 20,
                              alphaColor(RAYWHITE, static_cast<unsigned char>(235.0f * impactAlphaV20)));

            // Render a short-lived ghost of the note itself. Normal notes,
'@
$impactNew = @'
            const float impactProgressV20 = std::clamp(static_cast<float>(hitAgeV13 / 0.24), 0.0f, 1.0f);
            const float impactAlphaV20 = 1.0f - impactProgressV20;
            const float impactRadiusV20 = baseRadius * (1.15f + impactProgressV20 * 1.55f);
            DrawCylinderWires({x, 0.170f, hitZ - 0.12f}, impactRadiusV20, impactRadiusV20, 0.028f, 20,
                              alphaColor(RAYWHITE, static_cast<unsigned char>(235.0f * impactAlphaV20)));

            // Alpha.21 light burst: concentric translucent lane-colored discs
            // plus a white-hot core. This reads as a flash rather than only a
            // geometry change and is significantly cheaper than post-process bloom.
            const float flashV21 = std::clamp(1.0f - static_cast<float>(hitAgeV13 / 0.15), 0.0f, 1.0f);
            if (flashV21 > 0.0f) {
                Color laneFlashV21 = mixColor(cfg.lanes[lane], RAYWHITE, 0.25f);
                drawDisc3DV5({x, 0.115f, hitZ - 0.12f}, baseRadius * (1.95f + 0.55f * (1.0f - flashV21)),
                             0.030f, 24, alphaColor(laneFlashV21, static_cast<unsigned char>(55.0f * flashV21)));
                drawDisc3DV5({x, 0.145f, hitZ - 0.12f}, baseRadius * (1.45f + 0.35f * (1.0f - flashV21)),
                             0.040f, 22, alphaColor(laneFlashV21, static_cast<unsigned char>(105.0f * flashV21)));
                drawDisc3DV5({x, 0.205f, hitZ - 0.12f}, baseRadius * 0.72f,
                             0.055f, 18, alphaColor(RAYWHITE, static_cast<unsigned char>(245.0f * flashV21)));
            }

            // Render a short-lived ghost of the note itself. Normal notes,
'@
if (-not $text.Contains($impactOld)) { throw 'Could not locate alpha.20 hit impact for alpha.21 flash' }
$text = $text.Replace($impactOld, $impactNew)

# Open-note hit gets a whole-strike-line white flash too.
$openFeedbackMarker = '    if (recentHitV14 && s.lastHitOpen) {'
$openFeedbackAdd = @'
    if (recentHitV14 && s.lastHitOpen && hitAgeV13 < 0.15) {
        const float openFlashV21 = std::clamp(1.0f - static_cast<float>(hitAgeV13 / 0.15), 0.0f, 1.0f);
        DrawCube({0.0f, 0.125f, hitZ - 0.12f}, roadWidth * (0.92f + 0.10f * (1.0f - openFlashV21)),
                 0.060f, 0.26f, alphaColor(RAYWHITE, static_cast<unsigned char>(210.0f * openFlashV21)));
    }

    if (recentHitV14 && s.lastHitOpen) {
'@
if (-not $text.Contains($openFeedbackMarker)) { throw 'Could not locate open hit feedback for alpha.21 flash' }
$text = $text.Replace($openFeedbackMarker, $openFeedbackAdd.TrimEnd())

[System.IO.File]::WriteAllText($OutputPath, $text, [System.Text.UTF8Encoding]::new($false))
Write-Host "Prepared alpha.21 held library scrolling, sorting, animated menus and visible hit flashes: $OutputPath"
