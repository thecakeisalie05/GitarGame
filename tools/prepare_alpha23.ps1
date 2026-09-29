param(
    [Parameter(Mandatory=$true)][string]$InputPath,
    [Parameter(Mandatory=$true)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$alpha22 = Join-Path $PSScriptRoot 'prepare_alpha22.ps1'
& $alpha22 -InputPath $InputPath -OutputPath $OutputPath
if (-not (Test-Path $OutputPath)) { throw 'alpha.22 source preparation did not produce an output file before alpha.23 patching' }

$generatedDir = Split-Path -Parent $OutputPath
$legacyPath = Join-Path $generatedDir 'main.cpp'
$legacy = [System.IO.File]::ReadAllText($legacyPath)

# Carry legacy RB/FoF HOPO metadata into both chart encodings. Alpha.22 already
# forwards an explicit tick threshold; alpha.23 adds eighthnote_hopo as the
# fallback mode when no explicit hopo_frequency/hopofreq threshold is present.
$chartOld = 'chart = parseChart(info.directory / "notes.chart", err, info.hopoThresholdTicks);'
$chartNew = 'chart = parseChart(info.directory / "notes.chart", err, info.hopoThresholdTicks, info.eighthNoteHopo);'
if (-not $legacy.Contains($chartOld)) { throw 'Could not locate alpha.22 .chart load call for alpha.23' }
$legacy = $legacy.Replace($chartOld, $chartNew)

$midOld = 'chart = midichart::parse(info.directory / "notes.mid", err, info.hopoThresholdTicks);'
$midNew = 'chart = midichart::parse(info.directory / "notes.mid", err, info.hopoThresholdTicks, info.eighthNoteHopo);'
if (-not $legacy.Contains($midOld)) { throw 'Could not locate alpha.22 notes.mid load call for alpha.23' }
$legacy = $legacy.Replace($midOld, $midNew)

$midiOld = 'chart = midichart::parse(info.directory / "notes.midi", err, info.hopoThresholdTicks);'
$midiNew = 'chart = midichart::parse(info.directory / "notes.midi", err, info.hopoThresholdTicks, info.eighthNoteHopo);'
if (-not $legacy.Contains($midiOld)) { throw 'Could not locate alpha.22 notes.midi load call for alpha.23' }
$legacy = $legacy.Replace($midiOld, $midiNew)

[System.IO.File]::WriteAllText($legacyPath, $legacy, [System.Text.UTF8Encoding]::new($false))

$text = [System.IO.File]::ReadAllText($OutputPath)
$text = $text.Replace('v0.1.0-alpha.22', 'v0.1.0-alpha.23')
[System.IO.File]::WriteAllText($OutputPath, $text, [System.Text.UTF8Encoding]::new($false))

Write-Host "Prepared alpha.23 Rock Band 2 / legacy eighth-note HOPO compatibility: $OutputPath"
