param(
    [Parameter(Mandatory=$true)][string]$InputPath,
    [Parameter(Mandatory=$true)][string]$OutputPath
)
$ErrorActionPreference='Stop'
$alpha23=Join-Path $PSScriptRoot 'prepare_alpha23.ps1'
& $alpha23 -InputPath $InputPath -OutputPath $OutputPath
if(-not(Test-Path $OutputPath)){throw 'alpha.23 generation failed before alpha.24'}

$generatedDir=Split-Path -Parent $OutputPath
$legacyPath=Join-Path $generatedDir 'main.cpp'
$legacy=[IO.File]::ReadAllText($legacyPath)
$nl=[Environment]::NewLine

# ---------------------------------------------------------------------------
# Preserve isolated Opus stems when a playable guitar/rhythm stem is present.
# This enables whammy pitch FX and mute-on-miss for Harmonix/YARG packages
# instead of flattening every Opus stem into one mixed WAV.
# ---------------------------------------------------------------------------
$loadPattern='(?ms)^static std::vector<Stem> loadStems\(const fs::path& dir\) \{.*?^\}\r?\n\r?\nstatic void unloadStems'
$loadReplacement=@'
static bool playableInstrumentStemV24(const fs::path& path) {
    const std::string stem = lower(path.stem().string());
    return stem == "guitar" || stem == "rhythm";
}

