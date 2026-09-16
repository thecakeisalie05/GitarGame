param(
    [Parameter(Mandatory=$true)][string]$InputPath,
    [Parameter(Mandatory=$true)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$alpha9 = Join-Path $PSScriptRoot 'prepare_alpha9.ps1'
& $alpha9 -InputPath $InputPath -OutputPath $OutputPath
if (-not (Test-Path $OutputPath)) { throw 'alpha.9 source preparation did not produce an output file before alpha.10 patching' }

$text = [System.IO.File]::ReadAllText($OutputPath)

# The alpha.7+ picker runs in a separate PowerShell/WinForms process. With no
# owner, Windows can legally place that dialog behind a fullscreen GLFW window.
# Alpha.10 makes the chooser unambiguous: fullscreen GitarGame is temporarily
# minimized, the chooser is owned by a tiny invisible topmost WinForms window,
# and GitarGame is restored/refocused whether the user selects a folder or
# cancels the dialog.
$pickerPattern = '(?ms)^static std::optional<std::string> chooseSongsFolder\(\) \{.*?^\}\r?\n#endif'
$pickerReplacement = @'
static std::optional<std::string> chooseSongsFolder() {
    const bool wasFullscreen = IsWindowFullscreen();
    if (wasFullscreen) {
        ggdiag::log("Folder picker: minimizing fullscreen GitarGame before opening dialog");
        MinimizeWindow();
        Sleep(120);
    }

    auto restoreGameWindow = [&]() {
        if (wasFullscreen) {
            RestoreWindow();
            Sleep(80);
        }
        SetWindowFocused();
        ggdiag::log("Folder picker: GitarGame window restored/refocused");
    };

    const char* command =
        "powershell.exe -NoProfile -STA -WindowStyle Hidden -Command \""
        "$ErrorActionPreference='Stop';"
        "$OutputEncoding=[Console]::OutputEncoding=[Text.UTF8Encoding]::new();"
        "Add-Type -AssemblyName System.Windows.Forms;"
        "$owner=New-Object System.Windows.Forms.Form;"
        "$owner.ShowInTaskbar=$false;"
        "$owner.TopMost=$true;"
        "$owner.FormBorderStyle=[System.Windows.Forms.FormBorderStyle]::None;"
        "$owner.StartPosition=[System.Windows.Forms.FormStartPosition]::CenterScreen;"
        "$owner.Size=New-Object System.Drawing.Size(1,1);"
        "$owner.Opacity=0;"
        "$owner.Show();"
        "$owner.Activate();"
        "[System.Windows.Forms.Application]::DoEvents();"
        "$d=New-Object System.Windows.Forms.FolderBrowserDialog;"
        "$d.Description='Choose GitarGame songs folder';"
        "$r=$d.ShowDialog($owner);"
        "if($r -eq [System.Windows.Forms.DialogResult]::OK){[Console]::Write($d.SelectedPath)};"
        "$owner.Close();"
        "$owner.Dispose();"
        "\"";

    FILE* pipe = _popen(command, "r");
    if (!pipe) {
        restoreGameWindow();
        return std::nullopt;
    }

    std::string output;
    char buffer[2048]{};
    while (std::fgets(buffer, static_cast<int>(sizeof(buffer)), pipe)) output += buffer;
    const int code = _pclose(pipe);
    restoreGameWindow();

    output = trim(output);
    if (code != 0 || output.empty()) return std::nullopt;
    ggdiag::log("Folder picker: selected songs directory " + output);
    return output;
}
#endif
'@

$updated = [regex]::Replace($text, $pickerPattern, $pickerReplacement, 1)
if ($updated -eq $text) { throw 'Could not replace chooseSongsFolder() for alpha.10' }
$text = $updated.Replace('v0.1.0-alpha.9', 'v0.1.0-alpha.10')

[System.IO.File]::WriteAllText($OutputPath, $text, [System.Text.UTF8Encoding]::new($false))
Write-Host "Prepared alpha.10 fullscreen-safe folder picker: $OutputPath"
