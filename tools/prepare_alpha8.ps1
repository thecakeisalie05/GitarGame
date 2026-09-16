param(
    [Parameter(Mandatory=$true)][string]$InputPath,
    [Parameter(Mandatory=$true)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$alpha7 = Join-Path $PSScriptRoot 'prepare_alpha7.ps1'
& $alpha7 -InputPath $InputPath -OutputPath $OutputPath

$text = [System.IO.File]::ReadAllText($OutputPath)
$text = $text.Replace('v0.1.0-alpha.7', 'v0.1.0-alpha.8')
$includeReplacement = @'
#include <numeric>
#include "highway_grid.h"
'@
$text = $text.Replace('#include <numeric>', $includeReplacement.Trim())

# Restart transport guard ----------------------------------------------------
# raylib can briefly report the pre-seek decoder position on the frame immediately
# after Stop/Seek/Play. If gameplay consumes that stale time, a restarted song can
# instantly mark most notes missed, fill phrase state, and leave MISS feedback stuck.
$clockMarker = 'static AudioClockV7 audioClockV7;'
$clockReplacement = @'
static AudioClockV7 audioClockV7;

struct RestartGuardV8 {
    bool pending = false;
    double previousDecoderSeconds = 0.0;
    Clock::time_point requestedAt{};

    void begin(double previous) {
        previousDecoderSeconds = std::max(0.0, previous);
        requestedAt = Clock::now();
        pending = previousDecoderSeconds > 0.20;
    }

    bool waiting(double rawNow) {
        if (!pending) return false;
        const bool rewindObserved = rawNow < 0.20 || rawNow + 0.25 < previousDecoderSeconds;
        const bool timedOut = Clock::now() - requestedAt > std::chrono::milliseconds(750);
        if (rewindObserved || timedOut) {
            pending = false;
            audioClockV7.reset();
            return false;
        }
        return true;
    }
};

static RestartGuardV8 restartGuardV8;
'@
if (-not $text.Contains($clockMarker)) { throw 'Could not locate alpha.7 audio clock marker for restart guard' }
$text = $text.Replace($clockMarker, $clockReplacement)

$oldRestart = @'
static void playFromStartV7(Session& s) {
    playFromStart(s);
    audioClockV7.reset();
}
'@
$newRestart = @'
static void playFromStartV8(Session& s) {
    const double previous = s.stems.empty() ? 0.0 : static_cast<double>(GetMusicTimePlayed(s.stems.front().music));
    playFromStart(s); // resetChartState() clears note colors, SP, rock and judgment feedback.
    audioClockV7.reset();
    restartGuardV8.begin(previous);
}
'@
if (-not $text.Contains($oldRestart)) { throw 'Could not locate playFromStartV7() for alpha.8' }
$text = $text.Replace($oldRestart, $newRestart)
$text = $text.Replace('playFromStartV7(session)', 'playFromStartV8(session)')

$audioSampleLine = '    const double audioSeconds = audioClockV7.sample(s);'
$audioSampleReplacement = @'
    const double rawRestartCheck = static_cast<double>(GetMusicTimePlayed(s.stems.front().music));
    if (restartGuardV8.waiting(rawRestartCheck)) {
        // Hold the chart at its initial metadata/calibration position until the
        // decoder confirms the seek. This lasts only through the stale-position
        // window and prevents a full-chart false miss cascade on restart.
        return chartOffsetSeconds
            - activeSongDelayMsV7 / 1000.0
            - static_cast<double>(cfg.audioOffsetMs) / 1000.0;
    }
    const double audioSeconds = audioClockV7.sample(s);
'@
if (-not $text.Contains($audioSampleLine)) { throw 'Could not locate alpha.7 audio sample for restart guard' }
$text = $text.Replace($audioSampleLine, $audioSampleReplacement)

# Musical beat/measure grid --------------------------------------------------
$oldGuides = @'
    if (ui.depthGuides) for (int i = 1; i <= 9; ++i) {
        const float t = static_cast<float>(i) / 10.0f;
        const float z = hitZ + t * (farZ - hitZ);
        DrawLine3D({left, roadY + 0.012f, z}, {right, roadY + 0.012f, z}, alphaColor(RAYWHITE, 18));
    }
'@
$newGuides = @'
    if (ui.depthGuides) {
        static std::vector<HighwayGridLine> gridCacheV8;
        static int cachedResolutionV8 = -1;
        static size_t cachedNotesV8 = 0;
        static size_t cachedTemposV8 = 0;
        static size_t cachedSignaturesV8 = 0;
        static int64_t cachedLastTickV8 = -1;
        const int64_t lastTick = s.chart.notes.empty() ? -1 : s.chart.notes.back().tick;
        if (cachedResolutionV8 != s.chart.resolution || cachedNotesV8 != s.chart.notes.size() ||
            cachedTemposV8 != s.chart.tempos.size() || cachedSignaturesV8 != s.chart.timeSignatures.size() ||
            cachedLastTickV8 != lastTick) {
            gridCacheV8 = buildHighwayGrid(s.chart);
            cachedResolutionV8 = s.chart.resolution;
            cachedNotesV8 = s.chart.notes.size();
            cachedTemposV8 = s.chart.tempos.size();
            cachedSignaturesV8 = s.chart.timeSignatures.size();
            cachedLastTickV8 = lastTick;
        }

        for (const auto& gridLine : gridCacheV8) {
            const double dt = gridLine.time - now;
            if (dt < -0.10 || dt > visibleSeconds * 1.06) continue;
            const float z = hitZ + static_cast<float>(dt / visibleSeconds) * (farZ - hitZ);
            if (z < nearZ || z > farZ) continue;
            if (gridLine.measure) {
                DrawCube({0.0f, roadY + 0.020f, z}, roadWidth + 0.08f, 0.018f, 0.055f, alphaColor(RAYWHITE, 92));
            } else {
                DrawLine3D({left, roadY + 0.014f, z}, {right, roadY + 0.014f, z}, alphaColor(RAYWHITE, 27));
            }
        }
    }
'@
if (-not $text.Contains($oldGuides)) { throw 'Could not locate alpha.7 depth-guide block' }
$text = $text.Replace($oldGuides, $newGuides)

# Distinct HOPO / tap gem silhouettes ---------------------------------------
$gemPattern = '(?ms)        for \(int lane = 0; lane < 5; \+\+lane\) if \(n\.mask & \(1 << lane\)\) \{\r?\n            Color c = n\.missed \? missColor : cfg\.lanes\[lane\];\r?\n            if \(n\.hit\) c\.a = 70;\r?\n            const float radius = laneWidth \* 0\.31f \* ui\.noteScale;\r?\n            drawDisc3DV5\(\{laneX\(lane\), 0\.07f, z\}, radius, 0\.115f, 12, c\);\r?\n            if \(!n\.missed && \(n\.hopo \|\| n\.tap\)\) \{.*?\r?\n            \}\r?\n        \}'
$gemReplacement = @'
        for (int lane = 0; lane < 5; ++lane) if (n.mask & (1 << lane)) {
            Color c = n.missed ? missColor : cfg.lanes[lane];
            if (n.hit) c.a = 70;
            const float radius = laneWidth * 0.31f * ui.noteScale;

            if (n.missed) {
                drawDisc3DV5({laneX(lane), 0.07f, z}, radius, 0.115f, 12, c);
            } else if (n.tap) {
                Color tapOuter{235, 248, 255, static_cast<unsigned char>(n.hit ? 75 : 255)};
                drawDisc3DV5({laneX(lane), 0.075f, z}, radius * 0.92f, 0.105f, 14, tapOuter);
                drawDisc3DV5({laneX(lane), 0.190f, z}, radius * 0.47f, 0.028f, 14, c);
                DrawCylinderWires({laneX(lane), 0.195f, z}, radius * 0.50f, radius * 0.50f, 0.032f, 14, alphaColor(RAYWHITE, n.hit ? 65 : 235));
            } else if (n.hopo) {
                Color rim{225, 235, 245, static_cast<unsigned char>(n.hit ? 65 : 245)};
                drawDisc3DV5({laneX(lane), 0.072f, z}, radius * 0.86f, 0.095f, 14, rim);
                drawDisc3DV5({laneX(lane), 0.178f, z}, radius * 0.55f, 0.035f, 14, c);
                DrawCylinderWires({laneX(lane), 0.181f, z}, radius * 0.58f, radius * 0.58f, 0.040f, 14, alphaColor(RAYWHITE, n.hit ? 55 : 215));
            } else {
                drawDisc3DV5({laneX(lane), 0.07f, z}, radius, 0.115f, 12, c);
                Color shine = alphaColor(RAYWHITE, n.hit ? 20 : 65);
                drawDisc3DV5({laneX(lane), 0.188f, z}, radius * 0.18f, 0.018f, 10, shine);
            }
        }
'@
$gemUpdated = [regex]::Replace($text, $gemPattern, $gemReplacement, 1)
if ($gemUpdated -eq $text) { throw 'Could not replace alpha.7 note gem renderer for HOPO styling' }
$text = $gemUpdated

[System.IO.File]::WriteAllText($OutputPath, $text, [System.Text.UTF8Encoding]::new($false))
Write-Host "Prepared alpha.8 gameplay visuals and restart safety: $OutputPath"
