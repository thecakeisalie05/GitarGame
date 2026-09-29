param(
    [Parameter(Mandatory=$true)][string]$InputPath,
    [Parameter(Mandatory=$true)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$alpha18 = Join-Path $PSScriptRoot 'prepare_alpha18.ps1'
& $alpha18 -InputPath $InputPath -OutputPath $OutputPath
if (-not (Test-Path $OutputPath)) { throw 'alpha.18 source preparation did not produce an output file before alpha.19 patching' }

$generatedDir = Split-Path -Parent $OutputPath
$legacyPath = Join-Path $generatedDir 'main.cpp'
$legacy = [System.IO.File]::ReadAllText($legacyPath)
$nl = [Environment]::NewLine

# ---------------------------------------------------------------------------
# Highway length: keep the control, but make it meaningfully adjustable.
# ---------------------------------------------------------------------------
$legacy = $legacy.Replace(
    'else if (key == "highway_length") s.highwayLength = clampFloat(std::stof(value), 0.35f, 0.95f);',
    'else if (key == "highway_length") s.highwayLength = clampFloat(std::stof(value), 0.30f, 1.40f);'
)

# ---------------------------------------------------------------------------
# Async Opus preparation cache.
#
# Opus decoding/mixing is CPU-heavy. Alpha.13 performed it synchronously from
# the preview update path and loadSong(), which blocks the window message/render
# loop. Alpha.19 prepares the expensive PCM WAV bytes on a worker thread and
# only creates raylib Music objects on the main thread.
# ---------------------------------------------------------------------------
$loadMarker = 'static std::vector<Stem> loadStems(const fs::path& dir) {'
if (-not $legacy.Contains($loadMarker)) { throw 'Could not locate loadStems for alpha.19 async audio cache' }

$cacheCode = @'
struct PreparedOpusCacheV19 {
    bool fullAttempted = false;
    bool previewAttempted = false;
    fs::path fullPath;
    fs::path previewPath;
};

static std::mutex preparedOpusMutexV19;
static std::unordered_map<std::wstring, PreparedOpusCacheV19> preparedOpusCacheV19;

static std::wstring audioCacheKeyV19(const fs::path& dir) {
    std::error_code ec;
    const auto absolute = fs::absolute(dir, ec);
    return (ec ? dir : absolute).lexically_normal().wstring();
}

static uint64_t fnv1aV19(uint64_t hash, const void* data, size_t size) {
    const auto* bytes = static_cast<const unsigned char*>(data);
    for (size_t i = 0; i < size; ++i) {
        hash ^= static_cast<uint64_t>(bytes[i]);
        hash *= 1099511628211ULL;
    }
    return hash;
}

static uint64_t hashTextV19(uint64_t hash, const std::wstring& text) {
    return fnv1aV19(hash, text.data(), text.size() * sizeof(wchar_t));
}

static fs::path persistentAudioCacheRootV19() {
#ifdef _WIN32
    std::array<wchar_t, 32768> buffer{};
    const DWORD count = GetEnvironmentVariableW(L"LOCALAPPDATA", buffer.data(),
                                                 static_cast<DWORD>(buffer.size()));
    if (count > 0 && count < buffer.size())
        return fs::path(buffer.data()) / L"GitarGame" / L"cache" / L"audio";
#endif
    std::error_code ec;
    return fs::temp_directory_path(ec) / "GitarGame" / "cache" / "audio";
}

static bool dedicatedPreviewOpusExistsV19(const fs::path& dir) {
    std::error_code ec;
    return fs::is_regular_file(dir / "preview.opus", ec);
}

static bool needsFullOpusPreparationV19(const fs::path& dir) {
    std::error_code ec;
    bool hasOpus = false;
    for (const auto& entry : fs::directory_iterator(dir, ec)) {
        if (!entry.is_regular_file(ec)) { ec.clear(); continue; }
        const auto path = entry.path();
        if (!audioExtension(path) || lower(path.stem().string()) == "preview") continue;
        if (lower(path.extension().string()) == ".opus") hasOpus = true;
        else return false; // Native raylib stream path is already fast.
    }
    return hasOpus;
}

static bool needsAnyOpusPreparationV19(const fs::path& dir) {
    return dedicatedPreviewOpusExistsV19(dir) || needsFullOpusPreparationV19(dir);
}

static fs::path cacheFileForOpusV19(const fs::path& dir, bool previewOnly) {
    uint64_t hash = 1469598103934665603ULL;
    hash = hashTextV19(hash, audioCacheKeyV19(dir));
    const wchar_t kind = previewOnly ? L'P' : L'F';
    hash = fnv1aV19(hash, &kind, sizeof(kind));

    std::vector<fs::path> files;
    std::error_code ec;
    for (const auto& entry : fs::directory_iterator(dir, ec)) {
        if (!entry.is_regular_file(ec)) { ec.clear(); continue; }
        const fs::path path = entry.path();
        if (lower(path.extension().string()) != ".opus") continue;
        const bool isPreview = lower(path.stem().string()) == "preview";
        if (previewOnly != isPreview) continue;
        files.push_back(path);
    }
    std::sort(files.begin(), files.end());

    for (const auto& path : files) {
        const std::wstring name = path.filename().wstring();
        hash = hashTextV19(hash, name);

        const auto size = fs::file_size(path, ec);
        if (!ec) hash = fnv1aV19(hash, &size, sizeof(size));
        ec.clear();

        const auto stamp = fs::last_write_time(path, ec);
        if (!ec) {
            const auto ticks = stamp.time_since_epoch().count();
            hash = fnv1aV19(hash, &ticks, sizeof(ticks));
        }
        ec.clear();
    }

    std::wostringstream fileName;
    fileName << std::hex << std::setw(16) << std::setfill(L'0') << hash
             << (previewOnly ? L"-preview.wav" : L"-full.wav");
    return persistentAudioCacheRootV19() / fileName.str();
}

static bool usableCachedWavV19(const fs::path& path) {
    std::error_code ec;
    return fs::is_regular_file(path, ec) && fs::file_size(path, ec) > 44;
}

static bool writeCachedWavV19(const fs::path& path, const std::vector<unsigned char>& bytes) {
    if (bytes.size() <= 44) return false;
    std::error_code ec;
    fs::create_directories(path.parent_path(), ec);
    if (ec) return false;

    fs::path temp = path;
    temp += L".tmp";
    {
        std::ofstream out(temp, std::ios::binary | std::ios::trunc);
        if (!out) return false;
        out.write(reinterpret_cast<const char*>(bytes.data()),
                  static_cast<std::streamsize>(bytes.size()));
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

static bool fullOpusPreparationFinishedV19(const fs::path& dir) {
    if (!needsFullOpusPreparationV19(dir)) return true;
    const fs::path disk = cacheFileForOpusV19(dir, false);
    if (usableCachedWavV19(disk)) return true;
    std::lock_guard lock(preparedOpusMutexV19);
    const auto it = preparedOpusCacheV19.find(audioCacheKeyV19(dir));
    return it != preparedOpusCacheV19.end() && it->second.fullAttempted;
}

static bool previewOpusPreparationFinishedV19(const fs::path& dir) {
    if (!dedicatedPreviewOpusExistsV19(dir)) return true;
    const fs::path disk = cacheFileForOpusV19(dir, true);
    if (usableCachedWavV19(disk)) return true;
    std::lock_guard lock(preparedOpusMutexV19);
    const auto it = preparedOpusCacheV19.find(audioCacheKeyV19(dir));
    return it != preparedOpusCacheV19.end() && it->second.previewAttempted;
}

static bool anyOpusPreparationFinishedV19(const fs::path& dir) {
    return fullOpusPreparationFinishedV19(dir) && previewOpusPreparationFinishedV19(dir);
}

static fs::path preparedFullOpusPathV19(const fs::path& dir) {
    const fs::path disk = cacheFileForOpusV19(dir, false);
    if (usableCachedWavV19(disk)) return disk;
    std::lock_guard lock(preparedOpusMutexV19);
    const auto it = preparedOpusCacheV19.find(audioCacheKeyV19(dir));
    return it == preparedOpusCacheV19.end() ? fs::path{} : it->second.fullPath;
}

static fs::path preparedPreviewOpusPathV19(const fs::path& dir) {
    const fs::path disk = cacheFileForOpusV19(dir, true);
    if (usableCachedWavV19(disk)) return disk;
    std::lock_guard lock(preparedOpusMutexV19);
    const auto it = preparedOpusCacheV19.find(audioCacheKeyV19(dir));
    return it == preparedOpusCacheV19.end() ? fs::path{} : it->second.previewPath;
}

static void prepareOpusCachesV19(const fs::path& dir) {
    const std::wstring key = audioCacheKeyV19(dir);

    if (dedicatedPreviewOpusExistsV19(dir) && !previewOpusPreparationFinishedV19(dir)) {
        const fs::path cachePath = cacheFileForOpusV19(dir, true);
        std::string error;
        auto decoded = opusmix::decodeFile(dir / "preview.opus", error);
        const bool saved = decoded && writeCachedWavV19(cachePath, decoded->wavBytes);
        {
            std::lock_guard lock(preparedOpusMutexV19);
            auto& cache = preparedOpusCacheV19[key];
            cache.previewAttempted = true;
            if (saved) cache.previewPath = cachePath;
        }
#ifdef _WIN32
        if (saved) ggdiag::log("Cached preview Opus PCM: " + cachePath.string());
        else if (!decoded && !error.empty()) ggdiag::log("Async preview Opus decode failed: " + error);
#endif
    }

    if (needsFullOpusPreparationV19(dir) && !fullOpusPreparationFinishedV19(dir)) {
        const fs::path cachePath = cacheFileForOpusV19(dir, false);
        std::string error;
        auto mixed = opusmix::mixDirectory(dir, error);
        const bool saved = mixed && writeCachedWavV19(cachePath, mixed->wavBytes);
        {
            std::lock_guard lock(preparedOpusMutexV19);
            auto& cache = preparedOpusCacheV19[key];
            cache.fullAttempted = true;
            if (saved) cache.fullPath = cachePath;
        }
#ifdef _WIN32
        if (saved) ggdiag::log("Cached mixed Opus PCM: " + cachePath.string());
        else if (!mixed && !error.empty() && error != "No .opus stems found")
            ggdiag::log("Async song Opus mix failed: " + error);
#endif
    }
}

'@
$legacy = $legacy.Replace($loadMarker, $cacheCode + $loadMarker)

$loadPattern = '(?ms)^static std::vector<Stem> loadStems\(const fs::path& dir\) \{.*?^\}\r?\n\r?\nstatic void unloadStems'
$loadReplacement = @'
static std::vector<Stem> loadStems(const fs::path& dir) {
    std::vector<fs::path> files;
    std::error_code ec;
    bool hasOpus = false;
    for (const auto& entry : fs::directory_iterator(dir, ec)) {
        if (!entry.is_regular_file(ec)) { ec.clear(); continue; }
        const auto path = entry.path();
        if (!audioExtension(path) || lower(path.stem().string()) == "preview") continue;
        if (lower(path.extension().string()) == ".opus") hasOpus = true;
        else files.push_back(path);
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

    fs::path preparedPath = preparedFullOpusPathV19(dir);
    if (preparedPath.empty() && !fullOpusPreparationFinishedV19(dir)) {
        // Direct command-line launches and unusual entry points can still reach
        // loadSong without browser prewarming. Keep compatibility by preparing
        // synchronously only in that fallback path.
        prepareOpusCachesV19(dir);
        preparedPath = preparedFullOpusPathV19(dir);
    }
    if (preparedPath.empty()) return stems;

    const std::string preparedUtf8 = preparedPath.string();
    Music m = LoadMusicStream(preparedUtf8.c_str());
    if (m.ctxData != nullptr) {
        stems.push_back({m, preparedPath, {}});
#ifdef _WIN32
        ggdiag::log("Loaded prepared Opus package from persistent alpha.19 PCM cache");
#endif
    }
    return stems;
}

static void unloadStems
'@
$updatedLegacy = [regex]::Replace($legacy, $loadPattern, $loadReplacement, 1)
if ($updatedLegacy -eq $legacy) { throw 'Could not replace loadStems for alpha.19' }
$legacy = $updatedLegacy
[System.IO.File]::WriteAllText($legacyPath, $legacy, [System.Text.UTF8Encoding]::new($false))

# ---------------------------------------------------------------------------
# UI shell / async preparation coordinator / navigation audio.
# ---------------------------------------------------------------------------
$text = [System.IO.File]::ReadAllText($OutputPath)
$text = $text.Replace('v0.1.0-alpha.18', 'v0.1.0-alpha.19')

# Cleaner title screen.
$text = $text.Replace('    DrawText("lightweight five-fret player", 76, 136, 20, GRAY);' + $nl, '')
$text = $text.Replace('    DrawText("Fast startup. Audio-clock timing. Fully configurable highway.", 72, sh - 96, 17, LIGHTGRAY);' + $nl, '')

# Highway range in the live settings editor.
$text = $text.Replace(
    'cfg.highwayLength = clampFloat(cfg.highwayLength + dir * 0.02f, 0.35f, 0.95f);',
    'cfg.highwayLength = clampFloat(cfg.highwayLength + dir * 0.025f, 0.30f, 1.40f);'
)

# Generate subtle UI sounds procedurally so the portable build does not need an
# extra asset directory.
$uiSoundMarker = 'struct UiNav {'
$uiSoundCode = @'
static Sound makeUiToneV19(float frequency, float durationSeconds, float gain) {
    const int sampleRate = 44100;
    const int frameCount = std::max(1, static_cast<int>(durationSeconds * sampleRate));
    std::vector<short> samples(static_cast<size_t>(frameCount));
    for (int i = 0; i < frameCount; ++i) {
        const float t = static_cast<float>(i) / static_cast<float>(sampleRate);
        const float env = std::max(0.0f, 1.0f - t / durationSeconds);
        const float wave = std::sin(2.0f * PI * frequency * t);
        samples[static_cast<size_t>(i)] = static_cast<short>(wave * env * gain * 32767.0f);
    }
    Wave wave{};
    wave.frameCount = static_cast<unsigned int>(frameCount);
    wave.sampleRate = sampleRate;
    wave.sampleSize = 16;
    wave.channels = 1;
    wave.data = samples.data();
    return LoadSoundFromWave(wave);
}

struct UiSoundsV19 {
    Sound move{};
    Sound accept{};
    Sound back{};
    bool ready = false;

    void init() {
        if (!IsAudioDeviceReady()) return;
        move = makeUiToneV19(620.0f, 0.035f, 0.16f);
        accept = makeUiToneV19(880.0f, 0.055f, 0.20f);
        back = makeUiToneV19(410.0f, 0.050f, 0.18f);
        ready = move.frameCount > 0 && accept.frameCount > 0 && back.frameCount > 0;
    }

    void playMove() const { if (ready) { StopSound(move); PlaySound(move); } }
    void playAccept() const { if (ready) { StopSound(accept); PlaySound(accept); } }
    void playBack() const { if (ready) { StopSound(back); PlaySound(back); } }

    void unload() {
        if (!ready) return;
        UnloadSound(move);
        UnloadSound(accept);
        UnloadSound(back);
        ready = false;
    }
};

struct AsyncAudioPrepV19 {
    std::future<void> worker;
    fs::path active;
    fs::path queued;

    void request(const fs::path& dir) {
        if (!needsAnyOpusPreparationV19(dir) || anyOpusPreparationFinishedV19(dir)) return;
        if (!active.empty() && audioCacheKeyV19(active) == audioCacheKeyV19(dir)) return;
        queued = dir;
    }

    void update() {
        if (worker.valid() && worker.wait_for(std::chrono::milliseconds(0)) == std::future_status::ready) {
            try { worker.get(); } catch (...) {
#ifdef _WIN32
                ggdiag::log("Async audio preparation worker threw an exception");
#endif
            }
            active.clear();
        }
        if (!worker.valid() && !queued.empty()) {
            fs::path next = queued;
            queued.clear();
            if (needsAnyOpusPreparationV19(next) && !anyOpusPreparationFinishedV19(next)) {
                active = next;
                worker = std::async(std::launch::async, [next]() { prepareOpusCachesV19(next); });
            }
        }
    }

    bool busyFor(const fs::path& dir) const {
        return (!active.empty() && audioCacheKeyV19(active) == audioCacheKeyV19(dir)) ||
               (!queued.empty() && audioCacheKeyV19(queued) == audioCacheKeyV19(dir));
    }

    void finish() {
        queued.clear();
        if (worker.valid()) {
            try { worker.get(); } catch (...) {}
        }
        active.clear();
    }
};

'@
if (-not $text.Contains($uiSoundMarker)) { throw 'Could not locate UiNav for alpha.19 UI sound injection' }
$text = $text.Replace($uiSoundMarker, $uiSoundCode + $uiSoundMarker)

# Preview loader: Opus work is now cache-only on the UI thread. If the worker is
# still preparing bytes, startRequested() simply retries on a later frame.
$previewPattern = '(?ms)^static std::vector<Stem> loadPreviewStemsV13\(const fs::path& dir, bool& dedicatedPreview\) \{.*?^\}\r?\n\r?\nstruct SongPreviewV13'
$previewReplacement = @'
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
            if (!previewOpusPreparationFinishedV19(dir)) return {};
            const fs::path preparedPath = preparedPreviewOpusPathV19(dir);
            if (preparedPath.empty()) continue;
            const std::string preparedUtf8 = preparedPath.string();
            Music music = LoadMusicStream(preparedUtf8.c_str());
            if (music.ctxData != nullptr) return {{music, preparedPath, {}}};
        } else {
            const std::string utf8 = pathUtf8(path);
            Music music = LoadMusicStream(utf8.c_str());
            if (music.ctxData != nullptr) return {{music, path, {}}};
        }
    }

    dedicatedPreview = false;
    if (needsFullOpusPreparationV19(dir)) {
        if (!fullOpusPreparationFinishedV19(dir)) return {};
        const fs::path preparedPath = preparedFullOpusPathV19(dir);
        if (preparedPath.empty()) return {};
        const std::string preparedUtf8 = preparedPath.string();
        Music music = LoadMusicStream(preparedUtf8.c_str());
        if (music.ctxData != nullptr) return {{music, preparedPath, {}}};
        return {};
    }
    return loadStems(dir);
}

struct SongPreviewV13
'@
$updated = [regex]::Replace($text, $previewPattern, $previewReplacement, 1)
if ($updated -eq $text) { throw 'Could not replace preview loader for alpha.19 async audio' }
$text = $updated

# Runtime state.
$audioInitOld = 'Sound calibrationClick{}; bool calibrationClickReady = false; if (IsAudioDeviceReady()) { calibrationClick = createCalibrationClick(); calibrationClickReady = calibrationClick.frameCount > 0; }'
$audioInitNew = $audioInitOld + $nl + '    UiSoundsV19 uiSoundsV19; uiSoundsV19.init(); AsyncAudioPrepV19 audioPrepV19; int pendingSongV19 = -1;'
if (-not $text.Contains($audioInitOld)) { throw 'Could not locate audio initialization for alpha.19' }
$text = $text.Replace($audioInitOld, $audioInitNew)

# Play navigation sounds only in menu/UI screens, never while actually playing.
$navMarker = @'
#ifdef _WIN32
        mergeGuitarNav(nav, events, cfg);
#endif
'@
$navReplacement = @'
#ifdef _WIN32
        mergeGuitarNav(nav, events, cfg);
#endif
        if (screen != AppScreen::Playing && !binding && !showHelp) {
            if (nav.up || nav.down || nav.left || nav.right) uiSoundsV19.playMove();
            if (nav.accept || nav.start) uiSoundsV19.playAccept();
            else if (nav.back) uiSoundsV19.playBack();
        }
'@
if (-not $text.Contains($navMarker)) { throw 'Could not locate navigation merge for alpha.19 sounds' }
$text = $text.Replace($navMarker, $navReplacement.TrimEnd())

# Prewarm selected-song Opus data after the browser selection settles. This runs
# before preview update so the preview can begin immediately when bytes finish.
$previewLoopOld = @'
            if (!songs.empty()) {
                songPreview.request(selectedSong);
                songPreview.update(songs, songMeta);
            } else {
'@
$previewLoopNew = @'
            if (!songs.empty()) {
                songPreview.request(selectedSong);
                if (songPreview.requestedSong == selectedSong &&
                    Clock::now() - songPreview.requestedAt >= std::chrono::milliseconds(180)) {
                    audioPrepV19.request(songs[static_cast<size_t>(selectedSong)].directory);
                }
                audioPrepV19.update();
                songPreview.update(songs, songMeta);
            } else {
'@
if (-not $text.Contains($previewLoopOld)) { throw 'Could not locate browser preview loop for alpha.19 prewarm' }
$text = $text.Replace($previewLoopOld, $previewLoopNew)

# If Play is requested before an Opus-only package has finished preparation,
# keep rendering the browser and start automatically when the worker completes.
$browserLoadOld = 'if ((nav.accept || nav.start) && !songs.empty()) { songPreview.clearRequest(); if (loadSongV7(session, songs[selectedSong]))'
$browserLoadNew = 'if ((nav.accept || nav.start) && !songs.empty()) { songPreview.clearRequest(); const auto& chosenV19 = songs[static_cast<size_t>(selectedSong)]; if (needsFullOpusPreparationV19(chosenV19.directory) && !fullOpusPreparationFinishedV19(chosenV19.directory)) { pendingSongV19 = selectedSong; audioPrepV19.request(chosenV19.directory); status = "Loading audio..."; } else if (loadSongV7(session, chosenV19))'
if (-not $text.Contains($browserLoadOld)) { throw 'Could not locate song browser play action for alpha.19 async load' }
$text = $text.Replace($browserLoadOld, $browserLoadNew)

$beforeSwitchMarker = '        if (!binding && !showHelp) {' + $nl + '            switch (screen) {'
$pendingCode = @'
        audioPrepV19.update();
        if (pendingSongV19 >= 0 && screen == AppScreen::SongBrowser &&
            pendingSongV19 < static_cast<int>(songs.size())) {
            const auto& pendingInfoV19 = songs[static_cast<size_t>(pendingSongV19)];
            if (fullOpusPreparationFinishedV19(pendingInfoV19.directory)) {
                const int startingV19 = pendingSongV19;
                pendingSongV19 = -1;
                if (loadSongV7(session, songs[static_cast<size_t>(startingV19)])) {
                    activateSongTiming();
                    screen = AppScreen::Playing;
                    status.clear();
                } else {
                    status = session.error;
                }
            } else {
                status = "Loading audio...";
            }
        }

        if (!binding && !showHelp) {
            switch (screen) {
'@
if (-not $text.Contains($beforeSwitchMarker)) { throw 'Could not locate main switch marker for alpha.19 pending song start' }
$text = $text.Replace($beforeSwitchMarker, $pendingCode.TrimEnd())

# Clean shutdown: wait for at most the active preparation worker before shared
# caches and process state disappear.
$shutdownOld = 'songPreview.clearRequest(); artwork.clear(); unloadStems(session.stems); if (calibrationClickReady) UnloadSound(calibrationClick); CloseAudioDevice(); CloseWindow(); return 0;'
$shutdownNew = 'pendingSongV19 = -1; audioPrepV19.finish(); songPreview.clearRequest(); artwork.clear(); unloadStems(session.stems); uiSoundsV19.unload(); if (calibrationClickReady) UnloadSound(calibrationClick); CloseAudioDevice(); CloseWindow(); return 0;'
if (-not $text.Contains($shutdownOld)) { throw 'Could not locate shutdown path for alpha.19 cleanup' }
$text = $text.Replace($shutdownOld, $shutdownNew)

[System.IO.File]::WriteAllText($OutputPath, $text, [System.Text.UTF8Encoding]::new($false))
Write-Host "Prepared alpha.19 UI polish, highway controls, navigation audio and async Opus loading: $OutputPath"
