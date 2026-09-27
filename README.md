# GitarGame

GitarGame is a deliberately small, Windows-first five-fret chart player focused on low overhead, deterministic timing, high configurability, and a controller-first rhythm-game UI.

## Current alpha scope

- Clone Hero-style `notes.chart` parsing for `ExpertSingle`
- `.ogg`, `.mp3`, `.wav`, and `.flac` streaming through raylib
- Multiple audio stems from the song folder
- Basic chords, sustains, HOPO inference, forced-HOPO markers, and tap markers
- Lightweight real-perspective 3D highway
- Audio playback as the gameplay master clock
- `.chart` `Offset`, `song.ini` `delay`, and separate audio/input + video calibration handling
- Keyboard play (`A S J K L`, strum with `Up/Down`)
- XInput guitar support with a built-in binding wizard
- Independent configurable XInput polling thread
- Main menu, song browser, pause menu, settings, and robust A/V calibration screens
- Guitar-driven UI navigation
- Album/cover art and common `song.ini` metadata in the song browser
- Configurable highway speed/length/width, note size, camera FOV, colors, FPS, input polling, hit window, volume, audio/input offset, and video offset
- Native Windows song-folder picker
- Persistent startup/crash log plus Windows minidumps and release PDB symbols

This is still an alpha reference player rather than a behavioral clone of Clone Hero. Open notes, MIDI charts, practice mode, whammy/star-power gameplay, per-instrument tracks, advanced HOPO edge cases, and non-XInput HID/Raw Input backends are planned rather than silently approximated.

## Download

Use the **Releases** page. The Windows release contains a directly runnable `GitarGame.exe` plus a portable ZIP.

On first launch GitarGame creates `config.ini`, `ui.ini`, and a default `songs` directory if needed.

## Guitar UI controls

| Guitar control | UI action |
|---|---|
| Strum Up / Down | Move through menus and songs |
| Green | Select / activate |
| Red | Back |
| Yellow / Blue | Decrease / increase a setting |
| Start | Pause during gameplay |

Keyboard equivalents are the arrow/WASD keys, Enter, and Escape.

## Song browser

GitarGame scans recursively for `notes.chart`. Selected songs can display common metadata such as album, year, genre, and charter plus artwork discovered from common filenames including:

- `album.png`, `album.jpg`, `album.jpeg`
- `cover.png`, `cover.jpg`, `cover.jpeg`
- `icon.png`, `icon.jpg`
- `background.png`, `background.jpg` as a fallback

A typical library entry looks like:

```text
Songs/
  Artist - Song/
    song.ini
    notes.chart
    song.ogg
    guitar.ogg
    album.png
```

The song directory can be changed in **Settings > Song Library** using the Windows folder picker.

## Settings

The in-game settings UI is grouped into:

- **Gameplay** — highway speed, highway length, hit window, note size
- **Audio & Timing** — volume, audio/input offset, full A/V calibration
- **Video** — FPS cap, VSync, fullscreen, FPS display, video offset, auto video calibration
- **Appearance** — palette, individual lane colors, camera FOV, highway width, depth guides, album artwork
- **Input** — polling rate, controller binding, diagnostics
- **Song Library** — song folder, rescanning, detected song count

The underlying files remain plain text. `config.ini` stores core gameplay/video/input settings and `ui.ini` stores presentation/UI preferences.

## Calibration

GitarGame keeps **audio/input latency** and **video/display latency** separate in the engine. Audio/input calibration shifts hit judgment against the audio clock; video calibration shifts only the rendered highway, so correcting a slow display can never make a note easier or harder to hit.

The calibration screen provides three modes:

- **Full A/V auto calibration** — recommended; runs an audible-click pass and then a visual-crossing pass.
- **Audio / input only** — strum when each click is heard.
- **Video only** — strum when an alternating-direction marker crosses the center target.

Each pass collects repeated high-resolution input timestamps, rejects outliers with a robust median/MAD-style estimator, and reports accepted samples, spread, and a quality label before saving. The visual test alternates direction to reduce anticipation bias. Results can still be fine-tuned in 5 ms steps.

Manual audio/input timing adjustment also remains available during gameplay:

| Key | Action |
|---|---|
| F7 | Notes 5 ms earlier |
| F8 | Notes 5 ms later |
| Shift + F7/F8 | Adjust by 25 ms |
| F9 | Reset timing offset |

## Other controls

| Key | Action |
|---|---|
| F1 | Help overlay |
| F2 | Input diagnostics |
| F3 | Controller binding wizard (outside active gameplay) |
| F5 | Rescan songs in the song browser |
| F6 | Reload configuration |
| R | Restart active song |
| Space | Pause/resume active song |
| Esc | Back / pause |

## Performance architecture

Rendering, audio, and input sampling are intentionally decoupled. The 3D highway is a tiny scene consisting of a two-triangle road, simple guide lines, low-poly note discs, and boxes for sustains. XInput polling runs on a separate thread and can target 60–4000 Hz independently of the render FPS cap.

The gameplay clock is derived from the audio stream rather than accumulated frame deltas, so render hitches should not cause chart drift. Hit judgment uses the audio/input-compensated clock, while the highway renderer uses a separate video-compensated view of that clock.

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

## Roadmap

1. Raw Input / HID backend for guitars that do not expose useful XInput mappings.
2. MIDI (`notes.mid`) compatibility and more chart tracks/difficulties.
3. More exact Clone Hero HOPO/strum/fret semantics with regression tests.
4. Practice speed, section looping, and chart inspection.
5. More song-browser filtering/search and additional UI polish.
6. ChartForge integration as a deterministic reference/QA player.

## License

MIT. See `LICENSE`.
