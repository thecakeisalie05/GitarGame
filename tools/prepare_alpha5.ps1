param(
    [Parameter(Mandatory=$true)][string]$InputPath,
    [Parameter(Mandatory=$true)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$text = [System.IO.File]::ReadAllText($InputPath)

# main_v3.cpp was authored with the Windows Common Item Dialog. In this
# raylib build, importing the shell UI header family conflicts with the
# intentionally minimal Win32 surface used by the renderer. Replace only that
# implementation at configure time with a tiny Windows PowerShell bridge. The
# user still gets a native folder browser, while the executable itself does not
# need to import the USER/GDI-heavy shell COM headers.
$includePattern = '(?ms)^#ifdef _WIN32\r?\n#include <objbase\.h>\r?\n#include <shobjidl\.h>\r?\n#endif'
$includeReplacement = @'
#ifdef _WIN32
#ifdef PlaySound
#undef PlaySound
#endif
#endif
#include <cstdio>
'@
$text = [regex]::Replace($text, $includePattern, $includeReplacement, 1)

$pickerPattern = '(?ms)^static std::optional<std::string> chooseSongsFolder\(\) \{.*?^\}\r?\n#endif'
$pickerReplacement = @'
static std::optional<std::string> chooseSongsFolder() {
    const char* command =
        "powershell.exe -NoProfile -STA -Command \""
        "$OutputEncoding=[Console]::OutputEncoding=[Text.UTF8Encoding]::new();"
        "Add-Type -AssemblyName System.Windows.Forms;"
        "$d=New-Object System.Windows.Forms.FolderBrowserDialog;"
        "$d.Description='Choose GitarGame songs folder';"
        "if($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK){[Console]::Write($d.SelectedPath)}"
        "\"";

    FILE* pipe = _popen(command, "r");
    if (!pipe) return std::nullopt;

    std::string output;
    char buffer[2048]{};
    while (std::fgets(buffer, static_cast<int>(sizeof(buffer)), pipe)) output += buffer;
    const int code = _pclose(pipe);
    output = trim(output);
    if (code != 0 || output.empty()) return std::nullopt;
    return output;
}
#endif
'@

$updated = [regex]::Replace($text, $pickerPattern, $pickerReplacement, 1)
if ($updated -eq $text) {
    throw 'Could not locate chooseSongsFolder() block in main_v3.cpp'
}

$directory = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Force -Path $directory | Out-Null
[System.IO.File]::WriteAllText($OutputPath, $updated, [System.Text.UTF8Encoding]::new($false))
Write-Host "Prepared alpha.5 source: $OutputPath"