static std::vector<Stem> loadStems(const fs::path& dir) {
    std::vector<fs::path> files;
    std::vector<fs::path> opusFiles;
    std::error_code ec;
    for (const auto& entry : fs::directory_iterator(dir, ec)) {
        if (!entry.is_regular_file(ec)) { ec.clear(); continue; }
        const auto path = entry.path();
        if (lower(path.stem().string()) == "preview") continue;
        if (lower(path.extension().string()) == ".opus") opusFiles.push_back(path);
        else if (audioExtension(path)) files.push_back(path);
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
    if (!stems.empty()) return stems;

    const bool hasIsolatedInstrument = std::any_of(opusFiles.begin(), opusFiles.end(),
        [](const fs::path& p) { return playableInstrumentStemV24(p); });

    if (hasIsolatedInstrument) {
        std::sort(opusFiles.begin(), opusFiles.end(), [](const auto& a, const auto& b) {
            const int pa = audioPriority(a), pb = audioPriority(b);
            return pa == pb ? lower(a.filename().string()) < lower(b.filename().string()) : pa < pb;
        });
        for (const auto& path : opusFiles) {
            std::string error;
            auto decoded = opusmix::decodeFile(path, error);
            if (!decoded) continue;
            auto backing = std::make_shared<std::vector<unsigned char>>(std::move(decoded->wavBytes));
            if (backing->size() > static_cast<size_t>(std::numeric_limits<int>::max())) continue;
            Music m = LoadMusicStreamFromMemory(".wav", backing->data(), static_cast<int>(backing->size()));
            if (m.ctxData != nullptr) stems.push_back({m, path, backing});
        }
        if (!stems.empty()) return stems;
    }

    fs::path preparedPath = preparedFullOpusPathV19(dir);
    if (!preparedPath.empty()) {
        Music m = LoadMusicStream(preparedPath.string().c_str());
        if (m.ctxData != nullptr) return {{m, preparedPath, {}}};
    }

    std::string opusError;
    auto mixed = opusmix::mixDirectory(dir, opusError);
    if (!mixed) return stems;
    auto backing = std::make_shared<std::vector<unsigned char>>(std::move(mixed->wavBytes));
    if (backing->size() > static_cast<size_t>(std::numeric_limits<int>::max())) return stems;
    Music m = LoadMusicStreamFromMemory(".wav", backing->data(), static_cast<int>(backing->size()));
    if (m.ctxData != nullptr) stems.push_back({m, dir / "<mixed opus stems>", backing});
    return stems;
}

static void unloadStems
'@
$updated=[regex]::Replace($legacy,$loadPattern,$loadReplacement,1)
if($updated -eq $legacy){throw 'Could not replace loadStems for alpha.24'}
$legacy=$updated

# Session audio-feedback state.
$sessionNeedle='    bool lastJudgmentOverstrum = false;'
$sessionNew=@'
    bool lastJudgmentOverstrum = false;
    bool instrumentMutedV24 = false;
    bool whammyPitchActiveV24 = false;
'@
if(-not $legacy.Contains($sessionNeedle)){throw 'Could not locate Session feedback fields'}
$legacy=$legacy.Replace($sessionNeedle,$sessionNew.TrimEnd())

$resetNeedle='s.lastJudgmentOverstrum = false;'
$legacy=[regex]::Replace($legacy,[regex]::Escape($resetNeedle),$resetNeedle+' s.instrumentMutedV24 = false; s.whammyPitchActiveV24 = false;',1)

# Miss starts instrument mute. Anchor to alpha.18's miss-state reset so
# overstrums and playback resets do not trigger mute-on-miss.
$missNeedle=@'
            s.combo = 0;
            s.chTapReady = false;
            s.pendingStrum = false;
'@
$missNew=@'
            s.combo = 0;
            s.instrumentMutedV24 = true;
            s.chTapReady = false;
            s.pendingStrum = false;
'@
if(-not $legacy.Contains($missNeedle)){throw 'Could not locate actual miss-state block'}
$legacy=$legacy.Replace($missNeedle,$missNew.TrimEnd())

# A successful hit restores instrument volume.
$markNeedle='    s.lastJudgmentOverstrum = false;'
$markNew=$markNeedle+$nl+'    s.instrumentMutedV24 = false;'
$markIndex=$legacy.IndexOf('static void markHit')
if($markIndex -lt 0){throw 'markHit not found'}
$before=$legacy.Substring(0,$markIndex)
$after=$legacy.Substring($markIndex)
if(-not $after.Contains($markNeedle)){throw 'markHit judgment anchor missing'}
$after=[regex]::Replace($after,[regex]::Escape($markNeedle),$markNew,1)
$legacy=$before+$after

# Runtime audio FX helper.
$insertBefore='static void unloadStems'
$helper=@'
static void updateInstrumentAudioFxV24(std::vector<Stem>& stems,
                                       bool instrumentMuted,
                                       bool& whammyPitchActive,
                                       float whammyAmount) {
    if (stems.empty()) return;
    const float masterTime = GetMusicTimePlayed(stems.front().music);
    const float pitch = 1.0f - 0.095f * std::clamp(whammyAmount, 0.0f, 1.0f);
    const bool bending = whammyAmount > 0.03f;

    for (auto& stem : stems) {
        if (!playableInstrumentStemV24(stem.path)) continue;
        SetMusicVolume(stem.music, instrumentMuted ? 0.0f : 1.0f);
        SetMusicPitch(stem.music, bending ? pitch : 1.0f);
        if (!bending && whammyPitchActive && masterTime >= 0.0f)
            SeekMusicStream(stem.music, masterTime);
    }
    whammyPitchActive = bending;
}

'@
if(-not $legacy.Contains($insertBefore)){throw 'audio helper insertion anchor missing'}
$legacy=$legacy.Replace($insertBefore,$helper+$insertBefore,1)

[IO.File]::WriteAllText($legacyPath,$legacy,[Text.UTF8Encoding]::new($false))

# ---------------------------------------------------------------------------
# Main shell: cleaner white hit flashes + drive audio FX from current whammy.
# ---------------------------------------------------------------------------
$text=[IO.File]::ReadAllText($OutputPath)
$text=$text.Replace('v0.1.0-alpha.23','v0.1.0-alpha.24')

$flashOld=@'
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
'@
$flashNew=@'
            const float flashV24 = std::clamp(1.0f - static_cast<float>(hitAgeV13 / 0.115), 0.0f, 1.0f);
            if (flashV24 > 0.0f) {
                // Crisp white flash: fewer layers, shorter lifetime, much less grey haze.
                const float expandV24 = 1.0f - flashV24;
                drawDisc3DV5({x, 0.125f, hitZ - 0.12f}, baseRadius * (1.55f + 0.55f * expandV24),
                             0.028f, 22, alphaColor(RAYWHITE, static_cast<unsigned char>(115.0f * flashV24)));
                drawDisc3DV5({x, 0.205f, hitZ - 0.12f}, baseRadius * 0.78f,
                             0.050f, 18, alphaColor(RAYWHITE, static_cast<unsigned char>(255.0f * flashV24)));
            }
'@
if(-not $text.Contains($flashOld)){throw 'Could not locate alpha.21 flash block'}
$text=$text.Replace($flashOld,$flashNew.TrimEnd())

# After gameplay state/whammy computation, apply pitch/mute.
$whammyMarker='                    if (whammyInputV20 > 0.03f && !session.starPowerActive) {'
$fxCall='                    updateInstrumentAudioFxV24(session.stems, session.instrumentMutedV24, session.whammyPitchActiveV24, whammyInputV20);'+$nl+$whammyMarker
if(-not $text.Contains($whammyMarker)){throw 'Could not locate whammy gameplay block'}
$text=$text.Replace($whammyMarker,$fxCall,1)

[IO.File]::WriteAllText($OutputPath,$text,[Text.UTF8Encoding]::new($false))
Write-Host "Prepared alpha.24 cleaner white hit flashes, whammy pitch bend, and mute-on-miss: $OutputPath"
