param(
    [Parameter(Mandatory=$true)][string]$InputPath,
    [Parameter(Mandatory=$true)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$alpha10 = Join-Path $PSScriptRoot 'prepare_alpha10.ps1'
& $alpha10 -InputPath $InputPath -OutputPath $OutputPath
if (-not (Test-Path $OutputPath)) { throw 'alpha.10 source preparation did not produce an output file before alpha.11 patching' }

$text = [System.IO.File]::ReadAllText($OutputPath)
$text = $text.Replace('v0.1.0-alpha.10', 'v0.1.0-alpha.11')
[System.IO.File]::WriteAllText($OutputPath, $text, [System.Text.UTF8Encoding]::new($false))
Write-Host "Prepared alpha.11 MIDI sustain compatibility fix: $OutputPath"
