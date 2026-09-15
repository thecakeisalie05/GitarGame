# GitarGame

GitarGame is a deliberately small, Windows-first five-fret chart player focused on low overhead, deterministic timing, and aggressive configurability.

## v0.1.0-alpha.1 scope

- Clone Hero-style `notes.chart` parsing for `ExpertSingle`
- `.ogg`, `.mp3`, `.wav`, and `.flac` streaming through raylib
- Multiple audio stems from the song folder
- Basic chords, sustains, HOPO inference, forced-HOPO markers, and tap markers
- Keyboard play (`A S J K L`, strum with `Up/Down`)
- XInput guitar support with a built-in binding wizard (`F3`)
- Independent XInput polling thread with configurable target polling rate
- Configurable highway speed and length
- Configurable color presets and per-lane colors
- Configurable song directory, FPS cap, hit window, volume, and audio offset
- Recursive song-folder scanning
- Input diagnostics overlay (`F2`)

This is an alpha reference player, not yet a behavioral clone of Clone Hero. Open notes, MIDI charts, practice mode, whammy/star-power gameplay, per-instrument tracks, advanced HOPO edge cases, and non-XInput HID/Raw Input backends are planned rather than silently approximated.

## Download

Use the **Releases** page. The Windows release contains a directly runnable `GitarGame.exe` plus `config.example.ini`.

On first launch GitarGame creates `config.ini` beside the executable and a default `songs` directory if needed.

## Song layout

Point `songs_directory` in `config.ini` at a Clone Hero-compatible song library, or use the default:

```text
GitarGame/
  GitarGame.exe
  config.ini
  songs/
    Artist - Song/
      song.ini
      notes.chart
      song.ogg
      guitar.ogg
```

The scanner searches recursively for `notes.chart`.

## Controls

| Key | Action |
|---|---|
| A S J K L | Green, red, yellow, blue, orange |
| Up / Down | Strum |
| F1 | Help overlay |
| F2 | Input diagnostics |
| F3 | XInput binding wizard |
| F5 | Rescan songs |
| F6 | Reload `config.ini` |
| R | Restart song |
| Space | Pause/resume |
| Esc | Return to browser |

The binding wizard saves the controller mapping back to `config.ini`.

## Configuration

The important knobs are intentionally plain text:

```ini
[video]
fps_cap = 500

[input]
input_poll_hz = 1000

[gameplay]
highway_speed = 1.00
highway_length = 0.82
hit_window_ms = 120
audio_offset_ms = 0

[appearance]
color_scheme = classic
lane_green = #35D04F
lane_red = #EF3340
lane_yellow = #FFD23F
lane_blue = #2684FF
lane_orange = #FF8B2C
```

`input_poll_hz` is independent of `fps_cap` on Windows. The polling thread targets 60-4000 Hz. Very high values can consume more CPU and the effective rate is still constrained by the controller/USB/XInput stack.

## Build

Requirements:

- CMake 3.24+
- Visual Studio 2022 / MSVC
- Git

```powershell
cmake -S . -B build -A x64 -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release
```

raylib 5.5 is fetched automatically at configure time and linked statically.

## Architecture direction

The gameplay clock is derived from the audio stream rather than accumulated frame deltas. Rendering and XInput polling are intentionally decoupled so high input sampling does not require an equally high render cap.

Future priorities:

1. Raw Input / HID backend for guitars that do not expose useful XInput mappings.
2. MIDI (`notes.mid`) compatibility and more chart tracks/difficulties.
3. More exact Clone Hero HOPO/strum/fret semantics with regression tests.
4. Calibration and latency diagnostics.
5. Practice speed, section looping, and chart inspection.
6. ChartForge integration as a deterministic reference/QA player.

## License

MIT. See `LICENSE`.
