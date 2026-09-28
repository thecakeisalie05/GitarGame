# GitarGame alpha.18 — Clone Hero behavioral compatibility pass

Date: 2026-09-28

## Goal

Replace hit-window guessing with an evidence-backed model of Clone Hero guitar behavior.

## Sources and confidence

### High confidence / directly documented

- GenericMadScientist's CHOpt engine writeup documents a normal Clone Hero guitar hit window of 70 ms early / 70 ms late. Its footnote states that Matt, Clone Hero's lead developer, provided a separate 50 ms early-strum leniency value.
  Source: https://genericmadscientist.github.io/posts/how-chopt-works/
- Clone Hero's official manual documents strum, HOPO, tap, anchoring and modifier behavior.
  Source: https://wiki.clonehero.net/books/clone-hero-manual/page/how-to-play
- Current Clone Hero documentation/release notes distinguish normal ghost inputs from punitive ghosting modifiers and expose Precision-style stricter behavior.
  Sources: https://wiki.clonehero.net/ and https://clonehero.net/releases/

### Strong behavioral evidence

- Community testing consistently describes normal Clone Hero/GH3-style infinite frontend for HOPO/tap inputs: a target may be fretted before the normal frontend and remains eligible when the note reaches its window.
- Community testing also consistently reports that a recently hit HOPO can consume a nearby strum rather than creating an immediate overstrum.

### Open-source compatibility reference

- YARG.Core was inspected as a public GH/CH-family implementation, not as evidence of Clone Hero source code.
  Repository: https://github.com/YARC-Official/YARG.Core
- Its five-fret engine independently models a 140 ms default full window, strum leniency timers, HOPO leniency/strum eating, frontend state, anchoring, ghost handling and sustain-drop leniency.
- The 80 ms post-HOPO strum-eat value used by GitarGame alpha.18 is explicitly an approximation derived from YARG's public engine. It is not claimed to be a confirmed Clone Hero constant.

## Engine changes

- Restore the core timing window to ±70 ms.
- Add separate 50 ms early-strum buffering rather than widening the core window.
- Replace alpha.17's per-note frontend arm with persistent GH3-style tap/frontend readiness.
- Any fret transition primes readiness; a normal strum-note hit also primes the next HOPO/tap.
- HOPO/tap hits consume readiness and open a one-strum post-hit forgiveness window.
- Misses, overstrums and restarts clear carried input state.
- Normal ghost fret inputs are non-punitive; actual held-state matching still decides whether a note can hit.
- Single notes allow lower-fret anchoring.
- Strum chords require exact chord state.
- HOPO/tap chords allow lower-fret anchoring beneath the lowest chord fret.
- Existing timestamped XInput judgment from alpha.16 remains unchanged.

## Intentionally unresolved

- Exact current Clone Hero Double Strum Protection default interval was not established from a reliable public source.
- Exact current Clone Hero Sustain Drop Leniency default was not established from a reliable public source.
- Exact note-skipping edge cases and newest ghost/PFC spam-scoring details are not yet modeled.
- These remain explicit follow-up items rather than guessed constants.

## Verification

Alpha.18 is gated on the full Windows build plus chart compatibility, MIDI sustain, calibration estimator, gameplay feedback, guitar-engine and calibration-profile regression tests, followed by packaging/release publication.
