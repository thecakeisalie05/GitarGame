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

# alpha.6: route every gameplay load/restart/pause action through a monotonic
# timing clock. Do these replacements before injecting the wrapper functions so
# their calls to the legacy helpers are not rewritten recursively.
$updated = $updated.Replace('loadSong(session, info)', 'loadSongV6(session, info)')
$updated = $updated.Replace('loadSong(session, songs[selectedSong])', 'loadSongV6(session, songs[selectedSong])')
$updated = $updated.Replace('playFromStart(session)', 'playFromStartV6(session)')
$updated = $updated.Replace('togglePause(session)', 'togglePauseV6(session)')

$timingPattern = '(?ms)^static double correctedSongTimeV5\(const Session& s, const Settings& cfg, double chartOffsetSeconds\) \{.*?^\}\r?\n'
$timingReplacement = @'
// alpha.6 timing core -------------------------------------------------------
// GetMusicTimePlayed() is useful as a decoder-progress diagnostic, but it is
// not an audio-device presentation clock. Some encoded files can report
// processed decoder frames at a rate that does not perfectly track audible
// wall time. Gameplay therefore advances from steady_clock and treats audio
// latency as a fixed calibration/metadata offset.
struct GameplayClockV6 {
    bool active = false;
    bool paused = false;
    Clock::time_point started{};
    Clock::time_point pauseStarted{};
    double pausedSeconds = 0.0;

    void start() {
        active = true;
        paused = false;
        pausedSeconds = 0.0;
        started = Clock::now();
        pauseStarted = {};
    }

    void setPaused(bool value) {
        if (!active || value == paused) return;
        if (value) {
            pauseStarted = Clock::now();
            paused = true;
        } else {
            pausedSeconds += std::chrono::duration<double>(Clock::now() - pauseStarted).count();
            paused = false;
        }
    }

    double seconds() const {
        if (!active) return 0.0;
        const auto end = paused ? pauseStarted : Clock::now();
        return std::max(0.0, std::chrono::duration<double>(end - started).count() - pausedSeconds);
    }
};

static GameplayClockV6 gameplayClockV6;
static double activeSongDelayMsV6 = 0.0;
static bool activeSongDelayWasSecondsV6 = false;
static std::string activeSongDelayRawV6 = "0";

static double readCompatibleSongDelayMsV6(const SongInfo& song, bool& interpretedSeconds, std::string& rawText) {
    interpretedSeconds = false;
    rawText = "0";
    std::ifstream in(song.directory / "song.ini");
    std::string line;
    while (std::getline(in, line)) {
        const auto p = line.find('=');
        if (p == std::string::npos) continue;
        if (lower(trim(line.substr(0, p))) != "delay") continue;
        rawText = unquote(line.substr(p + 1));
        try {
            const double value = std::stod(rawText);
            const bool decimalNotation = rawText.find('.') != std::string::npos ||
                                         rawText.find('e') != std::string::npos ||
                                         rawText.find('E') != std::string::npos;
            // The documented song.ini unit is milliseconds, but legacy/community
            // charts also exist with fractional seconds. Only opt into seconds
            // compatibility for explicit fractional notation in a seconds-sized
            // range so ordinary integer delays such as 5 or -12 remain ms.
            if (decimalNotation && std::abs(value) > 0.000001 && std::abs(value) < 20.0) {
                interpretedSeconds = true;
                return value * 1000.0;
            }
            return value;
        } catch (...) {
            break;
        }
    }
    rawText = TextFormat("%.3f", song.delayMs);
    return static_cast<double>(song.delayMs);
}

static void beginTimingForSongV6(Session& s) {
    if (s.song) {
        activeSongDelayMsV6 = readCompatibleSongDelayMsV6(*s.song, activeSongDelayWasSecondsV6, activeSongDelayRawV6);
    } else {
        activeSongDelayMsV6 = 0.0;
        activeSongDelayWasSecondsV6 = false;
        activeSongDelayRawV6 = "0";
    }
    gameplayClockV6.start();
#ifdef _WIN32
    std::ostringstream out;
    out << "alpha.6 song clock start: delay_raw=" << activeSongDelayRawV6
        << " normalized_delay_ms=" << activeSongDelayMsV6
        << " delay_units=" << (activeSongDelayWasSecondsV6 ? "legacy-seconds" : "milliseconds")
        << " resolution=" << s.chart.resolution
        << " tempo_events=" << s.chart.tempos.size()
        << " notes=" << s.chart.notes.size();
    if (!s.chart.notes.empty()) {
        out << " first_note_s=" << s.chart.notes.front().time
            << " last_note_s=" << s.chart.notes.back().time;
    }
    ggdiag::log(out.str());
#endif
}

static bool loadSongV6(Session& s, const SongInfo& info) {
    const bool ok = loadSong(s, info);
    if (ok) beginTimingForSongV6(s);
    return ok;
}

static void playFromStartV6(Session& s) {
    playFromStart(s);
    if (s.playing) gameplayClockV6.start();
}

static void togglePauseV6(Session& s) {
    const bool wasPaused = s.paused;
    togglePause(s);
    if (s.playing && s.paused != wasPaused) gameplayClockV6.setPaused(s.paused);
}

static double decoderClockDriftMsV6(const Session& s) {
    if (s.stems.empty() || !gameplayClockV6.active) return 0.0;
    return (static_cast<double>(GetMusicTimePlayed(s.stems.front().music)) - gameplayClockV6.seconds()) * 1000.0;
}

static double correctedSongTimeV5(const Session& s, const Settings& cfg, double chartOffsetSeconds) {
    if (s.stems.empty() || !s.song) return 0.0;
    const double realtimeSeconds = gameplayClockV6.seconds();

#ifdef _WIN32
    static Clock::time_point lastDriftLog{};
    const auto now = Clock::now();
    if (lastDriftLog.time_since_epoch().count() == 0 || now - lastDriftLog >= std::chrono::seconds(5)) {
        std::ostringstream out;
        out << "Clock diagnostic: realtime_s=" << realtimeSeconds
            << " decoder_s=" << static_cast<double>(GetMusicTimePlayed(s.stems.front().music))
            << " decoder_minus_realtime_ms=" << decoderClockDriftMsV6(s);
        ggdiag::log(out.str());
        lastDriftLog = now;
    }
#endif

    return realtimeSeconds + chartOffsetSeconds
        - activeSongDelayMsV6 / 1000.0
        - static_cast<double>(cfg.audioOffsetMs) / 1000.0;
}
'@

$timingUpdated = [regex]::Replace($updated, $timingPattern, $timingReplacement, 1)
if ($timingUpdated -eq $updated) {
    throw 'Could not locate correctedSongTimeV5() for alpha.6 timing patch'
}
$updated = $timingUpdated

$directory = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Force -Path $directory | Out-Null
[System.IO.File]::WriteAllText($OutputPath, $updated, [System.Text.UTF8Encoding]::new($false))
Write-Host "Prepared alpha.6 source: $OutputPath"
