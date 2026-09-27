param(
    [Parameter(Mandatory=$true)][string]$InputPath,
    [Parameter(Mandatory=$true)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$alpha14 = Join-Path $PSScriptRoot 'prepare_alpha14.ps1'
& $alpha14 -InputPath $InputPath -OutputPath $OutputPath
if (-not (Test-Path $OutputPath)) { throw 'alpha.14 source preparation did not produce an output file before alpha.15 patching' }

$text = [System.IO.File]::ReadAllText($OutputPath)
$text = $text.Replace('v0.1.0-alpha.14', 'v0.1.0-alpha.15')

# Keep the shell COM implementation isolated in its own translation unit. This
# generated raylib source sees only a header with void*/std::string types, so
# shobjidl.h and the USER/GDI-heavy shell declarations never collide with raylib.
$includeMarker = '#include "gameplay_feedback.h"'
if (-not $text.Contains($includeMarker)) { throw 'Could not locate gameplay_feedback include for native picker header' }
$text = $text.Replace($includeMarker, $includeMarker + [Environment]::NewLine + '#include "native_folder_picker.h"')

$pickerPattern = '(?ms)^static std::optional<std::string> chooseSongsFolder\(\) \{.*?^}\r?\n#endif'
$pickerReplacement = @'
static std::optional<std::string> chooseSongsFolder() {
    const bool wasFullscreen = IsWindowFullscreen();

    // A Common Item Dialog is a real owned native window. Temporarily leave
    // fullscreen so Windows can place the owned dialog above the game without
    // relying on a hidden topmost helper process.
    if (wasFullscreen) {
        ggdiag::log("Folder picker: temporarily leaving fullscreen for native IFileDialog");
        ToggleFullscreen();
        Sleep(120);
    }

    SetWindowFocused();
    void* ownerWindow = GetWindowHandle();
    auto selected = ggwindows::chooseFolder(ownerWindow, L"Choose GitarGame songs folder");

    if (wasFullscreen) {
        ToggleFullscreen();
        Sleep(80);
    }
    SetWindowFocused();

    if (!selected || selected->empty()) {
        ggdiag::log("Folder picker: cancelled");
        return std::nullopt;
    }

    ggdiag::log("Folder picker: selected songs directory " + *selected);
    return selected;
}
#endif
'@

$updated = [regex]::Replace($text, $pickerPattern, $pickerReplacement, 1)
if ($updated -eq $text) { throw 'Could not replace PowerShell folder picker with native IFileDialog for alpha.15' }
$text = $updated

# Release hardening gate: fail source generation if the runtime shell-spawn
# implementation ever leaks back into the produced executable source.
if ($text.Contains('powershell.exe -NoProfile -STA') -or
    $text.Contains('_popen(command') -or
    $text.Contains('System.Windows.Forms.FolderBrowserDialog')) {
    throw 'alpha.15 hardening failed: runtime PowerShell folder-picker code is still present'
}

[System.IO.File]::WriteAllText($OutputPath, $text, [System.Text.UTF8Encoding]::new($false))
Write-Host "Prepared alpha.15 native Windows folder picker; runtime PowerShell bridge removed: $OutputPath"
