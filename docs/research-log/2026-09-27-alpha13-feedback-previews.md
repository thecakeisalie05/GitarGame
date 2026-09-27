# GitarGame alpha.13 — gameplay feedback and song-flow pass

Date: 2026-09-27

## Goal

Improve immediate gameplay readability and make song selection behave more like a mature rhythm-game shell.

## Requested behavior

- Fret/receptor feedback on hits, including an expanding ripple effect.
- Clearer indication that a sustain is actively being held.
- Automatic song previews in song select.
- Automatic return to song select when a song finishes.

## Implementation

- Added realtime hit-event state to the gameplay Session so visual effects are not shifted by video calibration.
- Receptors now brighten/enlarge on successful hits and emit projected 2D expanding ripple rings.
- Chords ripple each struck receptor; open-note hits pulse the receptor row.
- Hit sustains now clamp their visible tail to the strike line, brighten/widen while the correct fret state remains held, and render a luminous core plus latched receptor feedback.
- Added song-preview metadata parsing for `preview_start_time` / `preview_end_time`.
- Added a debounced song-preview transport that prefers dedicated `preview.*` audio, including native `preview.opus` decoding, and otherwise falls back to a bounded segment of the normal stems.
- Gameplay music is explicitly non-looping; previews manually loop only their selected preview window.
- Added audio-completion detection that returns to song select while retaining the current selection.
- Added pure regression helpers/tests for ripple lifetime, sustain-active state, preview window selection, and song-completion thresholds.

## Architecture notes

Preview playback owns a separate set of `Stem` resources from gameplay and is always stopped before gameplay begins. Hit animation timing uses `steady_clock` wall time, while note judgment still uses the audio/input-compensated gameplay clock and note rendering still uses the video-compensated visual clock.

## Verification plan

Release is gated on:

1. Windows configure/generation.
2. Full native application build.
3. Existing chart compatibility tests.
4. MIDI sustain tests.
5. Calibration estimator tests.
6. New gameplay-feedback/preview timing tests.
7. Packaging and alpha.13 publication.
