# Research log — alpha.7 chart compatibility overhaul

Date: 2026-09-15
Project: GitarGame

## Trigger

User playtesting showed chart-dependent timing failures: one chart could be delayed/slow while another could become visually too dense and run ahead of the music. Alpha.6's pure monotonic gameplay clock also demonstrated that a rhythm-game chart must not be allowed to advance independently of the audio transport.

## Human observations that materially changed the implementation

- Desync was song/chart dependent rather than universal.
- Alpha.6 produced notes that appeared faster/denser than the music.
- The requested priority was compatibility, verification and play correctness rather than more menu polish.
- Clear visual distinction between hits and misses was requested, plus graphical accuracy, rock and Star Power feedback.

## Engineering changes

- Split chart parsing into `src/chart_engine.h`.
- Added normalization and issue reporting rather than silently accepting malformed timing metadata.
- Added UTF-8 BOM handling so the first `[Song]` header is not lost.
- Added non-192 Resolution support, full BPM-map integration, exact `.chart` HOPO threshold, open notes, modifier handling, per-lane sustains, Star Power phrases and fallback five-fret tracks.
- Added audio-duration sanity validation and conservative missing-Resolution recovery.
- Reverted the alpha.6 pure wall-clock master. Decoder/audio progress is authoritative again; interpolation is capped at 20 ms and cannot accumulate into independent chart speed.
- Added gameplay judgment state, rock meter, Star Power meter/activation, hit timing feedback, miss ghosts and verification status.
- Added `tests/chart_engine_tests.cpp` and made tests a release gate.

## External references used

- TheNathannator/GuitarGame_ChartFormats — `.chart` format and five-fret semantics.
- Geomitron/scan-chart ecosystem references — used as a target for robust real-world chart parsing philosophy; implementation here is original and intentionally smaller in scope.
- raylib audio documentation/source — used to reassess the alpha.6 clock architecture.

## Verification plan

CI must pass both the Windows native build and chart regression tests. User runtime validation should specifically revisit the GaMetal Green Hill Zone chart and at least one chart that previously behaved correctly, then compare `GitarGame.log` chart summary fields if any disagreement remains.

## Current acceptance status

Pending Windows CI and user playtest at the time of this log entry.
