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
# Per-song HOPO threshold compatibility.
#
# Current builds already use chart_engine.h for natural HOPO inference. Honor
# Clone Hero's song.ini hopo_threshold override for both .chart and MIDI loads.
# ---------------------------------------------------------------------------
$chartCallOld = 'chart = parseChart(info.directory / "notes.chart", err);'
$chartCallNew = 'chart = parseChart(info.directory / "notes.chart", err, info.hopoThresholdTicks);'
if (-not $legacy.Contains($chartCallOld)) { throw 'Could not locate .chart load call for alpha.22 HOPO threshold metadata' }
$legacy = $legacy.Replace($chartCallOld, $chartCallNew)

$midiCallOld = 'chart = midichart::parse(info.directory / "notes.mid", err);'
$midiCallNew = 'chart = midichart::parse(info.directory / "notes.mid", err, info.hopoThresholdTicks);'
if (-not $legacy.Contains($midiCallOld)) { throw 'Could not locate notes.mid load call for alpha.22 HOPO threshold metadata' }
$legacy = $legacy.Replace($midiCallOld, $midiCallNew)

$midiLongCallOld = 'chart = midichart::parse(info.directory / "notes.midi", err);'
$midiLongCallNew = 'chart = midichart::parse(info.directory / "notes.midi", err, info.hopoThresholdTicks);'
if (-not $legacy.Contains($midiLongCallOld)) { throw 'Could not locate notes.midi load call for alpha.22 HOPO threshold metadata' }
$legacy = $legacy.Replace($midiLongCallOld, $midiLongCallNew)

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

Write-Host "Prepared alpha.22 per-song HOPO metadata and dense-stream strum fixes: $OutputPath"
