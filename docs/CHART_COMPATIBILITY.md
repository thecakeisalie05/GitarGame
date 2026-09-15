# GitarGame chart compatibility layer

GitarGame alpha.7 separates chart parsing/normalization/verification from rendering and input. The goal is to make timing failures observable and testable instead of treating every song as a slightly different special case.

## Playback contract

A parsed chart becomes a normalized `ChartData` object before gameplay starts. Gameplay never derives note spacing from render FPS or from a single global BPM. Every note time is produced by integrating the full `[SyncTrack]` tempo map at the chart's declared ticks-per-quarter-note `Resolution`.

The audio decoder position is the long-term playback authority. The UI may interpolate by at most 20 ms between decoder-position updates for smoother motion, but wall-clock time is not allowed to accumulate into independent chart speed.

Fixed timing adjustments are applied after audio time:

1. `.chart` `[Song] Offset`
2. normalized `song.ini delay`
3. user calibration offset

These values may shift the chart, but never scale chart speed.

## `.chart` compatibility implemented in alpha.7

- UTF-8 BOM normalization before section parsing
- `[Song] Resolution` and `Offset`
- `[SyncTrack]` BPM (`B`), time signature (`TS`) and ignored editor-only anchors (`A`)
- Full piecewise tempo integration
- Five-fret notes 0-4
- HOPO/strum flip modifier 5
- Tap modifier 6
- Open note 7
- Per-lane sustain lengths / extended sustains
- Star Power special phrase type 2
- Exact `.chart` natural-HOPO threshold `floor((65/192) * resolution)`
- Fallback five-fret track selection if `ExpertSingle` is absent
- Duplicate BPM normalization at the same tick
- Missing tick-zero BPM fallback to 120 BPM with a warning

## Verification

On load, the engine records parser issues and performs chart/audio sanity checks. Warnings remain playable; only timing conditions that make playback unsafe are blocking.

The gameplay HUD shows whether the loaded chart is verified or has warnings. `GitarGame.log` records the selected section, resolution, explicit/missing resolution state, BOM detection, tempo-event count, note count, Star Power phrase count, chart end time, audio duration, and each warning/error.

If `Resolution` is genuinely missing and the chart/audio lengths are implausible, GitarGame may conservatively test common chart resolutions and recover only when a candidate produces a substantially more plausible duration. Explicit authored resolutions are never silently changed.

## Regression gate

`tests/chart_engine_tests.cpp` currently covers:

- multiple BPM segments
- UTF-8 BOM + non-192 resolution
- modifier-only events not becoming notes
- exact HOPO threshold behavior
- Star Power phrase parsing and note association
- open notes and open sustains
- fallback track selection

The Windows release workflow runs these tests before packaging or publishing a release.

## Near-term compatibility work

The next major compatibility step after `.chart` stabilization is native `notes.mid` support and explicit instrument/difficulty selection. `.chart` and MIDI should normalize into the same internal `ChartData` representation so gameplay does not care which source format was used.
