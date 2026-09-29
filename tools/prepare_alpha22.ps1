param(
    [Parameter(Mandatory=$true)][string]$InputPath,
    [Parameter(Mandatory=$true)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$alpha21 = Join-Path $PSScriptRoot 'prepare_alpha21.ps1'
& $alpha21 -InputPath $InputPath -OutputPath $OutputPath
if (-not (Test-Path $OutputPath)) { throw 'alpha.21 source preparation did not produce an output file before alpha.22 patching' }

$generatedDir = Split-Path -Parent $OutputPath
$legacyPath = Join-Path $generatedDir 'main.cpp'
$legacy = [System.IO.File]::ReadAllText($legacyPath)

# ---------------------------------------------------------------------------
# HOPO classification parity.
#
# The compatibility parser already uses the CH/chart convention of 65 ticks at
# resolution 192. The legacy parser still used resolution/3, which truncates to
# 64 at 192 and incorrectly turns exact 65-tick HOPOs into strum notes.
# ---------------------------------------------------------------------------
$oldThreshold = 'const int64_t hopoThreshold = std::max<int64_t>(1, chart.resolution / 3);'
$newThreshold = 'const int64_t hopoThreshold = std::max<int64_t>(1, static_cast<int64_t>(std::floor((65.0 / 192.0) * chart.resolution)));'
if (-not $legacy.Contains($oldThreshold)) { throw 'Could not locate legacy HOPO threshold for alpha.22' }
$legacy = $legacy.Replace($oldThreshold, $newThreshold)

# ---------------------------------------------------------------------------
# Dense HOPO stream strumming.
#
# Alpha.18's 80ms compatibility strum-eat approximation ran before checking the
# next note. In fast streams (~75ms note spacing), that could consume the exact
# strum intended for the next note. Give a valid next-note hit priority over
# strum-eat forgiveness.
# ---------------------------------------------------------------------------
$eatOld = @'
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
'@
$eatNew = @'
    const double hopoEat = ggengine::kCloneHeroHopoStrumEatMs / 1000.0;
    if (s.hopoStrumEatAvailable) {
        bool nextCanTakeStrumV22 = false;
        double nextNoteTimeV22 = 1.0e30;
        if (s.nextNote < s.chart.notes.size()) {
            const auto& nextV22 = s.chart.notes[s.nextNote];
            nextNoteTimeV22 = nextV22.time;
            nextCanTakeStrumV22 =
                ggengine::noteFrettingMatches(held, nextV22.mask, nextV22.open,
                                              true, nextV22.hopo, nextV22.tap);
        }

        if (ggengine::hopoStrumShouldBeEaten(
                s.hopoStrumEatUntil - hopoEat, now, hopoEat,
                nextNoteTimeV22, window, nextCanTakeStrumV22)) {
            // This is only a redundant post-HOPO strum. If the next note is
            // already hittable, that note gets first claim on the input.
            s.hopoStrumEatAvailable = false;
            s.hopoStrumEatUntil = -1000.0;
            return false;
        }
        if (now > s.hopoStrumEatUntil ||
            (nextCanTakeStrumV22 && ggengine::withinHitWindow(nextNoteTimeV22, now, window))) {
            s.hopoStrumEatAvailable = false;
            s.hopoStrumEatUntil = -1000.0;
        }
    }
'@
if (-not $legacy.Contains($eatOld)) { throw 'Could not locate alpha.18 HOPO strum-eat block for alpha.22' }
$legacy = $legacy.Replace($eatOld, $eatNew.TrimEnd())

[System.IO.File]::WriteAllText($legacyPath, $legacy, [System.Text.UTF8Encoding]::new($false))

$text = [System.IO.File]::ReadAllText($OutputPath)
$text = $text.Replace('v0.1.0-alpha.21', 'v0.1.0-alpha.22')
[System.IO.File]::WriteAllText($OutputPath, $text, [System.Text.UTF8Encoding]::new($false))

Write-Host "Prepared alpha.22 HOPO boundary and dense-stream strum fixes: $OutputPath"
