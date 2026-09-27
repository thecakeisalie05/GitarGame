# GitarGame alpha.16 — Clone Hero-like timing/input engine

Date: 2026-09-27

## Goal

Make five-fret gameplay respond more like Clone Hero / Guitar Hero, with emphasis on timing-window feel and controller response rather than cosmetic imitation.

## Reference behavior

Clone Hero's official manual documents the following core semantics used for this pass:

- Strum notes are hit by strumming while the correct frets are held inside the hit window.
- HOPOs can be fret-hit only while a combo is active, but can always be strummed.
- Taps can be fret-hit without an active combo.
- Open HOPOs are hit by releasing held frets with an active combo.
- Open taps are hit by releasing held frets without requiring combo.
- Overstrums break combo and invalidate the current Star Power phrase.

The official documentation defines the hit-window concept but does not publish a numeric default. Alpha.16 therefore uses an approximately 140 ms total window (+/-70 ms) as a Clone Hero-like baseline based on common community measurements, while leaving it fully configurable.

## Key findings in the previous engine

- `InputEvent::when` was captured on the dedicated XInput polling thread but gameplay ignored it and judged every queued event at render-frame `now`.
- A nominal 1000 Hz poll rate therefore still inherited variable render-frame latency/jitter.
- Frame-wide miss advancement occurred before queued inputs were judged, allowing an input sampled inside the window to become a miss if the render frame consumed it after the late boundary.
- The current held-fret mask was reused for all queued events instead of the state that existed when each event was sampled.
- HOPOs were fret-hittable with combo == 0.
- Only fret-down events were used, so physical pull-offs and open fret-release notes could not work.

## Implementation

- InputEvent now stores the complete XInput button snapshot from the poll that generated the transition.
- Simultaneous transitions from one poll are grouped into one musical action.
- Each poll timestamp is mapped back from steady-clock time into the current audio-compensated song clock.
- Miss advancement is performed chronologically around the input events, then committed through the current frame after input processing.
- Strum actions take priority over fret transitions in the same poll so one physical motion cannot strum one note and auto-hit the next HOPO.
- Added CH-style single-note lower-fret anchoring and exact chord matching to a shared tested engine helper.
- HOPO fret transitions require active combo.
- Added true pull-off recognition from higher-fret releases.
- Taps work without active combo but require a fresh target-fret press.
- Added open HOPO/tap release semantics.
- Overstrums now fail the active Star Power phrase.
- Keyboard follows the same press/release rules; XInput remains the high-resolution path.
- Default half-window changed from 120 ms (240 ms total) to 70 ms (~140 ms total).
- Existing configurations still at the historical 120 ms default migrate once; custom values are preserved.

## Verification

A dedicated `guitar-engine` regression executable covers anchoring, exact chords, HOPO gating, pull-offs, taps, open release notes, hit-window edges, and event-to-song-time mapping. Alpha.16 remains gated by all existing chart, MIDI sustain, calibration, gameplay-feedback, Windows build, packaging, and release tests.

## Human acceptance

Pending playtest against familiar Clone Hero charts/controllers. The most useful subjective QA is fast alternate strumming, anchored HOPO ladders, descending pull-offs, repeated taps, and late/early hits near the window boundary.
