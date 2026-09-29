param(
    [Parameter(Mandatory=$true)][string]$InputPath,
    [Parameter(Mandatory=$true)][string]$OutputPath
)
$ErrorActionPreference='Stop'
$alpha24=Join-Path $PSScriptRoot 'prepare_alpha24.ps1'
& $alpha24 -InputPath $InputPath -OutputPath $OutputPath
if(-not(Test-Path $OutputPath)){throw 'alpha.24 generation failed before alpha.25'}

$generatedDir=Split-Path -Parent $OutputPath
$legacyPath=Join-Path $generatedDir 'main.cpp'
$legacy=[IO.File]::ReadAllText($legacyPath)
$nl=[Environment]::NewLine

# ---------------------------------------------------------------------------
# Instrument stem detection: accept real-world stem suffix/prefix variants.
# ---------------------------------------------------------------------------
$predOld=@'
static bool playableInstrumentStemV24(const fs::path& path) {
    const std::string stem = lower(path.stem().string());
    return stem == "guitar" || stem == "rhythm";
}
'@
$predNew=@'
static bool playableInstrumentStemV24(const fs::path& path) {
    const std::string stem = lower(path.stem().string());
    // Common CH/YARG/Harmonix extraction variants include guitar_1,
    // guitar_2, guitar.1, rhythm_1, etc. Treat any clearly named
    // guitar/rhythm stem as the playable instrument, but never song/mix.
    return stem.find("guitar") != std::string::npos ||
           stem.find("rhythm") != std::string::npos;
}
'@
if(-not $legacy.Contains($predOld)){throw 'Could not locate alpha.24 instrument stem predicate'}
$legacy=$legacy.Replace($predOld,$predNew.TrimEnd())

# ---------------------------------------------------------------------------
# True time-preserving whammy DSP.
#
# raylib SetMusicPitch resamples the stream and therefore changes playback
# rate. Replace it with an attached stream processor: a dual-tap modulated
# delay pitch shifter. It changes the perceived pitch while the Music clock
# continues at 1x speed.
# ---------------------------------------------------------------------------
$helperPattern='(?ms)^static void updateInstrumentAudioFxV24\(std::vector<Stem>& stems,.*?^\}\r?\n'
$helperReplacement=@'
static std::atomic<float> whammyAmountV25{0.0f};
static AudioStream whammyStreamV25{};
static bool whammyStreamAttachedV25 = false;

static void whammyPitchProcessorV25(void* bufferData, unsigned int frames) {
    float* data = static_cast<float*>(bufferData);
    if (!data || frames == 0) return;

    const float amount = std::clamp(whammyAmountV25.load(std::memory_order_relaxed), 0.0f, 1.0f);
    if (amount <= 0.005f) return;

    // About two semitones down at full whammy. The delay modulation keeps the
    // output frame count identical to the input frame count, so playback time
    // does not change.
    const float ratio = std::pow(2.0f, (-2.0f * amount) / 12.0f);
    constexpr int kBufferFrames = 8192;
    constexpr float kMinDelay = 96.0f;
    constexpr float kDelayRange = 3072.0f;
    static std::array<float, kBufferFrames * 2> delay{};
    static int writeFrame = 0;
    static float phase = 0.0f;

    const float phaseStep = (1.0f - ratio) / kDelayRange;

    auto readTap = [&](float delayFrames, int channel) {
        float read = static_cast<float>(writeFrame) - delayFrames;
        while (read < 0.0f) read += static_cast<float>(kBufferFrames);
        while (read >= static_cast<float>(kBufferFrames)) read -= static_cast<float>(kBufferFrames);
        const int i0 = static_cast<int>(read);
        const int i1 = (i0 + 1) % kBufferFrames;
        const float frac = read - static_cast<float>(i0);
        const float a = delay[static_cast<size_t>(i0) * 2 + channel];
        const float b = delay[static_cast<size_t>(i1) * 2 + channel];
        return a + (b - a) * frac;
    };

    for (unsigned int frame = 0; frame < frames; ++frame) {
        delay[static_cast<size_t>(writeFrame) * 2] = data[static_cast<size_t>(frame) * 2];
        delay[static_cast<size_t>(writeFrame) * 2 + 1] = data[static_cast<size_t>(frame) * 2 + 1];

        const float phase2 = std::fmod(phase + 0.5f, 1.0f);
        const float delay1 = kMinDelay + phase * kDelayRange;
        const float delay2 = kMinDelay + phase2 * kDelayRange;
        const float w1 = 0.5f - 0.5f * std::cos(2.0f * PI * phase);
        const float w2 = 1.0f - w1;

        for (int ch = 0; ch < 2; ++ch) {
            const float shifted = readTap(delay1, ch) * w1 + readTap(delay2, ch) * w2;
            // Blend into the dry signal so light whammy remains responsive and
            // full whammy sounds like an obvious bend without harsh switching.
            const float dry = data[static_cast<size_t>(frame) * 2 + ch];
            data[static_cast<size_t>(frame) * 2 + ch] =
                dry * (1.0f - amount) + shifted * amount;
        }

        writeFrame = (writeFrame + 1) % kBufferFrames;
        phase += phaseStep;
        if (phase >= 1.0f) phase -= 1.0f;
    }
}

static void detachWhammyProcessorV25() {
    if (!whammyStreamAttachedV25) return;
    DetachAudioStreamProcessor(whammyStreamV25, whammyPitchProcessorV25);
    whammyStreamV25 = {};
    whammyStreamAttachedV25 = false;
    whammyAmountV25.store(0.0f, std::memory_order_relaxed);
}

static void updateInstrumentAudioFxV24(std::vector<Stem>& stems,
                                       bool instrumentMuted,
                                       bool& whammyPitchActive,
                                       float whammyAmount) {
    if (stems.empty()) return;

    // Mute every matching playable-instrument stem and restore the same 0.58
    // gameplay mix level used when songs start.
    for (auto& stem : stems) {
        if (!playableInstrumentStemV24(stem.path)) continue;
        SetMusicVolume(stem.music, instrumentMuted ? 0.0f : 0.58f);
    }

    // Attach the time-preserving pitch processor to the first playable
    // instrument stream. Most five-fret packages expose one guitar stem; mute
    // behavior still applies to all matching stems.
    if (!whammyStreamAttachedV25) {
        for (auto& stem : stems) {
            if (!playableInstrumentStemV24(stem.path)) continue;
            whammyStreamV25 = stem.music.stream;
            AttachAudioStreamProcessor(whammyStreamV25, whammyPitchProcessorV25);
            whammyStreamAttachedV25 = true;
            break;
        }
    }

    whammyAmountV25.store(std::clamp(whammyAmount, 0.0f, 1.0f), std::memory_order_relaxed);
    whammyPitchActive = whammyAmount > 0.03f;
}
'@
$updated=[regex]::Replace($legacy,$helperPattern,$helperReplacement,1)
if($updated -eq $legacy){throw 'Could not replace alpha.24 audio FX helper for alpha.25'}
$legacy=$updated

# Detach the processor before any stream is unloaded.
$unloadMarker='static void unloadStems(std::vector<Stem>& stems) {'
if(-not $legacy.Contains($unloadMarker)){throw 'Could not locate unloadStems for whammy detach'}
$legacy=$legacy.Replace($unloadMarker,$unloadMarker+$nl+'    detachWhammyProcessorV25();')

[IO.File]::WriteAllText($legacyPath,$legacy,[Text.UTF8Encoding]::new($false))

$text=[IO.File]::ReadAllText($OutputPath)
$text=$text.Replace('v0.1.0-alpha.24','v0.1.0-alpha.25')

# Alpha.24 still described/implemented a re-sync path in release-era comments;
# alpha.25 no longer seeks instrument audio at all.
$text=$text.Replace('whammyPitchActiveV24','whammyPitchActiveV24')

[IO.File]::WriteAllText($OutputPath,$text,[Text.UTF8Encoding]::new($false))
Write-Host "Prepared alpha.25 time-preserving whammy DSP and robust instrument muting: $OutputPath"
